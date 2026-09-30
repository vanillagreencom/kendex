/**
 * Bridge history storage.
 *
 * Owns compact-envelope retention, per-session raw sidecar spill, byte
 * accounting, and rehydrated `history` response assembly. Separated from
 * `session-bridge.ts` so the bridge closure can focus on socket + Pi
 * event wiring.
 *
 * Raw spill semantics:
 *   - Each compact envelope can be paired with a raw JSONL line on disk.
 *   - Slots track `{ ref, offset, length }` so rehydration is one O(1)
 *     pread per envelope, not a full sidecar scan. Pending slots reserve bytes
 *     before enqueueing; raw history requests wait for the FIFO worker.
 *   - When a raw retention budget is configured and the live slots alone
 *     cannot hold the incoming payload, the spill is refused and the envelope
 *     keeps compact-only data plus an explicit `rawError` marker. The file is
 *     not touched: a refusal costs no I/O.
 *   - The worker replaces the sidecar only to reclaim orphaned bytes, those
 *     left by evicted envelopes. That rewrite therefore always makes room, so
 *     one event costs at most one rewrite or one refusal, never both. A
 *     rewrite that fails names its own I/O error on the envelope.
 */

import { stringifyError } from "./diagnostics.js";
import { Buffer } from "node:buffer";
import * as fs from "node:fs";
import * as path from "node:path";
import { setImmediate as nextTurn } from "node:timers/promises";

export interface HistoryEnvelope {
	type: string;
	event: string;
	timestamp: string;
	data: unknown;
	truncated?: boolean;
	originalBytes?: number;
	rawEventPath?: string;
	rawEventRef?: string;
	rawError?: string;
	rawRestored?: boolean;
}

export interface HistoryLimits {
	historyLimit: number;
	maxHistoryBytes: number;
	maxRawSpillBytes: number;
	spillEnabled: boolean;
}

export interface HistoryFilters {
	limit: number;
	maxBytes: number;
	event?: string;
	since?: string;
	raw?: boolean;
}

export interface HistoryResponse {
	events: HistoryEnvelope[];
	totalEvents: number;
	responseTruncated: boolean;
	rawSpillPath: string;
	rawErrors?: string[];
}

interface HistoryEntry {
	envelope: HistoryEnvelope;
	dataJson: string;
	json: string;
	bytes: number;
	rawSlot?: RawSlot;
}

type RawSlot = { ref: string; length: number } & (
	| { state: "pending" }
	| { state: "stored"; offset: number }
);

interface SpillJob {
	entry: HistoryEntry;
	line: string;
	length: number;
	budget: number;
}

const MAX_QUEUED_RAW_BYTES = 16 * 1024 * 1024;
const MAX_QUEUED_RAW_EVENTS = 64;

export type HistoryWarn = (where: string, error: unknown) => void;

const messages = {
	disabled: "spill_enabled=false\nRaw spill is disabled.",
	unsubscribed: "spill_subscriber=false\nNo bridge event subscriber was attached.",
	pending: "spill_pending=true\nRaw spill is queued; history --raw waits for it.",
	queue: "spill_queue_full=true\nThe bounded raw spill queue is full.",
	budget: (bytes: number) => `spill_max_bytes=${bytes}\nRaw spill exceeds the configured limit.`,
	refMismatch: (offset: number) => `raw_ref_offset=${offset}\nThe raw event reference does not match.`,
	noRawPayload: "raw_retained=false\nThe sanitizer kept no raw payload for this event, so there is nothing to restore.",
};

export class BridgeHistory {
	private readonly entries: HistoryEntry[] = [];
	readonly rawSpillPath: string;
	private readonly limits: () => HistoryLimits;
	private readonly warn: HistoryWarn;
	private bytes = 0;
	private rawBytes = 0;
	private rawSequence = 0;
	private readonly queue: SpillJob[] = [];
	private queuedBytes = 0;
	private queuedCount = 0;
	private work: Promise<void> | undefined;

	constructor(
		rawSpillPath: string,
		limits: () => HistoryLimits,
		warn: HistoryWarn = () => undefined,
	) {
		this.rawSpillPath = rawSpillPath;
		this.limits = limits;
		this.warn = warn;
	}

	get sizeBytes(): number {
		return this.bytes;
	}

	get rawSpillBytes(): number {
		return this.rawBytes;
	}

	get count(): number {
		return this.entries.length;
	}

