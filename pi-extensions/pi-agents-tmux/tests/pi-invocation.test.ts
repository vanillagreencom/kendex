import { afterAll, describe, expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join, relative } from "node:path";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import {
	assertSubagentSpawnDepth,
	currentSubagentDepth,
	getPiInvocation,
	MAX_SUBAGENT_DEPTH,
	PI_PACKAGE_NAME,
	PI_SUBAGENT_DEPTH_ENV,
	PI_SUBAGENT_ENTRY_ENV,
	writeLauncher,
	type PiInvocationRuntime,
} from "../extensions/subagent/pane.js";
import { runSingleAgent, setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import type { SingleResult, SubagentDetails } from "../extensions/subagent/types.js";

const tempDirs = new Set<string>();

afterAll(() => {
	for (const dir of tempDirs) rmSync(dir, { force: true, recursive: true });
});

function tempDir(prefix = "pi-agents-invocation-"): string {
	const dir = mkdtempSync(join(tmpdir(), prefix));
	tempDirs.add(dir);
	return dir;
}

function existingScript(basename: string, dir = tempDir()): string {
	const filePath = join(dir, basename);
	writeFileSync(filePath, "// test entry\n");
	return filePath;
}

// A script inside a fixture package: nearest-package.json identity is what
// getPiInvocation trusts, so tests place entries under explicit manifests.
function scriptInPackage(basename: string, manifest: Record<string, unknown>): string {
	const dir = join(tempDir(), "pkg");
	mkdirSync(dir, { recursive: true });
	writeFileSync(join(dir, "package.json"), JSON.stringify(manifest));
	return existingScript(basename, dir);
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

	test("a pi-looking basename outside the pi package does NOT self-re-invoke (PR #1178 f1)", () => {
		// Basenames are spoofable: a harness literally named cli.ts must still be
		// rejected because its nearest package.json is not pi's.
		const spoofed = scriptInPackage("cli.ts", { name: "some-harness", version: "0.0.1" });
		const invocation = getPiInvocation(["-p"], runtime({ argv1: spoofed }));
		expect(invocation.command).toBe("pi");
		expect(invocation.args).toEqual(["-p"]);
	});

	test("a pi-looking basename with NO reachable package.json does NOT self-re-invoke", () => {
		const orphan = existingScript("cli.ts");
		const invocation = getPiInvocation(["-p"], runtime({ argv1: orphan }));
		expect(invocation.command).toBe("pi");
	});

	test("pi dev-mode entries under pi's own package keep self-re-invoking", () => {
		for (const manifest of [
			{ name: PI_PACKAGE_NAME, version: "0.0.0" },
			{ name: "some-fork-of-pi", bin: { pi: "./cli.js" } },
		]) {
			const entry = scriptInPackage("cli.ts", manifest);
			const invocation = getPiInvocation(["-p"], runtime({ argv1: entry }));
			expect(invocation.command).toBe("/usr/bin/bun");
			expect(invocation.args).toEqual([entry, "-p"]);
		}
	});

	test("PI_SUBAGENT_ENTRY script override wins over a pi-package argv[1]", () => {
		const override = existingScript("custom-entry.mjs");
		const argv1 = scriptInPackage("cli.ts", { name: PI_PACKAGE_NAME });
		const invocation = getPiInvocation(["-p"], runtime({ argv1, env: { [PI_SUBAGENT_ENTRY_ENV]: override } }));
		expect(invocation.command).toBe("/usr/bin/bun");
		expect(invocation.args).toEqual([override, "-p"]);
	});

	test("relative PI_SUBAGENT_ENTRY resolves to an absolute path against the parent cwd (PR #1178 f2/f3)", () => {
		// The child spawns from the delegated agent cwd; a relative script arg
		// would ENOENT there. The returned arg must already be absolute.
		const override = existingScript("custom-entry.mjs");
		const relativeOverride = relative(process.cwd(), override);
		expect(isAbsolute(relativeOverride)).toBe(false);
		const invocation = getPiInvocation(["-p"], runtime({ env: { [PI_SUBAGENT_ENTRY_ENV]: relativeOverride } }));
		expect(invocation.command).toBe("/usr/bin/bun");
		expect(invocation.args[0]).toBe(override);
		expect(isAbsolute(invocation.args[0])).toBe(true);
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

function agent(name: string, systemPrompt = "", pane = false): AgentConfig {
	return {
		name,
		description: `${name} test agent`,
		pane,
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
			const root = tempDir("pi-agents-depth-env-");
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
			const root = tempDir("pi-agents-depth-cap-");
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

describe("persistent pane launcher depth export (vstack#192 / PR #1178 f4)", () => {
	test("generated launcher script exports the incremented PI_SUBAGENT_DEPTH before exec", async () => {
		const previous = process.env[PI_SUBAGENT_DEPTH_ENV];
		try {
			process.env[PI_SUBAGENT_DEPTH_ENV] = "1";
			const root = tempDir("pi-agents-launcher-depth-");
			const cwd = tempDir("pi-agents-launcher-cwd-");
			const paths = await writeLauncher(root, "parent-session-id", cwd, agent("iced", "You are iced.", true), undefined, undefined);
			const script = readFileSync(paths.launcherFile, "utf-8");
			// Omitting this export would silently reset pane descendants to depth
			// 0 and disarm the recursion guard for the whole pane subtree.
			expect(script).toMatch(new RegExp(`^export ${PI_SUBAGENT_DEPTH_ENV}=2$`, "m"));
			const exportIndex = script.indexOf(`export ${PI_SUBAGENT_DEPTH_ENV}=`);
			const execIndex = script.indexOf("exec ");
			expect(exportIndex).toBeGreaterThanOrEqual(0);
			expect(execIndex).toBeGreaterThan(exportIndex);
		} finally {
			if (previous === undefined) delete process.env[PI_SUBAGENT_DEPTH_ENV];
			else process.env[PI_SUBAGENT_DEPTH_ENV] = previous;
		}
	});
});
