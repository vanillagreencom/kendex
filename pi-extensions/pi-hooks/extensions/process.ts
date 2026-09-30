import { spawn } from "node:child_process";

/**
 * Outcome of a bounded child process run. `stoppedBy` names what cut the run
 * off, `null` for a run that ended on its own; a run cut off judged nothing,
 * whatever exit status it managed.
 */
export interface CommandResult {
	exitCode: number;
	stdout: string;
	stderr: string;
	stoppedBy: "timeout" | "abort" | null;
}

/** What a run takes besides its command. `stdin` is written to the child and
 * the pipe closed; omitted, the child gets no stdin at all. `signal` stops the
 * run the way the timeout does, for work owned by a turn the person can end. */
export interface CommandOptions {
	stdin?: string;
	signal?: AbortSignal;
}

function appendChunk(chunks: Buffer[], chunk: Buffer | string, totalBytes: { value: number }, maxBuffer: number): void {
	const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk));
	const remaining = maxBuffer - totalBytes.value;
	if (remaining <= 0) return;
	chunks.push(buffer.length > remaining ? buffer.subarray(0, remaining) : buffer);
	totalBytes.value += Math.min(buffer.length, remaining);
}

/**
 * Spawn `command args` in `cwd` with a hard timeout, collecting bounded
 * stdout/stderr. Never rejects: a spawn failure (ENOENT included) settles as
 * `exitCode: -1` with the error text in `stderr`.
 *
 * The child leads its own process group, and the timeout and an abort both
 * signal that group: SIGTERM, then SIGKILL a second later for a group still
 * running. So a child that forks, as cargo forks rustc, is stopped whole.
 */
export function runCommandAsync(command: string, args: string[], cwd: string, timeoutMs: number, options: CommandOptions = {}): Promise<CommandResult> {
	const { stdin, signal } = options;
	return new Promise((resolve) => {
		const stdout: Buffer[] = [];
		const stderr: Buffer[] = [];
		const stdoutBytes = { value: 0 };
		const stderrBytes = { value: 0 };
		const maxBuffer = 16 * 1024 * 1024;
		let stoppedBy: CommandResult["stoppedBy"] = null;
		let settled = false;
		let timer: ReturnType<typeof setTimeout> | undefined;
		let killTimer: ReturnType<typeof setTimeout> | undefined;
		const detached = process.platform !== "win32";
		// A turn already ended starts nothing.
		if (signal?.aborted) {
			resolve({ exitCode: -1, stdout: "", stderr: "", stoppedBy: "abort" });
			return;
		}

		let child: ReturnType<typeof spawn>;
		try {
			child = spawn(command, args, {
				cwd,
				detached,
				// Name the live object rather than let the runtime choose an env.
				// Bun's async spawn reads process.env today, so this is a no-op
				// here as it is under Node. It is the guarantee a test planting a
				// binary on PATH rests on, not a runtime default.
				env: process.env,
				stdio: [stdin === undefined ? "ignore" : "pipe", "pipe", "pipe"],
			});
		} catch (error) {
			resolve({ exitCode: -1, stdout: "", stderr: String(error), stoppedBy });
			return;
		}

		const finish = (exitCode: number, extraStderr = "") => {
			if (settled) return;
			settled = true;
			if (timer) clearTimeout(timer);
			if (killTimer) clearTimeout(killTimer);
			signal?.removeEventListener("abort", onAbort);
			if (extraStderr) appendChunk(stderr, extraStderr, stderrBytes, maxBuffer);
			resolve({
				exitCode,
				stdout: Buffer.concat(stdout).toString("utf8"),
				stderr: Buffer.concat(stderr).toString("utf8"),
				stoppedBy,
			});
		};

		const killChild = (sig: NodeJS.Signals) => {
			try {
				if (detached && child.pid) {
					process.kill(-child.pid, sig);
					return;
				}
			} catch {
				// Fall through to direct child kill below.
			}
			try {
				child.kill(sig);
			} catch {
				// Process already exited or cannot be signaled; close/error will settle.
			}
		};

		const stop = (cause: "timeout" | "abort") => {
			if (settled || stoppedBy !== null) return;
			stoppedBy = cause;
			// Scheduled before the SIGTERM, and inert once the run has settled:
			// an escalation assigned after a kill that settles the promise in the
			// same turn is a timer no settle path holds a handle to, and it would
			// later signal a pid the OS may have recycled onto another process.
			killTimer = setTimeout(() => {
				if (settled) return;
				killChild("SIGKILL");
				const why = cause === "timeout" ? `timed out after ${Math.max(1, timeoutMs)}ms` : "was aborted";
				finish(-1, `\n${command} ${args.join(" ")} ${why} and was killed.`);
			}, 1000);
			killChild("SIGTERM");
		};
		function onAbort(): void {
			stop("abort");
		}

		timer = setTimeout(() => stop("timeout"), Math.max(1, timeoutMs));
		signal?.addEventListener("abort", onAbort, { once: true });

		if (stdin !== undefined) {
			// A child that exits before reading its payload breaks the pipe, which
			// arrives here as EPIPE on a stream nobody is listening to and would
			// take the process down. The exit status is the answer either way.
			child.stdin?.on("error", () => {});
			child.stdin?.end(stdin);
		}

		child.stdout?.on("data", (chunk) => appendChunk(stdout, chunk, stdoutBytes, maxBuffer));
		child.stderr?.on("data", (chunk) => appendChunk(stderr, chunk, stderrBytes, maxBuffer));
		child.on("error", (error) => finish(-1, String(error)));
		child.on("close", (code, signal) => finish(typeof code === "number" ? code : -1, signal ? `\n${signal}` : ""));
	});
}
