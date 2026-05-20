import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { clearMemoryForTests, getWebContent, restoreStoredContent, storeWebContent } from "../src/storage.js";
import { createCodeSearchToolDefinition } from "../src/tools/code-search.js";
import { createGetWebContentToolDefinition } from "../src/tools/get-web-content.js";
import { buildWebFetchToolResult, createWebFetchToolDefinition, DEFAULT_WEB_FETCH_PREVIEW_CHARACTERS, MULTI_URL_AGGREGATE_CAP_LARGE_BATCH, MULTI_URL_AGGREGATE_CAP_SMALL_BATCH, MULTI_URL_LARGE_BATCH_PER_URL_HEAD, MULTI_URL_LARGE_BATCH_THRESHOLD } from "../src/tools/web-fetch.js";
import { createWebAnswerToolDefinition } from "../src/tools/web-answer.js";
import { createWebFindSimilarToolDefinition } from "../src/tools/web-find-similar.js";
import { createWebSearchToolDefinition } from "../src/tools/web-search.js";

const theme = { fg: (_tone: string, text: string) => text, bold: (text: string) => text };

test("stored content can be restored from session custom entries", () => {
	clearMemoryForTests();
	const appended: any[] = [];
	const pi = { appendEntry(type: string, data: unknown) { appended.push({ type, data }); } } as any;
	const stored = storeWebContent(pi, { title: "T", url: "https://example.com", content: "Body" });
	assert.equal(getWebContent(stored.id)?.content, "Body");
	clearMemoryForTests();
	restoreStoredContent({ sessionManager: { getEntries: () => appended.map((entry) => ({ type: "custom", customType: entry.type, data: entry.data })) } } as any);
	assert.equal(getWebContent(stored.id)?.url, "https://example.com");
});

test("get_web_content renderer styles missing-id errors with tree guidance", () => {
	const tool = createGetWebContentToolDefinition();
	const component = tool.renderResult({ content: [{ type: "text", text: "Stored content id not found: https://example.com" }] }, {}, theme, { isError: true, args: { id: "https://example.com" } });
	const text = component.render(200).join("\n");
	assert.match(text, /Get Web Content \(Session\)/);
	assert.match(text, /Get Web Content \(Session\) stored content id not found/);
	assert.doesNotMatch(text.split("\n")[0] ?? "", /https:\/\/example\.com/);
	assert.match(text, /├─ content id https:\/\/example\.com/);
	assert.match(text, /URLs are not content ids/);
});

test("get_web_content renderer flags result numbers as non-content ids", () => {
	const tool = createGetWebContentToolDefinition();
	const component = tool.renderResult({ content: [{ type: "text", text: "Stored content id not found: 7" }] }, {}, theme, { isError: true, args: { id: "7" } });
	const text = component.render(200).join("\n");
	assert.match(text, /├─ content id 7/);
	assert.match(text, /Result numbers from web_search are not content ids/);
	assert.match(text, /web_fetch with the result URL/);
});

test("get_web_content renderer separates session retrieval from source provider", () => {
	const tool = createGetWebContentToolDefinition();
	const component = tool.renderResult({ details: { id: "web-123", title: "Example", url: "https://example.com", contentLength: 42, metadata: { provider: "exa" } } }, {}, theme, { args: { id: "web-123" } });
	const text = component.render(200).join("\n");
	assert.match(text, /Get Web Content \(Session\) Example · 42 chars · full/);
	assert.doesNotMatch(text, /content id web-123/);
	assert.match(text, /source Exa/);
});

test("get_web_content renderer shows shown/full metadata when truncated", () => {
	const tool = createGetWebContentToolDefinition();
	const component = tool.renderResult({ details: { id: "web-long", title: "Long", url: "https://example.com/long", contentLength: 120000, maxCharacters: 50000, truncated: true, metadata: { provider: "http" } } }, {}, theme, { args: { id: "web-long" } });
	const text = component.render(200).join("\n");
	assert.match(text, /Get Web Content \(Session\) Long · 50000\/120000 chars · truncated/);
	assert.match(text, /source HTTP/);
});

