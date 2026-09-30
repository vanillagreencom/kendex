import { readFile, stat } from "node:fs/promises";

/** Most bytes one text body or cached file may hold in memory; a longer one is cut here and reported as truncated. */
export const TEXT_READ_BYTE_LIMIT = 8 * 1024 * 1024;
/** Most bytes one PDF may hold in memory. A PDF cut short cannot be parsed, so a longer one is refused, not cut. */
export const PDF_READ_BYTE_LIMIT = 32 * 1024 * 1024;
/** Most bytes one web_fetch call reads across every URL and file it fetches. */
export const CALL_BYTE_BUDGET = 64 * 1024 * 1024;

/** The bytes one web_fetch call may still read, shared by every fetch and file read the call makes. */
export class ByteBudget {
	readonly total: number;
	#remaining: number;

	constructor(total = CALL_BYTE_BUDGET) {
		this.total = total;
		this.#remaining = total;
	}

	/** The ceiling for the next read: `perRead`, lowered to what the call has left. Throws once nothing is left. */
	limitFor(perRead: number): number {
		if (this.#remaining <= 0) throw new Error(`web_fetch byte budget exhausted (${this.total} bytes read by this call); fetch fewer URLs per call.`);
		return Math.min(perRead, this.#remaining);
	}

	spend(bytes: number): void {
		this.#remaining -= bytes;
	}
}

export interface BoundedRead {
	bytes: Buffer;
	/** The ceiling the read stopped at when the source held more bytes than it; absent when the whole source was read. */
	truncatedAtBytes?: number;
}

/** Streams a response body, keeping at most `limit` bytes and cancelling the stream once more arrive. */
export async function readBodyWithin(response: Response, limit: number): Promise<BoundedRead> {
	if (!response.body) return { bytes: Buffer.alloc(0) };
	const reader = response.body.getReader();
	const chunks: Uint8Array[] = [];
	let total = 0;
	let truncated = false;
	try {
		for (;;) {
			const { done, value } = await reader.read();
			if (done) break;
			const room = limit - total;
			if (value.byteLength > room) {
				chunks.push(value.subarray(0, room));
				total += room;
				truncated = true;
				await reader.cancel();
				break;
			}
			chunks.push(value);
			total += value.byteLength;
		}
	} finally {
		reader.releaseLock();
	}
	return { bytes: Buffer.concat(chunks, total), ...(truncated ? { truncatedAtBytes: limit } : {}) };
}

/** The metadata field a stored item carries when its source was cut at the byte limit; `buildWebFetchToolResult` names the cut in the preview. */
export function truncationMetadata(truncatedAtBytes: number | undefined): { bodyTruncatedAtBytes?: number } {
	return truncatedAtBytes === undefined ? {} : { bodyTruncatedAtBytes: truncatedAtBytes };
}

/** The call's ceiling for reading this response; a response the exhausted budget refuses has its body cancelled, not left open. */
async function limitForResponse(response: Response, budget: ByteBudget, perRead: number): Promise<number> {
	try {
		return budget.limitFor(perRead);
	} catch (error) {
		await response.body?.cancel();
		throw error;
	}
}

export interface BoundedText {
	text: string;
	truncatedAtBytes?: number;
}

/** Reads a text body within the per-read text limit and the call's remaining budget, decoding it as UTF-8 like `Response.text()`. */
export async function readTextWithin(response: Response, budget: ByteBudget): Promise<BoundedText> {
	const read = await readBodyWithin(response, await limitForResponse(response, budget, TEXT_READ_BYTE_LIMIT));
	budget.spend(read.bytes.byteLength);
	return { text: new TextDecoder().decode(read.bytes), ...(read.truncatedAtBytes === undefined ? {} : { truncatedAtBytes: read.truncatedAtBytes }) };
}

/** Reads a PDF body whole within the per-read PDF limit and the call's remaining budget, refusing one that holds more. */
export async function readPdfWithin(response: Response, budget: ByteBudget, url: string): Promise<Buffer> {
	const limit = await limitForResponse(response, budget, PDF_READ_BYTE_LIMIT);
	const declared = Number(response.headers.get("content-length"));
	if (Number.isFinite(declared) && declared > limit) {
		await response.body?.cancel();
		throw pdfTooLarge(url, `${declared} bytes`, limit);
	}
	const read = await readBodyWithin(response, limit);
	budget.spend(read.bytes.byteLength);
	if (read.truncatedAtBytes !== undefined) throw pdfTooLarge(url, `over ${limit} bytes`, limit);
	return read.bytes;
}

/** Reads a local PDF whole, sizing it before the read and refusing one over the per-read PDF limit or the call's remaining budget. */
export async function readLocalPdfWithin(path: string, budget: ByteBudget): Promise<Buffer> {
	const limit = budget.limitFor(PDF_READ_BYTE_LIMIT);
	const { size } = await stat(path);
	if (size > limit) throw pdfTooLarge(path, `${size} bytes`, limit);
	const bytes = await readFile(path);
	budget.spend(bytes.byteLength);
	return bytes;
}

function pdfTooLarge(source: string, size: string, limit: number): Error {
	return new Error(`PDF too large: ${source} is ${size}; the read limit is ${limit} bytes.`);
}
