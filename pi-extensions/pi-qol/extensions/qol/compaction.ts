import { mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { complete, type Message } from "@earendil-works/pi-ai";
import { convertToLlm, serializeConversation, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
	DEFAULT_BUDGET_GUARD_PERCENT,
	DEFAULT_BUDGET_GUARD_TOKENS,
	DEFAULT_BUDGET_MAX_INPUT_CHARS,
	DEFAULT_COMPACTION_MAX_TOKENS,
	DEFAULT_COMPACTION_MODEL,
	DEFAULT_IDLE_COMPACTION_THRESHOLD_TOKENS,
	DEFAULT_TRANSCRIPT_RISK_WARN_CHARS,
	QOL_BUDGET_HANDOFF_FOLDER,
	QOL_BUDGET_HANDOFF_LATEST,
	QOL_COMPACTION_SYSTEM_PROMPT,
} from "./constants.js";
import {
	chunkConversationText as chunkConversationTextRaw,
	computeBudgetTrigger,
	evaluateTranscriptRisk,
	type BudgetTrigger,
	type TranscriptRiskResult,
} from "./budget-guard.js";
import { settingBoolean, settingNumber, settingString } from "./settings.js";
import { stringifyError } from "./util.js";

export type QolSummaryProfile = "concise" | "balanced" | "exhaustive";
export type QolSummaryPurpose = "compaction" | "branch-summary" | "session-search";

export function compactionNotify(ctx: ExtensionContext, message: string, level: "info" | "warning" | "error" = "info"): void {
	if (ctx.hasUI && settingBoolean("compaction.notify", true, ctx.cwd)) ctx.ui.notify(message, level);
}

export function compactionProfile(cwd: string): QolSummaryProfile {
	const value = settingString("compaction.profile", "balanced", cwd);
	return value === "concise" || value === "exhaustive" ? value : "balanced";
}

function compactionProfileInstructions(profile: QolSummaryProfile): string {
	if (profile === "concise") return "Prefer a compact continuation summary. Include only decisions, current state, modified/read files, blockers, and concrete next steps.";
	if (profile === "exhaustive") return "Be thorough. The summary may replace substantial conversation history, so preserve all relevant implementation details, alternatives considered, exact file paths, commands, errors, and pending work.";
	return "Be complete but not verbose. Preserve enough detail for a future assistant to continue without the old transcript.";
}

function stripThinkingForSummary(messages: Message[]): Message[] {
	return messages.map((message) => {
		if (message.role !== "assistant" || !Array.isArray(message.content)) return message;
		return {
			...message,
			content: message.content.filter((part: any) => part?.type !== "thinking"),
		};
	});
}

export function serializeMessagesForSummary(messages: AgentMessage[]): string {
	return serializeConversation(stripThinkingForSummary(convertToLlm(messages)));
}

function customMessageContentToText(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	const parts: string[] = [];
	for (const part of content) {
		if (part?.type === "text" && typeof part.text === "string") parts.push(part.text);
		else if (part?.type === "image") parts.push(`[image${typeof part.mimeType === "string" ? ` ${part.mimeType}` : ""}]`);
		else if (part?.type) parts.push(`[${String(part.type)}]`);
	}
	return parts.join("\n").trim();
}

function buildSummaryPrompt(options: {
	conversationText: string;
	customInstructions?: string;
	previousSummary?: string;
	profile: QolSummaryProfile;
	purpose: QolSummaryPurpose;
}): string {
	const purposeText = options.purpose === "branch-summary"
		? "the branch being left during /tree navigation"
		: options.purpose === "session-search"
			? "the previous session being imported into the current context"
			: "the conversation span being compacted";
	const previous = options.previousSummary ? `<previous-summary>\n${options.previousSummary}\n</previous-summary>\n\n` : "";
	const custom = options.customInstructions?.trim() ? `<custom-instructions>\n${options.customInstructions.trim()}\n</custom-instructions>\n\n` : "";
	return `${custom}${previous}<conversation>\n${options.conversationText}\n</conversation>\n\nSummarize ${purposeText} for a coding agent that must continue the work.\n\n${compactionProfileInstructions(options.profile)}\n\nUse this markdown shape:\n\n## Goal\n[What the user is trying to accomplish]\n\n## Constraints & Preferences\n- [Requirements, style, safety, or user preferences]\n\n## Progress\n### Done\n- [x] [Completed work]\n\n### In Progress\n- [ ] [Current partial work]\n\n### Blocked\n- [Blockers or none]\n\n## Key Decisions\n- **[Decision]**: [Rationale]\n\n## Files & Commands\n- [Files read/modified and important commands/results]\n\n## Next Steps\n1. [Most important next action]\n\n## Critical Context\n- [Anything easy to lose but needed later]`;
}

async function summarizeWithRemote(endpoint: string, systemPrompt: string, promptText: string, maxTokens: number, signal?: AbortSignal): Promise<string> {
	const response = await fetch(endpoint, {
		body: JSON.stringify({ maxTokens, prompt: promptText, systemPrompt }),
		headers: { "content-type": "application/json" },
		method: "POST",
		signal,
	});
	const text = await response.text();
	if (!response.ok) throw new Error(`Remote compaction endpoint returned ${response.status}: ${text.slice(0, 500)}`);
	let parsed: unknown;
	try {
		parsed = JSON.parse(text);
	} catch {
		throw new Error("Remote compaction endpoint did not return JSON");
	}
	if (parsed && typeof parsed === "object") {
		const record = parsed as Record<string, unknown>;
		if (typeof record.summary === "string") return record.summary;
		if (typeof record.text === "string") return record.text;
	}
	throw new Error("Remote compaction response missing summary");
}

export function resolveConfiguredModel(ctx: ExtensionContext, configured: string): any | undefined {
	if (!configured || configured.trim().toLowerCase() === "current") return ctx.model;
	const withoutThinking = configured.replace(/:(off|minimal|low|medium|high|xhigh)$/i, "");
	const slash = withoutThinking.indexOf("/");
	if (slash > 0) return ctx.modelRegistry.find(withoutThinking.slice(0, slash), withoutThinking.slice(slash + 1));
	const providers = [ctx.model?.provider, "google", "openai", "anthropic", "mistral", "moonshot", "cloudflare-ai-gateway", "cloudflare-workers-ai"].filter((value): value is string => typeof value === "string");
	for (const provider of providers) {
		const model = ctx.modelRegistry.find(provider, withoutThinking);
		if (model) return model;
	}
	return undefined;
}

export function modelLabel(model: any): string {
	return model ? `${model.provider}/${model.id}` : "unknown model";
}

function budgetMaxInputChars(ctx: ExtensionContext): number {
	const raw = Math.floor(settingNumber("compaction.maxInputChars", DEFAULT_BUDGET_MAX_INPUT_CHARS, ctx.cwd));
	// 0 or negative disables chunking. Anything above the hard floor is honored.
	return raw <= 0 ? 0 : Math.max(20_000, raw);
}

export const chunkConversationText = chunkConversationTextRaw;

export async function generateQolSummary(ctx: ExtensionContext, options: {
	conversationText: string;
	customInstructions?: string;
	previousSummary?: string;
	maxTokens?: number;
	model?: string;
	purpose: QolSummaryPurpose;
	signal?: AbortSignal;
	/** Internal: set true on recursive summary-of-summaries pass to skip rechunking. */
	skipChunking?: boolean;
}): Promise<{ model: string; summary: string; via: "model" | "remote"; chunkCount?: number }> {
	const maxTokens = Math.max(256, Math.floor(options.maxTokens ?? settingNumber("compaction.maxTokens", DEFAULT_COMPACTION_MAX_TOKENS, ctx.cwd)));
	const maxInputChars = budgetMaxInputChars(ctx);
	if (!options.skipChunking && maxInputChars > 0 && options.conversationText.length > maxInputChars) {
		return summarizeChunked(ctx, { ...options, maxTokens });
	}
	const promptText = buildSummaryPrompt({
		conversationText: options.conversationText,
		customInstructions: options.customInstructions,
		previousSummary: settingBoolean("compaction.includePreviousSummary", true, ctx.cwd) ? options.previousSummary : undefined,
		profile: compactionProfile(ctx.cwd),
		purpose: options.purpose,
	});

	const remoteEndpoint = settingString("compaction.remoteEndpoint", "", ctx.cwd);
	if (settingBoolean("compaction.remoteEnabled", false, ctx.cwd) && remoteEndpoint) {
		try {
			const summary = await summarizeWithRemote(remoteEndpoint, QOL_COMPACTION_SYSTEM_PROMPT, promptText, maxTokens, options.signal);
			return { model: remoteEndpoint, summary, via: "remote" };
		} catch (error) {
			compactionNotify(ctx, `Remote compaction failed, trying model fallback: ${stringifyError(error)}`, "warning");
		}
	}

	const configuredModel = options.model ?? settingString("compaction.model", DEFAULT_COMPACTION_MODEL, ctx.cwd);
	const model = resolveConfiguredModel(ctx, configuredModel);
	if (!model) throw new Error(`Summary model not found: ${configuredModel}`);
	const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
	if (!auth.ok) throw new Error(auth.error);
	if (!auth.apiKey) throw new Error(`No API key for ${model.provider}`);

	const message: Message = {
		content: [{ text: promptText, type: "text" }],
		role: "user",
		timestamp: Date.now(),
	};
	const response = await complete(
		model,
		{ messages: [message], systemPrompt: QOL_COMPACTION_SYSTEM_PROMPT },
		{ apiKey: auth.apiKey, headers: auth.headers, maxTokens, signal: options.signal },
	);
	const summary = response.content
		.filter((content): content is { type: "text"; text: string } => content.type === "text")
		.map((content) => content.text)
		.join("\n")
		.trim();
	return { model: modelLabel(model), summary, via: "model" };
}

async function summarizeChunked(ctx: ExtensionContext, options: {
	conversationText: string;
	customInstructions?: string;
	previousSummary?: string;
	maxTokens: number;
	model?: string;
	purpose: QolSummaryPurpose;
	signal?: AbortSignal;
}): Promise<{ model: string; summary: string; via: "model" | "remote"; chunkCount?: number }> {
	const maxInputChars = budgetMaxInputChars(ctx);
	const chunks = chunkConversationText(options.conversationText, maxInputChars);
	if (chunks.length <= 1) {
		return generateQolSummary(ctx, { ...options, skipChunking: true });
	}
	compactionNotify(ctx, `QOL chunked compaction: summarizing ${chunks.length} chunks (input ${options.conversationText.length.toLocaleString()} chars > cap ${maxInputChars.toLocaleString()}).`, "info");
	const partials: string[] = [];
	let lastVia: "model" | "remote" = "model";
	let lastModel = "";
	let previousSummary = options.previousSummary;
	for (let i = 0; i < chunks.length; i += 1) {
		if (options.signal?.aborted) throw new Error("Compaction aborted");
		const chunkText = chunks[i] ?? "";
		const customInstructions = `${options.customInstructions ? `${options.customInstructions}\n\n` : ""}This is chunk ${i + 1} of ${chunks.length} from a long conversation. Preserve all concrete files, commands, decisions, blockers, and current tasks visible in this chunk so a follow-up summary-of-summaries pass can stitch the timeline together.`;
		const partial = await generateQolSummary(ctx, {
			conversationText: chunkText,
			customInstructions,
			previousSummary,
			maxTokens: options.maxTokens,
			model: options.model,
			purpose: options.purpose,
			signal: options.signal,
			skipChunking: true,
		});
		if (!partial.summary.trim()) throw new Error(`Chunk ${i + 1}/${chunks.length} summary was empty`);
		partials.push(`### Chunk ${i + 1}/${chunks.length}\n${partial.summary.trim()}`);
		previousSummary = partial.summary;
		lastVia = partial.via;
		lastModel = partial.model;
	}
	const reduceText = partials.join("\n\n");
	const reduceInstructions = `${options.customInstructions ? `${options.customInstructions}\n\n` : ""}Merge the following chunk summaries (oldest first) into a single continuation summary. De-duplicate facts, keep exact files/commands/paths, preserve decisions, blockers, current tasks, and any artifact paths. If chunks contradict, prefer the most recent.`;
	const final = await generateQolSummary(ctx, {
		conversationText: reduceText,
		customInstructions: reduceInstructions,
		previousSummary: options.previousSummary,
		maxTokens: options.maxTokens,
		model: options.model,
		purpose: options.purpose,
		signal: options.signal,
		skipChunking: true,
	});
	return { chunkCount: chunks.length, model: final.model || lastModel, summary: final.summary, via: final.via || lastVia };
}

function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

function piUserDir(): string {
	return resolve(expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "~/.pi/agent"));
}

