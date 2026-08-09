// End-to-end wiring test: loads the qol extension against a fake Pi
// event bus, fires `agent_end` with over-budget usage, and asserts
// ctx.compact is invoked with the budget-guard sentinel. Guards against a
// regression where the budget guard call could be removed from the
// agent_end handler without any unit test catching it.

import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import qolDefault from "../extensions/qol.ts";
import { QOL_BUDGET_GUARD_SENTINEL } from "../extensions/qol/budget-guard.ts";

interface CompactCall { customInstructions?: string; onComplete?: () => void; onError?: (e: Error) => void }

interface CapturedHandlers {
	[name: string]: (event: any, ctx: any) => any;
}

interface FakeApi {
	handlers: CapturedHandlers;
	eventBusHandlers: Record<string, (data: any) => void>;
	commands: Record<string, any>;
	shortcuts: Record<string, any>;
	renderers: Record<string, any>;
	api: any;
}

function makeFakeApi(): FakeApi {
	const handlers: CapturedHandlers = {};
	const eventBusHandlers: Record<string, (data: any) => void> = {};
	const commands: Record<string, any> = {};
	const shortcuts: Record<string, any> = {};
	const renderers: Record<string, any> = {};
	const api: any = {
		events: {
			on(name: string, handler: (data: any) => void) {
				eventBusHandlers[name] = handler;
			},
		},
		getActiveTools: () => [],
		getAllTools: () => [],
		getCommands: () => [],
		getSessionName: () => undefined,
		getThinkingLevel: () => "off",
		on(name: string, handler: (event: any, ctx: any) => any) {
			handlers[name] = handler;
		},
		registerCommand(name: string, opts: any) {
			commands[name] = opts;
		},
		registerMessageRenderer(type: string, renderer: any) {
			renderers[type] = renderer;
		},
		registerShortcut(key: string, opts: any) {
			shortcuts[key] = opts;
		},
		sendMessage() {},
		setSessionName() {},
	};
	return { api, commands, eventBusHandlers, handlers, renderers, shortcuts };
}

function makeCtx(overrides: Partial<any> = {}) {
	return {
		abort() {},
		compact: mock(() => {}),
		cwd: process.env.PI_CODING_AGENT_DIR ?? "/tmp",
		getContextUsage: () => ({ contextWindow: 200_000, percent: 90, tokens: 180_000 }),
		getSystemPrompt: () => "",
		hasPendingMessages: () => false,
		hasUI: false,
		isIdle: () => true,
		model: undefined,
		modelRegistry: { find: () => undefined, getApiKeyAndHeaders: async () => ({ apiKey: "k", ok: true }) },
		sessionManager: {
			getBranch: () => [],
			getSessionFile: () => undefined,
			getSessionId: () => "test-session",
		},
		shutdown() {},
		signal: undefined,
		ui: {
			notify() {},
			setStatus() {},
		},
		...overrides,
	};
}

function startSession(fake: FakeApi, ctx: any) {
	fake.handlers.session_start!({ reason: "startup", type: "session_start" }, ctx);
}

let workdir = "";
const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
const originalHome = process.env.HOME;

beforeEach(() => {
	workdir = mkdtempSync(join(tmpdir(), "pi-qol-agent-end-"));
	process.env.PI_CODING_AGENT_DIR = workdir;
	process.env.HOME = workdir;
});

afterEach(() => {
	if (workdir) rmSync(workdir, { force: true, recursive: true });
	if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
	if (originalHome === undefined) delete process.env.HOME;
	else process.env.HOME = originalHome;
});

test("qol(pi) registers an agent_end handler", () => {
	const fake = makeFakeApi();
	qolDefault(fake.api);
	expect(typeof fake.handlers.agent_end).toBe("function");
	expect(typeof fake.handlers.agent_settled).toBe("function");
});

test("agent_settled waits for staged compaction completion", async () => {
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const agentEndHandler = fake.handlers.agent_end;
	const agentSettledHandler = fake.handlers.agent_settled;
	expect(agentEndHandler).toBeDefined();
	expect(agentSettledHandler).toBeDefined();
	const ctx = makeCtx();
	startSession(fake, ctx);
	agentEndHandler!({ messages: [], type: "agent_end" }, ctx);
	expect(ctx.compact.mock.calls.length).toBe(0);
	const settlement = agentSettledHandler!({ type: "agent_settled" }, ctx) as Promise<void>;
	expect(ctx.compact.mock.calls.length).toBe(1);
	const arg = ctx.compact.mock.calls[0]?.[0] as CompactCall;
	expect(arg.customInstructions ?? "").toContain(QOL_BUDGET_GUARD_SENTINEL);
	let settled = false;
	void settlement.then(() => { settled = true; });
	await Promise.resolve();
	expect(settled).toBe(false);
	arg.onComplete?.();
	await settlement;
	expect(settled).toBe(true);
});

