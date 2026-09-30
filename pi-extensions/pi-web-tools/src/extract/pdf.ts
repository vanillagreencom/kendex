import { execFile } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

export interface PdfExtractionResult {
	text: string;
	metadata: Record<string, unknown>;
}

export interface PdfExtractionOptions {
	preferPdftotext?: boolean;
	pdftotextCommand?: string;
}

const execFileAsync = promisify(execFile);

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

async function extractPdfTextWithPdftotextBuffer(buffer: ArrayBuffer | Uint8Array, command = "pdftotext"): Promise<PdfExtractionResult> {
	const dir = await mkdtemp(join(tmpdir(), "pi-web-tools-pdf-"));
	const input = join(dir, "input.pdf");
	try {
		await writeFile(input, Buffer.from(buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer)));
		const { stdout } = await execFileAsync(command, ["-layout", input, "-"], { maxBuffer: 50 * 1024 * 1024 });
		const text = normalizePdfText(String(stdout ?? ""));
		if (!text.trim()) throw new Error("pdftotext returned no text. The PDF may be scanned or image-only.");
		return { text, metadata: { extraction: "pdf-pdftotext", command } };
	} finally {
		await rm(dir, { recursive: true, force: true }).catch(() => undefined);
	}
}

export async function extractPdfTextBest(buffer: ArrayBuffer | Uint8Array, options: PdfExtractionOptions = {}): Promise<PdfExtractionResult> {
	const preferPdftotext = options.preferPdftotext ?? true;
	if (preferPdftotext) {
		try {
			return await extractPdfTextWithPdftotextBuffer(buffer, options.pdftotextCommand);
		} catch (error) {
			const fallback = extractPdfText(buffer);
			return { text: fallback.text, metadata: { ...fallback.metadata, pdftotextError: error instanceof Error ? error.message : String(error) } };
		}
	}
	return extractPdfText(buffer);
}
