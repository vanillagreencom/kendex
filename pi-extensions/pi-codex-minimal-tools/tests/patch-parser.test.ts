import assert from "node:assert/strict";
import test from "node:test";
import { parseApplyPatch } from "../src/patch/parser.js";

test("parseApplyPatch parses add/update/delete actions", () => {
	const parsed = parseApplyPatch(`*** Begin Patch
*** Add File: a.txt
+hello
*** Update File: b.txt
@@
-old
+new
*** Delete File: c.txt
*** End Patch`);
	assert.equal(parsed.actions.length, 3);
	assert.equal(parsed.actions[0]?.kind, "add");
	assert.equal(parsed.actions[1]?.kind, "update");
	assert.equal(parsed.actions[2]?.kind, "delete");
});
