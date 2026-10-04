import { execFile, spawn, type ChildProcess } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { needsWindowsShell, resolveWindowsCommand, taskkillPath } from "./windows-command.js";

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
const PS_DEADLINE_MS = 2_000;
const PS_OUTPUT_LIMIT_BYTES = 16 * 1024 * 1024;

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
type ProcessListing = { kind: "listed"; rows: ProcessRow[] } | { kind: "failed"; cause: string };

/** Every process's pid, parent and process group, from POSIX `ps`. */
function listProcesses(): Promise<ProcessListing> {
	return new Promise((resolve) => {
		execFile(PS_PATH, ["-A", "-o", "pid=", "-o", "ppid=", "-o", "pgid="], {
			env: { LC_ALL: "C" },
			killSignal: "SIGKILL",
			maxBuffer: PS_OUTPUT_LIMIT_BYTES,
			timeout: PS_DEADLINE_MS,
		}, (error, stdout) => {
			if (error) return resolve({ kind: "failed", cause: `${PS_PATH} failed: ${error.message}` });
			const rows: ProcessRow[] = [];
			for (const line of stdout.split("\n")) {
				const text = line.trim();
				if (!text) continue;
				const match = /^(\d+)\s+(\d+)\s+(\d+)$/.exec(text);
				if (!match) return resolve({ kind: "failed", cause: `${PS_PATH} printed an unreadable line: ${JSON.stringify(text)}` });
				rows.push({ pid: Number(match[1]), ppid: Number(match[2]), pgid: Number(match[3]) });
			}
			resolve({ kind: "listed", rows });
		});
	});
}

/**
 * The process groups of `root` and every listed descendant. A descendant that
 * moved to a group or session of its own (kendex runs npm that way) is
 * reached through that group.
 */
function treeGroups(root: number, rows: ProcessRow[]): { groups: number[]; cause?: string } {
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
			if (child.pgid <= 1) return { groups: [root], cause: `${PS_PATH} reported process group ${child.pgid} for descendant ${child.pid}` };
			groups.add(child.pgid);
		}
	}
	return { groups: [...groups] };
}

