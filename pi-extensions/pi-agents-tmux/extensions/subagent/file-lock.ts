import * as fs from "node:fs";
import * as path from "node:path";
import { withFileMutationQueue } from "@earendil-works/pi-coding-agent";
import { randomHex, randomJitter } from "./random.js";

interface LockOptions {
	staleMs?: number;
	retryMs?: number;
	timeoutMs?: number;
}

const DEFAULT_STALE_MS = 30_000;
const DEFAULT_RETRY_MS = 25;
const DEFAULT_TIMEOUT_MS = 10_000;

function lockDirFor(filePath: string): string {
	return `${filePath}.lock`;
}

async function tryClaimLockDir(lockDir: string): Promise<boolean> {
	try {
		await fs.promises.mkdir(lockDir, { mode: 0o700 });
		return true;
	} catch (err) {
		const code = (err as NodeJS.ErrnoException | undefined)?.code;
		if (code === "EEXIST") return false;
		if (code === "ENOENT") {
			await fs.promises.mkdir(path.dirname(lockDir), { recursive: true, mode: 0o700 });
			return tryClaimLockDir(lockDir);
		}
		throw err;
	}
}

async function clearStaleLock(lockDir: string, staleMs: number): Promise<boolean> {
	try {
		const stat = await fs.promises.stat(lockDir);
		if (Date.now() - stat.mtimeMs <= staleMs) return false;
	} catch (err) {
		const code = (err as NodeJS.ErrnoException | undefined)?.code;
		if (code === "ENOENT") return true;
		return false;
	}
	try {
		await fs.promises.rm(lockDir, { recursive: true, force: true });
		return true;
	} catch {
		return false;
	}
}

/**
 * Cross-process exclusive lock on filePath, implemented via atomic mkdir.
 * Holders are responsible for calling the returned release callback.
 *
 * Stale locks (older than staleMs) are reaped automatically — necessary because
 * a process killed while holding the lock cannot delete the lock dir itself.
 * The trade-off: a long-running mutation that exceeds staleMs may have its lock
 * stolen. Tune staleMs against the slowest expected mutation.
 */
export async function acquireFileLock(filePath: string, opts: LockOptions = {}): Promise<() => Promise<void>> {
	const lockDir = lockDirFor(filePath);
	const staleMs = opts.staleMs ?? DEFAULT_STALE_MS;
	const retryMs = opts.retryMs ?? DEFAULT_RETRY_MS;
	const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
	const start = Date.now();
	let touchTimer: ReturnType<typeof setInterval> | undefined;

	while (true) {
		if (await tryClaimLockDir(lockDir)) {
			const ownerFile = path.join(lockDir, "owner.json");
			try {
				await fs.promises.writeFile(
					ownerFile,
					JSON.stringify({ pid: process.pid, host: process.env.HOSTNAME ?? "", acquiredAt: Date.now() }),
					{ encoding: "utf-8", mode: 0o600 },
				);
			} catch {
				// Best-effort owner metadata; missing file does not invalidate the lock.
			}
			// Refresh mtime periodically so a slow mutation does not look stale to peers.
			const refresh = Math.max(500, Math.floor(staleMs / 4));
			touchTimer = setInterval(() => {
				const now = Date.now();
				fs.promises.utimes(lockDir, now / 1000, now / 1000).catch(() => undefined);
			}, refresh);
			touchTimer.unref?.();
			let released = false;
			return async () => {
				if (released) return;
				released = true;
				if (touchTimer) clearInterval(touchTimer);
				try {
					await fs.promises.rm(lockDir, { recursive: true, force: true });
				} catch {
					// Lock directory may have been reaped as stale by another process; ignore.
				}
			};
		}

		await clearStaleLock(lockDir, staleMs);

		if (Date.now() - start > timeoutMs) {
			throw new Error(`Timed out acquiring file lock for ${filePath} after ${timeoutMs}ms`);
		}
		const jitter = randomJitter(retryMs);
		await new Promise((resolve) => setTimeout(resolve, retryMs + jitter));
	}
}

/**
 * Run fn while holding both the in-process mutation queue (so concurrent
 * callers in this process serialize) and the cross-process file lock (so peers
 * in other processes — typically parent + child agent panes — do not interleave).
 *
 * Use for shared mutable state files such as task-registry.json and
 * pane-registry.json. Files that have a single writer (e.g. per-task outbox
 * JSON) do not need this and can stay on the cheaper in-process queue.
 */
export async function withCrossProcessFileLock<T>(filePath: string, fn: () => Promise<T>, opts?: LockOptions): Promise<T> {
	return withFileMutationQueue(filePath, async () => {
		const release = await acquireFileLock(filePath, opts);
		try {
			return await fn();
		} finally {
			await release();
		}
	});
}

/**
 * Write content to filePath atomically: stream into a sibling tmp file, then
 * rename into place. Concurrent readers always observe either the previous
 * complete content or the new complete content — never a torn write.
 *
 * Use for files that may be read by another process (peer parents, child
 * panes) without holding a lock. The tmp suffix is unique per process+call so
 * concurrent atomic writes from different writers do not collide on the tmp
 * file itself; the final rename is the linearization point.
 */
export async function atomicWriteFile(
	filePath: string,
	content: string | Buffer,
	mode: number = 0o600,
): Promise<void> {
	await fs.promises.mkdir(path.dirname(filePath), { recursive: true, mode: 0o700 });
	const tmpPath = `${filePath}.tmp.${process.pid}.${randomHex(8)}`;
	await fs.promises.writeFile(tmpPath, content, { encoding: typeof content === "string" ? "utf-8" : undefined, mode });
	try {
		await fs.promises.rename(tmpPath, filePath);
	} catch (err) {
		await fs.promises.rm(tmpPath, { force: true }).catch(() => undefined);
		throw err;
	}
}
