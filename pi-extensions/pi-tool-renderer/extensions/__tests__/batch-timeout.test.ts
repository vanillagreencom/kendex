import { afterEach, expect, jest, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { registerToolBatch } from "../tool-renderer/batch.js";
import { useWorld } from "./helpers/world.js";

const world = useWorld();
afterEach(() => jest.useRealTimers());

for (const row of [
	{ name: "configured deadline with successful siblings", timeout: 1000, calls: [{ tool: "bash", args: {} }, { tool: "read", args: { path: "wedged.md" } }, { tool: "grep", args: { pattern: "foo" } }], succeeded: 2 },
	{ name: "minimum deadline", timeout: 1, calls: [{ tool: "read", args: { path: "x" } }], succeeded: 0 },
]) {
	test(`tool_batch: ${row.name}`, async () => {
		const { cwd } = world();
		writeFileSync(join(cwd, ".pi", "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-tool-renderer": { batchCallTimeoutMs: row.timeout } } } } }));
		jest.useFakeTimers();
		let aborts = 0;
		const agent = {
			createReadTool: () => ({ execute: (_id: string, _args: unknown, signal: AbortSignal) => new Promise<never>((_resolve, reject) => {
				signal.addEventListener("abort", () => { aborts++; reject(new DOMException("", "AbortError")); }, { once: true });
			}) }),
			createBashTool: () => ({ execute: async () => ({ content: [{ type: "text", text: "ok-bash" }], isError: false }) }),
			createGrepTool: () => ({ execute: async () => ({ content: [{ type: "text", text: "ok-grep" }], isError: false }) }),
		};
		let definition: { execute: (...args: unknown[]) => Promise<{ content: Array<{ text: string }>; isError?: boolean; details: { total: number; failed: number; succeeded: number; items: Array<{ toolName: string; isError: boolean; resultText: string }> } }> } | undefined;
		registerToolBatch({ registerTool: (tool: typeof definition) => { definition = tool; } } as never, agent, cwd);
		expect(definition).toBeDefined();
		let settled = false;
		const pending = definition!.execute("batch-1", { calls: row.calls }, undefined, undefined, { cwd }).then((value) => { settled = true; return value; });
		await Promise.resolve();
		jest.advanceTimersByTime(999);
		await Promise.resolve();
		expect(settled).toBe(false);
		expect(aborts).toBe(0);
		jest.advanceTimersByTime(1);
		await Promise.resolve();
		expect(aborts).toBe(1);
		const result = await pending;
		expect(result.details.total).toBe(row.calls.length);
		expect(result.details.succeeded).toBe(row.succeeded);
		expect(result.details.failed).toBe(1);
		expect(result.isError).toBe(true);
		expect(result.content[0]!.text.split("\n")[0]).toBe(`batch_succeeded=${row.succeeded} batch_total=${row.calls.length}`);
		for (const item of result.details.items) {
			expect(item.isError).toBe(item.toolName === "read");
			expect(item.resultText.split("\n")[0]).toBe(item.toolName === "read" ? "batch_timeout_ms=1000 tool=read" : `ok-${item.toolName}`);
		}
		expect(jest.getTimerCount()).toBe(0);
	});
}