	/** Snapshot envelopes in chronological order. */
	snapshot(): HistoryEnvelope[] {
		return this.entries.map((entry) => entry.envelope);
	}

	/** Retain serialized compact data and queue raw data only for attached event subscribers. */
	push(envelope: HistoryEnvelope, rawJson?: string, dataJson = JSON.stringify(envelope.data) ?? "null", subscribed = true): string {
		const limits = this.limits();
		while (this.entries.length >= limits.historyLimit && this.entries.length > 0) this.evictOldest();
		// Retain the bounded JSON value, not an upstream object whose toJSON hides other data.
		envelope.data = JSON.parse(dataJson) as unknown;
		const entry: HistoryEntry = { envelope, dataJson, json: "", bytes: 0 };
		if (envelope.truncated && rawJson !== undefined) {
			if (!limits.spillEnabled) envelope.rawError = messages.disabled;
			else if (!subscribed) envelope.rawError = messages.unsubscribed;
			else this.enqueue(entry, rawJson, limits);
		}
		this.updateEntry(entry);
		this.entries.push(entry);
		this.bytes += entry.bytes;
		this.trim(limits);
		return entry.json;
	}

	private updateEntry(entry: HistoryEntry): void {
		// Serialize only metadata. The payload string is shared with measurement and spill.
		const metadata = JSON.stringify({ ...entry.envelope, data: undefined });
		entry.json = `${metadata.slice(0, -1)},"data":${entry.dataJson}}`;
		const bytes = Buffer.byteLength(entry.json, "utf8");
		if (this.entries.includes(entry)) this.bytes += bytes - entry.bytes;
		entry.bytes = bytes;
	}

	private trim(limits: HistoryLimits): void {
		while (limits.maxHistoryBytes > 0 && this.bytes > limits.maxHistoryBytes && this.entries.length > 1) this.evictOldest();
	}

	private evictOldest(): void {
		const removed = this.entries.shift();
		if (!removed) return;
		this.bytes -= removed.bytes;
		if (removed.rawSlot) {
			this.rawBytes -= removed.rawSlot.length;
		}
		// Sidecar reclamation happens lazily on the next spill that needs space.
	}

	/**
	 * Build a `history` response.
	 *
	 * Two passes so raw I/O happens only for in-budget envelopes:
	 *   1. Filter, then walk newest-first using compact envelope sizes to
	 *      pick the set that fits inside `maxBytes`. Older envelopes that
	 *      do not fit are excluded; nothing is read from the sidecar for
	 *      them.
	 *   2. For the selected set, optionally rehydrate from the sidecar
	 *      newest-first. If a rehydrated envelope would push the running
	 *      total past `maxBytes` the compact form is kept (and the
	 *      response is marked `responseTruncated`); raw read failures
	 *      surface as `rawError` on that envelope and aggregate into the
	 *      `rawErrors` array.
	 */
	async buildResponse(filters: HistoryFilters): Promise<HistoryResponse> {
		if (filters.raw) while (this.work) await this.work;
		const maxBytes = Math.max(0, Math.floor(filters.maxBytes));
		let candidates = this.entries.slice();
		if (filters.event) candidates = candidates.filter((entry) => entry.envelope.event === filters.event);
		if (filters.since) candidates = candidates.filter((entry) => typeof entry.envelope.timestamp === "string" && entry.envelope.timestamp >= (filters.since as string));
		candidates = candidates.slice(-Math.max(1, Math.floor(filters.limit)));

		const selected: HistoryEntry[] = [];
		let responseTruncated = false;
		let bytes = 0;
		for (let i = candidates.length - 1; i >= 0; i--) {
			const entry = candidates[i]!;
			if (selected.length > 0 && maxBytes > 0 && bytes + entry.bytes > maxBytes) {
				responseTruncated = true;
				break;
			}
			selected.unshift(entry);
			bytes += entry.bytes;
		}

		const events: HistoryEnvelope[] = selected.map((entry) => JSON.parse(entry.json) as HistoryEnvelope);
		const rawErrors: string[] = [];

		if (filters.raw && events.length > 0) {
			let running = bytes;
			for (let i = selected.length - 1; i >= 0; i--) {
				const entry = selected[i]!;
				const target = events[i]!;
				if (target.truncated !== true) continue;
				if (!entry.rawSlot) {
					// Say why this one stays compact, so a delta-only envelope
					// does not read as a spill that failed. A recorded spill
					// failure is more specific, so it wins. The note is
					// informational, so it is charged against the response
					// budget and dropped when it does not fit, the same rule
					// the rehydrated payload below follows.
					if (target.rawError !== undefined) continue;
					const annotated: HistoryEnvelope = { ...target, rawError: messages.noRawPayload };
					const growth = Buffer.byteLength(JSON.stringify(annotated), "utf8") - Buffer.byteLength(JSON.stringify(target), "utf8");
					if (events.length > 1 && maxBytes > 0 && running + growth > maxBytes) {
						responseTruncated = true;
						continue;
					}
					events[i] = annotated;
					running += growth;
					continue;
				}
				const compactSize = Buffer.byteLength(JSON.stringify(target), "utf8");
				if (entry.rawSlot.state !== "stored") throw new Error("Raw history read reached a pending spill");
				const read = this.readRaw(entry.rawSlot);
				if (!read.ok) {
					// A failure is reported whatever the budget; only optional
					// detail is dropped to stay inside it.
					target.rawError = read.error;
					rawErrors.push(`${target.event}#${entry.rawSlot.ref}: ${read.error}`);
					continue;
				}
				const candidate: HistoryEnvelope = { ...target, data: read.data, rawRestored: true };
				const candidateSize = Buffer.byteLength(JSON.stringify(candidate), "utf8");
				if (events.length > 1 && maxBytes > 0 && running + (candidateSize - compactSize) > maxBytes) {
					responseTruncated = true;
					continue;
				}
				events[i] = candidate;
				running += candidateSize - compactSize;
			}
		}

		return {
			events,
			totalEvents: candidates.length,
			responseTruncated,
			rawSpillPath: this.rawSpillPath,
			rawErrors: rawErrors.length > 0 ? rawErrors : undefined,
		};
	}

