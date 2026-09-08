import assert from "node:assert/strict";
import test from "node:test";
import { buildWebFetchToolResult, DEFAULT_WEB_FETCH_PREVIEW_CHARACTERS, MULTI_URL_AGGREGATE_CAP_LARGE_BATCH, MULTI_URL_AGGREGATE_CAP_SMALL_BATCH, MULTI_URL_LARGE_BATCH_PER_URL_HEAD, MULTI_URL_LARGE_BATCH_THRESHOLD } from "../src/tools/web-fetch.js";

for (const row of [
	{ name: "single URL preview", count: 1, size: 4005, prefix: "https://example.com/file", explicit: false, expected: { perUrlMaxCharacters: DEFAULT_WEB_FETCH_PREVIEW_CHARACTERS, manifest: false, aggregateCap: undefined, explicitMaxCharacters: false, overLargeCap: false } },
	{ name: "small batch", count: 5, size: 50000, prefix: "https://example.com/file", explicit: false, expected: { perUrlMaxCharacters: 3276, manifest: false, aggregateCap: MULTI_URL_AGGREGATE_CAP_SMALL_BATCH, explicitMaxCharacters: false, overLargeCap: false } },
	{ name: "below manifest threshold", count: 5, size: 8000, prefix: "https://example.com/file", explicit: false, expected: { perUrlMaxCharacters: 3276, manifest: false, aggregateCap: MULTI_URL_AGGREGATE_CAP_SMALL_BATCH, explicitMaxCharacters: false, overLargeCap: false } },
	{ name: "at manifest threshold", count: 6, size: 8000, prefix: "https://example.com/file", explicit: false, expected: { perUrlMaxCharacters: MULTI_URL_LARGE_BATCH_PER_URL_HEAD, manifest: true, aggregateCap: MULTI_URL_AGGREGATE_CAP_LARGE_BATCH, explicitMaxCharacters: false, overLargeCap: false } },
	{ name: "large manifest", count: 30, size: 50000, prefix: "https://example.com/file", explicit: false, expected: { perUrlMaxCharacters: MULTI_URL_LARGE_BATCH_PER_URL_HEAD, manifest: true, aggregateCap: MULTI_URL_AGGREGATE_CAP_LARGE_BATCH, explicitMaxCharacters: false, overLargeCap: false } },
	{ name: "id-only manifest", count: 50, size: 8000, prefix: `https://example.com/${"a".repeat(900)}/path`, explicit: false, expected: { perUrlMaxCharacters: MULTI_URL_LARGE_BATCH_PER_URL_HEAD, manifest: true, aggregateCap: MULTI_URL_AGGREGATE_CAP_LARGE_BATCH, explicitMaxCharacters: false, overLargeCap: false } },
	{ name: "explicit cap bypass", count: 30, size: 50000, prefix: "https://example.com/file", explicit: true, expected: { perUrlMaxCharacters: 8000, manifest: false, aggregateCap: undefined, explicitMaxCharacters: true, overLargeCap: true } },
]) {
	test(`web_fetch result: ${row.name}`, () => {
		const stored = Array.from({ length: row.count }, (_, index) => ({ id: `web-${index.toString(36)}`, title: `Item ${index}`, url: `${row.prefix}-${index}.rs`, content: "y".repeat(row.size), createdAt: "2026-01-01T00:00:00.000Z" }));
		const result = buildWebFetchToolResult(stored, "http", row.explicit ? { maxCharacters: 8000, explicit: true } : undefined);
		const block = result.content[0]!;
		const text = block.type === "text" ? block.text : "";
		const preview = result.details.preview;
		assert.deepEqual({
			threshold: MULTI_URL_LARGE_BATCH_THRESHOLD,
			type: block.type,
			perUrlMaxCharacters: preview.perUrlMaxCharacters,
			manifest: preview.manifest,
			aggregateCap: preview.aggregateCap,
			explicitMaxCharacters: preview.explicitMaxCharacters,
			overLargeCap: text.length > MULTI_URL_AGGREGATE_CAP_LARGE_BATCH,
			bounded: preview.aggregateCap === undefined || text.length <= preview.aggregateCap,
			ids: stored.map((item) => new RegExp(`\\b${item.id}\\b`).test(text)),
			guidance: text.includes("get_web_content"),
			idOnly: text.includes("id-only"),
			count: text.includes(`${row.count} URL`),
			printedHeadCap: !row.expected.manifest || row.name === "id-only manifest" || text.includes("512 chars"),
		}, { threshold: 6, type: "text", ...row.expected, bounded: true, ids: stored.map(() => true), guidance: true, idOnly: row.name === "id-only manifest", count: true, printedHeadCap: true });
	});
}

test("web_fetch preview retains complete per-item metadata", () => {
	const result = buildWebFetchToolResult([{ id: "web-long", title: "Long page", url: "https://example.com/long", content: "x".repeat(4005), createdAt: "2026-01-01T00:00:00.000Z" }], "http");
	const block = result.content[0]!;
	const text = block.type === "text" ? block.text : "";
	assert.deepEqual({ type: block.type, ratio: text.includes("4000/4005"), id: text.includes("web-long"), guidance: text.includes("get_web_content"), truncated: result.details.preview.truncated, shown: result.details.preview.shownCharacters, full: result.details.preview.fullCharacters, items: result.details.preview.items }, { type: "text", ratio: true, id: true, guidance: true, truncated: true, shown: 4000, full: 4005, items: [{ id: "web-long", shownCharacters: 4000, fullCharacters: 4005, truncated: true }] });
});
