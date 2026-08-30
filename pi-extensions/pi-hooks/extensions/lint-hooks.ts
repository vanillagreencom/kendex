import { createHash } from "node:crypto";

import { filterClippyErrors, findCargoWorkspaceRoot, runWorkspaceClippy } from "./cargo.js";

/**
 * What the end-of-turn clippy run established. `unavailable` is the state an
 * empty error list used to collapse into a clean tree: the workspace lookup
 * failed, the run was abandoned, or clippy failed printing nothing a filter
 * recognises. Nothing was proven about the tree in any of those, so the caller
 * says so rather than reporting a clean turn.
 */
export type ClippyOutcome =
	| { kind: "clean" }
	/**
	 * `lines` renders the report; `digest` identifies the run. They are not
	 * interchangeable: `lines` is the header lines a filter recognised, capped,
	 * so two runs differing in location, detail, or an error past the cap render
	 * the same. `digest` covers everything clippy wrote, which is what a caller
	 * asking "did anything change" has to compare.
	 */
	| { kind: "errors"; lines: string[]; digest: string }
	| { kind: "unavailable"; reason: string };

/**
 * Run workspace clippy and report up to 15 error header lines. Used by the
 * end-of-turn check, the one lane that runs clippy: a `.rs` write triggers
 * nothing, so the turn pays for clippy once rather than once per edit.
 */
export function workspaceClippyOutcome(cwd: string, timeoutMs: number): ClippyOutcome {
	const metadataBudget = Math.min(5000, Math.floor(timeoutMs / 4));
	const root = findCargoWorkspaceRoot(cwd, metadataBudget);
	if (!root) return { kind: "unavailable", reason: "cargo metadata named no workspace root here" };

	const clippyBudget = Math.max(1, timeoutMs - metadataBudget);
	const r = runWorkspaceClippy(root, clippyBudget);
	if (r.timedOut) return { kind: "unavailable", reason: `cargo clippy timed out after ${clippyBudget}ms` };
	if (r.exitCode === 0) return { kind: "clean" };
	const output = `${r.stdout}\n${r.stderr}`;
	const lines = filterClippyErrors(output);
	if (lines.length === 0) return { kind: "unavailable", reason: `cargo clippy exited ${r.exitCode} printing no error line` };
	return { kind: "errors", lines, digest: createHash("sha256").update(output).digest("hex") };
}
