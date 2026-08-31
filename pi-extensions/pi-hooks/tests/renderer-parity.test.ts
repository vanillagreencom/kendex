import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { PROJECT_LOCK_FILE, PROJECT_MARKER_DIRS } from "../extensions/config.ts";

/* The carrier restates rules the renderer owns, and a restatement drifts. Two
 * have on this branch: PI_CODING_AGENT_DIR (KEN-929) and the project markers.
 * Both were caught by a reviewer reading two files side by side, which is not a
 * mechanism. These read the Rust source and fail when the rule moves there, so
 * the next one is caught by a suite instead of by someone noticing.
 *
 * Reaching into crates/ from a package that ships without it is deliberate: the
 * tests directory is not in package.json `files`, so this runs in the repo, and
 * inside the repo the source is the authority. A missing file fails rather than
 * skips — a parity test that quietly passes when it cannot read the other side
 * is worse than none. */

const CRATES = join(import.meta.dir, "..", "..", "..", "crates", "core", "src");

function rustSource(...parts: string[]): string {
	const path = join(CRATES, ...parts);
	const source = readFileSync(path, "utf8");
	expect(source.length).toBeGreaterThan(0);
	return source;
}

describe("the carrier matches the rules the renderer owns", () => {
	// discover.rs::project_root_from is the operative rule: it is what
	// `kendex apply` resolves the project with, so it decides where the hooks
	// this carrier looks for were rendered. HarnessAdapter::project_markers
	// looks like the rule and is called from nowhere in crates/, so it is
	// deliberately not what this compares against.
	test("the project marker directories are the ones kendex discovers a project by", () => {
		const source = rustSource("discover.rs");
		const decl = /const MARKER_DIRS: \[&str; (\d+)\] = \[([\s\S]*?)\];/.exec(source);
		expect(decl).not.toBeNull();
		const declared = [...(decl as RegExpExecArray)[2].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
		// The declared length is read as well, so a regex that matched only part
		// of the array fails here instead of passing against a subset.
		expect(declared.length).toBe(Number((decl as RegExpExecArray)[1]));
		expect([...PROJECT_MARKER_DIRS].sort()).toEqual([...declared].sort());
	});

	// The second direction of the same defect, pinned by name: the carrier used
	// to treat .git as a marker, which resolved a vendored checkout as the
	// project and missed the hook rendered at the real root.
	test("a git directory is not one of them", () => {
		expect([...PROJECT_MARKER_DIRS]).not.toContain(".git");
	});

	test("the lock file that outranks a marker is the one kendex writes", () => {
		const source = rustSource("lock.rs");
		const decl = /pub const LOCK_FILE: &str = "([^"]+)";/.exec(source);
		expect(decl).not.toBeNull();
		expect(PROJECT_LOCK_FILE).toBe((decl as RegExpExecArray)[1]);
	});
});
