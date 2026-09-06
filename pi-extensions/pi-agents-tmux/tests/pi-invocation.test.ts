// How a child pi is invoked: which entry re-invokes (pi's own package, an
// override, or `pi` on PATH), the depth guard, and what the one-shot runner
// and the pane launcher hand the child (depth, entry, model, thinking).

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join, relative } from "node:path";
import test, { after } from "node:test";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import { shellQuote } from "../extensions/subagent/names.js";
import {
	assertSubagentSpawnDepth,
	currentSubagentDepth,
	getPiInvocation,
	MAX_SUBAGENT_DEPTH,
	PI_PACKAGE_NAME,
	PI_SUBAGENT_DEPTH_ENV,
	PI_SUBAGENT_ENTRY_ENV,
	type PiInvocation,
	type PiInvocationRuntime,
	writeLauncher,
} from "../extensions/subagent/pane.js";
import { runSingleAgent, setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import { PANE_LAUNCHER_VERSION } from "../extensions/subagent/types.js";
import { cleanupTempRuntimes, makeDetails, tempRuntime, testAgent, writeSettings } from "./single-agent-fixture.js";

after(cleanupTempRuntimes);

const BUN = "/usr/bin/bun";

function existingScript(basename: string, dir = tempRuntime()): string {
	const filePath = join(dir, basename);
	writeFileSync(filePath, "// test entry\n");
	return filePath;
}

// A script inside a fixture package: nearest-package.json identity is what
// getPiInvocation trusts, so entries sit under explicit manifests.
function scriptInPackage(basename: string, manifest: Record<string, unknown>): string {
	const dir = join(tempRuntime(), "pkg");
	mkdirSync(dir, { recursive: true });
	writeFileSync(join(dir, "package.json"), JSON.stringify(manifest));
	return existingScript(basename, dir);
}

function runtime(overrides: Partial<PiInvocationRuntime>): PiInvocationRuntime {
	return { argv1: undefined, execPath: BUN, env: {}, ...overrides };
}

// Absolute fixture paths print as their alias; a relative or unexpected path
// prints as itself, so a row expecting `entry` reddens on either.
type Alias = Record<string, string>;
const aliased = (value: string | undefined, alias: Alias) => (value === undefined ? "-" : value === BUN ? "bun" : alias[value] ?? value);

function invocationLine(invocation: PiInvocation, alias: Alias): string {
	return `cmd=${aliased(invocation.command, alias)} args=[${invocation.args.map((arg) => aliased(arg, alias)).join(",")}] child-entry=${aliased(invocation.childEntryOverride, alias)} depth=${invocation.childDepth}`;
}

type Resolution = () => { alias: Alias; args?: string[]; runtime: PiInvocationRuntime };

const withEntry = (entry: string, extra: Partial<PiInvocationRuntime> = {}) => ({ alias: { [entry]: "entry" }, runtime: runtime({ argv1: entry, ...extra }) });
const ON_PATH = "cmd=pi args=[-p] child-entry=- depth=1";
const SELF = "cmd=bun args=[entry,-p] child-entry=- depth=1";

// label | the process's argv[1], execPath and env | expect the invocation line
const resolutionRows: Array<[string, Resolution, string]> = [
	["a harness script as argv[1] falls back to pi on PATH (the fork-bomb shape)", () => withEntry(existingScript("harness.mjs")), ON_PATH],
	["a pi-looking basename in a foreign package falls back", () => withEntry(scriptInPackage("cli.ts", { name: "some-harness", version: "0.0.1" })), ON_PATH],
	["a pi-looking basename with no reachable manifest falls back", () => withEntry(existingScript("cli.ts")), ON_PATH],
	["pi's own package name re-invokes the script", () => withEntry(scriptInPackage("cli.ts", { name: PI_PACKAGE_NAME, version: "0.0.0" })), SELF],
	["a bin map whose pi entry is this script re-invokes", () => withEntry(scriptInPackage("cli.js", { name: "pi-fork", bin: { pi: "./cli.js" } })), SELF],
	["a package named pi whose string bin is this script re-invokes", () => withEntry(scriptInPackage("cli.js", { name: "pi", bin: "./cli.js" })), SELF],
	["a bin map whose pi entry is another file falls back", () => withEntry(scriptInPackage("cli.ts", { name: "some-fork-of-pi", bin: { pi: "./cli.js" } })), ON_PATH],
	["a package named pi whose string bin is another file falls back", () => withEntry(scriptInPackage("cli.ts", { name: "pi", bin: "./cli.js" })), ON_PATH],
	["an unparseable nearest manifest fails closed under a pi ancestor", () => {
		const outer = join(tempRuntime(), "pkg");
		const inner = join(outer, "vendor");
		mkdirSync(inner, { recursive: true });
		writeFileSync(join(outer, "package.json"), JSON.stringify({ name: PI_PACKAGE_NAME }));
		writeFileSync(join(inner, "package.json"), "{ not json");
		return withEntry(existingScript("cli.ts", inner));
	}, ON_PATH],
	["a manifest-less entry dir walks up to pi's manifest", () => {
		const pkgDir = join(tempRuntime(), "pkg");
		const srcDir = join(pkgDir, "src");
		mkdirSync(srcDir, { recursive: true });
		writeFileSync(join(pkgDir, "package.json"), JSON.stringify({ name: PI_PACKAGE_NAME }));
		return withEntry(existingScript("cli.ts", srcDir));
	}, SELF],
	["a script override wins over pi's own argv[1] and is handed down", () => {
		const override = existingScript("custom-entry.mjs");
		const argv1 = scriptInPackage("cli.ts", { name: PI_PACKAGE_NAME });
		return { alias: { [override]: "override", [argv1]: "entry" }, runtime: runtime({ argv1, env: { [PI_SUBAGENT_ENTRY_ENV]: override } }) };
	}, "cmd=bun args=[override,-p] child-entry=override depth=1"],
	["a relative script override resolves against the parent cwd and is handed down resolved", () => {
		const override = existingScript("custom-entry.mjs");
		const rel = relative(process.cwd(), override);
		assert.equal(isAbsolute(rel), false);
		return { alias: { [override]: "override" }, runtime: runtime({ env: { [PI_SUBAGENT_ENTRY_ENV]: rel } }) };
	}, "cmd=bun args=[override,-p] child-entry=override depth=1"],
	["a script override that does not exist is taken as an executable path", () => {
		const missing = join(tempRuntime(), "gone.mjs");
		return { alias: { [missing]: "missing" }, runtime: runtime({ env: { [PI_SUBAGENT_ENTRY_ENV]: missing } }) };
	}, "cmd=missing args=[-p] child-entry=missing depth=1"],
	["an absolute executable override is the command and is handed down", () => ({ alias: {}, runtime: runtime({ env: { [PI_SUBAGENT_ENTRY_ENV]: "/opt/pi/bin/pi" } }) }), "cmd=/opt/pi/bin/pi args=[-p] child-entry=/opt/pi/bin/pi depth=1"],
	["a relative separator-bearing executable override resolves and is handed down resolved", () => {
		const binDir = join(tempRuntime(), "bin");
		mkdirSync(binDir, { recursive: true });
		const executable = join(binDir, "pi");
		writeFileSync(executable, "#!/bin/sh\n");
		const rel = relative(process.cwd(), executable);
		assert.equal(isAbsolute(rel), false);
		return { alias: { [executable]: "executable" }, runtime: runtime({ env: { [PI_SUBAGENT_ENTRY_ENV]: rel } }) };
	}, "cmd=executable args=[-p] child-entry=executable depth=1"],
	["a separator-free override stays verbatim for PATH resolution", () => ({ alias: {}, runtime: runtime({ env: { [PI_SUBAGENT_ENTRY_ENV]: "pi-custom" } }) }), "cmd=pi-custom args=[-p] child-entry=pi-custom depth=1"],
	["a blank override is no override", () => ({ alias: {}, runtime: runtime({ env: { [PI_SUBAGENT_ENTRY_ENV]: "  " } }) }), ON_PATH],
	// The `!isBunVirtualScript` guard itself is only reachable inside a compiled
	// binary, where the virtual path exists; here the row reaches execPath
	// through the missing file and the non-runtime execPath.
	["the compiled binary (bun's virtual argv[1]) re-invokes execPath", () => ({ alias: {}, runtime: runtime({ argv1: "/$bunfs/root/cli.js", execPath: "/usr/lib/pi/pi" }) }), "cmd=/usr/lib/pi/pi args=[-p] child-entry=- depth=1"],
	["a non-runtime execPath is re-invoked even with a harness argv[1]", () => ({ ...withEntry(existingScript("harness.mjs"), { execPath: "/usr/lib/pi/pi" }) }), "cmd=/usr/lib/pi/pi args=[-p] child-entry=- depth=1"],
	["node as execPath with no script falls back", () => ({ alias: {}, runtime: runtime({ execPath: "/usr/bin/node" }) }), ON_PATH],
];

test("which pi a child re-invokes", () => {
	for (const [label, build, expect] of resolutionRows) {
		const { alias, args, runtime: rt } = build();
		assert.equal(invocationLine(getPiInvocation(args ?? ["-p"], rt), alias), expect, label);
	}
});

test("an unreadable nearest manifest fails closed under a pi ancestor", () => {
	// Root ignores file modes, and some CI filesystems do too; the case only
	// asserts where the read is genuinely refused.
	if (typeof process.getuid === "function" && process.getuid() === 0) return;
	const outer = join(tempRuntime(), "pkg");
	const inner = join(outer, "vendor");
	mkdirSync(inner, { recursive: true });
	writeFileSync(join(outer, "package.json"), JSON.stringify({ name: PI_PACKAGE_NAME }));
	const innerManifest = join(inner, "package.json");
	writeFileSync(innerManifest, JSON.stringify({ name: PI_PACKAGE_NAME }));
	chmodSync(innerManifest, 0o000);
	try {
		try {
			readFileSync(innerManifest, "utf-8");
			return;
		} catch {
			/* unreadable as intended */
		}
		const entry = existingScript("cli.ts", inner);
		assert.equal(invocationLine(getPiInvocation(["-p"], runtime({ argv1: entry })), { [entry]: "entry" }), ON_PATH);
	} finally {
		chmodSync(innerManifest, 0o600);
	}
});

// The depth as read, the child generation the guard grants (or `refused`), and
// the same through getPiInvocation, which runs the guard before resolving.
function depthLine(env: NodeJS.ProcessEnv): string {
	// Only the recursion guard's own error reads as `refused`; anything else
	// prints whole.
	const refusedOr = (error: unknown) => (/recursion guard/.test(String(error)) ? "refused" : `threw:${String(error)}`);
	const guard = () => {
		try {
			return String(assertSubagentSpawnDepth(env));
		} catch (error) {
			return refusedOr(error);
		}
	};
	const viaInvocation = () => {
		try {
			return String(getPiInvocation([], runtime({ env })).childDepth);
		} catch (error) {
			return refusedOr(error);
		}
	};
	return `current=${currentSubagentDepth(env)} child=${guard()} invocation=${viaInvocation()}`;
}

// label | env | expect the depth line
const depthRows: Array<[string, NodeJS.ProcessEnv, string]> = [
	["no depth var is generation zero", {}, "current=0 child=1 invocation=1"],
	["a depth is read", { [PI_SUBAGENT_DEPTH_ENV]: "2" }, "current=2 child=3 invocation=3"],
	["a non-number is zero", { [PI_SUBAGENT_DEPTH_ENV]: "banana" }, "current=0 child=1 invocation=1"],
	["a negative number is zero", { [PI_SUBAGENT_DEPTH_ENV]: "-4" }, "current=0 child=1 invocation=1"],
	["one below the cap spawns the last generation", { [PI_SUBAGENT_DEPTH_ENV]: String(MAX_SUBAGENT_DEPTH - 1) }, `current=${MAX_SUBAGENT_DEPTH - 1} child=${MAX_SUBAGENT_DEPTH} invocation=${MAX_SUBAGENT_DEPTH}`],
	["at the cap the guard refuses", { [PI_SUBAGENT_DEPTH_ENV]: String(MAX_SUBAGENT_DEPTH) }, `current=${MAX_SUBAGENT_DEPTH} child=refused invocation=refused`],
	["a valid override does not bypass the cap", { [PI_SUBAGENT_DEPTH_ENV]: String(MAX_SUBAGENT_DEPTH), [PI_SUBAGENT_ENTRY_ENV]: "/opt/pi/bin/pi" }, `current=${MAX_SUBAGENT_DEPTH} child=refused invocation=refused`],
];

test("the recursion depth guard", () => {
	for (const [label, env, expect] of depthRows) assert.equal(depthLine(env), expect, label);
});

// The two env vars the runner and launcher read from their own process.
function withProcessEnv<T>(depth: string | undefined, entry: string | undefined, fn: () => Promise<T>): Promise<T> {
	const previousDepth = process.env[PI_SUBAGENT_DEPTH_ENV];
	const previousEntry = process.env[PI_SUBAGENT_ENTRY_ENV];
	if (depth === undefined) delete process.env[PI_SUBAGENT_DEPTH_ENV];
	else process.env[PI_SUBAGENT_DEPTH_ENV] = depth;
	if (entry === undefined) delete process.env[PI_SUBAGENT_ENTRY_ENV];
	else process.env[PI_SUBAGENT_ENTRY_ENV] = entry;
	return fn().finally(() => {
		if (previousDepth === undefined) delete process.env[PI_SUBAGENT_DEPTH_ENV];
		else process.env[PI_SUBAGENT_DEPTH_ENV] = previousDepth;
		if (previousEntry === undefined) delete process.env[PI_SUBAGENT_ENTRY_ENV];
		else process.env[PI_SUBAGENT_ENTRY_ENV] = previousEntry;
	});
}

function agent(overrides: Partial<AgentConfig> = {}): AgentConfig {
	return { ...testAgent(), name: "scout", description: "scout test agent", filePath: "scout.md", ...overrides };
}

function captureSpawn(): Array<{ args: string[]; env: NodeJS.ProcessEnv | undefined }> {
	const calls: Array<{ args: string[]; env: NodeJS.ProcessEnv | undefined }> = [];
	setSingleAgentSpawnForTests(((command: string, args: string[], options?: { env?: NodeJS.ProcessEnv }) => {
		void command;
		calls.push({ args, env: options?.env });
		const proc = new EventEmitter() as any;
		proc.stdout = new EventEmitter();
		proc.stderr = new EventEmitter();
		proc.killed = false;
		proc.kill = () => { proc.killed = true; return true; };
		queueMicrotask(() => proc.emit("close", 0, null));
		return proc;
	}) as any);
	return calls;
}

const promptTempDirs = () => readdirSync(tmpdir()).filter((name) => name.startsWith("pi-subagent-"));
const flag = (args: string[], name: string) => { const at = args.indexOf(name); return at < 0 ? "-" : args[at + 1]; };

type SpawnWorld = { agent?: Partial<AgentConfig>; depth?: string; entry?: (cwd: string) => { alias: Alias; value: string }; parentModel?: string; parentThinking?: string; settings?: Record<string, unknown> };

// The spawn as one line: spawns, the child's depth and entry vars, the model
// and thinking flags, or `refused` with what the refusal left behind.
async function runnerLine(world: SpawnWorld): Promise<string> {
	const root = tempRuntime();
	const entry = world.entry?.(root);
	return withProcessEnv(world.depth, entry?.value, async () => {
		const calls = captureSpawn();
		const emitted: string[] = [];
		const pi = { getActiveTools: () => [], events: { emit: (name: string) => { emitted.push(name); } } } as any;
		const before = promptTempDirs();
		try {
			const config = agent(world.agent);
			if (world.settings) writeSettings(root, world.settings);
			await runSingleAgent(root, root, [config], config.name, "recon", undefined, world.parentModel, world.parentThinking, undefined, pi, undefined, undefined, makeDetails);
		} catch (error) {
			const same = JSON.stringify(promptTempDirs()) === JSON.stringify(before);
			return `refused=${/recursion guard/.test(String(error))} spawns=${calls.length} prompt-tmp=${same ? "unchanged" : "leaked"} events=${emitted.length ? emitted.join(",") : "none"}`;
		} finally {
			setSingleAgentSpawnForTests();
		}
		const call = calls[0];
		return `events=${emitted.length ? emitted.join(",") : "none"} spawns=${calls.length} depth=${call?.env?.[PI_SUBAGENT_DEPTH_ENV] ?? "-"} entry=${aliased(call?.env?.[PI_SUBAGENT_ENTRY_ENV], entry?.alias ?? {})} model=${flag(call?.args ?? [], "--model")} thinking=${flag(call?.args ?? [], "--thinking")}`;
	});
}

const relativeOverride = () => {
	const override = existingScript("custom-entry.mjs");
	return { alias: { [override]: "override" }, value: relative(process.cwd(), override) };
};

// label | the parent's env, agent and model | expect the spawn line
const runnerRows: Array<[string, SpawnWorld, string]> = [
	["a first-generation parent spawns the child at depth 1", { parentModel: "anthropic/claude-opus-5" }, "events=subagents:started,subagents:completed spawns=1 depth=1 entry=- model=anthropic/claude-opus-5 thinking=-"],
	["the child's depth is the parent's plus one", { depth: "1" }, "events=subagents:started,subagents:completed spawns=1 depth=2 entry=- model=- thinking=-"],
	["a relative entry override reaches the child resolved", { entry: relativeOverride }, "events=subagents:started,subagents:completed spawns=1 depth=1 entry=override model=- thinking=-"],
	["the frontmatter effort becomes the thinking flag", { agent: { effort: "high" }, parentModel: "anthropic/claude-opus-5" }, "events=subagents:started,subagents:completed spawns=1 depth=1 entry=- model=anthropic/claude-opus-5 thinking=high"],
	["a model suffix wins over the effort key", { agent: { effort: "high", model: "openai-codex/gpt-6-astra:low" } }, "events=subagents:started,subagents:completed spawns=1 depth=1 entry=- model=openai-codex/gpt-6-astra:low thinking=low"],
	["an effort of off passes no thinking flag", { agent: { effort: "off" }, parentModel: "anthropic/claude-opus-5" }, "events=subagents:started,subagents:completed spawns=1 depth=1 entry=- model=anthropic/claude-opus-5 thinking=-"],
	["the parent's level is ignored under the frontmatter source", { agent: { effort: "high" }, parentThinking: "low" }, "events=subagents:started,subagents:completed spawns=1 depth=1 entry=- model=- thinking=high"],
	["the parent's level wins under the parent source", { agent: { effort: "high" }, parentThinking: "low", settings: { subagentThinkingSource: "parent" } }, "events=subagents:started,subagents:completed spawns=1 depth=1 entry=- model=- thinking=low"],
	// A non-empty systemPrompt creates the prompt tmp dir before the guard
	// throws, so the refusal has something to clean up.
	["at the cap the runner refuses before the spawn, cleans its prompt dir and announces nothing", { agent: { systemPrompt: "You are scout." }, depth: String(MAX_SUBAGENT_DEPTH) }, "refused=true spawns=0 prompt-tmp=unchanged events=none"],
];

test("what the one-shot runner hands the child", async () => {
	for (const [label, world, expect] of runnerRows) assert.equal(await runnerLine(world), expect, label);
});

// The launcher script as one line: the depth it exports, the entry it exports
// or unsets, whether those exports precede the exec, and the exec line's model
// and thinking flags.
async function launcherLine(world: SpawnWorld): Promise<string> {
	const root = tempRuntime();
	const cwd = tempRuntime();
	const entry = world.entry?.(root);
	return withProcessEnv(world.depth, entry?.value, async () => {
		const paths = await writeLauncher(root, "parent-session-id", cwd, agent({ pane: true, systemPrompt: "You are iced.", ...world.agent }), world.parentModel, world.parentThinking);
		const script = readFileSync(paths.launcherFile, "utf-8");
		// The environment at `exec` is the assignments before it: exactly one
		// depth export and exactly one entry export or unset, or the counts print.
		const execAt = script.indexOf("\nexec ");
		const before = execAt > 0 ? script.slice(0, execAt).split("\n") : [];
		const depthWrites = before.map((line) => line.match(new RegExp(`^export ${PI_SUBAGENT_DEPTH_ENV}=(\\S+)$`))?.[1]).filter((v): v is string => v !== undefined);
		const entryWrites = before.map((line) => line.match(new RegExp(`^export ${PI_SUBAGENT_ENTRY_ENV}='([^']*)'$`))?.[1] ?? (new RegExp(`^unset ${PI_SUBAGENT_ENTRY_ENV}$`).test(line) ? "unset" : undefined)).filter((v): v is string => v !== undefined);
		const depth = depthWrites.length === 1 ? depthWrites[0] : `${depthWrites.length}-writes`;
		const entryLine = entryWrites.length === 1 ? (entryWrites[0] === "unset" ? "unset" : aliased(entryWrites[0], entry?.alias ?? {})) : `${entryWrites.length}-writes`;
		const afterExec = /^(export|unset) /m.test(script.slice(execAt + 1));
		const execLine = script.slice(execAt + 1).split("\n")[0] ?? "";
		const quoted = (name: string) => execLine.match(new RegExp(`'${name}' '([^']*)'`))?.[1] ?? "-";
		return `depth=${depth} entry=${entryLine} exports-after-exec=${afterExec} model=${quoted("--model")} thinking=${quoted("--thinking")}`;
	});
}

// label | the parent's env, agent and model | expect the launcher line
const launcherRows: Array<[string, SpawnWorld, string]> = [
	["the launcher exports the next depth and unsets a stale entry before the exec", { depth: "1" }, "depth=2 entry=unset exports-after-exec=false model=- thinking=-"],
	["a relative entry override is exported resolved", { entry: relativeOverride }, "depth=1 entry=override exports-after-exec=false model=- thinking=-"],
	["the frontmatter effort becomes the thinking flag", { agent: { effort: "high" }, parentModel: "anthropic/claude-opus-5" }, "depth=1 entry=unset exports-after-exec=false model=anthropic/claude-opus-5 thinking=high"],
	["a model suffix wins over the effort key", { agent: { effort: "high" }, parentModel: "openai-codex/gpt-6-astra:low" }, "depth=1 entry=unset exports-after-exec=false model=openai-codex/gpt-6-astra:low thinking=low"],
	["an effort of off passes no thinking flag", { agent: { effort: "off" }, parentModel: "anthropic/claude-opus-5" }, "depth=1 entry=unset exports-after-exec=false model=anthropic/claude-opus-5 thinking=-"],
	["the parent's selected level wins over the effort key", { agent: { effort: "high" }, parentThinking: "low" }, "depth=1 entry=unset exports-after-exec=false model=- thinking=low"],
];

test("what the pane launcher hands the child", async () => {
	for (const [label, world, expect] of launcherRows) assert.equal(await launcherLine(world), expect, label);
});

test("a resolved relative executable runs from a different delegated cwd", () => {
	// The mocked spawn never exercises OS command resolution. A relative
	// ./…/bin/pi override, resolved against the parent cwd, must execute when
	// the child's cwd is a different directory, both directly and through a
	// launcher file quoted the way writeLauncher quotes. Shebang scripts need a
	// POSIX shell; a noexec temp mount or bashless host skips the case.
	if (process.platform === "win32") return;
	const fixtureRoot = tempRuntime();
	const probe = join(fixtureRoot, "probe.sh");
	writeFileSync(probe, "#!/usr/bin/env bash\nexit 0\n");
	chmodSync(probe, 0o755);
	const probeRun = spawnSync(probe, []);
	if (probeRun.error || probeRun.status !== 0) return;

	const binDir = join(fixtureRoot, "bin");
	mkdirSync(binDir, { recursive: true });
	const marker = join(fixtureRoot, "marker.txt");
	const executable = join(binDir, "pi");
	writeFileSync(executable, `#!/bin/sh\nprintf ran > ${JSON.stringify(marker)}\n`);
	chmodSync(executable, 0o755);
	const relativeExecutable = relative(process.cwd(), executable);
	assert.equal(isAbsolute(relativeExecutable), false);
	// The delegated cwd sits deeper than the relative path's ".." climb; from a
	// shallow cwd the excess ".." segments clamp at / and the relative form
	// would accidentally still resolve.
	const upLevels = relativeExecutable.split("/").filter((segment) => segment === "..").length;
	let delegatedCwd = tempRuntime();
	for (let i = 0; i < upLevels; i++) delegatedCwd = join(delegatedCwd, `depth-${i}`);
	mkdirSync(delegatedCwd, { recursive: true });

	const launcher = (name: string, command: string, args: string[]): string => {
		const launcherPath = join(fixtureRoot, name);
		writeFileSync(launcherPath, `#!/usr/bin/env bash\nset -euo pipefail\nexec ${[command, ...args].map(shellQuote).join(" ")}\n`);
		chmodSync(launcherPath, 0o755);
		return launcherPath;
	};
	const ran = () => {
		if (!existsSync(marker)) return "no-marker";
		const text = readFileSync(marker, "utf-8");
		rmSync(marker, { force: true });
		return text;
	};

	const invocation = getPiInvocation([], runtime({ env: { [PI_SUBAGENT_ENTRY_ENV]: relativeExecutable } }));
	const direct = spawnSync(invocation.command, invocation.args, { cwd: delegatedCwd });
	const directLine = `direct=${direct.error ? "error" : direct.status}/${ran()}`;
	const viaLauncher = spawnSync(launcher("launcher.sh", invocation.command, invocation.args), [], { cwd: delegatedCwd });
	const viaLauncherLine = `launcher=${viaLauncher.status}/${ran()}`;
	// Control: the relative form fails command lookup from the delegated cwd.
	const broken = spawnSync(launcher("launcher-broken.sh", relativeExecutable, []), [], { cwd: delegatedCwd });
	assert.equal(`${directLine} ${viaLauncherLine} relative=${broken.status}`, "direct=0/ran launcher=0/ran relative=127");
});

test("PANE_LAUNCHER_VERSION is bumped when the launcher template changes", () => {
	// Kept as a guard, not a behaviour test: cleanupPaneRegistry recycles live
	// panes only when their recorded launcherVersion differs from this
	// constant, so a template change without a bump leaves running panes on
	// the old launcher (the depth guard shipped that way once). On failure:
	// bump PANE_LAUNCHER_VERSION in types.ts and update the digest here.
	const paneSource = readFileSync(join(import.meta.dir, "..", "extensions", "subagent", "pane.ts"), "utf-8");
	const templateStart = paneSource.indexOf("const script = `#!/usr/bin/env bash");
	const templateEnd = paneSource.indexOf("`;", templateStart);
	assert.notEqual(templateStart, -1, "launcher template start");
	assert.ok(templateEnd > templateStart, "launcher template end");
	const templateDigest = createHash("sha256").update(paneSource.slice(templateStart, templateEnd)).digest("hex").slice(0, 16);
	assert.equal(`version=${PANE_LAUNCHER_VERSION} template=${templateDigest}`, "version=11 template=38837c68b7dc5b2a");
});
