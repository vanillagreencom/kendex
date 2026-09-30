import { mock } from "bun:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, symlinkSync, unlinkSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// Runs the registered extension against real /bin/sh children in this private
// process; the Pi peers are mocked here only, as spawn-extension.ts does.
const unused = () => { throw new Error("retention_fixture.sdk_operation=unexpected_render"); };
mock.module("@earendil-works/pi-ai", () => ({ StringEnum: (values: readonly string[]) => ({ enum: values }) }));
mock.module("typebox", () => ({ Type: { Object: (value: unknown) => value, Optional: (value: unknown) => value, Number: () => ({}), String: () => ({}), Boolean: () => ({}) } }));
mock.module("@earendil-works/pi-tui", () => ({ matchesKey: unused, truncateToWidth: unused, visibleWidth: unused, wrapTextWithAnsi: unused }));
mock.module("@earendil-works/pi-coding-agent", () => ({ getShellConfig: () => ({ shell: "/bin/sh", args: ["-c"] }) }));

const { MAX_FINISHED_TASKS } = await import("../../extensions/constants.js");
const { LANE_FILE_MAX_AGE_MS } = await import("../../scripts/lane-retention.js");

interface ToolResult { content: { type: string; text: string }[]; details: { action: string; task?: Record<string, unknown>; tasks?: Record<string, unknown>[] } }
interface Tool { name: string; execute(id: string, params: Record<string, unknown>): Promise<ToolResult> }
const tools = new Map<string, Tool>();
const events = new Map<string, (event: unknown, ctx: ExtensionContext) => unknown>();
// The session the next event runs in; a forked session sets both.
let sessionId = "retention-session";
let branch: unknown[] = [];
const ctx = {
	cwd: process.cwd(), hasUI: false, isProjectTrusted: () => true,
	sessionManager: { getSessionId: () => sessionId, getSessionFile: () => join(process.cwd(), `${sessionId}.jsonl`), getBranch: () => branch, getEntries: () => branch },
	ui: { notify() {}, setWidget() {} },
} as unknown as ExtensionContext;
const pi = {
	registerTool(tool: Tool) { tools.set(tool.name, tool); },
	registerCommand() {}, registerShortcut() {}, registerMessageRenderer() {},
	on(event: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) { events.set(event, handler); },
	appendEntry() {}, sendMessage() {},
} as unknown as ExtensionAPI;
const dispatch = async (event: string) => { await events.get(event)!({}, ctx); };
const execute = async (params: Record<string, unknown>) => await tools.get("bg_task")!.execute("retention-call", params);

// A small output buffer, so a finished task's log is longer than what is read back.
const settingsPath = join(process.env.PI_CODING_AGENT_DIR!, "settings.json");
const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
settings.kendex.extensionManager.config["@vanillagreen/pi-background-tasks"].outputBufferMaxChars = 64;
writeFileSync(settingsPath, JSON.stringify(settings));

// Two lanes a previous run left: one whose worktree is gone, one whose log is
// old. Beside them, three folders the package did not make, each with a file
// past five days: one in the task directory outside the lanes folder, one in
// the lanes folder with no lane record, and a symbolic link to a folder
// outside the task directory.
const taskDir = process.env.PI_BG_TASK_DIR!;
const lanes = join(taskDir, "lanes");
const past = (Date.now() - LANE_FILE_MAX_AGE_MS - 60_000) / 1000;
const goneCwd = join(process.cwd(), "removed-worktree");
const goneLane = join(lanes, "gone-lane");
mkdirSync(goneLane, { recursive: true });
writeFileSync(join(goneLane, ".lane-cwd"), goneCwd);
writeFileSync(join(goneLane, "bg-1-1.log"), "gone");
const oldLane = join(lanes, "old-lane");
mkdirSync(oldLane, { recursive: true });
writeFileSync(join(oldLane, ".lane-cwd"), process.cwd());
writeFileSync(join(oldLane, "bg-1-1.log"), "old");
writeFileSync(join(oldLane, "bg-2-2.log"), "fresh");
utimesSync(join(oldLane, "bg-1-1.log"), past, past);
const foreign = join(taskDir, "foreign");
mkdirSync(foreign);
writeFileSync(join(foreign, ".lane-cwd"), goneCwd);
writeFileSync(join(foreign, "old.txt"), "foreign");
const unmarked = join(lanes, "unmarked");
mkdirSync(unmarked);
writeFileSync(join(unmarked, "old.log"), "unmarked");
utimesSync(join(unmarked, "old.log"), past, past);
const victim = join(process.cwd(), "victim");
mkdirSync(victim);
writeFileSync(join(victim, ".lane-cwd"), process.cwd());
writeFileSync(join(victim, "old.txt"), "victim");
utimesSync(join(victim, "old.txt"), past, past);
symlinkSync(victim, join(lanes, "planted"));

