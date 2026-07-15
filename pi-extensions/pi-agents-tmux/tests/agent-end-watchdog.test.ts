import assert from "node:assert/strict";
import { mkdtempSync, existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
	buildSyntheticOutbox,
	createAgentEndWatchdog,
	defaultOutboxExists,
	defaultWriteSyntheticOutbox,
	watchdogEnabledFromEnv,
	watchdogGraceMsFromEnv,
	WATCHDOG_DEFAULT_GRACE_SEC,
	WATCHDOG_REASON,
	type AgentEndWatchdogDeps,
	type SyntheticOutboxPayload,
} from "../extensions/subagent/agent-end-watchdog.js";
import type { PaneTaskRecord } from "../extensions/subagent/types.js";

interface ManualScheduler {
	scheduleAfter: AgentEndWatchdogDeps["scheduleAfter"];
	advance: () => Promise<void>;
	pending: () => number;
}

function manualScheduler(): ManualScheduler {
	const queue: Array<{ fn: () => void; cancelled: boolean }> = [];
	return {
		scheduleAfter(_delayMs, fn) {
			const entry = { fn, cancelled: false };
			queue.push(entry);
			return {
				cancel: () => {
					entry.cancelled = true;
				},
			};
		},
		async advance() {
			const snapshot = queue.splice(0, queue.length);
			for (const entry of snapshot) {
				if (entry.cancelled) continue;
				entry.fn();
			}
			// Yield once so scheduled microtasks (the runCheck promise chain
			// fired inside the timer callback) finish before the test asserts.
			await new Promise((resolve) => setTimeout(resolve, 0));
			await new Promise((resolve) => setTimeout(resolve, 0));
		},
		pending() {
			return queue.filter((entry) => !entry.cancelled).length;
		},
	};
}

interface BuildOpts {
	enabled?: boolean;
	graceMs?: number;
	status?: PaneTaskRecord["status"];
	outboxAlreadyExists?: boolean;
	paneIdle?: boolean;
	scheduler?: ManualScheduler;
	taskId?: string;
}

interface TestHarness {
	deps: AgentEndWatchdogDeps;
	watchdog: ReturnType<typeof createAgentEndWatchdog>;
	scheduler: ManualScheduler;
	writes: SyntheticOutboxPayload[];
	markFiredCalls: Array<{ taskId: string; payload: SyntheticOutboxPayload }>;
	warnings: string[];
	idleProbe: { calls: number; next: boolean };
	outboxFile: string;
	runtimeRoot: string;
	agentName: string;
	taskId: string;
}

function tempRuntime(): string {
	return mkdtempSync(join(tmpdir(), "pi-agents-watchdog-"));
}

function buildHarness(opts: BuildOpts = {}): TestHarness {
	const runtimeRoot = tempRuntime();
	const agentName = "planner";
	const taskId = opts.taskId ?? "task-watchdog-1";
	const outboxFile = join(runtimeRoot, "outbox", agentName, `${taskId}.json`);
	const scheduler = opts.scheduler ?? manualScheduler();
	const writes: SyntheticOutboxPayload[] = [];
	const markFiredCalls: Array<{ taskId: string; payload: SyntheticOutboxPayload }> = [];
	const warnings: string[] = [];
	const status: PaneTaskRecord["status"] = opts.status ?? "running";
	const idleProbe = { calls: 0, next: opts.paneIdle ?? true };
	let outboxOnDisk = Boolean(opts.outboxAlreadyExists);
	const deps: AgentEndWatchdogDeps = {
		graceMs: opts.graceMs ?? 10_000,
		now: () => Date.now(),
		scheduleAfter: scheduler.scheduleAfter,
		isEnabled: () => opts.enabled ?? true,
		outboxPathFor: () => outboxFile,
		readTaskRecord: async () => ({
			taskId,
			agent: agentName,
			task: "Plan.",
			status,
			outboxFile,
			createdAt: "2026-05-15T00:00:00.000Z",
		}),
		outboxExists: async () => outboxOnDisk || existsSync(outboxFile),
		isPaneIdle: async () => {
			idleProbe.calls += 1;
			return idleProbe.next;
		},
		writeSyntheticOutbox: async (file, payload) => {
			mkdirSync(join(runtimeRoot, "outbox", agentName), { recursive: true });
			writeFileSync(file, `${JSON.stringify(payload, null, "\t")}\n`);
			outboxOnDisk = true;
			writes.push(payload);
		},
		markFired: async (_root, _agent, id, payload) => {
			markFiredCalls.push({ taskId: id, payload });
		},
		logWarn: (msg) => {
			warnings.push(msg);
		},
	};
	const watchdog = createAgentEndWatchdog(deps);
	return { deps, watchdog, scheduler, writes, markFiredCalls, warnings, idleProbe, outboxFile, runtimeRoot, agentName, taskId };
}

