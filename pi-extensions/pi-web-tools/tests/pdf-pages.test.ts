import assert from "node:assert/strict";
import { chmodSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { looksLikeScannedPdf, MAX_PAGE_PIXELS, pageScaleArgs, rasterizePdfPages } from "../src/extract/pdf-pages.js";
import { tempDir } from "./fixtures.js";

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

const LETTER_AREA = 612 * 792;
for (const { name, dpi, area, expected } of [
	{ name: "letter page within the budget keeps the requested DPI", dpi: 150, area: LETTER_AREA, expected: ["-r", "150"] },
	{ name: "letter page over the budget lowers the DPI", dpi: 300, area: LETTER_AREA, expected: ["-r", "206"] },
	{ name: "unknown page size renders into the pixel box", dpi: 150, area: undefined, expected: ["-scale-to", "2000"] },
	{ name: "page too large for 1 DPI renders into the pixel box", dpi: 150, area: 72 * 72 * MAX_PAGE_PIXELS * 4, expected: ["-scale-to", "2000"] },
]) {
	test(`pageScaleArgs: ${name}`, () => {
		assert.deepEqual(pageScaleArgs(dpi, area), expected);
	});
}

for (const { name, info, expected } of [
	{ name: "largest listed page sets the DPI", info: "Pages:           3\nPage    1 size:  612 x 792 pts (letter)\nPage    2 size:  1224 x 1584 pts\n", expected: { infoArgs: ["-f", "1", "-l", "2"], args: ["-png", "-cropbox", "-r", "103", "-f", "1", "-l", "2"], pageCount: 3, images: 1 } },
	{ name: "no page size falls back to the pixel box", info: "Pages:           1\n", expected: { infoArgs: ["-f", "1", "-l", "2"], args: ["-png", "-cropbox", "-scale-to", "2000", "-f", "1", "-l", "1"], pageCount: 1, images: 1 } },
]) {
	test(`rasterizePdfPages: ${name}`, async (t) => {
		const root = tempDir(t);
		const pdfinfo = join(root, "pdfinfo");
		const pdftoppm = join(root, "pdftoppm");
		const argsFile = join(root, "args");
		const infoArgsFile = join(root, "pdfinfo.args");
		writeFileSync(join(root, "pdfinfo.out"), info);
		writeFileSync(pdfinfo, `#!/bin/sh\nprintf '%s\\n' "$@" > '${infoArgsFile}'\ncat -- '${join(root, "pdfinfo.out")}'\n`);
		writeFileSync(pdftoppm, `#!/bin/sh\nprintf '%s\\n' "$@" > '${argsFile}'\nfor last; do :; done\nprintf png > "$last-1.png"\n`);
		chmodSync(pdfinfo, 0o755);
		chmodSync(pdftoppm, 0o755);
		const result = await rasterizePdfPages(new Uint8Array([37, 80, 68, 70]), { maxPages: 2, dpi: 150, pdfinfoCommand: pdfinfo, pdftoppmCommand: pdftoppm });
		const args = readFileSync(argsFile, "utf8").trim().split("\n").slice(0, -2);
		const infoArgs = readFileSync(infoArgsFile, "utf8").trim().split("\n").slice(0, -1);
		assert.deepEqual({ infoArgs, args, pageCount: result.pageCount, images: result.images.length }, expected);
	});
}
