import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, realpathSync, rmSync } from "node:fs";
import { join } from "node:path";

import { commandFailure, runCommand, type CommandResult } from "../extensions/manager/process.ts";
import { mutantManager, processAlive, settleWithin, startedPid, writeCommand } from "./fixtures/commands.ts";

type ProcessModule = typeof import("../extensions/manager/process.ts");

const rootTmp = join(import.meta.dir, "..", "tmp", "process-test");
const originalPath = process.env.PATH;
// Processes a case started and its control may leave running.
const leftovers: number[] = [];
// A case with a mutant control runs real waits on two copies, past bun's 5 s default bound.
const CONTROL_CASE_MS = 20_000;

beforeEach(() => {
	rmSync(rootTmp, { recursive: true, force: true });
	mkdirSync(rootTmp, { recursive: true });
	// Children inherit the live environment; pin it to the tools these cases call.
	process.env.PATH = "/usr/bin:/bin";
});

afterEach(() => {
	for (const pid of leftovers.splice(0)) {
		try { process.kill(pid, "SIGKILL"); } catch {}
	}
	process.env.PATH = originalPath;
	rmSync(rootTmp, { recursive: true, force: true });
});

function live(): AbortSignal {
	return new AbortController().signal;
}

function summary(result: CommandResult): unknown {
	const failure = commandFailure(result);
	return { kind: result.kind, failure: failure && { reason: failure.reason, termination: failure.termination } };
}

test("each way a run ends maps to one result kind, and only exit 0 is success", async () => {
	const rows = [
		{ body: "echo done", expected: { kind: "exited", failure: undefined } },
		{ body: "exit 7", expected: { kind: "exited", failure: { reason: "exit", termination: "7" } } },
		// A natural signal exit, standing in for npm's heap-exhaustion abort.
		{ body: "kill -ABRT $$", expected: { kind: "signaled", failure: { reason: "exit", termination: "SIGABRT" } } },
	];
	for (const [index, row] of rows.entries()) {
		const command = writeCommand(join(rootTmp, `row-${index}`), row.body);
		expect(summary(await runCommand(command, [], { deadlineMs: 10_000, signal: live() }))).toEqual(row.expected);
	}
	const missing = await runCommand(join(rootTmp, "missing"), [], { deadlineMs: 10_000, signal: live() });
	expect(summary(missing)).toEqual({ kind: "launch-failed", failure: { reason: "launch", termination: "ENOENT" } });
});

async function signalExit(module: ProcessModule): Promise<unknown> {
	const command = writeCommand(join(rootTmp, "self-abort"), "kill -ABRT $$");
	const result = await module.runCommand(command, [], { deadlineMs: 10_000, signal: live() });
	return { kind: result.kind, success: module.commandFailure(result) === undefined };
}

test("a natural signal exit is a failure; control: reading the signal as exit 0 reports success", async () => {
	expect(await signalExit(await import("../extensions/manager/process.ts"))).toEqual({ kind: "signaled", success: false });
	const mutant = mutantManager(join(rootTmp, "mutant-signal"), [{
		file: "process.ts",
		before: 'resolve({ kind: "signaled", signal: exitSignal, output: output() })',
		after: 'resolve({ kind: "exited", code: 0, output: output() })',
	}]);
	expect(await signalExit(await import(join(mutant, "process.ts")))).toEqual({ kind: "exited", success: true });
}, CONTROL_CASE_MS);

async function hungRun(module: ProcessModule, cancel: AbortController): Promise<CommandResult | "unsettled"> {
	const pidFile = join(rootTmp, `hung-${Math.random()}`);
	const command = writeCommand(join(rootTmp, "hung"), `echo $$ > "${pidFile}"; exec sleep 30`);
	const run = module.runCommand(command, [], { deadlineMs: 200, signal: cancel.signal });
	leftovers.push(await startedPid(pidFile));
	// The deadline is 200 ms and sleep dies at SIGTERM, so a working runner
	// settles well inside this bound; a hung one is still running at it.
	return settleWithin(run, 3_000);
}

test("a run past its deadline stops its tree; control: an unarmed deadline never settles", async () => {
	const result = await hungRun(await import("../extensions/manager/process.ts"), new AbortController());
	expect(result === "unsettled" ? result : summary(result)).toEqual({ kind: "timed-out", failure: { reason: "timeout", termination: "200ms" } });
	expect(processAlive(leftovers.at(-1)!)).toBe(false);

	const mutant = mutantManager(join(rootTmp, "mutant-deadline"), [{
		file: "process.ts",
		before: 'timers.push(setTimeout(() => stopTree("timed-out"), deadlineMs));',
		after: 'timers.push(setTimeout(() => undefined, deadlineMs));',
	}]);
	const cleanup = new AbortController();
	expect(await hungRun(await import(join(mutant, "process.ts")), cleanup)).toBe("unsettled");
	cleanup.abort();
}, CONTROL_CASE_MS);

// Each shape starts one descendant that writes its own pid once it is set up.
const treeShapes = {
	// A shell waiting on a background grandchild in its group: npm under cmd.exe, or a lifecycle script under npm.
	"same-group": (pidFile: string) => `sleep 30 & echo $! > "${pidFile}"; wait`,
	// A lifecycle script that ignores SIGTERM and holds none of the runner's pipes, so the direct child closes first.
	"ignores-sigterm": (pidFile: string) => `sh -c 'trap "" TERM; echo $$ > "$1"; exec sleep 30' sh "${pidFile}" </dev/null >/dev/null 2>&1 & wait`,
	// kendex starts npm in a process group and session of its own.
	"own-session": (pidFile: string) => `perl -MPOSIX -e 'POSIX::setsid() > 0 or die "setsid: $!"; open(my $f, ">", $ARGV[0]) or die "pid: $!"; print $f "$$\\n"; close $f; exec "sleep", "30"' "${pidFile}" </dev/null >/dev/null 2>&1 & wait`,
} as const;

