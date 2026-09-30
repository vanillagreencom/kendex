import assert from "node:assert/strict";
import test from "node:test";
import { zstdDecompressSync } from "node:zlib";
import { compressRequestBodyZstd } from "../src/provider-shim.js";

// Holds reversibility only: compressing on Pi's thread instead of the thread pool
// returns the same bytes, so no production edit to that choice reddens this case.
test("Codex SSE request bodies use reversible zstd compression", async () => {
	const source = JSON.stringify({ model: "gpt-6-astra", input: [{ role: "user", content: "hello" }] });
	const compressed = await compressRequestBodyZstd(source);
	assert.ok(compressed, "Node runtime must expose zstd compression");
	assert.equal(zstdDecompressSync(compressed).toString("utf8"), source);
});
