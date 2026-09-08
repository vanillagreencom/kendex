import assert from "node:assert/strict";
import test from "node:test";
import { buildWebFetchToolResult, createWebFetchToolDefinition } from "../src/tools/web-fetch.js";

const theme = { fg: (_tone: string, text: string) => text, bold: (text: string) => text };
const tool = createWebFetchToolDefinition({} as any, () => ({}) as any);
test("web_fetch pending provider is unresolved", () => {
	assert.match(tool.renderCall({ url: "https://example.com", provider: "auto" }, theme, {}).render(200).join("\n"), /Web Fetch \(Resolving…\)/);
});
for (const row of [
	{ name: "resolved GitHub", provider: "github", id: "web-123", title: "file.zig", url: "https://example.com", content: "file", metadata: {}, present: [/Web Fetch \(GitHub\)/], absent: [/GitHub\/Auto/, /content id web-123/] },
	{ name: "preview metadata", provider: "github", id: "web-long", title: "Long page", url: "https://example.com/long", content: "x".repeat(4005), metadata: {}, present: [/Web Fetch \(GitHub\) https:\/\/example\.com\/long/, /1 stored · preview 4000\/4005 chars/, /Long page · https:\/\/example\.com\/long\s*$/m], absent: [/Long page · https:\/\/example\.com\/long · preview/, /content id web-long/, /GitHub\/Auto/] },
	{ name: "clone cache path", provider: "github", id: "web-gh", title: "owner/repo", url: "https://github.com/owner/repo", content: "# owner/repo", metadata: { provider: "github", extraction: "clone", cachePath: "/home/user/.pi/agent/cache/github/owner__repo" }, present: [/\/home\/user\/\.pi\/agent\/cache\/github\/owner__repo/], absent: [] },
	{ name: "Jina fallback", provider: "http+jina", id: "web-jina", title: "Recovered", url: "https://blocked.example", content: "recovered body", metadata: { provider: "http", extractionChain: ["html-basic", "jina"] }, present: [/Web Fetch \(HTTP\+Jina\)/], absent: [] },
	{ name: "URL leaf title", provider: "exa", id: "web-pdf", title: "", url: "https://example.com/path/dummy.pdf", content: "Dummy PDF file\n", metadata: {}, present: [/dummy\.pdf · https:\/\/example.com\/path\/dummy\.pdf/], absent: [/content id web-pdf/] },
]) {
	test(`web_fetch result render: ${row.name}`, () => {
		const result = buildWebFetchToolResult([{ id: row.id, title: row.title, url: row.url, content: row.content, metadata: row.metadata, createdAt: "2026-01-01T00:00:00.000Z" }], row.provider);
		const text = tool.renderResult(result, {}, theme, { args: { provider: "auto", url: row.url } }).render(200).join("\n");
		assert.deepEqual({ present: row.present.map((pattern) => pattern.test(text)), absent: row.absent.map((pattern) => pattern.test(text)) }, { present: row.present.map(() => true), absent: row.absent.map(() => false) });
	});
}
