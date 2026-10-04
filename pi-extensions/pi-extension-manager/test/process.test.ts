import { afterEach, beforeEach, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { commandFailure, runCommand, type CommandResult } from "../extensions/manager/process.ts";
import { mutantManager, processAlive, settleWithin, startedPid, waitFor, writeCommand, type SourceEdit } from "./fixtures/commands.ts";

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
		before: 'return { kind: "signaled", signal: first.exitSignal, output: output() };',
		after: 'return { kind: "exited", code: 0, output: output() };',
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
		before: 'const deadline = setTimeout(() => begin("timed-out"), deadlineMs);',
		after: "const deadline = setTimeout(() => undefined, deadlineMs);",
	}]);
	const cleanup = new AbortController();
	expect(await hungRun(await import(join(mutant, "process.ts")), cleanup)).toBe("unsettled");
	cleanup.abort();
}, CONTROL_CASE_MS);

// The listing stand-in creates this once its listing is read, then holds the
// listing back long enough for a running child to move out of the tree it shows.
const listedMarker = join(rootTmp, "listed");
const slowListing = join(rootTmp, "slow-ps");

function writeSlowListing(): void {
	rmSync(listedMarker, { force: true });
	writeCommand(slowListing, `out="$(/bin/ps "$@")" || exit $?\n: > "${listedMarker}"\n/bin/sleep 0.3\nprintf '%s\\n' "$out"`);
}

const perlSession = (pidFile: string) => `perl -MPOSIX -e 'POSIX::setsid() > 0 or die "setsid: $!"; open(my $f, ">>", $ARGV[0]) or die "pid: $!"; print $f "$$\\n"; close $f; exec "sleep", "30"' "${pidFile}" </dev/null >/dev/null 2>&1`;

// Each shape starts descendants that append their own pid, one per line, once set up.
const treeShapes = {
	// A shell waiting on a background grandchild in its group: npm under cmd.exe, or a lifecycle script under npm.
	"same-group": (pidFile: string) => `sleep 30 & echo $! >> "${pidFile}"; wait`,
	// A lifecycle script that ignores SIGTERM and holds none of the runner's pipes, so the direct child closes first.
	"ignores-sigterm": (pidFile: string) => `sh -c 'trap "" TERM; echo $$ >> "$1"; exec sleep 30' sh "${pidFile}" </dev/null >/dev/null 2>&1 & wait`,
	// kendex starts npm in a process group and session of its own.
	"own-session": (pidFile: string) => `${perlSession(pidFile)} & wait`,
	// kendex starts each git and npm child in a new process group, one after another,
	// so a child can be moving to its own group at the moment the stop lists the tree.
	"forking-sessions": (pidFile: string) => `while :; do ${perlSession(pidFile)} & sleep 0.002; done`,
	// A grandchild in a session of its own, out of the first freeze's reach, that
	// starts a child in a further session once the first listing has been read,
	// so only a second listing finds it.
	"forks-after-listing": (pidFile: string) => `perl -MPOSIX -e 'sub record { open(my $f, ">>", $ARGV[0]) or die "pid: $!"; print $f "$$\\n"; close $f } POSIX::setsid() > 0 or die "setsid: $!"; record(); select(undef, undef, undef, 0.01) until -e $ARGV[1]; my $pid = fork() // die "fork: $!"; if ($pid == 0) { POSIX::setsid() > 0 or die "setsid: $!"; record(); exec "sleep", "30" } exec "sleep", "30"' "${pidFile}" "${listedMarker}" </dev/null >/dev/null 2>&1 & wait`,
	// A child that moves to a session of its own once the stop's listing has read it.
	"regroups-after-listing": (pidFile: string) => `perl -MPOSIX -e 'open(my $f, ">>", $ARGV[0]) or die "pid: $!"; print $f "$$\\n"; close $f; select(undef, undef, undef, 0.01) until -e $ARGV[1]; POSIX::setsid() > 0 or die "setsid: $!"; exec "sleep", "30"' "${pidFile}" "${listedMarker}" </dev/null >/dev/null 2>&1 & wait`,
} as const;

type TreeShape = keyof typeof treeShapes;

