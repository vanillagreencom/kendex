import * as fs from "node:fs";
import * as path from "node:path";
import { safeFileName } from "./names.js";
import { randomHex } from "./random.js";
import { settingNumber, settingString } from "./settings.js";
import { readLastAssistantTextFromTranscript } from "./format.js";
import type { AttemptSummary, SingleResult } from "./types.js";

export const ONESHOT_SESSION_PREFIX = "oneshot-";
export const DEFAULT_REUSED_SESSION_BUDGET_THRESHOLD = 0.8;
export const DEFAULT_MODEL_CONTEXT_LIMIT_TOKENS = 272_000;

const CONTEXT_OVERFLOW_PATTERNS = [
	/context[_-]length[_-]exceeded/i,
	/"code"\s*:\s*"context_length_exceeded"/i,
	/"type"\s*:\s*"context_length_exceeded"/i,
	/exceeds the context window/i,
	/exceeds (?:the )?(?:model'?s )?maximum context length(?: of [\d,]+ tokens?|\s*\([\d,]+\))/i,
] as const;

export interface BgSessionSelection {
	ephemeral: boolean;
	explicit: boolean;
	key: string;
	path: string;
	mode: "fresh" | "resumed";
}

export interface SessionBudgetEstimate {
	bytes: number;
	contextLimitTokens: number;
	exists: boolean;
	path: string;
	ratio: number;
	threshold: number;
	tokens: number;
}

export interface SessionBudgetGuard {
	estimate: SessionBudgetEstimate;
	ok: boolean;
	warning?: string;
	/** Warn callers that still send the former setting during migration. */
	migrationWarning?: string;
}

/** Carry the new task and the prior final result, not the prior conversation. */
export async function prepareContextHandoff(task: string, estimate: SessionBudgetEstimate): Promise<{ task: string; notice: string }> {
	const priorResult = await readLastAssistantTextFromTranscript(estimate.path);
	return {
		task: `${task}\n\nPrior agent final result (${estimate.path}):\n${priorResult ?? "No prior final result available."}`,
		notice: `reused as fresh (context ${Math.round(estimate.ratio * 100)}%)`,
	};
}

export function createOneShotSessionKey(): string {
	return `${ONESHOT_SESSION_PREFIX}${Date.now().toString(36)}-${randomHex(4)}`;
}

export function bgSessionPath(runtimeRoot: string, agentName: string, sessionKey: string): string {
	return path.join(runtimeRoot, "sessions", `bg-${safeFileName(agentName)}-${safeFileName(sessionKey)}.jsonl`);
}

export function resolveBgSession(runtimeRoot: string, agentName: string, sessionKey?: string): BgSessionSelection {
	const trimmed = sessionKey?.trim();
	const explicit = Boolean(trimmed && !trimmed.startsWith(ONESHOT_SESSION_PREFIX));
	const key = trimmed || createOneShotSessionKey();
	return {
		ephemeral: !explicit,
		explicit,
		key,
		path: bgSessionPath(runtimeRoot, agentName, key),
		mode: explicit ? "resumed" : "fresh",
	};
}

export function normalizeBudgetThreshold(value: number): number {
	if (!Number.isFinite(value) || value <= 0) return DEFAULT_REUSED_SESSION_BUDGET_THRESHOLD;
	const normalized = value > 1 ? value / 100 : value;
	return Math.min(1, Math.max(0.01, normalized));
}

export function reusedSessionBudgetThreshold(cwd?: string): number {
	return normalizeBudgetThreshold(settingNumber("reusedSessionBudgetThreshold", DEFAULT_REUSED_SESSION_BUDGET_THRESHOLD, cwd));
}

export function modelContextLimitTokens(model: string | undefined, cwd?: string): number {
	const configured = Math.floor(settingNumber("reusedSessionContextLimitTokens", DEFAULT_MODEL_CONTEXT_LIMIT_TOKENS, cwd));
	if (Number.isFinite(configured) && configured > 0) return configured;
	void model;
	return DEFAULT_MODEL_CONTEXT_LIMIT_TOKENS;
}

export function estimateTokensFromBytes(bytes: number): number {
	return Math.ceil(Math.max(0, bytes) / 4);
}

export async function estimateSessionBudget(sessionPath: string, model: string | undefined, cwd?: string): Promise<SessionBudgetEstimate> {
	let bytes = 0;
	let exists = false;
	try {
		const stat = await fs.promises.stat(sessionPath);
		bytes = stat.isFile() ? stat.size : 0;
		exists = stat.isFile();
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
	}
	const contextLimitTokens = modelContextLimitTokens(model, cwd);
	const tokens = estimateTokensFromBytes(bytes);
	const threshold = reusedSessionBudgetThreshold(cwd);
	return {
		bytes,
		contextLimitTokens,
		exists,
		path: sessionPath,
		ratio: contextLimitTokens > 0 ? tokens / contextLimitTokens : 0,
		threshold,
		tokens,
	};
}

/** Judge reuse once; callers refuse an exact-session request or hand off. */
export async function guardReusedSessionBudget(sessionPath: string, agentName: string, model: string | undefined, cwd?: string): Promise<SessionBudgetGuard> {
	const estimate = await estimateSessionBudget(sessionPath, model, cwd);
	const legacyPolicy = settingString("reusedSessionBudgetPolicy", "", cwd);
	const migrationWarning = legacyPolicy ? `reusedSessionBudgetPolicy=${legacyPolicy} is retired. Remove it; ordinary reuse hands off above the threshold, and sameSession requires refusal.` : undefined;
	if (!estimate.exists || estimate.ratio <= estimate.threshold) return { estimate, ok: true, ...(migrationWarning ? { migrationWarning } : {}) };
	const pct = Math.round(estimate.ratio * 100);
	const thresholdPct = Math.round(estimate.threshold * 100);
	const warning = `Refusing reused session for ${agentName}: estimated context ${estimate.tokens}/${estimate.contextLimitTokens} tokens (${pct}%) exceeds ${thresholdPct}% guard threshold. Start a fresh agent without sessionKey or sameSession.`;
	return { estimate, ok: false, warning, ...(migrationWarning ? { migrationWarning } : {}) };
}

function contextLengthExceededField(value: unknown): boolean {
	return typeof value === "string" && isContextLengthExceededText(value);
}

export function isContextLengthExceededEnvelope(value: unknown): boolean {
	if (!value || typeof value !== "object") return false;
	const candidate = value as Record<string, unknown>;
	const errorValue = candidate.error;
	const error = errorValue && typeof errorValue === "object" ? errorValue as Record<string, unknown> : undefined;
	const message = candidate.message && typeof candidate.message === "object" ? candidate.message as Record<string, unknown> : undefined;
	return error?.code === "context_length_exceeded"
		|| error?.type === "context_length_exceeded"
		|| candidate.code === "context_length_exceeded"
		|| candidate.type === "context_length_exceeded"
		|| contextLengthExceededField(errorValue)
		|| contextLengthExceededField(candidate.errorMessage)
		|| contextLengthExceededField(candidate.stopReason)
		|| contextLengthExceededField(message?.errorMessage)
		|| contextLengthExceededField(message?.stopReason);
}

export function isContextLengthExceededText(text: string | undefined): boolean {
	if (!text) return false;
	return CONTEXT_OVERFLOW_PATTERNS.some((pattern) => pattern.test(text));
}

export function resultHasContextLengthExceeded(result: SingleResult): boolean {
	return isContextLengthExceededText([
		result.stderr,
		result.errorEnvelope,
		result.errorMessage,
		result.stopReason,
	].filter(Boolean).join("\n"));
}

export function summarizeAttempt(result: SingleResult): AttemptSummary {
	return {
		attempt: result.attempt ?? 1,
		errorEnvelope: result.errorEnvelope,
		errorMessage: result.errorMessage,
		exitCode: result.exitCode,
		sessionKey: result.sessionKey,
		sessionPath: result.sessionPath,
		stderr: result.stderr,
		stopReason: result.stopReason,
		taskId: result.taskId,
		transcriptPath: result.transcriptPath,
	};
}
