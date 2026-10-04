import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { commandLaunch, taskkillPath } from "./windows-command.js";

/*
 * The manager's one command runner: package updates and removals, package
 * instruction scripts and npm-root discovery all run through `runCommand`.
 *
 * It spawns the resolved executable itself rather than going through Pi's
 * `pi.exec` or Pi's host bash. `pi.exec` reports a natural signal exit as code
 * 0, and Pi's host bash under legacy WSL (System32 bash.exe) resolves `npm`
 * inside WSL instead of the Windows npm that manages Windows Pi's packages.
 */

/** Captured output; each stream keeps at most `OUTPUT_LIMIT_BYTES` of its tail. */
export interface CommandOutput {
	stdout: string;
	stderr: string;
	/** True when either stream dropped bytes from its head to stay within the bound. */
	truncated: boolean;
}

/**
 * How far a stop reached. `tree`: every process the command started that the
 * runner could list was signalled. `partial`: only what `cause` leaves
 * reachable was, so processes the command started may still run.
 */
export type StopReach = { kind: "tree" } | { kind: "partial"; cause: string };

/** How a run ended. Only `exited` with code 0 is success; every other case is a failure. */
export type CommandResult =
	| { kind: "exited"; code: number; output: CommandOutput }
	| { kind: "signaled"; signal: NodeJS.Signals; output: CommandOutput }
	| { kind: "timed-out"; deadlineMs: number; stop: StopReach; output: CommandOutput }
	| { kind: "cancelled"; stop: StopReach; output: CommandOutput }
	| { kind: "launch-failed"; error: Error };

export interface CommandRequest {
	cwd?: string;
	/** Wall-clock bound after which the whole process tree is stopped. */
	deadlineMs: number;
	/** Aborting stops the whole process tree; an already-aborted signal starts nothing. */
	signal: AbortSignal;
}

/** A failed run, classified once for every caller's notice. */
export interface CommandFailure {
	reason: "launch" | "exit" | "timeout" | "cancelled";
	/** The launch error code, exit code, terminating signal, deadline, or `cancelled`. */
	termination: string;
	detail: string;
}

const OUTPUT_LIMIT_BYTES = 256 * 1024;
/** POSIX: longest wait between SIGTERM and SIGKILL to the tree's process groups. */
const STOP_GRACE_MS = 2_000;
/** POSIX: how often the grace checks whether every group has exited. */
const STOP_POLL_MS = 50;
/** Time to wait for the streams to close after the final kill before settling anyway. */
const SETTLE_AFTER_KILL_MS = 2_000;
/** By absolute path, like taskkill, so the open project cannot shadow it. */
const PS_PATH = "/bin/ps";
const PS_OUTPUT_LIMIT_BYTES = 16 * 1024 * 1024;
/** Bound on each stop tool run: one `ps` listing, or taskkill. */
const STOP_TOOL_DEADLINE_MS = 2_000;
/**
 * Longest a stopped run takes to settle once its stop has signalled the tree,
 * on either platform: the POSIX grace before SIGKILL or the Windows taskkill
 * bound, whichever is longer, then the settle wait.
 */
export const STOP_SETTLE_MS = Math.max(STOP_GRACE_MS, STOP_TOOL_DEADLINE_MS) + SETTLE_AFTER_KILL_MS;
/**
 * POSIX: most listings one stop makes. Each listing past the first follows a
 * newly frozen group, and a frozen group cannot fork, so only a group that
 * refused SIGSTOP can keep adding groups; the bound keeps that from holding
 * the host's thread.
 */
const MAX_LISTINGS = 16;

class TailBuffer {
	private chunks: Buffer[] = [];
	private bytes = 0;
	dropped = false;

	push(chunk: Buffer): void {
		this.chunks.push(chunk);
		this.bytes += chunk.length;
		while (this.bytes > OUTPUT_LIMIT_BYTES) {
			const head = this.chunks[0]!;
			const excess = this.bytes - OUTPUT_LIMIT_BYTES;
			this.dropped = true;
			if (head.length <= excess) {
				this.chunks.shift();
				this.bytes -= head.length;
			} else {
				this.chunks[0] = head.subarray(excess);
				this.bytes -= excess;
			}
		}
	}

	text(): string {
		return Buffer.concat(this.chunks).toString("utf8");
	}
}

interface ProcessRow { pid: number; ppid: number; pgid: number }
type TreeReach = { kind: "listed"; groups: number[] } | { kind: "failed"; cause: string };

