import { expect, test } from "bun:test";
import { registerToolBatch } from "../tool-renderer/batch.js";
import { useWorld } from "./helpers/world.js";

const world = useWorld();
const theme = { bold: (text: string) => text, fg: (_token: string, text: string) => text };
const threeLines = { content: [{ type: "text", text: "a\nb\nc" }] };

for (const row of [
	{ tool: "read", args: { path: "a" }, summary: " · 3 lines" },
	{ tool: "bash", args: { command: "echo" }, summary: " · exit 0 · 3 lines" },
	{ tool: "grep", args: { pattern: "x" }, summary: " · 3 results" },
]) {
	test(`a finished tool_batch ${row.tool} row shows its result count`, async () => {
		const { cwd } = world();
		const tool = { execute: async () => threeLines };
		const host = { createReadTool: () => tool, createBashTool: () => tool, createGrepTool: () => tool };
		let definition: { execute: (...args: unknown[]) => Promise<unknown>; renderResult: (...args: any[]) => { render: (width: number) => string[] } } | undefined;
		registerToolBatch({ registerTool: (registered: typeof definition) => { definition = registered; } } as never, host, cwd);
		expect(definition).toBeDefined();
		const result = await definition!.execute("batch-render", { calls: [{ tool: row.tool, args: row.args }] }, undefined, undefined, { cwd });
		const rows = definition!.renderResult(result, { expanded: false, isPartial: false }, theme, { cwd }).render(200);
		expect(rows).toHaveLength(2);
		expect(rows[1]).toEndWith(row.summary);
	});
}
