import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { isLocalVideoPath, videoMimeForPath } from "../src/extract/video.js";
import { extractYouTubeUrl, formatYouTubeTranscript, isTranscriptPrompt, parseYouTubeUrl } from "../src/extract/youtube.js";
import { createWebFetchToolDefinition } from "../src/tools/web-fetch.js";

test("parseYouTubeUrl handles watch/youtu.be/shorts/live/embed/v", () => {
	assert.equal(parseYouTubeUrl("https://www.youtube.com/watch?v=abc123XYZ_-")?.videoId, "abc123XYZ_-");
	assert.equal(parseYouTubeUrl("https://youtu.be/abc123XYZ_-")?.videoId, "abc123XYZ_-");
	assert.equal(parseYouTubeUrl("https://youtube.com/shorts/abcDEF")?.kind, "short");
	assert.equal(parseYouTubeUrl("https://www.youtube.com/live/streamId1")?.kind, "live");
	assert.equal(parseYouTubeUrl("https://www.youtube.com/embed/clipId")?.kind, "embed");
	assert.equal(parseYouTubeUrl("https://www.youtube.com/v/legacyId")?.kind, "v");
});

test("parseYouTubeUrl returns undefined for unrelated hosts", () => {
	assert.equal(parseYouTubeUrl("https://vimeo.com/123"), undefined);
	assert.equal(parseYouTubeUrl("https://example.com/?v=fake"), undefined);
	assert.equal(parseYouTubeUrl("not a url"), undefined);
});

test("isTranscriptPrompt recognizes transcript requests", () => {
	assert.equal(isTranscriptPrompt("Produce a complete transcript with timestamps"), true);
	assert.equal(isTranscriptPrompt("Transcribe this video verbatim"), true);
	assert.equal(isTranscriptPrompt("Summarize the visual design"), false);
});

test("formatYouTubeTranscript emits complete timestamped caption lines", () => {
	assert.equal(formatYouTubeTranscript([
		{ offset: 0.08, duration: 1.2, text: "Hello &amp; welcome", lang: "en" },
		{ offset: 3661.9, duration: 2, text: "Don&#39;t\ntruncate this", lang: "en" },
	]), "[00:00:00] Hello & welcome\n[01:01:01] Don't truncate this");
});

test("formatYouTubeTranscript preserves invalid numeric HTML entities", () => {
	assert.equal(formatYouTubeTranscript([
		{ offset: 0, duration: 1, text: "invalid &#x110000; &#55296; &#xDFFF; valid &#x1F600;", lang: "en" },
	]), "[00:00:00] invalid &#x110000; &#55296; &#xDFFF; valid 😀");
});

test("extractYouTubeUrl uses native captions for transcript prompts", async () => {
	const controller = new AbortController();
	const result = await extractYouTubeUrl("https://www.youtube.com/watch?v=abc123XYZ_-&t=42s", {
		prompt: "Return the full transcript",
		transcriptLanguage: "fr",
		signal: controller.signal,
		transcriptFetcher: async (videoId, config) => {
			assert.equal(videoId, "abc123XYZ_-");
			assert.equal(config.lang, "fr");
			assert.equal(config.videoDetails, true);
			assert.equal(config.signal, controller.signal);
			return {
				videoDetails: {
					videoId,
					title: "Test Video",
					author: "Test Channel",
					channelId: "channel-1",
					lengthSeconds: 65,
					viewCount: 1,
					description: "",
					keywords: [],
					thumbnails: [],
					isLiveContent: false,
				},
				segments: [{ offset: 1, duration: 2, text: "Complete caption", lang: "en" }],
			};
		},
	});
	assert.equal(result?.source, "youtube-captions");
	assert.equal(result?.title, "Test Video");
	assert.equal(result?.content, "[00:00:01] Complete caption");
	assert.equal(result?.metadata.contentKind, "full-transcript");
});

