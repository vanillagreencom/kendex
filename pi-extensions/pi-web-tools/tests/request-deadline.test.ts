import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { type TestContext } from "node:test";
import { IN_FLIGHT_BYTE_BUDGET, TEXT_READ_BYTE_LIMIT } from "../src/extract/byte-budget.js";
import { extractGitHubUrl } from "../src/extract/github.js";
import { fetchHttpContent, fetchPdf } from "../src/extract/http.js";
import { extractLocalVideo } from "../src/extract/video.js";
import { extractYouTubeUrl } from "../src/extract/youtube.js";
import { DuckDuckGoClient } from "../src/providers/duckduckgo.js";
import { ExaClient } from "../src/providers/exa.js";
import { ExaMcpClient } from "../src/providers/exa-mcp.js";
import { GeminiApiClient } from "../src/providers/gemini-api.js";
import { GeminiWebClient } from "../src/providers/gemini-web.js";
import { PerplexityClient } from "../src/providers/perplexity.js";
import { DEFAULT_SETTINGS } from "../src/settings.js";
import { runExaResearch } from "../src/tools/web-research.js";
import { heldReads, stallingServer, tempDir, urlReads } from "./fixtures.js";

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

/** A fetch that answers the Gemini Files upload start itself, naming `base` as the upload URL, and sends every other request
 * to `base`: the upload then meets the server under test. */
function uploadStartedFetch(base: string): typeof fetch {
	const redirected = redirectedFetch(base);
	return async (input, init) => new Headers(init?.headers).get("x-goog-upload-command") === "start"
		? new Response("{}", { headers: { "x-goog-upload-url": `${base}/upload` } })
		: await redirected(input, init);
}

/** A fetch that answers the Gemini Files upload start and the upload itself, and sends every other request to `base`: the
 * analysis request then meets the server under test. */
function uploadedFetch(base: string): typeof fetch {
	const started = uploadStartedFetch(base);
	return async (input, init) => new Headers(init?.headers).get("x-goog-upload-command") === "upload, finalize"
		? Response.json({ file: { uri: "https://generativelanguage.googleapis.com/v1beta/files/clip" } })
		: await started(input, init);
}

/** A local video file small enough to upload. */
function localVideo(t: TestContext): string {
	const path = join(tempDir(t), "clip.mp4");
	writeFileSync(path, "video");
	return path;
}

type ServerMode = "silent" | "stall";

const paths: Array<{ name: string; timeout: "TimeoutError" | "wrapped"; modes?: ServerMode[]; call: (base: string, t: TestContext) => Promise<unknown> }> = [
	{ name: "Exa search", timeout: "TimeoutError", call: (base) => new ExaClient({ apiKey: "k", baseUrl: base, timeoutMs: DEADLINE_MS }).search({ query: "q" }) },
	{ name: "Exa research mode", timeout: "TimeoutError", call: (base) => runExaResearch(new ExaClient({ apiKey: "k", baseUrl: base }), { query: "q", researchMode: "lite" }, undefined, { ...DEFAULT_SETTINGS, apiKeys: {}, warnings: [], exaResearchModes: { lite: { timeoutSeconds: DEADLINE_MS / 1000 } } }) },
	{ name: "Exa MCP", timeout: "TimeoutError", call: (base) => new ExaMcpClient({ baseUrl: base, timeoutMs: DEADLINE_MS }).search({ query: "q" }) },
	{ name: "Perplexity", timeout: "TimeoutError", call: (base) => new PerplexityClient({ apiKey: "k", baseUrl: base, timeoutMs: DEADLINE_MS }).search({ query: "q" }) },
	{ name: "Gemini API", timeout: "TimeoutError", call: (base) => new GeminiApiClient({ apiKey: "k", baseUrl: base, timeoutMs: DEADLINE_MS }).search({ query: "q" }) },
	{ name: "DuckDuckGo", timeout: "TimeoutError", call: (base) => new DuckDuckGoClient({ fetchImpl: redirectedFetch(base), timeoutMs: DEADLINE_MS }).search({ query: "q" }) },
	{ name: "Gemini Web", timeout: "TimeoutError", call: (base) => new GeminiWebClient({ "__Secure-1PSID": "s" }, redirectedFetch(base)).query("q", { timeoutMs: DEADLINE_MS }) },
	{ name: "HTTP page", timeout: "TimeoutError", call: (base, t) => fetchHttpContent(`${base}/page`, { reads: urlReads(t), timeoutMs: DEADLINE_MS }) },
	{ name: "HTTP PDF", timeout: "TimeoutError", call: (base, t) => fetchPdf(`${base}/file.pdf`, { reads: urlReads(t), timeoutMs: DEADLINE_MS }) },
	{ name: "GitHub API", timeout: "TimeoutError", call: (base, t) => extractGitHubUrl("https://github.com/o/r/tree/main/src", { fetchImpl: redirectedFetch(base), cloneEnabled: false, timeoutMs: DEADLINE_MS, reads: urlReads(t) }) },
	{ name: "GitHub raw file", timeout: "TimeoutError", call: (base, t) => extractGitHubUrl("https://github.com/o/r/blob/main/a.md", { fetchImpl: redirectedFetch(base), cloneEnabled: false, timeoutMs: DEADLINE_MS, reads: urlReads(t) }) },
	// The upload start reads only its headers, so a server that stalls after them fails it without the deadline.
	{ name: "local video upload start", timeout: "TimeoutError", modes: ["silent"], call: (base, t) => extractLocalVideo(localVideo(t), { geminiApiKey: "k", fetchImpl: redirectedFetch(base), timeoutMs: DEADLINE_MS }) },
	{ name: "local video upload", timeout: "TimeoutError", call: (base, t) => extractLocalVideo(localVideo(t), { geminiApiKey: "k", fetchImpl: uploadStartedFetch(base), timeoutMs: DEADLINE_MS }) },
	{ name: "local video analysis", timeout: "TimeoutError", call: (base, t) => extractLocalVideo(localVideo(t), { geminiApiKey: "k", fetchImpl: uploadedFetch(base), timeoutMs: DEADLINE_MS }) },
	{ name: "YouTube Gemini API", timeout: "wrapped", call: (base) => extractYouTubeUrl("https://youtu.be/abc123XYZ_-", { mode: "understand", geminiApiKey: "k", fetchImpl: redirectedFetch(base), timeoutMs: DEADLINE_MS }) },
];

