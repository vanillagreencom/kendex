import assert from "node:assert/strict";
import test from "node:test";
import { isPreviousResponseNotFoundError } from "../src/provider-shim.js";

for (const row of [
	{ name: "code", error: { code: "previous_response_not_found" }, expected: true },
	{ name: "message", error: new Error("Codex error: previous_response_not_found"), expected: true },
	{ name: "unrelated", error: new Error("other failure"), expected: false },
]) {
	test(`missing previous response: ${row.name}`, () => assert.equal(isPreviousResponseNotFoundError(row.error), row.expected));
}