test("extractYouTubeUrl preserves caption fallback and recovers language variants", async () => {
	const fallback = await extractYouTubeUrl("https://youtu.be/abc123XYZ_-", {
		mode: "transcript",
		transcriptFetcher: async (videoId, config) => {
			assert.equal(Object.hasOwn(config, "lang"), false);
			return {
				videoDetails: {
					videoId,
					title: "Fallback Track",
					author: "Channel",
					channelId: "channel-1",
					lengthSeconds: 1,
					viewCount: 1,
					description: "",
					keywords: [],
					thumbnails: [],
					isLiveContent: false,
				},
				segments: [{ offset: 0, duration: 1, text: "Hola", lang: "es" }],
			};
		},
	});
	assert.equal(fallback?.metadata.language, "es");

	const requestedLanguages: Array<string | undefined> = [];
	const recovered = await extractYouTubeUrl("https://youtu.be/abc123XYZ_-", {
		mode: "transcript",
		transcriptLanguage: "EN",
		transcriptFetcher: async (videoId, config) => {
			requestedLanguages.push(config.lang);
			if (config.lang === "EN") {
				throw Object.assign(new Error("requested language unavailable"), {
					name: "YoutubeTranscriptNotAvailableLanguageError",
					availableLangs: ["fr", "en-US"],
				});
			}
			assert.equal(config.lang, "en-US");
			return {
				videoDetails: {
					videoId,
					title: "English Track",
					author: "Channel",
					channelId: "channel-1",
					lengthSeconds: 1,
					viewCount: 1,
					description: "",
					keywords: [],
					thumbnails: [],
					isLiveContent: false,
				},
				segments: [{ offset: 0, duration: 1, text: "Hello", lang: "en-US" }],
			};
		},
	});
	assert.deepEqual(requestedLanguages, ["EN", "en-US"]);
	assert.equal(recovered?.metadata.language, "en-US");

	const unavailable = Object.assign(new Error("requested language unavailable"), {
		name: "YoutubeTranscriptNotAvailableLanguageError",
		availableLangs: ["fr", "en-US"],
	});
	let unavailableCalls = 0;
	await assert.rejects(() => extractYouTubeUrl("https://youtu.be/abc123XYZ_-", {
		mode: "transcript",
		transcriptLanguage: "de",
		transcriptFetcher: async () => {
			unavailableCalls++;
			throw unavailable;
		},
	}), (error) => error === unavailable);
	assert.equal(unavailableCalls, 1);
});

test("videoMode=understand overrides transcript prompt detection", async () => {
	let transcriptCalls = 0;
	const result = await extractYouTubeUrl("https://youtu.be/abc123XYZ_-", {
		mode: "understand",
		prompt: "Summarize this transcript",
		preferGeminiWeb: false,
		geminiApiKey: "key",
		transcriptFetcher: async () => { transcriptCalls++; throw new Error("unexpected transcript call"); },
		fetchImpl: (async () => new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: "Visual summary" }] } }] }), { status: 200 })) as typeof fetch,
	});
	assert.equal(transcriptCalls, 0);
	assert.equal(result?.source, "gemini-api");
	assert.equal(result?.content, "Visual summary");
});

test("Gemini understanding preserves AbortError identity", async () => {
	const abort = new DOMException("cancelled", "AbortError");
	await assert.rejects(() => extractYouTubeUrl("https://youtu.be/abc123XYZ_-", {
		mode: "understand",
		preferGeminiWeb: false,
		geminiApiKey: "key",
		fetchImpl: (async () => { throw abort; }) as typeof fetch,
	}), (error) => {
		assert.equal(error, abort);
		return true;
	});
});

test("transcript failures surface directly instead of falling through to generic extraction", async () => {
	await assert.rejects(() => extractYouTubeUrl("https://youtu.be/abc123XYZ_-", {
		mode: "transcript",
		transcriptFetcher: async () => { throw new Error("captions disabled"); },
	}), /captions disabled/);
});

function webFetchSettings(videoEnabled = true): any {
	return {
		apiKeys: { exa: "exa-key", gemini: undefined, jina: undefined },
		video: { enabled: videoEnabled },
		browserCookies: { preferredBrowser: "auto", profile: undefined },
		githubClone: { enabled: false, maxRepoSizeMB: 350, cloneTimeoutSeconds: 60, cacheMaxAgeHours: 24 },
		htmlExtraction: { jinaFallback: false },
		pdfOcr: { enabled: false, maxPages: 5, dpi: 150 },
	};
}

