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
});

test("agent_end fires the budget guard with the QOL sentinel when over budget", () => {
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const handler = fake.handlers.agent_end;
	expect(handler).toBeDefined();
	const ctx = makeCtx();
	handler!({ messages: [], type: "agent_end" }, ctx);
	expect(ctx.compact.mock.calls.length).toBe(1);
	const arg = ctx.compact.mock.calls[0]?.[0] as CompactCall;
	expect(arg.customInstructions ?? "").toContain(QOL_BUDGET_GUARD_SENTINEL);
});

test("agent_end does not fire the budget guard when usage is below threshold", () => {
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const handler = fake.handlers.agent_end;
	const ctx = makeCtx({
		getContextUsage: () => ({ contextWindow: 200_000, percent: 30, tokens: 60_000 }),
	});
	handler!({ messages: [], type: "agent_end" }, ctx);
	expect(ctx.compact.mock.calls.length).toBe(0);
});

test("agent_end deduplicates while compaction is still in flight", () => {
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const handler = fake.handlers.agent_end;
	const ctx = makeCtx();
	handler!({ messages: [], type: "agent_end" }, ctx);
	handler!({ messages: [], type: "agent_end" }, ctx);
	expect(ctx.compact.mock.calls.length).toBe(1);
});

test("agent_end re-fires after the previous compaction completed via session_compact", () => {
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const handler = fake.handlers.agent_end;
	const sessionCompactHandler = fake.handlers.session_compact;
	expect(sessionCompactHandler).toBeDefined();
	const ctx = makeCtx();
	handler!({ messages: [], type: "agent_end" }, ctx);
	expect(ctx.compact.mock.calls.length).toBe(1);
	// Simulate Pi notifying us that compaction finished.
	sessionCompactHandler!({ compactionEntry: {}, fromExtension: true, type: "session_compact" }, ctx);
	handler!({ messages: [], type: "agent_end" }, ctx);
	expect(ctx.compact.mock.calls.length).toBe(2);
});

test("agent_end notifies when ctx.compact is unavailable rather than poisoning future retries", () => {
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const handler = fake.handlers.agent_end;
	const ctx = makeCtx({ compact: undefined });
	// First call: no ctx.compact, should not throw.
	handler!({ messages: [], type: "agent_end" }, ctx);
	// Now provide ctx.compact and fire again - guard should still attempt
	// because the previous attempt didn't poison the crossing key.
	const compact = mock(() => {});
	const ctxWithCompact = makeCtx({ compact });
	handler!({ messages: [], type: "agent_end" }, ctxWithCompact);
	expect(compact.mock.calls.length).toBe(1);
});
