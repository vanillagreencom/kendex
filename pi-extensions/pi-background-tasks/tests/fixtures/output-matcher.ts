import assert from "node:assert/strict";
import { performance } from "node:perf_hooks";
import { parseOutputMatcher } from "../../extensions/format.js";

const rows = [
	{ pattern: undefined, text: "output", expected: null },
	{ pattern: " ", text: "output", expected: null },
	{ pattern: "READY", text: "ready", expected: true },
	{ pattern: "/ready/i", text: "READY", expected: true },
	{ pattern: "/ready/g", text: "ready", expected: true },
	{ pattern: "/^ready/m", text: "waiting\nready", expected: true },
	{ pattern: "/[/", text: "literal /[/", expected: true },
	{ pattern: "/ready/", text: "waiting", expected: false },
];
for (const row of rows) {
	const matcher = parseOutputMatcher(row.pattern);
	assert.equal(matcher ? matcher(row.text) : null, row.expected);
	assert.equal(matcher ? matcher(row.text) : null, row.expected);
}
const matcher = parseOutputMatcher("/(a+)+$/");
assert.ok(matcher);
const text = "a".repeat(1_000_000 - 1) + "!";
const start = performance.now();
let reports = 0;
assert.throws(() => matcher(text), (error: unknown) => {
	const timeout = error instanceof Error && error.constructor.name === "OutputMatcherBudgetError";
	if (timeout) reports += 1;
	return timeout;
});
const elapsedMs = performance.now() - start;
// The real wait verifies Node's native timeout, with room for CI scheduling.
assert.ok(elapsedMs < 250, `matcher elapsed ${elapsedMs} ms`);
for (let index = 0; index < 20; index += 1) assert.equal(matcher(text), false);
console.log(JSON.stringify({ bytes: Buffer.byteLength(text), elapsedMs, reports, disabledCalls: 20, ordinaryCases: rows.length }));