test("web_fetch stores transcripts beyond the Exa cap without calling Exa", async () => {
	let exaCalls = 0;
	let stored: any;
	const transcript = "[00:00:00] " + "complete caption ".repeat(500);
	const tool = createWebFetchToolDefinition(
		{ appendEntry: (_type: string, item: unknown) => { stored = item; } } as any,
		() => webFetchSettings(),
		"web_fetch",
		{
			extractYouTubeUrl: async () => ({
				videoId: "abc123XYZ_-",
				url: "https://www.youtube.com/watch?v=abc123XYZ_-",
				title: "Complete Transcript",
				content: transcript,
				source: "youtube-captions",
				metadata: { provider: "youtube-captions", contentKind: "full-transcript", captionSegments: 500 },
			}),
			createExaClient: () => { exaCalls++; return {} as any; },
		},
	);
	const result = await tool.execute("test", {
		url: "https://youtu.be/abc123XYZ_-",
		provider: "http",
		videoMode: "transcript",
	}, undefined, undefined, { cwd: process.cwd() } as any);
	assert.ok(transcript.length > 6000);
	assert.equal(stored.content, transcript);
	assert.equal((result as any).details.provider, "youtube-captions");
	assert.equal(exaCalls, 0);
});

test("web_fetch never uses Exa after a YouTube extractor failure", async () => {
	let exaCalls = 0;
	const tool = createWebFetchToolDefinition(
		{ appendEntry() {} } as any,
		() => webFetchSettings(),
		"web_fetch",
		{
			extractYouTubeUrl: async () => { throw new Error("captions disabled"); },
			createExaClient: () => { exaCalls++; return {} as any; },
		},
	);
	await assert.rejects(() => tool.execute("test", {
		url: "https://youtu.be/abc123XYZ_-",
		videoMode: "transcript",
	}, undefined, undefined, { cwd: process.cwd() } as any), /captions disabled/);
	assert.equal(exaCalls, 0);
});

test("web_fetch returns successful batch items alongside YouTube failures", async () => {
	let exaCalls = 0;
	const tool = createWebFetchToolDefinition(
		{ appendEntry() {} } as any,
		() => webFetchSettings(),
		"web_fetch",
		{
			extractYouTubeUrl: async (url) => {
				if (url.includes("failedVid02")) throw new Error("captions disabled");
				return {
					videoId: "successVid1",
					url,
					title: "Complete Transcript",
					content: "[00:00:00] success",
					source: "youtube-captions",
					metadata: { provider: "youtube-captions", contentKind: "full-transcript" },
				};
			},
			createExaClient: () => { exaCalls++; return {} as any; },
		},
	);
	const result = await tool.execute("test", {
		urls: ["https://youtu.be/successVid1", "https://youtu.be/failedVid02"],
		videoMode: "transcript",
	}, undefined, undefined, { cwd: process.cwd() } as any);
	assert.equal((result as any).details.stored.length, 1);
	assert.equal((result as any).details.failures.length, 1);
	assert.equal((result as any).details.partial, true);
	assert.match((result as any).content[0].text, /Failed 1 URL/);
	assert.equal((result as any).details.stored[0].title, "Complete Transcript");
	assert.equal((result as any).details.failures[0].url, "https://youtu.be/failedVid02");
	assert.match((result as any).details.failures[0].error, /captions disabled/);
	assert.equal(exaCalls, 0);
});

test("web_fetch keeps partial failure text inside the multi-URL aggregate cap", async () => {
	const urls = Array.from({ length: 7 }, (_, index) => `https://youtu.be/videoId000${index}`);
	const tool = createWebFetchToolDefinition(
		{ appendEntry() {} } as any,
		() => webFetchSettings(),
		"web_fetch",
		{
			extractYouTubeUrl: async (url) => {
				if (!url.endsWith("0")) throw new Error("failure ".repeat(10000));
				return {
					videoId: url.slice(-11),
					url,
					title: "Transcript",
					content: "caption ".repeat(2000),
					source: "youtube-captions",
					metadata: { provider: "youtube-captions" },
				};
			},
		},
	);
	const result = await tool.execute("test", { urls, videoMode: "transcript" }, undefined, undefined, { cwd: process.cwd() } as any);
	assert.ok((result as any).content[0].text.length <= 25 * 1024);
	assert.equal((result as any).details.stored.length, 1);
	assert.equal((result as any).details.failures.length, 6);
});

