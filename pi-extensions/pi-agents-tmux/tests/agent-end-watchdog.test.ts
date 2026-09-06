// The settled-run watchdog as a state machine on a manual scheduler: each row
// is a script of agent_end events, grace expiries and direct checks on one
// task, read back after every step as one line. The real O_EXCL writer and
// the two env parsers are tables of their own.

import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { after } from "node:test";
import {
	type AgentEndWatchdogDeps,
	buildSyntheticOutbox,
	createAgentEndWatchdog,
	defaultOutboxExists,
	defaultWriteSyntheticOutbox,
	type OnAgentEndCheckResult,
	type OnAgentEndOutcome,
	type SyntheticOutboxPayload,
	WATCHDOG_DEFAULT_GRACE_SEC,
	WATCHDOG_REASON,
	watchdogEnabledFromEnv,
	watchdogGraceMsFromEnv,
} from "../extensions/subagent/agent-end-watchdog.js";
import type { PaneTaskRecord } from "../extensions/subagent/types.js";

const tempDirs: string[] = [];
after(() => {
	for (const dir of tempDirs) rmSync(dir, { force: true, recursive: true });
});
function tempRuntime(): string {
	const dir = mkdtempSync(join(tmpdir(), "pi-agents-watchdog-"));
	tempDirs.push(dir);
	return dir;
}

const AGENT = "planner";
const TASK = "task-watchdog-1";
const REAL_OUTBOX = { agent: AGENT, filesChanged: [], status: "completed", summary: "real completion", taskId: TASK, validation: [] };

// The world a script runs in: the task record the registry answers (or none,
// or a throw), whether the pane reads idle, and a writer or marker that fails.
type Failure = { code?: string; message: string };
interface WorldOpts {
	enabled?: boolean;
	record?: PaneTaskRecord["status"] | "no-status" | "no-outbox" | "none" | "throws";
	paneIdle?: boolean;
	writeFails?: Failure;
	markFails?: Failure;
}
interface World {
	watchdog: ReturnType<typeof createAgentEndWatchdog>;
	runtimeRoot: string;
	outboxFile: string;
	defaultOutboxFile: string;
	timers: Array<{ fn: () => void; cancelled: boolean; delayMs: number }>;
	probes: { record: number; outbox: number; idle: number };
	writes: SyntheticOutboxPayload[];
	marked: string[];
	warnings: string[];
	seen: { writes: number; marked: number; warnings: number; probes: { record: number; outbox: number; idle: number } };
}

function failing(failure: Failure): () => Promise<never> {
	return async () => {
		const err: NodeJS.ErrnoException = new Error(failure.message);
		if (failure.code) err.code = failure.code;
		throw err;
	};
}

function world(opts: WorldOpts = {}): World {
	const runtimeRoot = tempRuntime();
	const outboxFile = join(runtimeRoot, "outbox", AGENT, `${TASK}.json`);
	// The path the watchdog computes itself, distinct from the record's own.
	const defaultOutboxFile = join(runtimeRoot, "outbox", AGENT, `${TASK}.default.json`);
	const w: World = {
		watchdog: undefined as never,
		runtimeRoot,
		outboxFile,
		defaultOutboxFile,
		timers: [],
		probes: { record: 0, outbox: 0, idle: 0 },
		writes: [],
		marked: [],
		warnings: [],
		seen: { writes: 0, marked: 0, warnings: 0, probes: { record: 0, outbox: 0, idle: 0 } },
	};
	const record = opts.record ?? "running";
	const deps: AgentEndWatchdogDeps = {
		graceMs: 10_000,
		now: () => 0,
		scheduleAfter: (delayMs, fn) => {
			const entry = { fn, cancelled: false, delayMs };
			w.timers.push(entry);
			return { cancel: () => void (entry.cancelled = true) };
		},
		isEnabled: () => opts.enabled ?? true,
		outboxPathFor: () => defaultOutboxFile,
		readTaskRecord: async () => {
			w.probes.record += 1;
			if (record === "throws") throw new Error("registry unreadable");
			if (record === "none") return undefined;
			const rec: PaneTaskRecord = { agent: AGENT, createdAt: "2026-05-15T00:00:00.000Z", outboxFile, status: record as PaneTaskRecord["status"], task: "Plan.", taskId: TASK };
			if (record === "no-status") delete (rec as Partial<PaneTaskRecord>).status;
			if (record === "no-outbox") {
				rec.status = "running";
				delete rec.outboxFile;
			}
			return rec;
		},
		outboxExists: async (file) => {
			w.probes.outbox += 1;
			return existsSync(file);
		},
		isPaneIdle: async () => {
			w.probes.idle += 1;
			return opts.paneIdle ?? true;
		},
		writeSyntheticOutbox: opts.writeFails
			? failing(opts.writeFails)
			: async (file, payload) => {
					mkdirSync(join(runtimeRoot, "outbox", AGENT), { recursive: true });
					writeFileSync(file, `${JSON.stringify(payload, null, "\t")}\n`);
					w.writes.push(payload);
				},
		markFired: opts.markFails
			? failing(opts.markFails)
			: async (_root, _agent, id) => {
					w.marked.push(id);
				},
		logWarn: (msg) => void w.warnings.push(msg),
	};
	w.watchdog = createAgentEndWatchdog(deps);
	return w;
}

