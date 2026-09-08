import assert from "node:assert/strict";
import test from "node:test";
import { GeminiWebClient } from "../src/providers/gemini-web.js";

for (const { name, candidates, token, expected } of [
	{ name: "envelope", candidates: ["Tokio is the answer."], token: true, expected: "Tokio is the answer." },
	{ name: "latest nonempty candidate", candidates: ["", "partial", "complete response"], token: true, expected: "complete response" },
	{ name: "unresolved card", candidates: ["complete response", "https://googleusercontent.com/card_content/7"], token: true, expected: "complete response" },
	{ name: "missing token", candidates: [], token: false, expected: undefined },
]) {
	test(`Gemini Web query: ${name}`, async () => {
		let appCalls = 0;
		let queryCalls = 0;
		const envelope = `)]}'\n\n[${candidates.map((text) => JSON.stringify(["wrf", null, JSON.stringify([null, null, null, null, [[null, [text]]]])])).join(",")}]`;
		const client = new GeminiWebClient({ "__Secure-1PSID": "x", "__Secure-1PSIDTS": "y" }, async (url) => {
			if (String(url).startsWith("https://gemini.google.com/app")) { appCalls++; return new Response(token ? '<html>"SNlM0e":"AT0KEN"</html>' : "<html>no token</html>"); }
			if (String(url) !== "https://gemini.google.com/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate") throw new Error("unexpected endpoint");
			queryCalls++;
			return new Response(envelope);
		});
		const result = await client.query("hi", { timeoutMs: 5000 }).then((text) => ({ text, error: false }), (error: unknown) => ({ text: undefined, error: error instanceof Error }));
		assert.deepEqual({ ...result, appCalls, queryCalls }, { text: expected, error: !token, appCalls: 1, queryCalls: token ? 1 : 0 });
	});
}
