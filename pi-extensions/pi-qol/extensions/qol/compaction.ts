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
	QOL_COMPACTION_SYSTEM_PROMPT,
} from "./constants.js";
import {
	chunkConversationText as chunkConversationTextRaw,
	computeBudgetTrigger,
	isBudgetGuardCompaction,
	orchestrateChunkedSummary,
	type BudgetTrigger,
	type SummarizeOutcome,
	type SummarizeRequest,
	type TranscriptRiskResult,
} from "./budget-guard.js";
import {
	buildBudgetHandoff as buildBudgetHandoffData,
	writeBudgetHandoffArtifact as writeBudgetHandoffArtifactRaw,
	type HandoffWriteResult,
	type QolBudgetHandoff,
} from "./compaction-handoff.js";
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

export function budgetMaxInputChars(ctx: ExtensionContext): number {
	const raw = Math.floor(settingNumber("compaction.maxInputChars", DEFAULT_BUDGET_MAX_INPUT_CHARS, ctx.cwd));
	// 0 or negative disables chunking. Anything above the hard floor is honored.
	return raw <= 0 ? 0 : Math.max(20_000, raw);
}

export const chunkConversationText = chunkConversationTextRaw;
export type { QolBudgetHandoff } from "./compaction-handoff.js";

async function singleShotSummary(ctx: ExtensionContext, request: SummarizeRequest, options: { maxTokens: number; model?: string; purpose: QolSummaryPurpose; signal?: AbortSignal }): Promise<SummarizeOutcome> {
	const promptText = buildSummaryPrompt({
		conversationText: request.text,
		customInstructions: request.customInstructions,
		previousSummary: settingBoolean("compaction.includePreviousSummary", true, ctx.cwd) ? request.previousSummary : undefined,
		profile: compactionProfile(ctx.cwd),
		purpose: options.purpose,
	});

	const remoteEndpoint = settingString("compaction.remoteEndpoint", "", ctx.cwd);
	if (settingBoolean("compaction.remoteEnabled", false, ctx.cwd) && remoteEndpoint) {
		try {
			const summary = await summarizeWithRemote(remoteEndpoint, QOL_COMPACTION_SYSTEM_PROMPT, promptText, options.maxTokens, options.signal);
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
		{ apiKey: auth.apiKey, headers: auth.headers, maxTokens: options.maxTokens, signal: options.signal },
	);
	const summary = response.content
		.filter((content): content is { type: "text"; text: string } => content.type === "text")
		.map((content) => content.text)
		.join("\n")
		.trim();
	return { model: modelLabel(model), summary, via: "model" };
}

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
}): Promise<{ model: string; summary: string; via: "model" | "remote"; chunkCount?: number; reduceLevels?: number; requestCount?: number }> {
	const maxTokens = Math.max(256, Math.floor(options.maxTokens ?? settingNumber("compaction.maxTokens", DEFAULT_COMPACTION_MAX_TOKENS, ctx.cwd)));
	const maxInputChars = budgetMaxInputChars(ctx);
	const summarize = (request: SummarizeRequest) => singleShotSummary(ctx, request, {
		maxTokens,
		model: options.model,
		purpose: options.purpose,
		signal: options.signal,
	});
	if (options.skipChunking || maxInputChars <= 0 || options.conversationText.length <= maxInputChars) {
		return summarize({
			customInstructions: options.customInstructions,
			previousSummary: options.previousSummary,
			skipChunking: true,
			text: options.conversationText,
		});
	}
	const orchestrated = await orchestrateChunkedSummary({
		customInstructions: options.customInstructions,
		maxInputChars,
		notify: (message, level = "info") => compactionNotify(ctx, message, level),
		previousSummary: options.previousSummary,
		signal: options.signal,
		summarize,
		text: options.conversationText,
	});
	return orchestrated;
}

export function buildBudgetHandoff(ctx: ExtensionContext, options: {
	reason: string;
	preparation?: { messagesToSummarize?: AgentMessage[]; turnPrefixMessages?: AgentMessage[]; previousSummary?: string; tokensBefore?: number };
}): QolBudgetHandoff {
	return buildBudgetHandoffData({
		preparation: options.preparation,
		reason: options.reason,
		sessionManager: ctx.sessionManager as any,
	});
}

export function writeBudgetHandoffArtifact(ctx: ExtensionContext, handoff: QolBudgetHandoff): HandoffWriteResult {
	const enabled = settingBoolean("compaction.handoffArtifactEnabled", true, ctx.cwd);
	const result = writeBudgetHandoffArtifactRaw(handoff, { enabled });
	if (result.error) {
		compactionNotify(ctx, `QOL handoff artifact write failed: ${result.error}`, "warning");
	}
	return result;
}

export async function handleQolCompaction(event: any, ctx: ExtensionContext): Promise<any> {
	const isBudgetGuard = isBudgetGuardCompaction(event?.customInstructions);
	// Budget-guard-triggered compactions force the QOL bounded path so the
	// chunked summarizer + handoff artifact always run, even when the user
	// has not flipped compaction.customEnabled on.
	if (!isBudgetGuard && !settingBoolean("compaction.customEnabled", false, ctx.cwd)) return undefined;
	const preparation = event.preparation ?? {};
	const messages = [...(preparation.messagesToSummarize ?? []), ...(preparation.turnPrefixMessages ?? [])];
	if (messages.length === 0) return undefined;
	const tokensBefore = typeof preparation.tokensBefore === "number" ? preparation.tokensBefore : 0;
	const handoff = buildBudgetHandoff(ctx, { preparation, reason: event.customInstructions ?? "session_before_compact" });
	const handoffResult = writeBudgetHandoffArtifact(ctx, handoff);
	const sourceLabel = isBudgetGuard ? "pi-qol budget-guard" : "pi-qol";
	compactionNotify(ctx, `QOL compaction: summarizing ${messages.length} message(s), ${tokensBefore.toLocaleString()} token(s)${isBudgetGuard ? " (budget guard)" : ""}.`, "info");
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
		const chunkSuffix = result.chunkCount && result.chunkCount > 1 ? ` (${result.chunkCount} chunks, ${result.reduceLevels ?? 1} reduce level${(result.reduceLevels ?? 1) === 1 ? "" : "s"})` : "";
		compactionNotify(ctx, `QOL compaction complete via ${result.via}: ${result.model}${chunkSuffix}`, "info");
		return {
			compaction: {
				details: {
					chunkCount: result.chunkCount,
					handoffArtifact: handoffResult.path,
					handoffArtifactLatest: handoffResult.latestPath,
					handoffArtifactError: handoffResult.error,
					messageCount: messages.length,
					model: result.model,
					profile: compactionProfile(ctx.cwd),
					reduceLevels: result.reduceLevels,
					requestCount: result.requestCount,
					source: sourceLabel,
					trigger: isBudgetGuard ? "budget-guard" : "session_before_compact",
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