/** Every process's pid, parent and process group, from POSIX `ps`, synchronously. */
function listProcesses(): { kind: "listed"; rows: ProcessRow[] } | { kind: "failed"; cause: string } {
	const ps = spawnSync(PS_PATH, ["-A", "-o", "pid=", "-o", "ppid=", "-o", "pgid="], {
		encoding: "utf8",
		env: { LC_ALL: "C" },
		killSignal: "SIGKILL",
		maxBuffer: PS_OUTPUT_LIMIT_BYTES,
		timeout: STOP_TOOL_DEADLINE_MS,
	});
	if (ps.error) return { kind: "failed", cause: `${PS_PATH} failed: ${ps.error.message}` };
	if (ps.status !== 0) return { kind: "failed", cause: `${PS_PATH} exited ${ps.status ?? ps.signal}` };
	const rows: ProcessRow[] = [];
	for (const line of ps.stdout.split("\n")) {
		const text = line.trim();
		if (!text) continue;
		const match = /^(\d+)\s+(\d+)\s+(\d+)$/.exec(text);
		if (!match) return { kind: "failed", cause: `${PS_PATH} printed an unreadable line: ${JSON.stringify(text)}` };
		rows.push({ pid: Number(match[1]), ppid: Number(match[2]), pgid: Number(match[3]) });
	}
	return { kind: "listed", rows };
}

/**
 * The process groups of `root` and every listed descendant. A descendant that
 * moved to a group or session of its own (kendex runs npm that way) is
 * reached through that group.
 */
function treeGroups(root: number, rows: ProcessRow[]): TreeReach {
	const children = new Map<number, ProcessRow[]>();
	for (const row of rows) {
		const siblings = children.get(row.ppid);
		if (siblings) siblings.push(row);
		else children.set(row.ppid, [row]);
	}
	const groups = new Set([root]);
	const seen = new Set([root]);
	const queue = [root];
	while (queue.length > 0) {
		for (const child of children.get(queue.pop()!) ?? []) {
			if (seen.has(child.pid)) continue;
			seen.add(child.pid);
			queue.push(child.pid);
			// Signalling group 1 or 0 would reach every process this user owns or
			// the manager's own group; a descendant of a new session never reports either.
			if (child.pgid <= 1) return { kind: "failed", cause: `${PS_PATH} reported process group ${child.pgid} for descendant ${child.pid}` };
			groups.add(child.pgid);
		}
	}
	return { kind: "listed", groups: [...groups] };
}

/** Signal each group; the first refusal other than an exited group, if any. */
function signalGroups(child: ChildProcess, groups: number[], signal: "SIGSTOP" | "SIGTERM" | "SIGCONT" | "SIGKILL"): string | undefined {
	let refusal: string | undefined;
	for (const group of groups) {
		try {
			process.kill(-group, signal);
		} catch (error) {
			const code = (error as NodeJS.ErrnoException).code;
			if (code === "ESRCH") continue;
			// The command's own group refused: the direct child is all that is left in reach.
			if (group === child.pid) child.kill(signal);
			refusal ??= `${signal} to process group ${group} failed: ${code ?? String(error)}`;
		}
	}
	return refusal;
}

function anyGroupAlive(groups: number[]): boolean {
	return groups.some((group) => {
		try {
			process.kill(-group, 0);
			return true;
		} catch (error) {
			return (error as NodeJS.ErrnoException).code !== "ESRCH";
		}
	});
}

/**
 * POSIX stop. Everything up to the SIGTERM runs synchronously in the abort or
 * deadline listener, so it completes even when the host exits right after
 * aborting: freeze the command's group, list the tree, freeze each newly found
 * descendant group and list again until no new group appears, then SIGTERM and
 * SIGCONT every frozen group. A frozen process cannot fork, so no descendant
 * can move to a new group between the listing and the SIGTERM. A failed
 * listing still releases and signals every group frozen so far. Only the
 * grace and the SIGKILL to whatever outlives it are asynchronous; at quit they
 * run because session shutdown waits for the session's work (`inventory.ts`).
 */
