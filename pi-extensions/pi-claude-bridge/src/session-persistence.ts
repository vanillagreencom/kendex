import { type AssistantMessage, type Context } from "@earendil-works/pi-ai";
import { createSession, deleteSession, openSession, repairToolPairing } from "cc-session-io";
import { createHash } from "crypto";
import { realpathSync, statSync } from "fs";
import { resolve as pathResolve } from "path";
import { extensionApi, piUI, reportSyntheticToolResultRepair, setSharedSession, sharedSession, type SessionState } from "./bridge-state.js";
import { convertPiMessages } from "./convert.js";
import { DEBUG, DEBUG_LOG_PATH, debug, diagDump } from "./debug.js";
import { verifyWrittenSession as _verifyWrittenSession } from "./session-verify.js";
import { findUnpairedToolUses, insertLostToolResultPlaceholders } from "./tool-pairing-audit.js";

// --- Session persistence ---

const BRIDGE_SESSION_CUSTOM_TYPE = "claude-bridge-session";

interface PersistedBridgeSessionState extends SessionState {
	fingerprint: string;
	piSessionId?: string;
	updatedAt: string;
}

function fingerprintMessages(messages: Context["messages"]): string {
	const normalized = messages.map((message) => {
		if (message.role === "assistant") {
			return {
				role: message.role,
				provider: (message as AssistantMessage).provider,
				model: (message as AssistantMessage).model,
				content: (message as AssistantMessage).content,
			};
		}
		return message;
	});
	return createHash("sha256").update(JSON.stringify(normalized)).digest("hex");
}

function readBuiltSessionContext(sessionManager: unknown): { messages: Context["messages"] } | undefined {
	const built = typeof (sessionManager as any)?.buildSessionContext === "function" ? (sessionManager as any).buildSessionContext() : undefined;
	return Array.isArray(built?.messages) ? built as { messages: Context["messages"] } : undefined;
}

function latestPersistedBridgeSession(sessionManager: unknown): PersistedBridgeSessionState | undefined {
	const entries = typeof (sessionManager as any)?.getEntries === "function" ? (sessionManager as any).getEntries() : [];
	if (!Array.isArray(entries)) return undefined;
	for (let i = entries.length - 1; i >= 0; i--) {
		const entry = entries[i];
		if (entry?.type !== "custom" || entry.customType !== BRIDGE_SESSION_CUSTOM_TYPE) continue;
		const data = entry.data as Partial<PersistedBridgeSessionState> | undefined;
		if (!data || typeof data.sessionId !== "string" || typeof data.cursor !== "number" || typeof data.cwd !== "string" || typeof data.fingerprint !== "string") continue;
		return data as PersistedBridgeSessionState;
	}
	return undefined;
}

function claudeSessionExists(sessionId: string, cwd: string): boolean {
	try {
		const session = openSession({ sessionId, projectPath: cwd, claudeDir: process.env.CLAUDE_CONFIG_DIR });
		statSync(session.jsonlPath);
		return true;
	} catch {
		return false;
	}
}

function canonicalize(p: string | undefined): string | undefined {
	if (!p) return undefined;
	try { return realpathSync.native(p); } catch { return pathResolve(p); }
}

// Decides whether a persisted bridge-session marker is safe to restore.
//
// The fork case is the load-bearing one: pi/core's createBranchedSession copies
// every non-label entry from root→leaf into the new session file. That includes
// our claude-bridge-session markers from the parent. Restoring from them would
// --resume parent's Claude jsonl on the fork's first turn, leaking conversation
// past the fork point.
//
// Returns undefined when the entry is safe to use, or a short rejection reason
// for diagnostic logging. Old entries without piSessionId always reject, which
// degrades safely to the rebuild path.
export function shouldRestorePersistedBridgeEntry(
	persisted: { piSessionId?: string; cwd: string },
	currentPiSessionId: string | undefined,
	currentCwd: string | undefined,
): string | undefined {
	if (!persisted.piSessionId) return "missing piSessionId";
	if (currentPiSessionId && persisted.piSessionId !== currentPiSessionId) {
		return `piSessionId mismatch (persisted=${persisted.piSessionId} current=${currentPiSessionId})`;
	}
	if (currentCwd && canonicalize(persisted.cwd) !== canonicalize(currentCwd)) {
		return `cwd mismatch (persisted=${persisted.cwd} current=${currentCwd})`;
	}
	return undefined;
}