type TreeShape = keyof typeof treeShapes;

async function stoppedTree(module: ProcessModule, shape: TreeShape, trigger: "cancel" | "deadline"): Promise<{ kind: string; descendantAlive: boolean }> {
	const pidFile = join(rootTmp, `descendant-${Math.random()}`);
	const command = writeCommand(join(rootTmp, `tree-${shape}`), treeShapes[shape](pidFile));
	const cancel = new AbortController();
	const run = module.runCommand(command, [], { deadlineMs: trigger === "deadline" ? 500 : 30_000, signal: cancel.signal });
	const descendant = await startedPid(pidFile);
	leftovers.push(descendant);
	if (trigger === "cancel") cancel.abort();
	// The stop takes at most the 2 s SIGTERM grace plus a process listing.
	const result = await settleWithin(run, 6_000);
	if (result === "unsettled") throw new Error(`${shape} run did not settle`);
	// A killed descendant is reaped by its new parent asynchronously; give it
	// the same bound a terminal user waits.
	const until = Date.now() + 1_000;
	while (processAlive(descendant) && Date.now() < until) await Bun.sleep(20);
	return { kind: result.kind, descendantAlive: processAlive(descendant) };
}

test("a stop reaches every descendant before the run settles", async () => {
	const module = await import("../extensions/manager/process.ts");
	const rows = [
		{ shape: "same-group", trigger: "cancel", expected: { kind: "cancelled", descendantAlive: false } },
		{ shape: "ignores-sigterm", trigger: "cancel", expected: { kind: "cancelled", descendantAlive: false } },
		{ shape: "ignores-sigterm", trigger: "deadline", expected: { kind: "timed-out", descendantAlive: false } },
		{ shape: "own-session", trigger: "cancel", expected: { kind: "cancelled", descendantAlive: false } },
	] as const;
	for (const row of rows) expect({ ...row, observed: await stoppedTree(module, row.shape, row.trigger) }).toEqual({ ...row, observed: row.expected });
}, CONTROL_CASE_MS);

test("stop controls: each planted gap leaves its descendant running", async () => {
	const rows = [
		{ name: "signalling only each group's leader", shape: "same-group", before: "process.kill(-group, signal);", after: "process.kill(group, signal);" },
		{ name: "settling at the direct child's exit with no SIGKILL", shape: "ignores-sigterm", before: 'if (anyGroupAlive(reach.groups)) causes.push(signalGroups(child, reach.groups, "SIGKILL"));', after: "" },
		{ name: "signalling only the command's own group", shape: "own-session", before: "treeGroups(pid, listing.rows)", after: "{ groups: [pid] }" },
	] as const;
	for (const [index, row] of rows.entries()) {
		const mutant = mutantManager(join(rootTmp, `mutant-stop-${index}`), [{ file: "process.ts", before: row.before, after: row.after }]);
		const observed = await stoppedTree(await import(join(mutant, "process.ts")), row.shape, "cancel");
		expect({ name: row.name, observed }).toEqual({ name: row.name, observed: { kind: "cancelled", descendantAlive: true } });
	}
}, 30_000);

test("an already-aborted signal starts nothing", async () => {
	const marker = join(rootTmp, "started");
	const command = writeCommand(join(rootTmp, "touch"), `touch "${marker}"`);
	const cancel = new AbortController();
	cancel.abort();
	expect(summary(await runCommand(command, [], { deadlineMs: 10_000, signal: cancel.signal }))).toEqual({ kind: "cancelled", failure: { reason: "cancelled", termination: "cancelled" } });
	expect(existsSync(marker)).toBe(false);
});

test("captured output keeps the tail within its bound and marks the drop", async () => {
	const command = writeCommand(join(rootTmp, "loud"), "head -c 300000 /dev/zero | tr '\\0' a; printf END");
	const result = await runCommand(command, [], { deadlineMs: 10_000, signal: live() });
	if (result.kind !== "exited") throw new Error(`expected an exit, got ${result.kind}`);
	expect([result.output.stdout.length, result.output.stdout.endsWith("aEND"), result.output.truncated]).toEqual([256 * 1024, true, true]);
});

test("the child receives the live environment", async () => {
	process.env.PROCESS_TEST_MARKER = "live-value";
	try {
		const command = writeCommand(join(rootTmp, "env"), 'printf %s "$PROCESS_TEST_MARKER"');
		const result = await runCommand(command, [], { deadlineMs: 10_000, signal: live() });
		expect(result.kind === "exited" ? result.output.stdout : result.kind).toBe("live-value");
	} finally {
		delete process.env.PROCESS_TEST_MARKER;
	}
});

test("a command resolves against the requested working directory", async () => {
	const cwd = join(rootTmp, "work");
	mkdirSync(cwd);
	const command = writeCommand(join(rootTmp, "pwd"), "pwd -P");
	const result = await runCommand(command, [], { cwd, deadlineMs: 10_000, signal: live() });
	expect(result.kind === "exited" ? result.output.stdout.trim() : result.kind).toBe(realpathSync(cwd));
});
