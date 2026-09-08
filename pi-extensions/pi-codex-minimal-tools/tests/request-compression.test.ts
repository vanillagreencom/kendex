import assert from "node:assert/strict";
import test from "node:test";
import { zstdDecompressSync } from "node:zlib";
import { compressRequestBodyZstd } from "../src/provider-shim.js";

test("Codex SSE request bodies use reversible zstd compression", () => {
	const source = JSON.stringify({ model: "gpt-6-astra", input: [{ role: "user", content: "hello" }] });
	const compressed = compressRequestBodyZstd(source);
	assert.ok(compressed, "Node runtime must expose zstd compression");
	assert.equal(zstdDecompressSync(compressed).toString("utf8"), source);
});
