import { afterAll, beforeAll, expect, spyOn, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CONFIG_ID, installCarrier, type ListenerHandler, type SentCall, toolResultEvent, trusted, useIsolatedGitEnv } from "./harness.ts";

import * as cargo from "../extensions/cargo.ts";

useIsolatedGitEnv();

/* The host's clippy slot lives in the system temporary directory, where a Pi
 * lane on this host may hold it for real. This file's runs take a directory
 * of their own, so neither waits on the other. */
let savedTmp: string | undefined;
let scratchTmp: string | undefined;
beforeAll(() => {
	savedTmp = process.env.TMPDIR;
	scratchTmp = mkdtempSync(join(tmpdir(), "pi-hooks-clippy-tmp-"));
	process.env.TMPDIR = scratchTmp;
});
afterAll(() => {
	if (savedTmp === undefined) delete process.env.TMPDIR;
	else process.env.TMPDIR = savedTmp;
	if (scratchTmp !== undefined) rmSync(scratchTmp, { recursive: true, force: true });
});

/** The slot file every carrier on a host reads, by the name they read it at. */
function slotPath(): string {
	return join(tmpdir(), "kendex-pi-hooks-clippy.slot");
}

type TurnHandler = ListenerHandler;
type TurnHooks = { onToolResult: TurnHandler; onTurnEnd: TurnHandler; onTurnStart: TurnHandler; sent: SentCall[] };

function installTurnHandlers(): TurnHooks {
	const carrier = installCarrier();
	return {
		onToolResult: carrier.handler("tool_result"),
		onTurnEnd: carrier.handler("turn_end"),
		onTurnStart: carrier.handler("turn_start"),
		sent: carrier.sent,
	};
}

/** A project whose settings arm the end-of-turn check the fixtures above leave off. */
function initClippyProject(clippyTimeoutMs = 4000): string {
	const dir = mkdtempSync(join(tmpdir(), "pi-hooks-clippy-"));
	mkdirSync(join(dir, ".pi"), { recursive: true });
	writeFileSync(join(dir, ".pi", "settings.json"), JSON.stringify({
		kendex: {
			extensionManager: {
				config: { [CONFIG_ID]: { enabled: true, taskCompletedCheck: true, sessionDriftCheck: false, clippyTimeoutMs } },
			},
		},
	}));
	mkdirSync(join(dir, "src"), { recursive: true });
	writeFileSync(join(dir, "src", "lib.rs"), "pub fn answer() -> i32 { 42 }\n");
	return dir;
}

/**
 * A cargo naming `root` as the workspace and failing clippy with one error
 * line. FAKE_CLIPPY_EXIT and FAKE_CLIPPY_SILENT vary the verdict.
 * FAKE_CLIPPY_LOG gets a `start` and an `end` line around each clippy run,
 * FAKE_CLIPPY_SLEEP holds the run that many seconds, and FAKE_CLIPPY_CHILD
 * gets the pid of a child the run forks and waits on, as cargo forks rustc.
 */
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
		'if [ -n "${FAKE_CLIPPY_LOG:-}" ]; then printf \'start\\n\' >> "$FAKE_CLIPPY_LOG"; fi',
		'if [ -n "${FAKE_CLIPPY_CHILD:-}" ]; then /bin/sleep 30 & printf \'%s\' "$!" > "$FAKE_CLIPPY_CHILD"; wait; fi',
		'if [ -n "${FAKE_CLIPPY_SLEEP:-}" ]; then /bin/sleep "$FAKE_CLIPPY_SLEEP"; fi',
		'if [ -n "${FAKE_CLIPPY_LOG:-}" ]; then printf \'end\\n\' >> "$FAKE_CLIPPY_LOG"; fi',
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

type Knobs = { exit?: string; silent?: string; log?: string; sleep?: string; child?: string };

async function onPath(bin: string, run: () => Promise<void>, knobs: Knobs = {}): Promise<void> {
	const names = ["PATH", "FAKE_CLIPPY_EXIT", "FAKE_CLIPPY_SILENT", "FAKE_CLIPPY_LOG", "FAKE_CLIPPY_SLEEP", "FAKE_CLIPPY_CHILD"] as const;
	const saved = names.map((name) => process.env[name]);
	process.env.PATH = bin;
	process.env.FAKE_CLIPPY_EXIT = knobs.exit ?? "101";
	process.env.FAKE_CLIPPY_SILENT = knobs.silent ?? "0";
	for (const [name, value] of [["FAKE_CLIPPY_LOG", knobs.log], ["FAKE_CLIPPY_SLEEP", knobs.sleep], ["FAKE_CLIPPY_CHILD", knobs.child]] as const) {
		if (value === undefined) delete process.env[name];
		else process.env[name] = value;
	}
	try { await run(); } finally {
		for (const [index, name] of names.entries()) {
			if (saved[index] === undefined) delete process.env[name];
			else process.env[name] = saved[index];
		}
	}
}

