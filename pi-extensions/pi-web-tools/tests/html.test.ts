import assert from "node:assert/strict";
import test from "node:test";
import { htmlToMarkdown } from "../src/extract/http.js";
import { assessExtractionQuality, fetchViaJina } from "../src/extract/html.js";

for (const { name, chrome, absent } of [
	{ name: "script", chrome: "<script>bad()</script>", absent: /bad/ },
	{ name: "navigation", chrome: "<nav><ul><li></li><li>Nav</li></ul></nav>", absent: /Nav/ },
	{ name: "footer", chrome: "<footer>Footer</footer>", absent: /Footer/ },
	{ name: "empty bullet", chrome: "<p>-</p>", absent: /^-$/m },
	{ name: "sidebar", chrome: '<table class="sidebar navbox"><tr><td>Sidebar junk lots of links</td></tr></table>', absent: /Sidebar junk/ },
	{ name: "hatnote", chrome: '<div class="hatnote">For other meanings see other.</div>', absent: /For other meanings/ },
]) {
	test(`HTML conversion: ${name}`, () => {
		const result = htmlToMarkdown(`<html><head><title>T</title><style>x</style></head><body><main><h1>Hello</h1><p>Real body content here. See <a href="https://example.com">Example</a></p>${chrome}</main></body></html>`);
		assert.deepEqual({ title: result.title, heading: result.markdown.includes("# Hello"), link: result.markdown.includes("Example (https://example.com)"), body: result.markdown.includes("Real body content"), chrome: absent.test(result.markdown) }, { title: "T", heading: true, link: true, body: true, chrome: false });
	});
}
for (const { name, markdown, expected } of [
	{ name: "blocked", markdown: "Just a moment. Checking your browser.", expected: { blocked: true, blockedReason: true } },
	{ name: "low content", markdown: "x", expected: { lowContent: true } },
	{ name: "readable", markdown: "Body content. ".repeat(40), expected: { blocked: false, lowContent: false } },
]) {
	test(`HTML quality: ${name}`, () => {
		const result = assessExtractionQuality({ markdown }, 8000);
		const values = { blocked: result.blocked, lowContent: result.lowContent, blockedReason: result.reasons.some((reason) => reason.startsWith("blocked-pattern")) };
		assert.deepEqual(Object.fromEntries(Object.keys(expected).map((key) => [key, values[key as keyof typeof values]])), expected);
	});
}
test("Jina Reader parses title and markdown fields", async () => {
	const result = await fetchViaJina("https://x.example", { fetchImpl: async () => new Response("Title: Demo\nURL Source: https://x.example\n\nMarkdown Content:\n# Demo\n\nbody") });
	assert.deepEqual({ title: result.title, heading: result.markdown.includes("# Demo") }, { title: "Demo", heading: true });
});
