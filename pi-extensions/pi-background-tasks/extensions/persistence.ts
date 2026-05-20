// Snapshot persistence helpers for pi-background-tasks.
//
// Extracted from background-tasks.ts (reviewer-structure #2). Responsibilities:
//   - Resolve the per-session sidecar state path.
//   - Atomic temp+rename writes so a crash mid-write can't shred the
//     replay record (reviewer-error #2).
//   - Surface failures on both channels (Pi appendEntry + sidecar)
//     instead of silently swallowing them.
//
// The factory function returns a closure-friendly { persistSnapshots,
// sidecarStatePath, sessionIdForContext } trio so background-tasks.ts
// can pass it the current view of the task map without re-importing
// everything per call.

import {
	mkdirSync,
	renameSync,
	unlinkSync,
	writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

import { logBackgroundDiagnostic } from "./diagnostics.js";
import type { BackgroundTaskSnapshot } from "./types.js";

// Hard cap on the JSON byte size of a `vstack-background-tasks:state` custom
// entry appended to a Pi session JSONL file. Sessions are append-only, so
// repeatedly writing full task lists with multi-KB heredoc commands
// accumulates 10s-100s of MB of session history that crashes `/resume`
// (vstack#177). Sidecar state remains canonical at this size and is read
// first on restore; oversized session payloads degrade to a tiny manifest.
export const BG_TASKS_SNAPSHOT_MAX_BYTES = 64 * 1024;

export interface BgTasksBoundedManifest {
	version: 2;
	fullSnapshot: false;
	reason: "payload-too-large";
	byteSize: number;
	fingerprint: string;
	counts: { tasks: number };
	updatedAt: number;
}

export function isBgTasksBoundedManifest(value: unknown): value is BgTasksBoundedManifest {
	if (!value || typeof value !== "object") return false;
	const candidate = value as Partial<BgTasksBoundedManifest>;
	return candidate.version === 2 && candidate.fullSnapshot === false;
}

function stableValue(value: unknown): unknown {
	if (Array.isArray(value)) return value.map(stableValue);
	if (!value || typeof value !== "object") return value;
	const sorted: Record<string, unknown> = {};
	for (const key of Object.keys(value as Record<string, unknown>).sort()) sorted[key] = stableValue((value as Record<string, unknown>)[key]);
	return sorted;
}

export function stableSnapshotFingerprint(value: unknown): string {
	return JSON.stringify(stableValue(value));
}

export interface PersistResult {
	appendEntry: boolean;
	sidecar: boolean;
	/** Why the session-entry write resolved the way it did. */
	appendReason?: "appended" | "unchanged" | "manifest" | "no-active-context" | "error";
}

export interface PersistencePayload {
	version: number;
	tasks: BackgroundTaskSnapshot[];
	updatedAt: number;
}

export interface PersistenceDeps {
	pi: ExtensionAPI;
	customType: string;
	getActiveCtx: () => ExtensionContext | null;
	listSnapshots: () => BackgroundTaskSnapshot[];
	notify?: (where: string, message: string) => void;
	/** Override the per-entry byte cap (testing). Defaults to BG_TASKS_SNAPSHOT_MAX_BYTES. */
	maxEntryBytes?: number;
}

export function piUserDir(): string {
	return resolve(process.env.PI_CODING_AGENT_DIR?.trim() || `${process.env.HOME ?? ""}/.pi/agent`);
}

export function safeFileName(value: string): string {
	return value.replace(/[^\w.-]+/g, "_");
}

export function sessionIdForContext(ctx: ExtensionContext): string {
	const id = ctx.sessionManager.getSessionId();
	if (id && id.trim()) return id;
	const file = ctx.sessionManager.getSessionFile();
	if (file) return file.split(/[\\/]/).pop()?.replace(/\.jsonl$/, "") ?? `ephemeral-${process.pid}`;
	return `ephemeral-${process.pid}`;
}

export function sidecarStatePath(ctx: ExtensionContext): string {
	return join(
		piUserDir(),
		"vstack",
		"sessions",
		safeFileName(sessionIdForContext(ctx)),
		"pi-background-tasks",
		"state.json",
	);
}

// Atomic write: temp file in the same directory + rename(2). Aborts on
// error so the previous good state is preserved. Mode 0600 on the temp
// file matches the eventual file's permissions; mode 0700 on the
// parent directory prevents cross-user read of session state.
export function writeSidecarAtomic(file: string, payload: string): void {
	mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
	const tmp = `${file}.tmp.${process.pid}.${Date.now()}`;
	try {
		writeFileSync(tmp, payload, { encoding: "utf8", mode: 0o600 });
		renameSync(tmp, file);
	} catch (error) {
		try { unlinkSync(tmp); } catch { /* */ }
		throw error;
	}
}

export function reportPersistFailure(
	where: string,
	error: unknown,
	notify?: (where: string, message: string) => void,
): void {
	const msg = error instanceof Error ? error.message : String(error);
	logBackgroundDiagnostic("persistence failed", { where, error: msg });
	notify?.(where, msg);
}

// Persist the latest snapshot set on both channels independently:
//   1. pi.appendEntry — the in-session JSONL custom entry the agent
//      will see on next restore via getBranch().
//   2. Sidecar — out-of-session state.json the extension reads first
//      on session_start so the agent doesn't have to walk the entire
//      session log.
//
// Each channel's success is reported independently; one failure does
// not suppress the other. A partial write still leaves at least one
// durable copy of the latest state.
export function createPersistence(deps: PersistenceDeps): {
	persistSnapshots: () => PersistResult;
	payloadFor: (tasks: BackgroundTaskSnapshot[]) => PersistencePayload;
} {
	const notify = deps.notify;
	const maxBytes = deps.maxEntryBytes ?? BG_TASKS_SNAPSHOT_MAX_BYTES;
	// Last fingerprint observed per Pi session id. Identical successive task
	// lists do not re-append to JSONL; a session that mostly stays steady
	// emits one entry per change instead of one per lifecycle event.
	const lastFingerprintBySession = new Map<string, string>();

	function payloadFor(tasks: BackgroundTaskSnapshot[]): PersistencePayload {
		return { version: 1, tasks, updatedAt: Date.now() };
	}

	function persistSnapshots(): PersistResult {
		const payload = payloadFor(deps.listSnapshots());
		const ctx = deps.getActiveCtx();
		let appendEntryOk = false;
		let appendReason: PersistResult["appendReason"] = ctx ? undefined : "no-active-context";
		let sidecarOk = ctx == null;

		if (ctx) {
			const sessionKey = sessionIdForContext(ctx);
			// Fingerprint excludes updatedAt — only structural changes warrant a new session entry.
			const fingerprint = stableSnapshotFingerprint({ tasks: payload.tasks });
			if (lastFingerprintBySession.get(sessionKey) === fingerprint) {
				appendEntryOk = true;
				appendReason = "unchanged";
			} else {
				const serialized = JSON.stringify(payload);
				const byteSize = Buffer.byteLength(serialized, "utf8");
				try {
					if (byteSize <= maxBytes) {
						deps.pi.appendEntry(deps.customType, payload);
						appendReason = "appended";
					} else {
						const manifest: BgTasksBoundedManifest = {
							version: 2,
							fullSnapshot: false,
							reason: "payload-too-large",
							byteSize,
							fingerprint,
							counts: { tasks: payload.tasks.length },
							updatedAt: payload.updatedAt,
						};
						deps.pi.appendEntry(deps.customType, manifest);
						appendReason = "manifest";
					}
					lastFingerprintBySession.set(sessionKey, fingerprint);
					appendEntryOk = true;
				} catch (error) {
					appendReason = "error";
					reportPersistFailure("appendEntry", error, notify);
				}
			}
		} else {
			// No active context — fall back to the unconditional append so a one-shot/
			// no-context call still records something. Bounded restore is irrelevant
			// without a session.
			try {
				deps.pi.appendEntry(deps.customType, payload);
				appendEntryOk = true;
			} catch (error) {
				appendReason = "error";
				reportPersistFailure("appendEntry", error, notify);
			}
		}

		if (ctx) {
			try {
				writeSidecarAtomic(sidecarStatePath(ctx), `${JSON.stringify(payload, null, 2)}\n`);
				sidecarOk = true;
			} catch (error) {
				reportPersistFailure("sidecar", error, notify);
			}
		}

		return { appendEntry: appendEntryOk, sidecar: sidecarOk, appendReason };
	}

	return { persistSnapshots, payloadFor };
}