	/** Cancel pending work, wait for in-flight I/O, then remove the sidecar. */
	async cleanup(): Promise<void> {
		this.entries.length = 0;
		this.bytes = 0;
		this.rawBytes = 0;
		for (const job of this.queue.splice(0)) {
			this.queuedBytes -= job.length;
			this.queuedCount--;
		}
		await this.work;
		try {
			await fs.promises.unlink(this.rawSpillPath);
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code !== "ENOENT") this.warn("cleanup", error);
		}
	}

	private enqueue(entry: HistoryEntry, rawJson: string, limits: HistoryLimits): void {
		const ref = String(++this.rawSequence);
		const metadata = JSON.stringify({ ref, event: entry.envelope.event, timestamp: entry.envelope.timestamp });
		const line = `${metadata.slice(0, -1)},"data":${rawJson}}\n`;
		const length = Buffer.byteLength(line, "utf8");
		if (limits.maxRawSpillBytes > 0 && this.rawBytes + length > limits.maxRawSpillBytes) {
			entry.envelope.rawError = messages.budget(limits.maxRawSpillBytes);
			this.warn("spill.budget", new Error(entry.envelope.rawError));
			return;
		}
		if (this.queuedBytes + length > MAX_QUEUED_RAW_BYTES || this.queuedCount >= MAX_QUEUED_RAW_EVENTS) {
			entry.envelope.rawError = messages.queue;
			this.warn("spill.queue", new Error(messages.queue));
			return;
		}
		entry.rawSlot = { state: "pending", ref, length };
		entry.envelope.rawEventPath = this.rawSpillPath;
		entry.envelope.rawEventRef = ref;
		entry.envelope.rawError = messages.pending;
		this.rawBytes += length;
		this.queuedBytes += length;
		this.queuedCount++;
		this.queue.push({ entry, line, length, budget: limits.maxRawSpillBytes });
		if (!this.work) this.work = this.drain();
	}

	private async drain(): Promise<void> {
		// Start after publish returns. The queue bound includes the in-flight job.
		await nextTurn();
		try {
			let job: SpillJob | undefined;
			while ((job = this.queue.shift()) !== undefined) {
				try {
					if (!this.entries.includes(job.entry)) continue;
					await this.spill(job);
				} catch (error) {
					if (this.entries.includes(job.entry)) {
						this.rawBytes -= job.length;
						job.entry.rawSlot = undefined;
						delete job.entry.envelope.rawEventPath;
						delete job.entry.envelope.rawEventRef;
						job.entry.envelope.rawError = stringifyError(error);
					}
					this.warn("spill", error);
				} finally {
					this.queuedBytes -= job.length;
					this.queuedCount--;
					if (this.entries.includes(job.entry)) {
						this.updateEntry(job.entry);
						this.trim(this.limits());
					}
				}
			}
		} finally {
			this.work = undefined;
		}
	}

	private async spill(job: SpillJob): Promise<void> {
		const slot = job.entry.rawSlot;
		if (!slot || slot.state !== "pending") throw new Error("Spill job has no pending slot");
		let offset = await this.currentFileSize();
		if (job.budget > 0 && offset + job.length > job.budget) {
			await this.compactSidecar();
			offset = await this.currentFileSize();
		}
		if (!this.entries.includes(job.entry)) return;
		await fs.promises.mkdir(path.dirname(this.rawSpillPath), { recursive: true, mode: 0o700 });
		await fs.promises.appendFile(this.rawSpillPath, job.line, { mode: 0o600 });
		job.entry.rawSlot = { state: "stored", ref: slot.ref, length: slot.length, offset };
		delete job.entry.envelope.rawError;
	}

	private async currentFileSize(): Promise<number> {
		try {
			return (await fs.promises.stat(this.rawSpillPath)).size;
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code === "ENOENT") return 0;
			throw error;
		}
	}

	private readRaw(slot: Extract<RawSlot, { state: "stored" }>): { ok: true; data: unknown } | { ok: false; error: string } {
		const current = slot;
		try {
			const fd = fs.openSync(this.rawSpillPath, "r");
			try {
				const buf = Buffer.alloc(current.length);
				fs.readSync(fd, buf, 0, current.length, current.offset);
				const line = buf.toString("utf8").trimEnd();
				const parsed = JSON.parse(line) as { ref?: unknown; data?: unknown };
				if (parsed.ref !== slot.ref) return { ok: false, error: messages.refMismatch(current.offset) };
				return { ok: true, data: parsed.data };
			} finally {
				fs.closeSync(fd);
			}
		} catch (error) {
			return { ok: false, error: stringifyError(error) };
		}
	}

	/** Reclaim orphaned bytes in the same FIFO worker as append operations. */
	private async compactSidecar(): Promise<void> {
		const alive = this.entries.flatMap((entry) => entry.rawSlot?.state === "stored" ? [entry.rawSlot] : []);
		if (alive.length === 0) {
			try { await fs.promises.unlink(this.rawSpillPath); }
			catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
			return;
		}
		const temporary = `${this.rawSpillPath}.compact`;
		const input = await fs.promises.open(this.rawSpillPath, "r");
		try {
			const output = await fs.promises.open(temporary, "w", 0o600);
			const offsets: number[] = [];
			try {
				// One bounded buffer, not a second full sidecar held by Buffer.concat.
				const buffer = Buffer.alloc(64 * 1024);
				let cursor = 0;
				for (const slot of alive) {
					offsets.push(cursor);
					let copied = 0;
					while (copied < slot.length) {
						const { bytesRead } = await input.read(buffer, 0, Math.min(buffer.length, slot.length - copied), slot.offset + copied);
						if (bytesRead === 0) throw new Error("Raw sidecar ended before the retained slot");
						let written = 0;
						while (written < bytesRead) {
							const result = await output.write(buffer, written, bytesRead - written, cursor + written);
							if (result.bytesWritten === 0) throw new Error("Raw sidecar compaction wrote no bytes");
							written += result.bytesWritten;
						}
						copied += bytesRead;
						cursor += bytesRead;
					}
				}
			} finally { await output.close(); }
			await fs.promises.rename(temporary, this.rawSpillPath);
			alive.forEach((slot, i) => { slot.offset = offsets[i]!; });
		} finally {
			await input.close();
			try { await fs.promises.unlink(temporary); }
			catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") this.warn("compact.cleanup", error); }
		}
	}
}



/** Remove sidecar files belonging to dead pids. Best-effort. */
export function cleanupStaleSpills(rawDir: string, isAlive: (pid: number) => boolean): void {
	if (!fs.existsSync(rawDir)) return;
	let entries: string[] = [];
	try {
		entries = fs.readdirSync(rawDir);
	} catch {
		return;
	}
	for (const name of entries) {
		const match = /^(\d+)\.jsonl$/.exec(name);
		if (!match) continue;
		const pid = Number.parseInt(match[1]!, 10);
		if (!Number.isFinite(pid)) continue;
		if (pid === process.pid) continue;
		if (isAlive(pid)) continue;
		try {
			fs.unlinkSync(path.join(rawDir, name));
		} catch {
			// best-effort cleanup
		}
	}
}
