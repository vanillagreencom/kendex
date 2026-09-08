import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { beforeEach, afterEach } from "node:test";
import { createWebFetchToolDefinition } from "../src/tools/web-fetch.js";
import { clearMemoryForTests } from "../src/storage.js";
import { tempDir } from "./fixtures.js";

beforeEach(clearMemoryForTests);
afterEach(clearMemoryForTests);

interface FailureDetails { failures?: Array<{ url: string; provider: string; error: string }> }

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
	assert.deepEqual({
		exceedsProviderCap: Boolean(transcript.length > 6000),
		content: stored.content,
		provider: (result as any).details.provider,
		"exaCalls": exaCalls,
	}, {
		exceedsProviderCap: true,
		content: transcript,
		provider: "youtube-captions",
		"exaCalls": 0,
	});
});

test("web_fetch never uses Exa after a YouTube extractor failure", async () => {
	let exaCalls = 0;
	const failure = new Error("caption-fixture-failure");
	const tool = createWebFetchToolDefinition(
		{ appendEntry() {} } as any,
		() => webFetchSettings(),
		"web_fetch",
		{
			extractYouTubeUrl: async () => { throw failure; },
			createExaClient: () => { exaCalls++; return {} as any; },
		},
	);
	const error = await tool.execute("test", {
		url: "https://youtu.be/abc123XYZ_-",
		videoMode: "transcript",
	}, undefined, undefined, { cwd: process.cwd() } as any).then(() => undefined, (error: unknown) => error);
	assert.deepEqual({ sameError: error instanceof Error && error.message.includes(failure.message), exaCalls }, { sameError: true, exaCalls: 0 });
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
	assert.deepEqual({
		length: (result as any).details.stored.length,
		length2: (result as any).details.failures.length,
		partial: (result as any).details.partial,
		fixtureTextPresent: /Failed 1 URL/.test((result as any).content[0].text),
		title: (result as any).details.stored[0].title,
		url: (result as any).details.failures[0].url,
		fixtureTextPresent2: /captions disabled/.test((result as any).details.failures[0].error),
		"exaCalls": exaCalls,
	}, {
		length: 1,
		length2: 1,
		partial: true,
		fixtureTextPresent: true,
		title: "Complete Transcript",
		url: "https://youtu.be/failedVid02",
		fixtureTextPresent2: true,
		"exaCalls": 0,
	});
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
	assert.deepEqual({
		insideAggregateCap: Boolean((result as any).content[0].text.length <= 25 * 1024),
		length: (result as any).details.stored.length,
		length2: (result as any).details.failures.length,
		manifest: (result as any).details.preview.manifest,
		perUrlMaxCharacters: (result as any).details.preview.perUrlMaxCharacters,
		shownCharacters: (result as any).details.preview.shownCharacters,
		aggregateCap: (result as any).details.preview.aggregateCap,
	}, {
		insideAggregateCap: true,
		length: 1,
		length2: 6,
		manifest: false,
		perUrlMaxCharacters: 4000,
		shownCharacters: 4000,
		aggregateCap: 25 * 1024,
	});
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
	assert.deepEqual({
		length: (result as any).details.stored.length,
		url: (result as any).details.failures[0].url,
		fixtureTextPresent3: /Exa unavailable/.test((result as any).details.failures[0].error),
	}, {
		length: 1,
		url: "https://example.invalid/fail",
		fixtureTextPresent3: true,
	});
});

test("web_fetch extracts local PDF file paths into session storage", async (t) => {
	clearMemoryForTests();
	t.after(clearMemoryForTests);
	const dir = tempDir(t);
	const path = join(dir, "local.pdf");
	writeFileSync(path, "%PDF-1.4\nBT\n(Local PDF) Tj\nET");
	const appended: any[] = [];
	const tool = createWebFetchToolDefinition({ appendEntry(type: string, data: unknown) { appended.push({ type, data }); } } as any, () => ({ githubClone: { enabled: true }, apiKeys: {}, htmlExtraction: { jinaFallback: false }, pdfOcr: { enabled: false, maxPages: 5, dpi: 150 }, video: { enabled: false }, browserCookies: { preferredBrowser: "auto" } }) as any);
	const result = await tool.execute("call", { filePath: path, provider: "auto" }, undefined, undefined, { cwd: dir } as any);
	assert.equal(result.details.provider, "local");
	const stored = result.details.stored[0]!;
	assert.deepEqual({
		title2: stored.title,
		provider2: stored.metadata?.provider,
	}, {
		title2: "local.pdf",
		provider2: "local",
	});
	const block = result.content[0]!;
	assert.deepEqual({
		type: block.type,
		contentPresent: /Local PDF/.test(block.type === "text" ? block.text : ""),
		length3: appended.length,
	}, {
		type: "text",
		contentPresent: true,
		length3: 1,
	});
});

