import { filterClippyErrors, findCargoWorkspaceRoot, runWorkspaceClippy } from "./cargo.js";

/**
 * Run workspace clippy and return up to 15 error header lines. Used by the
 * end-of-turn check, the one lane that runs clippy: a `.rs` write triggers
 * nothing, so the turn pays for clippy once rather than once per edit.
 */
export function workspaceClippyErrors(cwd: string, timeoutMs: number): string[] {
	const metadataBudget = Math.min(5000, Math.floor(timeoutMs / 4));
	const root = findCargoWorkspaceRoot(cwd, metadataBudget);
	if (!root) return [];

	const clippyBudget = Math.max(1, timeoutMs - metadataBudget);
	const r = runWorkspaceClippy(root, clippyBudget);
	if (r.timedOut) return [`pi-hooks end-of-turn: cargo clippy timed out after ${clippyBudget}ms.`];
	if (r.exitCode === 0) return [];
	return filterClippyErrors(`${r.stdout}\n${r.stderr}`);
}
