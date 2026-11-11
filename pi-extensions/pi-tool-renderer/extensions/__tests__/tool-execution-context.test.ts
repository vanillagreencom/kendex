import { expect, test } from "bun:test";
import type { ExtensionAPI, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { registerToolBatch } from "../tool-renderer/batch.js";
import { useWorld } from "./helpers/world.js";

const world = useWorld();

test("tool_batch delegates every child to Pi's execution context", async () => {
	const received: unknown[][] = [];
	let definition: ToolDefinition | undefined;
	registerToolBatch({ registerTool: (tool: ToolDefinition) => { definition = tool; } } as ExtensionAPI, world().cwd);
	expect(definition).toBeDefined();
	const names = ["read", "bash", "grep", "find", "ls"];
	const args = { fixture: "unchanged" };
	const context = {
		cwd: world().cwd,
		executeTool: async (...arguments_: unknown[]) => {
			received.push(arguments_);
			return { result: { content: [] }, isError: false };
		},
	} as unknown as Parameters<ToolDefinition["execute"]>[4];
	const parent = new AbortController();
	await definition!.execute("batch", { calls: names.map((tool) => ({ tool, args })) }, parent.signal, undefined, context);
	expect(received).toHaveLength(names.length);
	for (const [index, arguments_] of received.entries()) {
		expect(arguments_[0]).toBe(names[index]);
		expect(arguments_[1]).toEqual(args);
		expect((arguments_[2] as { signal: AbortSignal }).signal.aborted).toBe(false);
	}
});
