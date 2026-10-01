import assert from "node:assert/strict";
import test, { after, afterEach } from "node:test";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { editAgentFrontmatterOverrides } from "../extensions/subagent/browser/frontmatter-editor.js";
import { setPaneExecCaptureForTests } from "../extensions/subagent/pane.js";
import { agent, cleanupTempRuntimes, importRuntimeCopy, tempRuntime } from "./browser-fixture.js";

after(cleanupTempRuntimes);
afterEach(() => setPaneExecCaptureForTests());

async function asynchronousSave(edit: typeof editAgentFrontmatterOverrides): Promise<void> {
	const cwd = tempRuntime();
	const dir = join(cwd, ".pi", "agents");
	mkdirSync(dir, { recursive: true });
	const filePath = join(dir, "engineer.md");
	writeFileSync(filePath, "---\nname: engineer\n---\nNever edit this file directly; kendex refresh regenerates it.\n");
	writeFileSync(join(cwd, "kendex.toml"), "");
	let refreshReady!: () => void;
	const ready = new Promise<void>((resolve) => { refreshReady = resolve; });
	let complete!: () => void;
	setPaneExecCaptureForTests(async (command, args, options) => {
		assert.equal(command, "kendex");
		assert.deepEqual(args, ["refresh", "--scope", "project"]);
		assert.equal(options?.timeoutMs, 120_000);
		assert.equal(options?.cwd, cwd);
		refreshReady();
		await new Promise<void>((resolve) => { complete = resolve; });
		return { code: 0, stdout: "", stderr: "" };
	});
	const ctx = { cwd, ui: { editor: async () => "model: test/model\ndeny-tools: bash\ncolor: blue" } } as unknown as Parameters<typeof edit>[0];
	let settled = false;
	const saving = edit(ctx, agent("engineer", false, { filePath })).then(() => { settled = true; });
	await ready;
	try {
		await new Promise(setImmediate);
		assert.equal(settled, false, "save must wait for refresh without blocking the event loop");
		assert.match(readFileSync(join(cwd, "kendex.toml"), "utf8"), /model = "test\/model"/);
	} finally { complete(); await saving; }
}

test("managed-agent refresh remains asynchronous and keeps its deadline", async () => {
	await asynchronousSave(editAgentFrontmatterOverrides);
	const mutant = await importRuntimeCopy("browser/frontmatter-editor.ts", "const refresh = await refreshkendexManagedAgent(agent, tomlPath, ctx.signal);", "const refresh = refreshkendexManagedAgent(agent, tomlPath, ctx.signal);") as typeof import("../extensions/subagent/browser/frontmatter-editor.js");
	await assert.rejects(asynchronousSave(mutant.editAgentFrontmatterOverrides), /save must wait/);
});
