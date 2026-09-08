import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import type { AgentConfig } from "../extensions/subagent/agents.js";
import { runPersistentPaneAgent, setPaneExecCaptureForTests } from "../extensions/subagent/pane.js";
import { writePaneRegistry } from "../extensions/subagent/tasks.js";
import { PANE_LAUNCHER_VERSION } from "../extensions/subagent/types.js";

function paneAgent(): AgentConfig {
	return {
		name: "rust",
		description: "Rust engineer",
		pane: true,
		source: "project",
		systemPrompt: "",
		filePath: "rust.md",
	};
}

function runPane(runtimeRoot: string, agents: AgentConfig[], agentName: string, forceSpawn = false) {
	return runPersistentPaneAgent(
		process.cwd(),
		runtimeRoot,
		"parent-session",
		agents,
		agentName,
		"inspect the project",
		undefined,
		undefined,
		undefined,
		undefined,
		{ getActiveTools: () => [] } as Parameters<typeof runPersistentPaneAgent>[9],
		forceSpawn,
	);
}

test("runPersistentPaneAgent returns a stable unknown-agent refusal record", async () => {
	const result = await runPane(process.cwd(), [], "missing-agent");

	assert.equal(result.stderr.split("\n", 1)[0], "unknown_agent=missing-agent");
	assert.equal(result.exitCode, 1);
	assert.equal(result.refused, true);
});

test("runPersistentPaneAgent returns a stable live-pane refusal record", async () => {
	const runtimeRoot = mkdtempSync(join(tmpdir(), "pi-agents-pane-refusal-"));
	try {
		await writePaneRegistry(runtimeRoot, {
			rust: {
				agent: "rust",
				paneId: "%42",
				windowName: "agent:rust",
				cwd: process.cwd(),
				sessionFile: join(runtimeRoot, "sessions", "rust.jsonl"),
				promptFile: join(runtimeRoot, "sessions", "rust.prompt.md"),
				launcherFile: join(runtimeRoot, "sessions", "rust.launcher.sh"),
				launcherVersion: PANE_LAUNCHER_VERSION,
				startedAt: new Date().toISOString(),
			},
		});
		setPaneExecCaptureForTests(async () => ({ code: 0, stdout: "%42\n", stderr: "" }));

		const result = await runPane(runtimeRoot, [paneAgent()], "rust", true);

		assert.equal(result.stderr.split("\n", 1)[0], "pane_already_running=rust");
		assert.equal(result.exitCode, 1);
		assert.equal(result.refused, true);
	} finally {
		setPaneExecCaptureForTests();
		rmSync(runtimeRoot, { recursive: true, force: true });
	}
});
