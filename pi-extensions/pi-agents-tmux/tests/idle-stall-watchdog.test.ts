// The idle-stall watchdog as scripts over an injected clock and registry:
// each row is a world (the records the registry lists, whether the pane is
// idle, what the outbox and the writer do) and a script of ticks, read back
// after every tick as one line. The poll timer and the three env parsers are
// tables of their own.

import assert from "node:assert/strict";
import test from "node:test";
import {
	createIdleStallWatchdog,
	type IdleStallWatchdogDeps,
	STALL_WATCHDOG_DEFAULT_INTERVAL_SEC,
	STALL_WATCHDOG_DEFAULT_THRESHOLD_SEC,
	STALL_WATCHDOG_REASON,
	type StallCheckOutcome,
	type StallSyntheticOutboxPayload,
	stallWatchdogEnabledFromEnv,
	stallWatchdogIntervalMsFromEnv,
	stallWatchdogThresholdMsFromEnv,
} from "../extensions/subagent/idle-stall-watchdog.js";
import type { PaneTaskRecord, PaneTaskStatus } from "../extensions/subagent/types.js";

const LAST_ACTIVITY = Date.parse("2026-05-15T12:00:00.000Z");
const THRESHOLD_MS = 300_000;
const STALE_NOW = LAST_ACTIVITY + 600_000;

type Failure = { code?: string; message: string };
type Rec = { taskId?: string; status?: PaneTaskStatus; agent?: string; activityAt?: number };
interface WorldOpts {
	enabled?: boolean;
	now?: number;
	threshold?: number;
	records?: Rec[] | "throws";
	awaitingRetry?: boolean;
	outboxPresent?: boolean;
	outboxThrows?: boolean;
	paneIdle?: boolean;
	writeFails?: Failure;
	markFails?: Failure;
}
interface World {
	watchdog: ReturnType<typeof createIdleStallWatchdog>;
	opts: WorldOpts;
	probes: { outbox: number; idle: number };
	writes: Array<{ file: string; payload: StallSyntheticOutboxPayload }>;
	marked: string[];
	warnings: string[];
	intervals: Array<{ ms: number; handler: () => void; handle: number }>;
	seen: { writes: number; marked: number; warnings: number; probes: { outbox: number; idle: number } };
}

function failing(failure: Failure): () => Promise<never> {
	return async () => {
		const err: NodeJS.ErrnoException = new Error(failure.message);
		if (failure.code) err.code = failure.code;
		throw err;
	};
}

function record(rec: Rec): PaneTaskRecord {
	const activity = new Date(rec.activityAt ?? LAST_ACTIVITY).toISOString();
	return { agent: rec.agent ?? "planner", createdAt: activity, status: rec.status ?? "running", task: "Plan.", taskId: rec.taskId ?? "task-1", updatedAt: activity };
}

function world(opts: WorldOpts): World {
	const w: World = {
		watchdog: undefined as never,
		opts,
		probes: { outbox: 0, idle: 0 },
		writes: [],
		marked: [],
		warnings: [],
		intervals: [],
		seen: { writes: 0, marked: 0, warnings: 0, probes: { outbox: 0, idle: 0 } },
	};
	let nextHandle = 1;
	const deps: IdleStallWatchdogDeps = {
		intervalMs: 60_000,
		thresholdMs: opts.threshold ?? THRESHOLD_MS,
		isEnabled: () => w.opts.enabled ?? true,
		now: () => w.opts.now ?? STALE_NOW,
		listActiveTasks: async () => {
			if (w.opts.records === "throws") throw new Error("registry unreadable");
			return (w.opts.records ?? [{}]).map(record);
		},
		isAwaitingRateLimitRetry: () => w.opts.awaitingRetry ?? false,
		outboxPathFor: (rec) => `/outbox/${rec.agent}/${rec.taskId}.json`,
		outboxExists: async (file) => {
			w.probes.outbox += 1;
			if (w.opts.outboxThrows) throw new Error("outbox unreadable");
			void file;
			return w.opts.outboxPresent ?? false;
		},
		isPaneIdle: async () => {
			w.probes.idle += 1;
			return w.opts.paneIdle ?? true;
		},
		lastActivityAt: (rec) => Date.parse(rec.updatedAt ?? ""),
		writeSyntheticOutbox: opts.writeFails
			? failing(opts.writeFails)
			: async (file, payload) => {
					w.writes.push({ file, payload });
				},
		markFired: opts.markFails
			? failing(opts.markFails)
			: async (rec, payload) => {
					w.marked.push(payload === w.writes.at(-1)?.payload ? rec.taskId : `${rec.taskId}!payload-mismatch`);
				},
		logWarn: (msg) => void w.warnings.push(msg),
		setInterval: (handler, ms) => {
			const handle = nextHandle++;
			w.intervals.push({ handle, handler, ms });
			return handle;
		},
		clearInterval: (handle) => {
			w.intervals = w.intervals.filter((entry) => entry.handle !== handle);
		},
	};
	w.watchdog = createIdleStallWatchdog(deps);
	return w;
}

