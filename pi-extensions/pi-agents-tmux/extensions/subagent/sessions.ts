import * as fs from "node:fs";
import * as path from "node:path";
import { safeFileName } from "./names.js";
import { randomHex } from "./random.js";
import { settingNumber, settingString } from "./settings.js";
import type { AttemptSummary, SingleResult } from "./types.js";

export const ONESHOT_SESSION_PREFIX = "oneshot-";
export const DEFAULT_REUSED_SESSION_BUDGET_THRESHOLD = 0.8;
export const DEFAULT_MODEL_CONTEXT_LIMIT_TOKENS = 200_000;

type ReusedSessionBudgetPolicy = "compact-then-resume" | "refuse-and-warn" | "warn";

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
	compacted?: boolean;
	compactionPath?: string;
	estimate: SessionBudgetEstimate;
	ok: boolean;
	policy: ReusedSessionBudgetPolicy;
	warning?: string;
}

export interface SessionCompactionRequest {
	agentName: string;
	estimate: SessionBudgetEstimate;
	model?: string;
	sessionPath: string;
}

export interface SessionCompactionResult {
	archivePath?: string;
}

type SessionCompactor = (request: SessionCompactionRequest) => Promise<SessionCompactionResult>;

const defaultSessionCompactor: SessionCompactor = async (request) => {
	let archivePath: string | undefined;
	try {
		const dir = path.dirname(request.sessionPath);
		archivePath = path.join(dir, `${path.basename(request.sessionPath)}.precompact-${Date.now()}`);
		await fs.promises.copyFile(request.sessionPath, archivePath);
		await fs.promises.truncate(request.sessionPath, 0);
	} catch (error) {
		throw new Error(`Failed to compact reused session ${request.sessionPath}: ${error instanceof Error ? error.message : String(error)}`);
	}
	return { archivePath };
};

let sessionCompactor: SessionCompactor = defaultSessionCompactor;

export function setSessionCompactorForTests(compactor?: SessionCompactor): void {
	sessionCompactor = compactor ?? defaultSessionCompactor;
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
	const value = settingString("reusedSessionBudgetPolicy", "refuse-and-warn", cwd);
	if (value === "warn" || value === "compact-then-resume") return value;
	return "refuse-and-warn";
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
	if (policy === "compact-then-resume") {
		let compacted: SessionCompactionResult;
		try {
			compacted = await sessionCompactor({ agentName, estimate, model, sessionPath });
		} catch (error) {
			return {
				estimate,
				ok: false,
				policy,
				warning: `Compaction failed for ${base} ${error instanceof Error ? error.message : String(error)}`,
			};
		}
		return {
			compacted: true,
			compactionPath: compacted.archivePath,
			estimate,
			ok: true,
			policy,
			warning: `Compacted ${base}${compacted.archivePath ? ` Archived previous session at ${compacted.archivePath}.` : ""}`,
		};
	}
	const warning = policy === "warn" ? `Warning for ${base}` : `Refusing ${base}`;
	return { estimate, ok: policy === "warn", policy, warning };
}

export function isContextLengthExceededEnvelope(value: unknown): boolean {
	if (!value || typeof value !== "object") return false;
	const candidate = value as Record<string, unknown>;
	const error = candidate.error && typeof candidate.error === "object" ? candidate.error as Record<string, unknown> : undefined;
	return error?.code === "context_length_exceeded"
		|| error?.type === "context_length_exceeded"
		|| candidate.code === "context_length_exceeded"
		|| candidate.type === "context_length_exceeded";
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
		result.errorEnvelope,
		result.errorMessage,
		result.stopReason,
		messageText(result),
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
