import { existsSync } from "node:fs";
import { delimiter, extname, isAbsolute, join } from "node:path";
import { spawn, type ChildProcess } from "node:child_process";

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

/** How a run ended. Only `exited` with code 0 is success; every other case is a failure. */
export type CommandResult =
	| { kind: "exited"; code: number; output: CommandOutput }
	| { kind: "signaled"; signal: NodeJS.Signals; output: CommandOutput }
	| { kind: "timed-out"; deadlineMs: number; output: CommandOutput }
	| { kind: "cancelled"; output: CommandOutput }
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
/** POSIX: time between SIGTERM and SIGKILL to the process group. */
const STOP_GRACE_MS = 2_000;
/** Time to wait for the streams to close after the final kill before settling anyway. */
const SETTLE_AFTER_KILL_MS = 2_000;

function envPath(env: NodeJS.ProcessEnv): string | undefined {
	return env.PATH ?? env.Path ?? env.path;
}

function pathExts(env: NodeJS.ProcessEnv): string[] {
	const raw = env.PATHEXT ?? env.PathExt ?? env.pathext ?? ".COM;.EXE;.BAT;.CMD";
	return raw
		.split(";")
		.map((entry) => entry.trim())
		.filter(Boolean)
		.map((entry) => (entry.startsWith(".") ? entry : `.${entry}`));
}

function commandCandidates(command: string, env: NodeJS.ProcessEnv): string[] {
	if (extname(command)) return [command];
	return [command, ...pathExts(env).map((ext) => `${command}${ext}`)];
}

/** Windows process creation does no PATHEXT lookup, so `npm` must become the `npm.cmd` on PATH. */
function resolveWindowsCommand(command: string, cwd: string | undefined, env: NodeJS.ProcessEnv): string {
	if (process.platform !== "win32") return command;
	if (command.includes("/") || command.includes("\\") || isAbsolute(command)) {
		for (const candidate of commandCandidates(command, env)) {
			const absolute = isAbsolute(candidate) ? candidate : join(cwd ?? process.cwd(), candidate);
			if (existsSync(absolute)) return absolute;
		}
		return command;
	}
	for (const dir of (envPath(env)?.split(delimiter) ?? [])) {
		if (!dir) continue;
		for (const candidate of commandCandidates(command, env)) {
			const full = join(dir, candidate);
			if (existsSync(full)) return full;
		}
	}
	return command;
}

/** A `.cmd` or `.bat` entrypoint runs only under cmd.exe. */
function needsWindowsShell(command: string): boolean {
	return process.platform === "win32" && /\.(?:bat|cmd)$/i.test(command);
}

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

/**
 * Stop the child's whole tree. A POSIX child leads its own process group, so
 * the signal reaches every descendant; Windows `taskkill /T` walks the tree
 * from cmd.exe down to the npm it started.
 */
function killTree(child: ChildProcess, signal: "SIGTERM" | "SIGKILL"): void {
	const pid = child.pid;
	if (pid === undefined) return;
	if (process.platform === "win32") {
		const killer = spawn("taskkill", ["/pid", String(pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
		// Without taskkill only the direct child is reachable.
		killer.on("error", () => child.kill());
		return;
	}
	try {
		process.kill(-pid, signal);
	} catch (error) {
		// ESRCH: the group has already exited. Any other refusal leaves the
		// direct child as the only process this runner can still reach.
		if ((error as NodeJS.ErrnoException).code !== "ESRCH") child.kill(signal);
	}
}

/**
 * Run `command` with `args`. Resolves with how the run ended; rejects only
 * when the runtime reports a close with neither an exit code nor a signal.
 */
export function runCommand(command: string, args: string[], request: CommandRequest): Promise<CommandResult> {
	const { cwd, deadlineMs, signal } = request;
	if (signal.aborted) return Promise.resolve({ kind: "cancelled", output: { stdout: "", stderr: "", truncated: false } });
	// The live environment, named explicitly: Bun's child_process otherwise
	// hands a child the environment the process started with.
	const env = process.env;
	const resolved = resolveWindowsCommand(command, cwd, env);
	return new Promise((resolve, reject) => {
		const stdout = new TailBuffer();
		const stderr = new TailBuffer();
		let stopped: "timed-out" | "cancelled" | undefined;
		let settled = false;
		const timers: ReturnType<typeof setTimeout>[] = [];
		let child: ChildProcess;
		try {
			child = spawn(resolved, args, {
				cwd,
				env,
				detached: process.platform !== "win32",
				shell: needsWindowsShell(resolved),
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
		const stoppedResult = (kind: "timed-out" | "cancelled"): CommandResult => kind === "timed-out"
			? { kind, deadlineMs, output: output() }
			: { kind, output: output() };
		const stopTree = (kind: "timed-out" | "cancelled"): void => {
			if (settled || stopped) return;
			stopped = kind;
			const settleStopped = () => finish(() => resolve(stoppedResult(kind)));
			if (process.platform === "win32") {
				killTree(child, "SIGKILL");
				timers.push(setTimeout(settleStopped, SETTLE_AFTER_KILL_MS));
				return;
			}
			killTree(child, "SIGTERM");
			timers.push(setTimeout(() => {
				killTree(child, "SIGKILL");
				timers.push(setTimeout(settleStopped, SETTLE_AFTER_KILL_MS));
			}, STOP_GRACE_MS));
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
			if (stopped) return finish(() => resolve(stoppedResult(stopped!)));
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

/** Classify a run; `undefined` only for a confirmed exit 0. */
export function commandFailure(result: CommandResult): CommandFailure | undefined {
	switch (result.kind) {
		case "exited":
			if (result.code === 0) return undefined;
			return { reason: "exit", termination: String(result.code), detail: outputText(result.output) || `exit ${result.code}` };
		case "signaled":
			return { reason: "exit", termination: result.signal, detail: [`Terminated by ${result.signal}.`, outputText(result.output)].filter(Boolean).join("\n") };
		case "timed-out":
			return { reason: "timeout", termination: `${result.deadlineMs}ms`, detail: [`No exit within ${result.deadlineMs} ms; the process tree was stopped.`, outputText(result.output)].filter(Boolean).join("\n") };
		case "cancelled":
			return { reason: "cancelled", termination: "cancelled", detail: "Cancelled before the command finished; the process tree was stopped." };
		case "launch-failed":
			return { reason: "launch", termination: (result.error as NodeJS.ErrnoException).code ?? "error", detail: `Could not start the command: ${result.error.name}: ${result.error.message}` };
		default: {
			const unreachable: never = result;
			throw new Error(`process-result: unknown kind ${JSON.stringify(unreachable)}`);
		}
	}
}
