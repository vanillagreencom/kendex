import assert from "node:assert/strict";
import test from "node:test";
import { responseHeaderTimeoutMsFromOptions } from "../src/provider-shim.js";

for (const row of [
	{ name: "configured", options: { timeoutMs: 45_000 }, expected: 45_000 },
	{ name: "zero", options: { timeoutMs: 0 }, expected: 20_000 },
	{ name: "absent", options: undefined, expected: 20_000 },
]) {
	test(`response header timeout option: ${row.name}`, () => assert.equal(responseHeaderTimeoutMsFromOptions(row.options), row.expected));
}
