import { expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { registerToolBatch } from "../tool-renderer/batch.js";
import { useWorld } from "./helpers/world.js";

const world = useWorld();
for (const row of [
	// The call schema permits an item without tool/name; normalization drops it.
	{ name: "empty normalized calls", calls: [{}], max: 8, executeTool: undefined, expected: "batch_calls=0", failed: 0, isError: true },
	{ name: "configured call limit", calls: [{ tool: "read" }, { tool: "read" }], max: 1, executeTool: undefined, expected: "batch_calls=2 max_calls=1", failed: 2, isError: true },
	// Pi returns failed outcomes for blocked, unknown, and invalid child calls.
	{ name: "SDK child refusal", calls: [{ tool: "read" }], max: 8, executeTool: async () => ({ result: { content: [{ type: "text", text: "child=refused" }] }, isError: true }), expected: "child=refused", failed: 1, isError: true },
	{ name: "execution API error", calls: [{ tool: "read" }], max: 8, executeTool: async () => { throw new TypeError("upstream-payload"); }, expected: "batch_error=TypeError", failed: 1, isError: true },
]) {
	test(`tool_batch refusal: ${row.name}`, async () => {
		const { cwd } = world();
		writeFileSync(join(cwd, ".pi", "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-tool-renderer": { batchMaxCalls: row.max } } } } }));
		let definition: { execute: (...args: unknown[]) => Promise<{ content: Array<{ text: string }>; isError?: boolean; details: { failed: number; items: Array<{ resultText: string }> } }>; renderResult: (...args: any[]) => { render: (width: number) => string[] } } | undefined;
		registerToolBatch({ registerTool: (tool: typeof definition) => { definition = tool; } } as never, cwd);
		expect(definition).toBeDefined();
		const result = await definition!.execute("batch-refusal", { calls: row.calls }, undefined, undefined, { cwd, executeTool: row.executeTool });
		expect(result.isError).toBe(row.isError);
		expect(result.details.failed).toBe(row.failed);
		expect((result.details.items[0]?.resultText ?? result.content[0]!.text).split("\n")[0]).toBe(row.expected);
		if (result.details.items.length === 0) {
			const rendered = definition!.renderResult(result, { expanded: false, isPartial: false }, { bold: (text: string) => text, fg: (_token: string, text: string) => text }, { cwd }).render(100);
			expect(rendered[0]).toBe(row.expected);
		}
	});
}