// A warning by the failure it names, with the pair and message it carries;
// any other line printed whole.
function warnTag(line: string): string {
	for (const [needle, tag] of [["writeSyntheticOutbox failed", "write-failed"], ["markFired failed", "mark-failed"], ["unexpected error", "unexpected"], ["runCheck threw", "check-threw"]] as const) {
		if (line.includes(needle)) return `${tag}(${JSON.stringify(line.slice(line.indexOf(" for ") + 5))})`;
	}
	return JSON.stringify(line);
}

// The synthetic payload by its status, reason, refs, synthetic mark and
// whether it carries a summary at all; the disk by what sits at the record's
// outbox path, and at the computed one when anything does.
function payloadTag(p: SyntheticOutboxPayload): string {
	return `${p.status}/${p.reason}@${p.agent}/${p.taskId}${p.synthetic === true ? "/synthetic" : "/NOT-SYNTHETIC"}${p.summary ? "" : "/EMPTY-SUMMARY"}`;
}
function diskTag(file: string): string {
	if (!existsSync(file)) return "absent";
	const parsed = JSON.parse(readFileSync(file, "utf8"));
	return parsed.synthetic === true ? "synthetic" : `real(${parsed.summary})`;
}
function outcomeTag(o: OnAgentEndOutcome): string {
	return o.scheduled ? "scheduled" : `refused:${o.reason}`;
}
function checkTag(r: OnAgentEndCheckResult): string {
	if (r.fired) return "fired";
	if (r.error !== undefined) return `error(${JSON.stringify(r.error)})`;
	return `skip:${r.skipped}`;
}

// Steps: an agent_end, the grace expiring (every live timer fires, then two
// macrotask turns so the check's promise chain settles), a direct check, and
// a real completion landing on disk.
type Step = (w: World) => Promise<string> | string;
const end: Step = (w) => outcomeTag(w.watchdog.onAgentEnd({ agentName: AGENT, runtimeRoot: w.runtimeRoot, taskId: TASK }));
const endWithoutTask: Step = (w) => outcomeTag(w.watchdog.onAgentEnd({ agentName: AGENT, runtimeRoot: w.runtimeRoot, taskId: "" }));
const grace: Step = async (w) => {
	const live = w.timers.filter((t) => !t.cancelled);
	for (const t of live) {
		t.cancelled = true;
		t.fn();
	}
	await new Promise((resolve) => setTimeout(resolve, 0));
	await new Promise((resolve) => setTimeout(resolve, 0));
	return `grace(${live.map((t) => t.delayMs).join(",") || "none"})`;
};
const check: Step = async (w) => {
	try {
		return checkTag(await w.watchdog.checkNow({ agentName: AGENT, runtimeRoot: w.runtimeRoot, taskId: TASK }));
	} catch (err) {
		return `threw(${JSON.stringify((err as Error).message)})`;
	}
};
const realCompletion: Step = (w) => {
	mkdirSync(join(w.runtimeRoot, "outbox", AGENT), { recursive: true });
	writeFileSync(w.outboxFile, JSON.stringify(REAL_OUTBOX));
	return "real-completion";
};

