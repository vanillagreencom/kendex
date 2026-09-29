import { afterEach, beforeEach, expect, jest, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import qolDefault from "../extensions/qol.ts";
import { clearPackageConfigCache } from "../extensions/qol/package-config.ts";
import { QOL_BUDGET_GUARD_SENTINEL } from "../extensions/qol/budget-guard.ts";
import { statusMessage } from "../extensions/qol/status-message.ts";
import { type CompactCall, type FakeApi, makeCtx, makeFakeApi } from "./fake-pi.ts";

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
	clearPackageConfigCache();
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
		jest.useRealTimers();
		if (workdir) rmSync(workdir, { force: true, recursive: true });
		if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
		if (originalHome === undefined) delete process.env.HOME;
		else process.env.HOME = originalHome;
		clearPackageConfigCache();
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

/** The user Pi settings file: Pi core's `compaction` object, absent where
 * `enabled` is undefined, beside the QOL package config. A defined `project`
 * also writes the project file with only Pi's key. */
function writePiSettings(enabled: boolean | undefined, qol: Record<string, unknown> = {}, project?: boolean): void {
	const settings = {
		...(enabled === undefined ? {} : { compaction: { enabled } }),
		kendex: { extensionManager: { config: { "@vanillagreen/pi-qol": qol } } },
	};
	// What pi-extension-manager's settings-changed event does after a write.
	clearPackageConfigCache();
	writeFileSync(join(workdir, "settings.json"), `${JSON.stringify(settings)}\n`, "utf8");
	if (project === undefined) return;
	mkdirSync(join(workdir, ".pi"), { recursive: true });
	writeFileSync(join(workdir, ".pi", "settings.json"), `${JSON.stringify({ compaction: { enabled: project } })}\n`, "utf8");
}

function statusLine(h: World, label: string): string | undefined {
	return statusMessage(h.ctx as any).split("\n").find((line) => line.startsWith(`${label}: `));
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
	...([
		{ trigger: "budgetGuard", user: false, fires: 0, status: "Budget guard: disabled by Pi compaction.enabled=false" },
		{ trigger: "budgetGuard", user: true, fires: 1, status: "Budget guard: enabled (budgetPercent=85, budgetTokens=-1)" },
		{ trigger: "budgetGuard", user: undefined, fires: 1, status: "Budget guard: enabled (budgetPercent=85, budgetTokens=-1)" },
		{ trigger: "budgetGuard", user: true, qol: { "compaction.budgetGuardEnabled": false }, fires: 0, status: "Budget guard: disabled" },
		{ trigger: "budgetGuard", user: true, project: false, fires: 0, status: "Budget guard: disabled by Pi compaction.enabled=false" },
		{ trigger: "budgetGuard", user: false, project: true, fires: 1, status: "Budget guard: enabled (budgetPercent=85, budgetTokens=-1)" },
		{ trigger: "idle", user: false, qol: { "compaction.idleEnabled": true }, fires: 0, status: "Idle compaction: disabled by Pi compaction.enabled=false" },
		{ trigger: "idle", user: true, qol: { "compaction.idleEnabled": true }, fires: 1, status: "Idle compaction: enabled after 1s idle" },
		{ trigger: "idle", user: undefined, qol: { "compaction.idleEnabled": true }, fires: 1, status: "Idle compaction: enabled after 1s idle" },
		{ trigger: "idle", user: true, fires: 0, status: "Idle compaction: disabled" },
	] as Array<{ trigger: "budgetGuard" | "idle"; user?: boolean; project?: boolean; qol?: Record<string, unknown>; fires: number; status: string }>).map((gate) => ({
		name: `${gate.trigger} with Pi compaction.enabled user=${gate.user} project=${gate.project} and QOL ${JSON.stringify(gate.qol ?? {})}`,
		setup: (h: World) => {
			writePiSettings(gate.user, { ...gate.qol, "compaction.idleTimeoutSeconds": 1 }, gate.project);
			if (gate.project !== undefined) h.ctx.isProjectTrusted = () => true;
			if (gate.trigger === "idle") {
				h.ctx.getContextUsage = () => ({ contextWindow: 1_000_000, percent: 25, tokens: 250_000 });
				jest.useFakeTimers();
			} else {
				h.ctx.getContextUsage = () => ({ contextWindow: 200_000, percent: 100, tokens: 200_000 });
			}
		},
		actions: [
			agentEnd,
			gate.trigger === "idle"
				? (h: World) => {
					jest.advanceTimersByTime(1_000);
					return h.ctx.compact.mock.calls.length;
				}
				: async (h: World) => {
					const settlement = h.fake.handlers.agent_settled!({ type: "agent_settled" }, h.ctx);
					await Promise.resolve();
					const calls = h.ctx.compact.mock.calls.length;
					(h.ctx.compact.mock.calls[0]?.[0] as CompactCall | undefined)?.onComplete?.();
					await settlement;
					return calls;
				},
			(h: World) => statusLine(h, gate.status.slice(0, gate.status.indexOf(":"))),
		],
		expected: [0, gate.fires, gate.status],
	})),
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