test("get_web_content renderer marks search-stored content as a provider-capped excerpt", () => {
	const tool = createGetWebContentToolDefinition();
	const component = tool.renderResult({ details: { id: "web-search", title: "Result", url: "https://example.com/result", contentLength: 1200, maxCharacters: 50000, truncated: false, metadata: { provider: "exa", contentKind: "search-result", providerTextMaxCharacters: 1200 } } }, {}, theme, { args: { id: "web-search" } });
	const text = component.render(200).join("\n");
	assert.match(text, /Get Web Content \(Session\) Result · 1200 chars · stored excerpt/);
	assert.match(text, /provider cap 1200 chars/);
	assert.doesNotMatch(text, /1200 chars · full/);
});

test("web_fetch renderer shows resolved provider without requested auto suffix", () => {
	const tool = createWebFetchToolDefinition({} as any, () => ({}) as any);
	const pending = tool.renderCall({ url: "https://example.com", provider: "auto" }, theme, {}).render(200).join("\n");
	assert.match(pending, /Web Fetch \(Resolving…\)/);
	const complete = tool.renderResult({ details: { provider: "github", stored: [{ id: "web-123", title: "file.zig" }] } }, {}, theme, { args: { provider: "auto", url: "https://example.com" } }).render(200).join("\n");
	assert.match(complete, /Web Fetch \(GitHub\)/);
	assert.doesNotMatch(complete, /GitHub\/Auto/);
	assert.doesNotMatch(complete, /content id web-123/);
});

test("web_fetch returned text and details identify preview truncation and stored full text", () => {
	const result = buildWebFetchToolResult([{
		id: "web-long",
		title: "Long page",
		url: "https://example.com/long",
		content: "x".repeat(DEFAULT_WEB_FETCH_PREVIEW_CHARACTERS + 5),
		createdAt: "2026-01-01T00:00:00.000Z",
	}], "http");
	const block = result.content[0]!;
	assert.equal(block.type, "text");
	const text = block.type === "text" ? block.text : "";
	assert.match(text, /Preview returned \(4000\/4005 chars shown\)/);
	assert.match(text, /Full extracted text is stored under content id\(s\): web-long/);
	assert.match(text, /\[preview 4000\/4005 chars; full text stored\]/);
	assert.match(text, /Use get_web_content with the content id for stored full text/);
	assert.equal(result.details.preview.truncated, true);
	assert.equal(result.details.preview.shownCharacters, 4000);
	assert.equal(result.details.preview.fullCharacters, 4005);
	assert.deepEqual(result.details.preview.items, [{ id: "web-long", shownCharacters: 4000, fullCharacters: 4005, truncated: true }]);
});

test("web_fetch renderer shows concise preview shown/full metadata when preview-truncated", () => {
	const tool = createWebFetchToolDefinition({} as any, () => ({}) as any);
	const result = buildWebFetchToolResult([{
		id: "web-long",
		title: "Long page",
		url: "https://example.com/long",
		content: "x".repeat(DEFAULT_WEB_FETCH_PREVIEW_CHARACTERS + 5),
		createdAt: "2026-01-01T00:00:00.000Z",
	}], "github");
	const rendered = tool.renderResult(result, {}, theme, { args: { provider: "auto", url: "https://example.com/long" } }).render(200).join("\n");
	assert.match(rendered, /Web Fetch \(GitHub\) https:\/\/example\.com\/long · 1 stored · preview 4000\/4005 chars/);
	assert.match(rendered, /Long page · https:\/\/example\.com\/long\s*$/m);
	assert.doesNotMatch(rendered, /Long page · https:\/\/example\.com\/long · preview/);
	assert.doesNotMatch(rendered, /content id web-long/);
	assert.doesNotMatch(rendered, /GitHub\/Auto/);
});

test("web_fetch renders cached at row when GitHub clone metadata is present", () => {
	const tool = createWebFetchToolDefinition({} as any, () => ({}) as any);
	const result = buildWebFetchToolResult([{
		id: "web-gh",
		title: "owner/repo",
		url: "https://github.com/owner/repo",
		content: "# owner/repo",
		createdAt: "2026-01-01T00:00:00.000Z",
		metadata: { provider: "github", extraction: "clone", cachePath: "/home/user/.pi/agent/cache/github/owner__repo" },
	}], "github");
	const rendered = tool.renderResult(result, {}, theme, { args: { provider: "auto", url: "https://github.com/owner/repo" } }).render(200).join("\n");
	assert.match(rendered, /cached at \/home\/user\/\.pi\/agent\/cache\/github\/owner__repo/);
});

