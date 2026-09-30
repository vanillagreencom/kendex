import { claimClippySlot, filterClippyErrors, findCargoWorkspaceRoot, runWorkspaceClippy } from "./cargo.js";

/**
 * What the end-of-turn clippy run established. `unavailable` is the state an
 * empty error list must not collapse into a clean tree: the workspace lookup
 * failed, the clippy slot could not be claimed, the run was abandoned, or
 * clippy failed printing nothing a filter recognises. Nothing was proven about
 * the tree in any of those, so the caller says so rather than reporting a
 * clean turn. `aborted` is the person ending the turn: the check stopped
 * because it was told to, there is no one left in that turn to tell, and the
 * caller keeps the turn's edits for the next turn's check.
 */
export type ClippyOutcome =
	| { kind: "clean" }
	| { kind: "errors"; lines: string[] }
	| { kind: "unavailable"; reason: string }
	| { kind: "aborted" };

/** The producer supplies diagnostic details without requiring consumers of
 * the published ClippyOutcome type to construct those additional fields. */
type DetailedClippyOutcome = Exclude<ClippyOutcome, { kind: "unavailable" }>
	| (Extract<ClippyOutcome, { kind: "unavailable" }> & (
		| { code: "workspace" | "slot"; value: string }
		| { code: "timeout-ms" | "exit"; value: number }
	));

/**
 * Run workspace clippy and report up to 15 error header lines. Used by the
 * end-of-turn check, the one lane that runs clippy: a `.rs` write triggers
 * nothing, so the turn pays for clippy once rather than once per edit.
 *
 * `timeoutMs` bounds the whole check. A quarter of it, capped at 5 seconds,
 * goes to the workspace lookup; the rest covers the wait for this user's
 * clippy slot and the clippy run together, so a lane queued behind another
 * lane's run still ends its turn inside its own budget. `signal` is the
 * turn's: the person ending the turn stops the lookup, the wait and the run.
 */
export async function workspaceClippyOutcome(cwd: string, timeoutMs: number, signal?: AbortSignal): Promise<DetailedClippyOutcome> {
	const metadataBudget = Math.min(5000, Math.floor(timeoutMs / 4));
	const root = await findCargoWorkspaceRoot(cwd, metadataBudget, signal);
	if (signal?.aborted) return { kind: "aborted" };
	if (!root) return { kind: "unavailable", code: "workspace", value: cwd, reason: "cargo metadata named no workspace root here" };

	const clippyBudget = Math.max(1, timeoutMs - metadataBudget);
	const timedOut = { kind: "unavailable", code: "timeout-ms", value: clippyBudget, reason: `the wait for the clippy slot and cargo clippy took more than ${clippyBudget}ms` } as const;
	const deadline = Date.now() + clippyBudget;
	const slot = await claimClippySlot(deadline, signal);
	switch (slot.kind) {
		case "aborted":
			return { kind: "aborted" };
		case "busy":
			return timedOut;
		case "failed":
			return { kind: "unavailable", code: "slot", value: slot.path, reason: `the clippy slot could not be claimed: ${slot.cause}` };
		case "held":
			break;
		default:
			throw new Error(`clippy slot claim ${JSON.stringify(slot satisfies never)} is no claim this check knows`);
	}
	let r: Awaited<ReturnType<typeof runWorkspaceClippy>>;
	try {
		r = await runWorkspaceClippy(root, Math.max(1, deadline - Date.now()), signal);
	} finally {
		await slot.release();
	}
	switch (r.stoppedBy) {
		case "abort":
			return { kind: "aborted" };
		case "timeout":
			return timedOut;
		case null:
			break;
		default:
			throw new Error(`cargo clippy stopped by ${JSON.stringify(r.stoppedBy satisfies never)}, which this check does not know`);
	}
	if (r.exitCode === 0) return { kind: "clean" };
	const lines = filterClippyErrors(`${r.stdout}\n${r.stderr}`);
	if (lines.length === 0) return { kind: "unavailable", code: "exit", value: r.exitCode, reason: `cargo clippy exited ${r.exitCode} printing no error line` };
	return { kind: "errors", lines };
}