for (const row of [
	{ name: "canonical URL", urls: ["http://www.example.com/article/"], results: [{ url: "https://example.com/article", title: "Canonical", text: "canonical content" }], statuses: [], expected: { urls: ["http://www.example.com/article/"], content: ["canonical content"], failures: undefined } },
	{ name: "result id", urls: ["http://example.com/id-match"], results: [{ id: "https://www.example.com/id-match/", url: "https://redirected.example/final", title: "Redirected", text: "redirect content" }], statuses: [], expected: { urls: ["http://example.com/id-match"], content: ["redirect content"], failures: undefined } },
	{ name: "missing URL singleton", urls: ["https://example.com/missing-url"], results: [{ title: "Missing URL", text: "positional content" }], statuses: [], expected: { urls: ["https://example.com/missing-url"], content: ["positional content"], failures: undefined } },
	{ name: "all anonymous", urls: ["https://example.com/a", "https://example.com/b", "https://example.com/c"], results: [{ text: "anonymous a" }, { text: "anonymous b" }, { text: "anonymous c" }], statuses: [], expected: { urls: ["https://example.com/a", "https://example.com/b", "https://example.com/c"], content: ["anonymous a", "anonymous b", "anonymous c"], failures: undefined } },
	{ name: "position preserved", urls: ["https://example.com/a", "https://example.com/b", "https://example.com/c"], results: [{ id: "https://example.com/a", text: "identified a" }, { text: "anonymous b" }, { id: "https://example.com/c", text: "identified c" }], statuses: [], expected: { urls: ["https://example.com/a", "https://example.com/b", "https://example.com/c"], content: ["identified a", "anonymous b", "identified c"], failures: undefined } },
	{ name: "singleton remainder", urls: ["https://example.com/a", "https://example.com/b", "https://example.com/c"], results: [{ id: "https://example.com/c", text: "identified c" }, { id: "https://example.com/a", text: "identified a" }, { text: "anonymous b" }], statuses: [], expected: { urls: ["https://example.com/a", "https://example.com/b", "https://example.com/c"], content: ["identified a", "anonymous b", "identified c"], failures: undefined } },
	{ name: "ambiguous remainder", urls: ["https://example.com/a", "https://example.com/b", "https://example.com/c"], results: [{ id: "https://example.com/c", text: "identified c" }, { text: "ambiguous anonymous one" }, { text: "ambiguous anonymous two" }], statuses: [], expected: { urls: ["https://example.com/c"], content: ["identified c"], failures: ["https://example.com/a", "https://example.com/b"] } },
	{ name: "deduplicated success status", urls: ["http://example.com", "https://example.com/"], results: [{ url: "https://example.com/", title: "Example", text: "content" }], statuses: [{ url: "http://example.com", status: "success" }, { url: "https://example.com/", status: "success" }], expected: { urls: ["http://example.com"], content: ["content"], failures: undefined } },
]) {
	test(`web_fetch Exa reconciliation: ${row.name}`, async () => {
		const tool = createWebFetchToolDefinition({ appendEntry() {} } as any, () => webFetchSettings(), "web_fetch", { createExaClient: () => ({ contents: async () => ({ results: row.results, raw: { statuses: row.statuses } }) }) as any });
		const result = await tool.execute("test", { urls: row.urls, provider: "exa" }, undefined, undefined, { cwd: process.cwd() } as any);
		const stored = [...result.details.stored].sort((a, b) => (a.url ?? "").localeCompare(b.url ?? ""));
		assert.deepEqual({ urls: stored.map((item) => item.url), content: stored.map((item) => item.content), failures: (result.details as typeof result.details & FailureDetails).failures?.map((item) => item.url) }, row.expected);
	});
}