test("web_fetch returns successes when Exa fallback also fails", async () => {
	const tool = createWebFetchToolDefinition(
		{ appendEntry() {} } as any,
		() => webFetchSettings(),
		"web_fetch",
		{
			extractYouTubeUrl: async (url) => ({
				videoId: "successVid1",
				url,
				title: "Transcript",
				content: "[00:00:00] success",
				source: "youtube-captions",
				metadata: { provider: "youtube-captions" },
			}),
			fetchHttpContent: async () => { throw new Error("direct blocked"); },
			createExaClient: () => ({ contents: async () => { throw new Error("Exa unavailable"); } }) as any,
		},
	);
	const result = await tool.execute("test", {
		urls: ["https://youtu.be/successVid1", "https://example.invalid/fail"],
		videoMode: "transcript",
	}, undefined, undefined, { cwd: process.cwd() } as any);
	assert.equal((result as any).details.stored.length, 1);
	assert.equal((result as any).details.failures[0].url, "https://example.invalid/fail");
	assert.match((result as any).details.failures[0].error, /Exa unavailable/);
});

test("web_fetch reconciles Exa HTTP-200 per-URL failures", async () => {
	const tool = createWebFetchToolDefinition(
		{ appendEntry() {} } as any,
		() => webFetchSettings(),
		"web_fetch",
		{
			createExaClient: () => ({
				contents: async () => ({
					results: [{ url: "https://example.com/good", title: "Good", text: "content" }],
					raw: { statuses: [{ url: "https://example.com/bad", status: "blocked" }] },
				}),
			}) as any,
		},
	);
	const result = await tool.execute("test", {
		urls: ["https://example.com/good", "https://example.com/bad"],
		provider: "exa",
	}, undefined, undefined, { cwd: process.cwd() } as any);
	assert.equal((result as any).details.stored.length, 1);
	assert.equal((result as any).details.failures.length, 1);
	assert.equal((result as any).details.failures[0].provider, "exa");
	assert.match((result as any).details.failures[0].error, /blocked/);

	const allFailedTool = createWebFetchToolDefinition(
		{ appendEntry() {} } as any,
		() => webFetchSettings(),
		"web_fetch",
		{ createExaClient: () => ({ contents: async () => ({ results: [], raw: { statuses: [{ url: "https://example.com/bad", error: "denied" }] } }) }) as any },
	);
	await assert.rejects(() => allFailedTool.execute("test", {
		url: "https://example.com/bad",
		provider: "exa",
	}, undefined, undefined, { cwd: process.cwd() } as any), /denied/);

	const dedupedTool = createWebFetchToolDefinition(
		{ appendEntry() {} } as any,
		() => webFetchSettings(),
		"web_fetch",
		{
			createExaClient: () => ({
				contents: async () => ({
					results: [{ url: "https://example.com/", title: "Example", text: "content" }],
					raw: { statuses: [{ url: "http://example.com", status: "success" }, { url: "https://example.com/", status: "success" }] },
				}),
			}) as any,
		},
	);
	const deduped = await dedupedTool.execute("test", {
		urls: ["http://example.com", "https://example.com/"],
		provider: "exa",
	}, undefined, undefined, { cwd: process.cwd() } as any);
	assert.equal((deduped as any).details.stored.length, 1);
	assert.equal((deduped as any).details.failures.length, 1);
	assert.equal((deduped as any).details.failures[0].url, "http://example.com");
	assert.match((deduped as any).details.failures[0].error, /success.*without text or summary/i);
});

test("web_fetch reports Exa success statuses with empty content", async () => {
	const tool = createWebFetchToolDefinition(
		{ appendEntry() {} } as any,
		() => webFetchSettings(),
		"web_fetch",
		{
			createExaClient: () => ({
				contents: async () => ({
					results: [{ url: "https://example.com/empty", title: "Empty", text: "", summary: "" }],
					raw: { statuses: [{ url: "https://example.com/empty", status: "success" }] },
				}),
			}) as any,
		},
	);
	await assert.rejects(() => tool.execute("test", {
		url: "https://example.com/empty",
		provider: "exa",
	}, undefined, undefined, { cwd: process.cwd() } as any), /success.*without text or summary/i);
});

