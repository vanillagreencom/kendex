/**
 * Settled-run missing-completion watchdog (vstack#66).
 *
 * Detects the silent-abandonment case where a subagent's turn ends — pane goes
 * idle, transcript settles — but no complete_subagent outbox JSON was written.
 * The parent's existing wake/poll mechanism only notices via completion files,
 * so without this watchdog the parent waits indefinitely while the child sits
 * idle. Pi 0.80.4 added `agent_settled`, which fires only after retry,
 * compaction retry, and queued continuations are exhausted. The child invokes
 * this watchdog from that safe lifecycle point, waits a grace period, and then
 * — if no outbox JSON has appeared and the child pane is confirmed idle —
 * synthesizes a needs_completion outbox so the existing wake handler kicks in.
 *
 * Configuration via env vars:
 *   VSTACK_AGENT_END_WATCHDOG=0          disables the watchdog entirely.
 *   VSTACK_AGENT_END_WATCHDOG_GRACE_SEC  grace before firing (default 10s).
 */

import * as fs from "node:fs";
import * as path from "node:path";
import { atomicWriteFile } from "./file-lock.js";
import type { PaneCompletion, PaneTaskRecord, PaneTaskStatus } from "./types.js";

export const WATCHDOG_REASON = "turn-ended-without-complete-subagent" as const;
export const WATCHDOG_DEFAULT_GRACE_SEC = 10;

export interface SyntheticOutboxPayload extends PaneCompletion {
	agent: string;
	taskId: string;
	status: "needs_completion";
	summary: string;
	filesChanged: string[];
	validation: string[];
	reason: typeof WATCHDOG_REASON;
	synthetic: true;
}

export interface AgentEndWatchdogDeps {
	graceMs: number;
	now: () => number;
	scheduleAfter: (delayMs: number, fn: () => void) => { cancel: () => void };
	isEnabled: () => boolean;
	outboxPathFor: (runtimeRoot: string, agentName: string, taskId: string) => string;
	readTaskRecord: (runtimeRoot: string, taskId: string) => Promise<PaneTaskRecord | undefined>;
	outboxExists: (outboxFile: string) => Promise<boolean>;
	isPaneIdle: (runtimeRoot: string, agentName: string) => Promise<boolean>;
	writeSyntheticOutbox: (outboxFile: string, payload: SyntheticOutboxPayload) => Promise<void>;
	markFired: (runtimeRoot: string, agentName: string, taskId: string, payload: SyntheticOutboxPayload) => Promise<void>;
	logWarn: (message: string) => void;
}

export interface OnAgentEndArgs {
	runtimeRoot: string;
	agentName: string;
	taskId: string;
}

export type OnAgentEndOutcome =
	| { scheduled: true }
	| { scheduled: false; reason: "disabled" | "already-fired" | "already-scheduled" | "missing-task-id" };

export interface OnAgentEndCheckResult {
	fired: boolean;
	skipped?: "outbox-present" | "task-terminal" | "pane-busy" | "no-record" | "already-fired";
	error?: string;
}

export interface AgentEndWatchdog {
	onAgentEnd(args: OnAgentEndArgs): OnAgentEndOutcome;
	/**
	 * Test helper: run the grace check synchronously for the given task. Returns
	 * the outcome so tests can assert without depending on real timers.
	 */
	checkNow(args: OnAgentEndArgs): Promise<OnAgentEndCheckResult>;
	hasFired(taskId: string): boolean;
	hasPending(taskId: string): boolean;
	cancel(taskId: string): boolean;
}

const ACTIVE_TASK_STATUSES = new Set<PaneTaskStatus>(["queued", "running", "unknown"]);

function isActiveStatus(status: PaneTaskStatus | undefined): boolean {
	if (!status) return true;
	return ACTIVE_TASK_STATUSES.has(status);
}

export function buildSyntheticOutbox(agentName: string, taskId: string): SyntheticOutboxPayload {
	return {
		agent: agentName,
		taskId,
		status: "needs_completion",
		summary:
			"Agent fully settled without calling complete_subagent. Pane is idle but task was not closed.",
		filesChanged: [],
		validation: [],
		reason: WATCHDOG_REASON,
		synthetic: true,
		notes: "Synthesized by settled-run watchdog (vstack#66). Treat as needs_completion; the child agent did not write a real outbox.",
	};
}