/** What a stop left: how the run ended, how far the stop reached, and whether any descendant lives. */
async function stoppedTree(module: ProcessModule, shape: TreeShape, trigger: "cancel" | "deadline"): Promise<unknown> {
	const pidFile = join(rootTmp, `descendants-${Math.random()}`);
	const command = writeCommand(join(rootTmp, `tree-${shape}`), treeShapes[shape](pidFile));
	if (shape === "regroups-after-listing" || shape === "forks-after-listing") writeSlowListing();
	const cancel = new AbortController();
	const run = module.runCommand(command, [], { deadlineMs: trigger === "deadline" ? 500 : 30_000, signal: cancel.signal });
	await waitFor(`pid file ${pidFile}`, () => existsSync(pidFile) && readFileSync(pidFile, "utf8").trim().length > 0);
	// The forking shape needs time to have children at every stage of moving out.
	if (shape === "forking-sessions") await Bun.sleep(150);
	if (trigger === "cancel") cancel.abort();
	// The stop takes at most the 2 s SIGTERM grace plus the process listings.
	const result = await settleWithin(run, 6_000);
	if (result === "unsettled") throw new Error(`${shape} run did not settle`);
	if (result.kind !== "cancelled" && result.kind !== "timed-out") throw new Error(`${shape} run ended as ${result.kind}`);
	// A killed descendant is reaped by its new parent asynchronously; give it
	// the same bound a terminal user waits.
	const descendants = () => readFileSync(pidFile, "utf8").trim().split("\n").map(Number);
	const until = Date.now() + 1_000;
	while (descendants().some(processAlive) && Date.now() < until) await Bun.sleep(20);
	leftovers.push(...descendants());
	return {
		kind: result.kind,
		stop: result.stop.kind,
		causeInNotice: result.stop.kind === "partial" ? commandFailure(result)!.detail.includes(result.stop.cause) : null,
		descendantsAlive: descendants().some(processAlive),
	};
}

// The listing tool is gone, so the stop reaches only the command's own group.
const psMissing: SourceEdit = { file: "process.ts", before: 'const PS_PATH = "/bin/ps";', after: 'const PS_PATH = "/nonexistent/ps";' };

// Every listing is read before a child can react, then delivered late.
const listingReadEarly: SourceEdit = { file: "process.ts", before: 'const PS_PATH = "/bin/ps";', after: `const PS_PATH = ${JSON.stringify(slowListing)};` };

const stopRows = [
	{ name: "same-group", shape: "same-group", trigger: "cancel", edits: [], expected: { kind: "cancelled", stop: "tree", causeInNotice: null, descendantsAlive: false } },
	{ name: "ignores-sigterm", shape: "ignores-sigterm", trigger: "cancel", edits: [], expected: { kind: "cancelled", stop: "tree", causeInNotice: null, descendantsAlive: false } },
	{ name: "ignores-sigterm at the deadline", shape: "ignores-sigterm", trigger: "deadline", edits: [], expected: { kind: "timed-out", stop: "tree", causeInNotice: null, descendantsAlive: false } },
	{ name: "own-session", shape: "own-session", trigger: "cancel", edits: [], expected: { kind: "cancelled", stop: "tree", causeInNotice: null, descendantsAlive: false } },
	{ name: "forking-sessions", shape: "forking-sessions", trigger: "cancel", edits: [], expected: { kind: "cancelled", stop: "tree", causeInNotice: null, descendantsAlive: false } },
	{ name: "regroups-after-listing", shape: "regroups-after-listing", trigger: "cancel", edits: [listingReadEarly], expected: { kind: "cancelled", stop: "tree", causeInNotice: null, descendantsAlive: false } },
	{ name: "forks-after-listing", shape: "forks-after-listing", trigger: "cancel", edits: [listingReadEarly], expected: { kind: "cancelled", stop: "tree", causeInNotice: null, descendantsAlive: false } },
	{ name: "no process listing", shape: "same-group", trigger: "cancel", edits: [psMissing], expected: { kind: "cancelled", stop: "partial", causeInNotice: true, descendantsAlive: false } },
] as const satisfies readonly { name: string; shape: TreeShape; trigger: "cancel" | "deadline"; edits: readonly SourceEdit[]; expected: unknown }[];

async function stopRowModule(dir: string, edits: readonly SourceEdit[]): Promise<ProcessModule> {
	if (edits.length === 0) return import("../extensions/manager/process.ts");
	return import(join(mutantManager(join(rootTmp, dir), [...edits]), "process.ts"));
}

test("a stop reaches every descendant before the run settles, and says when it cannot", async () => {
	for (const [index, row] of stopRows.entries()) {
		const observed = await stoppedTree(await stopRowModule(`row-${index}`, row.edits), row.shape, row.trigger);
		expect({ name: row.name, observed }).toEqual({ name: row.name, observed: row.expected });
	}
}, 30_000);

test("stop controls: each planted gap changes what its row observes", async () => {
	const controls = [
		{ name: "signalling only each group's leader", row: "same-group", before: "process.kill(-group, signal);", after: "process.kill(group, signal);" },
		{ name: "no SIGKILL after the grace", row: "ignores-sigterm", before: 'if (anyGroupAlive(groups)) causes.push(signalGroups(child, groups, "SIGKILL"));', after: "" },
		{ name: "settling at the direct child's close", row: "ignores-sigterm", before: "const stop = await first.reach;", after: 'const stop = await Promise.race([first.reach, closed.then(() => ({ kind: "tree" }))]);' },
		{ name: "signalling only the command's own group", row: "own-session", before: "treeGroups(pid, listing.rows)", after: '{ kind: "listed", groups: [pid] }' },
		{ name: "no listing after the first freeze", row: "forks-after-listing", before: "groups.push(...found);", after: "groups.push(...found);\n\t\tbreak;" },
		{ name: "listing before freezing the command's group", row: "regroups-after-listing", before: 'const causes = [signalGroups(child, groups, "SIGSTOP")];', after: "const causes: (string | undefined)[] = [];" },
		{ name: "reporting a failed listing as the whole tree", row: "no process listing", before: 'return cause ? { kind: "partial", cause } : { kind: "tree" };', after: 'return { kind: "tree" };' },
	] as const;
	for (const [index, control] of controls.entries()) {
		const row = stopRows.find((entry) => entry.name === control.row)!;
		const module = await stopRowModule(`control-${index}`, [...row.edits, { file: "process.ts", before: control.before, after: control.after }]);
		const observed = await stoppedTree(module, row.shape, row.trigger);
		expect({ name: control.name, differs: !Bun.deepEquals(observed, row.expected) }).toEqual({ name: control.name, differs: true });
	}
}, 40_000);