export function restoreSharedSessionFromPi(ctx: { sessionManager?: unknown; cwd?: string }): void {
	const persisted = latestPersistedBridgeSession(ctx.sessionManager);
	if (!persisted) return;
	const currentPiSessionId = typeof (ctx.sessionManager as any)?.getSessionId === "function" ? (ctx.sessionManager as any).getSessionId() : undefined;
	const currentCwd = typeof (ctx.sessionManager as any)?.getCwd === "function" ? (ctx.sessionManager as any).getCwd() : ctx.cwd;
	const rejection = shouldRestorePersistedBridgeEntry(persisted, currentPiSessionId, currentCwd);
	if (rejection) {
		debug(`restoreSharedSession: ${rejection} — forcing rebuild`);
		return;
	}
	const built = readBuiltSessionContext(ctx.sessionManager);
	if (!built) return;
	const cursor = Math.max(0, Math.min(persisted.cursor, built.messages.length));
	const fingerprint = fingerprintMessages(built.messages.slice(0, cursor));
	if (fingerprint !== persisted.fingerprint) {
		debug(`restoreSharedSession: fingerprint mismatch for ${persisted.sessionId.slice(0, 8)}`);
		return;
	}
	if (!claudeSessionExists(persisted.sessionId, persisted.cwd)) {
		debug(`restoreSharedSession: Claude session missing for ${persisted.sessionId.slice(0, 8)}`);
		return;
	}
	setSharedSession({ sessionId: persisted.sessionId, cursor, cwd: persisted.cwd });
	debug(`restoreSharedSession: restored ${persisted.sessionId.slice(0, 8)}, cursor=${cursor}`);
}

export function schedulePersistSharedSession(ctxLike?: { sessionManager?: unknown }): void {
	if (!extensionApi || !sharedSession || !ctxLike?.sessionManager) return;
	const snapshot = { ...sharedSession };
	const timer = setTimeout(() => {
		try {
			const built = readBuiltSessionContext(ctxLike.sessionManager);
			if (!built) return;
			const cursor = Math.max(0, Math.min(snapshot.cursor, built.messages.length));
			const data: PersistedBridgeSessionState = {
				...snapshot,
				cursor,
				fingerprint: fingerprintMessages(built.messages.slice(0, cursor)),
				piSessionId: typeof (ctxLike.sessionManager as any)?.getSessionId === "function" ? (ctxLike.sessionManager as any).getSessionId() : undefined,
				updatedAt: new Date().toISOString(),
			};
			extensionApi?.appendEntry(BRIDGE_SESSION_CUSTOM_TYPE, data);
			debug(`persistSharedSession: saved ${data.sessionId.slice(0, 8)}, cursor=${data.cursor}`);
		} catch (error) {
			debug("persistSharedSession failed:", error);
		}
	}, 0);
	timer.unref?.();
}

// Convert pi messages to Anthropic API format for session import.
// Lossy: non-Anthropic thinking blocks are dropped (no valid signature). User and
// tool-result image blocks are preserved when possible. If assistant blocks are
// otherwise incompatible, convertPiMessages emits a text placeholder so the record
// sequence stays valid before repairToolPairing runs.
function convertAndImportMessages(
	session: ReturnType<typeof createSession>,
	messages: Context["messages"],
	customToolNameToSdk?: Map<string, string>,
	cwd?: string,
): void {
	const { anthropicMessages, sanitizedIds } = convertPiMessages(messages, customToolNameToSdk);

	debug(`convertAndImportMessages: ${messages.length} pi msgs → ${anthropicMessages.length} anthropic msgs`);
	debug(`convertAndImportMessages: imported roles:`, anthropicMessages.map((m, i) => {
		const c = m.content;
		if (typeof c === "string") return `[${i}]${m.role}:text`;
		if (Array.isArray(c)) return `[${i}]${m.role}:${(c).map((b) => b.type).join("+")}`;
		return `[${i}]${m.role}:?`;
	}).join(" "));
	if (sanitizedIds.size > 0) {
		debug(`convertAndImportMessages: sanitized ${sanitizedIds.size} tool IDs:`,
			[...sanitizedIds.entries()].map(([orig, clean]) => orig === clean ? orig : `${orig}→${clean}`).join(", "));
	}
	// Pre-repair: pair every orphaned tool_use with an EXPLICIT bridge-authored
	// error result before cc-session-io's repairToolPairing can backfill its bare
	// "[no tool result recorded]" placeholder — which the model reads as tool
	// output and silently reasons on. Ours is is_error and says what to do.
	// repairToolPairing still runs after (idempotent; finds nothing left).
	const missingToolResults = findUnpairedToolUses(anthropicMessages);
	if (missingToolResults.length > 0) insertLostToolResultPlaceholders(anthropicMessages, missingToolResults);
	const repaired = repairToolPairing(anthropicMessages);
	if (missingToolResults.length > 0) {
		reportSyntheticToolResultRepair(missingToolResults, {
			cwd,
			messageCount: messages.length,
			anthropicMessageCount: anthropicMessages.length,
			sessionId: session.sessionId,
			jsonlPath: session.jsonlPath,
		});
	}
	if (repaired.length !== anthropicMessages.length) {
		debug(`convertAndImportMessages: repairToolPairing ${anthropicMessages.length} → ${repaired.length} msgs`);
	}
	if (repaired.length) session.importMessages(repaired);
}