for (const row of [
	{ name: "per-URL blocked", urls: ["https://example.com/good", "https://example.com/bad"], results: [{ url: "https://example.com/good", title: "Good", text: "content" }], statuses: [{ url: "https://example.com/bad", status: "blocked" }], token: "blocked", expected: { stored: 1, failures: 1, provider: "exa", token: true } },
	{ name: "all denied", urls: ["https://example.com/bad"], results: [], statuses: [{ url: "https://example.com/bad", error: "denied" }], token: "denied", expected: { rejected: true, token: true } },
	{ name: "success without content", urls: ["https://example.com/empty"], results: [{ url: "https://example.com/empty", title: "Empty", text: "", summary: "" }], statuses: [{ url: "https://example.com/empty", status: "success" }], token: "success", expected: { rejected: true, token: true } },
	{ name: "normalized status id", urls: ["https://example.com/status-detail"], results: [], statuses: [{ id: "https://example.com/status-detail/", status: "permission denied" }], token: "permission denied", expected: { rejected: true, token: true } },
	{ name: "unrelated batch", urls: ["https://example.com/one", "https://example.com/two"], results: [{ url: "https://unrelated.example/one", text: "unrelated one" }, { url: "https://unrelated.example/two", text: "unrelated two" }], statuses: [], token: undefined, expected: { rejected: true, token: true } },
	{ name: "unrelated singleton", urls: ["https://example.com/requested"], results: [{ url: "https://unrelated.example/page", text: "unrelated" }], statuses: [], token: undefined, expected: { rejected: true, token: true } },
]) {
	test(`web_fetch Exa failure: ${row.name}`, async () => {
		const tool = createWebFetchToolDefinition({ appendEntry() {} } as any, () => webFetchSettings(), "web_fetch", { createExaClient: () => ({ contents: async () => ({ results: row.results, raw: { statuses: row.statuses } }) }) as any });
		const result = await tool.execute("test", { urls: row.urls, provider: "exa" }, undefined, undefined, { cwd: process.cwd() } as any).then(
			(out) => ({ stored: out.details.stored.length, failures: (out.details as typeof out.details & FailureDetails).failures?.length, provider: (out.details as typeof out.details & FailureDetails).failures?.[0]?.provider, token: (out.details as typeof out.details & FailureDetails).failures?.[0]?.error.includes(row.token ?? "") }),
			(error: unknown) => ({ rejected: error instanceof Error, token: row.token === undefined || String(error).includes(row.token) }),
		);
		assert.deepEqual(result, row.expected);
	});
}

for (const mode of [undefined, "understand"] as const) {
	test(`non-transcript YouTube fallback: ${mode}`, async () => {
		let exaCalls = 0;
		const attemptedModes: unknown[] = [];
		const tool = createWebFetchToolDefinition({ appendEntry() {} } as any, () => webFetchSettings(), "web_fetch", {
			extractYouTubeUrl: async (_url, options) => { attemptedModes.push(options?.mode); throw new Error("Gemini-fixture-failure"); },
			createExaClient: () => ({ contents: async ({ urls }: { urls: string[] }) => { exaCalls++; return { results: [{ url: urls[0], title: "YouTube", text: "page excerpt" }], raw: {} }; } }) as any,
		});
		const result = await tool.execute("test", { url: "https://youtu.be/plainVideo1", videoMode: mode }, undefined, undefined, { cwd: process.cwd() } as any);
		assert.deepEqual({ provider: result.details.provider, attemptedModes, exaCalls }, { provider: "exa", attemptedModes: [mode], exaCalls: 1 });
	});
}

for (const row of [
	{ name: "understand overrides prompt", mode: "understand" as const, prompt: "Summarize this transcript visually", language: undefined },
	{ name: "auto prompt and language", mode: undefined, prompt: "Produce complete transcript", language: "de" },
]) {
	test(`web_fetch video options: ${row.name}`, async () => {
		const controller = new AbortController();
		const observed: unknown[] = [];
		const tool = createWebFetchToolDefinition({ appendEntry() {} } as any, () => webFetchSettings(), "web_fetch", {
			extractYouTubeUrl: async (url, options) => {
				observed.push({ mode: options?.mode, prompt: options?.prompt, language: options?.transcriptLanguage, signal: options?.signal === controller.signal, timeout: options?.timeoutMs });
				return { videoId: "abc123XYZ_-", url, title: "Transcript", content: "[00:00:00] Hallo", source: "youtube-captions", metadata: { provider: "youtube-captions" } };
			},
		});
		await tool.execute("test", { url: "https://youtu.be/abc123XYZ_-", videoMode: row.mode, prompt: row.prompt, transcriptLanguage: row.language }, controller.signal, undefined, { cwd: process.cwd() } as any);
		assert.deepEqual(observed, [{ mode: row.mode, prompt: row.prompt, language: row.language, signal: true, timeout: 120000 }]);
	});
}