async function editingTurn(hooks: TurnHooks, project: string, ctx: Record<string, unknown>): Promise<void> {
	await hooks.onToolResult(toolResultEvent("edit", { path: join(project, "src", "lib.rs") }), ctx);
	await hooks.onTurnEnd({}, ctx);
}

function expectSteered(call: SentCall): void {
	expect(call.options).toEqual({ triggerTurn: true });
	expect(call.message.customType).toBe("kendex-clippy");
	expect(call.message.display).toBe(false);
}

for (const row of [
	{ name: "headless errors", ui: false, code: "101", silent: "0", cargo: true, key: "clippy-errors=1" },
	{ name: "interactive errors", ui: true, code: "101", silent: "0", cargo: true, key: "clippy-errors=1" },
	{ name: "clean", ui: true, code: "0", silent: "0", cargo: true, key: undefined },
	{ name: "missing workspace", ui: false, code: "101", silent: "0", cargo: false, key: "clippy-workspace=" },
	{ name: "no error line", ui: false, code: "101", silent: "1", cargo: true, key: "clippy-exit=101" },
	{ name: "timed out", ui: false, code: "101", silent: "0", cargo: true, key: "clippy-timeout-ms=3000" },
]) {
	test(`clippy reports ${row.name}`, async () => {
		const project = initClippyProject();
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		const notices: string[] = [];
		const timeout = row.name === "timed out" ? spyOn(cargo, "runWorkspaceClippy").mockResolvedValue({ exitCode: -1, stdout: "", stderr: "", stoppedBy: "timeout" }) : undefined;
		try {
			const bin = row.cargo ? fakeClippyBin(cargoRoot, project) : cargoRoot;
			await onPath(bin, async () => {
				const hooks = installTurnHandlers();
				await editingTurn(hooks, project, trusted(project, row.ui ? {
					hasUI: true, ui: { notify: (message: string) => notices.push(message) },
				} : {}));
				expect(hooks.sent).toHaveLength(row.key === undefined ? 0 : 1);
				expect(notices).toHaveLength(row.ui && row.key !== undefined ? 1 : 0);
				if (row.key === undefined) return;
				const call = hooks.sent[0]!;
				expectSteered(call);
				expect(call.message.content.split("\n")[0]).toBe(row.key + (row.cargo ? "" : project));
				if (row.key === "clippy-errors=1") expect(call.message.content).toContain("error[E0425]");
				if (row.ui) expect(notices).toEqual([call.message.content]);
			}, { exit: row.code, silent: row.silent });
		} finally {
			timeout?.mockRestore();
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
		}
	});
}

for (const row of [
	{ name: "lookup recovery", turns: ["missing", "edit"], keys: ["clippy-workspace=", "clippy-errors=1"] },
	{ name: "repeated failure", turns: ["edit", "edit", "edit"], keys: ["clippy-errors=1", "clippy-errors=1", "clippy-errors=1"] },
	{ name: "untouched turn resets", turns: ["edit", "untouched"], keys: ["clippy-errors=1"] },
]) {
	test(`clippy lifecycle: ${row.name}`, async () => {
		const project = initClippyProject();
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		const emptyBin = join(cargoRoot, "empty");
		mkdirSync(emptyBin);
		try {
			const hooks = installTurnHandlers();
			const ctx = trusted(project);
			const bin = fakeClippyBin(cargoRoot, project);
			let reports = 0;
			for (const turn of row.turns) {
				await hooks.onTurnStart({}, ctx);
				await onPath(turn === "missing" ? emptyBin : bin, async () => {
					if (turn === "untouched") await hooks.onTurnEnd({}, ctx);
					else await editingTurn(hooks, project, ctx);
				});
				if (turn !== "untouched") reports++;
				expect(hooks.sent).toHaveLength(reports);
				for (const call of hooks.sent) expectSteered(call);
			}
			expect(hooks.sent.map((call) => call.message.content.split("\n")[0])).toEqual(row.keys.map((key) => key === "clippy-workspace=" ? key + project : key));
			if (row.name === "repeated failure") expect(hooks.sent[2]?.message.content).toBe(hooks.sent[0]?.message.content);
		} finally {
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
		}
	});
}

function pidAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

/** Poll `check` every 20ms until it holds or `ms` pass. A real child exits
 * on its own schedule after a signal, and this is that wait. */
async function until(check: () => boolean, ms: number): Promise<boolean> {
	const stop = Date.now() + ms;
	while (!check()) {
		if (Date.now() >= stop) return false;
		await new Promise((resolve) => setTimeout(resolve, 20));
	}
	return true;
}

test("clippy runs off Pi's thread: a timer fires while cargo compiles", async () => {
	const project = initClippyProject();
	const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
	const log = join(cargoRoot, "runs.log");
	try {
		const bin = fakeClippyBin(cargoRoot, project);
		await onPath(bin, async () => {
			const hooks = installTurnHandlers();
			// A real wait: the subject is whether Pi's event loop turns while
			// cargo runs, and a timer is what a keystroke's echo waits behind.
			// It records how far the run had got when it fired: a blocked loop
			// fires it only once the run has ended.
			let seen: string | undefined;
			const tick = setInterval(() => {
				const runs = readFileSync(log, { encoding: "utf8", flag: "a+" });
				if (runs !== "") seen ??= runs;
			}, 20);
			try {
				await editingTurn(hooks, project, trusted(project));
				expect(seen).toBe("start\n");
				expect(hooks.sent.map((call) => call.message.content.split("\n")[0])).toEqual(["clippy-errors=1"]);
			} finally { clearInterval(tick); }
		}, { log, sleep: "0.5" });
	} finally {
		rmSync(project, { recursive: true, force: true });
		rmSync(cargoRoot, { recursive: true, force: true });
	}
});

