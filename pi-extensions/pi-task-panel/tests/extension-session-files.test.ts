// The package's session files on disk: the saved-state directory's byte
// bound, its temporary-file cleanup, and lane retention of the session's
// directory (scripts/lane-retention.ts).
import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { clearPackageConfigCache } from "../extensions/package-config.js";
import { exportedTasks, fakeCtx, fakePi, mockPiModules } from "./lib/fake-pi.ts";
import { LANE_CWD_FILE, LANE_FILE_MAX_AGE_MS } from "../scripts/lane-retention.js";

mockPiModules();

const SESSION_ID = "session-files-test";

/** The count bound the saved-state directory had before its byte bound. */
const FORMER_SAVED_STATES_MAX = 20;

interface Session {
	base: string;
	pi: ReturnType<typeof fakePi>;
	/** The session's lane directory, holding the sidecar and `states/`. */
	lane: (sessionId: string) => string;
	/** Runs `tasks_write` in the session whose context is `ctx`. */
	tasksWrite: (ctx: ReturnType<typeof fakeCtx>, params: Record<string, unknown>) => Promise<unknown>;
}

async function inSession(run: (session: Session) => Promise<void>): Promise<void> {
	const previousPiDir = process.env.PI_CODING_AGENT_DIR;
	const previousDiagnosticLog = process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG;
	const base = realpathSync(mkdtempSync(join(tmpdir(), "pi-task-panel-files-")));
	try {
		process.env.PI_CODING_AGENT_DIR = join(base, "agent");
		process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG = join(base, "diagnostics.log");
		clearPackageConfigCache();
		const { default: taskPanel } = await import("../extensions/task-panel.js");
		const pi = fakePi();
		taskPanel(pi as never);
		await run({
			base,
			pi,
			lane: (sessionId) => join(base, "agent", "kendex", "sessions", sessionId, "pi-task-panel"),
			tasksWrite: (ctx, params) => pi.tools.get("tasks_write").execute("call", params, undefined, undefined, ctx),
		});
	} finally {
		if (previousPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousPiDir;
		if (previousDiagnosticLog === undefined) delete process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG;
		else process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG = previousDiagnosticLog;
		clearPackageConfigCache();
		rmSync(base, { recursive: true, force: true });
	}
}

/** A list over the session entry cap, so its save writes a saved-state file. */
function largeList(label: string) {
	return { action: "replace", tasks: Array.from({ length: 200 }, (_value, index) => ({ content: `${"x".repeat(400)} ${label} ${index}` })) };
}

test("saved states past the former count bound all stay while their bytes fit the byte bound", () => inSession(async ({ lane, tasksWrite, base }) => {
	const ctx = fakeCtx(base, SESSION_ID);
	const saves = FORMER_SAVED_STATES_MAX + 5;
	for (let save = 0; save < saves; save++) await tasksWrite(ctx, largeList(`save ${save}`));
	expect(readdirSync(join(lane(SESSION_ID), "states")).filter((name) => name.endsWith(".json"))).toHaveLength(saves);
}));

test("a pruning pass leaves no temporary file a failed write left in the saved-state directory", () => inSession(async ({ lane, tasksWrite, base }) => {
	const ctx = fakeCtx(base, SESSION_ID);
	await tasksWrite(ctx, largeList("first"));
	const states = join(lane(SESSION_ID), "states");
	const [saved] = readdirSync(states);
	writeFileSync(join(states, `${saved}.tmp-424242`), "{}\n");
	await tasksWrite(ctx, largeList("second"));
	expect(readdirSync(states).filter((name) => !name.endsWith(".json"))).toEqual([]);
}));

const RETENTION: Array<{ name: string; removeCwd: boolean; kept: boolean }> = [
	{ name: "a session whose working directory is gone loses its files at the next session start", removeCwd: true, kept: false },
	{ name: "a session whose working directory remains keeps its files at the next session start", removeCwd: false, kept: true },
];

for (const row of RETENTION) {
	test(`lane retention: ${row.name}`, () => inSession(async ({ base, pi, lane, tasksWrite }) => {
		const worktree = join(base, "worktree");
		mkdirSync(worktree);
		const ctx = { ...fakeCtx(base, SESSION_ID), cwd: worktree };
		await tasksWrite(ctx, { action: "add_task", task: "first" });
		await tasksWrite(ctx, largeList("large"));
		expect(readFileSync(join(lane(SESSION_ID), "state.json"), "utf8")).toContain("large");
		if (row.removeCwd) rmSync(worktree, { recursive: true });
		const start = pi.handlers.get("session_start");
		if (!start) throw new Error("handler-missing=session_start");
		await start({ type: "session_start" }, fakeCtx(base, `${SESSION_ID}-next`));
		expect(existsSync(lane(SESSION_ID))).toBe(row.kept);
	}));
}

/** Dates every file and directory under `dir`, `dir` included, `at`. */
function backDate(dir: string, at: number): void {
	for (const name of readdirSync(dir)) {
		const path = join(dir, name);
		if (statSync(path).isDirectory()) backDate(path, at);
		else utimesSync(path, at / 1000, at / 1000);
	}
	utimesSync(dir, at / 1000, at / 1000);
}

const RESUMED: Array<{ name: string; movedFrom: boolean }> = [
	{ name: "in the working directory it saved in", movedFrom: false },
	{ name: "in a new working directory after the one it saved in is gone", movedFrom: true },
];

for (const row of RESUMED) {
	test(`lane retention: a session resumed ${row.name} after its files aged out keeps its large list across a tree move, and a save after another session pruned its lane records the lane again`, () => inSession(async ({ base, pi, lane, tasksWrite }) => {
		const notifications: Array<{ message: string; level: string }> = [];
		const ctx = fakeCtx(base, SESSION_ID, notifications);
		const savedIn = join(base, "saved-in");
		mkdirSync(savedIn);
		if (row.movedFrom) ctx.cwd = savedIn;
		const large = largeList("resumed");
		await tasksWrite(ctx, large);
		const manifest = pi.appended.at(-1);
		expect(manifest?.data.fullSnapshot).toBe(false);
		ctx.sessionManager.getBranch = () => [{ type: "custom", customType: manifest?.customType, data: manifest?.data }] as never;
		const aged = Date.now() - LANE_FILE_MAX_AGE_MS - 60_000;
		backDate(lane(SESSION_ID), aged);
		if (row.movedFrom) {
			rmSync(savedIn, { recursive: true });
			ctx.cwd = base;
		}
		const start = pi.handlers.get("session_start");
		const navigate = pi.handlers.get("session_tree");
		if (!start || !navigate) throw new Error("handler-missing=session_start,session_tree");
		const expected = large.tasks.map((task) => task.content).sort();
		const restored = async () => (await exportedTasks(base, pi, ctx)).map((line) => line.replace(/ \((active|done|dropped)\)$/, "")).sort();

		await start({ type: "session_start" }, ctx);
		expect(await restored()).toEqual(expected);
		expect(existsSync(join(lane(SESSION_ID), "state.json"))).toBe(true);
		expect(existsSync(join(lane(SESSION_ID), "states", `${manifest?.data.fingerprint}.json`))).toBe(true);
		await navigate({}, ctx);
		expect(await restored()).toEqual(expected);
		expect(notifications.filter((note) => note.level === "warning")).toEqual([]);

		backDate(lane(SESSION_ID), aged);
		await start({ type: "session_start" }, fakeCtx(base, `${SESSION_ID}-next`));
		expect(existsSync(lane(SESSION_ID))).toBe(false);
		await tasksWrite(ctx, { action: "add_task", task: "after the prune" });
		expect(existsSync(join(lane(SESSION_ID), LANE_CWD_FILE))).toBe(true);
	}));
}
