import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { applyPatch } from "../src/patch/apply.js";
import { world } from "./helpers/world.js";

const cases = [
	{
		name: "add, update, delete, then move in one transaction",
		seed: { "update.txt": "alpha\nold\nomega", "delete.txt": "remove me" },
		patch: "*** Add File: added.txt\n+hello\n+world\n*** Update File: update.txt\n@@\n alpha\n-old\n+new\n omega\n*** Delete File: delete.txt\n*** Update File: update.txt\n*** Move to: moved.txt\n@@\n alpha\n-new\n+newer\n omega",
		files: { "added.txt": "hello\nworld", "moved.txt": "alpha\nnewer\nomega", "update.txt": null, "delete.txt": null },
		count: 4,
	},
	{
		name: "traversal refusal",
		seed: {}, patch: "*** Add File: ../escape.txt\n+nope",
		files: { "../escape.txt": null }, errorPath: "../escape.txt", code: "PATCH_PATH_OUTSIDE",
	},
	{
		name: "rollback after missing update target",
		seed: {}, patch: "*** Add File: ok.txt\n+ok\n*** Update File: missing.txt\n@@\n-old\n+new",
		files: { "ok.txt": null }, errorPath: "missing.txt", code: "PATCH_READ_FAILED",
	},
	{
		name: "ambiguous context refusal",
		seed: { "ambiguous.txt": "same\nsame\n" },
		patch: "*** Update File: ambiguous.txt\n@@\n-same\n+different",
		files: { "ambiguous.txt": "same\nsame\n" }, errorPath: "ambiguous.txt", code: "PATCH_CONTEXT_AMBIGUOUS",
	},
	{
		name: "CRLF preservation with LF context",
		seed: { "crlf.txt": "alpha\r\nold\r\nomega\r\n" },
		patch: "*** Update File: crlf.txt\n@@\n alpha\n-old\n+new\n omega",
		files: { "crlf.txt": "alpha\r\nnew\r\nomega\r\n" }, count: 1,
	},
] satisfies Array<{ name: string; seed: Record<string, string>; patch: string; files: Record<string, string | null>; code?: string; errorPath?: string; count?: number }>;

for (const row of cases) {
	test(`applyPatch: ${row.name}`, async (t) => {
		const { cwd } = world(t);
		for (const [name, bytes] of Object.entries(row.seed)) writeFileSync(join(cwd, name), bytes!);
		const apply = () => applyPatch(`*** Begin Patch\n${row.patch}\n*** End Patch`, { cwd });
		if (row.code) await assert.rejects(apply, { code: row.code, path: row.code === "PATCH_READ_FAILED" ? join(cwd, row.errorPath!) : row.errorPath });
		else assert.equal((await apply()).files.length, row.count);
		for (const [name, bytes] of Object.entries(row.files)) {
			if (bytes === null) assert.equal(existsSync(join(cwd, name)), false, name);
			else assert.equal(readFileSync(join(cwd, name), "utf8"), bytes, name);
		}
	});
}
