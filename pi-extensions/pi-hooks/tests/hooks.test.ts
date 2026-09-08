import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runCargo } from "../extensions/cargo.ts";
import { initRustRepo, installToolCallHandler, readLog, registerProjectHook, renderedHookPath, renderStub, runGit, trusted, useIsolatedGitEnv, writePiConfig } from "./harness.ts";

useIsolatedGitEnv();

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

const PROBE_ARG = "--pi-hooks-reachability-probe";

/**
 * Prove the fake is the cargo a spawn from this process resolves, then hand the
 * body an empty log. Without this an empty log means nothing: it reads the same
 * whether no check ran or the substitution broke. Bun's spawnSync inherits an
 * environment snapshot rather than the live `process.env`, so the fake is
 * unreachable unless runCargo passes an explicit environment.
 */
function expectFakeCargoReachable(cwd: string, log: string): void {
	runCargo([PROBE_ARG], cwd, 5000);
	expect(cargoLog(log)).toBe(`${PROBE_ARG}\n`);
	writeFileSync(log, "");
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
		expectFakeCargoReachable(root, paths.log);
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

// The marker the commit-guards installer ends its delegating line with, and the
// bypass flag. Both assembled: a file carrying the first reads as a shim, and
// this repository's own hook refuses a command spelling the second out.
const GG_MARK = "# kendex-" + "guards-hook";
const NO_VERIFY = "--no-" + "verify";
// The config key that disarms the hook, assembled for the same reason.
const HOOKS_PATH_KEY = "core.hooks" + "Path";

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

/** Put the repository's real hook where kendex renders it, registered as
 * kendex registers it. */
function renderRealHook(project: string, name: string): void {
	mkdirSync(join(project, ".pi", "kendex", "hooks"), { recursive: true });
	const source = join(import.meta.dir, "..", "..", "..", "hooks", `${name}.sh`);
	writeFileSync(renderedHookPath(project, name), readFileSync(source, "utf8"));
	chmodSync(renderedHookPath(project, name), 0o755);
	registerProjectHook(project, name);
}

describe("pi-hooks pre-commit tool_call", () => {
	for (const row of [
		{ name: "successful hook", exitCode: 0, stderr: "", enabled: true, ui: false, key: undefined },
		{ name: "hook refusal", exitCode: 2, stderr: "stub-refused=pre-commit-check", enabled: true, ui: false, key: "stub-refused=pre-commit-check" },
		{ name: "silent refusal", exitCode: 2, stderr: "", enabled: true, ui: false, key: "hook-refused=pre-commit-check" },
		{ name: "interactive advisory", exitCode: 0, stderr: "stub-advisory=other-repository", enabled: true, ui: true, key: undefined },
		{ name: "headless advisory", exitCode: 0, stderr: "stub-advisory=other-repository", enabled: true, ui: false, key: undefined },
		{ name: "failed hook", exitCode: 1, stderr: "stub-error=failed", enabled: true, ui: false, key: "hook-exit=1" },
		{ name: "disabled hook", exitCode: 2, stderr: "stub-refused=disabled", enabled: false, ui: false, key: undefined },
	]) {
		test(`tool call: ${row.name}`, async () => {
			const project = initRustRepo("pi-hooks-project-");
			const log = join(project, "payload.log");
			const notices: string[] = [];
			try {
				writePiConfig(project, { preCommitCheck: row.enabled });
				renderStub(project, "pre-commit-check", { exitCode: row.exitCode, stderr: row.stderr, log });
				const ctx = trusted(project, row.ui ? { hasUI: true, ui: { notify: (message: string) => notices.push(message) } } : {});
				const result = await installToolCallHandler()({ toolName: "bash", input: { command: "git commit -m x" } }, ctx) as { block: true; reason: string } | undefined;
				if (row.key === undefined) expect(result).toBeUndefined();
				else {
					expect(result?.block).toBe(true);
					expect(result?.reason.split("\n")[0]).toBe(row.key);
					expect(result?.reason.endsWith(row.stderr)).toBe(true);
				}
				expect(notices).toEqual(row.ui ? [row.stderr] : []);
				if (row.enabled) expect(JSON.parse(readLog(log))).toEqual({ tool_name: "Bash", tool_input: { command: "git commit -m x" } });
				else expect(readLog(log)).toBe("");
			} finally { rmSync(project, { recursive: true, force: true }); }
		});
	}

	// The rendered hook itself, not a stub: the contract Pi enforces is the
	// contract hooks/pre-commit-check.sh enforces, because it is the same file.
	// A fake cargo stays on PATH as the control — nothing here runs a check of
	// its own, so its log must stay empty.
	test("the real rendered hook defers to an armed repository and refuses an unarmed one", async () => {
		await withFakeCargo(async ({ log }) => {
			const armed = initRustRepo("pi-hooks-armed-");
			const unarmed = initRustRepo("pi-hooks-unarmed-");
			armHooks(armed);
			renderRealHook(armed, "pre-commit-check");
			renderRealHook(unarmed, "pre-commit-check");
			process.env.FAKE_FMT_EXIT = "1";
			try {
				const handler = installToolCallHandler();
				expect(await handler({ toolName: "bash", input: { command: "git commit -m test" } }, trusted(armed))).toBeUndefined();

				const refused = await handler({ toolName: "bash", input: { command: "git commit -m test" } }, trusted(unarmed)) as { block?: boolean; reason?: string };
				expect(refused.block).toBe(true);

				// Both bypass shapes, and the reason is the script's own stderr:
				// the flag, and the config key that switches the armed hook off.
				for (const command of [`git commit ${NO_VERIFY} -m test`, `git -c ${HOOKS_PATH_KEY}=/dev/null commit -m test`]) {
					const bypass = await handler({ toolName: "bash", input: { command } }, trusted(armed)) as { block?: boolean; reason?: string };
					expect(bypass.block).toBe(true);
				}

				expect(cargoLog(log)).toBe("");
			} finally {
				rmSync(armed, { recursive: true, force: true });
				rmSync(unarmed, { recursive: true, force: true });
			}
		});
	});
});

describe("pi-hooks bash guard passthrough", () => {
	test("spawns each armed guard's rendered hook in turn and stops at the first refusal", async () => {
		const project = initCleanRustRepo("pi-hooks-project-");
		const log = join(project, "order.log");
		try {
			renderStub(project, "block-bare-cd", { exitCode: 0, log });
			renderStub(project, "block-repo-copy", { exitCode: 2, stderr: "block-repo-copy=refused", log });
			renderStub(project, "pre-commit-check", { exitCode: 2, stderr: "pre-commit-check=refused", log });
			const handler = installToolCallHandler();
			const result = await handler({ toolName: "bash", input: { command: "cp -r . /tmp/x" } }, trusted(project)) as { block?: boolean; reason?: string };
			expect(result).toEqual({ block: true, reason: "block-repo-copy=refused" });
			// Two payloads read, not three: pre-commit-check never ran.
			expect(readLog(log).split("}{").length).toBe(2);
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("the real rendered block-bare-cd still blocks a bare cd and passes a chained one", async () => {
		const project = initCleanRustRepo("pi-hooks-project-");
		try {
			renderRealHook(project, "block-bare-cd");
			const handler = installToolCallHandler();
			for (const command of ["cd /tmp", "cd"]) {
				const result = await handler({ toolName: "bash", input: { command } }, trusted(project)) as { block?: boolean; reason?: string };
				expect(result.block).toBe(true);
			}
			expect(await handler({ toolName: "bash", input: { command: "(cd /tmp && ls)" } }, trusted(project))).toBeUndefined();
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("passes reviewer searches whose patterns contain backticks (kendex#668)", async () => {
		const project = initCleanRustRepo("pi-hooks-project-");
		try {
			for (const name of ["block-bare-cd", "block-repo-copy", "pre-commit-check"]) renderRealHook(project, name);
			const handler = installToolCallHandler();
			expect(await handler({ toolName: "bash", input: { command: 'rg -n "`kendex refresh`" skills/' } }, trusted(project))).toBeUndefined();
			expect(await handler({ toolName: "bash", input: { command: "rg -n '\\x60kendex refresh\\x60' skills/" } }, trusted(project))).toBeUndefined();
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});
});
