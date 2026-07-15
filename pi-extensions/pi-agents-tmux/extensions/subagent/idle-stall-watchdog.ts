// vstack#63 workaround: polling watchdog for subagent tasks that stall
// after pi-core auto-compaction.
//
// The settled-run watchdog in agent-end-watchdog.ts requires Pi to emit a
// terminal lifecycle event. Upstream issue #63 is that after auto-compaction
// the child Pi can sit idle indefinitely without reaching `agent_settled`, so
// that watchdog never runs. This polling watchdog
// fills that gap: every N seconds it walks the task registry and
// checks each active task for the combination of (a) bridge reports
// isIdle, (b) time-since-last-activity exceeds the staleness
// threshold, (c) no outbox JSON exists. When all three hold it writes
// a synthetic needs_completion outbox via the same O_EXCL writer the
// W5 watchdog uses; a racing real complete_subagent always wins.
//
// Configuration via env vars (read by the index.ts wiring):
//   VSTACK_STALL_WATCHDOG=0                disables the watchdog entirely.
//   VSTACK_STALL_WATCHDOG_INTERVAL_SEC     poll cadence (default 60s).
//   VSTACK_STALL_WATCHDOG_THRESHOLD_SEC    staleness gate (default 300s).

import type { PaneTaskRecord, PaneTaskStatus } from "./types.js";
import type { SyntheticOutboxPayload } from "./agent-end-watchdog.js";

export const STALL_WATCHDOG_REASON = "stalled-idle-no-progress" as const;
export const STALL_WATCHDOG_DEFAULT_INTERVAL_SEC = 60;
export const STALL_WATCHDOG_DEFAULT_THRESHOLD_SEC = 300;

export type StallSyntheticOutboxPayload = Omit<SyntheticOutboxPayload, "reason" | "summary" | "notes"> & {
	reason: typeof STALL_WATCHDOG_REASON;
	summary: string;
	notes?: string;
};

export function buildStallSyntheticOutbox(
	agentName: string,
	taskId: string,
	staleSec: number,
): StallSyntheticOutboxPayload {
	return {
		agent: agentName,
		taskId,
		status: "needs_completion",
		summary: `Agent has been idle with no progress for ${staleSec}s (post-compaction stall). Task may have hung after auto-compaction without reaching agent_settled.`,
		filesChanged: [],
		validation: [],
		reason: STALL_WATCHDOG_REASON,
		synthetic: true,
		notes:
			"Synthesized by idle-stall watchdog (vstack#63 workaround). Treat as needs_completion; the child agent may have stalled after auto-compaction.",
	};
}

export interface IdleStallWatchdogDeps {
	intervalMs: number;
	thresholdMs: number;
	isEnabled: () => boolean;
	now: () => number;
	listActiveTasks: () => Promise<PaneTaskRecord[]>;
	outboxExists: (outboxFile: string) => Promise<boolean>;
	outboxPathFor: (record: PaneTaskRecord) => string;
	isPaneIdle: (record: PaneTaskRecord) => Promise<boolean>;
	lastActivityAt: (record: PaneTaskRecord) => number;
	writeSyntheticOutbox: (outboxFile: string, payload: StallSyntheticOutboxPayload) => Promise<void>;
	markFired: (record: PaneTaskRecord, payload: StallSyntheticOutboxPayload) => Promise<void>;
	logWarn: (msg: string) => void;
	setInterval?: (handler: () => void, ms: number) => unknown;
	clearInterval?: (handle: unknown) => void;
}

export type StallCheckSkip =
	| "disabled"
	| "task-terminal"
	| "task-needs-completion"
	| "outbox-present"
	| "pane-busy"
	| "not-stale"
	| "already-fired"
	| "missing-task-id"
	| "race-lost";

export interface StallCheckOutcome {
	taskId: string;
	fired: boolean;
	skipped?: StallCheckSkip;
	error?: string;
}

export interface IdleStallWatchdog {
	checkAll(): Promise<StallCheckOutcome[]>;
	checkOne(record: PaneTaskRecord): Promise<StallCheckOutcome>;
	start(): void;
	stop(): void;
	isRunning(): boolean;
	hasFired(taskId: string): boolean;
}

const TERMINAL_STATUSES = new Set<PaneTaskStatus>([
	"completed",
	"failed",
	"blocked",
]);

function isTerminalTaskStatus(status: PaneTaskStatus | undefined): boolean {
	if (!status) return false;
	return TERMINAL_STATUSES.has(status);
}

