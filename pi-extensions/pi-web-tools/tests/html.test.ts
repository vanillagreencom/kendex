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
for (const { name, body, expected } of [
	{ name: "nested same-name tags", body: '<p>Keep A</p><div class="navbox"><div>inner<div>deeper</div></div>still nav</div><p>Keep B</p>', expected: "Keep A\nKeep B" },
	{ name: "never-closed block keeps its content", body: '<p>Keep A</p><div class="sidebar"><p>Orphan text</p><p>Keep B</p>', expected: "Keep A\nOrphan text\nKeep B" },
	{ name: "closing tag inside a nested tag's attribute", body: '<p>Keep A</p><div class="navbox"><div data-x="</div>">inner</div>still nav</div><p>Keep B</p>', expected: "Keep A\nKeep B" },
	{ name: "sequential blocks of different tags", body: '<p>Keep A</p><ul class="breadcrumbs"><li>Home</li></ul><p>Keep B</p><figure class="thumb"><figcaption>cap</figcaption></figure><p>Keep C</p>', expected: "Keep A\nKeep B\nKeep C" },
	{ name: "chrome nested in chrome", body: '<p>Keep A</p><div class="infobox"><table class="navbox"><tr><td>x</td></tr></table>info</div><p>Keep B</p>', expected: "Keep A\nKeep B" },
	{ name: "class that only contains a chrome name", body: '<p>Keep A</p><div class="navbox-like">kept</div><p>Keep B</p>', expected: "Keep A\nkept\nKeep B" },
	{ name: "blocks past the removal cap", body: Array.from({ length: 502 }, (_, i) => `<p>k${i}</p><div class="toc">t${i}</div>`).join(""), expected: Array.from({ length: 502 }, (_, i) => i < 500 ? `k${i}` : `k${i}\nt${i}`).join("\n") },
]) {
	test(`HTML chrome stripping: ${name}`, () => {
		assert.equal(htmlToMarkdown(`<html><body><main>${body}</main></body></html>`).markdown, expected);
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
