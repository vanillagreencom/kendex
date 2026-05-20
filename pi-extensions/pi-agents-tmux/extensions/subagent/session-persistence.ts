import { createHash } from "node:crypto";
import * as fs from "node:fs";

const SESSION_TAIL_BYTES = 1024 * 1024;

// Default cap on the JSON byte size of any extension state custom entry
// appended to a Pi session JSONL file. Sessions are append-only, so
// repeatedly writing 100s of KB of full-state snapshots accumulates into
// GB of session history that crashes `/resume` (vstack#177). Sidecar
// state on disk remains canonical at this size and is read first on
// restore; oversized session payloads degrade to bounded manifests or
// are skipped entirely.
export const BOUNDED_SNAPSHOT_DEFAULT_MAX_BYTES = 64 * 1024;

export interface BoundedSnapshotManifest {
	version: 2;
	fullSnapshot: false;
	reason: "payload-too-large";
	byteSize: number;
	fingerprint: string;
	counts: Record<string, number>;
	updatedAt: string;
}

export type BoundedSnapshotOutcome =
	| { appended: false; reason: "unchanged"; byteSize: number; fingerprint: string }
	| { appended: true; reason: "appended"; byteSize: number; fingerprint: string }
	| { appended: true; reason: "manifest"; byteSize: number; fingerprint: string; manifest: BoundedSnapshotManifest };

export interface BoundedAppenderLike {
	appendEntry: <T>(customType: string, data: T) => unknown;
}

export interface BoundedSnapshotOptions<T> {
	appender: BoundedAppenderLike;
	customType: string;
	payload: T;
	sessionKey: string;
	fingerprintCache: Map<string, string>;
	/** Optional fingerprint input override. Defaults to the payload itself. */
	fingerprintInput?: unknown;
	/** Override per-call. Default is `BOUNDED_SNAPSHOT_DEFAULT_MAX_BYTES`. */
	maxBytes?: number;
	/** Counts surfaced in the manifest body (`{ tasks: 205, panes: 0 }` etc). */
	counts?: () => Record<string, number>;
	/** Set false to skip the manifest entry entirely when over cap. Defaults to true. */
	manifestOnOverflow?: boolean;
}

export function appendBoundedSnapshot<T>(opts: BoundedSnapshotOptions<T>): BoundedSnapshotOutcome {
	const maxBytes = opts.maxBytes ?? BOUNDED_SNAPSHOT_DEFAULT_MAX_BYTES;
	const fingerprint = stableSessionSnapshotFingerprint(opts.fingerprintInput ?? opts.payload);
	const cached = opts.fingerprintCache.get(opts.sessionKey);
	if (cached === fingerprint) return { appended: false, reason: "unchanged", byteSize: 0, fingerprint };
	const serialized = JSON.stringify(opts.payload) ?? "null";
	const byteSize = Buffer.byteLength(serialized, "utf8");
	if (byteSize <= maxBytes) {
		opts.appender.appendEntry(opts.customType, opts.payload);
		opts.fingerprintCache.set(opts.sessionKey, fingerprint);
		return { appended: true, reason: "appended", byteSize, fingerprint };
	}
	if (opts.manifestOnOverflow === false) {
		opts.fingerprintCache.set(opts.sessionKey, fingerprint);
		return { appended: false, reason: "unchanged", byteSize, fingerprint };
	}
	const manifest: BoundedSnapshotManifest = {
		version: 2,
		fullSnapshot: false,
		reason: "payload-too-large",
		byteSize,
		fingerprint,
		counts: opts.counts?.() ?? {},
		updatedAt: new Date().toISOString(),
	};
	// vstack#183 defensive: the manifest itself must stay under the cap.
	// With the SHA-256 fingerprint the body is bounded, but the assertion
	// catches future field growth that would silently regress the fix.
	const manifestBytes = Buffer.byteLength(JSON.stringify(manifest) ?? "null", "utf8");
	if (manifestBytes > maxBytes) {
		opts.fingerprintCache.set(opts.sessionKey, fingerprint);
		return { appended: false, reason: "unchanged", byteSize, fingerprint };
	}
	opts.appender.appendEntry(opts.customType, manifest);
	opts.fingerprintCache.set(opts.sessionKey, fingerprint);
	return { appended: true, reason: "manifest", byteSize, fingerprint, manifest };
}

export function isBoundedSnapshotManifest(value: unknown): value is BoundedSnapshotManifest {
	if (!value || typeof value !== "object") return false;
	const candidate = value as Partial<BoundedSnapshotManifest>;
	return candidate.version === 2 && candidate.fullSnapshot === false;
}

export interface SessionLeafContextLike {
	sessionManager: {
		getLeafId?: () => string | null | undefined;
		getSessionFile?: () => string | undefined;
	};
}

function stableValue(value: unknown): unknown {
	if (Array.isArray(value)) return value.map(stableValue);
	if (!value || typeof value !== "object") return value;
	const sorted: Record<string, unknown> = {};
	for (const key of Object.keys(value as Record<string, unknown>).sort()) sorted[key] = stableValue((value as Record<string, unknown>)[key]);
	return sorted;
}

// vstack#183: fingerprints are persisted inside the overflow manifest;
// returning the full canonical JSON defeats the byte cap that the
// manifest exists to enforce. Hash the stable JSON down to a fixed-size
// hex digest so an oversized payload yields a small manifest.
export function stableSessionSnapshotFingerprint(value: unknown): string {
	return createHash("sha256").update(JSON.stringify(stableValue(value))).digest("hex");
}

function lastEntryIdFromText(text: string): string | undefined {
	const lines = text.split(/\r?\n/);
	for (let i = lines.length - 1; i >= 0; i--) {
		const line = lines[i]?.trim();
		if (!line) continue;
		try {
			const entry = JSON.parse(line) as { id?: unknown; type?: unknown };
			if (entry.type !== "session" && typeof entry.id === "string" && entry.id.trim()) return entry.id;
		} catch {
			// Tail chunks can start mid-line; keep scanning earlier lines or fall back to full read.
		}
	}
	return undefined;
}

export async function readLastSessionEntryId(sessionFile: string): Promise<string | undefined> {
	const handle = await fs.promises.open(sessionFile, "r");
	try {
		const stat = await handle.stat();
		if (stat.size <= 0) return undefined;
		const length = Math.min(stat.size, SESSION_TAIL_BYTES);
		const start = stat.size - length;
		const buffer = Buffer.alloc(length);
		await handle.read(buffer, 0, length, start);
		const fromTail = lastEntryIdFromText(buffer.toString("utf8"));
		if (fromTail || start === 0) return fromTail;
	} finally {
		await handle.close();
	}

	// Rare fallback: last JSONL entry is larger than the tail window.
	return lastEntryIdFromText(await fs.promises.readFile(sessionFile, "utf8"));
}

export async function sessionFileTailMatchesLeaf(ctx: SessionLeafContextLike): Promise<boolean> {
	const sessionFile = ctx.sessionManager.getSessionFile?.();
	if (!sessionFile) return true;
	let leafId: string | null | undefined;
	try {
		leafId = ctx.sessionManager.getLeafId?.();
	} catch {
		return false;
	}
	let lastId: string | undefined;
	try {
		lastId = await readLastSessionEntryId(sessionFile);
	} catch {
		return false;
	}
	if (!leafId) return lastId === undefined;
	return lastId === leafId;
}