test("web_fetch labels HTTP+Jina when extraction fell back through Jina", () => {
	const tool = createWebFetchToolDefinition({} as any, () => ({}) as any);
	const result = buildWebFetchToolResult([{
		id: "web-jina",
		title: "Recovered",
		url: "https://blocked.example",
		content: "recovered body",
		createdAt: "2026-01-01T00:00:00.000Z",
		metadata: { provider: "http", extractionChain: ["html-basic", "jina"] },
	}], "http+jina");
	const rendered = tool.renderResult(result, {}, theme, { args: { provider: "auto", url: "https://blocked.example" } }).render(200).join("\n");
	assert.match(rendered, /Web Fetch \(HTTP\+Jina\)/);
});

test("get_web_content shows source HTTP+Jina when chain includes jina", () => {
	const tool = createGetWebContentToolDefinition();
	const rendered = tool.renderResult({ details: { id: "web-jina", title: "Recovered", url: "https://blocked.example", contentLength: 80, truncated: false, metadata: { provider: "http", extractionChain: ["html-basic", "jina"] } } }, {}, theme, { args: { id: "web-jina" } }).render(200).join("\n");
	assert.match(rendered, /source HTTP\+Jina/);
});

test("web_fetch and get_web_content render URL leaf when provider returns blank title", () => {
	const fetchTool = createWebFetchToolDefinition({} as any, () => ({}) as any);
	const result = buildWebFetchToolResult([{
		id: "web-pdf",
		title: "",
		url: "https://example.com/path/dummy.pdf",
		content: "Dummy PDF file\n",
		createdAt: "2026-01-01T00:00:00.000Z",
	}], "exa");
	const renderedFetch = fetchTool.renderResult(result, {}, theme, { args: { provider: "auto", url: "https://example.com/path/dummy.pdf" } }).render(200).join("\n");
	assert.match(renderedFetch, /dummy\.pdf · https:\/\/example.com\/path\/dummy\.pdf/);
	assert.doesNotMatch(renderedFetch, /content id web-pdf/);

	const contentTool = createGetWebContentToolDefinition();
	const renderedContent = contentTool.renderResult({ details: { id: "web-pdf", title: "", url: "https://example.com/path/dummy.pdf", contentLength: 15, truncated: false, metadata: { provider: "exa" } } }, {}, theme, { args: { id: "web-pdf" } }).render(200).join("\n");
	assert.match(renderedContent, /Get Web Content \(Session\) dummy\.pdf · 15 chars · full/);
});

test("advanced search renderers hide content ids in compact rows", () => {
	const tool = createCodeSearchToolDefinition({} as any, () => ({}) as any);
	const rendered = tool.renderResult({ details: { results: [{ title: "Example", url: "https://example.com", contentId: "web-123" }] } }, {}, theme, { args: { query: "q" } }).render(200).join("\n");
	assert.match(rendered, /Code Search \(Exa\) q · 1 results/);
	assert.match(rendered, /https:\/\/example.com/);
	assert.doesNotMatch(rendered, /content id web-123/);
	assert.doesNotMatch(rendered, /contentId/);
});

test("web_search renderer shows result URLs and hides content ids", () => {
	const tool = createWebSearchToolDefinition({} as any, () => ({}) as any);
	const rendered = tool.renderResult({ details: { provider: "exa", results: [{ title: "Example", url: "https://example.com/path", contentId: "web-123" }] } }, {}, theme, { args: { query: "q" } }).render(200).join("\n");
	assert.match(rendered, /Web Search \(Exa\) q · 1 results/);
	assert.match(rendered, /https:\/\/example.com\/path/);
	assert.doesNotMatch(rendered, /content id web-123/);
});