// One step's line: what the step returned, then the task read back (fired,
// pending in the watchdog's own map, live timers in the scheduler), then what
// the step added: probes made, payloads written,
// marks, warnings, and the disk.
async function runScript(w: World, steps: Step[]): Promise<string> {
	const lines: string[] = [];
	for (const step of steps) {
		const head = await step(w);
		const probes = (["record", "outbox", "idle"] as const).map((k) => `${k[0]}${w.probes[k] - w.seen.probes[k]}`).join("");
		const wrote = w.writes.slice(w.seen.writes).map(payloadTag);
		const marks = w.marked.slice(w.seen.marked);
		const warned = w.warnings.slice(w.seen.warnings).map(warnTag);
		w.seen = { writes: w.writes.length, marked: w.marked.length, warnings: w.warnings.length, probes: { ...w.probes } };
		const live = w.timers.filter((t) => !t.cancelled).length;
		const fallback = existsSync(w.defaultOutboxFile) ? ` default=${diskTag(w.defaultOutboxFile)}` : "";
		lines.push(`${head} fired=${w.watchdog.hasFired(TASK)} pending=${w.watchdog.hasPending(TASK)} timers=${live} probes=${probes} +writes=[${wrote.join(",")}] +marked=[${marks.join(",")}] disk=${diskTag(w.outboxFile)}${fallback}${warned.length ? ` warn=[${warned.join(",")}]` : ""}`);
	}
	return lines.join("\n");
}

const SYNTHETIC = `needs_completion/${WATCHDOG_REASON}@${AGENT}/${TASK}/synthetic`;

