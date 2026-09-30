import assert from "node:assert/strict";
import test from "node:test";
import { htmlToMarkdown } from "../src/extract/http.js";
import { assessExtractionQuality, fetchViaJina } from "../src/extract/html.js";
import { urlReads } from "./fixtures.js";

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
	{ name: "never-closed block keeps its content", body: '<p>Keep A</p><div class="sidebar"><div>Inner</div><p>Orphan text</p><p>Keep B</p>', expected: "Keep A\nInner\nOrphan text\nKeep B" },
	{ name: "closing tag inside a nested tag's attribute", body: '<p>Keep A</p><div class="navbox"><div data-x="</div>">inner</div>still nav</div><p>Keep B</p>', expected: "Keep A\nKeep B" },
	{ name: "sequential blocks of different tags", body: '<p>Keep A</p><ul class="breadcrumbs"><li>Home</li></ul><p>Keep B</p><figure class="thumb"><figcaption>cap</figcaption></figure><p>Keep C</p>', expected: "Keep A\nKeep B\nKeep C" },
	{ name: "chrome nested in chrome", body: '<p>Keep A</p><div class="infobox"><table class="navbox"><tr><td>x</td></tr></table>info</div><p>Keep B</p>', expected: "Keep A\nKeep B" },
	{ name: "class that only contains a chrome name", body: '<p>Keep A</p><div class="navbox-like">kept</div><p>Keep B</p>', expected: "Keep A\nkept\nKeep B" },
	{ name: "blocks past the removal cap", body: Array.from({ length: 502 }, (_, i) => `<p>k${i}</p><div class="toc">t${i}</div>`).join(""), expected: Array.from({ length: 502 }, (_, i) => i < 500 ? `k${i}` : `k${i}\nt${i}`).join("\n") },
	{ name: "heading levels and line breaks", body: "<h2>Two</h2><h3>Three</h3><h4>Four</h4><h5>Five</h5><p>a<br>b</p>", expected: "## Two\n### Three\n#### Four\nFive\na\nb" },
	{ name: "link that never closes", body: '<p>Open<a href="https://x.example">never closed</p>', expected: "Open never closed" },
	{ name: "script that never closes", body: "<p>a<script>b</p>", expected: "a b" },
	{ name: "nav that never closes", body: "<p>a<nav>b</p>", expected: "a b" },
	{ name: "< that starts no tag", body: "<p>a <> b</p>", expected: "a <> b" },
	{ name: "second script block after a stray <", body: "<p>a < b</p><script>x()</script><p>mid</p><script>y()</script><p>end</p>", expected: "a mid\nend" },
	{ name: "entities", body: "<p>&amp;lt; &#38; &#x26; x&nbsp;y &amp; &#38;#x41; &amp;#65; &copy;</p>", expected: "< & & x y & A A ©" },
	{ name: "form closing tag inside a script", body: `<p>Before</p><form id=f><input name=q><script>document.body.insertAdjacentHTML("beforeend", '<b>hi</b></form>');</script><button>Go</button></form><p>After</p>`, expected: "Before\nAfter" },
	{ name: "header closing tag inside a script", body: "<p>Before</p><header><script>var tpl = '<div></header>';</script><p>Site</p></header><p>After</p>", expected: "Before\nAfter" },
	{ name: "nav closing tag inside a style", body: `<p>Before</p><nav><style>nav a::after{content:'</nav>'}</style><a href="/x">X</a></nav><p>After</p>`, expected: "Before\nAfter" },
]) {
	test(`HTML to markdown: ${name}`, () => {
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
test("Jina Reader parses title and markdown fields", async (t) => {
	const result = await fetchViaJina("https://x.example", { reads: urlReads(t), fetchImpl: async () => new Response("Title: Demo\nURL Source: https://x.example\n\nMarkdown Content:\n# Demo\n\nbody") });
	assert.deepEqual({ title: result.title, heading: result.markdown.includes("# Demo") }, { title: "Demo", heading: true });
});
