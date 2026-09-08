import assert from "node:assert/strict";
import test from "node:test";
import { withHttpStatusPrefix } from "../src/provider-shim.js";

for (const row of [
	{ status: 503, message: "upstream-token", expected: "HTTP 503: upstream-token" },
	{ status: 429, message: "HTTP 429: upstream-token", expected: "HTTP 429: upstream-token" },
	{ status: 503, message: "HTTP 503 upstream-token", expected: "HTTP 503 upstream-token" },
]) {
	test(`HTTP status prefix: ${row.message}`, () => assert.equal(withHttpStatusPrefix(row.status, row.message), row.expected));
}
