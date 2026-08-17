// Cross-process carrier for the rate-limit watchdog's pending-retry state.
//
// The watchdog that OBSERVES a rate limit lives in the child Pi process (its
// message_end handler sees the canonical signature), while the idle-stall
// watchdog that must defer to it polls from the PARENT. In-process state
// cannot cross that boundary, so the child persists each pending retry as a
// marker file under the shared runtime root and the parent reads it.
//
// The child's watchdog is the single writer: markers are written when a retry
// is scheduled and removed when it fires, resolves, or is cancelled. Readers
// honor a marker only within a grace window past its retry time, so a child
// that died with a retry pending cannot park its pane forever.

import * as fs from "node:fs";
import * as path from "node:path";
import { safeFileName } from "./names.js";

export const RETRY_MARKER_DIR = "rate-limit-retries";

export function retryMarkerPath(runtimeRoot: string, paneId: string): string {
	return path.join(runtimeRoot, RETRY_MARKER_DIR, `${safeFileName(paneId)}.json`);
}

/** Write (retryAtEpochMs set) or clear (null) the marker. Never throws. */
export function persistRetryMarker(runtimeRoot: string, paneId: string, retryAtEpochMs: number | null): void {
	const marker = retryMarkerPath(runtimeRoot, paneId);
	try {
		if (retryAtEpochMs === null) {
			fs.rmSync(marker, { force: true });
			return;
		}
		fs.mkdirSync(path.dirname(marker), { mode: 0o700, recursive: true });
		fs.writeFileSync(marker, `${JSON.stringify({ retryAtEpochMs })}\n`, { mode: 0o600 });
	} catch {
		// Best-effort by contract: rate-limit recovery must never throw, and a
		// missing marker only costs the cross-process skip.
	}
}

/**
 * Whether a pending-retry marker for this pane is live: it exists, parses,
 * and `now` has not passed its retry time by more than `graceMs`.
 */
export function retryMarkerActive(runtimeRoot: string, paneId: string, now: number, graceMs: number): boolean {
	try {
		const raw = fs.readFileSync(retryMarkerPath(runtimeRoot, paneId), "utf-8");
		const parsed = JSON.parse(raw) as { retryAtEpochMs?: unknown };
		const at = parsed?.retryAtEpochMs;
		if (typeof at !== "number" || !Number.isFinite(at)) return false;
		return now < at + Math.max(0, graceMs);
	} catch {
		return false;
	}
}