test("agent_end without complete_subagent writes synthetic needs_completion outbox after grace", async () => {
	const harness = buildHarness({ graceMs: 50 });
	const outcome = harness.watchdog.onAgentEnd({ runtimeRoot: harness.runtimeRoot, agentName: harness.agentName, taskId: harness.taskId });
	assert.equal(outcome.scheduled, true);
	assert.equal(harness.watchdog.hasPending(harness.taskId), true);
	await harness.scheduler.advance();
	assert.equal(harness.watchdog.hasFired(harness.taskId), true);
	assert.equal(harness.writes.length, 1, "exactly one synthetic outbox written");
	const payload = harness.writes[0];
	assert.equal(payload.status, "needs_completion");
	assert.equal(payload.reason, WATCHDOG_REASON);
	assert.equal(payload.synthetic, true);
	assert.match(payload.summary, /Agent fully settled/);
	assert.ok(existsSync(harness.outboxFile), "outbox file present on disk");
	const onDisk = JSON.parse(readFileSync(harness.outboxFile, "utf-8"));
	assert.equal(onDisk.reason, WATCHDOG_REASON);
	assert.equal(harness.markFiredCalls.length, 1);
});

test("VSTACK_AGENT_END_WATCHDOG=0 disables the watchdog entirely", async () => {
	const harness = buildHarness({ enabled: false, graceMs: 50 });
	const outcome = harness.watchdog.onAgentEnd({ runtimeRoot: harness.runtimeRoot, agentName: harness.agentName, taskId: harness.taskId });
	assert.equal(outcome.scheduled, false);
	if (outcome.scheduled === false) assert.equal(outcome.reason, "disabled");
	assert.equal(harness.scheduler.pending(), 0, "no grace timer scheduled");
	await harness.scheduler.advance();
	assert.equal(harness.writes.length, 0, "no synthetic outbox written");
	assert.equal(harness.watchdog.hasFired(harness.taskId), false);
});

test("race: complete_subagent writes outbox before grace expires -> watchdog skips", async () => {
	const harness = buildHarness({ graceMs: 50 });
	const outcome = harness.watchdog.onAgentEnd({ runtimeRoot: harness.runtimeRoot, agentName: harness.agentName, taskId: harness.taskId });
	assert.equal(outcome.scheduled, true);
	// Real complete_subagent writes a non-synthetic outbox during the grace window.
	mkdirSync(join(harness.runtimeRoot, "outbox", harness.agentName), { recursive: true });
	writeFileSync(
		harness.outboxFile,
		JSON.stringify({ agent: harness.agentName, taskId: harness.taskId, status: "completed", summary: "real completion", filesChanged: [], validation: [] }),
	);
	await harness.scheduler.advance();
	assert.equal(harness.writes.length, 0, "watchdog did not overwrite real outbox");
	assert.equal(harness.watchdog.hasFired(harness.taskId), false);
	const onDisk = JSON.parse(readFileSync(harness.outboxFile, "utf-8"));
	assert.equal(onDisk.summary, "real completion", "real outbox preserved");
});