interface SyncResult {
	sessionId: string | null;
}

/**
 * Ensure the shared session has all messages up to (but not including) the last user message.
 * Returns session ID to resume from, or null if no resume needed.
 */
// Read the session file we just wrote and sanity-check it. Warns instead of
// throwing — CC may be more tolerant than our checks, so a false positive
// shouldn't block the user. Pure logic is in session-verify.js; this wrapper
// fans each warning out to debug log + piUI notify + diagDump.
function verifyWrittenSession(
	jsonlPath: string,
	expectedSessionId: string,
	expectedRecordCount: number,
	cwd: string,
): void {
	const warnings = _verifyWrittenSession(jsonlPath, expectedSessionId, expectedRecordCount);
	for (const msg of warnings) {
		debug(`WARNING session verify: ${msg}`);
		piUI?.notify(
			`Session file issue: ${msg}\n` +
			`cwd=${cwd} realpath=${safeRealpath(cwd)} CLAUDE_CONFIG_DIR=${process.env.CLAUDE_CONFIG_DIR ?? "(unset)"}\n` +
			`Please copy and paste this message into a new issue at https://github.com/elidickinson/pi-claude-bridge/issues/new` +
			(DEBUG ? ` and attach ${DEBUG_LOG_PATH}` : ` (rerun with CLAUDE_BRIDGE_DEBUG=1 to capture a debug log)`),
			"warning",
		);
		diagDump("session_verify_fail", { msg, jsonlPath, cwd, realpath: safeRealpath(cwd), claudeConfigDir: process.env.CLAUDE_CONFIG_DIR ?? null });
	}
}

function safeRealpath(p: string): string {
	try { return realpathSync(p); } catch (e) { return `<failed: ${(e as Error).message}>`; }
}

// Diagnostic snapshot of where a session file was just written. Catches the
// class of bugs where pi writes to ~/.claude/projects/<X> but CC SDK reads
// from ~/.claude/projects/<Y> (symlinks, CLAUDE_CONFIG_DIR, hash mismatch).
function debugSessionPaths(label: string, cwd: string, jsonlPath: string): void {
	const realCwd = safeRealpath(cwd);
	let fileSize: number | null = null;
	let fileExists = false;
	try {
		const st = statSync(jsonlPath);
		fileExists = true;
		fileSize = st.size;
	} catch { /* file may not exist yet */ }
	debug(`${label}: cwd=${cwd}`);
	if (realCwd !== cwd) debug(`${label}: realpath(cwd)=${realCwd} (DIFFERS — symlink-resolved path is what CC SDK uses)`);
	debug(`${label}: jsonlPath=${jsonlPath}`);
	debug(`${label}: fileExists=${fileExists}${fileSize != null ? ` size=${fileSize}` : ""}`);
	debug(`${label}: env.CLAUDE_CONFIG_DIR=${process.env.CLAUDE_CONFIG_DIR ?? "(unset)"} HOME=${process.env.HOME ?? "(unset)"}`);
}

