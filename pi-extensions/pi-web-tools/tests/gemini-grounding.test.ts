import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import test from "node:test";
import { GeminiApiClient } from "../src/providers/gemini-api.js";

const redirect = (id: string) => `https://vertexaisearch.cloud.google.com/grounding-api-redirect/${id}`;
const grounded = (text: string, urls: string[]) => ({ candidates: [{ content: { parts: [{ text }] }, groundingMetadata: { groundingChunks: urls.map((uri) => ({ web: { uri } })) } }] });

// Gemini emits byte offsets per content part, and grounding indices include chunks with no web source.
for (const row of [
	{ name: "all sources", numResults: undefined, expected: "Café 🦀[1][2] ici.東京[1][3]\nÜber[2]", urls: ["https://example.com/Page", "https://example.com/page", "https://example.com/third"] },
	{ name: "result cap keeps citation numbers in the shown list", numResults: 2, expected: "Café 🦀[1][2] ici.東京[1]\nÜber[2]", urls: ["https://example.com/Page", "https://example.com/page"] },
]) {
	test(`Gemini grounding: ${row.name}`, async () => {
		const raw = {
			candidates: [{
				content: { parts: [{ text: "  Café 🦀 ici.東京" }, { text: "Über" }] },
				groundingMetadata: {
					groundingChunks: [{}, ...["https://example.com/Page", "https://example.com/page", "https://example.com/Page", "https://example.com/third"].map((uri) => ({ web: { uri } }))],
					groundingSupports: [
						{ segment: { endIndex: Buffer.byteLength("  Café 🦀 ici.東京") }, groundingChunkIndices: [3, 4] },
						{ segment: { endIndex: Buffer.byteLength("  Café 🦀") }, groundingChunkIndices: [0, 1, 2, 3] },
						{ segment: { endIndex: Buffer.byteLength("  Café 🦀") }, groundingChunkIndices: [2] },
						{ segment: { partIndex: 1, endIndex: Buffer.byteLength("Über") }, groundingChunkIndices: [2] },
					],
				},
			}],
		};
		const result = await new GeminiApiClient({ apiKey: "k", fetchImpl: async () => Response.json(raw) }).search({ query: "q", numResults: row.numResults });
		assert.deepEqual({ answer: result.answer, urls: result.results.map((source) => source.url) }, { answer: row.expected, urls: row.urls });
	});
}

test("Gemini redirects start in parallel, deduplicate after resolving, and fall back at the cap", { timeout: 10_000 }, async (t) => {
	t.mock.timers.enable({ apis: ["setTimeout"] });
	const started: Array<{ url: string; method?: string; redirect?: RequestRedirect }> = [];
	const signals: AbortSignal[] = [];
	const release: Array<(response: Response) => void> = [];
	const raw = grounded("answer", [redirect("a"), redirect("b"), redirect("stalled"), "https://example.com/page"]);
	const client = new GeminiApiClient({ apiKey: "k", fetchImpl: async (input, init) => {
		if (init?.method === "POST") return Response.json(raw);
		started.push({ url: String(input), method: init?.method, redirect: init?.redirect });
		const signal = init?.signal!;
		signals.push(signal);
		return await new Promise<Response>((resolve, reject) => {
			release.push(resolve);
			signal.addEventListener("abort", () => reject(signal.reason), { once: true });
		});
	} });
	const pending = client.search({ query: "q" });
	await setImmediate();
	assert.deepEqual(started, ["a", "b", "stalled"].map((id) => ({ url: redirect(id), method: "HEAD", redirect: "manual" })));
	release[0]!(new Response(null, { status: 302, headers: { location: "https://example.com/page" } }));
	release[1]!(new Response(null, { status: 302, headers: { location: "https://example.com/page" } }));
	await setImmediate();
	t.mock.timers.tick(2499);
	assert.equal(signals[2]!.aborted, false);
	t.mock.timers.tick(1);
	assert.deepEqual((await pending).results.map((source) => source.url), ["https://example.com/page", redirect("stalled")]);
	assert.equal(signals[2]!.reason.name, "TimeoutError");
});

// Google can omit Location, and fetch rejects network failures and caller cancellations.
for (const row of [
	{ name: "missing location", fail: false, cancel: false },
	{ name: "network failure", fail: true, cancel: false },
	{ name: "caller cancellation", fail: true, cancel: true },
]) {
	test(`Gemini redirect: ${row.name}`, async () => {
		const controller = new AbortController();
		const reason = new DOMException("stop", "AbortError");
		const client = new GeminiApiClient({ apiKey: "k", fetchImpl: async (_input, init) => {
			if (init?.method === "POST") return Response.json(grounded("answer", [redirect("a")]));
			if (row.cancel) controller.abort(reason);
			if (row.fail) throw new TypeError("fetch failed");
			return new Response(null, { status: 302 });
		} });
		if (row.cancel) await assert.rejects(client.search({ query: "q" }, controller.signal), (error) => error === reason);
		else assert.equal((await client.search({ query: "q" })).results[0]?.url, redirect("a"));
	});
}

// Google's API emits 429 and 5xx statuses; other failures must keep the original single attempt.
for (const row of [
	{ name: "503 then success", statuses: [503, 200], success: true },
	{ name: "429 then success", statuses: [429, 200], success: true },
	{ name: "persistent 503", statuses: [503, 503], success: false },
	{ name: "403", statuses: [403], success: false },
]) {
	test(`Gemini retry: ${row.name}`, async (t) => {
		t.mock.timers.enable({ apis: ["setTimeout"] });
		let attempts = 0;
		const client = new GeminiApiClient({ apiKey: "k", fetchImpl: async () => Response.json(grounded("answer", []), { status: row.statuses[attempts++]! }) });
		const pending = client.search({ query: "q" }).then((result) => ({ success: true, answer: result.answer }), () => ({ success: false }));
		await setImmediate();
		assert.equal(attempts, 1);
		t.mock.timers.tick(999);
		await setImmediate();
		assert.equal(attempts, 1);
		t.mock.timers.tick(1);
		assert.deepEqual(await pending, row.success ? { success: true, answer: "answer" } : { success: false });
		assert.equal(attempts, row.statuses.length);
	});
}

test("Gemini retry delay honours caller cancellation", async () => {
	const controller = new AbortController();
	const reason = new DOMException("stop", "AbortError");
	let attempts = 0;
	const client = new GeminiApiClient({ apiKey: "k", fetchImpl: async () => { attempts++; return new Response(null, { status: 503 }); } });
	const pending = client.search({ query: "q" }, controller.signal);
	await setImmediate();
	controller.abort(reason);
	await assert.rejects(pending, (error) => error === reason);
	assert.equal(attempts, 1);
});
