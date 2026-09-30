import { beforeEach, expect, test } from "bun:test";
import type { ExtensionAPI, Theme, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { newStackItem, renderStackItemText, setStackItemResultText } from "../tool-renderer/stack.js";
import { commandExit } from "../tool-renderer/text.js";
import { registerBash } from "../tool-renderer/tools.js";
import { useWorld } from "./helpers/world.js";

const world = useWorld();
const theme = { fg: (color: string, text: string) => `[${color}]${text}[/]`, bold: (text: string) => text } as Theme;
let definition: ToolDefinition;
beforeEach(() => {
	registerBash({ registerTool: (tool: ToolDefinition) => { definition = tool; } } as ExtensionAPI, {
		createBashTool: () => ({ description: "fixture", parameters: {}, execute: async () => ({ content: [] }) }),
	}, world().cwd);
});

const cases = [
	{ name: "success", text: "hello", isError: false, status: "exit 0" },
	{ name: "success mentioning an exit code", text: "the manual says exit 99", isError: false, status: "exit 0" },
	{ name: "success printing Pi's footer", text: "Command exited with code 99", isError: false, status: "exit 0" },
	{ name: "nonzero exit", text: "failure\n\nCommand exited with code 23", isError: true, status: "exit 23" },
	{ name: "timeout", text: "Command timed out after 1 seconds", isError: true, status: "failed" },
	{ name: "cancellation", text: "Command aborted", isError: true, status: "failed" },
];
for (const row of cases) {
	test(`standalone status: ${row.name}`, () => {
		const output = definition.renderResult!(
			{ content: [{ type: "text", text: row.text }], details: undefined },
			{ expanded: false, isPartial: false }, theme,
			{ args: { command: "probe" }, cwd: world().cwd, state: {}, isError: row.isError, toolCallId: row.name,
				executionStarted: true, argsComplete: true, isPartial: false, expanded: false, showImages: false, invalidate() {} },
		).render(200).join("\n");
		expect(output).toContain(`[${row.isError ? "error" : "success"}]${row.status}[/]`);
	});
	test(`grouped status: ${row.name}`, () => {
		const item = newStackItem("bash", row.name, { command: "probe" }, "batch");
		setStackItemResultText(item, row.text, row.isError, false);
		const output = renderStackItemText(item, theme, false, world().cwd);
		expect(output).toContain(row.isError ? "[error]failed[/]" : "[success]exit 0[/]");
	});
}

for (const [text, expected] of [
	["output\n\nCommand exited with code 23", 23],
	["output\r\n\r\nCommand exited with code 23\r\n", 23],
	["the manual says exit 99", null],
	["Command exited with code 23\nmore output", null],
] as const) {
	test(`exit footer: ${JSON.stringify(text)}`, () => expect(commandExit(text)).toBe(expected));
}
