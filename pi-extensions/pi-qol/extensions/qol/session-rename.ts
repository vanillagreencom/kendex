import type { Message } from "@earendil-works/pi-ai";
import { complete } from "./pi-ai-compat.js";
import type { ExtensionContext, SessionEntry } from "@earendil-works/pi-coding-agent";
import { textFromContent } from "./agent-end.js";
import { oneLine } from "./ansi.js";
import { modelLabel, resolveConfiguredModel } from "./compaction.js";
import {
	AUTO_RENAME_SYSTEM_PROMPT,
	DEFAULT_AUTO_RENAME_FALLBACK_MODEL,
	DEFAULT_AUTO_RENAME_INPUT_CHARS,
	DEFAULT_AUTO_RENAME_MAX_TOKENS,
	DEFAULT_AUTO_RENAME_MODEL,
	DEFAULT_AUTO_RENAME_NAME_CHARS,
	DEFAULT_AUTO_RENAME_PROMPT,
	DEFAULT_AUTO_RENAME_TIMEOUT_MS,
} from "./constants.js";
import { settingBoolean, settingNumber, settingString, settingStringAllowEmpty } from "./settings.js";
import { stringifyError } from "./util.js";

type AutoRenameFallbackMode = "none" | "truncate" | "words";

interface AutoRenameAuth {
	apiKey?: string;
	headers?: Record<string, string>;
	label: string;
	model: any;
	source: string;
}

export function autoRenameEnabled(cwd?: string): boolean {
	return settingBoolean("sessionAutoRename.enabled", true, cwd);
}

// pi raises this exact prefix when a captured ExtensionContext is touched
// after newSession / fork / switchSession / reload. Recognising it lets us
// abort gracefully instead of crashing the host process.
export function isStaleCtxError(error: unknown): boolean {
	const message = error instanceof Error ? error.message : typeof error === "string" ? error : "";
	return /extension ctx is stale/i.test(message);
}

function autoRenameCtxAlive(ctx: ExtensionContext): boolean {
	// Auto-rename runs from a deferred timer / async path, so the captured
	// extension context can be invalidated mid-flight by newSession / fork /
	// switchSession / reload. Touching ctx.hasUI on a stale ctx throws and
	// kills the host pi process, which has surfaced as bg subagents 'failing'
	// at exit code 1 even after their work completed cleanly. Treat any
	// access error as 'no UI available' and silently skip the notification.
	try {
		return ctx.hasUI;
	} catch {
		return false;
	}
}

// Read a ctx property without crashing if the ctx has been replaced. Used
// for the cwd-derived setting reads that downstream helpers depend on.
function readCtxCwd(ctx: ExtensionContext): string | undefined {
	try {
		return ctx.cwd;
	} catch {
		return undefined;
	}
}

function autoRenameDebug(ctx: ExtensionContext, message: string, level: "info" | "warning" | "error" = "info"): void {
	if (!autoRenameCtxAlive(ctx)) return;
	if (settingBoolean("sessionAutoRename.debug", false, ctx.cwd)) ctx.ui.notify(`[auto-rename] ${message}`, level);
}

export function autoRenameNotify(ctx: ExtensionContext, message: string, level: "info" | "warning" | "error" = "info", force = false): void {
	if (!autoRenameCtxAlive(ctx)) return;
	if (force || settingBoolean("sessionAutoRename.notify", false, ctx.cwd) || settingBoolean("sessionAutoRename.debug", false, ctx.cwd)) ctx.ui.notify(`[auto-rename] ${message}`, level);
}

export function firstUserMessageText(branch: SessionEntry[]): string | undefined {
	for (const entry of branch) {
		if (entry.type !== "message" || entry.message?.role !== "user") continue;
		const text = textFromContent(entry.message.content).trim();
		if (text) return text;
	}
	return undefined;
}

export function conversationTranscriptText(branch: SessionEntry[], maxChars: number): string | undefined {
	const lines: string[] = [];
	for (const entry of branch) {
		if (entry.type !== "message") continue;
		const role = entry.message?.role;
		if (role !== "user" && role !== "assistant") continue;
		const text = textFromContent(entry.message.content).trim();
		if (!text) continue;
		lines.push(`${role === "user" ? "User" : "Assistant"}: ${text}`);
	}
	const transcript = lines.join("\n\n").trim();
	return transcript ? truncateMiddle(transcript, maxChars) : undefined;
}

