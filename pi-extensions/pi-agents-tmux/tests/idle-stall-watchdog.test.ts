// vstack#63 workaround: polling watchdog detects subagent tasks that
// stall after pi-core auto-compaction (no agent_end ever fires) and
// writes a synthetic needs_completion outbox so the parent's existing
// wake path takes over.

import assert from "node:assert/strict";
import test from "node:test";
import {
	createIdleStallWatchdog,
	stallWatchdogEnabledFromEnv,
	stallWatchdogIntervalMsFromEnv,
	stallWatchdogThresholdMsFromEnv,
	STALL_WATCHDOG_DEFAULT_INTERVAL_SEC,
	STALL_WATCHDOG_DEFAULT_THRESHOLD_SEC,
	STALL_WATCHDOG_REASON,
	type IdleStallWatchdogDeps,
	type StallSyntheticOutboxPayload,
} from "../extensions/subagent/idle-stall-watchdog.js";
import type { PaneTaskRecord } from "../extensions/subagent/types.js";

interface HarnessOptions {
	awaitingRetry?: (rec: PaneTaskRecord) => boolean;
	enabled?: boolean;
	thresholdMs?: number;
	intervalMs?: number;
	nowEpochMs?: number;
	records?: PaneTaskRecord[];
	outboxExisting?: Set<string>;
	paneIdle?: (record: PaneTaskRecord) => boolean;
	writeFails?: (outboxFile: string) => Error | null;
}

interface Harness {
	deps: IdleStallWatchdogDeps;
	writes: Array<{ outboxFile: string; payload: StallSyntheticOutboxPayload }>;
	markFiredCalls: Array<{ taskId: string; payload: StallSyntheticOutboxPayload }>;
	warnings: string[];
	outboxExisting: Set<string>;
	scheduled: Array<{ ms: number; handler: () => void; handle: number }>;
}

function record(overrides: Partial<PaneTaskRecord>): PaneTaskRecord {
	return {
		taskId: "task-1",
		agent: "planner",
		task: "Plan.",
		status: "running",
		createdAt: "2026-05-15T12:00:00.000Z",
		updatedAt: "2026-05-15T12:00:00.000Z",
		...overrides,
	};
}

function outboxPathFor(rec: PaneTaskRecord): string {
	return rec.outboxFile ?? `/tmp/${rec.agent}/${rec.taskId}.json`;
}

function makeHarness(opts: HarnessOptions = {}): Harness {
	const writes: Harness["writes"] = [];
	const markFiredCalls: Harness["markFiredCalls"] = [];
	const warnings: string[] = [];
	const outboxExisting = opts.outboxExisting ?? new Set<string>();
	const scheduled: Harness["scheduled"] = [];
	let nextHandle = 1;
	const records = opts.records ?? [];
	const deps: IdleStallWatchdogDeps = {
		intervalMs: opts.intervalMs ?? 60_000,
		thresholdMs: opts.thresholdMs ?? 300_000,
		isEnabled: () => opts.enabled ?? true,
		now: () => opts.nowEpochMs ?? Date.now(),
		listActiveTasks: async () => records,
		isAwaitingRateLimitRetry: (rec) => (opts.awaitingRetry ? opts.awaitingRetry(rec) : false),
		outboxExists: async (file) => outboxExisting.has(file),
		outboxPathFor,
		isPaneIdle: async (rec) => (opts.paneIdle ? opts.paneIdle(rec) : true),
		lastActivityAt: (rec) => {
			const raw = rec.updatedAt ?? rec.completedAt ?? rec.createdAt;
			if (!raw) return 0;
			const ts = Date.parse(raw);
			return Number.isFinite(ts) ? ts : 0;
		},
		writeSyntheticOutbox: async (file, payload) => {
			const err = opts.writeFails?.(file);
			if (err) throw err;
			outboxExisting.add(file);
			writes.push({ outboxFile: file, payload });
		},
		markFired: async (rec, payload) => {
			markFiredCalls.push({ taskId: rec.taskId, payload });
		},
		logWarn: (msg) => warnings.push(msg),
		setInterval: (handler, ms) => {
			const handle = nextHandle++;
			scheduled.push({ ms, handler, handle });
			return handle;
		},
		clearInterval: (handle) => {
			const idx = scheduled.findIndex((entry) => entry.handle === handle);
			if (idx >= 0) scheduled.splice(idx, 1);
		},
	};
	return { deps, writes, markFiredCalls, warnings, outboxExisting, scheduled };
}

