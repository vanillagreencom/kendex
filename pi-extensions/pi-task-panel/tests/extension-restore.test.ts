import { expect, test } from "bun:test";
import { mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { clearPackageConfigCache } from "../extensions/package-config.js";
import { fakeCtx, fakePi, mockPiModules } from "./lib/fake-pi.ts";

mockPiModules();

const SESSION_ID = "restore-test";
const BRANCH_STATE_MISSING = "persistence_failure=branch-state-missing";

/** Saved in this order, so the sidecar ends holding `newer`; `mid` passes only the tool-result task cap, the other large lists the session entry cap too and get a saved-state file. */
const SAVES = {
	small: ["small task"],
	mid: Array.from({ length: 150 }, (_value, index) => `mid ${index}`),
	older: Array.from({ length: 200 }, (_value, index) => `${"o".repeat(400)} older ${index}`),
	newer: Array.from({ length: 200 }, (_value, index) => `${"n".repeat(400)} newer ${index}`),
};
type Save = keyof typeof SAVES;
/** A save's session custom entry, or its tasks_write tool result. */
type BranchRecord = `${Save}.${"entry" | "result"}`;

/** The saved-state directory's bound, `TASK_PANEL_SAVED_STATES_MAX`. */
const SAVED_STATES_MAX = 20;

/**
 * What happens between the saves and the restore. `evict`: as many further
 * large lists are saved as the saved-state directory keeps, so it drops
 * `older` and `newer`. `fork`: the restore runs in another session, which has
 * neither the sidecar nor the saved-state directory. `save-at-older`: the
 * panel moves to the `older` point and saves a change there first.
 */
type Before = "evict" | "fork" | "save-at-older";

const ROWS: Array<{ name: string; branch: BranchRecord[]; before?: Before; expected: Save | "empty"; warnings: string[] }> = [
	{ name: "a tree point before any task save ignores the newer sidecar", branch: [], expected: "empty", warnings: [] },
	{ name: "a manifest naming an older state restores it from its saved-state file", branch: ["small.entry", "older.entry"], expected: "older", warnings: [] },
	{ name: "a manifest naming the sidecar state restores the sidecar", branch: ["small.entry", "older.entry", "newer.entry"], expected: "newer", warnings: [] },
	{ name: "bounded details naming an older state restore it from its saved-state file", branch: ["small.result", "older.result"], expected: "older", warnings: [] },
	{ name: "bounded details naming the sidecar state replace older full details", branch: ["small.result", "newer.result"], expected: "newer", warnings: [] },
	{ name: "bounded details naming the full entry before them keep that list without a saved file", branch: ["small.entry", "small.result", "mid.entry", "mid.result"], expected: "mid", warnings: [] },
	{ name: "the newest leaf after a save at an older point restores the leaf's list", branch: ["small.entry", "older.entry", "newer.entry"], before: "save-at-older", expected: "newer", warnings: [] },
	{ name: "a manifest naming a state the saved-state directory dropped keeps the last full list and warns", branch: ["small.entry", "older.entry"], before: "evict", expected: "small", warnings: [BRANCH_STATE_MISSING] },
	{ name: "a full entry after a manifest naming a dropped state clears the warning", branch: ["older.entry", "small.entry"], before: "evict", expected: "small", warnings: [] },
	{ name: "full details after bounded details naming a dropped state clear the warning", branch: ["older.result", "small.result"], before: "evict", expected: "small", warnings: [] },
	{ name: "a fork keeps the last full list and warns", branch: ["small.entry", "newer.entry"], before: "fork", expected: "small", warnings: [BRANCH_STATE_MISSING] },
];

for (const row of ROWS) {
	test(`session_tree restore: ${row.name}`, async () => {
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
			const ctx = fakeCtx(base, SESSION_ID, notifications);
			const tasksWrite = (params: Record<string, unknown>) => pi.tools.get("tasks_write").execute("call", params, undefined, undefined, ctx);
			const navigate = pi.handlers.get("session_tree");
			if (!navigate) throw new Error("handler-missing=session_tree");
			const records = new Map<BranchRecord, unknown>();
			for (const save of Object.keys(SAVES) as Save[]) {
				const result = await tasksWrite({ action: "replace", tasks: SAVES[save].map((content) => ({ content })) });
				const entry = pi.appended.at(-1);
				records.set(`${save}.entry`, { type: "custom", customType: entry?.customType, data: entry?.data });
				records.set(`${save}.result`, { type: "message", message: { role: "toolResult", toolName: "tasks_write", details: result.details } });
			}
			expect(pi.appended.map((entry) => entry.data.fullSnapshot)).toEqual([undefined, undefined, false, false]);
			const states = join(base, "agent", "kendex", "sessions", SESSION_ID, "pi-task-panel", "states");
			expect(readdirSync(states)).toHaveLength(2);
			let restoreCtx = ctx;
			if (row.before === "evict") {
				// Back-dated, so the directory drops these two whatever the file system's timestamp granularity.
				for (const name of readdirSync(states)) utimesSync(join(states, name), 1, 1);
				for (let save = 0; save < SAVED_STATES_MAX; save++) {
					await tasksWrite({ action: "replace", tasks: Array.from({ length: 200 }, (_value, index) => ({ content: `${"e".repeat(400)} evict ${save} ${index}` })) });
				}
				expect(readdirSync(states)).toHaveLength(SAVED_STATES_MAX);
			} else if (row.before === "fork") restoreCtx = fakeCtx(base, `${SESSION_ID}-fork`, notifications);
			else if (row.before === "save-at-older") {
				ctx.sessionManager.getBranch = () => (["small.entry", "older.entry"] as BranchRecord[]).map((name) => records.get(name)) as never;
				await navigate({}, ctx);
				await tasksWrite({ action: "add_task", task: "edited at the older point" });
			}
			restoreCtx.sessionManager.getBranch = () => row.branch.map((name) => records.get(name)) as never;
			await navigate({}, restoreCtx);
			const exported = join(base, "exported.md");
			await pi.commands.get("tasks:export").handler(exported, restoreCtx);
			const restored = readFileSync(exported, "utf8").split("\n").filter((line) => line.startsWith("- ")).map((line) => line.slice(2).replace(/ \((active|done|dropped)\)$/, ""));
			expect(restored.sort()).toEqual(row.expected === "empty" ? [] : [...SAVES[row.expected]].sort());
			expect(notifications.filter((note) => note.level === "warning").map((note) => note.message.split("\n")[0])).toEqual(row.warnings);
		} finally {
			if (previousPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = previousPiDir;
			if (previousDiagnosticLog === undefined) delete process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG;
			else process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG = previousDiagnosticLog;
			clearPackageConfigCache();
			rmSync(base, { recursive: true, force: true });
		}
	});
}