function stopPosixTree(child: ChildProcess, pid: number): Promise<StopReach> {
	const groups = [pid];
	const causes = [signalGroups(child, groups, "SIGSTOP")];
	for (let listings = 0; ; listings += 1) {
		if (listings === MAX_LISTINGS) {
			causes.push(`the tree still gained process groups after ${MAX_LISTINGS} listings`);
			break;
		}
		const listing = listProcesses();
		const reach = listing.kind === "listed" ? treeGroups(pid, listing.rows) : listing;
		if (reach.kind === "failed") {
			causes.push(reach.cause);
			break;
		}
		const found = reach.groups.filter((group) => !groups.includes(group));
		if (found.length === 0) break;
		causes.push(signalGroups(child, found, "SIGSTOP"));
		groups.push(...found);
	}
	causes.push(signalGroups(child, groups, "SIGTERM"), signalGroups(child, groups, "SIGCONT"));
	return killAfterGrace(child, groups, causes);
}

async function killAfterGrace(child: ChildProcess, groups: number[], causes: (string | undefined)[]): Promise<StopReach> {
	const until = Date.now() + STOP_GRACE_MS;
	// A real wait: the groups exit on their own clock.
	while (anyGroupAlive(groups) && Date.now() < until) await sleep(STOP_POLL_MS);
	if (anyGroupAlive(groups)) causes.push(signalGroups(child, groups, "SIGKILL"));
	const cause = causes.filter((entry): entry is string => entry !== undefined).join("; ");
	return cause ? { kind: "partial", cause } : { kind: "tree" };
}

/**
 * Windows: `taskkill /T /F` walks the tree from cmd.exe down to the npm it
 * started. A taskkill that fails or outlasts its bound leaves the direct
 * child, killed here, as all the stop reached.
 */