const { default: backgroundTasks } = await import("../../extensions/background-tasks.js");
backgroundTasks(pi);
await dispatch("session_start");
const pruned = {
	goneLane: existsSync(goneLane),
	oldLane: readdirSync(oldLane).sort(),
	foreign: readdirSync(foreign).sort(),
	unmarked: readdirSync(unmarked).sort(),
	victim: readdirSync(victim).sort(),
};

const waitForExit = async (id: string) => {
	const deadline = Date.now() + 10_000;
	// A real child exits on its own; poll until its close event finalized it.
	while ((await execute({ action: "log", id })).details.task!.status === "running") {
		if (Date.now() > deadline) throw new Error(`retention_fixture.task_running=${id}`);
		await new Promise((resolve) => setTimeout(resolve, 10));
	}
};

const spawned = MAX_FINISHED_TASKS + 5;
for (let i = 1; i <= spawned; i++) {
	await execute({ action: "spawn", command: `printf out-${i}`, notifyOnExit: false });
	await waitForExit(`bg-${i}`);
}
const listedTasks = (await execute({ action: "list" })).details.tasks as unknown as Record<string, unknown>[] | { counts: { tasks: number } };
const listedCount = Array.isArray(listedTasks) ? listedTasks.length : listedTasks.counts.tasks;
const newest = (await execute({ action: "log", id: `bg-${spawned}` })).details.task!;
const laneDir = join(lanes, "retention-session");
const logsBeforeClear = readdirSync(laneDir).filter((name) => name.endsWith(".log")).length;
// A finished task's output is read from its log: with the log gone, nothing is left in memory.
unlinkSync(newest.logFile as string);
const newestLog = (await execute({ action: "log", id: newest.id })).content[0]!.text;
await execute({ action: "clear" });
const logsAfterClear = readdirSync(laneDir).filter((name) => name.endsWith(".log")).length;

// A finished task's output is the end of its log, not the start.
const long = (await execute({ action: "spawn", command: "printf HEAD; printf '%0200d' 0; printf TAIL-END", notifyOnExit: false })).details.task!;
await waitForExit(long.id as string);
const longLog = (await execute({ action: "log", id: long.id })).content[0]!.text;

// A log that stopped taking writes leaves the output in memory as the record.
const unlogged = (await execute({ action: "spawn", command: "sleep 0.3; printf late-output", notifyOnExit: false })).details.task!;
rmSync(unlogged.logFile as string);
mkdirSync(unlogged.logFile as string);
await waitForExit(unlogged.id as string);
const unloggedLog = (await execute({ action: "log", id: unlogged.id })).content[0]!.text;

const parentTask = (await execute({ action: "log", id: long.id })).details.task!;

await dispatch("session_shutdown");
const listedAfterShutdown = (await execute({ action: "list" })).content[0]!.text;

// A fork of this session copies its branch, so it restores this session's
// finished tasks: one past the bound, each with its log in this session's lane.
// The bound at session_start and a clear in the fork forget them, and the
// logs stay.
const parentLogs: string[] = [];
branch = Array.from({ length: MAX_FINISHED_TASKS + 1 }, (_, i) => {
	const logFile = join(laneDir, `bg-${100 + i}-parent.log`);
	writeFileSync(logFile, "parent-output");
	parentLogs.push(logFile);
	const task = { ...parentTask, id: `bg-${100 + i}`, logFile, updatedAt: (parentTask.updatedAt as number) + i };
	return { type: "message", message: { role: "toolResult", toolName: "bg_task", details: { action: "log", task } } };
});
sessionId = "fork-session";
await dispatch("session_start");
const forkListed = ((await execute({ action: "list" })).details.tasks as unknown as unknown[]).length;
await execute({ action: "clear" });
const fork = {
	taskSession: parentTask.sessionId,
	listed: forkListed,
	logsKept: parentLogs.filter((logFile) => existsSync(logFile)).length,
	listedAfterClear: (await execute({ action: "list" })).content[0]!.text,
};
await dispatch("session_shutdown");

process.stdout.write(JSON.stringify({
	pruned,
	spawned,
	listed: listedCount,
	logInLane: (newest.logFile as string).startsWith(`${laneDir}/`),
	laneCwd: existsSync(join(laneDir, ".lane-cwd")),
	logsBeforeClear,
	newestLog,
	logsAfterClear,
	longLog: { tail: longLog.includes("TAIL-END"), head: longLog.includes("HEAD") },
	unloggedLog,
	listedAfterShutdown,
	fork,
}));