export function createAgentEndWatchdog(deps: AgentEndWatchdogDeps): AgentEndWatchdog {
	const fired = new Set<string>();
	const pending = new Map<string, { cancel: () => void }>();

	async function runCheck(args: OnAgentEndArgs): Promise<OnAgentEndCheckResult> {
		const { runtimeRoot, agentName, taskId } = args;
		if (fired.has(taskId)) return { fired: false, skipped: "already-fired" };
		try {
			const record = await deps.readTaskRecord(runtimeRoot, taskId);
			if (!record) return { fired: false, skipped: "no-record" };
			if (!isActiveStatus(record.status)) return { fired: false, skipped: "task-terminal" };
			const outboxFile = record.outboxFile ?? deps.outboxPathFor(runtimeRoot, agentName, taskId);
			if (await deps.outboxExists(outboxFile)) return { fired: false, skipped: "outbox-present" };
			const idle = await deps.isPaneIdle(runtimeRoot, agentName);
			if (!idle) return { fired: false, skipped: "pane-busy" };
			if (fired.has(taskId)) return { fired: false, skipped: "already-fired" };
			const payload = buildSyntheticOutbox(agentName, taskId);
			try {
				await deps.writeSyntheticOutbox(outboxFile, payload);
			} catch (err) {
				// EEXIST means a real complete_subagent (or a peer watchdog) raced
				// us and won — that is the entire point of the O_EXCL writer, so
				// treat it as healthy outbox-present and stay quiet. Only log
				// when something genuinely went wrong (permission denied, disk
				// full, etc.).
				const code = (err as NodeJS.ErrnoException)?.code;
				if (code === "EEXIST") return { fired: false, skipped: "outbox-present" };
				const message = (err as Error)?.message ?? String(err);
				deps.logWarn(`settled-run watchdog: writeSyntheticOutbox failed for ${agentName}/${taskId}: ${message}`);
				return { fired: false, error: message };
			}
			fired.add(taskId);
			try {
				await deps.markFired(runtimeRoot, agentName, taskId, payload);
			} catch (err) {
				deps.logWarn(`settled-run watchdog: markFired failed for ${agentName}/${taskId}: ${(err as Error)?.message ?? err}`);
			}
			return { fired: true };
		} catch (err) {
			const message = (err as Error)?.message ?? String(err);
			deps.logWarn(`settled-run watchdog: unexpected error for ${agentName}/${taskId}: ${message}`);
			return { fired: false, error: message };
		}
	}

	return {
		onAgentEnd(args) {
			if (!args.taskId) return { scheduled: false, reason: "missing-task-id" };
			if (!deps.isEnabled()) return { scheduled: false, reason: "disabled" };
			if (fired.has(args.taskId)) return { scheduled: false, reason: "already-fired" };
			if (pending.has(args.taskId)) return { scheduled: false, reason: "already-scheduled" };
			const handle = deps.scheduleAfter(Math.max(0, deps.graceMs), () => {
				pending.delete(args.taskId);
				runCheck(args).catch((err) => {
					deps.logWarn(`settled-run watchdog: runCheck threw for ${args.agentName}/${args.taskId}: ${(err as Error)?.message ?? err}`);
				});
			});
			pending.set(args.taskId, handle);
			return { scheduled: true };
		},
		async checkNow(args) {
			const handle = pending.get(args.taskId);
			if (handle) {
				handle.cancel();
				pending.delete(args.taskId);
			}
			return runCheck(args);
		},
		hasFired(taskId) {
			return fired.has(taskId);
		},
		hasPending(taskId) {
			return pending.has(taskId);
		},
		cancel(taskId) {
			const handle = pending.get(taskId);
			if (!handle) return false;
			handle.cancel();
			pending.delete(taskId);
			return true;
		},
	};
}

export function watchdogEnabledFromEnv(env: NodeJS.ProcessEnv = process.env): boolean {
	const raw = env.VSTACK_AGENT_END_WATCHDOG?.trim();
	if (raw === undefined || raw === "") return true;
	return raw !== "0" && raw.toLowerCase() !== "false" && raw.toLowerCase() !== "off";
}

export function watchdogGraceMsFromEnv(env: NodeJS.ProcessEnv = process.env): number {
	const raw = env.VSTACK_AGENT_END_WATCHDOG_GRACE_SEC?.trim();
	const parsed = raw ? Number(raw) : Number.NaN;
	const seconds = Number.isFinite(parsed) && parsed >= 0 ? parsed : WATCHDOG_DEFAULT_GRACE_SEC;
	return Math.floor(seconds * 1000);
}

export async function defaultWriteSyntheticOutbox(outboxFile: string, payload: SyntheticOutboxPayload): Promise<void> {
	// Atomic create-if-missing so a real complete_subagent racing the watchdog
	// always wins. O_EXCL guarantees we never overwrite an existing outbox; the
	// final rename in atomicWriteFile is the linearization point for readers.
	await fs.promises.mkdir(path.dirname(outboxFile), { recursive: true, mode: 0o700 });
	try {
		const handle = await fs.promises.open(outboxFile, "wx", 0o600);
		await handle.writeFile(`${JSON.stringify(payload, null, "\t")}\n`, { encoding: "utf-8" });
		await handle.close();
		return;
	} catch (err) {
		const code = (err as NodeJS.ErrnoException)?.code;
		if (code === "EEXIST") {
			// Preserve the ErrnoException shape so runCheck can detect the race
			// via err.code and treat it as healthy outbox-present (no warn-log).
			const raceErr: NodeJS.ErrnoException = new Error(
				`outbox already exists at ${outboxFile}; refusing to overwrite`,
			);
			raceErr.code = "EEXIST";
			throw raceErr;
		}
		throw err;
	}
}

export async function defaultOutboxExists(outboxFile: string): Promise<boolean> {
	try {
		await fs.promises.access(outboxFile, fs.constants.F_OK);
		return true;
	} catch {
		return false;
	}
}

/**
 * Build a watchdog wired against real fs + the existing task registry, using
 * the package's atomicWriteFile when an O_EXCL create is not strictly required
 * (the wx open above is the actual race-safe path).
 */
export function defaultScheduleAfter(delayMs: number, fn: () => void): { cancel: () => void } {
	const handle = setTimeout(fn, delayMs);
	return {
		cancel: () => {
			clearTimeout(handle);
		},
	};
}

export async function _atomicWriteSyntheticOutboxFallback(outboxFile: string, payload: SyntheticOutboxPayload): Promise<void> {
	// Exposed for tests that need a non-O_EXCL write. Production code should use
	// defaultWriteSyntheticOutbox so a racing complete_subagent always wins.
	await atomicWriteFile(outboxFile, `${JSON.stringify(payload, null, "\t")}\n`);
}
