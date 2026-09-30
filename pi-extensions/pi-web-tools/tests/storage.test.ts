import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync, unlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { LANE_FILE_MAX_AGE_MS } from "../scripts/lane-retention.js";
import { beginWebContentSession, endWebContentSession, getWebContent, MEMORY_MAX_CHARS, storeWebContent } from "../src/storage.js";
import { createGetWebContentToolDefinition } from "../src/tools/get-web-content.js";
import { buildWebFetchToolResult } from "../src/tools/web-fetch.js";
import { textOf } from "./fixtures.js";

type Appended = { type: string; data: any };

/** A Pi user directory and a lane working directory, both owned by the case. */
function world(t: { after(fn: () => void): void }) {
	const raw = mkdtempSync(join(tmpdir(), "pi-web-tools-storage-"));
	const root = realpathSync(raw);
	const previous = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(root, "agent");
	const cwd = join(root, "lane");
	mkdirSync(cwd);
	t.after(() => {
		endWebContentSession();
		if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previous;
		rmSync(root, { recursive: true, force: true });
	});
	const appended: Appended[] = [];
	const pi = { appendEntry(type: string, data: unknown) { appended.push({ type, data }); } } as any;
	const ctx = (sessionId: string, laneCwd = cwd) => ({
		cwd: laneCwd,
		sessionManager: {
			getSessionId: () => sessionId,
			getEntries: () => appended.map((entry) => ({ type: "custom", customType: entry.type, data: entry.data })),
		},
	}) as any;
	const contentDir = (sessionId: string) => join(root, "agent", "kendex", "sessions", sessionId, "pi-web-tools", "content");
	return { root, cwd, pi, ctx, appended, contentDir };
}

test("a session record and tool details carry the stored id, never the text", (t) => {
	const w = world(t);
	beginWebContentSession(w.ctx("s1"));
	const stored = storeWebContent(w.pi, { title: "T", url: "https://example.com", content: "Body text" });
	const fetchDetails = buildWebFetchToolResult([stored], "http").details.stored;
	assert.deepEqual({
		record: w.appended.map((entry) => entry.data),
		fetchDetails,
	}, {
		record: [{ id: stored.id, title: "T", url: "https://example.com", createdAt: stored.createdAt, sessionId: "s1", contentLength: 9 }],
		fetchDetails: [{ id: stored.id, title: "T", url: "https://example.com", createdAt: stored.createdAt, sessionId: "s1", contentLength: 9 }],
	});
});

test("get_web_content details carry no text", async (t) => {
	const w = world(t);
	beginWebContentSession(w.ctx("s1"));
	const stored = storeWebContent(w.pi, { title: "T", url: "https://example.com", content: "Body text" });
	const result = await createGetWebContentToolDefinition().execute("call", { id: stored.id });
	assert.equal("content" in result.details, false);
	assert.equal(result.details.contentLength, 9);
});

test("a restarted session reads stored text back from disk by id", (t) => {
	const w = world(t);
	beginWebContentSession(w.ctx("s1"));
	const stored = storeWebContent(w.pi, { title: "T", url: "https://example.com", content: "Body" });
	endWebContentSession();
	assert.deepEqual(getWebContent(stored.id), { status: "unknown" });
	beginWebContentSession(w.ctx("s1"));
	const lookup = getWebContent(stored.id);
	assert.deepEqual(lookup.status === "found" && { content: lookup.item.content, url: lookup.item.url }, { content: "Body", url: "https://example.com" });
});

test("a forked session reads ids its parent stored from the parent's content directory", (t) => {
	const w = world(t);
	beginWebContentSession(w.ctx("parent"));
	const stored = storeWebContent(w.pi, { title: "T", content: "Body" });
	// A fork copies the parent's records into a session with a new id.
	beginWebContentSession(w.ctx("fork"));
	assert.equal(textOf(getWebContent(stored.id)), "Body");
});

for (const row of [
	{ name: "text file removed", legacy: false },
	{ name: "record from an earlier version", legacy: true },
]) {
	test(`get_web_content reports a recorded id whose text is gone, not an unknown id: ${row.name}`, async (t) => {
		const w = world(t);
		beginWebContentSession(w.ctx("s1"));
		let id: string;
		if (row.legacy) {
			id = "web-legacy";
			w.appended.push({ type: "pi-web-tools.content", data: { id, url: "https://example.com", content: "inline", createdAt: "2026-01-01T00:00:00.000Z" } });
		} else {
			id = storeWebContent(w.pi, { title: "T", url: "https://example.com", content: "Body" }).id;
			unlinkSync(join(w.contentDir("s1"), `${id}.json`));
		}
		beginWebContentSession(w.ctx("s1"));
		await assert.rejects(createGetWebContentToolDefinition().execute("call", { id }), /^Error: Stored content text gone: web-.*web_fetch on https:\/\/example\.com again/);
	});
}

