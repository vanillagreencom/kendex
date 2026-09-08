import assert from "node:assert/strict";
import test from "node:test";
import { looksLikeScannedPdf } from "../src/extract/pdf-pages.js";

for (const { name, text, bytes, scanned } of [
	{ name: "empty extraction", text: "", bytes: 5000, scanned: true },
	{ name: "whitespace extraction", text: "   ", bytes: 5000, scanned: true },
	{ name: "low density", text: "page 1", bytes: 200_000, scanned: true },
	{ name: "regular text layer", text: "lorem ipsum ".repeat(40), bytes: 200_000, scanned: false },
	{ name: "small PDF with text", text: "hi", bytes: 1000, scanned: false },
]) {
	test(`looksLikeScannedPdf: ${name}`, () => {
		assert.equal(looksLikeScannedPdf(text, bytes), scanned);
	});
}
