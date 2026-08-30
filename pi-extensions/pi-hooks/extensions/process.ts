import { spawn } from "node:child_process";

/** Outcome of a bounded child process run. */
export interface CommandResult {
	exitCode: number;
	stdout: string;
	stderr: string;
	timedOut: boolean;
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
 * `stdin` is written to the child and the pipe closed. Omitted, the child gets
 * no stdin at all, which is what every probe here wants; a hook script reading
 * its payload from stdin wants the string.
 */
export function runCommandAsync(command: string, args: string[], cwd: string, timeoutMs: number, stdin?: string): Promise<CommandResult> {
	return new Promise((resolve) => {
		const stdout: Buffer[] = [];
		const stderr: Buffer[] = [];
		const stdoutBytes = { value: 0 };
		const stderrBytes = { value: 0 };
		const maxBuffer = 16 * 1024 * 1024;
		let timedOut = false;
		let settled = false;
		let timer: ReturnType<typeof setTimeout> | undefined;
		let killTimer: ReturnType<typeof setTimeout> | undefined;
		const detached = process.platform !== "win32";

		let child: ReturnType<typeof spawn>;
		try {
			child = spawn(command, args, {
				cwd,
				detached,
				// Name the live object rather than let the runtime choose an env.
				// Bun's spawnSync defaults to a boot-time snapshot, which is what
				// left a fake binary on PATH unreachable in runCargo (KEN-843).
				// Bun's async spawn reads process.env today, so this is a no-op
				// here as it is under Node. It is the guarantee a test planting a
				// binary rests on, not a runtime default.
				env: process.env,
				stdio: [stdin === undefined ? "ignore" : "pipe", "pipe", "pipe"],
			});
		} catch (error) {
			resolve({ exitCode: -1, stdout: "", stderr: String(error), timedOut });
			return;
		}

		const finish = (exitCode: number, extraStderr = "") => {
			if (settled) return;
			settled = true;
			if (timer) clearTimeout(timer);
			if (killTimer) clearTimeout(killTimer);
			if (extraStderr) appendChunk(stderr, extraStderr, stderrBytes, maxBuffer);
			resolve({
				exitCode,
				stdout: Buffer.concat(stdout).toString("utf8"),
				stderr: Buffer.concat(stderr).toString("utf8"),
				timedOut,
			});
		};

		const killChild = (signal: NodeJS.Signals) => {
			try {
				if (detached && child.pid) {
					process.kill(-child.pid, signal);
					return;
				}
			} catch {
				// Fall through to direct child kill below.
			}
			try {
				child.kill(signal);
			} catch {
				// Process already exited or cannot be signaled; close/error will settle.
			}
		};

		timer = setTimeout(() => {
			timedOut = true;
			// Scheduled before the SIGTERM, and inert once the run has settled:
			// an escalation assigned after a kill that settles the promise in the
			// same turn is a timer no settle path holds a handle to, and it would
			// later signal a pid the OS may have recycled onto another process.
			killTimer = setTimeout(() => {
				if (settled) return;
				killChild("SIGKILL");
				finish(-1, `\n${command} ${args.join(" ")} timed out after ${Math.max(1, timeoutMs)}ms and was killed.`);
			}, 1000);
			killChild("SIGTERM");
		}, Math.max(1, timeoutMs));

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

