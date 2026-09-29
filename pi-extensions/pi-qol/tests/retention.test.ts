import { afterEach, beforeEach, expect, jest, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";

import qolDefault from "../extensions/qol.ts";
import {
	DEFAULT_SESSION_SEARCH_CACHE_TTL_SECONDS,
	SESSION_SEARCH_TEXT_MAX_CHARS,
	SESSION_SEARCH_TEXT_MAX_CHARS_PER_SESSION,
	SESSION_SEARCH_USER_MESSAGES_MAX_SESSIONS,
	THINKING_TIMER_MAX_DURATIONS,
} from "../extensions/qol/constants.ts";
import { capSessionSearchText, refreshQolSessionSearchCache, releaseQolSessionSearchCache, sessionUserMessages } from "../extensions/qol/session-search/cache.ts";
import { getThinkingTimerStore } from "../extensions/qol/thinking-timer.ts";
import type { QolSessionSearchSession } from "../extensions/qol/session-search/types.ts";
import { makeCtx, makeFakeApi } from "./fake-pi.ts";

let workdir = "";
let listAllCalls = 0;
const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
const originalHome = process.env.HOME;
const stubSessionManager = SessionManager as unknown as { listAll?: () => Promise<unknown[]> };

beforeEach(() => {
	workdir = mkdtempSync(join(tmpdir(), "pi-qol-retention-"));
	process.env.PI_CODING_AGENT_DIR = workdir;
	process.env.HOME = workdir;
	listAllCalls = 0;
	stubSessionManager.listAll = async () => {
		listAllCalls++;
		return [{ path: join(workdir, "a.jsonl"), allMessagesText: "text", modified: new Date(0) }];
	};
	releaseQolSessionSearchCache();
});

afterEach(() => {
	jest.useRealTimers();
	releaseQolSessionSearchCache();
	delete stubSessionManager.listAll;
	rmSync(workdir, { force: true, recursive: true });
	if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
	if (originalHome === undefined) delete process.env.HOME;
	else process.env.HOME = originalHome;
});

test("a headless session loads no session-search index at startup, and shutdown releases a loaded one", async () => {
	jest.useFakeTimers();
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const ctx = makeCtx({ cwd: workdir, hasUI: false });
	fake.handlers.session_start!({ reason: "startup", type: "session_start" }, ctx);
	jest.advanceTimersByTime(10_000);
	await Promise.resolve();
	expect(listAllCalls).toBe(0);
	await refreshQolSessionSearchCache(ctx as any);
	await fake.handlers.session_shutdown!({ type: "session_shutdown" }, ctx);
	await refreshQolSessionSearchCache(ctx as any);
	expect(listAllCalls).toBe(2);
});

test("the loaded index and parsed prompts are released after the default TTL and on release", async () => {
	jest.useFakeTimers();
	const ctx = makeCtx({ cwd: workdir });
	const prompts = join(workdir, "prompts.jsonl");
	const line = (text: string) => JSON.stringify({ type: "message", message: { role: "user", content: text } });
	writeFileSync(prompts, line("before"));
	await refreshQolSessionSearchCache(ctx as any);
	await refreshQolSessionSearchCache(ctx as any);
	sessionUserMessages(prompts);
	expect(listAllCalls).toBe(1);
	// The timer drops the parsed prompts with the index, with no search to trigger it.
	writeFileSync(prompts, line("after"));
	jest.advanceTimersByTime(DEFAULT_SESSION_SEARCH_CACHE_TTL_SECONDS * 1000);
	expect(sessionUserMessages(prompts)[0]?.text).toBe("after");
	await refreshQolSessionSearchCache(ctx as any);
	expect(listAllCalls).toBe(2);
	releaseQolSessionSearchCache();
	await refreshQolSessionSearchCache(ctx as any);
	expect(listAllCalls).toBe(3);
});

function searchSession(index: number, chars: number): QolSessionSearchSession {
	return {
		allMessagesText: "x".repeat(chars),
		created: new Date(index),
		cwd: "/w",
		firstMessage: "first",
		id: `s${index}`,
		messageCount: 1,
		modified: new Date(index),
		path: `/w/s${index}.jsonl`,
	};
}

test("the index keeps each session's text to the per-session cap and the sum to the index cap, newest first", () => {
	const count = Math.ceil(SESSION_SEARCH_TEXT_MAX_CHARS / SESSION_SEARCH_TEXT_MAX_CHARS_PER_SESSION) + 10;
	const sessions = capSessionSearchText(Array.from({ length: count }, (_, i) => searchSession(i, SESSION_SEARCH_TEXT_MAX_CHARS_PER_SESSION * 2)));
	const kept = sessions.map((session) => session.allMessagesText.length);
	expect(Math.max(...kept)).toBe(SESSION_SEARCH_TEXT_MAX_CHARS_PER_SESSION);
	expect(kept.reduce((sum, chars) => sum + chars, 0)).toBe(SESSION_SEARCH_TEXT_MAX_CHARS);
	expect([kept[0], kept[count - 1]]).toEqual([0, SESSION_SEARCH_TEXT_MAX_CHARS_PER_SESSION]);
});

test("parsed prompts are kept for a bounded number of sessions", () => {
	const line = (text: string) => JSON.stringify({ type: "message", message: { role: "user", content: text } });
	const paths = Array.from({ length: SESSION_SEARCH_USER_MESSAGES_MAX_SESSIONS + 1 }, (_, i) => {
		const path = join(workdir, `s${i}.jsonl`);
		writeFileSync(path, line(`before ${i}`));
		sessionUserMessages(path);
		return path;
	});
	// The oldest entry was dropped, so its file is read again; the newest is still cached.
	writeFileSync(paths[0]!, line("after 0"));
	writeFileSync(paths.at(-1)!, line("after last"));
	expect([sessionUserMessages(paths[0]!)[0]?.text, sessionUserMessages(paths.at(-1)!)[0]?.text]).toEqual(["after 0", `before ${SESSION_SEARCH_USER_MESSAGES_MAX_SESSIONS}`]);
});

test("thinking durations are bounded and finished labels are released at agent_end", async () => {
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const ctx = makeCtx({ cwd: workdir, hasUI: true, ui: { ...makeCtx().ui, theme: undefined } });
	const store = getThinkingTimerStore()!;
	for (let i = 0; i < 1000; i++) {
		const partial = { timestamp: i };
		fake.handlers.message_update!({ assistantMessageEvent: { type: "thinking_start", partial, contentIndex: 0 } }, ctx);
		store.labels.set(`${i}:0`, { setText() {} } as any);
		fake.handlers.message_update!({ assistantMessageEvent: { type: "thinking_end", partial, contentIndex: 0 } }, ctx);
	}
	expect(store.durations.size).toBe(THINKING_TIMER_MAX_DURATIONS);
	expect(store.labels.size).toBe(1000);
	fake.handlers.agent_end!({ messages: [], type: "agent_end" }, { ...ctx, hasUI: false });
	expect(store.labels.size).toBe(0);
	await fake.handlers.session_shutdown!({ type: "session_shutdown" }, { ...ctx, hasUI: false });
});