test("agent_settled waits for staged compaction error", async () => {
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const ctx = makeCtx();
	startSession(fake, ctx);
	fake.handlers.agent_end!({ messages: [], type: "agent_end" }, ctx);
	const settlement = fake.handlers.agent_settled!({ type: "agent_settled" }, ctx) as Promise<void>;
	let settled = false;
	void settlement.then(() => { settled = true; });
	await Promise.resolve();
	expect(settled).toBe(false);
	const arg = ctx.compact.mock.calls[0]?.[0] as CompactCall;
	arg.onError?.(new Error("model down"));
	await settlement;
	expect(settled).toBe(true);
});

test("agent_end does not fire the budget guard when usage is below threshold", async () => {
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const handler = fake.handlers.agent_end;
	const ctx = makeCtx({
		getContextUsage: () => ({ contextWindow: 200_000, percent: 30, tokens: 60_000 }),
	});
	startSession(fake, ctx);
	handler!({ messages: [], type: "agent_end" }, ctx);
	await fake.handlers.agent_settled!({ type: "agent_settled" }, ctx);
	expect(ctx.compact.mock.calls.length).toBe(0);
});

test("agent_end deduplicates while compaction is pending or in flight", async () => {
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const agentEndHandler = fake.handlers.agent_end;
	const agentSettledHandler = fake.handlers.agent_settled;
	const ctx = makeCtx();
	startSession(fake, ctx);
	agentEndHandler!({ messages: [], type: "agent_end" }, ctx);
	agentEndHandler!({ messages: [], type: "agent_end" }, ctx);
	expect(ctx.compact.mock.calls.length).toBe(0);
	const settlement = agentSettledHandler!({ type: "agent_settled" }, ctx) as Promise<void>;
	await agentSettledHandler!({ type: "agent_settled" }, ctx);
	expect(ctx.compact.mock.calls.length).toBe(1);
	const arg = ctx.compact.mock.calls[0]?.[0] as CompactCall;
	arg.onComplete?.();
	await settlement;
});

test("agent_end does not re-fire the same trigger after session_compact", async () => {
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const agentEndHandler = fake.handlers.agent_end;
	const agentSettledHandler = fake.handlers.agent_settled;
	const sessionCompactHandler = fake.handlers.session_compact;
	expect(sessionCompactHandler).toBeDefined();
	const ctx = makeCtx();
	startSession(fake, ctx);
	agentEndHandler!({ messages: [], type: "agent_end" }, ctx);
	const settlement = agentSettledHandler!({ type: "agent_settled" }, ctx) as Promise<void>;
	expect(ctx.compact.mock.calls.length).toBe(1);
	// Simulate Pi notifying us that compaction finished.
	sessionCompactHandler!({ compactionEntry: {}, fromExtension: true, type: "session_compact" }, ctx);
	const arg = ctx.compact.mock.calls[0]?.[0] as CompactCall;
	arg.onComplete?.();
	await settlement;
	agentEndHandler!({ messages: [], type: "agent_end" }, ctx);
	await agentSettledHandler!({ type: "agent_settled" }, ctx);
	expect(ctx.compact.mock.calls.length).toBe(1);
});

test("Pi auto-compaction between agent_end and agent_settled resolves without dispatch", async () => {
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const agentEndHandler = fake.handlers.agent_end;
	const agentSettledHandler = fake.handlers.agent_settled;
	const sessionCompactHandler = fake.handlers.session_compact;
	const ctx = makeCtx();
	startSession(fake, ctx);

	// Canonical Pi ordering: extension agent_end handlers run first, core then
	// performs its post-agent compaction check, emits session_compact, and only
	// after that emits agent_settled.
	agentEndHandler!({ messages: [], type: "agent_end" }, ctx);
	sessionCompactHandler!({ compactionEntry: {}, fromExtension: false, reason: "threshold", type: "session_compact" }, ctx);
	await agentSettledHandler!({ type: "agent_settled" }, ctx);

	expect(ctx.compact.mock.calls.length).toBe(0);
	// Fake usage remains in the same trigger bucket. A later agent cycle stays
	// suppressed until usage drops below threshold or advances to a new key.
	agentEndHandler!({ messages: [], type: "agent_end" }, ctx);
	await agentSettledHandler!({ type: "agent_settled" }, ctx);
	expect(ctx.compact.mock.calls.length).toBe(0);
});