test("a new session holds none of the previous session's items", (t) => {
	const w = world(t);
	beginWebContentSession(w.ctx("s1"));
	const stored = storeWebContent(w.pi, { title: "T", content: "Body" });
	w.appended.length = 0;
	beginWebContentSession(w.ctx("s2"));
	assert.deepEqual(getWebContent(stored.id), { status: "unknown" });
});

test("memory holds at most MEMORY_MAX_CHARS of text, dropping the least recently used", (t) => {
	const w = world(t);
	beginWebContentSession(w.ctx("s1"));
	const chunk = "x".repeat(Math.ceil(MEMORY_MAX_CHARS / 4));
	const first = storeWebContent(w.pi, { title: "first", content: chunk });
	const second = storeWebContent(w.pi, { title: "second", content: chunk });
	// Reading the first item makes the second the least recently used.
	getWebContent(first.id);
	for (let i = 0; i < 3; i++) storeWebContent(w.pi, { title: `n${i}`, content: chunk });
	// With its file gone, an item still in memory is still served; a dropped one is not.
	unlinkSync(join(w.contentDir("s1"), `${first.id}.json`));
	unlinkSync(join(w.contentDir("s1"), `${second.id}.json`));
	assert.deepEqual([getWebContent(first.id).status, getWebContent(second.id).status], ["found", "missing"]);
});

test("a lane's stored text is gone once its working directory is gone", (t) => {
	const w = world(t);
	const merged = join(w.root, "merged-worktree");
	mkdirSync(merged);
	beginWebContentSession(w.ctx("merged", merged));
	storeWebContent(w.pi, { title: "T", content: "Body" });
	endWebContentSession();
	rmSync(merged, { recursive: true });
	beginWebContentSession(w.ctx("next"));
	assert.equal(existsSync(w.contentDir("merged")), false);
});

test("a stored file older than five days is removed on the next session start", (t) => {
	const w = world(t);
	beginWebContentSession(w.ctx("s1"));
	const old = storeWebContent(w.pi, { title: "old", content: "old" });
	const fresh = storeWebContent(w.pi, { title: "fresh", content: "fresh" });
	const past = (Date.now() - LANE_FILE_MAX_AGE_MS - 60_000) / 1000;
	utimesSync(join(w.contentDir("s1"), `${old.id}.json`), past, past);
	beginWebContentSession(w.ctx("s2"));
	assert.deepEqual(readdirSync(w.contentDir("s1")).sort(), [".lane-cwd", `${fresh.id}.json`].sort());
});

test("a lane directory with nothing left in it is removed", (t) => {
	const w = world(t);
	const dir = w.contentDir("idle");
	mkdirSync(dir, { recursive: true });
	writeFileSync(join(dir, ".lane-cwd"), w.cwd);
	const past = (Date.now() - LANE_FILE_MAX_AGE_MS - 60_000) / 1000;
	utimesSync(join(dir, ".lane-cwd"), past, past);
	beginWebContentSession(w.ctx("s1"));
	assert.equal(existsSync(dir), false);
});

test("an unreadable sessions root is reported as a prune failure, not thrown", (t) => {
	const w = world(t);
	const root = join(w.root, "agent", "kendex", "sessions");
	mkdirSync(join(root, ".."), { recursive: true });
	writeFileSync(root, "not a directory");
	assert.deepEqual(beginWebContentSession(w.ctx("s1")).failed.map((failure) => failure.path), [root]);
});

test("the extension starts the store on session_start and releases it on session_shutdown", async (t) => {
	const w = world(t);
	const { default: webTools } = await import("../src/index.js");
	const handlers = new Map<string, (event: unknown, ctx: unknown) => unknown>();
	const pi = {
		...w.pi,
		on: (name: string, handler: (event: unknown, ctx: unknown) => unknown) => handlers.set(name, handler),
		registerTool() {},
		registerCommand() {},
		getActiveTools: () => [],
		setActiveTools() {},
	};
	webTools(pi as any);
	const ctx = { ...w.ctx("s1"), hasUI: false, isProjectTrusted: () => true };
	await handlers.get("session_start")!({ type: "session_start" }, ctx);
	const stored = storeWebContent(w.pi, { title: "T", content: "Body" });
	assert.equal(existsSync(join(w.contentDir("s1"), `${stored.id}.json`)), true);
	await handlers.get("session_shutdown")!({ type: "session_shutdown" }, ctx);
	assert.deepEqual(getWebContent(stored.id), { status: "unknown" });
});
