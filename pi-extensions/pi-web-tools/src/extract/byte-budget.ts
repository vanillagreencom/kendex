import { open, stat } from "node:fs/promises";

/** Most bytes one text body or cached file may hold in memory; a longer one is cut here and reported as truncated. */
export const TEXT_READ_BYTE_LIMIT = 8 * 1024 * 1024;
/** Most bytes one PDF may hold in memory. A PDF cut short cannot be parsed, so a longer one is refused, not cut. */
export const PDF_READ_BYTE_LIMIT = 32 * 1024 * 1024;
/** Most bytes one web_fetch call reads through UrlReads across its URLs. */
export const CALL_BYTE_BUDGET = 64 * 1024 * 1024;
/** Most bytes the reads of all web_fetch calls in this process reserve at once. A read waits here for room and is never cut by it,
 * so it stays at or above PDF_READ_BYTE_LIMIT: one read always fits once the reads ahead of it release. */
export const IN_FLIGHT_BYTE_BUDGET = 64 * 1024 * 1024;
/** Longest a read waits for room in IN_FLIGHT_BYTE_BUDGET before its URL fails; slow reads of other calls, and the bytes their
 * URLs hold while processed, can hold the room. */
export const IN_FLIGHT_WAIT_TIMEOUT_MS = 60_000;
/** Longest a body read waits for its next chunk before its URL fails. A server that stops sending with the connection open would
 * otherwise hold the read's in-flight room for good; kept under IN_FLIGHT_WAIT_TIMEOUT_MS, so a read waiting behind a stalled
 * one gets the room before its own wait ends. */
export const BODY_IDLE_TIMEOUT_MS = 30_000;

/** The ceiling that cut a read short: the per-read limit, what the web_fetch call had left of CALL_BYTE_BUDGET, or the
 * content-length the response declared. */
export type ReadCeiling = "read-limit" | "call-budget" | "declared-length";

/** Raised for a read once its web_fetch call has read CALL_BYTE_BUDGET, or once it waited IN_FLIGHT_WAIT_TIMEOUT_MS for room in
 * IN_FLIGHT_BYTE_BUDGET; the read's URL fails and the call's other URLs keep what they stored. */
export class ByteBudgetExhausted extends Error {
	readonly budget: "call" | "in-flight";

	constructor(budget: "call" | "in-flight", total: number) {
		super(budgetMessage(budget, total));
		this.name = "ByteBudgetExhausted";
		this.budget = budget;
	}
}

function budgetMessage(budget: "call" | "in-flight", total: number): string {
	switch (budget) {
		case "call": return `web_fetch byte budget exhausted (${total} bytes read by this call); fetch fewer URLs per call.`;
		case "in-flight": return `web_fetch in-flight byte budget full: this read waited ${IN_FLIGHT_WAIT_TIMEOUT_MS / 1000} s for room in the ${total} bytes all web_fetch calls share; retry once other fetches finish.`;
		default: {
			const unknown: never = budget;
			throw new Error(`unknown byte budget: ${String(unknown)}`);
		}
	}
}

/** The bytes every web_fetch call in the process reserves. A reservation waits in FIFO order until the bytes ahead of it are
 * released, so a large read is never starved by smaller ones behind it. */
class InFlightBytes {
	readonly #total: number;
	#free: number;
	readonly #waiting: Array<{ bytes: number; grant: () => void }> = [];

	constructor(total: number) {
		this.#total = total;
		this.#free = total;
	}

