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
 *     pread per envelope, not a full sidecar scan.
 *   - When a raw retention budget is configured the sidecar is rewritten
 *     in-place to drop slots whose envelopes already evicted; if the new
 *     payload still does not fit it is refused and the envelope keeps
 *     compact-only data plus an explicit `rawError` marker.
 */

import { Buffer } from "node:buffer";
import * as fs from "node:fs";
import * as path from "node:path";

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
	bytes: number;
	rawSlot?: RawSlot;
}

interface RawSlot {
	ref: string;
	offset: number;
	length: number;
}

export type HistoryWarn = (where: string, error: unknown) => void;

export class BridgeHistory {
	private readonly entries: HistoryEntry[] = [];
	private readonly rawIndex = new Map<string, RawSlot>();
	private bytes = 0;
	private rawBytes = 0;
	private rawSequence = 0;
	private lastSpillError: string | undefined;

	constructor(
		readonly rawSpillPath: string,
		private readonly limits: () => HistoryLimits,
		private readonly warn: HistoryWarn = () => undefined,
	) {}

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

	/** Push a compact envelope; optionally spill the raw payload to the sidecar. */
	push(envelope: HistoryEnvelope, rawPayload?: unknown): HistoryEnvelope {
		const limits = this.limits();
		// Evict by count first so the raw spill budget reflects only live entries.
		while (this.entries.length >= limits.historyLimit && this.entries.length > 0) this.evictOldest();

		let rawSlot: RawSlot | undefined;
		if (envelope.truncated && rawPayload !== undefined) {
			if (limits.spillEnabled) {
				rawSlot = this.spill(envelope.event, envelope.timestamp, rawPayload, limits);
				if (rawSlot) {
					envelope.rawEventPath = this.rawSpillPath;
					envelope.rawEventRef = rawSlot.ref;
					delete envelope.rawError;
				} else if (this.lastSpillError) {
					envelope.rawError = this.lastSpillError;
				}
			} else {
				envelope.rawError = "raw spill disabled";
			}
		}
		const bytes = Buffer.byteLength(JSON.stringify(envelope), "utf8");
		this.entries.push({ envelope, bytes, rawSlot });
		this.bytes += bytes;
		while (limits.maxHistoryBytes > 0 && this.bytes > limits.maxHistoryBytes && this.entries.length > 1) this.evictOldest();
		return envelope;
	}

	private evictOldest(): void {
		const removed = this.entries.shift();
		if (!removed) return;
		this.bytes -= removed.bytes;
		if (removed.rawSlot) {
			this.rawIndex.delete(removed.rawSlot.ref);
			this.rawBytes -= removed.rawSlot.length;
		}
		// Sidecar reclamation happens lazily on the next spill that needs space.
	}

	/** Build a `history` response: filter, then walk newest-first, optionally rehydrating raw, until the byte budget is reached. */
	buildResponse(filters: HistoryFilters): HistoryResponse {
		const maxBytes = Math.max(0, Math.floor(filters.maxBytes));
		let candidates = this.entries.slice();
		if (filters.event) candidates = candidates.filter((entry) => entry.envelope.event === filters.event);
		if (filters.since) candidates = candidates.filter((entry) => typeof entry.envelope.timestamp === "string" && entry.envelope.timestamp >= (filters.since as string));
		candidates = candidates.slice(-Math.max(1, Math.floor(filters.limit)));

		const events: HistoryEnvelope[] = [];
		const rawErrors: string[] = [];
		let bytes = 0;
		let responseTruncated = false;

		for (let i = candidates.length - 1; i >= 0; i--) {
			const entry = candidates[i]!;
			let envelope = clone(entry.envelope);
			if (filters.raw && entry.rawSlot && envelope.truncated === true) {
				const read = this.readRaw(entry.rawSlot);
				if (read.ok) {
					envelope = { ...envelope, data: read.data, rawRestored: true };
				} else {
					envelope.rawError = read.error;
					rawErrors.push(`${envelope.event}#${entry.rawSlot.ref}: ${read.error}`);
				}
			}
			const size = Buffer.byteLength(JSON.stringify(envelope), "utf8");
			if (events.length > 0 && maxBytes > 0 && bytes + size > maxBytes) {
				responseTruncated = true;
				break;
			}
			events.unshift(envelope);
			bytes += size;
		}

		return {
			events,
			totalEvents: candidates.length,
			responseTruncated,
			rawSpillPath: this.rawSpillPath,
			rawErrors: rawErrors.length > 0 ? rawErrors : undefined,
		};
	}

