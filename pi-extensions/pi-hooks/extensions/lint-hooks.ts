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
	 * `lines` and `reason` render the report; `digest` identifies the run. They
	 * are not interchangeable, and a caller asking "did anything change" must
	 * compare the digest. `lines` is the header lines a filter recognised,
	 * capped, so two runs differing in location, detail, or an error past the
	 * cap render the same. `reason` is coarser still — a timeout says how long
	 * it waited and nothing about the partial output it collected, so two
	 * unlike runs read alike.
	 */
	| { kind: "errors"; lines: string[]; digest: string }
	| { kind: "unavailable"; reason: string; digest: string };

function digestOf(...parts: string[]): string {
	return createHash("sha256").update(parts.join("\n")).digest("hex");
}

/**
 * Run workspace clippy and report up to 15 error header lines. Used by the
 * end-of-turn check, the one lane that runs clippy: a `.rs` write triggers
 * nothing, so the turn pays for clippy once rather than once per edit.
 */
export function workspaceClippyOutcome(cwd: string, timeoutMs: number): ClippyOutcome {
	const metadataBudget = Math.min(5000, Math.floor(timeoutMs / 4));
	const root = findCargoWorkspaceRoot(cwd, metadataBudget);
	// The one outcome with no run output behind it: `findCargoWorkspaceRoot`
	// answers `string | null` and drops what cargo printed, so the reason is
	// genuinely all there is to identify this by. Two lookups failing for
	// unlike causes therefore share a digest and the second is suppressed;
	// closing that needs the metadata output carried out of that function.
	if (!root) {
		const reason = "cargo metadata named no workspace root here";
		return { kind: "unavailable", reason, digest: digestOf(reason) };
	}

	const clippyBudget = Math.max(1, timeoutMs - metadataBudget);
	const r = runWorkspaceClippy(root, clippyBudget);
	// Whatever the run collected before it was abandoned or gave up. A timeout
	// and a failure printing nothing recognisable both keep it: the reason
	// alone would make two unlike runs one, which is the suppression this
	// digest exists to refuse.
	const output = `${r.stdout}\n${r.stderr}`;
	if (r.timedOut) {
		const reason = `cargo clippy timed out after ${clippyBudget}ms`;
		return { kind: "unavailable", reason, digest: digestOf(reason, output) };
	}
	if (r.exitCode === 0) return { kind: "clean" };
	const lines = filterClippyErrors(output);
	if (lines.length === 0) {
		const reason = `cargo clippy exited ${r.exitCode} printing no error line`;
		return { kind: "unavailable", reason, digest: digestOf(reason, output) };
	}
	return { kind: "errors", lines, digest: digestOf(output) };
}
