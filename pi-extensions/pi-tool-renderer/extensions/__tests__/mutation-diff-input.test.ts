import { expect, test } from "bun:test";
import { chmodSync, readFileSync, truncateSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import * as agent from "@earendil-works/pi-coding-agent";

import { MAX_DIFF_INPUT_BYTES, readDiffSnapshot } from "../tool-renderer/diff.js";
import { registerEdit, registerWrite } from "../tool-renderer/tools.js";
import { useWorld } from "./helpers/world.js";

const world = useWorld();
const theme = { fg: (_tone: string, text: string) => text, bg: (_tone: string, text: string) => text, bold: (text: string) => text };

function registered(register: typeof registerEdit, host: object, cwd: string): any {
	const tools: any[] = [];
	register({ registerTool: (tool: any) => tools.push(tool) } as any, host, cwd);
	expect(tools.length).toBe(1);
	return tools[0];
}

function rendered(component: any): string {
	return component.render(200).join("\n");
}

test("an oversized file is refused on its size, before any read", async () => {
	expect(process.getuid?.()).not.toBe(0);
	const { cwd } = world();
	const path = join(cwd, "big.txt");
	writeFileSync(path, "");
	truncateSync(path, MAX_DIFF_INPUT_BYTES + 1);
	chmodSync(path, 0o000);
	// A read before the size check fails on the permission, not the size.
	expect(await readDiffSnapshot("big.txt", cwd)).toEqual({ kind: "skipped", reason: "over 700 KB" });
});

test("snapshots name an absent file and carry a small file's text", async () => {
	const { cwd } = world();
	writeFileSync(join(cwd, "small.txt"), "a\n");
	expect(await readDiffSnapshot("missing.txt", cwd)).toEqual({ kind: "absent" });
	expect(await readDiffSnapshot("small.txt", cwd)).toEqual({ kind: "text", text: "a\n" });
});

const oversized = "x".repeat(MAX_DIFF_INPUT_BYTES + 1);

for (const [name, patch, expected] of [
	["a small patch builds the diff", "--- absent.txt\n+++ absent.txt\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n", { kendexDiff: { additions: 1, removals: 1, path: "absent.txt" } }],
	["a patch over the cap is skipped", `--- absent.txt\n+++ absent.txt\n@@ -1 +1 @@\n-old\n+${oversized}\n`, { kendexDiffSkipped: "over 700 KB" }],
] as const) {
	test(`edit takes Pi's patch and reads no file of its own: ${name}`, async () => {
		const { cwd } = world();
		const edit = { description: "fixture", parameters: {}, execute: async () => ({ content: [], details: { diff: "", patch } }) };
		const tool = registered(registerEdit, { createEditTool: () => edit }, cwd);
		const result = await tool.execute("call", { path: "absent.txt", edits: [] }, undefined, undefined, { cwd });
		expect(result.details).toMatchObject(expected);
		expect(Object.keys(result.details).filter((key) => key.startsWith("kendexDiff"))).toEqual(Object.keys(expected));
	});
}

test("edit through Pi's own tool renders Pi's patch", async () => {
	const { cwd } = world();
	writeFileSync(join(cwd, "a.txt"), "keep\nold\n");
	const tool = registered(registerEdit, agent, cwd);
	const result = await tool.execute("call", { path: "a.txt", edits: [{ oldText: "old", newText: "new" }] }, undefined, undefined, { cwd });
	expect(result.details.kendexDiff.lines.map((line: any) => `${line.type}:${line.content}`)).toEqual(["ctx:keep", "del:old", "add:new"]);
});

for (const [name, before, content] of [
	["an oversized file", MAX_DIFF_INPUT_BYTES + 1, "small\n"],
	["oversized content", 6, oversized],
] as const) {
	test(`a write of ${name} reports the skipped diff and keeps the write label`, async () => {
		const { cwd } = world();
		const path = join(cwd, "big.txt");
		writeFileSync(path, "");
		truncateSync(path, before);
		const tool = registered(registerWrite, agent, cwd);
		const args = { path: "big.txt", content };
		const result = await tool.execute("call", args, undefined, undefined, { cwd });
		expect(readFileSync(path, "utf8")).toBe(content);
		expect(result.details).toMatchObject({ kendexDiffSkipped: "over 700 KB", kendexDiffWasNewFile: false });
		expect(result.details.kendexDiff).toBeUndefined();
		const row = rendered(tool.renderResult(result, { expanded: false, isPartial: false }, theme, { args, cwd, isError: false }));
		expect(row).toContain("Write big.txt");
		expect(row).toContain("diff skipped: over 700 KB");
	});
}

for (const [name, size, expected] of [
	["a small file shows the preview", 4, "Write a.txt · preview"],
	["an oversized file reports the skipped diff", MAX_DIFF_INPUT_BYTES + 1, "Write a.txt · 1 lines · diff skipped: over 700 KB"],
] as const) {
	test(`the write call preview reads the old file off the render path, then redraws: ${name}`, async () => {
		const { cwd } = world();
		const path = join(cwd, "a.txt");
		writeFileSync(path, "");
		truncateSync(path, size);
		const tool = registered(registerWrite, agent, cwd);
		const args = { path: "a.txt", content: "new\n" };
		let redrawn!: () => void;
		const redraw = new Promise<void>((resolve) => { redrawn = resolve; });
		const context = { args, argsComplete: true, cwd, executionStarted: true, isPartial: true, state: {} as Record<string, unknown>, toolCallId: `preview-${size}`, invalidate: () => redrawn() };

		const pending = rendered(tool.renderCall(args, theme, context));
		expect(pending).not.toContain("preview");
		expect(pending).not.toContain("diff skipped");
		await redraw;
		expect(rendered(tool.renderCall(args, theme, context))).toContain(expected);

		tool.renderCall(args, theme, { ...context, isPartial: false });
		expect(context.state.kendexWriteSnapshot).toBeUndefined();
	});
}