const managerSource = join(import.meta.dir, "..", "extensions", "manager");

/**
 * Pi quits by awaiting its session_shutdown handlers, the manager's returning
 * `closeInventorySession`, then calling process.exit. A Bun process here runs
 * `shape` as session work, closes the session, awaiting it or not, and exits.
 * Whether any descendant the shape recorded lives once the process has exited.
 */
async function quitDuringRun(managerDir: string, shape: TreeShape, awaitShutdown: boolean): Promise<boolean> {
	const pidFile = join(rootTmp, `quit-pids-${Math.random()}`);
	const command = writeCommand(join(rootTmp, `quit-${shape}`), treeShapes[shape](pidFile));
	const host = join(rootTmp, `quit-host-${Math.random()}.ts`);
	writeFileSync(host, [
		'import { existsSync, readFileSync } from "node:fs";',
		'import { join } from "node:path";',
		"const [managerDir, command, pidFile, mode] = process.argv.slice(2);",
		'const { runCommand } = await import(join(managerDir, "process.ts"));',
		'const { closeInventorySession, sessionWork } = await import(join(managerDir, "inventory.ts"));',
		"const pi = {};",
		"void sessionWork(pi, (signal) => runCommand(command, [], { deadlineMs: 30_000, signal }));",
		'while (!existsSync(pidFile) || !readFileSync(pidFile, "utf8").trim()) await Bun.sleep(10);',
		'if (mode === "await") await closeInventorySession(pi);',
		"else void closeInventorySession(pi);",
		"process.exit(0);",
	].join("\n"));
	const quit = spawnSync(process.execPath, ["--no-install", host, managerDir, command, pidFile, awaitShutdown ? "await" : "exit"], { encoding: "utf8", env: { PATH: process.env.PATH }, timeout: 10_000 });
	if (quit.status !== 0) throw new Error(`quit host exited ${quit.status ?? quit.signal}: ${quit.stderr}`);
	const descendants = readFileSync(pidFile, "utf8").trim().split("\n").map(Number);
	leftovers.push(...descendants);
	// A signalled descendant is reaped by its new parent asynchronously; one
	// that ignored SIGTERM and never got SIGKILL is still running at this bound.
	const until = Date.now() + 1_000;
	while (descendants.some(processAlive) && Date.now() < until) await Bun.sleep(20);
	return descendants.some(processAlive);
}

const quitRows = [
	// The SIGKILL past the grace runs only because shutdown waits for it.
	{ name: "a descendant ignoring SIGTERM, shutdown awaited", shape: "ignores-sigterm", awaitShutdown: true },
	// Everything up to SIGTERM runs inside the abort listener.
	{ name: "a host that exits right after aborting", shape: "same-group", awaitShutdown: false },
] as const;

test("quitting leaves no descendant running; controls: a shutdown that does not wait, a stop that starts after the listener returns", async () => {
	for (const row of quitRows) {
		expect({ name: row.name, alive: await quitDuringRun(managerSource, row.shape, row.awaitShutdown) }).toEqual({ name: row.name, alive: false });
	}
	const controls = [
		{ row: 0, file: "inventory.ts", before: "await Promise.race([Promise.all(session.running), new Promise<void>((resolve) => { bound = setTimeout(resolve, SHUTDOWN_WAIT_MS); })]);", after: "" },
		{ row: 1, file: "process.ts", before: 'startStop({ kind, reach: process.platform === "win32" ? stopWindowsTree(child, pid) : stopPosixTree(child, pid) });', after: 'setImmediate(() => startStop({ kind, reach: process.platform === "win32" ? stopWindowsTree(child, pid) : stopPosixTree(child, pid) }));' },
	] as const;
	for (const [index, control] of controls.entries()) {
		const row = quitRows[control.row];
		const mutant = mutantManager(join(rootTmp, `mutant-quit-${index}`), [{ file: control.file, before: control.before, after: control.after }]);
		expect({ name: row.name, edit: control.file, alive: await quitDuringRun(mutant, row.shape, row.awaitShutdown) }).toEqual({ name: row.name, edit: control.file, alive: true });
	}
}, CONTROL_CASE_MS);

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