test("agent_end notifies when ctx.compact is unavailable rather than poisoning future retries", async () => {
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const handler = fake.handlers.agent_end;
	const ctx = makeCtx({ compact: undefined });
	startSession(fake, ctx);
	// First settled cycle: no ctx.compact, should not throw or poison the key.
	handler!({ messages: [], type: "agent_end" }, ctx);
	await fake.handlers.agent_settled!({ type: "agent_settled" }, ctx);
	// Now provide ctx.compact and fire again - guard should still attempt
	// because the previous attempt didn't poison the crossing key.
	const compact = mock(() => {});
	const ctxWithCompact = makeCtx({ compact, sessionManager: ctx.sessionManager });
	handler!({ messages: [], type: "agent_end" }, ctxWithCompact);
	const settlement = fake.handlers.agent_settled!({ type: "agent_settled" }, ctxWithCompact) as Promise<void>;
	expect(compact.mock.calls.length).toBe(1);
	const arg = compact.mock.calls[0]?.[0] as CompactCall;
	arg.onComplete?.();
	await settlement;
});

test("late session_compact from a reset session cannot consume the new session trigger", async () => {
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const ctxA = makeCtx({
		sessionManager: { getBranch: () => [], getSessionFile: () => undefined, getSessionId: () => "session-a" },
	});
	const ctxB = makeCtx({
		sessionManager: { getBranch: () => [], getSessionFile: () => undefined, getSessionId: () => "session-b" },
	});

	startSession(fake, ctxA);
	fake.handlers.agent_end!({ messages: [], type: "agent_end" }, ctxA);
	const settlementA = fake.handlers.agent_settled!({ type: "agent_settled" }, ctxA) as Promise<void>;
	expect(ctxA.compact.mock.calls.length).toBe(1);

	startSession(fake, ctxB);
	await settlementA;
	fake.handlers.agent_end!({ messages: [], type: "agent_end" }, ctxB);
	fake.handlers.session_compact!({ compactionEntry: {}, fromExtension: true, type: "session_compact" }, ctxA);
	const settlementB = fake.handlers.agent_settled!({ type: "agent_settled" }, ctxB) as Promise<void>;

	expect(ctxB.compact.mock.calls.length).toBe(1);
	const compactB = ctxB.compact.mock.calls[0]?.[0] as CompactCall;
	compactB.onComplete?.();
	await settlementB;
});

test("late session_compact cannot make a new-session Already compacted error benign", async () => {
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const ctxA = makeCtx({
		sessionManager: { getBranch: () => [], getSessionFile: () => undefined, getSessionId: () => "session-a" },
	});
	const ctxB = makeCtx({
		sessionManager: { getBranch: () => [], getSessionFile: () => undefined, getSessionId: () => "session-b" },
	});

	startSession(fake, ctxA);
	fake.handlers.agent_end!({ messages: [], type: "agent_end" }, ctxA);
	const settlementA = fake.handlers.agent_settled!({ type: "agent_settled" }, ctxA) as Promise<void>;
	startSession(fake, ctxB);
	await settlementA;

	fake.handlers.agent_end!({ messages: [], type: "agent_end" }, ctxB);
	const firstSettlementB = fake.handlers.agent_settled!({ type: "agent_settled" }, ctxB) as Promise<void>;
	expect(ctxB.compact.mock.calls.length).toBe(1);
	fake.handlers.session_compact!({ compactionEntry: {}, fromExtension: true, type: "session_compact" }, ctxA);
	const firstCompactB = ctxB.compact.mock.calls[0]?.[0] as CompactCall;
	firstCompactB.onError?.(new Error("Already compacted"));
	await firstSettlementB;

	fake.handlers.agent_end!({ messages: [], type: "agent_end" }, ctxB);
	const retrySettlementB = fake.handlers.agent_settled!({ type: "agent_settled" }, ctxB) as Promise<void>;
	expect(ctxB.compact.mock.calls.length).toBe(2);
	const retryCompactB = ctxB.compact.mock.calls[1]?.[0] as CompactCall;
	retryCompactB.onComplete?.();
	await retrySettlementB;
});
