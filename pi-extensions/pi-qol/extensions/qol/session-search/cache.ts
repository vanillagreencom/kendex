import { realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { SessionManager, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { oneLine } from "../ansi.js";
import {
	DEFAULT_SESSION_SEARCH_CACHE_TTL_SECONDS,
	DEFAULT_SESSION_SEARCH_SHORTCUT,
	SESSION_SEARCH_PENDING_SYMBOL,
	SESSION_SEARCH_STATUS_KEY,
	SESSION_SEARCH_TEXT_MAX_CHARS,
	SESSION_SEARCH_TEXT_MAX_CHARS_PER_SESSION,
	SESSION_SEARCH_USER_MESSAGES_MAX_SESSIONS,
} from "../constants.js";
import { expandHome, piSettingsPaths, readSettingsFiles } from "../package-config.js";
import { settingBoolean, settingNumber, settingString, settingStringAllowEmpty } from "../settings.js";
import { forEachSessionJsonlLine, forEachSessionJsonlLineAsync } from "./jsonl.js";
import type {
	QolSessionPaletteAction,
	QolSessionSearchPendingMessage,
	QolSessionSearchResult,
	QolSessionSearchScope,
	QolSessionSearchSession,
	QolSessionUserMessage,
} from "./types.js";

let qolSessionSearchCache: QolSessionSearchSession[] = [];
let qolSessionSearchLoadedAt = 0;
let qolSessionSearchLoading: Promise<QolSessionSearchSession[]> | undefined;
let qolSessionSearchLoadController: AbortController | undefined;
let qolSessionSearchReleaseTimer: ReturnType<typeof setTimeout> | undefined;
/** Parsed user prompts per session path, oldest insertion first; at most
 *  SESSION_SEARCH_USER_MESSAGES_MAX_SESSIONS entries. */
const qolSessionUserMessagesCache = new Map<string, QolSessionUserMessage[]>();
/** The resume or fork action the editor's `/search:resume-pending <id>` line
 *  names. Queuing another replaces it, since the editor holds one line. */
let qolSessionSearchPendingAction: { id: string; action: QolSessionPaletteAction } | undefined;
let qolSessionSearchPendingActionCounter = 0;

/** Hold `action` as the one pending action and return the id that claims it. */
export function queueSessionSearchPendingAction(action: QolSessionPaletteAction): string {
	const id = `ss-${Date.now().toString(36)}-${(++qolSessionSearchPendingActionCounter).toString(36)}`;
	qolSessionSearchPendingAction = { id, action };
	return id;
}

/** Remove and return the pending action when `id` names it. */
export function takeSessionSearchPendingAction(id: string): QolSessionPaletteAction | undefined {
	if (qolSessionSearchPendingAction?.id !== id) return undefined;
	const { action } = qolSessionSearchPendingAction;
	qolSessionSearchPendingAction = undefined;
	return action;
}

/** Drop the pending action. Runs on session shutdown. */
export function clearSessionSearchPendingAction(): void {
	qolSessionSearchPendingAction = undefined;
}

export function getPendingSessionSearchMessage(): QolSessionSearchPendingMessage | undefined {
	return (globalThis as unknown as Record<PropertyKey, unknown>)[SESSION_SEARCH_PENDING_SYMBOL] as QolSessionSearchPendingMessage | undefined;
}

export function setPendingSessionSearchMessage(message: QolSessionSearchPendingMessage | undefined): void {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	if (message) host[SESSION_SEARCH_PENDING_SYMBOL] = message;
	else delete host[SESSION_SEARCH_PENDING_SYMBOL];
}

function coerceDate(value: unknown): Date {
	if (value instanceof Date && !Number.isNaN(value.getTime())) return value;
	const date = new Date(typeof value === "string" || typeof value === "number" ? value : 0);
	return Number.isNaN(date.getTime()) ? new Date(0) : date;
}

function sessionInfoToSearchSession(info: any): QolSessionSearchSession | undefined {
	if (!info || typeof info.path !== "string") return undefined;
	return {
		allMessagesText: typeof info.allMessagesText === "string" ? info.allMessagesText : "",
		created: coerceDate(info.created),
		cwd: typeof info.cwd === "string" ? info.cwd : "",
		firstMessage: typeof info.firstMessage === "string" ? info.firstMessage : "(no messages)",
		id: typeof info.id === "string" ? info.id : basename(info.path),
		messageCount: Number.isFinite(Number(info.messageCount)) ? Number(info.messageCount) : 0,
		modified: coerceDate(info.modified),
		name: typeof info.name === "string" && info.name.trim() ? info.name.trim() : undefined,
		parentSessionPath: typeof info.parentSessionPath === "string" ? info.parentSessionPath : undefined,
		path: info.path,
	};
}

function resolveSettingsRelativePath(value: string, settingsPath: string): string {
	const expanded = expandHome(value.trim());
	return isAbsolute(expanded) ? expanded : resolve(dirname(settingsPath), expanded);
}

export function sessionSearchShortcut(cwd?: string): string | undefined {
	// Legacy escape hatch from the original ctrl+f setting. If users disabled it,
	// keep shortcuts disabled even though the default shortcut is now conflict-free.
	if (!settingBoolean("sessionSearch.ctrlFShortcut", true, cwd)) return undefined;
	const shortcut = settingStringAllowEmpty("sessionSearch.shortcutKey", DEFAULT_SESSION_SEARCH_SHORTCUT, cwd).trim().toLowerCase();
	if (!shortcut || shortcut === "none" || shortcut === "off" || shortcut === "false") return undefined;
	if (shortcut === "f3") return DEFAULT_SESSION_SEARCH_SHORTCUT;
	return shortcut;
}

function configuredSessionDir(cwd: string): string | undefined {
	const envDir = process.env.PI_CODING_AGENT_SESSION_DIR?.trim();
	if (envDir) return resolveSettingsRelativePath(envDir, join(resolve(cwd), ".pi", "settings.json"));
	let configured: string | undefined;
	for (const file of readSettingsFiles(piSettingsPaths(cwd))) {
		if (file.kind !== "parsed") continue;
		const sessionDir = file.settings.sessionDir;
		if (typeof sessionDir === "string" && sessionDir.trim()) configured = resolveSettingsRelativePath(sessionDir, file.path);
	}
	return configured;
}

/** Resolve a project once at index entry. A deleted directory keeps its
 * absolute spelling; other filesystem failures remain visible. */
export async function canonicalPathForSessionSearch(path: string): Promise<string> {
	try {
		return await realpath(path);
	} catch (error) {
		if (["ENOENT", "ENOTDIR"].includes((error as NodeJS.ErrnoException).code ?? "")) return resolve(path);
		throw error;
	}
}

/** Prepare prompts and canonical projects asynchronously. Both the shared
 * cache and an overlay supplied with sessions use this index entry point. */
export async function prepareQolSessionSearchSessions(sessions: QolSessionSearchSession[], signal: AbortSignal): Promise<QolSessionSearchSession[]> {
	const paths = new Map<string, string>();
	let budget = SESSION_SEARCH_TEXT_MAX_CHARS;
	const prepared: QolSessionSearchSession[] = [];
	for (const session of [...sessions].sort((a, b) => b.modified.getTime() - a.modified.getTime())) {
		signal.throwIfAborted();
		let canonicalCwd = session.canonicalCwd ?? paths.get(session.cwd);
		if (canonicalCwd === undefined) {
			canonicalCwd = session.cwd ? await canonicalPathForSessionSearch(session.cwd) : "";
			paths.set(session.cwd, canonicalCwd);
		}
		const messages: QolSessionUserMessage[] = [];
		let remaining = Math.min(SESSION_SEARCH_TEXT_MAX_CHARS_PER_SESSION, budget);
		const keep = (message: QolSessionUserMessage) => {
			if (remaining <= 0) return;
			const text = message.text.slice(0, remaining);
			remaining -= text.length;
			budget -= text.length;
			messages.push({ ...message, text });
		};
		if (session.userMessages !== undefined) session.userMessages.forEach(keep);
		else if (remaining > 0) {
			try {
				let index = 0;
				await forEachSessionJsonlLineAsync(session.path, (line) => {
					const message = userMessageFromLine(line, index + 1);
					if (message) { index++; keep(message); }
				}, signal);
			} catch (error) {
				signal.throwIfAborted();
				// Pi can list a session which is removed before its prompt read.
				if (!["ENOENT", "ENOTDIR"].includes((error as NodeJS.ErrnoException).code ?? "")) throw error;
			}
		}
		prepared.push({ ...session, canonicalCwd, userMessages: messages });
	}
	signal.throwIfAborted();
	return prepared;
}

export function defaultSessionSearchScope(cwd?: string): QolSessionSearchScope {
	return settingString("sessionSearch.defaultScope", "current", cwd).toLowerCase() === "all" ? "all" : "current";
}

/** Cap the message text the index keeps: each session's text at the per-session
 *  limit, and the sum at the index limit, filled newest session first. */
export function capSessionSearchText(sessions: QolSessionSearchSession[]): QolSessionSearchSession[] {
	let budget = SESSION_SEARCH_TEXT_MAX_CHARS;
	const newestFirst = [...sessions].sort((a, b) => b.modified.getTime() - a.modified.getTime());
	for (const session of newestFirst) {
		const kept = session.allMessagesText.slice(0, Math.min(SESSION_SEARCH_TEXT_MAX_CHARS_PER_SESSION, budget));
		budget -= kept.length;
		session.allMessagesText = kept;
	}
	return sessions;
}

async function loadQolSessionSearchSessions(ctx: ExtensionContext, signal: AbortSignal, onProgress?: (loaded: number, total: number) => void): Promise<QolSessionSearchSession[]> {
	const customSessionDir = configuredSessionDir(ctx.cwd);
	const infos = customSessionDir
		? await SessionManager.list(ctx.cwd, customSessionDir, onProgress, signal)
		: await SessionManager.listAll(onProgress, signal);
	signal.throwIfAborted();
	return prepareQolSessionSearchSessions(capSessionSearchText(infos.map(sessionInfoToSearchSession).filter((session): session is QolSessionSearchSession => session !== undefined)), signal);
}

/** Drop the loaded index and the parsed prompts. Runs when the index outlives
 *  its TTL and on session shutdown; the next search loads the index again. */
export function releaseQolSessionSearchCache(): void {
	qolSessionSearchLoadController?.abort();
	qolSessionSearchLoadController = undefined;
	qolSessionSearchLoading = undefined;
	if (qolSessionSearchReleaseTimer) clearTimeout(qolSessionSearchReleaseTimer);
	qolSessionSearchReleaseTimer = undefined;
	qolSessionSearchCache = [];
	qolSessionSearchLoadedAt = 0;
	qolSessionUserMessagesCache.clear();
}

export async function refreshQolSessionSearchCache(ctx: ExtensionContext, options?: { force?: boolean; quiet?: boolean }): Promise<QolSessionSearchSession[]> {
	const ttlMs = Math.max(0, settingNumber("sessionSearch.cacheTtlSeconds", DEFAULT_SESSION_SEARCH_CACHE_TTL_SECONDS, ctx.cwd) * 1000);
	// A TTL of 0 keeps the index until session shutdown.
	const fresh = qolSessionSearchCache.length > 0 && (ttlMs === 0 || Date.now() - qolSessionSearchLoadedAt < ttlMs);
	if (!options?.force && fresh) return qolSessionSearchCache;
	if (qolSessionSearchLoading) return qolSessionSearchLoading;

	if (!options?.quiet && ctx.hasUI) ctx.ui.setStatus(SESSION_SEARCH_STATUS_KEY, "Loading sessions...");
	const controller = new AbortController();
	qolSessionSearchLoadController = controller;
	qolSessionSearchLoading = loadQolSessionSearchSessions(ctx, controller.signal, (loaded, total) => {
		if (controller.signal.aborted) return;
		if (!options?.quiet && ctx.hasUI) ctx.ui.setStatus(SESSION_SEARCH_STATUS_KEY, `Loading sessions ${loaded}/${total}`);
	}).then((sessions) => {
		controller.signal.throwIfAborted();
		qolSessionSearchLoadController = undefined;
		releaseQolSessionSearchCache();
		qolSessionSearchCache = sessions;
		qolSessionSearchLoadedAt = Date.now();
		if (ttlMs > 0) {
			qolSessionSearchReleaseTimer = setTimeout(releaseQolSessionSearchCache, ttlMs);
			qolSessionSearchReleaseTimer.unref?.();
		}
		return sessions;
	}).finally(() => {
		if (qolSessionSearchLoadController === controller || !controller.signal.aborted) {
			qolSessionSearchLoadController = undefined;
			qolSessionSearchLoading = undefined;
			if (!options?.quiet && ctx.hasUI) ctx.ui.setStatus(SESSION_SEARCH_STATUS_KEY, undefined);
		}
	});
	return qolSessionSearchLoading;
}

function messageContentText(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.map((part: any) => {
		if (part?.type === "text" && typeof part.text === "string") return part.text;
		if (part?.type === "image") return "[image]";
		return "";
	}).filter(Boolean).join(" ");
}

function sessionMessageTimestamp(entry: any, message: any): number | undefined {
	if (typeof message?.timestamp === "number" && Number.isFinite(message.timestamp)) return message.timestamp;
	if (typeof entry?.timestamp === "number" && Number.isFinite(entry.timestamp)) return entry.timestamp;
	if (typeof entry?.timestamp === "string") {
		const parsed = new Date(entry.timestamp).getTime();
		if (!Number.isNaN(parsed)) return parsed;
	}
	return undefined;
}

function userMessageFromLine(line: string, index: number, fullText = false): QolSessionUserMessage | undefined {
	let entry: { type?: string; id?: unknown; parentId?: unknown; timestamp?: unknown; message?: { role?: string; content?: unknown; timestamp?: unknown } };
	try { entry = JSON.parse(line); } catch { return undefined; }
	const message = entry?.type === "message" ? entry.message : undefined;
	if (message?.role !== "user") return undefined;
	const content = messageContentText(message.content);
	const text = fullText ? content : oneLine(content);
	if (!text) return undefined;
	return {
		entryId: typeof entry.id === "string" ? entry.id : undefined,
		index,
		parentId: typeof entry.parentId === "string" || entry.parentId === null ? entry.parentId : undefined,
		text,
		timestamp: sessionMessageTimestamp(entry, message),
	};
}

export function sessionUserMessages(sessionPath: string): QolSessionUserMessage[] {
	const cached = qolSessionUserMessagesCache.get(sessionPath);
	if (cached) return cached;
	const messages: QolSessionUserMessage[] = [];
	try {
		forEachSessionJsonlLine(sessionPath, (line) => {
			const message = userMessageFromLine(line, messages.length + 1);
			if (message) messages.push(message);
		});
	} catch {
		// Ignore unreadable sessions; callers fall back to SessionInfo.firstMessage.
	}
	qolSessionUserMessagesCache.set(sessionPath, messages);
	for (const oldest of qolSessionUserMessagesCache.keys()) {
		if (qolSessionUserMessagesCache.size <= SESSION_SEARCH_USER_MESSAGES_MAX_SESSIONS) break;
		qolSessionUserMessagesCache.delete(oldest);
	}
	return messages;
}

export function userMessagesForResult(result: QolSessionSearchResult): QolSessionUserMessage[] {
	const messages = result.userMessages ?? sessionUserMessages(result.path);
	if (messages.length > 0) return messages;
	return [{ index: 1, text: oneLine(result.firstMessage || "No user messages") }];
}

/** Load the original Copy/Fork payload without retaining it in the index.
 * SessionManager.open reads synchronously, so use Pi's documented JSONL
 * format to stream to the selected entry instead. */
export async function sessionUserMessageForAction(result: QolSessionSearchResult, selected?: QolSessionUserMessage, signal = new AbortController().signal): Promise<QolSessionUserMessage> {
	let found: QolSessionUserMessage | undefined;
	let index = 0;
	await forEachSessionJsonlLineAsync(result.path, (line) => {
		const message = userMessageFromLine(line, index + 1, true);
		if (!message) return;
		index++;
		if (selected?.entryId ? message.entryId === selected.entryId : message.index === (selected?.index ?? 1)) {
			found = message;
			return false;
		}
	}, signal, { maxLineChars: Infinity });
	signal.throwIfAborted();
	if (!found) throw new Error(`Session prompt not found: ${selected?.entryId ?? selected?.index ?? 1}`);
	return found;
}

export function sessionUserPromptCount(session: QolSessionSearchSession): number {
	const count = sessionUserMessages(session.path).length;
	if (count > 0) return count;
	return session.firstMessage && session.firstMessage !== "(no messages)" ? 1 : 0;
}

export function promptCountLabel(count: number): string {
	return `${count} prompt${count === 1 ? "" : "s"}`;
}

export function lastUserMessageSnippet(session: QolSessionSearchSession): string {
	const messages = sessionUserMessages(session.path);
	return messages[messages.length - 1]?.text || oneLine(session.firstMessage || "No user messages");
}

export function sessionDisplayName(session: QolSessionSearchSession): string {
	if (session.name) return oneLine(session.name) || "session";
	if (session.cwd) {
		const parts = oneLine(session.cwd).split(/[\\/]+/).filter(Boolean);
		if (parts.length >= 2) return parts.slice(-2).join("/");
		if (parts.length === 1) return parts[0]!;
	}
	return oneLine(basename(session.path) || "session") || "session";
}

export function sessionResumeTitle(session: QolSessionSearchSession): string {
	// Match /resume's primary label: explicit session name, otherwise first user prompt.
	if (session.name) return oneLine(session.name) || sessionDisplayName(session);
	if (session.firstMessage && session.firstMessage !== "(no messages)") return oneLine(session.firstMessage) || sessionDisplayName(session);
	return sessionDisplayName(session);
}

export function shortPathForUi(path: string): string {
	const cleaned = oneLine(path);
	const home = homedir();
	if (cleaned === home) return "~";
	if (cleaned.startsWith(`${home}/`)) return `~${cleaned.slice(home.length)}`;
	return cleaned;
}

export interface QolModelInfo {
	provider: string;
	id: string;
}

export function sessionModelInfo(sessionPath: string): QolModelInfo | undefined {
	try {
		const model = SessionManager.open(sessionPath).buildSessionContext().model;
		if (!model?.provider || !model?.modelId) return undefined;
		return { provider: model.provider, id: model.modelId };
	} catch {
		return undefined;
	}
}

export function sameModel(a: QolModelInfo | undefined, b: QolModelInfo | undefined): boolean {
	return Boolean(a && b && a.provider === b.provider && a.id === b.id);
}

export function modelLabel(model: QolModelInfo | undefined): string {
	return model ? `${model.provider}/${model.id}` : "unknown model";
}

export function pinSessionModel(sessionPath: string, model: NonNullable<ExtensionContext["model"]>, thinkingLevel?: string): void {
	const manager = SessionManager.open(sessionPath);
	const context = manager.buildSessionContext();
	if (context.model?.provider !== model.provider || context.model?.modelId !== model.id) {
		manager.appendModelChange(model.provider, model.id);
	}
	if (thinkingLevel) {
		const branch = manager.getBranch();
		const lastThinking = [...branch].reverse().find((entry: any) => entry?.type === "thinking_level_change") as { thinkingLevel?: string } | undefined;
		if (lastThinking?.thinkingLevel !== thinkingLevel) manager.appendThinkingLevelChange(thinkingLevel as any);
	}
}
