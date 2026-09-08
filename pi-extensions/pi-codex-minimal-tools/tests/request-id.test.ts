import assert from "node:assert/strict";
import test from "node:test";
import { createCodexRequestId } from "../src/provider-shim.js";

test("Codex sessionless request IDs are UUIDv7", () => {
	assert.match(createCodexRequestId(), /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});
