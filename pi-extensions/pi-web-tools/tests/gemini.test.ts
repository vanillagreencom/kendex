import assert from "node:assert/strict";
import test from "node:test";
import { GeminiApiClient, geminiSearch } from "../src/providers/gemini-api.js";
import { GeminiWebClient } from "../src/providers/gemini-web.js";

function jsonResponse(payload: unknown, status = 200): Response {
	return new Response(JSON.stringify(payload), { status, headers: { "content-type": "application/json" } });
}

test("GeminiApiClient buildSearchBody attaches googleSearch tool and domain hints", () => {
	const client = new GeminiApiClient({ apiKey: "k", fetchImpl: (async () => jsonResponse({})) as typeof fetch });
	const body = client.buildSearchBody({ query: "rust async", includeDomains: ["docs.rs"], excludeDomains: ["spam.io"] });
	assert.deepEqual(body.tools, [{ googleSearch: {} }]);
	const text = (body.contents as any)[0].parts[0].text;
	assert.match(text, /docs\.rs/);
	assert.match(text, /spam\.io/);
});

test("GeminiApiClient.search normalizes candidates and groundingChunks", async () => {
	const fetchImpl = (async () => jsonResponse({
		candidates: [{
			content: { parts: [{ text: "Tokio is the dominant async runtime." }] },
			groundingMetadata: { groundingChunks: [{ web: { uri: "https://tokio.rs", title: "Tokio" } }, { web: { uri: "https://docs.rs/futures", title: "futures" } }, { web: { uri: "https://tokio.rs", title: "dup" } }] },
		}],
	})) as typeof fetch;
	const out = await new GeminiApiClient({ apiKey: "k", fetchImpl }).search({ query: "rust async" });
	assert.match(out.answer ?? "", /Tokio/);
	assert.equal(out.results.length, 2);
	assert.equal(out.metadata.provider, "gemini");
});

test("GeminiApiClient.search rejects non-2xx with status", async () => {
	const fetchImpl = (async () => new Response("denied", { status: 403 })) as typeof fetch;
	await assert.rejects(() => new GeminiApiClient({ apiKey: "k", fetchImpl }).search({ query: "q" }), /Gemini API request failed \(403\)/);
});

test("geminiSearch helper requires API key", async () => {
	await assert.rejects(() => geminiSearch({ query: "q" }, { apiKey: undefined as any }), /Gemini/);
});

test("GeminiWebClient.query parses StreamGenerate envelope and surfaces text", async () => {
	let appCall = 0;
	const inner = JSON.stringify([null, null, null, null, [[null, ["Tokio is the answer."]]]]);
	const wrf = ["wrf", null, inner];
	const envelope = `)]}'\n\n[${JSON.stringify(wrf)}]`;
	const fetchImpl = (async (url: any) => {
		const u = String(url);
		if (u.startsWith("https://gemini.google.com/app")) {
			appCall++;
			return new Response(`<html>"SNlM0e":"AT0KEN"</html>`, { status: 200 });
		}
		if (u === "https://gemini.google.com/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate") {
			return new Response(envelope, { status: 200 });
		}
		throw new Error("unexpected " + u);
	}) as typeof fetch;
	const client = new GeminiWebClient({ "__Secure-1PSID": "x", "__Secure-1PSIDTS": "y" }, fetchImpl);
	const text = await client.query("hi", { timeoutMs: 5000 });
	assert.match(text, /Tokio is the answer/);
	assert.equal(appCall, 1);
});

test("GeminiWebClient.query uses latest non-empty streamed candidate", async () => {
	const empty = JSON.stringify([null, null, null, null, [[null, [""]]]]);
	const partial = JSON.stringify([null, null, null, null, [[null, ["partial"]]]]);
	const complete = JSON.stringify([null, null, null, null, [[null, ["complete response"]]]]);
	const envelope = `)]}'\n\n[${[empty, partial, complete].map((body) => JSON.stringify(["wrf", null, body])).join(",")}]`;
	const fetchImpl = (async (url: any) => {
		if (String(url).startsWith("https://gemini.google.com/app")) return new Response(`<html>"SNlM0e":"AT0KEN"</html>`, { status: 200 });
		return new Response(envelope, { status: 200 });
	}) as typeof fetch;
	const client = new GeminiWebClient({ "__Secure-1PSID": "x", "__Secure-1PSIDTS": "y" }, fetchImpl);
	assert.equal(await client.query("hi", { timeoutMs: 5000 }), "complete response");
});

test("GeminiWebClient.query ignores unresolved streamed card placeholders", async () => {
	const complete = JSON.stringify([null, null, null, null, [[null, ["complete response"]]]]);
	const placeholder = JSON.stringify([null, null, null, null, [[null, ["https://googleusercontent.com/card_content/7"]]]]);
	const envelope = `)]}'\n\n[${[complete, placeholder].map((body) => JSON.stringify(["wrf", null, body])).join(",")}]`;
	const fetchImpl = (async (url: any) => {
		if (String(url).startsWith("https://gemini.google.com/app")) return new Response(`<html>"SNlM0e":"AT0KEN"</html>`, { status: 200 });
		return new Response(envelope, { status: 200 });
	}) as typeof fetch;
	const client = new GeminiWebClient({ "__Secure-1PSID": "x", "__Secure-1PSIDTS": "y" }, fetchImpl);
	assert.equal(await client.query("hi", { timeoutMs: 5000 }), "complete response");
});

test("GeminiWebClient.query throws when access token missing", async () => {
	const fetchImpl = (async () => new Response("<html>no token</html>", { status: 200 })) as typeof fetch;
	const client = new GeminiWebClient({ "__Secure-1PSID": "x", "__Secure-1PSIDTS": "y" }, fetchImpl);
	await assert.rejects(() => client.query("hi", { timeoutMs: 5000 }), /Unable to authenticate/);
});