function truncateMiddle(text: string, maxChars: number): string {
	const max = Math.max(200, Math.floor(maxChars));
	if (text.length <= max) return text;
	const marker = "\n[...truncated...]\n";
	const budget = max - marker.length;
	if (budget <= 0) return text.slice(0, max);
	const headBudget = Math.ceil(budget * 0.6);
	const tailBudget = budget - headBudget;
	let head = text.slice(0, headBudget);
	const headSpace = head.lastIndexOf(" ");
	if (headSpace > headBudget * 0.6) head = head.slice(0, headSpace);
	let tail = text.slice(text.length - tailBudget);
	const tailSpace = tail.indexOf(" ");
	if (tailSpace >= 0 && tailSpace < tailBudget * 0.4) tail = tail.slice(tailSpace + 1);
	return `${head}${marker}${tail}`;
}

function clampAutoRenameName(name: string, maxChars: number): string {
	const max = Math.max(20, Math.floor(maxChars));
	let cleaned = oneLine(name).replace(/[.!?:;,]+$/g, "").trim();
	if (cleaned.length <= max) return cleaned;
	const truncated = cleaned.slice(0, max).trimEnd();
	const lastSpace = truncated.lastIndexOf(" ");
	cleaned = lastSpace > max * 0.45 ? truncated.slice(0, lastSpace) : truncated;
	return cleaned.replace(/[,;:\s]+$/g, "").trim();
}

function stripAutoRenameThinkTags(text: string): string {
	return text
		.replace(/<think>[\s\S]*?<\/think>/gi, "")
		.replace(/<thinking>[\s\S]*?<\/thinking>/gi, "")
		.replace(/<think>[\s\S]*/gi, "")
		.replace(/<thinking>[\s\S]*/gi, "")
		.trim();
}

