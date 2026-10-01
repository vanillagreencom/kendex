import { mock } from "bun:test";
import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { interceptNativeEffects, fixturePid } from "./spawn-native.js";

const effects = { identityGone: false };
const native = await interceptNativeEffects(effects);
const platform = Object.getOwnPropertyDescriptor(process, "platform")!;
// The native fixture supplies Linux process identity reads for the orphan.
Object.defineProperty(process, "platform", { ...platform, value: "linux" });
const unused = () => { throw new Error("restored-exit reached an unrelated operation"); };
mock.module("@earendil-works/pi-ai", () => ({ StringEnum: (values: string[]) => ({ enum: values }) }));
mock.module("typebox", () => ({ Type: { Object: (value: unknown) => value, Optional: (value: unknown) => value, Number: () => ({}), String: () => ({}), Boolean: () => ({}) } }));
mock.module("@earendil-works/pi-tui", () => ({ matchesKey: unused, truncateToWidth: unused, visibleWidth: unused, wrapTextWithAnsi: unused }));
mock.module("@earendil-works/pi-coding-agent", () => ({ getShellConfig: unused }));
const { default: backgroundTasks } = await import("../../extensions/background-tasks.js");
const events = new Map<string, (event: unknown, ctx: ExtensionContext) => unknown>();
let clear: (() => Promise<unknown>) | undefined;
const tails: { outputTail: string; outputTailTruncated: boolean; eventType: string; task: { terminationReason?: string } }[] = [];
const pi = {
	on: (name: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) => events.set(name, handler),
	registerTool: (tool: { name: string; execute(id: string, params: unknown): Promise<unknown> }) => {
		if (tool.name === "bg_task") clear = () => tool.execute("clear", { action: "clear" });
	},
	registerCommand() {}, registerShortcut() {}, registerMessageRenderer() {}, appendEntry() {},
	sendMessage: (message: { details: (typeof tails)[number] }) => tails.push(message.details),
} as unknown as ExtensionAPI;
backgroundTasks(pi);
const long = "x".repeat(4000) + "TAIL";
const rows = [
	{ action: "delivered", output: long, truncated: true },
	{ action: "short", output: "TAIL", truncated: false },
	{ action: "exact", output: "x".repeat(1996) + "TAIL", truncated: false },
	{ action: "unicode", output: "😀".repeat(1000) + "TAIL", truncated: true },
	{ action: "orphan", output: long, truncated: true },
	{ action: "clear", output: long, truncated: true },
	{ action: "shutdown", output: long, truncated: true },
] as const;
try {
	for (const { action, output, truncated } of rows) {
		effects.identityGone = false;
		const logFile = `${process.cwd()}/${action}.log`;
		await writeFile(logFile, output);
		const before = tails.length;
		const task = {
			id: "bg-1", command: "restored", cwd: process.cwd(), exitCode: 0, exitNotified: false,
			logFile, notifyOnExit: true, notifyOnOutput: false, outputBytes: Buffer.byteLength(output),
			pid: action === "orphan" ? fixturePid : 0, sessionId: action, startedAt: 1,
			status: action === "orphan" ? "running" : "completed", title: "restored", updatedAt: 1,
			procIdent: { pid: fixturePid, comm: "fixture-child", startToken: "12345" },
		};
		const ctx = {
			cwd: process.cwd(), hasUI: false, isProjectTrusted: () => true,
			sessionManager: { getSessionId: () => action, getSessionFile: () => null, getBranch: () => [{ type: "custom", customType: "kendex-background-tasks:state", data: { tasks: [task] } }] },
			ui: { notify() {}, setWidget() {} },
		} as unknown as ExtensionContext;
		await events.get("session_start")!({}, ctx);
		if (action === "clear") await clear!();
		if (action === "shutdown") await events.get("session_shutdown")!({}, ctx);
		if (action === "orphan") {
			assert.equal(tails.length, before, "a live restored orphan must not emit an exit");
			effects.identityGone = true;
			await native.fireInterval(30_000);
		}
		const suppressed = action === "clear" || action === "shutdown";
		// Real asynchronous file reads must finish before testing delivery or suppression.
		for (let waited = 0; waited < 100 && (suppressed || tails.length === before); waited += 1) await Bun.sleep(1);
		assert.equal(tails.length, before + (suppressed ? 0 : 1), action);
		if (!suppressed) {
			const tail = tails[before];
			assert.equal(tail.eventType, "exit");
			assert.ok(tail.outputTail.endsWith("TAIL"));
			assert.equal(tail.outputTailTruncated, truncated, `exit omission metadata: ${action}`);
			assert.equal(tail.outputTail.startsWith("[...truncated]\n"), truncated, `exit omission marker: ${action}`);
			assert.ok(tail.outputTail.length <= 2015);
			if (action === "delivered" || action === "orphan") assert.equal(tail.outputTail, "[...truncated]\n" + "x".repeat(1996) + "TAIL");
			if (!truncated) assert.equal(tail.outputTail, output);
			if (action === "orphan") assert.equal(tail.task.terminationReason, "orphaned-pid-gone");
		}
		if (action !== "shutdown") await events.get("session_shutdown")!({}, ctx);
	}
	process.stdout.write(JSON.stringify({ delivered: tails.length }));
} finally {
	Object.defineProperty(process, "platform", platform);
	native.restore();
}