	/** Resolves once `bytes` are reserved. Rejects having reserved nothing when the signal aborts first, with its reason, or
	 * when IN_FLIGHT_WAIT_TIMEOUT_MS passes first, with ByteBudgetExhausted. */
	reserve(bytes: number, signal: AbortSignal | undefined): Promise<void> {
		if (bytes > this.#total) throw new Error(`in-flight reservation of ${bytes} bytes exceeds IN_FLIGHT_BYTE_BUDGET (${this.#total}); a per-read limit must stay within it.`);
		signal?.throwIfAborted();
		if (this.#waiting.length === 0 && bytes <= this.#free) {
			this.#free -= bytes;
			return Promise.resolve();
		}
		return new Promise<void>((resolve, reject) => {
			const stopWaiting = () => {
				clearTimeout(timer);
				signal?.removeEventListener("abort", onAbort);
			};
			const leave = (error: unknown) => {
				stopWaiting();
				this.#waiting.splice(this.#waiting.indexOf(waiter), 1);
				reject(error);
				this.#grant();
			};
			const onAbort = () => leave(signal!.reason);
			const waiter = { bytes, grant: () => { stopWaiting(); resolve(); } };
			const timer = setTimeout(() => leave(new ByteBudgetExhausted("in-flight", this.#total)), IN_FLIGHT_WAIT_TIMEOUT_MS);
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
		if (this.#remaining <= 0) throw new ByteBudgetExhausted("call", this.total);
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

	/** Streams a response body within the ceiling, or within its declared length when that is smaller, then cancels the stream.
	 * A body that sends nothing for BODY_IDLE_TIMEOUT_MS fails the read. */
	async readBody(response: Response, perRead: number): Promise<BoundedRead> {
		const declared = declaredLength(response);
		const ceiling = await this.#reserve(perRead, declared).catch(async (error: unknown) => {
			await response.body?.cancel().catch(() => undefined);
			throw error;
		});
		const atLimit = declared !== undefined && declared <= ceiling.limit ? "whole" : "cut";
		const read = await this.#charged(ceiling.reserved, () => streamWithin(response, ceiling.reserved, atLimit));
		if (!read.truncated) return { bytes: read.bytes };
		return { bytes: read.bytes, cut: ceiling.reserved < ceiling.limit ? { atBytes: ceiling.reserved, by: "declared-length" } : { atBytes: ceiling.limit, by: ceiling.by } };
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

/** The body length a response declares, or undefined when it declares none that holds for its body: fetch decompresses an
 * encoded body, which then runs past the content-length of the compressed bytes. */
function declaredLength(response: Response): number | undefined {
	const encoding = response.headers.get("content-encoding");
	if (encoding !== null && encoding.trim().toLowerCase() !== "identity") return undefined;
	const length = response.headers.get("content-length")?.trim();
	return length !== undefined && /^\d+$/.test(length) ? Number(length) : undefined;
}

/** Streams a body until it ends or holds `limit` bytes, then cancels the rest. `atLimit` is what holding `limit` bytes means:
 * "whole" when `limit` is the length the body declared, "cut" otherwise. Neither waits for another chunk to learn whether more
 * follows, since a server holding the connection open never answers that read. */
async function streamWithin(response: Response, limit: number, atLimit: "whole" | "cut"): Promise<{ bytes: Buffer; truncated: boolean }> {
	if (!response.body) return { bytes: Buffer.alloc(0), truncated: false };
	const reader = response.body.getReader();
	const chunks: Uint8Array[] = [];
	let total = 0;
	let truncated = false;
	try {
		for (;;) {
			if (total === limit) {
				truncated = atLimit === "cut";
				await reader.cancel();
				break;
			}
			const { done, value } = await nextChunk(reader, total);
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
	} catch (error) {
		await reader.cancel().catch(() => undefined);
		throw error;
	} finally {
		reader.releaseLock();
	}
	return { bytes: Buffer.concat(chunks, total), truncated };
}

/** The body's next chunk; rejects naming the stall when none arrives within BODY_IDLE_TIMEOUT_MS. */
async function nextChunk(reader: ReadableStreamDefaultReader<Uint8Array>, total: number): Promise<ReadableStreamReadResult<Uint8Array>> {
	let timer: ReturnType<typeof setTimeout> | undefined;
	const stalled = new Promise<never>((_, reject) => {
		timer = setTimeout(() => reject(new Error(`web_fetch body stalled: no bytes arrived for ${BODY_IDLE_TIMEOUT_MS / 1000} s after ${total} bytes; the server kept the connection open without sending.`)), BODY_IDLE_TIMEOUT_MS);
	});
	try {
		return await Promise.race([reader.read(), stalled]);
	} finally {
		clearTimeout(timer);
	}
}

/** The metadata fields a stored item carries when its source was cut; `buildWebFetchToolResult` names the cut and its ceiling in
 * the preview, and `get_web_content` labels the item as cut. */
export function truncationMetadata(cut: BoundedRead["cut"]): { bodyTruncatedAtBytes?: number; bodyTruncatedBy?: ReadCeiling } {
	return cut === undefined ? {} : { bodyTruncatedAtBytes: cut.atBytes, bodyTruncatedBy: cut.by };
}

/** The model-facing note for a stored item whose source `truncationMetadata` marked as cut, or undefined for a whole source;
 * the `web_fetch` preview and the `get_web_content` text both carry it. */
export function sourceCutNote(metadata: Record<string, unknown> | undefined): string | undefined {
	const cutAt = metadata?.bodyTruncatedAtBytes;
	if (typeof cutAt !== "number") return undefined;
	const byBudget = metadata?.bodyTruncatedBy === "call-budget";
	return `source cut at ${cutAt} bytes${byBudget ? " because this call's byte budget ran out; fetch fewer URLs per call to read it whole" : ""}`;
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
	const declared = declaredLength(response);
	if (declared !== undefined && declared > limit) {
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
