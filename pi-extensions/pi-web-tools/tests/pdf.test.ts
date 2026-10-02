import assert from "node:assert/strict";
import { chmodSync, existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { readLocalPdfWithin } from "../src/extract/byte-budget.js";
import { extractPdfText, extractPdfTextBest } from "../src/extract/pdf.js";
import { piExec, processAlive, sleepingHelper, tempDir, urlReads } from "./fixtures.js";

for (const { name, operators, expected } of [
	{ name: "Tj", operators: "(Hello PDF) Tj", expected: "Hello PDF" },
	{ name: "TJ", operators: "[( chunk) 20 ( two)] TJ", expected: "chunk two" },
]) {
	test(`PDF text operator: ${name}`, () => {
		assert.equal(extractPdfText(`%PDF-1.4\nBT\n${operators}\nET`).text.trim(), expected);
	});
}
test("a read local PDF uses the basic parser when pdftotext is disabled", async (t) => {
	const path = join(tempDir(t), "sample.pdf");
	writeFileSync(path, "%PDF-1.4\nBT\n(Local PDF) Tj\nET");
	const result = await extractPdfTextBest(await readLocalPdfWithin(path, urlReads(t)), { pi: piExec, preferPdftotext: false });
	assert.deepEqual({ text: result.text.trim(), extraction: result.metadata.extraction }, { text: "Local PDF", extraction: "pdf-basic" });
});

test("a hung pdftotext is killed at its deadline, its directory removed, and the basic parser answers", { timeout: 10_000 }, async (t) => {
	const helper = sleepingHelper(tempDir(t), "pdftotext", 30);
	const started = performance.now();
	const result = await extractPdfTextBest(Buffer.from("%PDF-1.4\nBT\n(Fallback text) Tj\nET"), { pi: piExec, pdftotextCommand: helper.path, timeoutMs: 300 });
	const elapsed = performance.now() - started;
	assert.deepEqual({ text: result.text, extraction: result.metadata.extraction, withinBound: elapsed < 3_000, helperAlive: processAlive(helper.pid()), inputKept: existsSync(helper.args()[1]!) }, { text: "Fallback text", extraction: "pdf-basic", withinBound: true, helperAlive: false, inputKept: false });
});

test("a cancelled pdftotext run rejects with the cancellation and kills the helper", { timeout: 10_000 }, async (t) => {
	const helper = sleepingHelper(tempDir(t), "pdftotext", 30);
	const controller = new AbortController();
	const abort = new DOMException("cancelled", "AbortError");
	const pending = extractPdfTextBest(Buffer.from("%PDF-1.4\nBT\n(Fallback text) Tj\nET"), { pi: piExec, pdftotextCommand: helper.path, signal: controller.signal }).then(() => undefined, (caught: unknown) => caught);
	while (!existsSync(`${helper.path}.args`)) await new Promise((resolve) => setTimeout(resolve, 10)); // the helper has started
	controller.abort(abort);
	assert.deepEqual({ sameError: await pending === abort, helperAlive: processAlive(helper.pid()) }, { sameError: true, helperAlive: false });
});

// A pdftotext that dies by a signal Pi did not send (SIGKILL, as an OOM kill does, which writes no core file) after writing
// part of its text, and one whose text runs past the output limit (a sparse file, so no 51 MiB is written).
const OVER_LIMIT_BYTES = 51 * 1024 * 1024;
for (const row of [
	{ name: "a pdftotext killed by a signal after writing part of its text", script: `printf partial > "$3"\nkill -KILL $$`, error: (command: string) => `${command} exited 137` },
	{ name: "a pdftotext output over its byte limit", script: `dd if=/dev/null of="$3" bs=1048576 seek=51 2>/dev/null`, error: () => `pdftotext wrote ${OVER_LIMIT_BYTES} bytes` },
]) {
	test(`${row.name} falls back to the basic parser and names the failure`, { timeout: 10_000 }, async (t) => {
		const command = join(tempDir(t), "pdftotext");
		writeFileSync(command, `#!/bin/sh\n${row.script}\n`);
		chmodSync(command, 0o755);
		const result = await extractPdfTextBest(Buffer.from("%PDF-1.4\nBT\n(Fallback text) Tj\nET"), { pi: piExec, pdftotextCommand: command });
		const pdftotextError = String(result.metadata.pdftotextError);
		assert.deepEqual({ text: result.text, extraction: result.metadata.extraction, namesFailure: pdftotextError.startsWith(row.error(command)) }, { text: "Fallback text", extraction: "pdf-basic", namesFailure: true });
	});
}