// label | world | steps | expect (one line per step)
const rows: Array<[string, WorldOpts, Step[], string]> = [
	[
		"a settled turn with no outbox fires after the grace, writes the synthetic outbox and marks the task",
		{},
		[end, grace],
		[
			"scheduled fired=false pending=true timers=1 probes=r0o0i0 +writes=[] +marked=[] disk=absent",
			`grace(10000) fired=true pending=false timers=0 probes=r1o1i1 +writes=[${SYNTHETIC}] +marked=[${TASK}] disk=synthetic`,
		].join("\n"),
	],
	[
		"a disabled watchdog arms nothing",
		{ enabled: false },
		[end, grace],
		["refused:disabled fired=false pending=false timers=0 probes=r0o0i0 +writes=[] +marked=[] disk=absent", "grace(none) fired=false pending=false timers=0 probes=r0o0i0 +writes=[] +marked=[] disk=absent"].join("\n"),
	],
	[
		"an agent_end without a task id is refused",
		{},
		[endWithoutTask],
		"refused:missing-task-id fired=false pending=false timers=0 probes=r0o0i0 +writes=[] +marked=[] disk=absent",
	],
	[
		"a real completion during the grace wins and is kept",
		{},
		[end, realCompletion, grace],
		[
			"scheduled fired=false pending=true timers=1 probes=r0o0i0 +writes=[] +marked=[] disk=absent",
			"real-completion fired=false pending=true timers=1 probes=r0o0i0 +writes=[] +marked=[] disk=real(real completion)",
			"grace(10000) fired=false pending=false timers=0 probes=r1o1i0 +writes=[] +marked=[] disk=real(real completion)",
		].join("\n"),
	],
	[
		"a busy pane at the grace is probed and left alone",
		{ paneIdle: false },
		[end, grace],
		["scheduled fired=false pending=true timers=1 probes=r0o0i0 +writes=[] +marked=[] disk=absent", "grace(10000) fired=false pending=false timers=0 probes=r1o1i1 +writes=[] +marked=[] disk=absent"].join("\n"),
	],
	[
		"a second agent_end while pending is already scheduled; after the grace it is already fired and checks nothing",
		{},
		[end, end, grace, end, grace],
		[
			"scheduled fired=false pending=true timers=1 probes=r0o0i0 +writes=[] +marked=[] disk=absent",
			"refused:already-scheduled fired=false pending=true timers=1 probes=r0o0i0 +writes=[] +marked=[] disk=absent",
			`grace(10000) fired=true pending=false timers=0 probes=r1o1i1 +writes=[${SYNTHETIC}] +marked=[${TASK}] disk=synthetic`,
			"refused:already-fired fired=true pending=false timers=0 probes=r0o0i0 +writes=[] +marked=[] disk=synthetic",
			"grace(none) fired=true pending=false timers=0 probes=r0o0i0 +writes=[] +marked=[] disk=synthetic",
		].join("\n"),
	],
	[
		"a direct check cancels the pending timer and reads the task terminal",
		{ record: "completed" },
		[end, check, grace],
		[
			"scheduled fired=false pending=true timers=1 probes=r0o0i0 +writes=[] +marked=[] disk=absent",
			"skip:task-terminal fired=false pending=false timers=0 probes=r1o0i0 +writes=[] +marked=[] disk=absent",
			"grace(none) fired=false pending=false timers=0 probes=r0o0i0 +writes=[] +marked=[] disk=absent",
		].join("\n"),
	],
	["a task with no record", { record: "none" }, [check], "skip:no-record fired=false pending=false timers=0 probes=r1o0i0 +writes=[] +marked=[] disk=absent"],
	["a task with no status yet is active", { record: "no-status" }, [check], `fired fired=true pending=false timers=0 probes=r1o1i1 +writes=[${SYNTHETIC}] +marked=[${TASK}] disk=synthetic`],
	["a queued task is active", { record: "queued" }, [check], `fired fired=true pending=false timers=0 probes=r1o1i1 +writes=[${SYNTHETIC}] +marked=[${TASK}] disk=synthetic`],
	["a blocked task is terminal", { record: "blocked" }, [check], "skip:task-terminal fired=false pending=false timers=0 probes=r1o0i0 +writes=[] +marked=[] disk=absent"],
	["a failed task is terminal", { record: "failed" }, [check], "skip:task-terminal fired=false pending=false timers=0 probes=r1o0i0 +writes=[] +marked=[] disk=absent"],
	["a task already needing completion is terminal", { record: "needs_completion" }, [check], "skip:task-terminal fired=false pending=false timers=0 probes=r1o0i0 +writes=[] +marked=[] disk=absent"],
	["a task of unknown status is active", { record: "unknown" }, [check], `fired fired=true pending=false timers=0 probes=r1o1i1 +writes=[${SYNTHETIC}] +marked=[${TASK}] disk=synthetic`],
	["a record without an outbox path is written at the computed one", { record: "no-outbox" }, [check], `fired fired=true pending=false timers=0 probes=r1o1i1 +writes=[${SYNTHETIC}] +marked=[${TASK}] disk=absent default=synthetic`],
	["an outbox already on disk", {}, [realCompletion, check], ["real-completion fired=false pending=false timers=0 probes=r0o0i0 +writes=[] +marked=[] disk=real(real completion)", "skip:outbox-present fired=false pending=false timers=0 probes=r1o1i0 +writes=[] +marked=[] disk=real(real completion)"].join("\n")],
	["a busy pane", { paneIdle: false }, [check], "skip:pane-busy fired=false pending=false timers=0 probes=r1o1i1 +writes=[] +marked=[] disk=absent"],
	["a writer losing the O_EXCL race is a quiet outbox-present", { writeFails: { code: "EEXIST", message: "outbox already exists" } }, [check, check], ["skip:outbox-present fired=false pending=false timers=0 probes=r1o1i1 +writes=[] +marked=[] disk=absent", "skip:outbox-present fired=false pending=false timers=0 probes=r1o1i1 +writes=[] +marked=[] disk=absent"].join("\n")],
	["a writer failing otherwise is warned and the task stays unfired", { writeFails: { code: "ENOSPC", message: "disk full" } }, [check], 'error("disk full") fired=false pending=false timers=0 probes=r1o1i1 +writes=[] +marked=[] disk=absent warn=[write-failed("planner/task-watchdog-1: disk full")]'],
	["a failing mark is warned after the outbox is written and the task counts as fired", { markFails: { message: "registry locked" } }, [check, check], [`fired fired=true pending=false timers=0 probes=r1o1i1 +writes=[${SYNTHETIC}] +marked=[] disk=synthetic warn=[mark-failed("planner/task-watchdog-1: registry locked")]`, "skip:already-fired fired=true pending=false timers=0 probes=r0o0i0 +writes=[] +marked=[] disk=synthetic"].join("\n")],
	["an unreadable registry is warned and the task stays unfired", { record: "throws" }, [check], 'error("registry unreadable") fired=false pending=false timers=0 probes=r1o0i0 +writes=[] +marked=[] disk=absent warn=[unexpected("planner/task-watchdog-1: registry unreadable")]'],
];

