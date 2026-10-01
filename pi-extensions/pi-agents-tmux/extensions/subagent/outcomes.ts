import type { SingleResult } from "./types.js";

/** Lifecycle reported by dispatch, the Agents panel and tool renderers. */
export type ResultStatus = "running" | "completed" | "failed" | "refused" | "stopped" | "needs_completion";

/** A refusal ran no child; provider errors can end with process exit zero. */
export function singleResultStatus(result: SingleResult): ResultStatus {
	if (result.refused) return "refused";
	if (result.status === "stopped" || result.stopReason === "aborted") return "stopped";
	if (result.status === "needs_completion") return "needs_completion";
	if (result.exitCode === -1) return "running";
	if (result.stopReason === "error") return "failed";
	return result.exitCode === 0 ? "completed" : "failed";
}

/** Whether the caller must handle an unsuccessful dispatch. */
export function singleResultIsError(result: SingleResult): boolean {
	const status = singleResultStatus(result);
	switch (status) {
		case "failed":
		case "refused":
		case "stopped": return true;
		case "running":
		case "completed":
		case "needs_completion": return false;
		default: { const unreachable: never = status; throw new Error(`Unknown result status: ${unreachable}`); }
	}
}
