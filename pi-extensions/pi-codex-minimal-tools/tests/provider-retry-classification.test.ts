import assert from "node:assert/strict";
import test from "node:test";
import { isRetryableError } from "../src/provider-shim.js";

for (const row of [
	{ status: 524, message: "Cloudflare timeout", expected: true },
	{ status: 400, message: "grpc ResourceExhausted", expected: true },
	{ status: 400, message: "socket connection was closed unexpectedly", expected: true },
	{ status: 400, message: "please retry your request", expected: true },
	{ status: 400, message: "you can retry your request", expected: true },
	{ status: 400, message: "Service unavailable", expected: true },
	{ status: 400, message: "server error", expected: true },
	{ status: 400, message: "Internal server error", expected: true },
	{ status: 400, message: "HTTP 503", expected: true },
	{ status: 429, message: "insufficient_quota", expected: false },
	{ status: 429, message: "ResourceExhausted: quota exceeded", expected: false },
	{ status: 400, message: "Do not retry the request: invalid schema", expected: false },
	{ status: 400, message: "billing account disabled", expected: false },
	{ status: 400, message: "invalid schema", expected: false },
]) {
	test(`retry classification: ${row.status}/${row.message}`, () => assert.equal(isRetryableError(row.status, row.message), row.expected));
}
