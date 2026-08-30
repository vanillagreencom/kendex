import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

import { runCargo } from "../extensions/cargo.ts";
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
	// A fake cargo stays on PATH throughout as the control: withFakeCargo proves
	// it reachable before handing over, and the gate defers or refuses without
	// running a check of its own, so the log must stay empty.
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
