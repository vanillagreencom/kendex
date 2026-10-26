import { expect, test } from "bun:test";
import { chmodSync, readFileSync, truncateSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import * as agent from "@earendil-works/pi-coding-agent";

import { attachDiffDetails, MAX_DIFF_INPUT_BYTES, readDiffSnapshot, textSnapshot } from "../tool-renderer/diff.js";
import { createEditRenderers, createWriteRenderers } from "../tool-renderer/tools.js";
import { useWorld } from "./helpers/world.js";

const world = useWorld();
const theme = { fg: (_tone: string, text: string) => text, bg: (_tone: string, text: string) => text, bold: (text: string) => text };


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
	["a patch over the cap is skipped", `--- absent.txt\n+++ absent.txt\n@@ -1 +1 @@\n-over-cap-deletion-sentinel\n+${oversized}\n`, { kendexDiffSkipped: "over 700 KB" }],
] as const) {
	test(`edit takes Pi's patch and reads no file of its own: ${name}`, async () => {
		const { cwd } = world();
		const edit = { description: "fixture", parameters: {}, execute: async () => ({ content: [], details: { diff: "", patch } }) };
		const tool = createEditRenderers(cwd);
		const result = await edit.execute();
		const original = structuredClone(result);
		const lines = rendered(tool.renderResult!(result, { expanded: true, isPartial: false }, theme as any, { args: { path: "absent.txt" }, cwd, state: {} } as any));
		expect(result).toEqual(original);
		if ("kendexDiff" in expected) {
			expect(lines).toContain("old");
			expect(lines).toContain("new");
		} else expect(lines).not.toContain("over-cap-deletion-sentinel");
	});
}

test("edit through Pi's own tool renders Pi's patch", async () => {
	const { cwd } = world();
	writeFileSync(join(cwd, "a.txt"), "keep\nold\n");
	const tool = createEditRenderers(cwd);
	const result = await agent.createEditTool(cwd).execute("call", { path: "a.txt", edits: [{ oldText: "old", newText: "new" }] }, undefined, undefined, { cwd } as any);
	const before = structuredClone(result);
	const lines = rendered(tool.renderResult!(result, { expanded: true, isPartial: false }, theme as any, { args: { path: "a.txt" }, cwd, state: {} } as any));
	expect(lines).toContain("old");
	expect(lines).toContain("new");
	expect(result).toEqual(before);
});

for (const [name, before, content] of [
	["an oversized file", MAX_DIFF_INPUT_BYTES + 1, "small\n"],
	["oversized content", 6, oversized],
] as const) {
	test(`write drawing reports skipped metadata for ${name} and keeps the write label`, async () => {
		const { cwd } = world();
		const path = join(cwd, "big.txt");
		writeFileSync(path, "");
		truncateSync(path, before);
		const tool = createWriteRenderers(cwd);
		const args = { path: "big.txt", content };
		const beforeSnapshot = await readDiffSnapshot(args.path, cwd);
		const native = await agent.createWriteTool(cwd).execute("call", args, undefined, undefined, { cwd } as any);
		const result = attachDiffDetails({ ...native }, beforeSnapshot, textSnapshot(content), args.path);
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
		const tool = createWriteRenderers(cwd);
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
