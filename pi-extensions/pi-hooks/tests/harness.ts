import { afterAll, beforeAll } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
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
 * once, because bun's beforeAll is per file. */
export function useIsolatedGitEnv(): void {
	const isolatedEnv: Record<string, string> = { GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" };
	const savedEnv: Record<string, string | undefined> = {};
	beforeAll(() => {
		for (const [name, value] of Object.entries(isolatedEnv)) {
			savedEnv[name] = process.env[name];
			process.env[name] = value;
		}
	});
	afterAll(() => {
		for (const [name, value] of Object.entries(savedEnv)) {
			if (value === undefined) delete process.env[name];
			else process.env[name] = value;
		}
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
 * it. The extension spawns what is here and nothing else. */
export function renderedHookPath(project: string, name: string): string {
	return join(project, ".pi", "kendex", "hooks", `${name}.sh`);
}

/** Put a stub hook where kendex renders one. It appends the payload it read to
 * `log`, writes `stderr`, and exits `exitCode` — so the log proves the spawn
 * happened and carries what the extension sent. */
export function renderStub(project: string, name: string, opts: { exitCode: number; stderr?: string; log: string }): void {
	writeStub(renderedHookPath(project, name), opts);
}

export function renderUserStub(userRoot: string, name: string, opts: { exitCode: number; stderr?: string; log: string }): void {
	writeStub(join(userRoot, "kendex", "hooks", `${name}.sh`), opts);
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