// The two ways a run is cut off, each stopping the whole process tree cargo
// started rather than cargo alone, and each freeing the host's slot. The
// person ending the turn says nothing to an agent that is no longer running.
for (const row of [
	{ name: "timeout", timeoutMs: 1000, abort: false, key: "clippy-timeout-ms=750" },
	{ name: "abort", timeoutMs: 20_000, abort: true, key: undefined },
]) {
	test(`clippy ${row.name} stops the compiler's whole process tree`, async () => {
		const project = initClippyProject(row.timeoutMs);
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		const childFile = join(cargoRoot, "child.pid");
		let childPid: number | undefined;
		try {
			const bin = fakeClippyBin(cargoRoot, project);
			await onPath(bin, async () => {
				const hooks = installTurnHandlers();
				const turn = new AbortController();
				const ctx = trusted(project, { signal: turn.signal });
				await hooks.onToolResult(toolResultEvent("edit", { path: join(project, "src", "lib.rs") }), ctx);
				const ended = hooks.onTurnEnd({}, ctx);
				expect(await until(() => existsSync(childFile) && readFileSync(childFile, "utf8") !== "", 5000)).toBe(true);
				childPid = Number(readFileSync(childFile, "utf8"));
				expect(pidAlive(childPid)).toBe(true);
				if (row.abort) turn.abort();
				await ended;
				expect(await until(() => !pidAlive(childPid!), 3000)).toBe(true);
				expect(existsSync(slotPath())).toBe(false);
				expect(hooks.sent.map((call) => call.message.content.split("\n")[0])).toEqual(row.key === undefined ? [] : [row.key]);
			}, { child: childFile });
		} finally {
			if (childPid !== undefined && pidAlive(childPid)) process.kill(childPid, "SIGKILL");
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
		}
	});
}

test("two lanes on one host run clippy one at a time", async () => {
	const project = initClippyProject(20_000);
	const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
	const log = join(cargoRoot, "runs.log");
	try {
		const bin = fakeClippyBin(cargoRoot, project);
		await onPath(bin, async () => {
			const lanes = [installTurnHandlers(), installTurnHandlers()];
			await Promise.all(lanes.map((hooks) => editingTurn(hooks, project, trusted(project))));
			expect(readFileSync(log, "utf8")).toBe("start\nend\nstart\nend\n");
			for (const hooks of lanes) expect(hooks.sent.map((call) => call.message.content.split("\n")[0])).toEqual(["clippy-errors=1"]);
			expect(existsSync(slotPath())).toBe(false);
		}, { log, sleep: "0.3" });
	} finally {
		rmSync(project, { recursive: true, force: true });
		rmSync(cargoRoot, { recursive: true, force: true });
	}
});

// A slot another lane holds is waited on for the budget; one no live holder
// names is taken over. The live row's holder is this process under another
// claim, and its budget is 1000ms, so 750ms of waiting past the lookup.
const deadPid = spawnSync("true").pid;
for (const row of [
	{ name: "a live holder is waited on for the budget", holder: () => JSON.stringify({ pid: process.pid, token: "other-lane", until: Date.now() + 60_000 }), key: "clippy-timeout-ms=750", ran: "" },
	{ name: "a dead holder's slot is taken over", holder: () => JSON.stringify({ pid: deadPid, token: "dead-lane", until: Date.now() + 60_000 }), key: "clippy-errors=1", ran: "start\nend\n" },
	{ name: "a holder past its deadline is taken over", holder: () => JSON.stringify({ pid: process.pid, token: "late-lane", until: Date.now() - 1 }), key: "clippy-errors=1", ran: "start\nend\n" },
	{ name: "a slot naming no holder is taken over", holder: () => "not a holder", key: "clippy-errors=1", ran: "start\nend\n" },
]) {
	test(`clippy slot: ${row.name}`, async () => {
		const project = initClippyProject(1000);
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		const log = join(cargoRoot, "runs.log");
		try {
			writeFileSync(slotPath(), row.holder());
			const bin = fakeClippyBin(cargoRoot, project);
			await onPath(bin, async () => {
				const hooks = installTurnHandlers();
				await editingTurn(hooks, project, trusted(project));
				expect(hooks.sent.map((call) => call.message.content.split("\n")[0])).toEqual([row.key]);
				expect(readFileSync(log, { encoding: "utf8", flag: "a+" })).toBe(row.ran);
			}, { log });
		} finally {
			rmSync(slotPath(), { force: true });
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
		}
	});
}
