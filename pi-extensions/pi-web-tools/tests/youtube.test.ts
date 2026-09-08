import assert from "node:assert/strict";
import test from "node:test";
import { extractYouTubeUrl, formatYouTubeTranscript, isTranscriptPrompt, parseYouTubeUrl } from "../src/extract/youtube.js";

for (const { url, field, expected } of [
	{ url: "https://www.youtube.com/watch?v=abc123XYZ_-", field: "videoId", expected: "abc123XYZ_-" },
	{ url: "https://youtu.be/abc123XYZ_-", field: "videoId", expected: "abc123XYZ_-" },
	{ url: "https://youtube.com/shorts/abcDEF", field: "kind", expected: "short" },
	{ url: "https://www.youtube.com/live/streamId1", field: "kind", expected: "live" },
	{ url: "https://www.youtube.com/embed/clipId", field: "kind", expected: "embed" },
	{ url: "https://www.youtube.com/v/legacyId", field: "kind", expected: "v" },
	{ url: "https://vimeo.com/123", field: "result", expected: undefined },
	{ url: "https://example.com/?v=fake", field: "result", expected: undefined },
	{ url: "not a url", field: "result", expected: undefined },
]) {
	test(`YouTube URL: ${url}`, () => {
		const result = parseYouTubeUrl(url);
		assert.equal(field === "result" ? result : result?.[field as "videoId" | "kind"], expected);
	});
}
for (const { prompt, expected } of [
	{ prompt: "Produce a complete transcript with timestamps", expected: true },
	{ prompt: "Transcribe this video verbatim", expected: true },
	{ prompt: "Return transcriptions for these talks", expected: true },
	{ prompt: "Get the closed captioning", expected: true },
	{ prompt: "Extract subtitles while subtitling the clip", expected: true },
	{ prompt: "Analyze the transcriptome", expected: false },
	{ prompt: "Summarize the visual design", expected: false },
]) {
	test(`transcript prompt: ${prompt}`, () => assert.equal(isTranscriptPrompt(prompt), expected));
}
for (const { name, segments, expected } of [
	{ name: "timestamp and line normalization", segments: [{ offset: 0.08, duration: 1.2, text: "Hello &amp; welcome", lang: "en" }, { offset: 3661.9, duration: 2, text: "Don&#39;t\ntruncate this", lang: "en" }], expected: "[00:00:00] Hello & welcome\n[01:01:01] Don't truncate this" },
	{ name: "out-of-range entity", segments: [{ offset: 0, duration: 1, text: "&#x110000;", lang: "en" }], expected: "[00:00:00] &#x110000;" },
	{ name: "decimal surrogate", segments: [{ offset: 0, duration: 1, text: "&#55296;", lang: "en" }], expected: "[00:00:00] &#55296;" },
	{ name: "hex surrogate", segments: [{ offset: 0, duration: 1, text: "&#xDFFF;", lang: "en" }], expected: "[00:00:00] &#xDFFF;" },
	{ name: "astral entity", segments: [{ offset: 0, duration: 1, text: "&#x1F600;", lang: "en" }], expected: "[00:00:00] 😀" },
	{ name: "decimal single pass", segments: [{ offset: 0, duration: 1, text: "&#38;lt;", lang: "en" }], expected: "[00:00:00] &lt;" },
	{ name: "hex single pass", segments: [{ offset: 0, duration: 1, text: "&#x26;amp;", lang: "en" }], expected: "[00:00:00] &amp;" },
	{ name: "named single pass", segments: [{ offset: 0, duration: 1, text: "&amp;lt;", lang: "en" }], expected: "[00:00:00] &lt;" },
	{ name: "named entity", segments: [{ offset: 0, duration: 1, text: "&lt;", lang: "en" }], expected: "[00:00:00] <" },
]) {
	test(`transcript format: ${name}`, () => assert.equal(formatYouTubeTranscript(segments), expected));
}

function captions(videoId: string, title: string, text: string, lang: string, offset = 0) {
	return {
		videoDetails: { videoId, title, author: "Channel", channelId: "channel-1", lengthSeconds: 65, viewCount: 1, description: "", keywords: [], thumbnails: [], isLiveContent: false },
		segments: [{ offset, duration: 1, text, lang }],
	};
}