// A warning by the failure it names, the pair it names and the message it
// carries; any other line printed whole.
function warnTag(line: string): string {
	for (const [needle, tag] of [["writeSyntheticOutbox failed", "write-failed"], ["markFired failed", "mark-failed"], ["unexpected error", "unexpected"], ["listActiveTasks threw", "list-failed"]] as const) {
		if (!line.includes(needle)) continue;
		const rest = line.slice(line.indexOf(needle) + needle.length);
		const m = /^(?: for (\S+))?: ([\s\S]*)$/.exec(rest);
		return m ? `${tag}(${m[1] ?? "-"}, ${JSON.stringify(m[2])})` : JSON.stringify(line);
	}
	return JSON.stringify(line);
}

// The payload by its status, reason, refs and synthetic mark, the one datum
// it carries about the stall (the seconds in its summary), the fields it
// carries at all, and the file it was written to.
function payloadTag(w: { file: string; payload: StallSyntheticOutboxPayload }): string {
	const p = w.payload;
	const stale = /for (\d+)s/.exec(p.summary)?.[1] ?? JSON.stringify(p.summary);
	const fields = Object.keys(p).sort().join("+");
	return `${p.status}/${p.reason}@${p.agent}/${p.taskId}${p.synthetic === true ? "/synthetic" : "/NOT-SYNTHETIC"} stale=${stale}s ${fields} -> ${w.file}`;
}
function outcomeTag(o: StallCheckOutcome): string {
	if (o.fired) return `${o.taskId}:fired`;
	if (o.error !== undefined) return `${o.taskId}:error(${JSON.stringify(o.error)})`;
	return `${o.taskId}:skip:${o.skipped}`;
}

// A tick is one checkAll; its line is the outcomes in registry order, then
// the probes, writes, marks and warnings the tick added.
type Step = (w: World) => Promise<string> | string;
const tick: Step = async (w) => (await w.watchdog.checkAll()).map(outcomeTag).join(" ") || "none";
const retryCleared: Step = (w) => {
	w.opts.awaitingRetry = false;
	return "retry-cleared";
};

async function runScript(w: World, steps: Step[]): Promise<string> {
	const lines: string[] = [];
	for (const step of steps) {
		const head = await step(w);
		const probes = `o${w.probes.outbox - w.seen.probes.outbox}i${w.probes.idle - w.seen.probes.idle}`;
		const wrote = w.writes.slice(w.seen.writes).map(payloadTag);
		const marks = w.marked.slice(w.seen.marked);
		const warned = w.warnings.slice(w.seen.warnings).map(warnTag);
		w.seen = { writes: w.writes.length, marked: w.marked.length, warnings: w.warnings.length, probes: { ...w.probes } };
		lines.push(`${head} probes=${probes} +writes=[${wrote.join(",")}] +marked=[${marks.join(",")}]${warned.length ? ` warn=[${warned.join(",")}]` : ""}`);
	}
	return lines.join("\n");
}

const FIELDS = "agent+filesChanged+notes+reason+status+summary+synthetic+taskId+validation";
const PAYLOAD = (agent: string, task: string, stale: number) => `needs_completion/${STALL_WATCHDOG_REASON}@${agent}/${task}/synthetic stale=${stale}s ${FIELDS} -> /outbox/${agent}/${task}.json`;
const FIRED = `task-1:fired probes=o1i1 +writes=[${PAYLOAD("planner", "task-1", 600)}] +marked=[task-1]`;
const QUIET = "+writes=[] +marked=[]";