// Two semantic paths:
//   REUSE — pi's history is in sync with the existing sharedSession (or drifted
//     only by the trailing final-assistant message that pi appends after
//     streamSimple returns, which CC's own persisted session already has).
//     Returns the existing sessionId. Keeps CC's prompt cache warm.
//   REBUILD — no session yet, or pi's history has diverged (non-trailing
//     missed messages, e.g. another provider took a turn). Wipes the existing
//     session file (if any) and writes a fresh one containing all prior
//     messages, reusing the same sessionId across rebuilds so UUIDs stay
//     stable for the lifetime of pi's session.
//
// Why a full rebuild rather than patching:
//   Injecting deltas into an existing session creates a branch that CC's
//   --resume doesn't follow (documented attempt prior to this). A complete
//   overwrite at the same path is simpler and correct.
//
// Why reuse the sessionId across rebuilds:
//   CC re-reads the JSONL on every --resume call — no in-process UUID
//   caching. Validated in tests/exp-session-clear.mjs, including the case
//   where CC had appended its own tool_use/tool_result records between
//   rebuilds. Preserving the UUID means stable log correlation across
//   provider switches and no orphaned session files.
//
// Log strings still say "Case 1/2/3/4" so existing diagnostics (int-cache.sh,
// int-session-resume.mjs) keep grepping the same anchors.
export function syncSharedSession(
	messages: Context["messages"],
	cwd: string,
	customToolNameToSdk?: Map<string, string>,
	modelId?: string,
): SyncResult {
	const priorMessages = messages.slice(0, -1); // everything before the new user prompt

	// REUSE path
	if (sharedSession && !sharedSession.needsRebuild) {
		const missed = priorMessages.slice(sharedSession.cursor);
		const trailingAssistantOnly =
			missed.length === 1 && (missed[0] as { role?: string }).role === "assistant";
		if (missed.length === 0 || trailingAssistantOnly) {
			if (trailingAssistantOnly) {
				setSharedSession({ ...sharedSession, cursor: priorMessages.length, cwd });
			}
			debug(`Case 3: ${trailingAssistantOnly ? "advanced cursor past trailing assistant, " : ""}resuming session ${sharedSession.sessionId.slice(0, 8)}, cursor=${sharedSession.cursor}`);
			debug(`syncResult: path=reuse sessionId=${sharedSession.sessionId} cursor=${sharedSession.cursor}`);
			return { sessionId: sharedSession.sessionId };
		}
	}

	// REBUILD path
	if (priorMessages.length === 0) {
		debug(`Case 1: clean start, ${messages.length} total messages`);
		debug(`syncResult: path=clean-start`);
		return { sessionId: null };
	}
	const previousSessionId = sharedSession?.sessionId;
	const previousCursor = sharedSession?.cursor ?? 0;
	// preserveId: rebuild in place (deleteSession + createSession with the
	// existing UUID), so prompt-cache UUIDs stay stable for log correlation
	// and for any tools that key off them. Skipped only when there's a
	// concurrent writer we shouldn't race — see forceRotate docs above.
	const preserveId = previousSessionId !== undefined && !sharedSession?.forceRotate;
	if (preserveId) {
		// Wipe prior jsonl + companion dir (no-op if nothing to wipe).
		deleteSession(previousSessionId!, cwd, process.env.CLAUDE_CONFIG_DIR);
	}
	const session = createSession({
		projectPath: cwd,
		claudeDir: process.env.CLAUDE_CONFIG_DIR,
		...(preserveId ? { sessionId: previousSessionId } : {}),
		...(modelId ? { model: modelId } : {}),
	});
	convertAndImportMessages(session, priorMessages, customToolNameToSdk, cwd);
	session.save();
	verifyWrittenSession(session.jsonlPath, session.sessionId, session.messages.length, cwd);
	setSharedSession({ sessionId: session.sessionId, cursor: priorMessages.length, cwd });
	if (previousSessionId === undefined) {
		debug(`Case 2: first turn with ${priorMessages.length} prior messages → session ${session.sessionId.slice(0, 8)}, ${session.messages.length} records`);
	} else if (preserveId) {
		const missedCount = priorMessages.length - previousCursor;
		debug(`Case 4: ${missedCount} missed messages, ${priorMessages.length} total → rewrote session ${session.sessionId.slice(0, 8)} (same id), ${session.messages.length} records`);
	} else {
		debug(`Case 4 post-abort: ${priorMessages.length} total → new session ${session.sessionId.slice(0, 8)} (was ${previousSessionId.slice(0, 8)}, rotated to avoid race with orphan writer), ${session.messages.length} records`);
	}
	debugSessionPaths(`${session.sessionId.slice(0, 8)}`, cwd, session.jsonlPath);
	debug(`syncResult: path=rebuild sessionId=${session.sessionId} priors=${priorMessages.length} ${previousSessionId === undefined ? "first" : preserveId ? "preserved" : "rotated-post-abort"}`);
	return { sessionId: session.sessionId };
}
