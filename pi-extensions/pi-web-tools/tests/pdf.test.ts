import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { extractPdfText, fetchLocalPdfText } from "../src/extract/pdf.js";
import { tempDir } from "./fixtures.js";

for (const { name, operators, expected } of [
	{ name: "Tj", operators: "(Hello PDF) Tj", expected: "Hello PDF" },
	{ name: "TJ", operators: "[( chunk) 20 ( two)] TJ", expected: "chunk two" },
]) {
	test(`PDF text operator: ${name}`, () => {
		assert.equal(extractPdfText(`%PDF-1.4\nBT\n${operators}\nET`).text.trim(), expected);
	});
}
test("local PDF uses the basic parser when pdftotext is disabled", async (t) => {
	const path = join(tempDir(t), "sample.pdf");
	writeFileSync(path, "%PDF-1.4\nBT\n(Local PDF) Tj\nET");
	const result = await fetchLocalPdfText(path, { preferPdftotext: false });
	assert.deepEqual({ text: result.text.trim(), extraction: result.metadata.extraction }, { text: "Local PDF", extraction: "pdf-basic" });
});
