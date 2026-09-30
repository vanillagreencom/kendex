import { afterAll, beforeAll, expect, spyOn, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CONFIG_ID, installCarrier, type ListenerHandler, type SentCall, toolResultEvent, trusted, useIsolatedGitEnv } from "./harness.ts";

import * as cargo from "../extensions/cargo.ts";
import { clearPackageConfigCache } from "../extensions/package-config.ts";

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

/** The slot file every carrier this user runs on a host reads, by the name
 * they read it at. */
function slotName(): string {
	return `kendex-pi-hooks-clippy-${process.getuid!()}.slot`;
}

function slotPath(): string {
	return join(tmpdir(), slotName());
}

type TurnHandler = ListenerHandler;
type TurnHooks = { onToolResult: TurnHandler; onTurnEnd: TurnHandler; sent: SentCall[] };

function installTurnHandlers(): TurnHooks {
	const carrier = installCarrier();
	return {
		onToolResult: carrier.handler("tool_result"),
		onTurnEnd: carrier.handler("turn_end"),
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
	// What pi-extension-manager's settings-changed event does after a write.
	clearPackageConfigCache();
	mkdirSync(join(dir, "src"), { recursive: true });
	writeFileSync(join(dir, "src", "lib.rs"), "pub fn answer() -> i32 { 42 }\n");
	return dir;
}

/** Another lane's slot record, as the fake's takeover writes it. */
const TAKER = JSON.stringify({ pid: 1, token: "taker-lane", until: 4_102_444_800_000 });

/**
 * A cargo naming `root` as the workspace and failing clippy with one error
 * line. FAKE_CLIPPY_EXIT and FAKE_CLIPPY_SILENT vary the verdict.
 * FAKE_CLIPPY_LOG gets a `start` and an `end` line around each clippy run,
 * FAKE_CLIPPY_SLEEP holds the run that many seconds, and FAKE_CLIPPY_CHILD
 * gets the pid of a child the run forks and waits on, as cargo forks rustc.
 * FAKE_METADATA_HOLD is a file the workspace lookup creates before it hangs,
 * and FAKE_CLIPPY_TAKEOVER a slot file the run overwrites with another
 * lane's record, as a waiter that judged the slot stale does.
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
		'  if [ -n "${FAKE_METADATA_HOLD:-}" ]; then : > "$FAKE_METADATA_HOLD"; /bin/sleep 30; fi',
		`  printf '{"workspace_root":"%s"}' ${JSON.stringify(root)}`,
		"  exit 0",
		"fi",
		'if [ -n "${FAKE_CLIPPY_LOG:-}" ]; then printf \'start\\n\' >> "$FAKE_CLIPPY_LOG"; fi',
		`if [ -n "\${FAKE_CLIPPY_TAKEOVER:-}" ]; then printf '%s' '${TAKER}' > "$FAKE_CLIPPY_TAKEOVER"; fi`,
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

type Knobs = { exit?: string; silent?: string; log?: string; sleep?: string; child?: string; hold?: string; takeover?: string };

async function onPath(bin: string, run: () => Promise<void>, knobs: Knobs = {}): Promise<void> {
	const names = ["PATH", "FAKE_CLIPPY_EXIT", "FAKE_CLIPPY_SILENT", "FAKE_CLIPPY_LOG", "FAKE_CLIPPY_SLEEP", "FAKE_CLIPPY_CHILD", "FAKE_METADATA_HOLD", "FAKE_CLIPPY_TAKEOVER"] as const;
	const saved = names.map((name) => process.env[name]);
	process.env.PATH = bin;
	process.env.FAKE_CLIPPY_EXIT = knobs.exit ?? "101";
	process.env.FAKE_CLIPPY_SILENT = knobs.silent ?? "0";
	for (const [name, value] of [
		["FAKE_CLIPPY_LOG", knobs.log],
		["FAKE_CLIPPY_SLEEP", knobs.sleep],
		["FAKE_CLIPPY_CHILD", knobs.child],
		["FAKE_METADATA_HOLD", knobs.hold],
		["FAKE_CLIPPY_TAKEOVER", knobs.takeover],
	] as const) {
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

// Each turn is one of: an edit to lib.rs with cargo on PATH, the same edit
// with no cargo, no edit at all, or an edit in a turn whose run the person
// ended before `turn_end`, which Pi then fires with the signal aborted. Each
// turn's key is what it reports, or `null` for nothing.
for (const row of [
	{ name: "lookup recovery", turns: [["missing", "clippy-workspace="], ["edit", "clippy-errors=1"]] },
	{ name: "repeated failure", turns: [["edit", "clippy-errors=1"], ["edit", "clippy-errors=1"], ["edit", "clippy-errors=1"]] },
	{ name: "untouched turn resets", turns: [["edit", "clippy-errors=1"], ["untouched", null]] },
	{ name: "an ended check's edits carry to the next turn", turns: [["aborted", null], ["untouched", "clippy-errors=1"], ["untouched", null]] },
] as const) {
	test(`clippy lifecycle: ${row.name}`, async () => {
		const project = initClippyProject();
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		const emptyBin = join(cargoRoot, "empty");
		mkdirSync(emptyBin);
		try {
			const hooks = installTurnHandlers();
			const bin = fakeClippyBin(cargoRoot, project);
			const keys: string[] = [];
			for (const [turn, key] of row.turns) {
				const ended = new AbortController();
				if (turn === "aborted") ended.abort();
				const ctx = trusted(project, { signal: ended.signal });
				await onPath(turn === "missing" ? emptyBin : bin, async () => {
					if (turn === "untouched") await hooks.onTurnEnd({}, ctx);
					else await editingTurn(hooks, project, ctx);
				});
				if (key !== null) keys.push(key === "clippy-workspace=" ? key + project : key);
				expect(hooks.sent.map((call) => call.message.content.split("\n")[0])).toEqual(keys);
				for (const call of hooks.sent) expectSteered(call);
			}
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

/** Fill `findCargoWorkspaceRoot`'s per-cwd cache, so a timed turn spends
 * its budget on the slot and the clippy run alone and no spawn of the fake's
 * lookup races a short deadline. */
async function primeLookup(project: string): Promise<void> {
	expect(await cargo.findCargoWorkspaceRoot(project, 20_000)).toBe(project);
}

/** Whether a claim of the slot is under way: its staged record stands beside
 * the slot file until the claim returns. */
function claimStaged(): boolean {
	return readdirSync(tmpdir()).some((name) => name.startsWith(`${slotName()}.`));
}

// Every way a check is cut off. Each stops the whole process tree cargo
// started rather than cargo alone, and frees this lane's slot. The person
// ending the turn says nothing to an agent that is no longer running, and
// the check settles at once, wherever it was: in the workspace lookup, in
// the wait for a slot another lane holds, or in the clippy run. The timeout
// row's budget is 3000ms, so 2250ms for the slot and the run.
const OTHER_LANE = JSON.stringify({ pid: process.pid, token: "other-lane", until: 4_102_444_800_000 });
for (const row of [
	{ name: "timeout", phase: "run", timeoutMs: 3000, abort: false, key: "clippy-timeout-ms=2250" },
	{ name: "abort in the run", phase: "run", timeoutMs: 20_000, abort: true, key: undefined },
	{ name: "abort in the wait for the slot", phase: "wait", timeoutMs: 20_000, abort: true, key: undefined },
	{ name: "abort in the workspace lookup", phase: "lookup", timeoutMs: 20_000, abort: true, key: undefined },
] as const) {
	test(`clippy ${row.name} stops the check's whole process tree`, async () => {
		const project = initClippyProject(row.timeoutMs);
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		const childFile = join(cargoRoot, "child.pid");
		const holdFile = join(cargoRoot, "lookup.hold");
		const log = join(cargoRoot, "runs.log");
		let childPid: number | undefined;
		try {
			if (row.phase === "wait") writeFileSync(slotPath(), OTHER_LANE);
			const bin = fakeClippyBin(cargoRoot, project);
			await onPath(bin, async () => {
				if (row.phase !== "lookup") await primeLookup(project);
				const hooks = installTurnHandlers();
				const turn = new AbortController();
				const ctx = trusted(project, { signal: turn.signal });
				await hooks.onToolResult(toolResultEvent("edit", { path: join(project, "src", "lib.rs") }), ctx);
				const ended = hooks.onTurnEnd({}, ctx);
				if (row.phase === "run") {
					expect(await until(() => existsSync(childFile) && readFileSync(childFile, "utf8") !== "", 5000)).toBe(true);
					childPid = Number(readFileSync(childFile, "utf8"));
					expect(pidAlive(childPid)).toBe(true);
				} else {
					expect(await until(() => row.phase === "wait" ? claimStaged() : existsSync(holdFile), 5000)).toBe(true);
				}
				const cut = Date.now();
				if (row.abort) turn.abort();
				await ended;
				if (row.abort) expect(Date.now() - cut).toBeLessThan(5000);
				if (childPid !== undefined) expect(await until(() => !pidAlive(childPid!), 3000)).toBe(true);
				if (row.phase === "wait") expect(readFileSync(slotPath(), "utf8")).toBe(OTHER_LANE);
				else expect(existsSync(slotPath())).toBe(false);
				expect(readFileSync(log, { encoding: "utf8", flag: "a+" })).toBe(row.phase === "run" ? "start\n" : "");
				expect(hooks.sent.map((call) => call.message.content.split("\n")[0])).toEqual(row.key === undefined ? [] : [row.key]);
			}, { child: childFile, hold: row.phase === "lookup" ? holdFile : undefined, log });
		} finally {
			if (childPid !== undefined && pidAlive(childPid)) process.kill(childPid, "SIGKILL");
			rmSync(slotPath(), { force: true });
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
// names is taken over, and a takeover of this lane's own claim is left
// standing when this lane releases. The waiting row's budget is 1000ms, so
// 750ms for the wait, with the lookup cached so no spawn races it; the rest
// never wait and take the 20000ms the abort rows do. The pid-1 holder is one
// the OS answers with EPERM, a pid another user's process now has, which the
// row makes so under any user by answering signal 0 for pid 1 that way.
const deadPid = spawnSync("true").pid;
const FAR = 4_102_444_800_000;
type SlotRow = {
	name: string;
	holder?: string;
	timeoutMs: number;
	key: string;
	ran: string;
	after: string | undefined;
	eperm?: boolean;
	takeover?: boolean;
	missingTmp?: boolean;
};
for (const row of [
	{ name: "a live holder is waited on for the budget", holder: JSON.stringify({ pid: process.pid, token: "other-lane", until: FAR }), timeoutMs: 1000, key: "clippy-timeout-ms=750", ran: "", after: JSON.stringify({ pid: process.pid, token: "other-lane", until: FAR }) },
	{ name: "a dead holder's slot is taken over", holder: JSON.stringify({ pid: deadPid, token: "dead-lane", until: FAR }), timeoutMs: 20_000, key: "clippy-errors=1", ran: "start\nend\n", after: undefined },
	{ name: "a holder whose pid another user now has is taken over", holder: JSON.stringify({ pid: 1, token: "reused-lane", until: FAR }), timeoutMs: 20_000, key: "clippy-errors=1", ran: "start\nend\n", after: undefined, eperm: true },
	{ name: "a holder past its deadline is taken over", holder: JSON.stringify({ pid: process.pid, token: "late-lane", until: Date.now() - 1 }), timeoutMs: 20_000, key: "clippy-errors=1", ran: "start\nend\n", after: undefined },
	{ name: "a slot naming no holder is taken over", holder: "not a holder", timeoutMs: 20_000, key: "clippy-errors=1", ran: "start\nend\n", after: undefined },
	{ name: "a lane's release leaves the claim that took its slot over", timeoutMs: 20_000, key: "clippy-errors=1", ran: "start\nend\n", after: TAKER, takeover: true },
	{ name: "a slot that cannot be written is named", timeoutMs: 20_000, key: "clippy-slot=", ran: "", after: undefined, missingTmp: true },
] satisfies SlotRow[]) {
	test(`clippy slot: ${row.name}`, async () => {
		const project = initClippyProject(row.timeoutMs);
		const cargoRoot = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
		const log = join(cargoRoot, "runs.log");
		const kill = process.kill.bind(process);
		const eperm = row.eperm ? spyOn(process, "kill").mockImplementation((pid: number, signal?: string | number) => {
			if (pid === 1 && signal === 0) throw Object.assign(new Error("kill EPERM"), { code: "EPERM" });
			return kill(pid, signal);
		}) : undefined;
		const scratch = process.env.TMPDIR;
		try {
			if (row.holder !== undefined) writeFileSync(slotPath(), row.holder);
			const bin = fakeClippyBin(cargoRoot, project);
			await onPath(bin, async () => {
				await primeLookup(project);
				const hooks = installTurnHandlers();
				const missing = join(cargoRoot, "no-such-tmp");
				if (row.missingTmp) process.env.TMPDIR = missing;
				try {
					await editingTurn(hooks, project, trusted(project));
				} finally { process.env.TMPDIR = scratch; }
				const said = hooks.sent.map((call) => call.message.content.split("\n")[0]!);
				if (row.missingTmp) {
					expect(said).toHaveLength(1);
					expect(said[0]!.startsWith(`${row.key}${join(missing, slotName())}`)).toBe(true);
				} else {
					expect(said).toEqual([row.key]);
				}
				expect(readFileSync(log, { encoding: "utf8", flag: "a+" })).toBe(row.ran);
				if (row.after === undefined) expect(existsSync(slotPath())).toBe(false);
				else expect(readFileSync(slotPath(), "utf8")).toBe(row.after);
			}, { log, takeover: row.takeover ? slotPath() : undefined });
		} finally {
			eperm?.mockRestore();
			rmSync(slotPath(), { force: true });
			rmSync(project, { recursive: true, force: true });
			rmSync(cargoRoot, { recursive: true, force: true });
		}
	});
}