/** Signal each group; the first refusal other than an exited group, if any. */
function signalGroups(child: ChildProcess, groups: number[], signal: "SIGTERM" | "SIGKILL"): string | undefined {
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
 * POSIX: list the tree before the first signal, since a descendant whose
 * parent dies is reparented out of it, then SIGTERM every group and SIGKILL
 * whatever is still there after the grace. Resolves once the final kill is
 * sent, whether or not the direct child has already closed.
 */
async function stopPosixTree(child: ChildProcess, pid: number): Promise<StopReach> {
	const listing = await listProcesses();
	const reach = listing.kind === "listed" ? treeGroups(pid, listing.rows) : { groups: [pid], cause: listing.cause };
	const causes = [reach.cause, signalGroups(child, reach.groups, "SIGTERM")];
	const until = Date.now() + STOP_GRACE_MS;
	// A real wait: the groups exit on their own clock.
	while (anyGroupAlive(reach.groups) && Date.now() < until) await sleep(STOP_POLL_MS);
	if (anyGroupAlive(reach.groups)) causes.push(signalGroups(child, reach.groups, "SIGKILL"));
	const cause = causes.filter((entry): entry is string => entry !== undefined).join("; ");
	return cause ? { kind: "partial", cause } : { kind: "tree" };
}

/** Windows: `taskkill /T /F` walks the tree from cmd.exe down to the npm it started. */
function stopWindowsTree(child: ChildProcess, pid: number): Promise<StopReach> {
	return new Promise((resolve) => {
		const killer = spawn(taskkillPath(process.env), ["/pid", String(pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
		killer.on("error", (error) => {
			child.kill();
			resolve({ kind: "partial", cause: `taskkill could not start: ${error.message}` });
		});
		killer.on("close", (code) => {
			resolve(code === 0 ? { kind: "tree" } : { kind: "partial", cause: `taskkill exited ${code ?? "without a code"}` });
		});
	});
}

/**
 * Run `command` with `args`. Resolves with how the run ended; rejects only
 * when the runtime reports a close with neither an exit code nor a signal.
 * A stopped run settles only after its tree's final kill, never at the direct
 * child's exit alone.
 */
export function runCommand(command: string, args: string[], request: CommandRequest): Promise<CommandResult> {
	const { cwd, deadlineMs, signal } = request;
	if (signal.aborted) return Promise.resolve({ kind: "cancelled", stop: { kind: "tree" }, output: { stdout: "", stderr: "", truncated: false } });
	// The live environment, named explicitly: Bun's child_process otherwise
	// hands a child the environment the process started with.
	const env = process.env;
	const resolved = resolveWindowsCommand(command, cwd, env, process.platform);
	return new Promise((resolve, reject) => {
		const stdout = new TailBuffer();
		const stderr = new TailBuffer();
		let stopped: "timed-out" | "cancelled" | undefined;
		let stopReach: StopReach | undefined;
		let closed = false;
		let settled = false;
		const timers: ReturnType<typeof setTimeout>[] = [];
		let child: ChildProcess;
		try {
			child = spawn(resolved, args, {
				cwd,
				env,
				detached: process.platform !== "win32",
				shell: needsWindowsShell(resolved, process.platform),
				stdio: ["ignore", "pipe", "pipe"],
				windowsHide: true,
			});
		} catch (error) {
			resolve({ kind: "launch-failed", error: error instanceof Error ? error : new Error(String(error)) });
			return;
		}
		const output = (): CommandOutput => ({ stdout: stdout.text(), stderr: stderr.text(), truncated: stdout.dropped || stderr.dropped });
		const finish = (settle: () => void): void => {
			if (settled) return;
			settled = true;
			for (const timer of timers) clearTimeout(timer);
			signal.removeEventListener("abort", onAbort);
			settle();
		};
		const settleStopped = (kind: "timed-out" | "cancelled", stop: StopReach): void => finish(() => resolve(kind === "timed-out"
			? { kind, deadlineMs, stop, output: output() }
			: { kind, stop, output: output() }));
		const stopTree = (kind: "timed-out" | "cancelled"): void => {
			if (settled || stopped) return;
			const pid = child.pid;
			// No pid: the spawn failed, and its `error` event settles the run.
			if (pid === undefined) return;
			stopped = kind;
			const stop = process.platform === "win32" ? stopWindowsTree(child, pid) : stopPosixTree(child, pid);
			stop.then((reach) => {
				stopReach = reach;
				if (closed) settleStopped(kind, reach);
				else timers.push(setTimeout(() => settleStopped(kind, reach), SETTLE_AFTER_KILL_MS));
			}, (error: unknown) => finish(() => reject(error)));
		};
		const onAbort = () => stopTree("cancelled");
		child.stdout!.on("data", (chunk: Buffer) => stdout.push(chunk));
		child.stderr!.on("data", (chunk: Buffer) => stderr.push(chunk));
		child.on("error", (error) => {
			// Only a spawn failure, which leaves no pid, ends the run here; any
			// later error still reaches `close`.
			if (child.pid === undefined) finish(() => resolve({ kind: "launch-failed", error }));
		});
		child.on("close", (code, exitSignal) => {
			closed = true;
			if (stopped) {
				// A stop in progress settles once its final kill is sent.
				if (stopReach) settleStopped(stopped, stopReach);
				return;
			}
			if (exitSignal !== null) return finish(() => resolve({ kind: "signaled", signal: exitSignal, output: output() }));
			if (code !== null) return finish(() => resolve({ kind: "exited", code, output: output() }));
			finish(() => reject(new Error(`process-close: ${resolved} closed with neither an exit code nor a signal`)));
		});
		signal.addEventListener("abort", onAbort, { once: true });
		timers.push(setTimeout(() => stopTree("timed-out"), deadlineMs));
	});
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
