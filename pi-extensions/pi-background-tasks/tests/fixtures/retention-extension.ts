import { mock } from "bun:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { existsSync, mkdirSync, readdirSync, unlinkSync, utimesSync, writeFileSync } from "node:fs";
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
const ctx = {
	cwd: process.cwd(), hasUI: false, isProjectTrusted: () => true,
	sessionManager: { getSessionId: () => "retention-session", getSessionFile: () => join(process.cwd(), "session.jsonl"), getBranch: () => [], getEntries: () => [] },
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

// Two lanes a previous run left: one whose worktree is gone, one whose log is old.
const taskDir = process.env.PI_BG_TASK_DIR!;
const goneLane = join(taskDir, "gone-lane");
mkdirSync(goneLane, { recursive: true });
writeFileSync(join(goneLane, ".lane-cwd"), join(process.cwd(), "removed-worktree"));
writeFileSync(join(goneLane, "bg-1-1.log"), "gone");
const oldLane = join(taskDir, "old-lane");
mkdirSync(oldLane, { recursive: true });
writeFileSync(join(oldLane, ".lane-cwd"), process.cwd());
writeFileSync(join(oldLane, "bg-1-1.log"), "old");
writeFileSync(join(oldLane, "bg-2-2.log"), "fresh");
const past = (Date.now() - LANE_FILE_MAX_AGE_MS - 60_000) / 1000;
utimesSync(join(oldLane, "bg-1-1.log"), past, past);

const { default: backgroundTasks } = await import("../../extensions/background-tasks.js");
backgroundTasks(pi);
await dispatch("session_start");
const pruned = { goneLane: existsSync(goneLane), oldLane: readdirSync(oldLane).sort() };

const spawned = MAX_FINISHED_TASKS + 5;
for (let i = 1; i <= spawned; i++) {
	await execute({ action: "spawn", command: `printf out-${i}`, notifyOnExit: false });
	const deadline = Date.now() + 10_000;
	// A real child exits on its own; poll until its close event finalized it.
	while ((await execute({ action: "log", id: `bg-${i}` })).details.task!.status === "running") {
		if (Date.now() > deadline) throw new Error(`retention_fixture.task_running=bg-${i}`);
		await new Promise((resolve) => setTimeout(resolve, 10));
	}
}
const listedTasks = (await execute({ action: "list" })).details.tasks as unknown as Record<string, unknown>[] | { counts: { tasks: number } };
const listedCount = Array.isArray(listedTasks) ? listedTasks.length : listedTasks.counts.tasks;
const newest = (await execute({ action: "log", id: `bg-${spawned}` })).details.task!;
const laneDir = join(taskDir, "retention-session");
const logsBeforeClear = readdirSync(laneDir).filter((name) => name.endsWith(".log")).length;
// A finished task's output is read from its log: with the log gone, nothing is left in memory.
unlinkSync(newest.logFile as string);
const newestLog = (await execute({ action: "log", id: newest.id })).content[0]!.text;
await execute({ action: "clear" });
const logsAfterClear = readdirSync(laneDir).filter((name) => name.endsWith(".log")).length;
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
}));
