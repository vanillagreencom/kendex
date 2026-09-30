import { expect, test } from "bun:test";
import { cpSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { CONFIG_ID, registerRendered, useIsolatedGitEnv } from "../../../pi-hooks/tests/harness.ts";
import { runBatchSession } from "./helpers/pi-batch.js";
import { useWorld } from "./helpers/world.js";

useIsolatedGitEnv();
const world = useWorld();
const renderer = join(import.meta.dir, "../..");

for (const batched of [false, true]) {
	test(`PreToolUse refuses ${batched ? "batched" : "direct"} bash in a real Pi session`, async () => {
		const { cwd, agent } = world();
		registerRendered(agent, "tool_call", "Bash", "cat >/dev/null; echo 'guard=refused' >&2; exit 2");
		writeFileSync(join(agent, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { [CONFIG_ID]: { enabled: true, sessionDriftCheck: false } } } } }));
		const result = await runBatchSession({ cwd, agentDir: agent, renderer, batched });
		const text = result.content.map((part) => part.type === "text" ? part.text : "").join("");
		expect(result.isError).toBe(true);
		expect(text).toContain("guard=refused");
		expect(text).not.toContain("child-ran");
	});
}

test("must-fail control: direct child execution makes the guard regression red", async () => {
	const { cwd, agent, root } = world();
	registerRendered(agent, "tool_call", "Bash", "cat >/dev/null; echo 'guard=refused' >&2; exit 2");
	writeFileSync(join(agent, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { [CONFIG_ID]: { enabled: true, sessionDriftCheck: false } } } } }));
	const copy = join(root, "renderer-copy");
	cpSync(renderer, copy, { recursive: true, filter: (path) => !path.includes("node_modules") && !path.includes("__tests__") });
	const path = join(copy, "extensions/tool-renderer/batch.ts");
	const source = readFileSync(path, "utf8");
	const guarded = "context.executeTool(call.tool, call.args, { signal: childController.signal })";
	expect(source.split(guarded)).toHaveLength(2);
	// Restore the bypass in a disposable copy, not in the tracked implementation.
	const mutant = source.replace(guarded, '(async () => ({ result: await (await import("@earendil-works/pi-coding-agent")).createBashTool(effectiveCwd).execute(`${_toolCallId}:${index}`, call.args, childController.signal, undefined, context), isError: false }))()');
	expect(mutant).not.toBe(source);
	writeFileSync(path, mutant);
	const result = await runBatchSession({ cwd, agentDir: agent, renderer: copy, batched: true });
	const text = result.content.map((part) => part.type === "text" ? part.text : "").join("");
	expect(text).toContain("child-ran");
	expect(() => expect(result.isError).toBe(true)).toThrow();
	expect(() => expect(text).toContain("guard=refused")).toThrow();
});