test("task idle past threshold with no outbox -> writes synthetic outbox", async () => {
	const now = Date.parse("2026-05-15T12:10:00.000Z"); // 600s after last activity
	const harness = makeHarness({
		nowEpochMs: now,
		thresholdMs: 300_000,
		records: [record({ updatedAt: "2026-05-15T12:00:00.000Z" })],
	});
	const watchdog = createIdleStallWatchdog(harness.deps);
	const outcomes = await watchdog.checkAll();
	assert.equal(outcomes.length, 1);
	assert.equal(outcomes[0]?.fired, true);
	assert.equal(harness.writes.length, 1);
	const payload = harness.writes[0]?.payload!;
	assert.equal(payload.status, "needs_completion");
	assert.equal(payload.reason, STALL_WATCHDOG_REASON);
	assert.equal(payload.synthetic, true);
	assert.match(payload.summary, /idle with no progress .*cause undetermined/);
	assert.equal(harness.markFiredCalls.length, 1);
});

test("a pane is not condemned while awaiting a rate-limit retry (skipped: rate-limited)", async () => {
	const now = Date.parse("2026-05-15T12:10:00.000Z");
	const harness = makeHarness({
		awaitingRetry: (rec) => rec.agent === "planner",
		nowEpochMs: now,
		records: [record({ updatedAt: "2026-05-15T12:00:00.000Z" })],
	});
	const watchdog = createIdleStallWatchdog(harness.deps);
	const outcomes = await watchdog.checkAll();
	assert.equal(outcomes[0]?.fired, false);
	assert.equal(outcomes[0]?.skipped, "rate-limited");
	assert.equal(harness.writes.length, 0);
	// The gate clears once the retry state does — the same pane is judged
	// normally on the next tick.
	const after = makeHarness({ nowEpochMs: now, records: [record({ updatedAt: "2026-05-15T12:00:00.000Z" })] });
	const second = createIdleStallWatchdog(after.deps);
	const later = await second.checkAll();
	assert.equal(later[0]?.fired, true);
});

test("task with existing outbox -> no synthetic write (skipped: outbox-present)", async () => {
	const now = Date.parse("2026-05-15T12:10:00.000Z");
	const harness = makeHarness({
		nowEpochMs: now,
		records: [record({ updatedAt: "2026-05-15T12:00:00.000Z" })],
		outboxExisting: new Set([outboxPathFor(record({}))]),
	});
	const watchdog = createIdleStallWatchdog(harness.deps);
	const outcomes = await watchdog.checkAll();
	assert.equal(outcomes[0]?.fired, false);
	assert.equal(outcomes[0]?.skipped, "outbox-present");
	assert.equal(harness.writes.length, 0);
});

test("task pane busy (not idle) -> no synthetic write", async () => {
	const now = Date.parse("2026-05-15T12:10:00.000Z");
	const harness = makeHarness({
		nowEpochMs: now,
		records: [record({ updatedAt: "2026-05-15T12:00:00.000Z" })],
		paneIdle: () => false,
	});
	const watchdog = createIdleStallWatchdog(harness.deps);
	const outcomes = await watchdog.checkAll();
	assert.equal(outcomes[0]?.skipped, "pane-busy");
	assert.equal(harness.writes.length, 0);
});

test("task not yet stale (within threshold) -> no synthetic write", async () => {
	const now = Date.parse("2026-05-15T12:02:00.000Z"); // 120s after last activity
	const harness = makeHarness({
		nowEpochMs: now,
		thresholdMs: 300_000,
		records: [record({ updatedAt: "2026-05-15T12:00:00.000Z" })],
	});
	const watchdog = createIdleStallWatchdog(harness.deps);
	const outcomes = await watchdog.checkAll();
	assert.equal(outcomes[0]?.skipped, "not-stale");
	assert.equal(harness.writes.length, 0);
});

test("watchdog disabled via env flag -> no checkAll, no writes", async () => {
	const harness = makeHarness({
		enabled: false,
		records: [record({ updatedAt: "2026-01-01T00:00:00.000Z" })],
	});
	const watchdog = createIdleStallWatchdog(harness.deps);
	const outcomes = await watchdog.checkAll();
	assert.equal(outcomes.length, 1);
	assert.equal(outcomes[0]?.skipped, "disabled");
	assert.equal(harness.writes.length, 0);
});

test("terminal status (completed) is skipped", async () => {
	const now = Date.parse("2026-05-15T13:00:00.000Z");
	const harness = makeHarness({
		nowEpochMs: now,
		records: [record({ status: "completed", updatedAt: "2026-05-15T12:00:00.000Z" })],
	});
	const watchdog = createIdleStallWatchdog(harness.deps);
	const outcomes = await watchdog.checkAll();
	assert.equal(outcomes[0]?.skipped, "task-terminal");
});

