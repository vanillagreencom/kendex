// Time-limited subprocess probes, whose result type says which outcomes settle
// an answer, and the bounded pool that runs many of them. runProbe
// never blocks Pi's thread: the child runs off the event loop, a timeout kills
// it, and the caller awaits one tagged result. runProbeSync is for a caller
// that cannot await, and blocks for at most the same timeout.

import { execFile, spawnSync } from "node:child_process";

/** Longest one probe subprocess may run before it is killed. */
export const PROBE_TIMEOUT_MS = 1_000;

/** Most probes one restore or one orphan-watcher pass runs at once. */
export const PROBE_CONCURRENCY = 4;

// show-environment prints the whole user environment; the cap only has to
// hold what a real `systemctl` or `ps` prints.
const PROBE_MAX_BUFFER_BYTES = 1024 * 1024;

/**
 * How a probe ended, and whether that settles an answer.
 * `exited`: the command ran to an exit status. `missing`: the command does not
 * exist, which every later call repeats. `unsettled`: a timeout, a signal or
 * another start failure, which a later call may not repeat, so the caller asks
 * again.
 */
export type ProbeResult =
	| { kind: "exited"; status: number; stdout: string }
	| { kind: "missing" }
	| { kind: "unsettled"; cause: "timed-out" }
	| { kind: "unsettled"; cause: "signalled"; signal: string }
	| { kind: "unsettled"; cause: "spawn-failed"; code: string };

export type ProbeRunner = (file: string, args: string[]) => Promise<ProbeResult>;

function startFailure(code: string): ProbeResult {
	return code === "ENOENT" ? { kind: "missing" } : { kind: "unsettled", cause: "spawn-failed", code };
}

/** Run one probe command. Resolves with a tagged result and never rejects. */
export function runProbe(file: string, args: string[]): Promise<ProbeResult> {
	return new Promise((resolve) => {
		try {
			execFile(file, args, { encoding: "utf8", maxBuffer: PROBE_MAX_BUFFER_BYTES, timeout: PROBE_TIMEOUT_MS, windowsHide: true }, (error, stdout) => {
				if (!error) {
					resolve({ kind: "exited", status: 0, stdout });
					return;
				}
				// execFile's error carries a numeric code for a non-zero exit, a
				// string code for a spawn or buffer failure, and `killed` when its
				// own timeout sent the signal.
				if (typeof error.code === "number") resolve({ kind: "exited", status: error.code, stdout });
				else if (error.killed) resolve({ kind: "unsettled", cause: "timed-out" });
				else if (error.signal) resolve({ kind: "unsettled", cause: "signalled", signal: error.signal });
				else resolve(startFailure(String(error.code ?? error.message)));
			});
		} catch (error) {
			resolve(startFailure(error instanceof Error ? error.message : String(error)));
		}
	});
}

/** Run one probe command synchronously. Same result shape as runProbe. */
export function runProbeSync(file: string, args: string[]): ProbeResult {
	const result = spawnSync(file, args, { encoding: "utf8", maxBuffer: PROBE_MAX_BUFFER_BYTES, timeout: PROBE_TIMEOUT_MS, windowsHide: true });
	if (result.error) {
		const code = (result.error as NodeJS.ErrnoException).code;
		return code === "ETIMEDOUT" ? { kind: "unsettled", cause: "timed-out" } : startFailure(String(code ?? result.error.message));
	}
	if (result.signal) return { kind: "unsettled", cause: "signalled", signal: result.signal };
	if (result.status === null) throw new Error(`spawnSync ${file} reported no error, no signal and no exit status`);
	return { kind: "exited", status: result.status, stdout: result.stdout ?? "" };
}

/**
 * Map `items` through `work` with at most `limit` calls in flight. Results
 * keep the input order.
 */
export async function mapWithConcurrency<T, R>(items: readonly T[], limit: number, work: (item: T) => Promise<R>): Promise<R[]> {
	const results: R[] = new Array(items.length);
	let next = 0;
	const worker = async () => {
		while (next < items.length) {
			const index = next++;
			results[index] = await work(items[index]!);
		}
	};
	await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
	return results;
}