export function createIdleStallWatchdog(deps: IdleStallWatchdogDeps): IdleStallWatchdog {
	const fired = new Set<string>();
	let timer: unknown;
	const scheduler = deps.setInterval ?? setInterval;
	const cancel = deps.clearInterval ?? clearInterval;

	async function checkOne(record: PaneTaskRecord): Promise<StallCheckOutcome> {
		const taskId = record?.taskId ?? "";
		if (!taskId) return { taskId: "", fired: false, skipped: "missing-task-id" };
		if (fired.has(taskId)) return { taskId, fired: false, skipped: "already-fired" };
		if (isTerminalTaskStatus(record.status)) return { taskId, fired: false, skipped: "task-terminal" };
		if (record.status === "needs_completion") return { taskId, fired: false, skipped: "task-needs-completion" };
		try {
			const outboxFile = deps.outboxPathFor(record);
			if (await deps.outboxExists(outboxFile)) return { taskId, fired: false, skipped: "outbox-present" };
			const lastActivity = deps.lastActivityAt(record);
			const staleMs = Math.max(0, deps.now() - lastActivity);
			if (staleMs < deps.thresholdMs) return { taskId, fired: false, skipped: "not-stale" };
			const idle = await deps.isPaneIdle(record);
			if (!idle) return { taskId, fired: false, skipped: "pane-busy" };
			if (fired.has(taskId)) return { taskId, fired: false, skipped: "already-fired" };
			const payload = buildStallSyntheticOutbox(record.agent, taskId, Math.floor(staleMs / 1000));
			try {
				await deps.writeSyntheticOutbox(outboxFile, payload);
			} catch (err) {
				const code = (err as NodeJS.ErrnoException)?.code;
				if (code === "EEXIST") return { taskId, fired: false, skipped: "race-lost" };
				const message = (err as Error)?.message ?? String(err);
				deps.logWarn(`idle-stall watchdog: writeSyntheticOutbox failed for ${record.agent}/${taskId}: ${message}`);
				return { taskId, fired: false, error: message };
			}
			fired.add(taskId);
			try {
				await deps.markFired(record, payload);
			} catch (err) {
				deps.logWarn(`idle-stall watchdog: markFired failed for ${record.agent}/${taskId}: ${(err as Error)?.message ?? err}`);
			}
			return { taskId, fired: true };
		} catch (err) {
			const message = (err as Error)?.message ?? String(err);
			deps.logWarn(`idle-stall watchdog: unexpected error for ${record.agent}/${taskId}: ${message}`);
			return { taskId, fired: false, error: message };
		}
	}

	async function checkAll(): Promise<StallCheckOutcome[]> {
		if (!deps.isEnabled()) return [{ taskId: "", fired: false, skipped: "disabled" }];
		let records: PaneTaskRecord[];
		try {
			records = await deps.listActiveTasks();
		} catch (err) {
			deps.logWarn(`idle-stall watchdog: listActiveTasks threw: ${(err as Error)?.message ?? err}`);
			return [];
		}
		const outcomes: StallCheckOutcome[] = [];
		for (const record of records) outcomes.push(await checkOne(record));
		return outcomes;
	}

	return {
		checkOne,
		checkAll,
		start() {
			if (timer !== undefined) return;
			if (!deps.isEnabled()) return;
			timer = scheduler(() => {
				checkAll().catch((err) => {
					deps.logWarn(`idle-stall watchdog: tick threw: ${(err as Error)?.message ?? err}`);
				});
			}, Math.max(0, deps.intervalMs));
		},
		stop() {
			if (timer === undefined) return;
			cancel(timer);
			timer = undefined;
		},
		isRunning() {
			return timer !== undefined;
		},
		hasFired(taskId: string) {
			return fired.has(taskId);
		},
	};
}

export function stallWatchdogEnabledFromEnv(env: NodeJS.ProcessEnv = process.env): boolean {
	const raw = env.VSTACK_STALL_WATCHDOG?.trim();
	if (raw === undefined || raw === "") return true;
	return raw !== "0" && raw.toLowerCase() !== "false" && raw.toLowerCase() !== "off";
}

export function stallWatchdogIntervalMsFromEnv(env: NodeJS.ProcessEnv = process.env): number {
	const raw = env.VSTACK_STALL_WATCHDOG_INTERVAL_SEC?.trim();
	const parsed = raw ? Number(raw) : Number.NaN;
	const seconds = Number.isFinite(parsed) && parsed >= 0 ? parsed : STALL_WATCHDOG_DEFAULT_INTERVAL_SEC;
	return Math.floor(seconds * 1000);
}

export function stallWatchdogThresholdMsFromEnv(env: NodeJS.ProcessEnv = process.env): number {
	const raw = env.VSTACK_STALL_WATCHDOG_THRESHOLD_SEC?.trim();
	const parsed = raw ? Number(raw) : Number.NaN;
	const seconds = Number.isFinite(parsed) && parsed >= 0 ? parsed : STALL_WATCHDOG_DEFAULT_THRESHOLD_SEC;
	return Math.floor(seconds * 1000);
}