// label | world | ticks | expect (one line per tick)
const rows: Array<[string, WorldOpts, Step[], string]> = [
	["an idle task past the threshold with no outbox fires", {}, [tick], FIRED],
	["exactly at the threshold is stale", { now: LAST_ACTIVITY + THRESHOLD_MS }, [tick], `task-1:fired probes=o1i1 +writes=[${PAYLOAD("planner", "task-1", 300)}] +marked=[task-1]`],
	["one millisecond under the threshold is not", { now: LAST_ACTIVITY + THRESHOLD_MS - 1 }, [tick], `task-1:skip:not-stale probes=o1i0 ${QUIET}`],
	["activity far in the future is not stale", { now: LAST_ACTIVITY - 600_000 }, [tick], `task-1:skip:not-stale probes=o1i0 ${QUIET}`],
	["a part second is not counted", { now: LAST_ACTIVITY + 600_999 }, [tick], FIRED],
	["at a zero threshold activity in the future counts as no stall and fires", { now: LAST_ACTIVITY - 600_000, threshold: 0 }, [tick], `task-1:fired probes=o1i1 +writes=[${PAYLOAD("planner", "task-1", 0)}] +marked=[task-1]`],
	["a pane awaiting a rate-limit retry is not condemned until the retry state clears", { awaitingRetry: true }, [tick, retryCleared, tick], [`task-1:skip:rate-limited probes=o0i0 ${QUIET}`, `retry-cleared probes=o0i0 ${QUIET}`, FIRED].join("\n")],
	["an outbox already present", { outboxPresent: true }, [tick], `task-1:skip:outbox-present probes=o1i0 ${QUIET}`],
	["a busy pane", { paneIdle: false }, [tick], `task-1:skip:pane-busy probes=o1i1 ${QUIET}`],
	["a disabled watchdog checks nothing", { enabled: false }, [tick], `:skip:disabled probes=o0i0 ${QUIET}`],
	["a completed task is terminal", { records: [{ status: "completed" }] }, [tick], `task-1:skip:task-terminal probes=o0i0 ${QUIET}`],
	["a failed task is terminal", { records: [{ status: "failed" }] }, [tick], `task-1:skip:task-terminal probes=o0i0 ${QUIET}`],
	["a blocked task is terminal", { records: [{ status: "blocked" }] }, [tick], `task-1:skip:task-terminal probes=o0i0 ${QUIET}`],
	["a task already needing completion", { records: [{ status: "needs_completion" }] }, [tick], `task-1:skip:task-needs-completion probes=o0i0 ${QUIET}`],
	["a queued task is judged", { records: [{ status: "queued" }] }, [tick], FIRED],
	["a task of unknown status is judged", { records: [{ status: "unknown" }] }, [tick], FIRED],
	["a record without a task id", { records: [{ taskId: "" }] }, [tick], `:skip:missing-task-id probes=o0i0 ${QUIET}`],
	["a fired task is not fired again on the next tick", {}, [tick, tick], [FIRED, `task-1:skip:already-fired probes=o0i0 ${QUIET}`].join("\n")],
	["every listed task is judged in order and on its own", { records: [{}, { activityAt: STALE_NOW, taskId: "task-2" }, { agent: "scout", taskId: "task-3" }] }, [tick], `task-1:fired task-2:skip:not-stale task-3:fired probes=o3i2 +writes=[${PAYLOAD("planner", "task-1", 600)},${PAYLOAD("scout", "task-3", 600)}] +marked=[task-1,task-3]`],
	["a writer losing the O_EXCL race is a quiet race-lost and the task may fire later", { writeFails: { code: "EEXIST", message: "outbox already exists" } }, [tick, tick], [`task-1:skip:race-lost probes=o1i1 ${QUIET}`, `task-1:skip:race-lost probes=o1i1 ${QUIET}`].join("\n")],
	["a writer failing otherwise is warned and the task stays unfired", { writeFails: { code: "ENOSPC", message: "disk full" } }, [tick], `task-1:error("disk full") probes=o1i1 ${QUIET} warn=[write-failed(planner/task-1, "disk full")]`],
	["a failing mark is warned after the write and the task counts as fired", { markFails: { message: "registry locked" } }, [tick, tick], [`task-1:fired probes=o1i1 +writes=[${PAYLOAD("planner", "task-1", 600)}] +marked=[] warn=[mark-failed(planner/task-1, "registry locked")]`, `task-1:skip:already-fired probes=o0i0 ${QUIET}`].join("\n")],
	["an unreadable registry is warned and the tick judges nothing", { records: "throws" }, [tick], `none probes=o0i0 ${QUIET} warn=[list-failed(-, "registry unreadable")]`],
	["a probe that throws is warned and the task stays unfired", { outboxThrows: true }, [tick], `task-1:error("outbox unreadable") probes=o1i0 ${QUIET} warn=[unexpected(planner/task-1, "outbox unreadable")]`],
];

