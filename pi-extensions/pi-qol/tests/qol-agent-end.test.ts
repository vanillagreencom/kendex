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
		compact: mock((_options: CompactCall) => {}),
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
			notify: mock((_message: string, _level: string) => {}),
			setEditorComponent() {},
			setHeader() {},
			setFooter() {},
			setStatus() {},
			setWidget() {},
		},
		...overrides,
	};
}

type Context = ReturnType<typeof makeCtx>;
const startedSessions: Array<{ fake: FakeApi; ctx: Context }> = [];

function startSession(fake: FakeApi, ctx: Context): void {
	startedSessions.push({ fake, ctx });
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

afterEach(async () => {
	const failures: unknown[] = [];
	try {
		for (const { fake, ctx } of startedSessions.splice(0).reverse()) {
			try {
				await fake.handlers.session_shutdown!({ type: "session_shutdown" }, ctx);
			} catch (error) {
				failures.push(error);
			}
		}
	} finally {
		if (workdir) rmSync(workdir, { force: true, recursive: true });
		if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
		if (originalHome === undefined) delete process.env.HOME;
		else process.env.HOME = originalHome;
	}
	if (failures.length) throw new AggregateError(failures, "session_shutdown failed");
});

interface World {
	fake: FakeApi;
	ctx: Context;
	settlement?: Promise<void>;
	settled: boolean;
	previousCtx?: Context;
}

function agentEnd(h: World): number {
	h.fake.handlers.agent_end!({ messages: [], type: "agent_end" }, h.ctx);
	return h.ctx.compact?.mock.calls.length ?? 0;
}

async function agentSettled(h: World) {
	h.settled = false;
	h.settlement = h.fake.handlers.agent_settled!({ type: "agent_settled" }, h.ctx) as Promise<void>;
	void h.settlement.then(() => { h.settled = true; });
	await Promise.resolve();
	return { calls: h.ctx.compact?.mock.calls.length ?? 0, settled: h.settled };
}

async function completeCompaction(h: World): Promise<boolean> {
	const call = h.ctx.compact.mock.calls.at(-1)?.[0] as CompactCall | undefined;
	call?.onComplete?.();
	await h.settlement;
	return h.settled;
}

function sessionCompact(h: World, fromExtension = true, ctx = h.ctx): void {
	h.fake.handlers.session_compact!({ compactionEntry: {}, fromExtension, reason: "threshold", type: "session_compact" }, ctx);
}

async function switchSession(h: World): Promise<boolean> {
	h.previousCtx = h.ctx;
	h.ctx = makeCtx({
		sessionManager: { getBranch: () => [], getSessionFile: () => undefined, getSessionId: () => "session-b" },
	});
	startSession(h.fake, h.ctx);
	await h.settlement;
	return h.settled;
}

const rows: Array<{
	name: string;
	start?: boolean;
	setup?: (h: World) => void;
	actions: Array<(h: World) => unknown | Promise<unknown>>;
	expected: unknown[];
}> = [
	{
		name: "registers end, settled and compact handlers",
		start: false,
		actions: [({ fake }) => [typeof fake.handlers.agent_end, typeof fake.handlers.agent_settled, typeof fake.handlers.session_compact]],
		expected: [["function", "function", "function"]],
	},
	{
		name: "settlement waits for compaction completion",
		actions: [
			agentEnd,
			async (h) => ({
				...await agentSettled(h),
				instructions: (h.ctx.compact.mock.calls[0]?.[0] as CompactCall | undefined)?.customInstructions,
			}),
			completeCompaction,
		],
		expected: [0, { calls: 1, settled: false, instructions: expect.stringContaining(QOL_BUDGET_GUARD_SENTINEL) }, true],
	},
	{
		name: "settlement waits for compaction error",
		actions: [
			agentEnd,
			agentSettled,
			async (h) => {
				const call = h.ctx.compact.mock.calls[0]?.[0] as CompactCall;
				call.onError?.(new Error("model down"));
				await h.settlement;
				return h.settled;
			},
		],
		expected: [0, { calls: 1, settled: false }, true],
	},
	{
		name: "below-threshold usage does not dispatch",
		setup: (h) => { h.ctx.getContextUsage = () => ({ contextWindow: 200_000, percent: 30, tokens: 60_000 }); },
		actions: [
			agentEnd,
			async (h) => {
				await h.fake.handlers.agent_settled!({ type: "agent_settled" }, h.ctx);
				return h.ctx.compact.mock.calls.length;
			},
		],
		expected: [0, 0],
	},
	{
		name: "repeated end and settled events deduplicate pending and in-flight work",
		actions: [
			agentEnd,
			agentEnd,
			agentSettled,
			async (h) => {
				await h.fake.handlers.agent_settled!({ type: "agent_settled" }, h.ctx);
				return h.ctx.compact.mock.calls.length;
			},
			completeCompaction,
		],
		expected: [0, 0, { calls: 1, settled: false }, 1, true],
	},
	{
		name: "session_compact suppresses the same trigger after completion",
		actions: [
			agentEnd,
			agentSettled,
			async (h) => {
				sessionCompact(h);
				return completeCompaction(h);
			},
			agentEnd,
			async (h) => {
				await h.fake.handlers.agent_settled!({ type: "agent_settled" }, h.ctx);
				return h.ctx.compact.mock.calls.length;
			},
		],
		expected: [0, { calls: 1, settled: false }, true, 1, 1],
	},
	{
		name: "Pi auto-compaction between end and settled suppresses dispatch and the next cycle",
		actions: [
			agentEnd,
			async (h) => {
				sessionCompact(h, false);
				await h.fake.handlers.agent_settled!({ type: "agent_settled" }, h.ctx);
				return h.ctx.compact.mock.calls.length;
			},
			agentEnd,
			async (h) => {
				await h.fake.handlers.agent_settled!({ type: "agent_settled" }, h.ctx);
				return h.ctx.compact.mock.calls.length;
			},
		],
		expected: [0, 0, 0, 0],
	},
	{
		name: "missing compact function warns and allows retry",
		setup: (h) => { h.ctx.compact = undefined; },
		actions: [
			agentEnd,
			async (h) => {
				h.ctx.hasUI = true;
				try {
					await h.fake.handlers.agent_settled!({ type: "agent_settled" }, h.ctx);
					return h.ctx.ui.notify.mock.calls.map((call: [string, string]) => call[1]);
				} finally {
					h.ctx.hasUI = false;
				}
			},
			(h) => {
				h.ctx = makeCtx({ sessionManager: h.ctx.sessionManager });
				return agentEnd(h);
			},
			agentSettled,
			completeCompaction,
		],
		expected: [0, ["warning"], 0, { calls: 1, settled: false }, true],
	},
	{
		name: "late old-session compact event cannot consume a new-session trigger",
		actions: [
			agentEnd,
			agentSettled,
			switchSession,
			agentEnd,
			async (h) => {
				sessionCompact(h, true, h.previousCtx);
				return agentSettled(h);
			},
			completeCompaction,
		],
		expected: [0, { calls: 1, settled: false }, true, 0, { calls: 1, settled: false }, true],
	},
	{
		name: "late old-session compact event cannot suppress retry after Already compacted",
		actions: [
			agentEnd,
			agentSettled,
			switchSession,
			agentEnd,
			agentSettled,
			async (h) => {
				sessionCompact(h, true, h.previousCtx);
				const call = h.ctx.compact.mock.calls[0]?.[0] as CompactCall;
				call.onError?.(new Error("Already compacted"));
				await h.settlement;
				return h.settled;
			},
			agentEnd,
			agentSettled,
			completeCompaction,
		],
		expected: [0, { calls: 1, settled: false }, true, 0, { calls: 1, settled: false }, true, 1, { calls: 2, settled: false }, true],
	},
];

for (const row of rows) {
	test(`qol event wiring: ${row.name}`, async () => {
		const fake = makeFakeApi();
		qolDefault(fake.api);
		const h: World = { fake, ctx: makeCtx(), settled: false };
		row.setup?.(h);
		if (row.start !== false) startSession(fake, h.ctx);
		const observed: unknown[] = [];
		for (const action of row.actions) observed.push(await action(h));
		expect(observed).toStrictEqual(row.expected);
	});
}
