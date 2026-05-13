import * as fs from "node:fs";
import * as path from "node:path";
import { safeFileName } from "./names.js";
import { settingNumber, settingString } from "./settings.js";
import type { AttemptSummary, SingleResult } from "./types.js";

export const ONESHOT_SESSION_PREFIX = "oneshot-";
export const DEFAULT_REUSED_SESSION_BUDGET_THRESHOLD = 0.8;
export const DEFAULT_MODEL_CONTEXT_LIMIT_TOKENS = 200_000;

type ReusedSessionBudgetPolicy = "refuse" | "warn";

export interface BgSessionSelection {
	ephemeral: boolean;
	explicit: boolean;
	key: string;
	path: string;
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
	policy: ReusedSessionBudgetPolicy;
	warning?: string;
}

export function createOneShotSessionKey(): string {
	return `${ONESHOT_SESSION_PREFIX}${Date.now().toString(36)}-${Math.random().toString(16).slice(2, 10)}`;
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

export function reusedSessionBudgetPolicy(cwd?: string): ReusedSessionBudgetPolicy {
	return settingString("reusedSessionBudgetPolicy", "refuse", cwd) === "warn" ? "warn" : "refuse";
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
	} catch {
		// Missing session files are empty reused lanes.
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

export async function guardReusedSessionBudget(sessionPath: string, agentName: string, model: string | undefined, cwd?: string): Promise<SessionBudgetGuard> {
	const estimate = await estimateSessionBudget(sessionPath, model, cwd);
	const policy = reusedSessionBudgetPolicy(cwd);
	if (!estimate.exists || estimate.ratio <= estimate.threshold) return { estimate, ok: true, policy };
	const pct = Math.round(estimate.ratio * 100);
	const thresholdPct = Math.round(estimate.threshold * 100);
	const base = `reused session for ${agentName}: estimated context ${estimate.tokens}/${estimate.contextLimitTokens} tokens (${pct}%) exceeds ${thresholdPct}% guard threshold. Use a fresh call without sessionKey, a smaller task, or raise reusedSessionBudgetThreshold/reusedSessionContextLimitTokens if intentional.`;
	const warning = policy === "warn" ? `Warning for ${base}` : `Refusing ${base}`;
	return { estimate, ok: policy === "warn", policy, warning };
}

export function isContextLengthExceededText(text: string | undefined): boolean {
	if (!text) return false;
	return /context[_-]length[_-]exceeded/i.test(text)
		|| /"code"\s*:\s*"context_length_exceeded"/i.test(text)
		|| /"type"\s*:\s*"context_length_exceeded"/i.test(text);
}

function messageText(result: SingleResult): string {
	const parts: string[] = [];
	for (const message of result.messages ?? []) {
		for (const part of message.content ?? []) {
			if (part.type === "text") parts.push(part.text);
		}
	}
	return parts.join("\n");
}

export function resultHasContextLengthExceeded(result: SingleResult): boolean {
	return isContextLengthExceededText([
		result.stderr,
		result.errorMessage,
		result.stopReason,
		messageText(result),
	].filter(Boolean).join("\n"));
}

export function summarizeAttempt(result: SingleResult): AttemptSummary {
	return {
		attempt: result.attempt ?? 1,
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
