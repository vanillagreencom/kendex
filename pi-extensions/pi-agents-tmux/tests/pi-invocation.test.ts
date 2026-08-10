import { describe, expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import { mkdtempSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import {
	assertSubagentSpawnDepth,
	currentSubagentDepth,
	getPiInvocation,
	MAX_SUBAGENT_DEPTH,
	PI_SUBAGENT_DEPTH_ENV,
	PI_SUBAGENT_ENTRY_ENV,
	type PiInvocationRuntime,
} from "../extensions/subagent/pane.js";
import { runSingleAgent, setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import type { SingleResult, SubagentDetails } from "../extensions/subagent/types.js";

function scriptDir(): string {
	return mkdtempSync(join(tmpdir(), "pi-agents-invocation-"));
}

function existingScript(basename: string): string {
	const filePath = join(scriptDir(), basename);
	writeFileSync(filePath, "// test entry\n");
	return filePath;
}

function runtime(overrides: Partial<PiInvocationRuntime>): PiInvocationRuntime {
	return { argv1: undefined, execPath: "/usr/bin/bun", env: {}, ...overrides };
}

describe("getPiInvocation entry resolution (vstack#192)", () => {
	test("harness-like argv[1] (existing non-pi script) does NOT self-re-invoke", () => {
		// The fork-bomb shape: a standalone `bun harness.mjs` imported runner.ts
		// directly, so argv[1] is the harness. Re-invoking it spawns the harness
		// recursively; the resolver must fall back to pi on PATH instead.
		const harness = existingScript("harness.mjs");
		const invocation = getPiInvocation(["--mode", "json"], runtime({ argv1: harness }));
		expect(invocation.command).toBe("pi");
		expect(invocation.args).toEqual(["--mode", "json"]);
		expect(invocation.args).not.toContain(harness);
	});

	test("pi dev-mode entries keep self-re-invoking under the same runtime", () => {
		for (const basename of ["cli.ts", "cli.js", "pi"]) {
			const entry = existingScript(basename);
			const invocation = getPiInvocation(["-p"], runtime({ argv1: entry }));
			expect(invocation.command).toBe("/usr/bin/bun");
			expect(invocation.args).toEqual([entry, "-p"]);
		}
	});

	test("PI_SUBAGENT_ENTRY script override wins over a pi-looking argv[1]", () => {
		const override = existingScript("custom-entry.mjs");
		const argv1 = existingScript("cli.ts");
		const invocation = getPiInvocation(["-p"], runtime({ argv1, env: { [PI_SUBAGENT_ENTRY_ENV]: override } }));
		expect(invocation.command).toBe("/usr/bin/bun");
		expect(invocation.args).toEqual([override, "-p"]);
	});

	test("PI_SUBAGENT_ENTRY executable override is used as the command itself", () => {
		const invocation = getPiInvocation(["-p"], runtime({ env: { [PI_SUBAGENT_ENTRY_ENV]: "/opt/pi/bin/pi" } }));
		expect(invocation.command).toBe("/opt/pi/bin/pi");
		expect(invocation.args).toEqual(["-p"]);
	});

	test("compiled pi binary (/$bunfs argv[1]) still re-invokes execPath directly", () => {
		const invocation = getPiInvocation(["-p"], runtime({ argv1: "/$bunfs/root/cli.js", execPath: "/usr/lib/pi/pi" }));
		expect(invocation.command).toBe("/usr/lib/pi/pi");
		expect(invocation.args).toEqual(["-p"]);
	});
});

describe("PI_SUBAGENT_DEPTH recursion guard (vstack#192)", () => {
	test("currentSubagentDepth parses the env var defensively", () => {
		expect(currentSubagentDepth({})).toBe(0);
		expect(currentSubagentDepth({ [PI_SUBAGENT_DEPTH_ENV]: "2" })).toBe(2);
		expect(currentSubagentDepth({ [PI_SUBAGENT_DEPTH_ENV]: "banana" })).toBe(0);
		expect(currentSubagentDepth({ [PI_SUBAGENT_DEPTH_ENV]: "-4" })).toBe(0);
	});

	test("assertSubagentSpawnDepth increments below the cap and refuses at it", () => {
		expect(assertSubagentSpawnDepth({})).toBe(1);
		expect(assertSubagentSpawnDepth({ [PI_SUBAGENT_DEPTH_ENV]: String(MAX_SUBAGENT_DEPTH - 1) })).toBe(MAX_SUBAGENT_DEPTH);
		expect(() => assertSubagentSpawnDepth({ [PI_SUBAGENT_DEPTH_ENV]: String(MAX_SUBAGENT_DEPTH) })).toThrow(
			new RegExp(`${PI_SUBAGENT_DEPTH_ENV} recursion guard`),
		);
	});

	test("the guard is independent of entry resolution: a valid override still refuses at cap", () => {
		const override = existingScript("custom-entry.mjs");
		expect(() =>
			getPiInvocation([], runtime({ env: { [PI_SUBAGENT_ENTRY_ENV]: override, [PI_SUBAGENT_DEPTH_ENV]: String(MAX_SUBAGENT_DEPTH) } })),
		).toThrow(new RegExp(`refusing to spawn a subagent at depth ${MAX_SUBAGENT_DEPTH + 1}`));
	});

	test("getPiInvocation reports the child generation for the spawn env", () => {
		expect(getPiInvocation([], runtime({})).childDepth).toBe(1);
		expect(getPiInvocation([], runtime({ env: { [PI_SUBAGENT_DEPTH_ENV]: "1" } })).childDepth).toBe(2);
	});
});

function makeDetails(results: SingleResult[]): SubagentDetails {
	return { mode: "single", agentScope: "project", projectAgentsDir: null, results };
}

function agent(name: string, systemPrompt = ""): AgentConfig {
	return {
		name,
		description: `${name} test agent`,
		pane: false,
		systemPrompt,
		source: "project",
		filePath: `${name}.md`,
	};
}

function captureSpawnedEnv(): Array<NodeJS.ProcessEnv | undefined> {
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
		queueMicrotask(() => proc.emit("close", 0, null));
		return proc;
	}) as any);
	return envs;
}

