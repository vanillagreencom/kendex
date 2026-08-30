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

type TurnHandler = (event: Record<string, unknown>, ctx: Record<string, unknown>) => Promise<unknown>;
type SentMessage = { customType: string; content: string; display: boolean };
/** Both arguments of every `pi.sendMessage` call: the options decide delivery, so they are asserted. */
type SentCall = { message: SentMessage; options: Record<string, unknown> | undefined };
type TurnHooks = { onToolResult: TurnHandler; onTurnEnd: TurnHandler; onSessionStart: TurnHandler; sent: SentCall[] };

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
	const onSessionStart = handlers.get("session_start");
	if (!onToolResult || !onTurnEnd || !onSessionStart) throw new Error("turn hooks were not registered");
	return { onToolResult, onTurnEnd, onSessionStart, sent };
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

/** A cargo naming `root` as the workspace, failing clippy with one error line and a location. FAKE_CLIPPY_EXIT, _SILENT and _LOC vary the run. */
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
		'if [ "${FAKE_CLIPPY_SILENT:-}" != "1" ]; then',
		"  printf '%s\\n' 'error[E0425]: cannot find value nope in this scope'",
		'  printf \'  --> src/lib.rs:%s\\n\' "${FAKE_CLIPPY_LOC:-1:1}"',
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

	// The steered message makes the agent take another turn, which can edit and
	// fail the same way. Without the repeat guard that is a loop; with it an
	// agent making no progress is told once.
	test("an unchanged summary is steered once, however many turns repeat it", async () => {
		const project = initClippyProject();
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		const notices: string[] = [];
		try {
			await onPath(fakeClippyBin(cargoRoot, project), async () => {
				const hooks = installTurnHandlers();
				const ctx = {
					cwd: project,
					isProjectTrusted: () => true,
					hasUI: true,
					ui: { notify: (message: string) => notices.push(message) },
				};
				await editingTurn(hooks, project, ctx);
				await editingTurn(hooks, project, ctx);
				await editingTurn(hooks, project, ctx);
				expect(hooks.sent).toHaveLength(1);
				// The notification is not a loop risk and keeps reporting.
				expect(notices).toHaveLength(3);
			});
		} finally {
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
		}
	});

	test("an error returning after a clean turn is steered again", async () => {
		const project = initClippyProject();
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		try {
			await onPath(fakeClippyBin(cargoRoot, project), async () => {
				const hooks = installTurnHandlers();
				const ctx = { cwd: project, isProjectTrusted: () => true };
				await editingTurn(hooks, project, ctx);
				process.env.FAKE_CLIPPY_EXIT = "0";
				await editingTurn(hooks, project, ctx);
				delete process.env.FAKE_CLIPPY_EXIT;
				await editingTurn(hooks, project, ctx);
				expect(hooks.sent).toHaveLength(2);
				expect(hooks.sent[1].message.content).toBe(hooks.sent[0].message.content);
			});
		} finally {
			delete process.env.FAKE_CLIPPY_EXIT;
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
		}
	});

	// A1: a failed workspace lookup is a condition the session can leave. If it
	// were cached, every later turn would repeat the same unavailable summary
	// and the guard would suppress the recovery forever.
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

	// A2: clippy failing while printing nothing the filter recognises. The
	// workspace lookup succeeds here, so this reaches the branch the
	// no-cargo-on-PATH case never gets to.
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

	// A3: the summary is a count and five header lines, so an error that moves
	// renders identically. Suppressing on that loses real progress; the digest
	// covers everything clippy wrote, so only an unchanged run is suppressed.
	test("two runs that render alike but differ in full output are both steered", async () => {
		const project = initClippyProject();
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		try {
			await onPath(fakeClippyBin(cargoRoot, project), async () => {
				const hooks = installTurnHandlers();
				const ctx = { cwd: project, isProjectTrusted: () => true };
				process.env.FAKE_CLIPPY_LOC = "1:1";
				await editingTurn(hooks, project, ctx);
				process.env.FAKE_CLIPPY_LOC = "9:9";
				await editingTurn(hooks, project, ctx);
				expect(hooks.sent).toHaveLength(2);
				// The collision is real: both turns render the same text.
				expect(hooks.sent[1].message.content).toBe(hooks.sent[0].message.content);
			});
		} finally {
			delete process.env.FAKE_CLIPPY_LOC;
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
		}
	});

	// The fingerprint lives as long as the installed extension, but Pi starts a
	// new conversation in that same process. `/usr/lib/pi/docs/extensions.md`
	// gives the whole reason set as startup | reload | new | resume | fork, and
	// only `reload` leaves the conversation standing, so only `reload` keeps the
	// suppression. Anything else would carry one conversation's report into the
	// next and swallow its first failing turn.
	test("every session boundary but a reload steers a failure the last one reported", async () => {
		const project = initClippyProject();
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		try {
			await onPath(fakeClippyBin(cargoRoot, project), async () => {
				const steersAfter: Record<string, number> = {};
				for (const reason of ["startup", "reload", "new", "resume", "fork"]) {
					const hooks = installTurnHandlers();
					const ctx = { cwd: project, isProjectTrusted: () => true };
					await editingTurn(hooks, project, ctx);
					await hooks.onSessionStart({ reason }, ctx);
					await editingTurn(hooks, project, ctx);
					steersAfter[reason] = hooks.sent.length;
				}
				expect(steersAfter).toEqual({ startup: 2, reload: 1, new: 2, resume: 2, fork: 2 });
			});
		} finally {
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
		}
	});
});