function safeFileName(value: string): string {
	return value.replace(/[^\w.-]+/g, "_");
}

function sessionIdForHandoff(ctx: ExtensionContext): string {
	const sm = ctx.sessionManager as any;
	const id = typeof sm.getSessionId === "function" ? sm.getSessionId() : undefined;
	if (typeof id === "string" && id.trim()) return id;
	const file = typeof sm.getSessionFile === "function" ? sm.getSessionFile() : undefined;
	if (typeof file === "string" && file.trim()) return basename(file, ".jsonl");
	return `ephemeral-${process.pid}`;
}

export interface QolBudgetHandoff {
	reason: string;
	timestamp: number;
	sessionId: string;
	tokensBefore?: number;
	messageCount: number;
	previousSummary?: string;
	taskState?: unknown;
	artifactRefs: string[];
	model?: string;
}

export function writeBudgetHandoffArtifact(ctx: ExtensionContext, handoff: QolBudgetHandoff): string | undefined {
	if (!settingBoolean("compaction.handoffArtifactEnabled", true, ctx.cwd)) return undefined;
	try {
		const baseDir = join(piUserDir(), "vstack", "sessions", safeFileName(handoff.sessionId), QOL_BUDGET_HANDOFF_FOLDER);
		mkdirSync(baseDir, { recursive: true, mode: 0o700 });
		const stamped = join(baseDir, `${new Date(handoff.timestamp).toISOString().replace(/[:.]/g, "-")}.json`);
		const latest = join(dirname(baseDir), basename(baseDir), QOL_BUDGET_HANDOFF_LATEST);
		const payload = JSON.stringify(handoff, null, 2);
		writeFileSync(stamped, payload, { mode: 0o600 });
		writeFileSync(latest, payload, { mode: 0o600 });
		return stamped;
	} catch {
		return undefined;
	}
}