/** Whether `error` is the TimeoutError of a DEADLINE_MS deadline, or an error that names it inside its own message. */
function namesDeadline(error: unknown, timeout: "TimeoutError" | "wrapped"): boolean {
	return timeout === "TimeoutError"
		? error instanceof DOMException && error.name === "TimeoutError"
		: error instanceof Error && error.message.includes(`exceeded its ${DEADLINE_MS} ms deadline`);
}

for (const mode of ["silent", "stall"] as const) {
	for (const path of paths.filter((row) => row.modes?.includes(mode) ?? true)) {
		test(`request deadline: ${path.name}, server ${mode}`, { timeout: 10_000 }, async (t) => {
			const base = await stallingServer(t, mode);
			const started = performance.now();
			const error = await path.call(base, t).then(() => undefined, (caught: unknown) => caught);
			const elapsed = performance.now() - started;
			// A wrapped path reports the attempt's TimeoutError inside its own error, which names each attempt that failed.
			assert.deepEqual({ timedOut: namesDeadline(error, path.timeout), withinBound: elapsed < ENDS_WITHIN_MS }, { timedOut: true, withinBound: true });
		});
	}
}

test("request deadline: a repo whose README request stalls returns its description at the deadline", { timeout: 10_000 }, async (t) => {
	const base = await stallingServer(t, "stall");
	const redirected = redirectedFetch(base);
	const fetchImpl: typeof fetch = async (input, init) => String(input) === "https://api.github.com/repos/o/r"
		? Response.json({ full_name: "o/r", description: "the description" })
		: await redirected(input, init);
	const started = performance.now();
	const result = await extractGitHubUrl("https://github.com/o/r", { fetchImpl, cloneEnabled: false, timeoutMs: DEADLINE_MS, reads: urlReads(t) });
	const elapsed = performance.now() - started;
	assert.deepEqual({ content: result?.content, withinBound: elapsed < ENDS_WITHIN_MS }, { content: "# o/r\n\nthe description", withinBound: true });
});

// Reads of other web_fetch calls hold the whole in-flight budget, so each read below waits for room; its request's deadline
// ends the wait, long before IN_FLIGHT_WAIT_TIMEOUT_MS would.
const budgetWaits: Array<{ name: string; timeout: "TimeoutError" | "wrapped"; call: (t: TestContext) => Promise<unknown> }> = [
	{ name: "HTTP page", timeout: "TimeoutError", call: (t) => fetchHttpContent("https://pages.example/a", { fetchImpl: async () => new Response("page"), reads: urlReads(t), timeoutMs: DEADLINE_MS }) },
	{ name: "HTTP PDF", timeout: "TimeoutError", call: (t) => fetchPdf("https://pages.example/a.pdf", { fetchImpl: async () => new Response("%PDF-1.4"), reads: urlReads(t), timeoutMs: DEADLINE_MS }) },
	// The page fails with 503, and its Jina fallback's error is wrapped in the page's.
	{ name: "Jina Reader fallback", timeout: "wrapped", call: (t) => fetchHttpContent("https://pages.example/a", { fetchImpl: async (input) => String(input).startsWith("https://r.jina.ai/") ? new Response("Title: a") : new Response("", { status: 503 }), jinaFallback: true, reads: urlReads(t), timeoutMs: DEADLINE_MS }) },
];

for (const row of budgetWaits) {
	test(`request deadline: a ${row.name} read waiting for in-flight room ends at the deadline`, { timeout: 10_000 }, async (t) => {
		await heldReads(t, IN_FLIGHT_BYTE_BUDGET / TEXT_READ_BYTE_LIMIT);
		const started = performance.now();
		const error = await row.call(t).then(() => undefined, (caught: unknown) => caught);
		const elapsed = performance.now() - started;
		assert.deepEqual({ timedOut: namesDeadline(error, row.timeout), withinBound: elapsed < ENDS_WITHIN_MS }, { timedOut: true, withinBound: true });
	});
}

test("request deadline: the caller's cancellation keeps its own reason", { timeout: 10_000 }, async (t) => {
	const base = await stallingServer(t, "stall");
	const controller = new AbortController();
	const abort = new DOMException("cancelled", "AbortError");
	const pending = new ExaClient({ apiKey: "k", baseUrl: base }).search({ query: "q" }, controller.signal).then(() => undefined, (caught: unknown) => caught);
	controller.abort(abort);
	assert.equal(await pending, abort);
});