function stopWindowsTree(child: ChildProcess, pid: number): Promise<StopReach> {
	return new Promise((resolve) => {
		const killer = spawn(taskkillPath(process.env), ["/pid", String(pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
		const end = (cause: string | undefined): void => {
			clearTimeout(bound);
			if (cause === undefined) return resolve({ kind: "tree" });
			child.kill();
			resolve({ kind: "partial", cause });
		};
		const bound = setTimeout(() => {
			killer.kill("SIGKILL");
			end(`taskkill did not finish within ${STOP_TOOL_DEADLINE_MS} ms`);
		}, STOP_TOOL_DEADLINE_MS);
		killer.on("error", (error) => end(`taskkill could not start: ${error.message}`));
		killer.on("close", (code) => end(code === 0 ? undefined : `taskkill exited ${code ?? "without a code"}`));
	});
}

/** What ended the direct child: a spawn failure, or its close. */
type ChildEnd =
	| { kind: "launch-failed"; error: Error }
	| { kind: "closed"; code: number | null; exitSignal: NodeJS.Signals | null };

/** A stop under way: what began it, and its reach once the final kill is sent. */
interface StopStart { kind: "timed-out" | "cancelled"; reach: Promise<StopReach> }

/** Resolves when `closed` does or `ms` passes, whichever is first. */
async function closedWithin(closed: Promise<ChildEnd>, ms: number): Promise<void> {
	let bound: ReturnType<typeof setTimeout> | undefined;
	await Promise.race([closed, new Promise<void>((resolve) => { bound = setTimeout(resolve, ms); })]);
	clearTimeout(bound);
}

/**
 * Run `command` with `args`. Resolves with how the run ended; rejects only
 * when the runtime reports a close with neither an exit code nor a signal.
 * A stopped run settles only after its tree's final kill, never at the direct
 * child's exit alone.
 */
export async function runCommand(command: string, args: string[], request: CommandRequest): Promise<CommandResult> {
	const { cwd, deadlineMs, signal } = request;
	if (signal.aborted) return { kind: "cancelled", stop: { kind: "tree" }, output: { stdout: "", stderr: "", truncated: false } };
	// The live environment, named explicitly: Bun's child_process otherwise
	// hands a child the environment the process started with.
	const env = process.env;
	const launch = commandLaunch(command, args, cwd, { platform: process.platform, env, exists: existsSync });
	if (launch.kind === "not-found") {
		const error: NodeJS.ErrnoException = new Error(`${command} was not found in: ${launch.searched.join(";") || "an empty PATH"}`);
		error.code = "ENOENT";
		return { kind: "launch-failed", error };
	}
	let child: ChildProcess;
	try {
		child = spawn(launch.file, launch.args, {
			cwd,
			env,
			detached: process.platform !== "win32",
			stdio: ["ignore", "pipe", "pipe"],
			windowsHide: true,
			windowsVerbatimArguments: launch.verbatim,
		});
	} catch (error) {
		return { kind: "launch-failed", error: error instanceof Error ? error : new Error(String(error)) };
	}
	const stdout = new TailBuffer();
	const stderr = new TailBuffer();
	child.stdout!.on("data", (chunk: Buffer) => stdout.push(chunk));
	child.stderr!.on("data", (chunk: Buffer) => stderr.push(chunk));
	const output = (): CommandOutput => ({ stdout: stdout.text(), stderr: stderr.text(), truncated: stdout.dropped || stderr.dropped });
	const closed = new Promise<ChildEnd>((resolve) => {
		// Only a spawn failure, which leaves no pid, ends the run here; any
		// later error still reaches `close`.
		child.on("error", (error) => { if (child.pid === undefined) resolve({ kind: "launch-failed", error }); });
		child.on("close", (code, exitSignal) => resolve({ kind: "closed", code, exitSignal }));
	});
	let startStop!: (start: StopStart) => void;
	const stopped = new Promise<StopStart>((resolve) => { startStop = resolve; });
	// One stop per run: whichever of the deadline and the abort fires first disarms the other.
	const begin = (kind: StopStart["kind"]): void => {
		clearTimeout(deadline);
		signal.removeEventListener("abort", onAbort);
		const pid = child.pid;
		// No pid: the spawn failed, and `closed` carries its error.
		if (pid === undefined) return;
		startStop({ kind, reach: process.platform === "win32" ? stopWindowsTree(child, pid) : stopPosixTree(child, pid) });
	};
	const onAbort = (): void => begin("cancelled");
	const deadline = setTimeout(() => begin("timed-out"), deadlineMs);
	signal.addEventListener("abort", onAbort, { once: true });
	try {
		const first = await Promise.race([closed, stopped]);
		switch (first.kind) {
			case "launch-failed":
				return { kind: "launch-failed", error: first.error };
			case "closed":
				if (first.exitSignal !== null) return { kind: "signaled", signal: first.exitSignal, output: output() };
				if (first.code !== null) return { kind: "exited", code: first.code, output: output() };
				throw new Error(`process-close: ${launch.file} closed with neither an exit code nor a signal`);
			case "timed-out":
			case "cancelled": {
				const stop = await first.reach;
				await closedWithin(closed, SETTLE_AFTER_KILL_MS);
				return first.kind === "timed-out" ? { kind: first.kind, deadlineMs, stop, output: output() } : { kind: first.kind, stop, output: output() };
			}
			default: {
				const unreachable: never = first;
				throw new Error(`process-run: unknown end ${JSON.stringify(unreachable)}`);
			}
		}
	} finally {
		clearTimeout(deadline);
		signal.removeEventListener("abort", onAbort);
	}
}

function outputText(output: CommandOutput): string {
	const text = output.stderr.trim() || output.stdout.trim();
	return text && output.truncated ? `[earlier output dropped]\n${text}` : text;
}

function stopText(stop: StopReach): string {
	switch (stop.kind) {
		case "tree":
			return "the process tree was stopped.";
		case "partial":
			return `the command was stopped, but ${stop.cause}; processes it started may still be running.`;
		default: {
			const unreachable: never = stop;
			throw new Error(`process-stop: unknown reach ${JSON.stringify(unreachable)}`);
		}
	}
}

/** Classify a run; `undefined` only for a confirmed exit 0. */
export function commandFailure(result: CommandResult): CommandFailure | undefined {
	switch (result.kind) {
		case "exited":
			if (result.code === 0) return undefined;
			return { reason: "exit", termination: String(result.code), detail: outputText(result.output) || `exit ${result.code}` };
		case "signaled":
			return { reason: "exit", termination: result.signal, detail: [`Terminated by ${result.signal}.`, outputText(result.output)].filter(Boolean).join("\n") };
		case "timed-out":
			return { reason: "timeout", termination: `${result.deadlineMs}ms`, detail: [`No exit within ${result.deadlineMs} ms; ${stopText(result.stop)}`, outputText(result.output)].filter(Boolean).join("\n") };
		case "cancelled":
			return { reason: "cancelled", termination: "cancelled", detail: `Cancelled before the command finished; ${stopText(result.stop)}` };
		case "launch-failed":
			return { reason: "launch", termination: (result.error as NodeJS.ErrnoException).code ?? "error", detail: `Could not start the command: ${result.error.name}: ${result.error.message}` };
		default: {
			const unreachable: never = result;
			throw new Error(`process-result: unknown kind ${JSON.stringify(unreachable)}`);
		}
	}
}
