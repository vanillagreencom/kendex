import { afterAll, beforeAll } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

import piHooks from "../extensions/hooks.ts";

/* Fixtures shared by the pi-hooks suites. */

export const CONFIG_ID = "@vanillagreen/pi-hooks";

export type ToolCallHandler = (event: { toolName: string; input: Record<string, unknown> }, ctx: Record<string, unknown>) => Promise<unknown>;

export function runGit(args: string[], cwd: string): void {
	const result = spawnSync("git", args, { cwd, encoding: "utf8" });
	if (result.status !== 0) {
		throw new Error(`git ${args.join(" ")} failed: ${result.stderr || result.stdout}`);
	}
}

export function writePiConfig(project: string): void {
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeFileSync(join(project, ".pi", "settings.json"), JSON.stringify({
		kendex: {
			extensionManager: {
				config: {
					[CONFIG_ID]: {
						enabled: true,
						preCommitCheck: true,
						taskCompletedCheck: false,
						clippyTimeoutMs: 3000,
					},
				},
			},
		},
	}, null, 2));
}

/* Git reads no config of the developer's here: a global core.hooksPath would
 * disarm every fixture, and a global init.templateDir can leave git init
 * without the hooks directory the fixtures write into. Each suite calls this
 * once, because bun's beforeAll is per file.
 *
 * GIT_DIR, GIT_COMMON_DIR, GIT_WORK_TREE and GIT_INDEX_FILE are cleared
 * together, the rule AGENTS.md states: a suite run from a git hook context
 * inherits them, and every `git init`, `git add` and `git commit` a fixture
 * makes would then land in the real repository's index rather than the
 * temporary one it just created. Clearing three of the four leaves the same
 * hole. */
const CLEARED = ["GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"] as const;

export function useIsolatedGitEnv(): void {
	const isolatedEnv: Record<string, string> = { GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" };
	const savedEnv: Record<string, string | undefined> = {};
	let emptyAgentDir: string | undefined;
	beforeAll(() => {
		for (const [name, value] of Object.entries(isolatedEnv)) {
			savedEnv[name] = process.env[name];
			process.env[name] = value;
		}
		for (const name of CLEARED) {
			savedEnv[name] = process.env[name];
			delete process.env[name];
		}
		// Unset, piUserDir() is ~/.pi/agent, so the developer's own global
		// registry and settings answer as a second scope in every case that
		// does not name one. An empty root is the one nobody has installed to.
		savedEnv.PI_CODING_AGENT_DIR = process.env.PI_CODING_AGENT_DIR;
		emptyAgentDir = mkdtempSync(join(tmpdir(), "pi-hooks-empty-agent-"));
		process.env.PI_CODING_AGENT_DIR = emptyAgentDir;
	});
	afterAll(() => {
		for (const [name, value] of Object.entries(savedEnv)) {
			if (value === undefined) delete process.env[name];
			else process.env[name] = value;
		}
		if (emptyAgentDir !== undefined) rmSync(emptyAgentDir, { recursive: true, force: true });
	});
}

export function initRustRepo(prefix: string): string {
	const dir = mkdtempSync(join(tmpdir(), prefix));
	runGit(["init", "-q"], dir);
	mkdirSync(join(dir, ".git", "hooks"), { recursive: true });
	writePiConfig(dir);
	mkdirSync(join(dir, "src"), { recursive: true });
	writeFileSync(join(dir, "src", "lib.rs"), "pub fn answer() -> i32 { 42 }\n");
	runGit(["add", "src/lib.rs"], dir);
	return dir;
}

export function installToolCallHandler(): ToolCallHandler {
	let handler: ToolCallHandler | undefined;
	const pi = {
		on(event: string, cb: ToolCallHandler) {
			if (event === "tool_call") handler = cb;
		},
	};
	piHooks(pi as never);
	if (!handler) throw new Error("tool_call handler was not registered");
	return handler;
}

/** The kendex render of a hook, at the project path docs/adapters/pi.md gives
 * it. The extension spawns what the registry beside it names and nothing else. */
export function renderedHookPath(project: string, name: string): string {
	return join(project, ".pi", "kendex", "hooks", `${name}.sh`);
}

/**
 * Register one hook in the rendered registry under a scope root, the way
 * `crates/core/src/engine/targets.rs::pi_hook` and the `UpsertHook` edit write
 * it: keyed by Pi's listener name, matcher and all, with the command spelling
 * that scope takes. Appended, so a fixture's registration order is the order
 * the carrier runs them in.
 */
export function registerRendered(root: string, listener: string, matcher: string | undefined, command: string, timeout?: number): void {
	const path = join(root, "kendex", "hooks.json");
	mkdirSync(join(path, ".."), { recursive: true });
	let registry: { hooks: Record<string, { matcher?: string; hooks: Record<string, unknown>[] }[]> };
	try {
		registry = JSON.parse(readFileSync(path, "utf8"));
	} catch {
		registry = { hooks: {} };
	}
	const groups = (registry.hooks[listener] ??= []);
	let group = groups.find((candidate) => candidate.matcher === matcher);
	if (group === undefined) {
		group = { ...(matcher === undefined ? {} : { matcher }), hooks: [] };
		groups.push(group);
	}
	group.hooks.push({ type: "command", command, ...(timeout === undefined ? {} : { timeout }) });
	writeFileSync(path, `${JSON.stringify(registry, null, 2)}\n`);
}

/** Put a stub hook where kendex renders one, registered as kendex registers it.
 * It appends the payload it read to `log`, writes `stderr`, and exits
 * `exitCode` — so the log proves the spawn happened and carries what the
 * extension sent. */
export function renderStub(project: string, name: string, opts: { exitCode: number; stderr?: string; log: string }): void {
	writeStub(renderedHookPath(project, name), opts);
	registerProjectHook(project, name);
}

/** The registration kendex writes for a project-scope hook, command and all. */
export function registerProjectHook(project: string, name: string): void {
	registerRendered(join(project, ".pi"), "tool_call", "Bash", `bash "$(git rev-parse --show-toplevel)/.pi/kendex/hooks/${name}.sh"`);
}

export function renderUserStub(userRoot: string, name: string, opts: { exitCode: number; stderr?: string; log: string }): void {
	const script = join(userRoot, "kendex", "hooks", `${name}.sh`);
	writeStub(script, opts);
	registerRendered(userRoot, "tool_call", "Bash", `bash "${script}"`);
}

function writeStub(path: string, opts: { exitCode: number; stderr?: string; log: string }): void {
	mkdirSync(join(path, ".."), { recursive: true });
	writeFileSync(path, [
		"#!/usr/bin/env bash",
		"set -euo pipefail",
		`cat >> ${JSON.stringify(opts.log)}`,
		...(opts.stderr ? [`echo ${JSON.stringify(opts.stderr)} >&2`] : []),
		`exit ${opts.exitCode}`,
	].join("\n") + "\n");
	chmodSync(path, 0o755);
}

export function readLog(log: string): string {
	return readFileSync(log, { encoding: "utf8", flag: "a+" });
}

/** A trusted workspace. Pi gates the project's own scripts on this, so every
 * case that expects a project-scope hook to run has to say so. */
export function trusted(cwd: string, extra: Record<string, unknown> = {}): Record<string, unknown> {
	return { cwd, isProjectTrusted: () => true, ...extra };
}
