import assert from "node:assert/strict";
import test from "node:test";
import { buildCodexUserAgent } from "../src/provider-shim.js";

test("Codex user agent synchronously includes OS metadata", () => {
	const userAgent = buildCodexUserAgent();
	assert.match(userAgent, /^pi \(.+; .+\)$/);
	assert.notEqual(userAgent, "pi (browser)");
});