for (const row of [
	{ name: "forced Exa mode", provider: "exa" as const, enabled: true, videoMode: "transcript" as const, prompt: undefined, mixed: false },
	{ name: "forced Exa prompt", provider: "exa" as const, enabled: true, videoMode: undefined, prompt: "Produce complete transcript", mixed: false },
	{ name: "disabled video mode", provider: "http" as const, enabled: false, videoMode: "transcript" as const, prompt: undefined, mixed: false },
	{ name: "disabled video prompt", provider: "http" as const, enabled: false, videoMode: undefined, prompt: "Produce complete transcript", mixed: false },
	{ name: "forced Exa mixed batch", provider: "exa" as const, enabled: true, videoMode: "transcript" as const, prompt: undefined, mixed: true },
	{ name: "disabled mixed batch", provider: "http" as const, enabled: false, videoMode: "transcript" as const, prompt: undefined, mixed: true },
]) {
	test(`web_fetch transcript conflict: ${row.name}`, async () => {
		const calls: string[] = [];
		const tool = createWebFetchToolDefinition({ appendEntry() {} } as any, () => webFetchSettings(row.enabled), "web_fetch", {
			extractYouTubeUrl: async () => { calls.push("youtube"); throw new Error("unexpected extraction"); },
			fetchHttpContent: async (url) => { calls.push(url); return { url, title: "Good", content: "content", metadata: {} }; },
			createExaClient: () => ({ contents: async ({ urls }: { urls: string[] }) => { calls.push(...urls); return { results: urls.map((url) => ({ url, title: "Good", text: "content" })), raw: {} }; } }) as any,
		});
		const youtube = "https://youtu.be/abc123XYZ_-";
		const urls = row.mixed ? [youtube, "https://example.com/good"] : [youtube];
		const result = await tool.execute("test", { urls, provider: row.provider, videoMode: row.videoMode, prompt: row.prompt }, undefined, undefined, { cwd: process.cwd() } as any).then(
			(out) => ({ stored: out.details.stored.length, failureUrls: (out.details as typeof out.details & FailureDetails).failures?.map((item) => item.url), calls }),
			(error: unknown) => ({ rejected: error instanceof Error, calls }),
		);
		assert.deepEqual(result, row.mixed ? { stored: 1, failureUrls: [youtube], calls: ["https://example.com/good"] } : { rejected: true, calls: [] });
	});
}

for (const { name, count, explicit, success, expected } of [
	{ name: "explicit partial failure", count: 3, explicit: true, success: true, expected: { blockBound: true, rowBounds: [true, true] } },
	{ name: "explicit all failed", count: 2, explicit: true, success: false, expected: { rejected: true, bounded: true } },
	{ name: "large all failed", count: 7, explicit: false, success: false, expected: { rejected: true, bounded: true } },
]) {
	test(`web_fetch failure limits: ${name}`, async () => {
		const tool = createWebFetchToolDefinition({ appendEntry() {} } as any, () => webFetchSettings(), "web_fetch", {
			fetchHttpContent: async (url) => { if (success && url.endsWith("0")) return { url, title: "Good", content: "content", metadata: {} }; throw new Error("failure detail ".repeat(20000)); },
		});
		const result = await tool.execute("test", { urls: Array.from({ length: count }, (_, index) => `https://example.com/${index}`), provider: "http", ...(explicit ? { textMaxCharacters: 100000 } : {}) }, undefined, undefined, { cwd: process.cwd() } as any).then(
			(out) => { const text = out.content[0]!.type === "text" ? out.content[0]!.text : ""; return { blockBound: text.slice(text.indexOf("\n\nFailed")).length <= 8 * 1024, rowBounds: (out.details as typeof out.details & FailureDetails).failures?.map((failure) => failure.error.length <= 1024) }; },
			(error: unknown) => ({ rejected: error instanceof Error, bounded: String(error).length <= (explicit ? 8 : 25) * 1024 }),
		);
		assert.deepEqual(result, expected);
	});
}

test("web_fetch preserves AbortError identity", async () => {
	const abort = new DOMException("cancelled", "AbortError");
	const tool = createWebFetchToolDefinition({ appendEntry() {} } as any, () => webFetchSettings(), "web_fetch", { extractYouTubeUrl: async () => { throw abort; } });
	await assert.rejects(() => tool.execute("test", { url: "https://youtu.be/abc123XYZ_-", videoMode: "transcript" }, undefined, undefined, { cwd: process.cwd() } as any), (error) => error === abort);
});

test("web_fetch all-failed batch retains every fixture failure", async () => {
	const tool = createWebFetchToolDefinition({ appendEntry() {} } as any, () => webFetchSettings(), "web_fetch", { extractYouTubeUrl: async (url) => { throw new Error(`failed ${url.slice(-11)}`); } });
	const result = await tool.execute("test", { urls: ["https://youtu.be/failedVid01", "https://youtu.be/failedVid02"], videoMode: "transcript" }, undefined, undefined, { cwd: process.cwd() } as any).then(() => undefined, (error: unknown) => error);
	assert.deepEqual({ rejected: result instanceof Error, members: [String(result).includes("failedVid01"), String(result).includes("failedVid02")] }, { rejected: true, members: [true, true] });
});
