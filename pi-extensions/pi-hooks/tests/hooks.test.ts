import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { runCargo } from "../extensions/cargo.ts";
import { PROJECT_LOCK_FILE, PROJECT_MARKER_DIRS, projectRoot, readConfig, recordProjectTrust, rootAnchored } from "../extensions/config.ts";
import piHooks from "../extensions/hooks.ts";
import {
	CONFIG_ID,
	initRustRepo,
	installToolCallHandler,
	readLog,
	renderedHookPath,
	renderStub,
	renderUserStub,
	runGit,
	trusted,
	useIsolatedGitEnv,
} from "./harness.ts";

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
 * environment snapshot rather than the live `process.env`, so the fake sat
 * unreachable and every assertion below was vacuous until runCargo started
 * passing an explicit env (KEN-843).
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

// The marker the growth-guards installer ends its delegating line with, and the
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

/** Put the repository's real hook where kendex renders it. */
function renderRealHook(project: string, name: string): void {
	mkdirSync(join(project, ".pi", "kendex", "hooks"), { recursive: true });
	const source = join(import.meta.dir, "..", "..", "..", "hooks", `${name}.sh`);
	writeFileSync(renderedHookPath(project, name), readFileSync(source, "utf8"));
	chmodSync(renderedHookPath(project, name), 0o755);
}

function runHandlerChild(home: string, workspace: string, agentDir: string, trusted: boolean): ReturnType<typeof spawnSync> {
	const modulePath = join(import.meta.dir, "..", "extensions", "hooks.ts");
	const program = `
import piHooks from ${JSON.stringify(modulePath)};
let handler;
piHooks({ on(event, callback) { if (event === "tool_call") handler = callback; } });
const result = await handler(
	{ toolName: "bash", input: { command: "git commit -m x" } },
	{ cwd: ${JSON.stringify(workspace)}, isProjectTrusted: () => ${trusted} },
);
process.stdout.write(JSON.stringify(result ?? null));
`;
	return spawnSync(process.execPath, ["-e", program], {
		cwd: workspace,
		encoding: "utf8",
		env: { ...process.env, HOME: home, PI_CODING_AGENT_DIR: agentDir },
	});
}

/** `projectRoot` under a given HOME, in a child because homedir() reads the
 * process's own environment. */
function projectRootUnder(home: string, cwd: string): string | null {
	const child = spawnSync(process.execPath, ["-e", `
import { projectRoot } from ${JSON.stringify(join(import.meta.dir, "..", "extensions", "config.ts"))};
process.stdout.write(JSON.stringify(projectRoot(process.argv[1]) ?? null));
`, cwd], { encoding: "utf8", env: { ...process.env, HOME: home } });
	if (child.status !== 0) throw new Error(child.stderr);
	return JSON.parse(child.stdout) as string | null;
}

