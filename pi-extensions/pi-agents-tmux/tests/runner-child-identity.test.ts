import { describe, expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import {
	runSingleAgent,
	setSingleAgentSpawnForTests,
} from "../extensions/subagent/runner.js";
import type { SingleResult, SubagentDetails } from "../extensions/subagent/types.js";

function tempRuntime(): string {
	return mkdtempSync(join(tmpdir(), "pi-agents-runner-env-"));
}

function makeDetails(results: SingleResult[]): SubagentDetails {
	return { mode: "single", agentScope: "project", projectAgentsDir: null, results };
}

function mockPiEvents() {
	return {
		getActiveTools: () => [],
		events: { emit: () => undefined },
	} as any;
}

function captureSpawnedEnv(scenarios: Array<{ code: number; stdout?: string }>): Array<NodeJS.ProcessEnv | undefined> {
	const envs: Array<NodeJS.ProcessEnv | undefined> = [];
	setSingleAgentSpawnForTests(((command: string, args: string[], options?: { env?: NodeJS.ProcessEnv }) => {
		void command;
		void args;
		envs.push(options?.env);
		const proc = new EventEmitter() as any;
		proc.stdout = new EventEmitter();
		proc.stderr = new EventEmitter();
		proc.killed = false;
		proc.kill = () => { proc.killed = true; return true; };
		const scenario = scenarios.shift() ?? { code: 0 };
		queueMicrotask(() => {
			if (scenario.stdout) proc.stdout.emit("data", Buffer.from(scenario.stdout));
			proc.emit("close", scenario.code, null);
		});
		return proc;
	}) as any);
	return envs;
}

function agent(name: string, color?: string): AgentConfig {
	return {
		name,
		description: `${name} test agent`,
		pane: false,
		systemPrompt: "",
		source: "project",
		filePath: `${name}.md`,
		color,
	};
}

describe("bg one-shot runner exports child identity env (issue #228)", () => {
	test("PI_SUBAGENT_CHILD_AGENT is set to the target agent name", async () => {
		const envs = captureSpawnedEnv([{ code: 0 }]);
		try {
			await runSingleAgent(
				tempRuntime(),
				tempRuntime(),
				[agent("scout")],
				"scout",
				"map the unknown",
				undefined,
				undefined,
				undefined,
				undefined,
				mockPiEvents(),
				undefined,
				undefined,
				makeDetails,
			);
			expect(envs).toHaveLength(1);
			expect(envs[0]?.PI_SUBAGENT_CHILD_AGENT).toBe("scout");
		} finally {
			setSingleAgentSpawnForTests();
		}
	});

	test("PI_SUBAGENT_CHILD_COLOR is exported when the agent has a color", async () => {
		const envs = captureSpawnedEnv([{ code: 0 }]);
		try {
			await runSingleAgent(
				tempRuntime(),
				tempRuntime(),
				[agent("scout", "cyan")],
				"scout",
				"recon",
				undefined,
				undefined,
				undefined,
				undefined,
				mockPiEvents(),
				undefined,
				undefined,
				makeDetails,
			);
			expect(envs[0]?.PI_SUBAGENT_CHILD_COLOR).toBe("cyan");
		} finally {
			setSingleAgentSpawnForTests();
		}
	});

	test("bridge env vars (PI_BRIDGE_*) and PI_SUBAGENT_PARENT_SESSION_ID are stripped even when set in parent", async () => {
		// Issue #228 post-verification: bridge workaround is pane-oriented; bg
		// children must not bleed bridge session/role. Regression guard against
		// the pre-PR review round-1 finding — the earlier test pre-cleared
		// these vars, so a `{...process.env, PI_SUBAGENT_CHILD_AGENT: ...}`
		// spread that *didn't* delete them was still passing.
		const envs = captureSpawnedEnv([{ code: 0 }]);
		const previousParent = process.env.PI_BRIDGE_PARENT_SESSION_ID;
		const previousChild = process.env.PI_BRIDGE_CHILD_ROLE;
		const previousSession = process.env.PI_SUBAGENT_PARENT_SESSION_ID;
		const previousExtraBridge = process.env.PI_BRIDGE_SOCKET_PATH;
		try {
			// Set sentinel values BEFORE spawn so the test actually exercises
			// the strip path. If runner.ts ever drops the explicit deletes,
			// these sentinels would otherwise leak through.
			process.env.PI_BRIDGE_PARENT_SESSION_ID = "sentinel-parent";
			process.env.PI_BRIDGE_CHILD_ROLE = "sentinel-role";
			process.env.PI_SUBAGENT_PARENT_SESSION_ID = "sentinel-session";
			process.env.PI_BRIDGE_SOCKET_PATH = "/tmp/sentinel-socket";
			await runSingleAgent(
				tempRuntime(),
				tempRuntime(),
				[agent("scout")],
				"scout",
				"recon",
				undefined,
				undefined,
				undefined,
				undefined,
				mockPiEvents(),
				undefined,
				undefined,
				makeDetails,
			);
			expect(envs[0]?.PI_BRIDGE_PARENT_SESSION_ID).toBeUndefined();
			expect(envs[0]?.PI_BRIDGE_CHILD_ROLE).toBeUndefined();
			expect(envs[0]?.PI_SUBAGENT_PARENT_SESSION_ID).toBeUndefined();
			// Any other PI_BRIDGE_* var must also be stripped, not just the
			// two named ones.
			expect(envs[0]?.PI_BRIDGE_SOCKET_PATH).toBeUndefined();
		} finally {
			setSingleAgentSpawnForTests();
			if (previousParent === undefined) delete process.env.PI_BRIDGE_PARENT_SESSION_ID;
			else process.env.PI_BRIDGE_PARENT_SESSION_ID = previousParent;
			if (previousChild === undefined) delete process.env.PI_BRIDGE_CHILD_ROLE;
			else process.env.PI_BRIDGE_CHILD_ROLE = previousChild;
			if (previousSession === undefined) delete process.env.PI_SUBAGENT_PARENT_SESSION_ID;
			else process.env.PI_SUBAGENT_PARENT_SESSION_ID = previousSession;
			if (previousExtraBridge === undefined) delete process.env.PI_BRIDGE_SOCKET_PATH;
			else process.env.PI_BRIDGE_SOCKET_PATH = previousExtraBridge;
		}
	});

	test("PI_SUBAGENT_CHILD_COLOR is cleared when the parent had it set but the agent has no color", async () => {
		const envs = captureSpawnedEnv([{ code: 0 }]);
		const previous = process.env.PI_SUBAGENT_CHILD_COLOR;
		try {
			process.env.PI_SUBAGENT_CHILD_COLOR = "magenta";
			await runSingleAgent(
				tempRuntime(),
				tempRuntime(),
				[agent("scout")],
				"scout",
				"recon",
				undefined,
				undefined,
				undefined,
				undefined,
				mockPiEvents(),
				undefined,
				undefined,
				makeDetails,
			);
			expect(envs[0]?.PI_SUBAGENT_CHILD_COLOR).toBeUndefined();
		} finally {
			setSingleAgentSpawnForTests();
			if (previous === undefined) delete process.env.PI_SUBAGENT_CHILD_COLOR;
			else process.env.PI_SUBAGENT_CHILD_COLOR = previous;
		}
	});
});