test("status already needs_completion is skipped", async () => {
	const now = Date.parse("2026-05-15T13:00:00.000Z");
	const harness = makeHarness({
		nowEpochMs: now,
		records: [record({ status: "needs_completion", updatedAt: "2026-05-15T12:00:00.000Z" })],
	});
	const watchdog = createIdleStallWatchdog(harness.deps);
	const outcomes = await watchdog.checkAll();
	assert.equal(outcomes[0]?.skipped, "task-needs-completion");
});

test("successive checks for same task fire only once", async () => {
	const now = Date.parse("2026-05-15T13:00:00.000Z");
	const harness = makeHarness({
		nowEpochMs: now,
		records: [record({ updatedAt: "2026-05-15T12:00:00.000Z" })],
	});
	const watchdog = createIdleStallWatchdog(harness.deps);
	await watchdog.checkAll();
	const second = await watchdog.checkAll();
	assert.equal(second[0]?.fired, false);
	assert.equal(second[0]?.skipped, "already-fired");
	assert.equal(harness.writes.length, 1, "exactly one synthetic outbox over two ticks");
});

test("write EEXIST is treated as race-lost (no error log)", async () => {
	const now = Date.parse("2026-05-15T13:00:00.000Z");
	const harness = makeHarness({
		nowEpochMs: now,
		records: [record({ updatedAt: "2026-05-15T12:00:00.000Z" })],
		writeFails: () => {
			const err: NodeJS.ErrnoException = new Error("EEXIST race-loss");
			err.code = "EEXIST";
			return err;
		},
	});
	const watchdog = createIdleStallWatchdog(harness.deps);
	const outcomes = await watchdog.checkAll();
	assert.equal(outcomes[0]?.fired, false);
	assert.equal(outcomes[0]?.skipped, "race-lost");
	assert.equal(harness.warnings.length, 0, "EEXIST is healthy race-loss; no warn-log");
});

test("write ENOSPC (non-EEXIST) logs warning and records error", async () => {
	const now = Date.parse("2026-05-15T13:00:00.000Z");
	const harness = makeHarness({
		nowEpochMs: now,
		records: [record({ updatedAt: "2026-05-15T12:00:00.000Z" })],
		writeFails: () => {
			const err: NodeJS.ErrnoException = new Error("disk full");
			err.code = "ENOSPC";
			return err;
		},
	});
	const watchdog = createIdleStallWatchdog(harness.deps);
	const outcomes = await watchdog.checkAll();
	assert.equal(outcomes[0]?.fired, false);
	assert.ok(outcomes[0]?.error);
	assert.ok(
		harness.warnings.some((w) => w.includes("writeSyntheticOutbox failed") && w.includes("disk full")),
		`expected disk-full warn, got: ${JSON.stringify(harness.warnings)}`,
	);
});

test("start() schedules a poll on the injected setInterval", () => {
	const harness = makeHarness({ intervalMs: 60_000 });
	const watchdog = createIdleStallWatchdog(harness.deps);
	watchdog.start();
	assert.equal(harness.scheduled.length, 1);
	assert.equal(harness.scheduled[0]?.ms, 60_000);
	assert.equal(watchdog.isRunning(), true);
	watchdog.stop();
	assert.equal(harness.scheduled.length, 0);
	assert.equal(watchdog.isRunning(), false);
});

test("start() is a no-op when watchdog is disabled", () => {
	const harness = makeHarness({ enabled: false });
	const watchdog = createIdleStallWatchdog(harness.deps);
	watchdog.start();
	assert.equal(harness.scheduled.length, 0);
	assert.equal(watchdog.isRunning(), false);
});

test("env parsers honor defaults and overrides", () => {
	assert.equal(stallWatchdogEnabledFromEnv({} as NodeJS.ProcessEnv), true);
	assert.equal(stallWatchdogEnabledFromEnv({ VSTACK_STALL_WATCHDOG: "0" } as any), false);
	assert.equal(stallWatchdogEnabledFromEnv({ VSTACK_STALL_WATCHDOG: "false" } as any), false);
	assert.equal(stallWatchdogIntervalMsFromEnv({} as NodeJS.ProcessEnv), STALL_WATCHDOG_DEFAULT_INTERVAL_SEC * 1000);
	assert.equal(stallWatchdogIntervalMsFromEnv({ VSTACK_STALL_WATCHDOG_INTERVAL_SEC: "10" } as any), 10_000);
	assert.equal(stallWatchdogThresholdMsFromEnv({} as NodeJS.ProcessEnv), STALL_WATCHDOG_DEFAULT_THRESHOLD_SEC * 1000);
	assert.equal(stallWatchdogThresholdMsFromEnv({ VSTACK_STALL_WATCHDOG_THRESHOLD_SEC: "30" } as any), 30_000);
});
