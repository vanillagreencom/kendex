import assert from "node:assert/strict";
import test from "node:test";
import { getEnvApiKeyCompat } from "../src/provider-shim.js";

for (const row of [
	{ name: "compat", root: {}, expected: "key-for-openai-codex", compatCalls: 1 },
	{ name: "root", root: { getEnvApiKey: (provider: string) => `root-key-for-${provider}` }, expected: "root-key-for-openai-codex", compatCalls: 0 },
]) {
	test(`API key lookup: ${row.name}`, async () => {
		let calls = 0;
		const key = await getEnvApiKeyCompat("openai-codex", { root: row.root, loadCompat: async () => { calls++; return { getEnvApiKey: (provider: string) => `key-for-${provider}` }; } });
		assert.equal(key, row.expected);
		assert.equal(calls, row.compatCalls);
	});
}