test("the idle-stall watchdog", async () => {
	for (const [label, opts, steps, expect] of rows) assert.equal(await runScript(world(opts), steps), expect, label);
});

// The poll: start arms one interval at the configured cadence, its handler
// runs a tick, stop clears it; each step reads back the timer state and what
// the step wrote.
const start: Step = (w) => (w.watchdog.start(), "start");
const stop: Step = (w) => (w.watchdog.stop(), "stop");
const fireTimer: Step = async (w) => {
	for (const entry of w.intervals) entry.handler();
	await new Promise((resolve) => setTimeout(resolve, 0));
	await new Promise((resolve) => setTimeout(resolve, 0));
	return `fire(${w.intervals.map((e) => e.ms).join(",") || "none"})`;
};
async function runPoll(w: World, steps: Step[]): Promise<string> {
	const lines: string[] = [];
	for (const step of steps) {
		const head = await step(w);
		const wrote = w.writes.slice(w.seen.writes).length;
		w.seen.writes = w.writes.length;
		lines.push(`${head} running=${w.watchdog.isRunning()} intervals=[${w.intervals.map((e) => e.ms).join(",")}] +writes=${wrote}`);
	}
	return lines.join("\n");
}

// label | world | steps | expect
const pollRows: Array<[string, WorldOpts, Step[], string]> = [
	["start arms one interval whose handler ticks, and stop clears it", {}, [start, fireTimer, stop, fireTimer], ["start running=true intervals=[60000] +writes=0", "fire(60000) running=true intervals=[60000] +writes=1", "stop running=false intervals=[] +writes=0", "fire(none) running=false intervals=[] +writes=0"].join("\n")],
	["a second start does not arm a second interval, a second stop is idle", {}, [start, start, stop, stop], ["start running=true intervals=[60000] +writes=0", "start running=true intervals=[60000] +writes=0", "stop running=false intervals=[] +writes=0", "stop running=false intervals=[] +writes=0"].join("\n")],
	["a disabled watchdog does not start", { enabled: false }, [start], "start running=false intervals=[] +writes=0"],
];

test("the poll timer", async () => {
	for (const [label, opts, steps, expect] of pollRows) assert.equal(await runPoll(world(opts), steps), expect, label);
});

// label | KENDEX_STALL_WATCHDOG | expect
const enabledRows: Array<[string, string | undefined, boolean]> = [
	["unset is on", undefined, true],
	["empty is on", "", true],
	["1 is on", "1", true],
	["0 is off", "0", false],
	["false is off", "false", false],
	["OFF is off", "OFF", false],
	["a padded 0 is off", " 0 ", false],
];

test("KENDEX_STALL_WATCHDOG", () => {
	for (const [label, value, expect] of enabledRows) assert.equal(stallWatchdogEnabledFromEnv(value === undefined ? {} : { KENDEX_STALL_WATCHDOG: value }), expect, label);
});

// The interval and threshold parsers share one grammar and differ in their
// default; every row runs through both.
const parsers: Array<[string, (env: NodeJS.ProcessEnv) => number, string, number]> = [
	["interval", stallWatchdogIntervalMsFromEnv, "KENDEX_STALL_WATCHDOG_INTERVAL_SEC", STALL_WATCHDOG_DEFAULT_INTERVAL_SEC * 1000],
	["threshold", stallWatchdogThresholdMsFromEnv, "KENDEX_STALL_WATCHDOG_THRESHOLD_SEC", STALL_WATCHDOG_DEFAULT_THRESHOLD_SEC * 1000],
];

// label | value | expect (ms, or "default")
const secondsRows: Array<[string, string | undefined, number | "default"]> = [
	["unset is the default", undefined, "default"],
	["empty is the default", "", "default"],
	["seconds are milliseconds", "10", 10_000],
	["a fraction keeps whole milliseconds", "0.0015", 1],
	["zero is zero", "0", 0],
	["a negative is the default", "-1", "default"],
	["garbage is the default", "garbage", "default"],
	["Infinity is the default", "Infinity", "default"],
];

test("KENDEX_STALL_WATCHDOG_INTERVAL_SEC and _THRESHOLD_SEC", () => {
	for (const [name, parse, key, defaultMs] of parsers) {
		for (const [label, value, expect] of secondsRows) assert.equal(parse(value === undefined ? {} : { [key]: value }), expect === "default" ? defaultMs : expect, `${name}: ${label}`);
	}
	assert.notEqual(stallWatchdogIntervalMsFromEnv({}), stallWatchdogThresholdMsFromEnv({}), "the two defaults differ");
});