describe("pi-hooks root selection", () => {
	test("a subdirectory session runs the project's guard, and an untrusted one runs nothing of the project's", async () => {
		const project = initRustRepo("pi-hooks-subdir-");
		const nested = join(project, "crates", "core");
		const log = join(project, "payload.log");
		try {
			mkdirSync(nested, { recursive: true });
			renderStub(project, "pre-commit-check", { exitCode: 2, stderr: "pre-commit-check: refused", log });
			const handler = installToolCallHandler();

			// Pi saves a trust decision for the folder or any parent, so its
			// answer covers this whole tree: the guard rendered at the root runs
			// from a subdirectory exactly as it does from the root.
			const refused = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(nested)) as { block?: boolean; reason?: string };
			expect(refused).toEqual({ block: true, reason: "pre-commit-check: refused" });
			expect(readLog(log)).toContain("git commit -m x");

			// Untrusted, the project contributes nothing and no global root
			// holds this name, so the command passes with nothing spawned.
			writeFileSync(log, "");
			expect(await handler({ toolName: "bash", input: { command: "git commit -m x" } }, { cwd: nested, isProjectTrusted: () => false })).toBeUndefined();
			expect(readLog(log)).toBe("");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// The renderer walks for these and this reads from where it wrote. The
	// current-project rule is `project_root_from`, which consults the marker
	// directories and the lock file, not `is_project`'s MARKER_FILES.
	test("the project markers are the renderer's, case for case", () => {
		const crates = join(import.meta.dir, "..", "..", "..", "crates", "core", "src");
		const discover = readFileSync(join(crates, "discover.rs"), "utf8");
		const dirs = discover.match(/const MARKER_DIRS: \[&str; \d+\] = \[([\s\S]*?)\n\];/);
		expect(dirs, "MARKER_DIRS not found in crates/core/src/discover.rs").not.toBeNull();
		expect([...dirs![1]!.matchAll(/"([^"]+)"/g)].map(([, marker]) => marker)).toEqual([...PROJECT_MARKER_DIRS]);

		const lock = readFileSync(join(crates, "lock.rs"), "utf8").match(/const LOCK_FILE: &str = "([^"]+)";/);
		expect(lock, "LOCK_FILE not found in crates/core/src/lock.rs").not.toBeNull();
		expect(lock![1]).toBe(PROJECT_LOCK_FILE);

		// The walk tests each marker in the shape the renderer tests it in.
		expect(discover).toContain("MARKER_DIRS.iter().any(|m| dir.join(m).is_dir())");
		expect(discover).toContain("dir.join(crate::lock::LOCK_FILE).is_file()");
	});

	test("a vendored checkout inside a project does not stop the walk", async () => {
		const project = initRustRepo("pi-hooks-vendor-");
		const nested = join(project, "vendor", "nested");
		const log = join(project, "payload.log");
		try {
			// Were `.git/` a marker the walk would stop here, find no script, and
			// allow the command with an empty spawn log: every guard off, silently.
			mkdirSync(join(nested, ".git"), { recursive: true });
			renderStub(project, "pre-commit-check", { exitCode: 2, stderr: "pre-commit-check: refused", log });
			const handler = installToolCallHandler();
			const result = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(nested)) as { block?: boolean; reason?: string };
			expect(result).toEqual({ block: true, reason: "pre-commit-check: refused" });
			expect(readLog(log)).toContain("git commit -m x");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("a `.pi` file is not a project, and a marked one below it still is", () => {
		const outer = mkdtempSync(join(tmpdir(), "pi-hooks-shape-"));
		try {
			const inner = join(outer, "inner");
			mkdirSync(join(inner, "deep"), { recursive: true });
			writeFileSync(join(inner, ".pi"), "not a directory\n");
			expect(projectRoot(join(inner, "deep"))).toBeUndefined();
			mkdirSync(join(inner, ".claude"), { recursive: true });
			expect(projectRoot(join(inner, "deep"))).toBe(realpathSync(inner));
		} finally {
			rmSync(outer, { recursive: true, force: true });
		}
	});

	// Pi's global root lives under home, so a marker there must not make home the
	// project: that would spawn ~/.pi/kendex/hooks/<name>.sh, which kendex never
	// renders, and merge ~/.pi/settings.json over the kendex global scope. The
	// lock file is the one exception, and the renderer's exception too.
	test("home is not the project, spelled either way, and a session in it has none", () => {
		const real = mkdtempSync(join(tmpdir(), "pi-hooks-home-"));
		const link = join(mkdtempSync(join(tmpdir(), "pi-hooks-link-")), "home");
		try {
			symlinkSync(real, link, "dir");
			mkdirSync(join(real, ".pi"), { recursive: true });
			mkdirSync(join(real, "notes"), { recursive: true });

			// Both spellings of one directory answer the same: `resolve` does not
			// dereference symlinks, so a spelling comparison would miss on any
			// machine whose home path carries one.
			for (const home of [real, link]) {
				expect(projectRootUnder(home, join(home, "notes"))).toBeNull();
				expect(projectRootUnder(home, home)).toBeNull();
			}

			// The lock file wins wherever it stands, home included — the renderer's
			// own rule, applied before it writes.
			writeFileSync(join(real, PROJECT_LOCK_FILE), "{}\n");
			for (const home of [real, link]) {
				expect(projectRootUnder(home, join(home, "notes"))).toBe(realpathSync(real));
			}
		} finally {
			rmSync(real, { recursive: true, force: true });
			rmSync(dirname(link), { recursive: true, force: true });
		}
	});

	test("a relative global override is refused, and an absolute or blank one answers", () => {
		const home = mkdtempSync(join(tmpdir(), "pi-hooks-global-home-"));
		const workspace = mkdtempSync(join(tmpdir(), "pi-hooks-global-workspace-"));
		const absolute = mkdtempSync(join(tmpdir(), "pi-hooks-global-absolute-"));
		try {
			// A relative value would root the global scope at the session's own
			// directory, where a checkout's script reaches the branch that never
			// asks about trust. The default answers instead.
			const cases = [
				["relative/agent", join(home, ".pi", "agent")],
				["   ", join(home, ".pi", "agent")],
				[absolute, absolute],
			] as const;
			for (const [agentDir, root] of cases) {
				const log = join(root, "payload.log");
				renderUserStub(root, "pre-commit-check", { exitCode: 2, stderr: "global refused", log });
				const child = runHandlerChild(home, workspace, agentDir, false);
				expect(child.status, child.stderr).toBe(0);
				expect(JSON.parse(child.stdout)).toEqual({ block: true, reason: "global refused" });
				expect(readLog(log)).toContain("git commit -m x");
				rmSync(join(root, "kendex"), { recursive: true, force: true });
			}

			// The control: the same relative value with a script planted where
			// it would have pointed. Nothing is found, so nothing runs.
			const planted = join(workspace, "relative", "agent");
			const log = join(workspace, "planted.log");
			renderUserStub(planted, "pre-commit-check", { exitCode: 2, stderr: "must not run", log });
			const child = runHandlerChild(home, workspace, "relative/agent", false);
			expect(child.status, child.stderr).toBe(0);
			expect(JSON.parse(child.stdout)).toBeNull();
			expect(readLog(log)).toBe("");
		} finally {
			for (const dir of [home, workspace, absolute]) rmSync(dir, { recursive: true, force: true });
		}
	});

	// The renderer decides where the guards are written and this decides where
	// they are read. A value the two read differently is a guard rendered under
	// one root and looked for under another, which is a silent allow.
	test("the root-anchored rule agrees with the renderer case for case", () => {
		const source = readFileSync(join(import.meta.dir, "..", "..", "..", "crates", "core", "src", "harness", "pi.rs"), "utf8");
		const table = source.match(/PI_ROOT_ABSOLUTE_CASES: &\[\(&str, bool, bool\)\] = &\[([\s\S]*?)\n\];/);
		expect(table, "PI_ROOT_ABSOLUTE_CASES not found in crates/core/src/harness/pi.rs").not.toBeNull();
		const cases = [...table![1]!.matchAll(/\("((?:[^"\\]|\\.)*)",\s*(true|false),\s*(true|false)\)/g)]
			.map(([, value, posix, windows]) => [JSON.parse(`"${value}"`) as string, posix === "true", windows === "true"] as const);
		expect(cases.length).toBeGreaterThanOrEqual(7);
		for (const [value, posix, windows] of cases) {
			expect(rootAnchored(value, false), `POSIX ${JSON.stringify(value)}`).toBe(posix);
			expect(rootAnchored(value, true), `Windows ${JSON.stringify(value)}`).toBe(windows);
		}
	});

	// readConfig, not the guard: the same answer gates merging the project's own
	// settings.json, and every default is on, so a read that should not have
	// happened turns a guard off.
	test("the project's settings are read only where Pi trusts the project", () => {
		const project = initRustRepo("pi-hooks-config-");
		const nested = join(project, "crates");
		try {
			mkdirSync(nested, { recursive: true });
			writeFileSync(join(project, ".pi", "settings.json"), JSON.stringify({
				kendex: { extensionManager: { config: { [CONFIG_ID]: { enabled: false } } } },
			}));
			recordProjectTrust({ cwd: nested, isProjectTrusted: () => false });
			expect(readConfig(nested).enabled).toBeUndefined();
			recordProjectTrust({ cwd: nested, isProjectTrusted: () => true });
			expect(readConfig(nested).enabled).toBe(false);
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// runCommandAsync sends SIGTERM at the budget and the child gets a grace
	// period, so a hook that traps the signal settles as timedOut with exit 0 —
	// the one status a cut-off run must never take.
	test("a hook that traps the signal and exits 0 past its budget still refuses", async () => {
		const project = initRustRepo("pi-hooks-budget-");
		try {
			writeFileSync(join(project, ".pi", "settings.json"), JSON.stringify({
				kendex: { extensionManager: { config: { [CONFIG_ID]: { hookTimeoutMs: 200, blockBareCd: false, blockRepoCopy: false } } } },
			}));
			const script = renderedHookPath(project, "pre-commit-check");
			mkdirSync(join(script, ".."), { recursive: true });
			writeFileSync(script, [
				"#!/usr/bin/env bash",
				"trap 'exit 0' TERM",
				"cat > /dev/null",
				"sleep 5 &",
				"wait $!",
				"exit 0",
			].join("\n") + "\n");
			chmodSync(script, 0o755);
			const handler = installToolCallHandler();
			const result = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(project)) as { block?: boolean; reason?: string };
			expect(result.block).toBe(true);
			expect(result.reason).toContain("timed out after 200ms");

			// The control: the same budget, a hook that finishes inside it.
			writeFileSync(script, ["#!/usr/bin/env bash", "cat > /dev/null", "exit 0"].join("\n") + "\n");
			expect(await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(project))).toBeUndefined();
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});
});


describe("pi-hooks pre-commit tool_call", () => {
	test("spawns the rendered hook with the payload a PreToolUse hook is sent", async () => {
		const project = initRustRepo("pi-hooks-project-");
		const log = join(project, "payload.log");
		try {
			renderStub(project, "pre-commit-check", { exitCode: 0, log });
			const handler = installToolCallHandler();
			expect(await handler({ toolName: "bash", input: { command: "git status" } }, trusted(project))).toBeUndefined();
			expect(JSON.parse(readLog(log))).toEqual({ tool_name: "Bash", tool_input: { command: "git status" } });
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("maps exit 2 to a block whose reason is the hook's stderr", async () => {
		const project = initRustRepo("pi-hooks-project-");
		const log = join(project, "payload.log");
		try {
			renderStub(project, "pre-commit-check", { exitCode: 2, stderr: "pre-commit-check: refused for a reason", log });
			const handler = installToolCallHandler();
			const result = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(project)) as { block?: boolean; reason?: string };
			expect(result).toEqual({ block: true, reason: "pre-commit-check: refused for a reason" });
			expect(readLog(log)).toContain("git commit -m x");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("exit 0 with stderr is a UI notice, never a block", async () => {
		const project = initRustRepo("pi-hooks-project-");
		const log = join(project, "payload.log");
		const notices: string[] = [];
		try {
			renderStub(project, "pre-commit-check", { exitCode: 0, stderr: "pre-commit-check: the command moves repositories", log });
			const handler = installToolCallHandler();
			const ctx = trusted(project, { hasUI: true, ui: { notify: (message: string) => notices.push(message) } });
			expect(await handler({ toolName: "bash", input: { command: "git commit -m x" } }, ctx)).toBeUndefined();
			expect(notices).toEqual(["pre-commit-check: the command moves repositories"]);
			// Headless Pi has no ui: the notice is dropped, never thrown.
			expect(await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(project))).toBeUndefined();
			expect(notices).toHaveLength(1);
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("a hook that exits without judging refuses rather than standing aside", async () => {
		const project = initRustRepo("pi-hooks-project-");
		const log = join(project, "payload.log");
		try {
			renderStub(project, "pre-commit-check", { exitCode: 1, stderr: "boom", log });
			const handler = installToolCallHandler();
			const result = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(project)) as { block?: boolean; reason?: string };
			expect(result.block).toBe(true);
			expect(result.reason).toContain("exited 1 without judging this command");
			expect(result.reason).toContain("boom");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("the preCommitCheck setting turns the gate off before any spawn", async () => {
		const project = initRustRepo("pi-hooks-project-");
		const log = join(project, "payload.log");
		writeFileSync(join(project, ".pi", "settings.json"), JSON.stringify({
			kendex: { extensionManager: { config: { [CONFIG_ID]: { preCommitCheck: false, blockBareCd: false, blockRepoCopy: false } } } },
		}));
		try {
			renderStub(project, "pre-commit-check", { exitCode: 2, stderr: "should never run", log });
			const handler = installToolCallHandler();
			const ctx = trusted(project);
			expect(await handler({ toolName: "bash", input: { command: "git commit -m x" } }, ctx)).toBeUndefined();
			expect(readLog(log)).toBe("");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

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
				expect(refused.reason).toContain("not armed by kendex");
				expect(refused.reason).toContain("kendex guard install");

				// Both bypass shapes, and the reason is the script's own stderr:
				// the flag, and the config key that switches the armed hook off.
				for (const command of [`git commit ${NO_VERIFY} -m test`, `git -c ${HOOKS_PATH_KEY}=/dev/null commit -m test`]) {
					const bypass = await handler({ toolName: "bash", input: { command } }, trusted(armed)) as { block?: boolean; reason?: string };
					expect(bypass.block).toBe(true);
					expect(bypass.reason).toContain("would skip this repository's armed git hooks");
					expect(bypass.reason).toContain("git commit -F <file>");
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
			renderStub(project, "block-repo-copy", { exitCode: 2, stderr: "block-repo-copy: refused", log });
			renderStub(project, "pre-commit-check", { exitCode: 2, stderr: "pre-commit-check: refused", log });
			const handler = installToolCallHandler();
			const result = await handler({ toolName: "bash", input: { command: "cp -r . /tmp/x" } }, trusted(project)) as { block?: boolean; reason?: string };
			expect(result).toEqual({ block: true, reason: "block-repo-copy: refused" });
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
				expect(result.reason).toContain("Use a subshell instead");
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

type TurnHandler = (event: Record<string, unknown>, ctx: Record<string, unknown>) => Promise<unknown>;
type SentMessage = { customType: string; content: string; display: boolean };
/** Both arguments of every `pi.sendMessage` call: the options decide delivery, so they are asserted. */
type SentCall = { message: SentMessage; options: Record<string, unknown> | undefined };
type TurnHooks = { onToolResult: TurnHandler; onTurnEnd: TurnHandler; onTurnStart: TurnHandler; sent: SentCall[] };

function installTurnHandlers(): TurnHooks {
	const handlers = new Map<string, TurnHandler>();
	const sent: SentCall[] = [];
	const pi = {
		on(event: string, cb: TurnHandler) {
			handlers.set(event, cb);
		},
		sendMessage(message: SentMessage, options?: Record<string, unknown>) {
			sent.push({ message, options });
		},
	};
	piHooks(pi as never);
	const onToolResult = handlers.get("tool_result");
	const onTurnEnd = handlers.get("turn_end");
	const onTurnStart = handlers.get("turn_start");
	if (!onToolResult || !onTurnEnd || !onTurnStart) throw new Error("turn hooks were not registered");
	return { onToolResult, onTurnEnd, onTurnStart, sent };
}

/** A project whose settings arm the end-of-turn check the fixtures above leave off. */
function initClippyProject(): string {
	const dir = mkdtempSync(join(tmpdir(), "pi-hooks-clippy-"));
	mkdirSync(join(dir, ".pi"), { recursive: true });
	writeFileSync(join(dir, ".pi", "settings.json"), JSON.stringify({
		kendex: {
			extensionManager: {
				config: { [CONFIG_ID]: { enabled: true, taskCompletedCheck: true, sessionDriftCheck: false, clippyTimeoutMs: 4000 } },
			},
		},
	}));
	mkdirSync(join(dir, "src"), { recursive: true });
	writeFileSync(join(dir, "src", "lib.rs"), "pub fn answer() -> i32 { 42 }\n");
	return dir;
}

/** A cargo naming `root` as the workspace and failing clippy with one error line. FAKE_CLIPPY_EXIT and FAKE_CLIPPY_SILENT vary the run. */
function fakeClippyBin(dir: string, root: string): string {
	const bin = join(dir, "bin");
	mkdirSync(bin, { recursive: true });
	const cargo = join(bin, "cargo");
	writeFileSync(cargo, [
		// A `/bin/sh` shebang, not `/usr/bin/env`: these fixtures run with PATH
		// narrowed to this directory, so nothing else is there to look up.
		"#!/bin/sh",
		"set -eu",
		'if [ "$1" = "metadata" ]; then',
		`  printf '{"workspace_root":"%s"}' ${JSON.stringify(root)}`,
		"  exit 0",
		"fi",
		// A line no error filter recognises, so the run reads as unavailable
		// rather than as errors.
		'if [ "${FAKE_CLIPPY_SILENT:-}" = "1" ]; then',
		"  printf '%s\\n' 'warning: nothing an error filter matches'",
		"else",
		"  printf '%s\\n' 'error[E0425]: cannot find value nope in this scope'",
		"fi",
		'exit "${FAKE_CLIPPY_EXIT:-101}"',
		"",
	].join("\n"));
	chmodSync(cargo, 0o755);
	return bin;
}

async function onPath(bin: string, run: () => Promise<void>): Promise<void> {
	const oldPath = process.env.PATH;
	process.env.PATH = bin;
	try {
		await run();
	} finally {
		if (oldPath === undefined) delete process.env.PATH;
		else process.env.PATH = oldPath;
	}
}

describe("pi-hooks end-of-turn clippy", () => {
	/** One turn that edits a `.rs` file, against an already-installed extension. */
	async function editingTurn(hooks: TurnHooks, project: string, ctx: Record<string, unknown>): Promise<void> {
		await hooks.onToolResult({ toolName: "edit", input: { path: join(project, "src", "lib.rs") } }, ctx);
		await hooks.onTurnEnd({}, ctx);
	}

	async function turnEditing(project: string, ctxExtras: Record<string, unknown>): Promise<SentCall[]> {
		const hooks = installTurnHandlers();
		await editingTurn(hooks, project, { cwd: project, isProjectTrusted: () => true, ...ctxExtras });
		return hooks.sent;
	}

	// `triggerTurn: true` is the whole delivery: since pi#8022 a `triggerTurn:
	// false` message is recorded without steering the active run, so a headless
	// run that is ending never reads it.
	function expectSteered(call: SentCall): void {
		expect(call.options).toEqual({ triggerTurn: true });
		expect(call.message.customType).toBe("kendex-clippy");
		expect(call.message.display).toBe(false);
	}

	test("a headless turn hands the agent the clippy summary", async () => {
		const project = initClippyProject();
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		try {
			await onPath(fakeClippyBin(cargoRoot, project), async () => {
				// No `hasUI`, no `ui`: the notification lane a headless Pi lacks.
				const sent = await turnEditing(project, {});
				expect(sent).toHaveLength(1);
				expectSteered(sent[0]);
				expect(sent[0].message.content).toContain("clippy reported 1 workspace error(s)");
				expect(sent[0].message.content).toContain("cannot find value nope");
			});
		} finally {
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
		}
	});

	test("an interactive turn notifies and hands the agent the same summary", async () => {
		const project = initClippyProject();
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		const notices: string[] = [];
		try {
			await onPath(fakeClippyBin(cargoRoot, project), async () => {
				const sent = await turnEditing(project, {
					hasUI: true,
					ui: { notify: (message: string) => notices.push(message) },
				});
				expect(notices).toHaveLength(1);
				expect(notices[0]).toContain("clippy reported 1 workspace error(s)");
				expect(sent).toHaveLength(1);
				expectSteered(sent[0]);
				expect(sent[0].message.content).toBe(notices[0]);
			});
		} finally {
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
		}
	});

	// The control: the same fixture with clippy passing must stay silent, or
	// the two tests above would pass on a hook that reports every turn.
	test("a clean turn says nothing in either lane", async () => {
		const project = initClippyProject();
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		const notices: string[] = [];
		process.env.FAKE_CLIPPY_EXIT = "0";
		try {
			await onPath(fakeClippyBin(cargoRoot, project), async () => {
				const sent = await turnEditing(project, {
					hasUI: true,
					ui: { notify: (message: string) => notices.push(message) },
				});
				expect(sent).toHaveLength(0);
				expect(notices).toHaveLength(0);
			});
		} finally {
			delete process.env.FAKE_CLIPPY_EXIT;
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
		}
	});

	test("a turn clippy could not judge says so rather than reading as clean", async () => {
		const project = initClippyProject();
		const emptyBin = mkdtempSync(join(tmpdir(), "pi-hooks-nocargo-"));
		try {
			await onPath(emptyBin, async () => {
				const sent = await turnEditing(project, {});
				expect(sent).toHaveLength(1);
				expectSteered(sent[0]);
				expect(sent[0].message.content).toContain("proved nothing about the tree");
			});
		} finally {
			rmSync(project, { recursive: true, force: true });
			rmSync(emptyBin, { recursive: true, force: true });
		}
	});

	// A failed workspace lookup is a condition the session can leave: if it were
	// cached, every later turn would report the tree unexaminable however
	// available cargo had since become.
	test("a workspace found after a failed lookup is reported on the next turn", async () => {
		const project = initClippyProject();
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		const emptyBin = mkdtempSync(join(tmpdir(), "pi-hooks-nocargo-"));
		try {
			const hooks = installTurnHandlers();
			const ctx = { cwd: project, isProjectTrusted: () => true };
			await onPath(emptyBin, () => editingTurn(hooks, project, ctx));
			await onPath(fakeClippyBin(cargoRoot, project), () => editingTurn(hooks, project, ctx));
			expect(hooks.sent).toHaveLength(2);
			expect(hooks.sent[0].message.content).toContain("proved nothing about the tree");
			expect(hooks.sent[1].message.content).toContain("clippy reported 1 workspace error(s)");
		} finally {
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
			rmSync(emptyBin, { recursive: true, force: true });
		}
	});

	// Clippy failing while printing nothing the filter recognises. The workspace
	// lookup succeeds here, so this reaches the branch the no-cargo-on-PATH case
	// never gets to.
	test("clippy failing with no error line is reported as unjudgeable", async () => {
		const project = initClippyProject();
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		process.env.FAKE_CLIPPY_SILENT = "1";
		try {
			await onPath(fakeClippyBin(cargoRoot, project), async () => {
				const sent = await turnEditing(project, {});
				expect(sent).toHaveLength(1);
				expectSteered(sent[0]);
				expect(sent[0].message.content).toContain("cargo clippy exited 101 printing no error line");
			});
		} finally {
			delete process.env.FAKE_CLIPPY_SILENT;
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
		}
	});

	// The behaviour a repeat guard used to suppress, asserted rather than left
	// as an absence. An agent that cannot fix an error hears the same advisory
	// each turn: noisy and self-correcting, where withholding it can leave a
	// headless turn told nothing when there was something to say.
	test("a second identical failing turn steers again", async () => {
		const project = initClippyProject();
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		try {
			await onPath(fakeClippyBin(cargoRoot, project), async () => {
				const hooks = installTurnHandlers();
				const ctx = { cwd: project, isProjectTrusted: () => true };
				await editingTurn(hooks, project, ctx);
				await editingTurn(hooks, project, ctx);
				await editingTurn(hooks, project, ctx);
				expect(hooks.sent).toHaveLength(3);
				expect(hooks.sent[2].message.content).toBe(hooks.sent[0].message.content);
			});
		} finally {
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
		}
	});

	// What bounds the reporting now that nothing suppresses a repeat: the turn
	// state. A steered turn that writes no `.rs` file runs no clippy and reports
	// nothing, so each further report costs the agent an edit.
	test("a turn that touched no Rust steers nothing, however the last one ended", async () => {
		const project = initClippyProject();
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		try {
			await onPath(fakeClippyBin(cargoRoot, project), async () => {
				const hooks = installTurnHandlers();
				const ctx = { cwd: project, isProjectTrusted: () => true };
				await editingTurn(hooks, project, ctx);
				expect(hooks.sent).toHaveLength(1);
				// The turn the steered message provokes, editing nothing.
				await hooks.onTurnStart({}, ctx);
				await hooks.onTurnEnd({}, ctx);
				expect(hooks.sent).toHaveLength(1);
			});
		} finally {
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
		}
	});
});
