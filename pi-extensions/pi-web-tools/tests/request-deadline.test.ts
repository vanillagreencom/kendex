import assert from "node:assert/strict";
import test, { type TestContext } from "node:test";
import { fetchHttpContent, fetchPdf } from "../src/extract/http.js";
import { extractYouTubeUrl } from "../src/extract/youtube.js";
import { DuckDuckGoClient } from "../src/providers/duckduckgo.js";
import { ExaClient } from "../src/providers/exa.js";
import { ExaMcpClient } from "../src/providers/exa-mcp.js";
import { GeminiApiClient } from "../src/providers/gemini-api.js";
import { GeminiWebClient } from "../src/providers/gemini-web.js";
import { PerplexityClient } from "../src/providers/perplexity.js";
import { DEFAULT_SETTINGS } from "../src/settings.js";
import { runExaResearch } from "../src/tools/web-research.js";
import { stallingServer, urlReads } from "./fixtures.js";

const DEADLINE_MS = 200;
/** Each call must end well inside this; a path with no deadline holds the connection until the test's own timeout. */
const ENDS_WITHIN_MS = 2_000;

/** A fetch that sends every request to `base`, keeping its path, method, body and signal. */
function redirectedFetch(base: string): typeof fetch {
	return (input, init) => {
		const url = new URL(input instanceof Request ? input.url : String(input));
		return fetch(`${base}${url.pathname}${url.search}`, init);
	};
}

const paths: Array<{ name: string; timeout: "TimeoutError" | "wrapped"; call: (base: string, t: TestContext) => Promise<unknown> }> = [
	{ name: "Exa search", timeout: "TimeoutError", call: (base) => new ExaClient({ apiKey: "k", baseUrl: base, timeoutMs: DEADLINE_MS }).search({ query: "q" }) },
	{ name: "Exa research mode", timeout: "TimeoutError", call: (base) => runExaResearch(new ExaClient({ apiKey: "k", baseUrl: base }), { query: "q", researchMode: "lite" }, undefined, { ...DEFAULT_SETTINGS, apiKeys: {}, warnings: [], exaResearchModes: { lite: { timeoutSeconds: DEADLINE_MS / 1000 } } }) },
	{ name: "Exa MCP", timeout: "TimeoutError", call: (base) => new ExaMcpClient({ baseUrl: base, timeoutMs: DEADLINE_MS }).search({ query: "q" }) },
	{ name: "Perplexity", timeout: "TimeoutError", call: (base) => new PerplexityClient({ apiKey: "k", baseUrl: base, timeoutMs: DEADLINE_MS }).search({ query: "q" }) },
	{ name: "Gemini API", timeout: "TimeoutError", call: (base) => new GeminiApiClient({ apiKey: "k", baseUrl: base, timeoutMs: DEADLINE_MS }).search({ query: "q" }) },
	{ name: "DuckDuckGo", timeout: "TimeoutError", call: (base) => new DuckDuckGoClient({ fetchImpl: redirectedFetch(base), timeoutMs: DEADLINE_MS }).search({ query: "q" }) },
	{ name: "Gemini Web", timeout: "TimeoutError", call: (base) => new GeminiWebClient({ "__Secure-1PSID": "s" }, redirectedFetch(base)).query("q", { timeoutMs: DEADLINE_MS }) },
	{ name: "HTTP page", timeout: "TimeoutError", call: (base, t) => fetchHttpContent(`${base}/page`, { reads: urlReads(t), timeoutMs: DEADLINE_MS }) },
	{ name: "HTTP PDF", timeout: "TimeoutError", call: (base, t) => fetchPdf(`${base}/file.pdf`, { reads: urlReads(t), timeoutMs: DEADLINE_MS }) },
	{ name: "YouTube Gemini API", timeout: "wrapped", call: (base) => extractYouTubeUrl("https://youtu.be/abc123XYZ_-", { mode: "understand", geminiApiKey: "k", fetchImpl: redirectedFetch(base), timeoutMs: DEADLINE_MS }) },
];

for (const mode of ["silent", "stall"] as const) {
	for (const path of paths) {
		test(`request deadline: ${path.name}, server ${mode}`, { timeout: 10_000 }, async (t) => {
			const base = await stallingServer(t, mode);
			const started = performance.now();
			const error = await path.call(base, t).then(() => undefined, (caught: unknown) => caught);
			const elapsed = performance.now() - started;
			// A wrapped path reports the attempt's TimeoutError inside its own error, which names each attempt that failed.
			const timedOut = path.timeout === "TimeoutError"
				? error instanceof DOMException && error.name === "TimeoutError"
				: error instanceof Error && error.message.includes(`exceeded its ${DEADLINE_MS} ms deadline`);
			assert.deepEqual({ timedOut, withinBound: elapsed < ENDS_WITHIN_MS }, { timedOut: true, withinBound: true });
		});
	}
}

test("request deadline: the caller's cancellation keeps its own reason", { timeout: 10_000 }, async (t) => {
	const base = await stallingServer(t, "stall");
	const controller = new AbortController();
	const abort = new DOMException("cancelled", "AbortError");
	const pending = new ExaClient({ apiKey: "k", baseUrl: base }).search({ query: "q" }, controller.signal).then(() => undefined, (caught: unknown) => caught);
	controller.abort(abort);
	assert.equal(await pending, abort);
});
