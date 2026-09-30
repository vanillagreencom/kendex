// Asynchronous, time-limited subprocess probes and the bounded pool that runs
// many of them. A probe never blocks Pi's thread: the child runs off the event
// loop, a timeout kills it, and the caller awaits one tagged result.

import { execFile } from "node:child_process";

/** Longest one probe subprocess may run before it is killed. */
export const PROBE_TIMEOUT_MS = 1_000;

/** Most probes one restore or one orphan-watcher pass runs at once. */
export const PROBE_CONCURRENCY = 4;

// show-environment prints the whole user environment; the cap only has to
// hold what a real `systemctl` or `ps` prints.
const PROBE_MAX_BUFFER_BYTES = 1024 * 1024;

export type ProbeResult =
	| { kind: "exited"; status: number; stdout: string }
	| { kind: "timed-out" }
	| { kind: "signalled"; signal: string }
	| { kind: "spawn-failed"; code: string };

export type ProbeRunner = (file: string, args: string[]) => Promise<ProbeResult>;

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
				else if (error.killed) resolve({ kind: "timed-out" });
				else if (error.signal) resolve({ kind: "signalled", signal: error.signal });
				else resolve({ kind: "spawn-failed", code: String(error.code ?? error.message) });
			});
		} catch (error) {
			resolve({ kind: "spawn-failed", code: error instanceof Error ? error.message : String(error) });
		}
	});
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
