import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DEFAULT_DEADLINE_MS, type PiExec, runHelper, withDeadline } from "../utils/deadline.js";

export interface PdfExtractionResult {
	text: string;
	metadata: Record<string, unknown>;
}

export interface PdfExtractionOptions {
	/** Runs pdftotext. */
	pi: PiExec;
	signal?: AbortSignal;
	preferPdftotext?: boolean;
	pdftotextCommand?: string;
	/** Deadline of the pdftotext run; DEFAULT_DEADLINE_MS when absent. */
	timeoutMs?: number;
}

/** Most bytes of text pdftotext may write; a longer output is refused and the basic extraction runs instead. */
const PDFTOTEXT_OUTPUT_BYTE_LIMIT = 50 * 1024 * 1024;

function decodePdfLiteral(input: string): string {
	return input
		.replace(/\\n/g, "\n")
		.replace(/\\r/g, "\r")
		.replace(/\\t/g, "\t")
		.replace(/\\\(/g, "(")
		.replace(/\\\)/g, ")")
		.replace(/\\\\/g, "\\");
}

export function extractPdfText(buffer: ArrayBuffer | Uint8Array | string): PdfExtractionResult {
	const binary = typeof buffer === "string" ? buffer : Buffer.from(buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer)).toString("latin1");
	const chunks: string[] = [];
	for (const match of binary.matchAll(/\(([^()]{2,})\)\s*T[jJ]/g)) chunks.push(decodePdfLiteral(match[1] ?? ""));
	for (const match of binary.matchAll(/\[([^\]]+)\]\s*TJ/g)) {
		const segment = match[1] ?? "";
		const parts = [...segment.matchAll(/\(([^()]*)\)/g)].map((item) => decodePdfLiteral(item[1] ?? ""));
		if (parts.length) chunks.push(parts.join(""));
	}
	const text = chunks.join("\n").replace(/[ \t]+/g, " ").replace(/\n{3,}/g, "\n\n").trim();
	if (!text) throw new Error("PDF text extraction found no embedded text. Use OCR or a provider fallback for scanned PDFs.");
	return { text, metadata: { extraction: "pdf-basic", chunks: chunks.length } };
}

function normalizePdfText(text: string): string {
	return text.replace(/[ \t]+\n/g, "\n").replace(/\n{4,}/g, "\n\n\n").trimEnd();
}

async function extractPdfTextWithPdftotextBuffer(buffer: ArrayBuffer | Uint8Array, options: PdfExtractionOptions): Promise<PdfExtractionResult> {
	const command = options.pdftotextCommand ?? "pdftotext";
	const dir = await mkdtemp(join(tmpdir(), "pi-web-tools-pdf-"));
	const input = join(dir, "input.pdf");
	const output = join(dir, "output.txt");
	try {
		await writeFile(input, Buffer.from(buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer)));
		// The text goes to a file, sized before it is read: Pi's exec holds stdout in memory with no limit.
		await withDeadline(options.signal, options.timeoutMs ?? DEFAULT_DEADLINE_MS, command, (signal) => runHelper(options.pi, command, ["-layout", input, output], signal));
		const { size } = await stat(output);
		if (size > PDFTOTEXT_OUTPUT_BYTE_LIMIT) throw new Error(`pdftotext wrote ${size} bytes, over its ${PDFTOTEXT_OUTPUT_BYTE_LIMIT}-byte limit.`);
		const text = normalizePdfText(await readFile(output, "utf8"));
		if (!text.trim()) throw new Error("pdftotext returned no text. The PDF may be scanned or image-only.");
		return { text, metadata: { extraction: "pdf-pdftotext", command } };
	} finally {
		await rm(dir, { recursive: true, force: true }).catch(() => undefined);
	}
}

/** The PDF's text from pdftotext, or from the basic extraction when pdftotext fails or passes its deadline; the failure is
 * named in `pdftotextError`. A cancellation through `signal` rejects instead. */
export async function extractPdfTextBest(buffer: ArrayBuffer | Uint8Array, options: PdfExtractionOptions): Promise<PdfExtractionResult> {
	const preferPdftotext = options.preferPdftotext ?? true;
	if (preferPdftotext) {
		try {
			return await extractPdfTextWithPdftotextBuffer(buffer, options);
		} catch (error) {
			if (options.signal?.aborted) throw error;
			const fallback = extractPdfText(buffer);
			return { text: fallback.text, metadata: { ...fallback.metadata, pdftotextError: error instanceof Error ? error.message : String(error) } };
		}
	}
	return extractPdfText(buffer);
}