test("advanced Exa tools render compact provider-labeled summaries", () => {
	const answer = createWebAnswerToolDefinition({} as any, () => ({}) as any);
	const similar = createWebFindSimilarToolDefinition({} as any, () => ({}) as any);
	const answerCall = answer.renderCall({ query: "What is Ghostty?" }, theme, {}).render(200).join("\n");
	const longAnswer = "Ghostty is a fast terminal emulator. ".repeat(30);
	const answerResult = answer.renderResult({ details: { answer: longAnswer, results: [] } }, {}, theme, { args: { query: "What is Ghostty?" } }).render(200).join("\n");
	const expandedAnswerResult = answer.renderResult({ details: { answer: longAnswer, results: [] } }, { expanded: true }, theme, { args: { query: "What is Ghostty?" } }).render(200).join("\n");
	const similarResult = similar.renderResult({ details: { results: [{ title: "Docs", url: "https://ghostty.org/docs" }, { title: "Repo", url: "https://github.com/ghostty-org/ghostty" }] } }, {}, theme, { args: { url: "https://ghostty.org" } }).render(200).join("\n");
	assert.match(answerCall, /Web Answer \(Exa\) What is Ghostty\?/);
	assert.match(answerResult, /Web Answer \(Exa\) What is Ghostty\?/);
	assert.doesNotMatch(answerResult.split("\n")[0] ?? "", /· answer/);
	assert.match(answerResult, /Ghostty is a fast terminal emulator\./);
	assert.doesNotMatch(answerResult, /answer Ghostty/);
	assert.match(answerResult, /ctrl\+o to expand/);
	assert.ok(expandedAnswerResult.length > answerResult.length);
	assert.match(similarResult, /Web Find Similar \(Exa\) https:\/\/ghostty.org · 2 results/);
	assert.match(similarResult, /Docs · https:\/\/ghostty.org\/docs/);
});

function makeStored(count: number, perItemChars: number, urlPrefix = "https://example.com/file"): Array<{ id: string; title: string; url: string; content: string; createdAt: string }> {
	const items = [];
	for (let index = 0; index < count; index++) {
		items.push({
			id: `web-${index.toString(36)}`,
			title: `Item ${index}`,
			url: `${urlPrefix}-${index}.rs`,
			content: "y".repeat(perItemChars),
			createdAt: "2026-01-01T00:00:00.000Z",
		});
	}
	return items;
}

function textOfResult(result: ReturnType<typeof buildWebFetchToolResult>): string {
	const block = result.content[0]!;
	return block.type === "text" ? block.text : "";
}

test("web_fetch caps aggregate content[0].text for small multi-URL batches (2-5 URLs)", () => {
	const stored = makeStored(5, 50000);
	const result = buildWebFetchToolResult(stored, "http");
	const text = textOfResult(result);
	assert.ok(text.length <= MULTI_URL_AGGREGATE_CAP_SMALL_BATCH, `expected <= ${MULTI_URL_AGGREGATE_CAP_SMALL_BATCH} chars, got ${text.length}`);
	const expectedPerUrl = Math.min(DEFAULT_WEB_FETCH_PREVIEW_CHARACTERS, Math.floor(MULTI_URL_AGGREGATE_CAP_SMALL_BATCH / 5));
	assert.equal(result.details.preview.perUrlMaxCharacters, expectedPerUrl);
	assert.ok(expectedPerUrl < DEFAULT_WEB_FETCH_PREVIEW_CHARACTERS, "5 URLs should shrink per-URL preview below the default cap");
	assert.equal(result.details.preview.aggregateCap, MULTI_URL_AGGREGATE_CAP_SMALL_BATCH);
	assert.equal(result.details.preview.manifest, false);
	assert.equal(result.details.preview.explicitMaxCharacters, false);
	assert.match(text, /Fetched 5 URL\(s\)/);
	assert.match(text, /Use get_web_content with the content id for stored full text/);
});