	/** Drop all in-memory state and remove the sidecar file. */
	cleanup(): void {
		this.entries.length = 0;
		this.bytes = 0;
		this.rawBytes = 0;
		this.rawIndex.clear();
		try {
			fs.unlinkSync(this.rawSpillPath);
		} catch {
			// Already gone or not created yet.
		}
	}

	private spill(event: string, timestamp: string, raw: unknown, limits: HistoryLimits): RawSlot | undefined {
		this.lastSpillError = undefined;
		try {
			this.ensureRawDir();
			const ref = String(++this.rawSequence);
			const line = `${JSON.stringify({ ref, event, timestamp, data: raw })}\n`;
			const length = Buffer.byteLength(line, "utf8");

			if (limits.maxRawSpillBytes > 0 && this.rawBytes + length > limits.maxRawSpillBytes) {
				this.compactSidecar();
				if (this.rawBytes + length > limits.maxRawSpillBytes) {
					this.lastSpillError = `raw spill exceeds maxRawSpillBytes (${limits.maxRawSpillBytes})`;
					this.warn("spill.budget", new Error(this.lastSpillError));
					return undefined;
				}
			}

			let offset = 0;
			try {
				offset = fs.statSync(this.rawSpillPath).size;
			} catch (error) {
				if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
				offset = 0;
			}
			fs.appendFileSync(this.rawSpillPath, line, { mode: 0o600 });
			const slot: RawSlot = { ref, offset, length };
			this.rawIndex.set(ref, slot);
			this.rawBytes += length;
			return slot;
		} catch (error) {
			this.lastSpillError = stringifyError(error);
			this.warn("spill", error);
			return undefined;
		}
	}

	private readRaw(slot: RawSlot): { ok: true; data: unknown } | { ok: false; error: string } {
		const current = this.rawIndex.get(slot.ref) ?? slot;
		try {
			const fd = fs.openSync(this.rawSpillPath, "r");
			try {
				const buf = Buffer.alloc(current.length);
				fs.readSync(fd, buf, 0, current.length, current.offset);
				const line = buf.toString("utf8").trimEnd();
				const parsed = JSON.parse(line) as { ref?: unknown; data?: unknown };
				if (parsed.ref !== slot.ref) return { ok: false, error: `raw ref mismatch at offset ${current.offset}` };
				return { ok: true, data: parsed.data };
			} finally {
				fs.closeSync(fd);
			}
		} catch (error) {
			return { ok: false, error: stringifyError(error) };
		}
	}

	private compactSidecar(): void {
		const alive = this.entries.filter((entry) => entry.rawSlot).map((entry) => entry.rawSlot!);
		if (alive.length === 0) {
			try {
				fs.unlinkSync(this.rawSpillPath);
			} catch {
				// already absent
			}
			this.rawIndex.clear();
			this.rawBytes = 0;
			return;
		}
		try {
			const fd = fs.openSync(this.rawSpillPath, "r");
			const buffers: Buffer[] = [];
			try {
				for (const slot of alive) {
					const buf = Buffer.alloc(slot.length);
					fs.readSync(fd, buf, 0, slot.length, slot.offset);
					buffers.push(buf);
				}
			} finally {
				fs.closeSync(fd);
			}
			this.rawIndex.clear();
			this.rawBytes = 0;
			fs.writeFileSync(this.rawSpillPath, Buffer.concat(buffers), { mode: 0o600 });
			let cursor = 0;
			for (let i = 0; i < alive.length; i++) {
				const slot = alive[i]!;
				const length = buffers[i]!.length;
				slot.offset = cursor;
				slot.length = length;
				this.rawIndex.set(slot.ref, slot);
				cursor += length;
			}
			this.rawBytes = cursor;
		} catch (error) {
			this.warn("compactSidecar", error);
		}
	}

	private ensureRawDir(): void {
		const dir = path.dirname(this.rawSpillPath);
		if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
	}
}

function clone(envelope: HistoryEnvelope): HistoryEnvelope {
	return JSON.parse(JSON.stringify(envelope)) as HistoryEnvelope;
}

function stringifyError(error: unknown): string {
	if (error instanceof Error) return `${error.name}: ${error.message}`;
	return String(error);
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