test("multi-turn: pane is busy when grace expires -> watchdog does NOT fire", async () => {
	const harness = buildHarness({ graceMs: 50, paneIdle: false });
	const outcome = harness.watchdog.onAgentEnd({ runtimeRoot: harness.runtimeRoot, agentName: harness.agentName, taskId: harness.taskId });
	assert.equal(outcome.scheduled, true);
	await harness.scheduler.advance();
	assert.equal(harness.writes.length, 0, "no outbox written while pane busy");
	assert.equal(harness.watchdog.hasFired(harness.taskId), false);
	assert.ok(harness.idleProbe.calls >= 1, "isPaneIdle was probed");
});

test("successive agent_end events for same task fire only once", async () => {
	const harness = buildHarness({ graceMs: 50 });
	const first = harness.watchdog.onAgentEnd({ runtimeRoot: harness.runtimeRoot, agentName: harness.agentName, taskId: harness.taskId });
	const second = harness.watchdog.onAgentEnd({ runtimeRoot: harness.runtimeRoot, agentName: harness.agentName, taskId: harness.taskId });
	assert.equal(first.scheduled, true);
	assert.equal(second.scheduled, false);
	if (second.scheduled === false) assert.equal(second.reason, "already-scheduled");
	await harness.scheduler.advance();
	assert.equal(harness.writes.length, 1, "first scheduled run fired exactly once");
	const third = harness.watchdog.onAgentEnd({ runtimeRoot: harness.runtimeRoot, agentName: harness.agentName, taskId: harness.taskId });
	assert.equal(third.scheduled, false);
	if (third.scheduled === false) assert.equal(third.reason, "already-fired");
	await harness.scheduler.advance();
	assert.equal(harness.writes.length, 1, "subsequent agent_end did not duplicate outbox");
});

test("task record already terminal -> watchdog skips and writes nothing", async () => {
	const harness = buildHarness({ graceMs: 50, status: "completed" });
	harness.watchdog.onAgentEnd({ runtimeRoot: harness.runtimeRoot, agentName: harness.agentName, taskId: harness.taskId });
	await harness.scheduler.advance();
	assert.equal(harness.writes.length, 0, "no synthetic outbox for terminal task");
	assert.equal(harness.watchdog.hasFired(harness.taskId), false);
});

test("defaultWriteSyntheticOutbox refuses to overwrite existing outbox (O_EXCL race-safety)", async () => {
	const runtimeRoot = tempRuntime();
	const outboxFile = join(runtimeRoot, "outbox", "planner", "task-excl.json");
	mkdirSync(join(runtimeRoot, "outbox", "planner"), { recursive: true });
	writeFileSync(outboxFile, JSON.stringify({ summary: "real" }));
	const payload = buildSyntheticOutbox("planner", "task-excl");
	await assert.rejects(() => defaultWriteSyntheticOutbox(outboxFile, payload), /outbox already exists/);
	const onDisk = JSON.parse(readFileSync(outboxFile, "utf-8"));
	assert.equal(onDisk.summary, "real", "existing outbox untouched");
});

test("defaultWriteSyntheticOutbox writes payload when path is free", async () => {
	const runtimeRoot = tempRuntime();
	const outboxFile = join(runtimeRoot, "outbox", "planner", "task-new.json");
	const payload = buildSyntheticOutbox("planner", "task-new");
	await defaultWriteSyntheticOutbox(outboxFile, payload);
	assert.equal(await defaultOutboxExists(outboxFile), true);
	const onDisk = JSON.parse(readFileSync(outboxFile, "utf-8"));
	assert.equal(onDisk.reason, WATCHDOG_REASON);
	assert.equal(onDisk.synthetic, true);
});