test("web_fetch emits a manifest for large multi-URL batches (6+ URLs) and stays under 25 KB", () => {
	const stored = makeStored(30, 50000);
	const result = buildWebFetchToolResult(stored, "exa");
	const text = textOfResult(result);
	assert.ok(text.length <= MULTI_URL_AGGREGATE_CAP_LARGE_BATCH, `expected <= ${MULTI_URL_AGGREGATE_CAP_LARGE_BATCH} chars, got ${text.length}`);
	assert.equal(result.details.preview.manifest, true);
	assert.equal(result.details.preview.perUrlMaxCharacters, MULTI_URL_LARGE_BATCH_PER_URL_HEAD);
	assert.match(text, /Fetched 30 URLs/);
	assert.match(text, /stored as 30 content ids/);
	assert.match(text, /Per-URL preview heads capped at 512 chars/);
	assert.match(text, /Call get_web_content <id>/);
	// Every content id should appear in the manifest section.
	for (const item of stored) assert.ok(text.includes(item.id), `manifest missing ${item.id}`);
});

test("web_fetch threshold for large-batch manifest matches the constant", () => {
	assert.equal(MULTI_URL_LARGE_BATCH_THRESHOLD, 6);
	const smallBatch = buildWebFetchToolResult(makeStored(MULTI_URL_LARGE_BATCH_THRESHOLD - 1, 8000), "http");
	const largeBatch = buildWebFetchToolResult(makeStored(MULTI_URL_LARGE_BATCH_THRESHOLD, 8000), "http");
	assert.equal(smallBatch.details.preview.manifest, false);
	assert.equal(largeBatch.details.preview.manifest, true);
});

test("web_fetch honors explicit textMaxCharacters and bypasses aggregate cap", () => {
	const stored = makeStored(30, 50000);
	const result = buildWebFetchToolResult(stored, "exa", { maxCharacters: 8000, explicit: true });
	const text = textOfResult(result);
	assert.equal(result.details.preview.manifest, false);
	assert.equal(result.details.preview.perUrlMaxCharacters, 8000);
	assert.equal(result.details.preview.aggregateCap, undefined);
	assert.equal(result.details.preview.explicitMaxCharacters, true);
	assert.ok(text.length > MULTI_URL_AGGREGATE_CAP_LARGE_BATCH, `expected > ${MULTI_URL_AGGREGATE_CAP_LARGE_BATCH} chars when caller opts in, got ${text.length}`);
});

test("web_fetch single-URL behavior is unchanged when textMaxCharacters omitted", () => {
	const stored = makeStored(1, DEFAULT_WEB_FETCH_PREVIEW_CHARACTERS + 5);
	const result = buildWebFetchToolResult(stored, "http");
	const text = textOfResult(result);
	assert.equal(result.details.preview.perUrlMaxCharacters, DEFAULT_WEB_FETCH_PREVIEW_CHARACTERS);
	assert.equal(result.details.preview.manifest, false);
	assert.match(text, /Fetched 1 URL\(s\)/);
	assert.match(text, /Preview returned \(4000\/4005 chars shown\)/);
});

test("web_fetch backwards-compatible positional maxCharacters argument still works", () => {
	const stored = makeStored(1, 4005);
	const result = buildWebFetchToolResult(stored, "http", 4000);
	const text = textOfResult(result);
	assert.match(text, /Preview returned \(4000\/4005 chars shown\)/);
});

test("web_fetch extracts local PDF file paths into session storage", async () => {
	clearMemoryForTests();
	const dir = mkdtempSync(join(tmpdir(), "pi-web-tools-local-pdf-"));
	const path = join(dir, "local.pdf");
	writeFileSync(path, "%PDF-1.4\nBT\n(Local PDF) Tj\nET");
	const appended: any[] = [];
	const tool = createWebFetchToolDefinition({ appendEntry(type: string, data: unknown) { appended.push({ type, data }); } } as any, () => ({ githubClone: { enabled: true }, apiKeys: {}, htmlExtraction: { jinaFallback: false }, pdfOcr: { enabled: false, maxPages: 5, dpi: 150 }, video: { enabled: false }, browserCookies: { preferredBrowser: "auto" } }) as any);
	const result = await tool.execute("call", { filePath: path, provider: "auto" }, undefined, undefined, { cwd: dir } as any);
	assert.equal(result.details.provider, "local");
	const stored = result.details.stored[0]!;
	assert.equal(stored.title, "local.pdf");
	assert.equal(stored.metadata?.provider, "local");
	const block = result.content[0]!;
	assert.equal(block.type, "text");
	assert.match(block.type === "text" ? block.text : "", /Local PDF/);
	assert.equal(appended.length, 1);
});
