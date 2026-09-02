import { randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { appendFileSync, existsSync } from "node:fs";
import { rm, unlink } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { SessionManager, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { canonicalPath, expandHome } from "./paths.js";
import { forEachSessionJsonlLine } from "./session-lines.js";
import { configuredSessionDir, settingBoolean } from "./settings.js";
import { LEGACY_STATUS_KEY, KENDEX_MODAL_LOCK_SYMBOL, type Scope, type SessionInfo, type kendexModalLock } from "./types.js";

function piUserDir(): string {
	const configured = expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "~/.pi/agent");
	return isAbsolute(configured) ? resolve(configured) : join(homedir(), ".pi", "agent");
}

function safeFileName(value: string): string {
	return value.replace(/[^\w.-]+/g, "_");
}

// Per-session kendex tree (new layout):
//   ~/.pi/agent/kendex/sessions/<id>/<package>/...
// Deleting this dir removes data from every kendex extension that opted into
// the shared layout (pi-agents-tmux, pi-prompt-stash, pi-output-policy, ...).
function perSessionkendexDir(sessionId: string): string {
	return join(piUserDir(), "kendex", "sessions", safeFileName(sessionId));
}

// Legacy per-package layout (pre path-flip):
//   ~/.pi/agent/kendex/<package>/sessions/<id>/...
// Cleaned up here in case migration on session_start never ran (session was
// never reopened before deletion).
function legacyPerPackageSessionDirs(sessionId: string): string[] {
	const safe = safeFileName(sessionId);
	const root = join(piUserDir(), "kendex");
	const legacyPackages = ["pi-agents-tmux", "prompt-stash", "pi-output-policy"];
	return legacyPackages.map((pkg) => join(root, pkg, "sessions", safe));
}

async function removeExtensionSessionData(sessionId: string): Promise<void> {
	const targets = [perSessionkendexDir(sessionId), ...legacyPerPackageSessionDirs(sessionId)];
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
		const trashArgs = sessionPath.startsWith("-") ? ["--", sessionPath] : [sessionPath];
		const trashResult = spawnSync("trash", trashArgs, { encoding: "utf8" });
		if (trashResult.status === 0 || !existsSync(sessionPath)) primary = { ok: true, method: "trash" };
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

export function clearLegacySessionStatus(ctx: ExtensionContext): void {
	if (!ctx.hasUI) return;
	ctx.ui.setStatus(LEGACY_STATUS_KEY, undefined);
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
