import { expect, test } from "bun:test";
import type { ExtensionAPI, ExtensionContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { registerBash, registerEdit, registerRead, registerReadOnly, registerWrite } from "../tool-renderer/tools.js";
import { registerToolBatch } from "../tool-renderer/batch.js";
import { useWorld } from "./helpers/world.js";

const world = useWorld();
const registrations = [
	["read", registerRead],
	["bash", registerBash],
	["edit", registerEdit],
	["write", registerWrite],
	["grep", (pi: ExtensionAPI, host: object, cwd: string) => registerReadOnly(pi, host, cwd, "grep")],
	["find", (pi: ExtensionAPI, host: object, cwd: string) => registerReadOnly(pi, host, cwd, "find")],
	["ls", (pi: ExtensionAPI, host: object, cwd: string) => registerReadOnly(pi, host, cwd, "ls")],
] as const;

for (const [name, register] of registrations) {
	test(`${name} forwards the execution context without changing the other arguments`, async () => {
		let received: unknown[] = [];
		let definition: ToolDefinition | undefined;
		const original = {
			description: "fixture",
			parameters: {},
			execute: async (...arguments_: unknown[]) => {
				received = arguments_;
				return { content: [] };
			},
		};
		const host = {
			createReadTool: () => original, createBashTool: () => original,
			createEditTool: () => original, createWriteTool: () => original,
			createGrepTool: () => original, createFindTool: () => original, createLsTool: () => original,
		};
		register({ registerTool: (tool: ToolDefinition) => { definition = tool; } } as ExtensionAPI, host, world().cwd);
		expect(definition).toBeDefined();
		const input = {};
		const signal = new AbortController().signal;
		const onUpdate = () => {};
		const context = { cwd: world().cwd } as ExtensionContext;
		await definition!.execute("call", input, signal, onUpdate, context);
		expect(received).toEqual(["call", input, signal, onUpdate, context]);
		expect(received[4]).toBe(context);
	});

	test(`${name} preserves structured results and accepts tools from Pi below 0.99.0`, async () => {
		for (const structured of [true, false]) {
			let definition: ToolDefinition | undefined;
			const outputSchema = { type: "object", properties: { output: { type: "string" } } };
			const structuredContent = { output: "fixture", truncated: false, full_output_path: null };
			const result = { content: [{ type: "text", text: "fixture" }], ...(structured ? { structuredContent } : {}) };
			const original = {
				description: "fixture",
				parameters: {},
				...(structured ? { outputSchema } : {}),
				execute: async () => result,
			};
			const host = {
				createReadTool: () => original, createBashTool: () => original,
				createEditTool: () => original, createWriteTool: () => original,
				createGrepTool: () => original, createFindTool: () => original, createLsTool: () => original,
			};
			// Each row needs its own cwd because the renderer caches built-in tools by cwd.
			const cwd = `${world().cwd}/${structured ? "structured" : "legacy"}`;
			register({ registerTool: (tool: ToolDefinition) => { definition = tool; } } as ExtensionAPI, host, cwd);
			expect(definition).toBeDefined();
			const returned = await definition!.execute("call", {}, undefined, undefined, { cwd } as ExtensionContext);
			expect(returned).toBe(result);
			expect((returned as unknown as Record<string, unknown>).structuredContent).toBe(structured ? structuredContent : undefined);
			expect((definition as unknown as Record<string, unknown>).outputSchema).toBe(structured ? outputSchema : undefined);
		}
	});

	test(`${name} carries the wrapped tool's request fields onto the replacement`, () => {
		let definition: ToolDefinition | undefined;
		const original = {
			description: "fixture",
			parameters: { type: "object", properties: {} },
			constrainedSampling: { type: "json_schema", strict: "prefer" },
			prepareArguments: (args: unknown) => args,
			execute: async () => ({ content: [] }),
		};
		const host = {
			createReadTool: () => original, createBashTool: () => original,
			createEditTool: () => original, createWriteTool: () => original,
			createGrepTool: () => original, createFindTool: () => original, createLsTool: () => original,
		};
		register({ registerTool: (tool: ToolDefinition) => { definition = tool; } } as ExtensionAPI, host, world().cwd);
		const carried = definition as unknown as Record<string, unknown>;
		for (const field of ["description", "parameters", "constrainedSampling", "prepareArguments"] as const) {
			expect(carried[field]).toBe(original[field]);
		}
	});

	for (const field of ["promptSnippet", "promptGuidelines"] as const) {
		test(`${name} carries ${field} from Pi's tool definition, which the wrapped tool lacks`, () => {
			let definition: ToolDefinition | undefined;
			const original = { description: "fixture", parameters: {}, execute: async () => ({ content: [] }) };
			const piDefinition = { promptSnippet: `${name} snippet`, promptGuidelines: [`${name} guideline`] };
			const host = {
				createReadTool: () => original, createBashTool: () => original,
				createEditTool: () => original, createWriteTool: () => original,
				createGrepTool: () => original, createFindTool: () => original, createLsTool: () => original,
				[`create${name[0]!.toUpperCase()}${name.slice(1)}ToolDefinition`]: () => piDefinition,
			};
			// Its own cwd, because the renderer caches built-in tools by cwd.
			register({ registerTool: (tool: ToolDefinition) => { definition = tool; } } as ExtensionAPI, host, `${world().cwd}/${field}`);
			expect((definition as unknown as Record<string, unknown>)[field]).toBe(piDefinition[field]);
		});
	}
}

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