test("writeSyntheticOutbox EEXIST race -> skipped:outbox-present, no warn-log", async () => {
	const harness = buildHarness({ graceMs: 50 });
	// Stub the writer to mimic a real complete_subagent winning the race:
	// fs.open(path, 'wx') threw EEXIST after the existence check raced.
	harness.deps.writeSyntheticOutbox = async () => {
		const err: NodeJS.ErrnoException = new Error("outbox already exists");
		err.code = "EEXIST";
		throw err;
	};
	harness.watchdog.onAgentEnd({ runtimeRoot: harness.runtimeRoot, agentName: harness.agentName, taskId: harness.taskId });
	await harness.scheduler.advance();
	assert.equal(harness.watchdog.hasFired(harness.taskId), false, "fired stays false on EEXIST race-loss");
	assert.equal(harness.writes.length, 0);
	assert.equal(harness.warnings.length, 0, "EEXIST is healthy race-loss; no warn-log");
});

test("writeSyntheticOutbox non-EEXIST error -> warn-log retained", async () => {
	const harness = buildHarness({ graceMs: 50 });
	harness.deps.writeSyntheticOutbox = async () => {
		const err: NodeJS.ErrnoException = new Error("disk full");
		err.code = "ENOSPC";
		throw err;
	};
	harness.watchdog.onAgentEnd({ runtimeRoot: harness.runtimeRoot, agentName: harness.agentName, taskId: harness.taskId });
	await harness.scheduler.advance();
	assert.equal(harness.watchdog.hasFired(harness.taskId), false);
	assert.ok(
		harness.warnings.some((w) => w.includes("writeSyntheticOutbox failed") && w.includes("disk full")),
		`expected disk-full warn-log, got: ${JSON.stringify(harness.warnings)}`,
	);
});

test("defaultWriteSyntheticOutbox throws ErrnoException with code=EEXIST on race", async () => {
	const runtimeRoot = tempRuntime();
	const outboxFile = join(runtimeRoot, "outbox", "planner", "task-race.json");
	mkdirSync(join(runtimeRoot, "outbox", "planner"), { recursive: true });
	writeFileSync(outboxFile, JSON.stringify({ summary: "real" }));
	const payload = buildSyntheticOutbox("planner", "task-race");
	try {
		await defaultWriteSyntheticOutbox(outboxFile, payload);
		assert.fail("defaultWriteSyntheticOutbox should have thrown");
	} catch (err) {
		assert.equal((err as NodeJS.ErrnoException).code, "EEXIST", "rethrow must preserve code=EEXIST");
	}
});

test("watchdogEnabledFromEnv parses VSTACK_AGENT_END_WATCHDOG truthy/falsy values", () => {
	assert.equal(watchdogEnabledFromEnv({} as NodeJS.ProcessEnv), true);
	assert.equal(watchdogEnabledFromEnv({ VSTACK_AGENT_END_WATCHDOG: "" } as any), true);
	assert.equal(watchdogEnabledFromEnv({ VSTACK_AGENT_END_WATCHDOG: "1" } as any), true);
	assert.equal(watchdogEnabledFromEnv({ VSTACK_AGENT_END_WATCHDOG: "0" } as any), false);
	assert.equal(watchdogEnabledFromEnv({ VSTACK_AGENT_END_WATCHDOG: "false" } as any), false);
	assert.equal(watchdogEnabledFromEnv({ VSTACK_AGENT_END_WATCHDOG: "off" } as any), false);
});

test("watchdogGraceMsFromEnv uses default 10s and parses overrides", () => {
	assert.equal(watchdogGraceMsFromEnv({} as NodeJS.ProcessEnv), WATCHDOG_DEFAULT_GRACE_SEC * 1000);
	assert.equal(watchdogGraceMsFromEnv({ VSTACK_AGENT_END_WATCHDOG_GRACE_SEC: "3" } as any), 3000);
	assert.equal(watchdogGraceMsFromEnv({ VSTACK_AGENT_END_WATCHDOG_GRACE_SEC: "" } as any), WATCHDOG_DEFAULT_GRACE_SEC * 1000);
	assert.equal(watchdogGraceMsFromEnv({ VSTACK_AGENT_END_WATCHDOG_GRACE_SEC: "garbage" } as any), WATCHDOG_DEFAULT_GRACE_SEC * 1000);
});
