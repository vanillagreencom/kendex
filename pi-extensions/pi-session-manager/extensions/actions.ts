import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { appendFileSync, existsSync } from "node:fs";
import { rm, unlink } from "node:fs/promises";
import { join } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { piUserDir } from "./package-config.js";
import { canonicalPath } from "./paths.js";
import { forEachSessionJsonlLine } from "./session-lines.js";
import { configuredSessionDir, settingBoolean } from "./settings.js";
import { KENDEX_MODAL_LOCK_SYMBOL, type Scope, type SessionInfo, type kendexModalLock } from "./types.js";

/** How long `trash` may run on one session file before it is killed and the delete fails. */
const TRASH_TIMEOUT_MS = 5_000;

type TrashOutcome = "trashed" | "refused" | "timed-out";

// stdio is ignored and completion read from "exit": a grandchild holding an
// inherited pipe would otherwise keep a killed `trash` pending. `trash` leads its
// own process group, and the deadline kills the group: a helper it started (npm
// trash-cli's native helper on macOS) would otherwise outlive it and could still
// move the file after the delete reported it kept. Windows has no process groups.
function runTrash(sessionPath: string): Promise<TrashOutcome> {
	const args = sessionPath.startsWith("-") ? ["--", sessionPath] : [sessionPath];
	const ownGroup = process.platform !== "win32";
	return new Promise((resolve) => {
		let timedOut = false;
		const child = spawn("trash", args, { stdio: "ignore", detached: ownGroup });
		const timer = setTimeout(() => {
			timedOut = true;
			if (!ownGroup || child.pid === undefined) {
				child.kill("SIGKILL");
				return;
			}
			try {
				process.kill(-child.pid, "SIGKILL");
			} catch (error) {
				// The group ended between the deadline and its exit event.
				if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
			}
		}, TRASH_TIMEOUT_MS);
		child.once("error", () => {
			clearTimeout(timer);
			resolve("refused");
		});
		child.once("exit", (code) => {
			clearTimeout(timer);
			resolve(timedOut ? "timed-out" : code === 0 ? "trashed" : "refused");
		});
	});
}

function safeFileName(value: string): string {
	return value.replace(/[^\w.-]+/g, "_");
}

// Per-session kendex tree:
//   ~/.pi/agent/kendex/sessions/<id>/<package>/...
// Deleting this dir removes data from every kendex extension that opted into
// the shared layout (pi-agents-tmux, pi-prompt-stash, pi-output-policy, ...).
function perSessionkendexDir(sessionId: string): string {
	return join(piUserDir(), "kendex", "sessions", safeFileName(sessionId));
}

async function removeExtensionSessionData(sessionId: string): Promise<void> {
	const targets = [perSessionkendexDir(sessionId)];
	for (const dir of targets) {
		if (!existsSync(dir)) continue;
		try {
			await rm(dir, { recursive: true, force: true });
		} catch {
			// Best-effort. Failure leaves the dir on disk but does not block the
			// primary session-file deletion.
		}
	}
}

function sessionIdFromPath(sessionPath: string): string {
	const base = sessionPath.split(/[\\/]/).pop() ?? sessionPath;
	return base.replace(/\.jsonl?$/i, "");
}

function appendSessionInfoFallback(sessionPath: string, name: string): void {
	const ids = new Set<string>();
	let parentId: string | null = null;
	try {
		forEachSessionJsonlLine(sessionPath, (line) => {
			if (!line.trim()) return;
			const entry = JSON.parse(line) as { type?: string; id?: string };
			if (entry.type === "session") return;
			if (typeof entry.id === "string") {
				ids.add(entry.id);
				parentId = entry.id;
			}
		});
	} catch {
		// If parsing fails, still append a valid standalone session_info entry.
	}

	let id = randomUUID().slice(0, 8);
	while (ids.has(id)) id = randomUUID().slice(0, 8);
	appendFileSync(sessionPath, `${JSON.stringify({ type: "session_info", id, parentId, timestamp: new Date().toISOString(), name: name.trim() })}\n`);
}

export function renameSession(path: string, name: string): void {
	try {
		SessionManager.open(path).appendSessionInfo(name);
	} catch {
		appendSessionInfoFallback(path, name);
	}
}

export async function deleteSessionFile(
	sessionPath: string,
	cwd: string,
	sessionId?: string,
): Promise<{ ok: boolean; method: "trash" | "unlink"; error?: string }> {
	const id = sessionId && sessionId.trim() ? sessionId.trim() : sessionIdFromPath(sessionPath);

	let primary: { ok: boolean; method: "trash" | "unlink"; error?: string } | undefined;
	if (settingBoolean("deleteUsesTrash", true, cwd)) {
		const outcome = await runTrash(sessionPath);
		if (outcome === "trashed" || !existsSync(sessionPath)) primary = { ok: true, method: "trash" };
		else if (outcome === "timed-out") return { ok: false, method: "trash", error: `trash did not finish within ${TRASH_TIMEOUT_MS / 1000} s; the session file was kept` };
	}

	if (!primary) {
		try {
			await unlink(sessionPath);
			primary = { ok: true, method: "unlink" };
		} catch (error) {
			return { ok: false, method: "unlink", error: error instanceof Error ? error.message : String(error) };
		}
	}

	await removeExtensionSessionData(id);
	return primary;
}

export async function loadSessionsForScope(cwd: string, scope: Scope, onProgress?: (loaded: number, total: number) => void): Promise<SessionInfo[]> {
	const customSessionDir = configuredSessionDir(cwd);
	if (customSessionDir) {
		const sessions = await SessionManager.list(cwd, customSessionDir, onProgress);
		if (scope === "all") return sessions;
		const current = canonicalPath(cwd);
		return sessions.filter((session) => canonicalPath(session.cwd) === current);
	}
	return scope === "all" ? SessionManager.listAll(onProgress) : SessionManager.list(cwd, undefined, onProgress);
}

export function acquirekendexModalLock(): () => void {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const existing = host[KENDEX_MODAL_LOCK_SYMBOL] as kendexModalLock | undefined;
	const lock = existing && typeof existing.depth === "number" ? existing : { depth: 0 };
	host[KENDEX_MODAL_LOCK_SYMBOL] = lock;
	lock.depth += 1;
	let released = false;
	return () => {
		if (released) return;
		released = true;
		lock.depth = Math.max(0, lock.depth - 1);
	};
}
