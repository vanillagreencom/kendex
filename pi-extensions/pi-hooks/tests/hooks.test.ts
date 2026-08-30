import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

import piHooks from "../extensions/hooks.ts";

const CONFIG_ID = "@vanillagreen/pi-hooks";

type ToolCallHandler = (event: { toolName: string; input: Record<string, unknown> }, ctx: Record<string, unknown>) => Promise<unknown>;

function runGit(args: string[], cwd: string): void {
	const result = spawnSync("git", args, { cwd, encoding: "utf8" });
	if (result.status !== 0) {
		throw new Error(`git ${args.join(" ")} failed: ${result.stderr || result.stdout}`);
	}
}

function writePiConfig(project: string): void {
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

// Git reads no config of the developer's here: a global core.hooksPath
// would disarm every fixture, and a global init.templateDir can leave git
// init without the hooks directory the fixtures write into.
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

function initRustRepo(prefix: string): string {
	const dir = mkdtempSync(join(tmpdir(), prefix));
	runGit(["init", "-q"], dir);
	mkdirSync(join(dir, ".git", "hooks"), { recursive: true });
	writePiConfig(dir);
	mkdirSync(join(dir, "src"), { recursive: true });
	writeFileSync(join(dir, "src", "lib.rs"), "pub fn answer() -> i32 { 42 }\n");
	runGit(["add", "src/lib.rs"], dir);
	return dir;
}

function initCleanRustRepo(prefix: string): string {
	const dir = initRustRepo(prefix);
	runGit(["-c", "user.email=pi-hooks@example.com", "-c", "user.name=pi-hooks", "commit", "-q", "-m", "init"], dir);
	return dir;
}

function fakeCargoBin(root: string): { bin: string; log: string } {
	const bin = join(root, "bin");
	mkdirSync(bin, { recursive: true });
	const log = join(root, "cargo.log");
	const cargo = join(bin, "cargo");
	writeFileSync(cargo, `#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_CARGO_LOG"
exit "\${FAKE_FMT_EXIT:-0}"
`);
	chmodSync(cargo, 0o755);
	return { bin, log };
}

function installToolCallHandler(): ToolCallHandler {
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

async function withFakeCargo<T>(run: (paths: { bin: string; log: string }) => Promise<T>): Promise<T> {
	const root = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
	const paths = fakeCargoBin(root);
	const oldPath = process.env.PATH;
	const oldLog = process.env.FAKE_CARGO_LOG;
	const oldFmt = process.env.FAKE_FMT_EXIT;
	process.env.PATH = `${paths.bin}:${oldPath ?? ""}`;
	process.env.FAKE_CARGO_LOG = paths.log;
	try {
		return await run(paths);
	} finally {
		if (oldPath === undefined) delete process.env.PATH;
		else process.env.PATH = oldPath;
		if (oldLog === undefined) delete process.env.FAKE_CARGO_LOG;
		else process.env.FAKE_CARGO_LOG = oldLog;
		if (oldFmt === undefined) delete process.env.FAKE_FMT_EXIT;
		else process.env.FAKE_FMT_EXIT = oldFmt;
		rmSync(root, { recursive: true, force: true });
	}
}

// The marker the growth-guards installer ends its delegating line with,
// assembled so this file is not itself mistaken for a shim.
const GG_MARK = "# kendex-" + "guards-hook";

function armHooks(project: string): void {
	for (const lane of ["pre-commit", "commit-msg"]) {
		const file = join(project, ".git", "hooks", lane);
		writeFileSync(file, `#!/bin/sh\nexit 0 ${GG_MARK}\n`);
		chmodSync(file, 0o755);
	}
}

function cargoLog(log: string): string {
	return readFileSync(log, { encoding: "utf8", flag: "a+" });
}

describe("pi-hooks pre-commit tool_call", () => {
	// A fake cargo stays on PATH throughout as the control: the gate defers or
	// refuses, and never runs a check of its own, so the log must stay empty.
	test("defers to an armed repository without running anything", async () => {
		await withFakeCargo(async ({ log }) => {
			const project = initRustRepo("pi-hooks-project-");
			armHooks(project);
			process.env.FAKE_FMT_EXIT = "1";
			try {
				const handler = installToolCallHandler();
				expect(await handler({ toolName: "bash", input: { command: "git commit -m test" } }, { cwd: project })).toBeUndefined();
				expect(cargoLog(log)).toBe("");
			} finally {
				rmSync(project, { recursive: true, force: true });
			}
		});
	});

	test("refuses an unarmed repository naming kendex guard install", async () => {
		await withFakeCargo(async ({ log }) => {
			const project = initRustRepo("pi-hooks-project-");
			try {
				const handler = installToolCallHandler();
				const result = await handler({ toolName: "bash", input: { command: "git commit -m test" } }, { cwd: project }) as { block?: boolean; reason?: string };
				expect(result.block).toBe(true);
				expect(result.reason).toContain("not armed by kendex");
				expect(result.reason).toContain("kendex guard install");
				expect(cargoLog(log)).toBe("");
			} finally {
				rmSync(project, { recursive: true, force: true });
			}
		});
	});

	test("refuses a bypass of the armed hooks", async () => {
		const project = initRustRepo("pi-hooks-project-");
		armHooks(project);
		try {
			const handler = installToolCallHandler();
			for (const command of ["git commit --no-verify -m test", "git commit -anm test", "git -c core.hooksPath=/dev/null commit -m test"]) {
				const result = await handler({ toolName: "bash", input: { command } }, { cwd: project }) as { block?: boolean; reason?: string };
				expect(result.block).toBe(true);
				expect(result.reason).toContain("bypasses this repository's armed git hooks");
			}
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("shell expansion is not a refusal", async () => {
		const project = initRustRepo("pi-hooks-project-");
		armHooks(project);
		try {
			const handler = installToolCallHandler();
			for (const command of [
				'repo=$(git rev-parse --show-toplevel) && git -C "$repo" commit -m test',
				"git -C `pwd` commit -m test",
				'cd "$dir" && git commit -m test',
			]) {
				expect(await handler({ toolName: "bash", input: { command } }, { cwd: project })).toBeUndefined();
			}
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("the preCommitCheck setting turns the gate off", async () => {
		const project = initRustRepo("pi-hooks-project-");
		writeFileSync(join(project, ".pi", "settings.json"), JSON.stringify({
			kendex: { extensionManager: { config: { [CONFIG_ID]: { preCommitCheck: false } } } },
		}));
		try {
			const handler = installToolCallHandler();
			const ctx = { cwd: project, isProjectTrusted: () => true };
			expect(await handler({ toolName: "bash", input: { command: "git commit -m test" } }, ctx)).toBeUndefined();
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("a commit aimed elsewhere from outside any repository passes with a UI notice", async () => {
		const plain = mkdtempSync(join(tmpdir(), "pi-hooks-plain-"));
		const other = mkdtempSync(join(tmpdir(), "pi-hooks-other-"));
		runGit(["init", "-q"], other);
		const notices: string[] = [];
		try {
			const handler = installToolCallHandler();
			const ctx = { cwd: plain, hasUI: true, ui: { notify: (message: string) => notices.push(message) } };
			expect(await handler({ toolName: "bash", input: { command: `git -C ${JSON.stringify(other)} commit -m fixture` } }, ctx)).toBeUndefined();
			expect(notices).toHaveLength(1);
			expect(notices[0]).toContain("moves repositories");
			expect(notices[0]).toContain(`judged ${plain} only`);
			// Headless Pi has no ui: the notice is dropped, never thrown.
			expect(await handler({ toolName: "bash", input: { command: `git -C ${JSON.stringify(other)} commit -m fixture` } }, { cwd: plain })).toBeUndefined();
			expect(notices).toHaveLength(1);
		} finally {
			rmSync(plain, { recursive: true, force: true });
			rmSync(other, { recursive: true, force: true });
		}
	});

	test("allows a command with no git commit in any argv without running anything", async () => {
		await withFakeCargo(async ({ log }) => {
			const project = initRustRepo("pi-hooks-project-");
			process.env.FAKE_FMT_EXIT = "1";
			try {
				const handler = installToolCallHandler();
				for (const command of ["cargo fmt", "git status", "echo commit", "git log --grep=commit"]) {
					expect(await handler({ toolName: "bash", input: { command } }, { cwd: project })).toBeUndefined();
				}
				expect(cargoLog(log)).toBe("");
			} finally {
				rmSync(project, { recursive: true, force: true });
			}
		});
	});
});

describe("pi-hooks bash guard passthrough", () => {
	test("passes reviewer searches whose patterns contain backticks (kendex#668)", async () => {
		const project = initCleanRustRepo("pi-hooks-project-");
		try {
			const handler = installToolCallHandler();
			expect(await handler({ toolName: "bash", input: { command: 'rg -n "`kendex refresh`" skills/' } }, { cwd: project })).toBeUndefined();
			expect(await handler({ toolName: "bash", input: { command: "rg -n '\\x60kendex refresh\\x60' skills/" } }, { cwd: project })).toBeUndefined();
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("still blocks a bare cd", async () => {
		const project = initCleanRustRepo("pi-hooks-project-");
		try {
			const handler = installToolCallHandler();
			const blocked = {
				block: true,
				reason: "Bare 'cd' changes working directory permanently across tool calls. Use a subshell instead: (cd /path && command)",
			};
			expect(await handler({ toolName: "bash", input: { command: "cd /tmp" } }, { cwd: project })).toEqual(blocked);
			expect(await handler({ toolName: "bash", input: { command: "cd" } }, { cwd: project })).toEqual(blocked);
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});
});