function lastTaskStateFromBranch(ctx: ExtensionContext): unknown {
	try {
		const branch = ctx.sessionManager.getBranch?.() ?? [];
		for (let i = branch.length - 1; i >= 0; i -= 1) {
			const entry = branch[i] as any;
			if (entry?.type !== "message" || entry.message?.role !== "toolResult") continue;
			const content = entry.message.content;
			const parts = Array.isArray(content) ? content : [];
			for (const part of parts) {
				if (part?.type !== "toolResult") continue;
				const details = part?.details;
				if (details && typeof details === "object" && "state" in (details as Record<string, unknown>)) {
					return (details as Record<string, unknown>).state;
				}
			}
		}
	} catch {
		// Best-effort. Missing task state just means a smaller handoff payload.
	}
	return undefined;
}

function collectArtifactRefs(ctx: ExtensionContext, maxRefs = 20): string[] {
	try {
		const branch = ctx.sessionManager.getBranch?.() ?? [];
		const refs = new Set<string>();
		const pattern = /(?:^|\s|["'`(\[<])((?:\.{1,2}\/|\/|~\/)?[\w.\-+@/]+\.(?:md|json|jsonl|txt|log|ts|tsx|js|jsx|rs|toml|yml|yaml|html|sh|fish|bash|py|go|java|cs|cpp|h|hpp|sql|csv|env|lock|patch|diff))/g;
		for (let i = branch.length - 1; i >= 0 && refs.size < maxRefs; i -= 1) {
			const entry = branch[i] as any;
			if (entry?.type !== "message") continue;
			const content = entry.message?.content;
			const parts = Array.isArray(content) ? content : [];
			for (const part of parts) {
				const text = typeof part?.text === "string" ? part.text : typeof part?.thinking === "string" ? part.thinking : "";
				if (!text) continue;
				pattern.lastIndex = 0;
				let match: RegExpExecArray | null;
				while ((match = pattern.exec(text)) !== null && refs.size < maxRefs) {
					if (match[1]) refs.add(match[1]);
				}
			}
		}
		return Array.from(refs);
	} catch {
		return [];
	}
}

export function buildBudgetHandoff(ctx: ExtensionContext, options: {
	reason: string;
	preparation?: { messagesToSummarize?: AgentMessage[]; turnPrefixMessages?: AgentMessage[]; previousSummary?: string; tokensBefore?: number };
}): QolBudgetHandoff {
	const preparation = options.preparation ?? {};
	const messageCount = (preparation.messagesToSummarize?.length ?? 0) + (preparation.turnPrefixMessages?.length ?? 0);
	return {
		artifactRefs: collectArtifactRefs(ctx),
		messageCount,
		previousSummary: preparation.previousSummary,
		reason: options.reason,
		sessionId: sessionIdForHandoff(ctx),
		taskState: lastTaskStateFromBranch(ctx),
		timestamp: Date.now(),
		tokensBefore: typeof preparation.tokensBefore === "number" ? preparation.tokensBefore : undefined,
	};
}

export async function handleQolCompaction(event: any, ctx: ExtensionContext): Promise<any> {
	if (!settingBoolean("compaction.customEnabled", false, ctx.cwd)) return undefined;
	const preparation = event.preparation ?? {};
	const messages = [...(preparation.messagesToSummarize ?? []), ...(preparation.turnPrefixMessages ?? [])];
	if (messages.length === 0) return undefined;
	const tokensBefore = typeof preparation.tokensBefore === "number" ? preparation.tokensBefore : 0;
	const handoff = buildBudgetHandoff(ctx, { preparation, reason: event.customInstructions ?? "session_before_compact" });
	const handoffPath = writeBudgetHandoffArtifact(ctx, handoff);
	compactionNotify(ctx, `QOL compaction: summarizing ${messages.length} message(s), ${tokensBefore.toLocaleString()} token(s).`, "info");
	try {
		const conversationText = serializeMessagesForSummary(messages);
		const result = await generateQolSummary(ctx, {
			conversationText,
			customInstructions: event.customInstructions,
			previousSummary: preparation.previousSummary,
			purpose: "compaction",
			signal: event.signal,
		});
		if (!result.summary.trim()) throw new Error("Compaction summary was empty");
		const chunkSuffix = result.chunkCount && result.chunkCount > 1 ? ` (${result.chunkCount} chunks)` : "";
		compactionNotify(ctx, `QOL compaction complete via ${result.via}: ${result.model}${chunkSuffix}`, "info");
		return {
			compaction: {
				details: {
					chunkCount: result.chunkCount,
					handoffArtifact: handoffPath,
					messageCount: messages.length,
					model: result.model,
					profile: compactionProfile(ctx.cwd),
					source: "pi-qol",
					via: result.via,
				},
				firstKeptEntryId: preparation.firstKeptEntryId,
				summary: result.summary,
				tokensBefore: preparation.tokensBefore,
			},
		};
	} catch (error) {
		if (event.signal?.aborted) return undefined;
		compactionNotify(ctx, `QOL compaction failed: ${stringifyError(error)}`, "error");
		return settingBoolean("compaction.fallbackToDefault", true, ctx.cwd) ? undefined : { cancel: true };
	}
}

function summarizeEntryForBranch(entry: any): string[] {
	if (entry?.type === "message" && entry.message) return [serializeMessagesForSummary([entry.message])];
	if (entry?.type === "compaction" && typeof entry.summary === "string") return [`[Compaction summary]: ${entry.summary}`];
	if (entry?.type === "branch_summary" && typeof entry.summary === "string") return [`[Branch summary]: ${entry.summary}`];
	if (entry?.type === "custom_message") return [`[Custom message${entry.customType ? `:${entry.customType}` : ""}]: ${customMessageContentToText(entry.content) || "[empty]"}`];
	return [];
}

export async function handleQolBranchSummary(event: any, ctx: ExtensionContext): Promise<any> {
	if (!settingBoolean("compaction.branchSummaryEnabled", false, ctx.cwd)) return undefined;
	const preparation = event.preparation ?? {};
	if (preparation.userWantsSummary !== true) return undefined;
	const entries = Array.isArray(preparation.entriesToSummarize) ? preparation.entriesToSummarize : [];
	const conversationText = entries.flatMap(summarizeEntryForBranch).join("\n\n").trim();
	if (!conversationText) return undefined;
	compactionNotify(ctx, `QOL branch summary: summarizing ${entries.length} entr${entries.length === 1 ? "y" : "ies"}.`, "info");
	try {
		const result = await generateQolSummary(ctx, {
			conversationText,
			customInstructions: event.customInstructions ?? preparation.customInstructions,
			purpose: "branch-summary",
			signal: event.signal,
		});
		if (!result.summary.trim()) throw new Error("Branch summary was empty");
		return {
			summary: {
				details: { entryCount: entries.length, model: result.model, profile: compactionProfile(ctx.cwd), source: "pi-qol", via: result.via },
				summary: result.summary,
			},
		};
	} catch (error) {
		if (event.signal?.aborted) return undefined;
		compactionNotify(ctx, `QOL branch summary failed: ${stringifyError(error)}`, "error");
		return undefined;
	}
}

function contextUsage(ctx: ExtensionContext): { contextWindow?: number; tokens: number } | undefined {
	const usage = ctx.getContextUsage?.() as { tokens?: unknown; contextWindow?: unknown } | undefined;
	const tokens = Number(usage?.tokens);
	if (!Number.isFinite(tokens) || tokens <= 0) return undefined;
	const contextWindow = Number(usage?.contextWindow ?? ctx.model?.contextWindow);
	return { contextWindow: Number.isFinite(contextWindow) && contextWindow > 0 ? contextWindow : undefined, tokens };
}

export function compactionTriggerReason(ctx: ExtensionContext): string | undefined {
	const usage = contextUsage(ctx);
	if (!usage) return undefined;
	const tokenLimit = settingNumber("compaction.thresholdTokens", -1, ctx.cwd);
	if (tokenLimit > 0 && usage.tokens >= tokenLimit) return `${usage.tokens.toLocaleString()} tokens >= ${Math.floor(tokenLimit).toLocaleString()} token limit`;
	const percentLimit = settingNumber("compaction.thresholdPercent", -1, ctx.cwd);
	if (percentLimit > 0 && usage.contextWindow) {
		const percent = (usage.tokens / usage.contextWindow) * 100;
		if (percent >= percentLimit) return `${percent.toFixed(1)}% context >= ${percentLimit}% limit`;
	}
	const idleLimit = settingNumber("compaction.idleThresholdTokens", DEFAULT_IDLE_COMPACTION_THRESHOLD_TOKENS, ctx.cwd);
	if (usage.tokens >= idleLimit) return `${usage.tokens.toLocaleString()} tokens >= ${Math.floor(idleLimit).toLocaleString()} idle threshold`;
	return undefined;
}

export type BudgetGuardTrigger = BudgetTrigger;
export type TranscriptRiskState = TranscriptRiskResult;

/**
 * Budget guard fires on agent_end (no idle wait) when context usage crosses a
 * percent of the model window or an absolute token limit. Returns a stable key
 * per crossing so the caller can suppress repeated triggers while usage stays
 * above the threshold.
 */
export function budgetGuardTrigger(ctx: ExtensionContext): BudgetGuardTrigger | undefined {
	if (!settingBoolean("compaction.budgetGuardEnabled", true, ctx.cwd)) return undefined;
	const usage = contextUsage(ctx);
	if (!usage) return undefined;
	return computeBudgetTrigger({
		contextWindow: usage.contextWindow,
		enabled: true,
		percentLimit: settingNumber("compaction.budgetPercent", DEFAULT_BUDGET_GUARD_PERCENT, ctx.cwd),
		tokenLimit: settingNumber("compaction.budgetTokens", DEFAULT_BUDGET_GUARD_TOKENS, ctx.cwd),
		tokens: usage.tokens,
	});
}

/**
 * Transcript-risk: serialized request payload may be very large even if token
 * count alone has not reached the model window. Compared against the
 * compaction.transcriptRiskWarnChars setting.
 */
export function transcriptRiskState(ctx: ExtensionContext, messages: AgentMessage[]): TranscriptRiskState {
	const threshold = Math.floor(settingNumber("compaction.transcriptRiskWarnChars", DEFAULT_TRANSCRIPT_RISK_WARN_CHARS, ctx.cwd));
	if (!Array.isArray(messages) || messages.length === 0 || threshold <= 0) {
		return { chars: 0, exceeded: false, messageCount: 0, threshold };
	}
	let chars = 0;
	try {
		const text = serializeMessagesForSummary(messages);
		chars = text.length;
	} catch {
		chars = 0;
	}
	return evaluateTranscriptRisk({ chars, messageCount: messages.length, threshold });
}
