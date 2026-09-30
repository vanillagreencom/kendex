import { open, stat } from "node:fs/promises";

/** Most bytes one text body or cached file may hold in memory; a longer one is cut here and reported as truncated. */
export const TEXT_READ_BYTE_LIMIT = 8 * 1024 * 1024;
/** Most bytes one PDF may hold in memory. A PDF cut short cannot be parsed, so a longer one is refused, not cut. */
export const PDF_READ_BYTE_LIMIT = 32 * 1024 * 1024;
/** Most bytes one web_fetch call reads across every URL and file it fetches. */
export const CALL_BYTE_BUDGET = 64 * 1024 * 1024;
/** Most body and file bytes all web_fetch calls in this process hold at once. A read waits here for room and is never cut by it,
 * so it stays at or above PDF_READ_BYTE_LIMIT: one read always fits once the reads ahead of it release. */
export const IN_FLIGHT_BYTE_BUDGET = 64 * 1024 * 1024;

/** The ceiling that cut a read short: the per-read limit, or what the web_fetch call had left of CALL_BYTE_BUDGET. */
export type ReadCeiling = "read-limit" | "call-budget";

/** Raised for a read once its web_fetch call has read CALL_BYTE_BUDGET; the call's other URLs keep what they stored. */
export class ByteBudgetExhausted extends Error {
	constructor(total: number) {
		super(`web_fetch byte budget exhausted (${total} bytes read by this call); fetch fewer URLs per call.`);
		this.name = "ByteBudgetExhausted";
	}
}

/** The bytes every web_fetch call in the process holds. A reservation waits in FIFO order until the bytes ahead of it are
 * released, so a large read is never starved by smaller ones behind it. */
class InFlightBytes {
	readonly #total: number;
	#free: number;
	readonly #waiting: Array<{ bytes: number; grant: () => void }> = [];

	constructor(total: number) {
		this.#total = total;
		this.#free = total;
	}

	/** Resolves once `bytes` are reserved; rejects with the signal's reason when it aborts first, having reserved nothing. */
	reserve(bytes: number, signal: AbortSignal | undefined): Promise<void> {
		if (bytes > this.#total) throw new Error(`in-flight reservation of ${bytes} bytes exceeds IN_FLIGHT_BYTE_BUDGET (${this.#total}); a per-read limit must stay within it.`);
		signal?.throwIfAborted();
		if (this.#waiting.length === 0 && bytes <= this.#free) {
			this.#free -= bytes;
			return Promise.resolve();
		}
		return new Promise<void>((resolve, reject) => {
			const onAbort = () => {
				this.#waiting.splice(this.#waiting.indexOf(waiter), 1);
				reject(signal!.reason);
				this.#grant();
			};
			const waiter = { bytes, grant: () => { signal?.removeEventListener("abort", onAbort); resolve(); } };
			signal?.addEventListener("abort", onAbort, { once: true });
			this.#waiting.push(waiter);
		});
	}

	release(bytes: number): void {
		this.#free += bytes;
		this.#grant();
	}

	#grant(): void {
		while (this.#waiting.length && this.#waiting[0]!.bytes <= this.#free) {
			const waiter = this.#waiting.shift()!;
			this.#free -= waiter.bytes;
			waiter.grant();
		}
	}
}

const inFlight = new InFlightBytes(IN_FLIGHT_BYTE_BUDGET);

/** The bytes one web_fetch call may still read, shared by every URL it fetches. */
export class ByteBudget {
	readonly total: number;
	#remaining: number;

	constructor(total = CALL_BYTE_BUDGET) {
		this.total = total;
		this.#remaining = total;
	}

	/** Throws ByteBudgetExhausted once the call has nothing left; web_fetch checks it before a URL's network or git work. */
	assertRemaining(): void {
		if (this.#remaining <= 0) throw new ByteBudgetExhausted(this.total);
	}

	/** The reads of one URL. They hold their bytes in the process-wide in-flight budget until `release`, which the caller
	 * runs when the URL's processing ends. */
	openUrl(signal?: AbortSignal): UrlReads {
		return new UrlReads(this, signal);
	}

	/** The ceiling for one read: `perRead`, lowered to what the call has left, and which of the two it is. */
	ceiling(perRead: number): { limit: number; by: ReadCeiling } {
		this.assertRemaining();
		return this.#remaining < perRead ? { limit: this.#remaining, by: "call-budget" } : { limit: perRead, by: "read-limit" };
	}

	spend(bytes: number): void {
		this.#remaining -= bytes;
	}
}

export interface BoundedRead {
	bytes: Buffer;
	/** Present when the source held more bytes than the read's ceiling: the bytes kept and the ceiling that cut them. */
	cut?: { atBytes: number; by: ReadCeiling };
}

/** One URL's reads. Each read reserves its ceiling in the in-flight budget before it starts, charges the call for the bytes
 * it read, and keeps those bytes reserved until `release`. A read waits only while this URL holds nothing, because it
 * releases the URL's earlier reads first, so waiting reads cannot deadlock each other. */
export class UrlReads {
	readonly #call: ByteBudget;
	readonly #signal: AbortSignal | undefined;
	#held = 0;

	constructor(call: ByteBudget, signal: AbortSignal | undefined) {
		this.#call = call;
		this.#signal = signal;
	}

	/** The ceiling the next read of `perRead` would get; throws ByteBudgetExhausted once the call has nothing left. */
	ceiling(perRead: number): { limit: number; by: ReadCeiling } {
		return this.#call.ceiling(perRead);
	}