test("web_fetch normalizes Exa status ids before matching", async () => {
	const tool = createWebFetchToolDefinition(
		{ appendEntry() {} } as any,
		() => webFetchSettings(),
		"web_fetch",
		{
			createExaClient: () => ({
				contents: async () => ({
					results: [],
					raw: { statuses: [{ id: "https://example.com/status-detail/", status: "permission denied" }] },
				}),
			}) as any,
		},
	);
	await assert.rejects(() => tool.execute("test", {
		url: "https://example.com/status-detail",
		provider: "exa",
	}, undefined, undefined, { cwd: process.cwd() } as any), /permission denied/);
});

test("web_fetch preserves AbortError identity and aggregates all-failed batches", async () => {
	const abort = new DOMException("cancelled", "AbortError");
	const abortingTool = createWebFetchToolDefinition(
		{ appendEntry() {} } as any,
		() => webFetchSettings(),
		"web_fetch",
		{ extractYouTubeUrl: async () => { throw abort; } },
	);
	await assert.rejects(() => abortingTool.execute("test", {
		url: "https://youtu.be/abc123XYZ_-",
		videoMode: "transcript",
	}, undefined, undefined, { cwd: process.cwd() } as any), (error) => {
		assert.equal(error, abort);
		return true;
	});

	const failingTool = createWebFetchToolDefinition(
		{ appendEntry() {} } as any,
		() => webFetchSettings(),
		"web_fetch",
		{ extractYouTubeUrl: async (url) => { throw new Error(`failed ${url.slice(-11)}`); } },
	);
	await assert.rejects(() => failingTool.execute("test", {
		urls: ["https://youtu.be/failedVid01", "https://youtu.be/failedVid02"],
		videoMode: "transcript",
	}, undefined, undefined, { cwd: process.cwd() } as any), (error) => {
		assert.match(String(error), /failedVid01/);
		assert.match(String(error), /failedVid02/);
		return true;
	});

	const manyFailingTool = createWebFetchToolDefinition(
		{ appendEntry() {} } as any,
		() => webFetchSettings(),
		"web_fetch",
		{ extractYouTubeUrl: async () => { throw new Error("failure ".repeat(10000)); } },
	);
	await assert.rejects(() => manyFailingTool.execute("test", {
		urls: Array.from({ length: 7 }, (_, index) => `https://youtu.be/videoId000${index}`),
		videoMode: "transcript",
	}, undefined, undefined, { cwd: process.cwd() } as any), (error) => {
		assert.ok(String(error).length <= 25 * 1024);
		return true;
	});
});

test("web_fetch videoMode=understand bypasses transcript-like prompt preflight", async () => {
	let seenMode: string | undefined;
	const tool = createWebFetchToolDefinition(
		{ appendEntry() {} } as any,
		() => webFetchSettings(),
		"web_fetch",
		{
			extractYouTubeUrl: async (url, options) => {
				seenMode = options?.mode;
				return { videoId: "abc123XYZ_-", url, title: "Summary", content: "visual summary", source: "gemini-api", metadata: { provider: "gemini-api" } };
			},
		},
	);
	await tool.execute("test", {
		url: "https://youtu.be/abc123XYZ_-",
		videoMode: "understand",
		prompt: "Summarize this transcript visually",
	}, undefined, undefined, { cwd: process.cwd() } as any);
	assert.equal(seenMode, "understand");
});

test("web_fetch forwards auto transcript prompt, language, and signal", async () => {
	const controller = new AbortController();
	let observed = false;
	const tool = createWebFetchToolDefinition(
		{ appendEntry() {} } as any,
		() => webFetchSettings(),
		"web_fetch",
		{
			extractYouTubeUrl: async (url, options) => {
				assert.equal(options?.prompt, "Produce complete transcript");
				assert.equal(options?.transcriptLanguage, "de");
				assert.equal(options?.signal, controller.signal);
				observed = true;
				return { videoId: "abc123XYZ_-", url, title: "Transcript", content: "[00:00:00] Hallo", source: "youtube-captions", metadata: { provider: "youtube-captions" } };
			},
		},
	);
	await tool.execute("test", {
		url: "https://youtu.be/abc123XYZ_-",
		prompt: "Produce complete transcript",
		transcriptLanguage: "de",
	}, controller.signal, undefined, { cwd: process.cwd() } as any);
	assert.equal(observed, true);
});

