// The package's session files on disk: the saved-state directory's byte
// bound, its temporary-file cleanup, and lane retention of the session's
// directory (scripts/lane-retention.ts).
import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { clearPackageConfigCache } from "../extensions/package-config.js";
import { fakeCtx, fakePi, mockPiModules } from "./lib/fake-pi.ts";

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
