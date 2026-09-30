import { readFileSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { openLaneDir, pruneLanes, type LanePruneResult } from "../scripts/lane-retention.js";
import { piUserDir } from "./package-config.js";

export interface StoredWebContent {
	id: string;
	title?: string;
	url?: string;
	content: string;
	metadata?: Record<string, unknown>;
	createdAt: string;
	/** The session whose content directory holds the text. A forked session
	 *  copies the parent's records, so its ids still name the parent's files. */
	sessionId?: string;
}

/** A stored item without its text: what a session record and a tool's details
 *  carry, so the text is held once, in the lane's content directory. */
export interface StoredWebContentRef {
	id: string;
	title?: string;
	url?: string;
	metadata?: Record<string, unknown>;
	createdAt: string;
	sessionId?: string;
	contentLength: number;
}

const CUSTOM_TYPE = "pi-web-tools.content";
const PACKAGE_FOLDER = "pi-web-tools";
const CONTENT_FOLDER = "content";

/** Characters of stored text held in memory; past it the least recently used
 *  items are dropped, and a later read loads them from disk. */
export const MEMORY_MAX_CHARS = 8 * 1024 * 1024;

interface SessionStore {
	/** The session whose lane content directory new text goes to; undefined
	 *  before a session starts. */
	sessionId?: string;
	cwd?: string;
	refs: Map<string, StoredWebContentRef>;
	/** Stored items in least-recently-used-first order. */
	memory: Map<string, StoredWebContent>;
	memoryChars: number;
}

function emptyStore(sessionId?: string, cwd?: string): SessionStore {
	return { sessionId, cwd, refs: new Map(), memory: new Map(), memoryChars: 0 };
}

let store = emptyStore();

function safeFileName(value: string): string {
	return value.replace(/[^\w.-]+/g, "_");
}

function sessionIdForContext(ctx: ExtensionContext): string {
	const id = ctx.sessionManager?.getSessionId?.();
	if (id && id.trim()) return id;
	const file = ctx.sessionManager?.getSessionFile?.();
	if (file) return basename(file, ".jsonl");
	return `ephemeral-${process.pid}`;
}

function sessionsRoot(): string {
	return join(piUserDir(), "kendex", "sessions");
}

function contentDir(sessionId: string): string {
	return join(sessionsRoot(), safeFileName(sessionId), PACKAGE_FOLDER, CONTENT_FOLDER);
}

function contentPath(sessionId: string, id: string): string {
	return join(contentDir(sessionId), `${safeFileName(id)}.json`);
}

export function makeContentId(prefix = "web"): string {
	return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

export function toStoredRef(item: StoredWebContent): StoredWebContentRef {
	const { content, ...rest } = item;
	return { ...rest, contentLength: content.length };
}

function remember(item: StoredWebContent): void {
	const previous = store.memory.get(item.id);
	if (previous) {
		store.memory.delete(item.id);
		store.memoryChars -= previous.content.length;
	}
	store.memory.set(item.id, item);
	store.memoryChars += item.content.length;
	for (const [id, oldest] of store.memory) {
		if (store.memoryChars <= MEMORY_MAX_CHARS || id === item.id) break;
		store.memory.delete(id);
		store.memoryChars -= oldest.content.length;
	}
}

/**
 * Start the store for the session in `ctx`: drop every item the previous
 * session held, apply the lane retention rule to the content directories of
 * all sessions, then read this session's stored ids back from its records.
 * The text itself stays on disk until an id is read.
 */
export function beginWebContentSession(ctx: ExtensionContext): LanePruneResult {
	const pruned = pruneLanes(sessionsRoot(), [PACKAGE_FOLDER, CONTENT_FOLDER]);
	store = emptyStore(sessionIdForContext(ctx), ctx.cwd);
	for (const entry of ctx.sessionManager?.getEntries?.() ?? []) {
		if ((entry as any).type !== "custom" || (entry as any).customType !== CUSTOM_TYPE) continue;
		const ref = (entry as any).data as StoredWebContentRef | undefined;
		if (typeof ref?.id === "string") store.refs.set(ref.id, ref);
	}
	return pruned;
}

/** Release every stored item held in memory; the session is over. */
export function endWebContentSession(): void {
	store = emptyStore();
}

export function storeWebContent(pi: ExtensionAPI, item: Omit<StoredWebContent, "id" | "createdAt" | "sessionId"> & { id?: string }): StoredWebContent {
	const stored: StoredWebContent = { ...item, id: item.id ?? makeContentId(), createdAt: new Date().toISOString(), sessionId: store.sessionId };
	if (store.sessionId) {
		openLaneDir(contentDir(store.sessionId), store.cwd ?? process.cwd());
		writeFileSync(contentPath(store.sessionId, stored.id), JSON.stringify(stored), { mode: 0o600 });
	}
	const ref = toStoredRef(stored);
	store.refs.set(stored.id, ref);
	remember(stored);
	pi.appendEntry?.(CUSTOM_TYPE, ref);
	return stored;
}

/** What a lookup of a stored id found. `unknown`: this session never recorded
 *  the id. `missing`: the session recorded it, but its text is no longer on
 *  disk (the retention rule removed it, or an earlier version kept the text
 *  in the session record instead). */
export type WebContentLookup =
	| { status: "found"; item: StoredWebContent }
	| { status: "unknown" }
	| { status: "missing"; ref: StoredWebContentRef };

/** The stored item `id`, from memory or from the content directory of the
 *  session that stored it. */
export function getWebContent(id: string): WebContentLookup {
	const held = store.memory.get(id);
	if (held) {
		remember(held);
		return { status: "found", item: held };
	}
	const ref = store.refs.get(id);
	if (!ref) return { status: "unknown" };
	if (!ref.sessionId) return { status: "missing", ref };
	let raw: string;
	try {
		raw = readFileSync(contentPath(ref.sessionId, id), "utf8");
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return { status: "missing", ref };
		throw error;
	}
	const item = JSON.parse(raw) as StoredWebContent;
	remember(item);
	return { status: "found", item };
}