test("web_fetch rejects transcript requests that force Exa or disable video extraction", async () => {
	const enabledTool = createWebFetchToolDefinition({ appendEntry() {} } as any, () => webFetchSettings());
	await assert.rejects(() => enabledTool.execute("test", {
		url: "https://youtu.be/abc123XYZ_-",
		provider: "exa",
		videoMode: "transcript",
	}, undefined, undefined, { cwd: process.cwd() } as any), /incompatible with provider=exa/);
	await assert.rejects(() => enabledTool.execute("test", {
		url: "https://youtu.be/abc123XYZ_-",
		provider: "exa",
		prompt: "Produce complete transcript",
	}, undefined, undefined, { cwd: process.cwd() } as any), /incompatible with provider=exa/);

	const disabledTool = createWebFetchToolDefinition({ appendEntry() {} } as any, () => webFetchSettings(false));
	await assert.rejects(() => disabledTool.execute("test", {
		url: "https://youtu.be/abc123XYZ_-",
		videoMode: "transcript",
	}, undefined, undefined, { cwd: process.cwd() } as any), /disabled by the video.enabled setting/);
	await assert.rejects(() => disabledTool.execute("test", {
		url: "https://youtu.be/abc123XYZ_-",
		prompt: "Produce complete transcript",
	}, undefined, undefined, { cwd: process.cwd() } as any), /disabled by the video.enabled setting/);
});

test("web_fetch keeps transcript conflicts per-URL in mixed batches", async () => {
	const exaTool = createWebFetchToolDefinition(
		{ appendEntry() {} } as any,
		() => webFetchSettings(),
		"web_fetch",
		{
			createExaClient: () => ({
				contents: async ({ urls }: { urls: string[] }) => {
					assert.deepEqual(urls, ["https://example.com/good"]);
					return { results: [{ url: urls[0], title: "Good", text: "content" }], raw: {} };
				},
			}) as any,
		},
	);
	const exaResult = await exaTool.execute("test", {
		urls: ["https://youtu.be/abc123XYZ_-", "https://example.com/good"],
		provider: "exa",
		videoMode: "transcript",
	}, undefined, undefined, { cwd: process.cwd() } as any);
	assert.equal((exaResult as any).details.stored.length, 1);
	assert.equal((exaResult as any).details.failures[0].url, "https://youtu.be/abc123XYZ_-");
	assert.match((exaResult as any).details.failures[0].error, /incompatible with provider=exa/);

	const disabledTool = createWebFetchToolDefinition(
		{ appendEntry() {} } as any,
		() => webFetchSettings(false),
		"web_fetch",
		{ fetchHttpContent: async (url) => ({ url, title: "Good", content: "content", metadata: {} }) },
	);
	const disabledResult = await disabledTool.execute("test", {
		urls: ["https://youtu.be/abc123XYZ_-", "https://example.com/good"],
		provider: "http",
		videoMode: "transcript",
	}, undefined, undefined, { cwd: process.cwd() } as any);
	assert.equal((disabledResult as any).details.stored.length, 1);
	assert.equal((disabledResult as any).details.failures[0].url, "https://youtu.be/abc123XYZ_-");
	assert.match((disabledResult as any).details.failures[0].error, /disabled by the video.enabled setting/);
});

test("isLocalVideoPath detects common video extensions", () => {
	const dir = mkdtempSync(join(tmpdir(), "pi-vid-test-"));
	const mp4 = join(dir, "sample.mp4");
	writeFileSync(mp4, "fake");
	assert.equal(isLocalVideoPath(mp4), true);
	assert.equal(isLocalVideoPath("/x/foo.mov"), true);
	assert.equal(isLocalVideoPath("/x/foo.webm"), true);
	assert.equal(isLocalVideoPath("/x/foo.txt"), false);
	assert.equal(videoMimeForPath("/x/foo.mp4"), "video/mp4");
	assert.equal(videoMimeForPath("/x/foo.mov"), "video/quicktime");
});
