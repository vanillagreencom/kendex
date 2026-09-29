import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { SessionManager, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { oneLine } from "../ansi.js";
import {
	DEFAULT_SESSION_SEARCH_CACHE_TTL_SECONDS,
	DEFAULT_SESSION_SEARCH_SHORTCUT,
	SESSION_SEARCH_PENDING_SYMBOL,
	SESSION_SEARCH_STATUS_KEY,
} from "../constants.js";
import { expandHome, piSettingsPaths, readSettingsFiles } from "../package-config.js";
import { settingBoolean, settingNumber, settingString, settingStringAllowEmpty } from "../settings.js";
import { forEachSessionJsonlLine } from "./jsonl.js";
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
const qolSessionUserMessagesCache = new Map<string, QolSessionUserMessage[]>();
export const qolSessionSearchPendingActions = new Map<string, QolSessionPaletteAction>();
let qolSessionSearchPendingActionCounter = 0;

export function nextSessionSearchPendingActionId(): string {
	return `ss-${Date.now().toString(36)}-${(++qolSessionSearchPendingActionCounter).toString(36)}`;
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

function canonicalPathForSessionSearch(path: string | undefined): string | undefined {
	if (!path) return undefined;
	try {
		return realpathSync.native(path);
	} catch {
		return resolve(path);
	}
}

export function sameSessionSearchProject(sessionCwd: string | undefined, cwd: string): boolean {
	return canonicalPathForSessionSearch(sessionCwd) === canonicalPathForSessionSearch(cwd);
}

export function defaultSessionSearchScope(cwd?: string): QolSessionSearchScope {
	return settingString("sessionSearch.defaultScope", "current", cwd).toLowerCase() === "all" ? "all" : "current";
}

async function loadQolSessionSearchSessions(ctx: ExtensionContext, onProgress?: (loaded: number, total: number) => void): Promise<QolSessionSearchSession[]> {
	const customSessionDir = configuredSessionDir(ctx.cwd);
	const infos = customSessionDir
		? await SessionManager.list(ctx.cwd, customSessionDir, onProgress)
		: await SessionManager.listAll(onProgress);
	return infos.map(sessionInfoToSearchSession).filter((session): session is QolSessionSearchSession => session !== undefined);
}

export async function refreshQolSessionSearchCache(ctx: ExtensionContext, options?: { force?: boolean; quiet?: boolean }): Promise<QolSessionSearchSession[]> {
	const ttlMs = Math.max(0, settingNumber("sessionSearch.cacheTtlSeconds", DEFAULT_SESSION_SEARCH_CACHE_TTL_SECONDS, ctx.cwd) * 1000);
	const fresh = qolSessionSearchCache.length > 0 && (ttlMs === 0 || Date.now() - qolSessionSearchLoadedAt < ttlMs);
	if (!options?.force && fresh) return qolSessionSearchCache;
	if (qolSessionSearchLoading) return qolSessionSearchLoading;

	if (!options?.quiet && ctx.hasUI) ctx.ui.setStatus(SESSION_SEARCH_STATUS_KEY, "Loading sessions...");
	qolSessionSearchLoading = loadQolSessionSearchSessions(ctx, (loaded, total) => {
		if (!options?.quiet && ctx.hasUI) ctx.ui.setStatus(SESSION_SEARCH_STATUS_KEY, `Loading sessions ${loaded}/${total}`);
	}).then((sessions) => {
		qolSessionSearchCache = sessions;
		qolSessionSearchLoadedAt = Date.now();
		qolSessionUserMessagesCache.clear();
		return sessions;
	}).finally(() => {
		qolSessionSearchLoading = undefined;
		if (!options?.quiet && ctx.hasUI) ctx.ui.setStatus(SESSION_SEARCH_STATUS_KEY, undefined);
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

export function sessionUserMessages(sessionPath: string): QolSessionUserMessage[] {
	const cached = qolSessionUserMessagesCache.get(sessionPath);
	if (cached) return cached;
	const messages: QolSessionUserMessage[] = [];
	try {
		forEachSessionJsonlLine(sessionPath, (line) => {
			if (!line.trim()) return;
			let entry: any;
			try { entry = JSON.parse(line); } catch { return; }
			const message = entry?.type === "message" ? entry.message : undefined;
			if (!message || message.role !== "user") return;
			const text = oneLine(messageContentText(message.content));
			if (!text) return;
			messages.push({
				entryId: typeof entry.id === "string" ? entry.id : undefined,
				index: messages.length + 1,
				parentId: typeof entry.parentId === "string" || entry.parentId === null ? entry.parentId : undefined,
				text,
				timestamp: sessionMessageTimestamp(entry, message),
			});
		});
	} catch {
		// Ignore unreadable sessions; callers fall back to SessionInfo.firstMessage.
	}
	qolSessionUserMessagesCache.set(sessionPath, messages);
	return messages;
}

export function userMessagesForResult(result: QolSessionSearchResult): QolSessionUserMessage[] {
	const messages = sessionUserMessages(result.path);
	if (messages.length > 0) return messages;
	return [{ index: 1, text: oneLine(result.firstMessage || "No user messages") }];
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
