import { expect, test } from "bun:test";
import { mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, truncateSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { clearPackageConfigCache } from "../extensions/package-config.js";
import { fakeCtx, fakePi, mockPiModules } from "./lib/fake-pi.ts";

mockPiModules();

const SESSION_ID = "restore-test";
const BRANCH_STATE_MISSING = "persistence_failure=branch-state-missing";

/** `mid` passes only the tool-result task cap, the other large lists the session entry cap too and get a saved-state file; `latest` is saved only by the `tie` step. */
const SAVES = {
	small: ["small task"],
	mid: Array.from({ length: 150 }, (_value, index) => `mid ${index}`),
	older: Array.from({ length: 200 }, (_value, index) => `${"o".repeat(400)} older ${index}`),
	newer: Array.from({ length: 200 }, (_value, index) => `${"n".repeat(400)} newer ${index}`),
	latest: Array.from({ length: 200 }, (_value, index) => `${"l".repeat(400)} latest ${index}`),
};
type Save = keyof typeof SAVES;
/** Saved in this order before every row, so the sidecar ends holding `newer`. */
const SAVE_ORDER: Save[] = ["small", "mid", "older", "newer"];
/** A save's session custom entry, or its tasks_write tool result. */
type BranchRecord = `${Save}.${"entry" | "result"}`;

/** The saved-state directory's bound, `TASK_PANEL_SAVED_STATES_MAX_BYTES`. */
const SAVED_STATES_MAX_BYTES = 32 * 1024 * 1024;

/** Past the clock, so a file dated here is newer than any file a save writes; the `tie` step uses it. */
const AHEAD_OF_CLOCK = 4_000_000_000;

/**
 * What happens between the saves and the restore. `evict`: `older`'s file is
 * back-dated, a filler file dated between it and `newer` brings the directory
 * to within half a file of its bound, and one further large list is saved, so
 * the directory drops `older` and keeps `newer`. `fork`: the restore runs in
 * another session, which has neither the sidecar nor the saved-state
 * directory. `save-at-older`: the panel moves to the `older` point and saves a
 * change there first. `tie`: every file in the directory, and a filler file
 * the size of the bound, are dated past the clock, so the next file a save
 * writes is neither the newest by timestamp, as when consecutive saves share
 * one, nor within the bound beside the others; then `latest` is saved, and
 * `small` after it replaces the sidecar.
 */
type Before = "evict" | "fork" | "save-at-older" | "tie";

const ROWS: Array<{ name: string; branch: BranchRecord[]; before?: Before; expected: Save | "empty"; warnings: string[] }> = [
	{ name: "a tree point before any task save ignores the newer sidecar", branch: [], expected: "empty", warnings: [] },
	{ name: "a manifest naming an older state restores it from its saved-state file", branch: ["small.entry", "older.entry"], expected: "older", warnings: [] },
	{ name: "a manifest naming the sidecar state restores the sidecar", branch: ["small.entry", "older.entry", "newer.entry"], expected: "newer", warnings: [] },
	{ name: "bounded details naming an older state restore it from its saved-state file", branch: ["small.result", "older.result"], expected: "older", warnings: [] },
	{ name: "bounded details naming the sidecar state replace older full details", branch: ["small.result", "newer.result"], expected: "newer", warnings: [] },
	{ name: "bounded details naming the full entry before them keep that list without a saved file", branch: ["small.entry", "small.result", "mid.entry", "mid.result"], expected: "mid", warnings: [] },
	{ name: "the newest leaf after a save at an older point restores the leaf's list", branch: ["small.entry", "older.entry", "newer.entry"], before: "save-at-older", expected: "newer", warnings: [] },
	{ name: "a manifest naming a state the saved-state directory dropped keeps the last full list and warns", branch: ["small.entry", "older.entry"], before: "evict", expected: "small", warnings: [BRANCH_STATE_MISSING] },
	{ name: "a manifest naming a saved state after one naming a dropped state restores it without a warning", branch: ["older.entry", "newer.entry"], before: "evict", expected: "newer", warnings: [] },
	{ name: "a full entry after a manifest naming a dropped state clears the warning", branch: ["older.entry", "small.entry"], before: "evict", expected: "small", warnings: [] },
	{ name: "full details after bounded details naming a dropped state clear the warning", branch: ["older.result", "small.result"], before: "evict", expected: "small", warnings: [] },
	{ name: "a save past the directory's bound keeps the file it wrote when others share or pass its timestamp", branch: ["small.entry", "latest.entry"], before: "tie", expected: "latest", warnings: [] },
	{ name: "a fork keeps the last full list and warns", branch: ["small.entry", "newer.entry"], before: "fork", expected: "small", warnings: [BRANCH_STATE_MISSING] },
];

/** Loads the extension into a fresh fake session whose Pi user directory and diagnostic log sit under a scratch root. */
async function inSession(run: (session: { base: string; pi: ReturnType<typeof fakePi>; ctx: ReturnType<typeof fakeCtx>; notifications: Array<{ message: string; level: string }>; navigate: (event: unknown, ctx: unknown) => unknown }) => Promise<void>): Promise<void> {
	const previousPiDir = process.env.PI_CODING_AGENT_DIR;
	const previousDiagnosticLog = process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG;
	const base = realpathSync(mkdtempSync(join(tmpdir(), "pi-task-panel-restore-")));
	try {
		process.env.PI_CODING_AGENT_DIR = join(base, "agent");
		process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG = join(base, "diagnostics.log");
		clearPackageConfigCache();
		const { default: taskPanel } = await import("../extensions/task-panel.js");
		const pi = fakePi();
		taskPanel(pi as never);
		const notifications: Array<{ message: string; level: string }> = [];
		const navigate = pi.handlers.get("session_tree");
		if (!navigate) throw new Error("handler-missing=session_tree");
		await run({ base, pi, ctx: fakeCtx(base, SESSION_ID, notifications), notifications, navigate });
	} finally {
		if (previousPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousPiDir;
		if (previousDiagnosticLog === undefined) delete process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG;
		else process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG = previousDiagnosticLog;
		clearPackageConfigCache();
		rmSync(base, { recursive: true, force: true });
	}
}

/** The task lines `/tasks:export` writes for the panel's current state. */
async function exportedTasks(base: string, pi: ReturnType<typeof fakePi>, ctx: ReturnType<typeof fakeCtx>): Promise<string[]> {
	const exported = join(base, "exported.md");
	await pi.commands.get("tasks:export").handler(exported, ctx);
	return readFileSync(exported, "utf8").split("\n").filter((line) => line.startsWith("- ")).map((line) => line.slice(2));
}

for (const row of ROWS) {
	test(`session_tree restore: ${row.name}`, () => inSession(async ({ base, pi, ctx, notifications, navigate }) => {
		const tasksWrite = (params: Record<string, unknown>) => pi.tools.get("tasks_write").execute("call", params, undefined, undefined, ctx);
		const records = new Map<BranchRecord, unknown>();
		const save = async (name: Save) => {
			const result = await tasksWrite({ action: "replace", tasks: SAVES[name].map((content) => ({ content })) });
			const entry = pi.appended.at(-1);
			records.set(`${name}.entry`, { type: "custom", customType: entry?.customType, data: entry?.data });
			records.set(`${name}.result`, { type: "message", message: { role: "toolResult", toolName: "tasks_write", details: result.details } });
		};
		const saveLargeLists = async (count: number) => {
			for (let save = 0; save < count; save++) {
				await tasksWrite({ action: "replace", tasks: Array.from({ length: 200 }, (_value, index) => ({ content: `${"e".repeat(400)} evict ${save} ${index}` })) });
			}
		};
		for (const name of SAVE_ORDER) await save(name);
		expect(pi.appended.map((entry) => entry.data.fullSnapshot)).toEqual([undefined, undefined, false, false]);
		const states = join(base, "agent", "kendex", "sessions", SESSION_ID, "pi-task-panel", "states");
		const savedStates = () => readdirSync(states).filter((name) => name.endsWith(".json")).sort();
		const savedStateFile = (name: Save) => `${(records.get(`${name}.entry`) as { data: { fingerprint: string } }).data.fingerprint}.json`;
		expect(savedStates()).toEqual([savedStateFile("older"), savedStateFile("newer")].sort());
		let restoreCtx = ctx;
		/** A sparse `.json` file of `bytes` bytes dated `at`, counted against the bound like a saved state. */
		const filler = (bytes: number, at: number) => {
			const path = join(states, "filler.json");
			writeFileSync(path, "");
			truncateSync(path, bytes);
			utimesSync(path, at, at);
		};
		if (row.before === "evict") {
			// Back-dated, so the directory drops it whatever the file system's timestamp granularity.
			utimesSync(join(states, savedStateFile("older")), 1, 1);
			// The evicting save's file is within a few hundred bytes of `older`'s size.
			const fileBytes = statSync(join(states, savedStateFile("older"))).size;
			filler(SAVED_STATES_MAX_BYTES - statSync(join(states, savedStateFile("newer"))).size - fileBytes - Math.floor(fileBytes / 2), 2);
			await saveLargeLists(1);
			expect(savedStates()).toHaveLength(3);
			expect(savedStates()).toContain(savedStateFile("newer"));
			expect(savedStates()).not.toContain(savedStateFile("older"));
		} else if (row.before === "tie") {
			for (const name of readdirSync(states)) utimesSync(join(states, name), AHEAD_OF_CLOCK, AHEAD_OF_CLOCK);
			filler(SAVED_STATES_MAX_BYTES, AHEAD_OF_CLOCK + 1);
			await save("latest");
			expect(savedStates()).toEqual([savedStateFile("latest")]);
			await save("small");
		} else if (row.before === "fork") restoreCtx = fakeCtx(base, `${SESSION_ID}-fork`, notifications);
		else if (row.before === "save-at-older") {
			ctx.sessionManager.getBranch = () => (["small.entry", "older.entry"] as BranchRecord[]).map((name) => records.get(name)) as never;
			await navigate({}, ctx);
			await tasksWrite({ action: "add_task", task: "edited at the older point" });
		}
		restoreCtx.sessionManager.getBranch = () => row.branch.map((name) => records.get(name)) as never;
		await navigate({}, restoreCtx);
		const restored = (await exportedTasks(base, pi, restoreCtx)).map((line) => line.replace(/ \((active|done|dropped)\)$/, ""));
		expect(restored.sort()).toEqual(row.expected === "empty" ? [] : [...SAVES[row.expected]].sort());
		expect(notifications.filter((note) => note.level === "warning").map((note) => note.message.split("\n")[0])).toEqual(row.warnings);
	}));
}

test("a slash change at an older tree point that recreates the newer state saves it", () => inSession(async ({ base, pi, ctx, navigate }) => {
	await pi.tools.get("tasks_write").execute("call", { action: "replace", tasks: [{ content: "first" }, { content: "second" }] }, undefined, undefined, ctx);
	const older = pi.appended.at(-1);
	const done = pi.commands.get("tasks:done");
	await done.handler("first", ctx);
	expect(pi.appended).toHaveLength(2);
	const entry = (appended: { customType: string; data: unknown }) => ({ type: "custom", customType: appended.customType, data: appended.data });
	ctx.sessionManager.getBranch = () => [entry(older!)] as never;
	await navigate({}, ctx);
	expect(await exportedTasks(base, pi, ctx)).toEqual(["first (active)", "second"]);
	await done.handler("first", ctx);
	expect(pi.appended).toHaveLength(3);
	ctx.sessionManager.getBranch = () => [entry(older!), entry(pi.appended[2])] as never;
	await navigate({}, ctx);
	expect(await exportedTasks(base, pi, ctx)).toEqual(["first (done)", "second (active)"]);
}));