for (const row of [
	{ name: "native prompt", prompt: "Return the full transcript", mode: undefined, language: "fr", returned: "en", title: "Test Video", text: "Complete caption", offset: 1, expectedLanguages: ["fr"], expectedContent: "[00:00:01] Complete caption" },
	{ name: "default language", prompt: undefined, mode: "transcript" as const, language: undefined, returned: "es", title: "Fallback Track", text: "Hola", offset: 0, expectedLanguages: [undefined], expectedContent: "[00:00:00] Hola" },
	{ name: "language variant", prompt: undefined, mode: "transcript" as const, language: "EN", returned: "en-US", title: "English Track", text: "Hello", offset: 0, expectedLanguages: ["EN", "en-US"], expectedContent: "[00:00:00] Hello" },
]) {
	test(`YouTube captions: ${row.name}`, async () => {
		const controller = new AbortController();
		const requests: unknown[] = [];
		const result = await extractYouTubeUrl("https://www.youtube.com/watch?v=abc123XYZ_-&t=42s", {
			prompt: row.prompt, mode: row.mode, transcriptLanguage: row.language, signal: controller.signal,
			transcriptFetcher: async (videoId, config) => {
				requests.push({ videoId, lang: config.lang, hasLanguage: Object.hasOwn(config, "lang"), videoDetails: config.videoDetails, sameSignal: config.signal === controller.signal });
				if (config.lang === "EN") throw Object.assign(new Error("language"), { name: "YoutubeTranscriptNotAvailableLanguageError", availableLangs: ["fr", "en-US"] });
				return captions(videoId, row.title, row.text, row.returned, row.offset);
			},
		});
		assert.deepEqual({ requests, source: result?.source, title: result?.title, content: result?.content, kind: result?.metadata.contentKind, language: result?.metadata.language }, {
			requests: row.expectedLanguages.map((lang) => ({ videoId: "abc123XYZ_-", lang, hasLanguage: lang !== undefined, videoDetails: true, sameSignal: true })),
			source: "youtube-captions", title: row.title, content: row.expectedContent, kind: "full-transcript", language: row.returned,
		});
	});
}
for (const { name, language, error } of [
	{ name: "unavailable language", language: "de", error: Object.assign(new Error("language"), { name: "YoutubeTranscriptNotAvailableLanguageError", availableLangs: ["fr", "en-US"] }) },
	{ name: "caption failure", language: undefined, error: new Error("caption-fixture-failure") },
]) {
	test(`caption rejection: ${name}`, async () => {
		let calls = 0;
		const result = await extractYouTubeUrl("https://youtu.be/abc123XYZ_-", { mode: "transcript", transcriptLanguage: language, transcriptFetcher: async () => { calls++; throw error; } }).then(() => undefined, (caught: unknown) => caught);
		assert.deepEqual({ sameError: result === error, calls }, { sameError: true, calls: 1 });
	});
}

test("understanding overrides transcript prompt detection", async () => {
	let transcriptCalls = 0;
	let sentPrompt: string | undefined;
	const result = await extractYouTubeUrl("https://youtu.be/abc123XYZ_-", {
		mode: "understand", prompt: "Summarize this transcript", preferGeminiWeb: false, geminiApiKey: "key",
		transcriptFetcher: async () => { transcriptCalls++; throw new Error("unexpected transcript call"); },
		fetchImpl: async (_url, init) => {
			sentPrompt = JSON.parse(String(init?.body)).contents[0].parts[1].text;
			return new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: "Visual summary" }] } }] }), { status: 200 });
		},
	});
	assert.deepEqual({ transcriptCalls, sentPrompt, source: result?.source, content: result?.content }, { transcriptCalls: 0, sentPrompt: "Summarize this transcript", source: "gemini-api", content: "Visual summary" });
});

test("understanding preserves AbortError identity", async () => {
	const abort = new DOMException("cancelled", "AbortError");
	await assert.rejects(() => extractYouTubeUrl("https://youtu.be/abc123XYZ_-", { mode: "understand", preferGeminiWeb: false, geminiApiKey: "key", fetchImpl: async () => { throw abort; } }), (error) => error === abort);
});

test("caption timeout callback aborts the transcript fetcher", async (t) => {
	let fire: (() => void) | undefined;
	let delay: number | undefined;
	const timer = { unref() {} };
	t.mock.method(globalThis, "setTimeout", (callback: () => void, milliseconds: number) => { fire = callback; delay = milliseconds; return timer; });
	t.mock.method(globalThis, "clearTimeout", () => {});
	let signal: AbortSignal | undefined;
	const pending = extractYouTubeUrl("https://youtu.be/abc123XYZ_-", {
		mode: "transcript", timeoutMs: 5,
		transcriptFetcher: async (_id, config) => {
			signal = config.signal;
			return await new Promise((_resolve, reject) => config.signal?.addEventListener("abort", () => reject(config.signal?.reason), { once: true }));
		},
	}).then(() => undefined, (error: unknown) => error);
	fire?.();
	// An omitted abort must fail before awaiting the pending extraction.
	const aborted = signal?.aborted;
	const error = aborted ? await pending : undefined;
	assert.deepEqual({ delay, aborted, timeout: error instanceof DOMException && error.name === "TimeoutError" }, { delay: 5, aborted: true, timeout: true });
});

test("successful captions remove the parent timeout listener", async (t) => {
	const signal = new AbortController().signal;
	const add = t.mock.method(signal, "addEventListener");
	const remove = t.mock.method(signal, "removeEventListener");
	await extractYouTubeUrl("https://youtu.be/abc123XYZ_-", { mode: "transcript", timeoutMs: 60000, signal, transcriptFetcher: async (id) => captions(id, "Cleanup", "Done", "en") });
	assert.deepEqual({ added: add.mock.callCount(), removed: remove.mock.callCount() }, { added: 1, removed: 1 });
});