test("the settled-run watchdog", async () => {
	for (const [label, opts, steps, expect] of rows) assert.equal(await runScript(world(opts), steps), expect, label);
});

// The real writer and existence probe: an O_EXCL create, so a completion
// already on disk is kept and the loss is reported by its code.
async function writerLine(existing: string | undefined): Promise<string> {
	const runtimeRoot = tempRuntime();
	const outboxFile = join(runtimeRoot, "outbox", AGENT, `${TASK}.json`);
	if (existing !== undefined) {
		mkdirSync(join(runtimeRoot, "outbox", AGENT), { recursive: true });
		writeFileSync(outboxFile, existing);
	}
	const existed = await defaultOutboxExists(outboxFile);
	let head: string;
	try {
		await defaultWriteSyntheticOutbox(outboxFile, buildSyntheticOutbox(AGENT, TASK));
		head = "written";
	} catch (err) {
		head = `rejected:${(err as NodeJS.ErrnoException).code ?? JSON.stringify((err as Error).message)}`;
	}
	const parsed = JSON.parse(readFileSync(outboxFile, "utf8"));
	const disk = parsed.synthetic === true ? payloadTag(parsed) : `real(${parsed.summary})`;
	return `existed=${existed} ${head} exists=${await defaultOutboxExists(outboxFile)} disk=${disk}`;
}

// label | what is on disk | expect
const writerRows: Array<[string, string | undefined, string]> = [
	["a free path is created with the synthetic payload", undefined, `existed=false written exists=true disk=${SYNTHETIC}`],
	["an outbox already on disk is kept and the loss carries EEXIST", JSON.stringify({ summary: "real" }), "existed=true rejected:EEXIST exists=true disk=real(real)"],
];

test("the O_EXCL synthetic outbox writer", async () => {
	for (const [label, existing, expect] of writerRows) assert.equal(await writerLine(existing), expect, label);
});

// label | KENDEX_AGENT_END_WATCHDOG | expect
const enabledRows: Array<[string, string | undefined, boolean]> = [
	["unset is on", undefined, true],
	["empty is on", "", true],
	["1 is on", "1", true],
	["0 is off", "0", false],
	["false is off", "false", false],
	["off is off", "off", false],
	["OFF is off", "OFF", false],
	["a padded 0 is off", " 0 ", false],
];

test("KENDEX_AGENT_END_WATCHDOG", () => {
	for (const [label, value, expect] of enabledRows) assert.equal(watchdogEnabledFromEnv(value === undefined ? {} : { KENDEX_AGENT_END_WATCHDOG: value }), expect, label);
});

const DEFAULT_GRACE_MS = WATCHDOG_DEFAULT_GRACE_SEC * 1000;

// label | KENDEX_AGENT_END_WATCHDOG_GRACE_SEC | expect (ms)
const graceRows: Array<[string, string | undefined, number]> = [
	["unset is the default", undefined, DEFAULT_GRACE_MS],
	["empty is the default", "", DEFAULT_GRACE_MS],
	["whitespace is the default", " ", DEFAULT_GRACE_MS],
	["seconds are milliseconds", "3", 3000],
	["a fraction keeps whole milliseconds", "0.0015", 1],
	["zero is zero", "0", 0],
	["a negative is the default", "-1", DEFAULT_GRACE_MS],
	["garbage is the default", "garbage", DEFAULT_GRACE_MS],
	["Infinity is the default", "Infinity", DEFAULT_GRACE_MS],
];

test("KENDEX_AGENT_END_WATCHDOG_GRACE_SEC", () => {
	for (const [label, value, expect] of graceRows) assert.equal(watchdogGraceMsFromEnv(value === undefined ? {} : { KENDEX_AGENT_END_WATCHDOG_GRACE_SEC: value }), expect, label);
});
