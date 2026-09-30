import { afterEach, beforeEach, expect, jest, setSystemTime, test } from "bun:test";
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
import { sendQolNotification } from "../extensions/qol/notifications.ts";
import { clearPackageConfigCache } from "../extensions/qol/package-config.ts";
import { openQolSessionSearch } from "../extensions/qol/session-search/index.ts";
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
	clearPackageConfigCache();
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
	clearPackageConfigCache();
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

test("only the latest queued resume action stays pending, and session_shutdown drops it", async () => {
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const levels: string[] = [];
	let editor = "";
	// No switchSession, so a chosen resume is queued behind an editor command.
	const ctx = makeCtx({
		cwd: workdir,
		hasUI: true,
		ui: {
			...makeCtx().ui,
			custom: async () => ({ type: "resume", result: searchSession(1, 0) }),
			notify: (_text: string, level: string) => { if (level !== "info") levels.push(level); },
			setEditorText: (text: string) => { editor = text; },
		},
	});
	const queue = async () => {
		await openQolSessionSearch(fake.api, ctx as any);
		return editor.replace("/search:resume-pending ", "");
	};
	const resumePending = (id: string) => fake.commands["search:resume-pending"].handler(id, ctx);
	const first = await queue();
	const second = await queue();
	// A missing action warns; a found one runs and reports resume unavailable here.
	await resumePending(first);
	await resumePending(second);
	const third = await queue();
	await fake.handlers.session_shutdown!({ type: "session_shutdown" }, ctx);
	await resumePending(third);
	expect({ distinct: new Set([first, second, third]).size, levels }).toEqual({ distinct: 3, levels: ["warning", "error", "warning"] });
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

test("opening session search after the index was released shows the overlay before the reload finishes", async () => {
	const order: string[] = [];
	let finishLoad: (sessions: unknown[]) => void = () => {};
	stubSessionManager.listAll = () => new Promise((resolve) => { finishLoad = resolve; });
	let renders = 0;
	let close: (action: unknown) => void = () => {};
	const ctx = makeCtx({
		cwd: workdir,
		hasUI: true,
		ui: {
			...makeCtx().ui,
			custom: (factory: (tui: unknown, theme: unknown, keybindings: unknown, done: (action: unknown) => void) => unknown) => new Promise((resolve) => {
				order.push("overlay");
				close = resolve;
				factory({ requestRender: () => { renders++; }, terminal: { rows: 40 } }, undefined, undefined, resolve);
			}),
		},
	});
	const opened = openQolSessionSearch(makeFakeApi().api, ctx as any);
	await Promise.resolve();
	order.push("load finished");
	finishLoad([{ path: join(workdir, "a.jsonl"), allMessagesText: "text", modified: new Date(0) }]);
	// The overlay is told to redraw once the loaded index reaches it.
	for (let tick = 0; tick < 10 && renders === 0; tick++) await Promise.resolve();
	close({ type: "cancel" });
	await opened;
	expect({ order, renders }).toEqual({ order: ["overlay", "load finished"], renders: 1 });
});

// Dropping an expired cooldown entry changes only memory, which no row can
// see: an expired entry no longer suppresses anything. The rows hold that the
// drop keeps an entry still inside its cooldown, and that session_shutdown
// forgets every entry.
for (const row of [
	{ name: "a key inside its cooldown stays suppressed after another key is sent", shutdown: false, expected: ["A", "B"] },
	{ name: "session_shutdown forgets every cooldown", shutdown: true, expected: ["A", "B", "A"] },
]) {
	test(`notification cooldowns: ${row.name}`, async () => {
		writeFileSync(join(workdir, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: {
			"@vanillagreen/pi-qol": { "notification.bell": false, "notification.native": false, "notification.piUi": true, "notification.cooldownSeconds": 8 },
		} } } }));
		clearPackageConfigCache();
		const fake = makeFakeApi();
		qolDefault(fake.api);
		const sent: string[] = [];
		// Every tmux read fails, so delivery marks nothing; the rows read only the Pi UI channel.
		const tmuxAbsent = { exec: async () => ({ code: 1, stdout: "", stderr: "", killed: false }) };
		const ctx = makeCtx({ cwd: workdir, hasUI: true, ui: { ...makeCtx().ui, notify: (text: string) => { sent.push(text); } } });
		try {
			setSystemTime(new Date(1_000_000));
			await sendQolNotification(tmuxAbsent, ctx as any, "test", "A", "info", "A");
			setSystemTime(new Date(1_001_000));
			await sendQolNotification(tmuxAbsent, ctx as any, "test", "B", "info", "B");
			if (row.shutdown) await fake.handlers.session_shutdown!({ type: "session_shutdown" }, ctx);
			setSystemTime(new Date(1_002_000));
			await sendQolNotification(tmuxAbsent, ctx as any, "test", "A", "info", "A");
		} finally {
			setSystemTime();
			if (!row.shutdown) await fake.handlers.session_shutdown!({ type: "session_shutdown" }, ctx);
		}
		expect(sent).toEqual(row.expected);
	});
}

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

test("thinking durations are bounded and finished labels are released at agent_end, running ones kept", async () => {
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
	// One block still running when the agent ends keeps its ticking label.
	const running = { timestamp: 1000 };
	fake.handlers.message_update!({ assistantMessageEvent: { type: "thinking_start", partial: running, contentIndex: 0 } }, ctx);
	store.labels.set("1000:0", { setText() {} } as any);
	expect(store.durations.size).toBe(THINKING_TIMER_MAX_DURATIONS);
	expect(store.labels.size).toBe(1001);
	fake.handlers.agent_end!({ messages: [], type: "agent_end" }, { ...ctx, hasUI: false });
	expect([...store.labels.keys()]).toEqual(["1000:0"]);
	await fake.handlers.session_shutdown!({ type: "session_shutdown" }, { ...ctx, hasUI: false });
});