function promptTempDirs(): string[] {
	return readdirSync(tmpdir()).filter((name) => name.startsWith("pi-subagent-"));
}

describe("bg one-shot runner depth guard wiring (vstack#192)", () => {
	test("spawned child env carries the incremented PI_SUBAGENT_DEPTH", async () => {
		const envs = captureSpawnedEnv();
		const previous = process.env[PI_SUBAGENT_DEPTH_ENV];
		try {
			delete process.env[PI_SUBAGENT_DEPTH_ENV];
			const root = mkdtempSync(join(tmpdir(), "pi-agents-depth-env-"));
			await runSingleAgent(root, root, [agent("scout")], "scout", "recon", undefined, undefined, undefined, undefined, { getActiveTools: () => [], events: { emit: () => undefined } } as any, undefined, undefined, makeDetails);
			expect(envs).toHaveLength(1);
			expect(envs[0]?.[PI_SUBAGENT_DEPTH_ENV]).toBe("1");
		} finally {
			setSingleAgentSpawnForTests();
			if (previous === undefined) delete process.env[PI_SUBAGENT_DEPTH_ENV];
			else process.env[PI_SUBAGENT_DEPTH_ENV] = previous;
		}
	});

	test("at the depth cap the runner refuses before spawning and reclaims the prompt tmp dir", async () => {
		const envs = captureSpawnedEnv();
		const previous = process.env[PI_SUBAGENT_DEPTH_ENV];
		try {
			process.env[PI_SUBAGENT_DEPTH_ENV] = String(MAX_SUBAGENT_DEPTH);
			const root = mkdtempSync(join(tmpdir(), "pi-agents-depth-cap-"));
			const before = promptTempDirs();
			// A non-empty systemPrompt forces the tmp prompt dir to be created
			// before invocation resolution throws, exercising the failure-path
			// cleanup in runSingleAgentAttempt's finally.
			await expect(
				runSingleAgent(root, root, [agent("scout", "You are scout.")], "scout", "recon", undefined, undefined, undefined, undefined, { getActiveTools: () => [], events: { emit: () => undefined } } as any, undefined, undefined, makeDetails),
			).rejects.toThrow(new RegExp(`${PI_SUBAGENT_DEPTH_ENV} recursion guard`));
			expect(envs).toHaveLength(0);
			expect(promptTempDirs()).toEqual(before);
		} finally {
			setSingleAgentSpawnForTests();
			if (previous === undefined) delete process.env[PI_SUBAGENT_DEPTH_ENV];
			else process.env[PI_SUBAGENT_DEPTH_ENV] = previous;
		}
	});
});
