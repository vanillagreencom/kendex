import { spawn, spawnSync } from "node:child_process";

export interface CargoResult {
	exitCode: number;
	stdout: string;
	stderr: string;
	timedOut: boolean;
}

export function runCargo(args: string[], cwd: string, timeoutMs: number): CargoResult {
	const result = spawnSync("cargo", args, {
		cwd,
		encoding: "utf8",
		timeout: Math.max(1, timeoutMs),
		maxBuffer: 16 * 1024 * 1024,
	});
	return {
		exitCode: typeof result.status === "number" ? result.status : -1,
		stdout: result.stdout ?? "",
		stderr: result.stderr ?? "",
		timedOut: (result as { signal?: NodeJS.Signals | null }).signal === "SIGTERM",
	};
}

function appendChunk(chunks: Buffer[], chunk: Buffer | string, totalBytes: { value: number }, maxBuffer: number): void {
	const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk));
	const remaining = maxBuffer - totalBytes.value;
	if (remaining <= 0) return;
	chunks.push(buffer.length > remaining ? buffer.subarray(0, remaining) : buffer);
	totalBytes.value += Math.min(buffer.length, remaining);
}

export function runCargoAsync(args: string[], cwd: string, timeoutMs: number): Promise<CargoResult> {
	return new Promise((resolve) => {
		const stdout: Buffer[] = [];
		const stderr: Buffer[] = [];
		const stdoutBytes = { value: 0 };
		const stderrBytes = { value: 0 };
		const maxBuffer = 16 * 1024 * 1024;
		let timedOut = false;
		let settled = false;

		let child: ReturnType<typeof spawn>;
		try {
			child = spawn("cargo", args, {
				cwd,
				stdio: ["ignore", "pipe", "pipe"],
			});
		} catch (error) {
			resolve({ exitCode: -1, stdout: "", stderr: String(error), timedOut });
			return;
		}

		const finish = (exitCode: number, extraStderr = "") => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			if (extraStderr) appendChunk(stderr, extraStderr, stderrBytes, maxBuffer);
			resolve({
				exitCode,
				stdout: Buffer.concat(stdout).toString("utf8"),
				stderr: Buffer.concat(stderr).toString("utf8"),
				timedOut,
			});
		};

		const timer = setTimeout(() => {
			timedOut = true;
			child.kill("SIGTERM");
		}, Math.max(1, timeoutMs));

		child.stdout?.on("data", (chunk) => appendChunk(stdout, chunk, stdoutBytes, maxBuffer));
		child.stderr?.on("data", (chunk) => appendChunk(stderr, chunk, stderrBytes, maxBuffer));
		child.on("error", (error) => finish(-1, String(error)));
		child.on("close", (code, signal) => finish(typeof code === "number" ? code : -1, signal ? `\n${signal}` : ""));
	});
}

/**
 * In-process cache for `cargo metadata --workspace_root`. `cargo metadata` is
 * ~0.5-1s even on a warm cache; calling it on every edit/turn adds up. The
 * workspace root for a given cwd doesn't change during a session, so caching
 * by cwd is sound.
 */
const workspaceRootCache = new Map<string, string | null>();

export function findCargoWorkspaceRoot(cwd: string, timeoutMs: number): string | null {
	if (workspaceRootCache.has(cwd)) return workspaceRootCache.get(cwd) ?? null;
	const r = runCargo(["metadata", "--format-version", "1", "--no-deps"], cwd, timeoutMs);
	if (r.exitCode !== 0) {
		workspaceRootCache.set(cwd, null);
		return null;
	}
	let root: string | null = null;
	try {
		const meta = JSON.parse(r.stdout);
		if (typeof meta?.workspace_root === "string") root = meta.workspace_root;
	} catch {
		root = null;
	}
	workspaceRootCache.set(cwd, root);
	return root;
}

export async function findCargoWorkspaceRootAsync(cwd: string, timeoutMs: number): Promise<string | null> {
	if (workspaceRootCache.has(cwd)) return workspaceRootCache.get(cwd) ?? null;
	const r = await runCargoAsync(["metadata", "--format-version", "1", "--no-deps"], cwd, timeoutMs);
	if (r.exitCode !== 0) {
		workspaceRootCache.set(cwd, null);
		return null;
	}
	let root: string | null = null;
	try {
		const meta = JSON.parse(r.stdout);
		if (typeof meta?.workspace_root === "string") root = meta.workspace_root;
	} catch {
		root = null;
	}
	workspaceRootCache.set(cwd, root);
	return root;
}

/**
 * Per-turn cache for the most recent workspace clippy run. Both `post-edit-lint`
 * and `task-completed-check` need the same `cargo clippy --workspace
 * --all-targets -- -D warnings` output; without caching they double-run.
 *
 * Callers `invalidate()` whenever the working tree changes (i.e. after every
 * edit/write tool result) so a stale result isn't reused once the source has
 * moved. `runWorkspaceClippy` reuses the cached output if it's still valid.
 */
let cachedClippy: { root: string; result: CargoResult } | null = null;

export function invalidateClippyCache(): void {
	cachedClippy = null;
}

export function runWorkspaceClippy(root: string, timeoutMs: number): CargoResult {
	if (cachedClippy && cachedClippy.root === root) {
		return cachedClippy.result;
	}
	const result = runCargo(["clippy", "--workspace", "--all-targets", "--", "-D", "warnings"], root, timeoutMs);
	cachedClippy = { root, result };
	return result;
}

export async function runWorkspaceClippyAsync(root: string, timeoutMs: number): Promise<CargoResult> {
	if (cachedClippy && cachedClippy.root === root) {
		return cachedClippy.result;
	}
	const result = await runCargoAsync(["clippy", "--workspace", "--all-targets", "--", "-D", "warnings"], root, timeoutMs);
	cachedClippy = { root, result };
	return result;
}

export function filterLinesContaining(output: string, needle: string, limit = 10): string[] {
	return output
		.split("\n")
		.filter((line) => line.includes(needle))
		.slice(0, limit);
}

export function filterClippyErrors(output: string, limit = 15): string[] {
	return output
		.split("\n")
		.filter((line) => /^error/i.test(line.trim()))
		.slice(0, limit);
}