function normalizeAutoRenameCandidate(line: string): string {
	return line
		.replace(/<[^>]+>/g, " ")
		.replace(/^\s*(?:final\s+)?(?:title|name|session\s+name)\s*[:\-]\s*/i, "")
		.replace(/^[\s\-*>#•]+/, "")
		.replace(/^\d+[.)]\s*/, "")
		.replace(/\*\*/g, "")
		.replace(/`/g, "")
		.replace(/^["'“”‘’]+|["'“”‘’]+$/g, "")
		.replace(/\s+/g, " ")
		.trim();
}

function looksLikeAutoRenameReasoning(line: string): boolean {
	if (!line) return true;
	if (/\b(here'?s|i would|best title|candidate|option|reasoning|analysis|thinking)\b/i.test(line)) return true;
	if (/[{}<>|]/.test(line)) return true;
	const words = line.split(/\s+/).filter(Boolean);
	return words.length === 0 || words.length > 12;
}

function autoRenameResponseText(response: any): string {
	const blocks = Array.isArray(response?.content) ? response.content : [];
	const text = blocks
		.filter((block: any) => block?.type === "text" && typeof block.text === "string")
		.map((block: any) => block.text)
		.join("\n")
		.trim();
	if (text) return text;
	return blocks
		.filter((block: any) => block?.type === "thinking" && typeof block.thinking === "string")
		.map((block: any) => block.thinking)
		.join("\n")
		.trim();
}

function sanitizeAutoRenameName(raw: string, maxChars: number): string | undefined {
	const stripped = stripAutoRenameThinkTags(raw);
	const lines = stripped
		.split(/\r?\n/)
		.map(normalizeAutoRenameCandidate)
		.filter(Boolean);
	let name = "";
	for (let index = lines.length - 1; index >= 0; index -= 1) {
		if (!looksLikeAutoRenameReasoning(lines[index]!)) {
			name = lines[index]!;
			break;
		}
	}
	if (!name && lines.length > 0) name = [...lines].sort((a, b) => a.length - b.length)[0]!;
	name = clampAutoRenameName(name, maxChars);
	return name && !looksLikeAutoRenameReasoning(name) ? name : undefined;
}

function titleCaseWord(word: string): string {
	return word ? `${word.charAt(0).toUpperCase()}${word.slice(1).toLowerCase()}` : word;
}

function autoRenameFallbackMode(cwd?: string): AutoRenameFallbackMode {
	const configured = settingString("sessionAutoRename.fallback", "words", cwd).toLowerCase();
	return configured === "none" || configured === "truncate" ? configured : "words";
}

function deterministicAutoRenameName(query: string, cwd?: string): string | undefined {
	const mode = autoRenameFallbackMode(cwd);
	if (mode === "none") return undefined;
	const maxChars = settingNumber("sessionAutoRename.maxNameChars", DEFAULT_AUTO_RENAME_NAME_CHARS, cwd);
	const cleaned = oneLine(query)
		.replace(/[`"'“”‘’]/g, "")
		.replace(/[^\w\s./-]/g, " ")
		.replace(/\s+/g, " ")
		.trim();
	if (!cleaned) return undefined;
	if (mode === "truncate") return clampAutoRenameName(cleaned, Math.min(maxChars, 50));
	const words = cleaned.split(/\s+/).filter(Boolean).slice(0, 6).map(titleCaseWord);
	return clampAutoRenameName(words.join(" "), maxChars);
}

function autoRenamePrompt(query: string, cwd?: string): string {
	const maxChars = Math.max(200, Math.floor(settingNumber("sessionAutoRename.maxInputChars", DEFAULT_AUTO_RENAME_INPUT_CHARS, cwd)));
	const message = truncateMiddle(query, maxChars);
	const configured = settingStringAllowEmpty("sessionAutoRename.prompt", "", cwd);
	const template = configured || DEFAULT_AUTO_RENAME_PROMPT;
	if (template.includes("{{message}}")) return template.split("{{message}}").join(message);
	return `${template.trim()}\n\nFirst user message:\n${message}`.trim();
}

function disabledModelSetting(value: string): boolean {
	const normalized = value.trim().toLowerCase();
	return !normalized || normalized === "none" || normalized === "off" || normalized === "disabled";
}

function autoRenameModelSettings(cwd?: string): string[] {
	const primary = settingString("sessionAutoRename.model", DEFAULT_AUTO_RENAME_MODEL, cwd);
	const fallback = settingStringAllowEmpty("sessionAutoRename.fallbackModel", DEFAULT_AUTO_RENAME_FALLBACK_MODEL, cwd);
	const candidates = [primary];
	if (primary === DEFAULT_AUTO_RENAME_MODEL) candidates.push("openai-codex/gpt-5.3-codex-spark");
	candidates.push(fallback);
	return candidates
		.map((value) => value.trim())
		.filter((value) => !disabledModelSetting(value))
		.filter((value, index, all) => all.findIndex((candidate) => candidate.toLowerCase() === value.toLowerCase()) === index);
}

function headerRecord(headers: unknown): Record<string, string> | undefined {
	if (!headers || typeof headers !== "object" || Array.isArray(headers)) return undefined;
	const entries = Object.entries(headers as Record<string, unknown>)
		.filter((entry): entry is [string, string] => typeof entry[1] === "string" && entry[1].length > 0);
	return entries.length > 0 ? Object.fromEntries(entries) : undefined;
}

function modelCost(model: any): number {
	const cost = model?.cost;
	return Number(cost?.input ?? 0) + Number(cost?.output ?? 0);
}

async function cheapestAvailableAutoRenameModel(ctx: ExtensionContext): Promise<AutoRenameAuth | undefined> {
	let registry: any;
	try {
		registry = ctx.modelRegistry as any;
	} catch (error) {
		if (isStaleCtxError(error)) return undefined;
		throw error;
	}
	const rawModels = typeof registry.getAvailable === "function" ? registry.getAvailable() : typeof registry.getAll === "function" ? registry.getAll() : [];
	const models = Array.isArray(rawModels) ? rawModels.filter((model) => model?.input?.includes?.("text") ?? true) : [];
	models.sort((a, b) => modelCost(a) - modelCost(b) || modelLabel(a).localeCompare(modelLabel(b)));
	for (const model of models) {
		try {
			const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
			const headers = headerRecord(auth.headers);
			if (auth.ok && (auth.apiKey || headers)) return { apiKey: auth.apiKey, headers, label: modelLabel(model), model, source: "cheapest" };
		} catch (error) {
			if (isStaleCtxError(error)) return undefined;
			// Try the next available model.
		}
	}
	return undefined;
}

async function resolveAutoRenameModel(ctx: ExtensionContext, configured: string): Promise<AutoRenameAuth | undefined> {
	try {
		if (configured.trim().toLowerCase() === "cheapest") return await cheapestAvailableAutoRenameModel(ctx);
		const model = resolveConfiguredModel(ctx, configured);
		if (!model) {
			autoRenameDebug(ctx, `model not found: ${configured}`, "warning");
			return undefined;
		}
		try {
			const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
			const headers = headerRecord(auth.headers);
			if (!auth.ok) {
				autoRenameDebug(ctx, `auth unavailable for ${modelLabel(model)}: ${auth.error}`, "warning");
				return undefined;
			}
			if (!auth.apiKey && !headers) {
				autoRenameDebug(ctx, `no auth for ${modelLabel(model)}; use /login or models.json`, "warning");
				return undefined;
			}
			return { apiKey: auth.apiKey, headers, label: modelLabel(model), model, source: configured };
		} catch (error) {
			if (isStaleCtxError(error)) return undefined;
			autoRenameDebug(ctx, `auth failed for ${modelLabel(model)}: ${stringifyError(error)}`, "warning");
			return undefined;
		}
	} catch (error) {
		if (isStaleCtxError(error)) return undefined;
		throw error;
	}
}

export async function generateAutoRenameName(query: string, ctx: ExtensionContext, fullConversation = false): Promise<{ name?: string; source: string }> {
	// Snapshot cwd once. If the ctx has already gone stale, fall through with
	// undefined cwd — downstream settings reads handle that and the rename
	// will abort with "none".
	const cwd = readCtxCwd(ctx);
	const maxNameChars = Math.max(20, Math.floor(settingNumber("sessionAutoRename.maxNameChars", DEFAULT_AUTO_RENAME_NAME_CHARS, cwd)));
	const maxTokens = Math.max(16, Math.floor(settingNumber("sessionAutoRename.maxTokens", DEFAULT_AUTO_RENAME_MAX_TOKENS, cwd)));
	const prompt = fullConversation
		? `${AUTO_RENAME_SYSTEM_PROMPT}\n\nName this session using the conversation transcript below. Return only the title.\n\n${query}`
		: autoRenamePrompt(query, cwd);
	const message: Message = {
		content: [{ text: prompt, type: "text" }],
		role: "user",
		timestamp: Date.now(),
	};

	for (const configured of autoRenameModelSettings(cwd)) {
		const resolved = await resolveAutoRenameModel(ctx, configured);
		if (!resolved) continue;
		try {
			const controller = new AbortController();
			const timeoutMs = Math.max(1000, Math.floor(settingNumber("sessionAutoRename.timeoutMs", DEFAULT_AUTO_RENAME_TIMEOUT_MS, cwd)));
			const timeout = setTimeout(() => controller.abort(), timeoutMs);
			timeout.unref?.();
			try {
				const response = await complete(
					resolved.model,
					{ messages: [message], systemPrompt: AUTO_RENAME_SYSTEM_PROMPT },
					{ apiKey: resolved.apiKey, headers: resolved.headers, maxTokens, signal: controller.signal },
				);
				if (response.stopReason === "error") {
					autoRenameDebug(ctx, `${resolved.label} failed: ${response.errorMessage ?? "unknown error"}`, "warning");
					continue;
				}
				const name = sanitizeAutoRenameName(autoRenameResponseText(response), maxNameChars);
				if (name) return { name, source: resolved.label };
				autoRenameDebug(ctx, `${resolved.label} returned no usable title`, "warning");
			} finally {
				clearTimeout(timeout);
			}
		} catch (error) {
			if (isStaleCtxError(error)) return { source: "none" };
			autoRenameDebug(ctx, `${resolved.label} failed: ${stringifyError(error)}`, "warning");
		}
	}

	const deterministic = deterministicAutoRenameName(query, cwd);
	return deterministic ? { name: deterministic, source: `fallback:${autoRenameFallbackMode(cwd)}` } : { source: "none" };
}

export function withAutoRenamePrefix(name: string, cwd?: string): string {
	const maxNameChars = Math.max(20, Math.floor(settingNumber("sessionAutoRename.maxNameChars", DEFAULT_AUTO_RENAME_NAME_CHARS, cwd)));
	const prefix = clampAutoRenameName(settingStringAllowEmpty("sessionAutoRename.prefix", "", cwd), 40);
	return clampAutoRenameName(prefix ? `${prefix}: ${name}` : name, maxNameChars);
}