	/** Streams a response body within the ceiling, cancelling the stream once more bytes arrive. */
	async readBody(response: Response, perRead: number): Promise<BoundedRead> {
		const ceiling = await this.#reserve(perRead, undefined).catch(async (error: unknown) => {
			await response.body?.cancel().catch(() => undefined);
			throw error;
		});
		const read = await this.#charged(ceiling.reserved, () => streamWithin(response, ceiling.limit));
		return read.truncated ? { bytes: read.bytes, cut: { atBytes: ceiling.limit, by: ceiling.by } } : { bytes: read.bytes };
	}

	/** Reads a file within the ceiling, sizing it through its open handle before any byte is read. */
	async readFile(path: string, perRead: number): Promise<BoundedRead & { size: number }> {
		const handle = await open(path, "r");
		try {
			const { size } = await handle.stat();
			const ceiling = await this.#reserve(perRead, size);
			const read = await this.#charged(ceiling.reserved, async () => {
				const buffer = Buffer.alloc(ceiling.reserved);
				const { bytesRead } = await handle.read(buffer, 0, ceiling.reserved, 0);
				return { bytes: buffer.subarray(0, bytesRead), truncated: false };
			});
			return size > ceiling.limit ? { bytes: read.bytes, size, cut: { atBytes: ceiling.limit, by: ceiling.by } } : { bytes: read.bytes, size };
		} finally {
			await handle.close();
		}
	}

	/** Returns every byte this URL holds to the in-flight budget. */
	release(): void {
		inFlight.release(this.#held);
		this.#held = 0;
	}

	/** Takes the read's ceiling and reserves the bytes it may hold (`size` when the source's size is known and smaller). */
	async #reserve(perRead: number, size: number | undefined): Promise<{ limit: number; by: ReadCeiling; reserved: number }> {
		const ceiling = this.#call.ceiling(perRead);
		const reserved = size === undefined ? ceiling.limit : Math.min(size, ceiling.limit);
		this.release();
		await inFlight.reserve(reserved, this.#signal);
		this.#held = reserved;
		return { ...ceiling, reserved };
	}

	/** Runs a read holding `reserved` bytes, charges the call for what it read, and keeps only those bytes reserved. */
	async #charged(reserved: number, read: () => Promise<{ bytes: Buffer; truncated: boolean }>): Promise<{ bytes: Buffer; truncated: boolean }> {
		try {
			const result = await read();
			this.#call.spend(result.bytes.byteLength);
			inFlight.release(reserved - result.bytes.byteLength);
			this.#held = result.bytes.byteLength;
			return result;
		} catch (error) {
			this.release();
			throw error;
		}
	}
}

async function streamWithin(response: Response, limit: number): Promise<{ bytes: Buffer; truncated: boolean }> {
	if (!response.body) return { bytes: Buffer.alloc(0), truncated: false };
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
	return { bytes: Buffer.concat(chunks, total), truncated };
}

/** The metadata fields a stored item carries when its source was cut; `buildWebFetchToolResult` names the cut and its ceiling in
 * the preview, and `get_web_content` labels the item as cut. */
export function truncationMetadata(cut: BoundedRead["cut"]): { bodyTruncatedAtBytes?: number; bodyTruncatedBy?: ReadCeiling } {
	return cut === undefined ? {} : { bodyTruncatedAtBytes: cut.atBytes, bodyTruncatedBy: cut.by };
}

export interface BoundedText {
	text: string;
	cut?: BoundedRead["cut"];
}

/** Reads a text body within the per-read text limit and the call's remaining budget, decoding it as UTF-8 like `Response.text()`. */
export async function readTextWithin(response: Response, reads: UrlReads): Promise<BoundedText> {
	const read = await reads.readBody(response, TEXT_READ_BYTE_LIMIT);
	return { text: new TextDecoder().decode(read.bytes), ...(read.cut ? { cut: read.cut } : {}) };
}

/** Reads a PDF body whole within the per-read PDF limit and the call's remaining budget, refusing one that holds more, before
 * any byte is read when its declared length already exceeds the ceiling. */
export async function readPdfWithin(response: Response, reads: UrlReads, url: string): Promise<Buffer> {
	const { limit } = reads.ceiling(PDF_READ_BYTE_LIMIT);
	const declared = Number(response.headers.get("content-length"));
	if (response.headers.has("content-length") && Number.isFinite(declared) && declared > limit) {
		await response.body?.cancel();
		throw pdfTooLarge(url, `${declared} bytes`, limit);
	}
	const read = await reads.readBody(response, PDF_READ_BYTE_LIMIT);
	if (read.cut) throw pdfTooLarge(url, `over ${read.cut.atBytes} bytes`, read.cut.atBytes);
	return read.bytes;
}

/** Reads a local PDF whole within the per-read PDF limit and the call's remaining budget, refusing one over the ceiling
 * before any byte is read. */
export async function readLocalPdfWithin(path: string, reads: UrlReads): Promise<Buffer> {
	const { limit } = reads.ceiling(PDF_READ_BYTE_LIMIT);
	const { size } = await stat(path);
	if (size > limit) throw pdfTooLarge(path, `${size} bytes`, limit);
	const read = await reads.readFile(path, PDF_READ_BYTE_LIMIT);
	if (read.cut) throw pdfTooLarge(path, `${read.size} bytes`, read.cut.atBytes);
	return read.bytes;
}

function pdfTooLarge(source: string, size: string, limit: number): Error {
	return new Error(`PDF too large: ${source} is ${size}; the read limit is ${limit} bytes.`);
}
