// The vendored lane retention helper (scripts/lane-retention.ts): which
// recorded working directories count as gone. package-policy.test.mjs holds
// the copies equal across lane file owners.
import { afterEach, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openLaneDir, pruneLanes } from "../scripts/lane-retention.js";

let root = "";

afterEach(() => {
	chmodSync(join(root, "locked"), 0o700);
	rmSync(root, { recursive: true, force: true });
});

// Each row records one working directory for a lane holding one fresh file.
// Only a stat that answers ENOENT or ENOTDIR removes the lane.
// Pi's ExtensionRunner ctx.cwd preserves trailing spaces in directory names.
const rows: Array<{ name: string; cwd: (root: string) => string; removed: boolean; failure?: string }> = [
	{ name: "present", cwd: (r) => join(r, "worktree"), removed: false },
	{ name: "present with trailing whitespace", cwd: (r) => join(r, "worktree-with-trailing-space "), removed: false },
	{ name: "missing (ENOENT)", cwd: (r) => join(r, "removed-worktree"), removed: true },
	{ name: "under a file (ENOTDIR)", cwd: (r) => join(r, "plain-file", "worktree"), removed: true },
	{ name: "unreadable (EACCES)", cwd: (r) => join(r, "locked", "worktree"), removed: false, failure: "lane-cwd-unchecked" },
];

for (const row of rows) {
	test(`a lane whose recorded working directory is ${row.name} is ${row.removed ? "removed" : "kept"}`, () => {
		root = mkdtempSync(join(tmpdir(), "pi-agents-lane-retention-"));
		mkdirSync(join(root, "worktree"));
		mkdirSync(join(root, "worktree-with-trailing-space "));
		writeFileSync(join(root, "plain-file"), "");
		mkdirSync(join(root, "locked", "worktree"), { recursive: true });
		chmodSync(join(root, "locked"), 0o000);
		const lanes = join(root, "lanes");
		const lane = join(lanes, "lane");
		openLaneDir(lane, row.cwd(root));
		writeFileSync(join(lane, "fresh.jsonl"), "{}\n");
		const result = pruneLanes(lanes);
		expect({
			removed: result.removed,
			kept: existsSync(join(lane, "fresh.jsonl")),
			failed: result.failed.map((failure) => ({ path: failure.path, key: failure.error.split(":")[0] })),
		}).toEqual({
			removed: row.removed ? [lane] : [],
			kept: !row.removed,
			failed: row.failure ? [{ path: lane, key: row.failure }] : [],
		});
	});
}
