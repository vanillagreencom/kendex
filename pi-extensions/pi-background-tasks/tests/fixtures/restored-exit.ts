import { mock } from "bun:test";
import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const unused = () => { throw new Error("restored-exit reached an unrelated operation"); };
mock.module("@earendil-works/pi-ai", () => ({ StringEnum: (values: string[]) => ({ enum: values }) }));
mock.module("typebox", () => ({ Type: { Object: (value: unknown) => value, Optional: (value: unknown) => value, Number: () => ({}), String: () => ({}), Boolean: () => ({}) } }));
mock.module("@earendil-works/pi-tui", () => ({ matchesKey: unused, truncateToWidth: unused, visibleWidth: unused, wrapTextWithAnsi: unused }));
mock.module("@earendil-works/pi-coding-agent", () => ({ getShellConfig: unused }));
const { default: backgroundTasks } = await import("../../extensions/background-tasks.js");
const events = new Map<string, (event: unknown, ctx: ExtensionContext) => unknown>();
let clear: (() => Promise<unknown>) | undefined;
const tails: string[] = [];
const pi = {
	on: (name: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) => events.set(name, handler),
	registerTool: (tool: { name: string; execute(id: string, params: unknown): Promise<unknown> }) => {
		if (tool.name === "bg_task") clear = () => tool.execute("clear", { action: "clear" });
	},
	registerCommand() {}, registerShortcut() {}, registerMessageRenderer() {}, appendEntry() {},
	sendMessage: (message: { details: { outputTail: string } }) => tails.push(message.details.outputTail),
} as unknown as ExtensionAPI;
backgroundTasks(pi);
const rows = ["delivered", "clear", "shutdown"] as const;
for (const action of rows) {
	const logFile = `${process.cwd()}/${action}.log`;
	const output = "x".repeat(4000) + "TAIL";
	await writeFile(logFile, output);
	const task = {
		id: "bg-1", command: "restored", cwd: process.cwd(), exitCode: 0, exitNotified: false,
		logFile, notifyOnExit: true, notifyOnOutput: false, outputBytes: output.length,
		pid: 0, sessionId: action, startedAt: 1, status: "completed", title: "restored", updatedAt: 1,
	};
	const ctx = {
		cwd: process.cwd(), hasUI: false, isProjectTrusted: () => true,
		sessionManager: { getSessionId: () => action, getSessionFile: () => null, getBranch: () => [{ type: "custom", customType: "kendex-background-tasks:state", data: { tasks: [task] } }] },
		ui: { notify() {}, setWidget() {} },
	} as unknown as ExtensionContext;
	await events.get("session_start")!({}, ctx);
	if (action === "clear") await clear!();
	if (action === "shutdown") await events.get("session_shutdown")!({}, ctx);
	// A real asynchronous file read must complete before observing its wake.
	for (let waited = 0; waited < 100 && (action !== "delivered" || tails.length === 0); waited += 1) await Bun.sleep(1);
	assert.equal(tails.length, 1, action);
	assert.ok(tails[0].endsWith("TAIL"));
	assert.equal(tails[0].length, 2000);
	if (action !== "shutdown") await events.get("session_shutdown")!({}, ctx);
}
process.stdout.write(JSON.stringify({ delivered: tails.length }));
