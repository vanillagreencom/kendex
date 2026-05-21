// Integration test for handleQolCompaction covering the sentinel bypass
// of compaction.customEnabled, handoff artifact write, details fields,
// warning propagation on handoff failure, and error propagation when the
// summarizer fails. The pi-ai `complete` call is stubbed via the bunfig
// preload (returns "stubbed summary text"); we only need to assert the
// surrounding handler control flow.

import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { QOL_BUDGET_GUARD_SENTINEL } from "../extensions/qol/budget-guard.ts";
import { handleQolCompaction } from "../extensions/qol/compaction.ts";

let workdir = "";
const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
const originalHome = process.env.HOME;

beforeEach(() => {
	workdir = mkdtempSync(join(tmpdir(), "pi-qol-handle-"));
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

function makeMessage(text: string) {
	return { content: [{ text, type: "text" }], role: "user", timestamp: Date.now() } as any;
}

function makeCtx(overrides: Partial<any> = {}) {
	const notify = mock(() => {});
	return {
		notify,
		ctx: {
			cwd: workdir,
			getContextUsage: () => ({ contextWindow: 200_000, percent: 50, tokens: 100_000 }),
			hasUI: true,
			model: { contextWindow: 200_000, id: "test-model", provider: "test" },
			modelRegistry: {
				find: () => ({ contextWindow: 200_000, id: "test-model", provider: "test" }),
				getApiKeyAndHeaders: async () => ({ apiKey: "k", headers: {}, ok: true }),
			},
			sessionManager: {
				getBranch: () => [],
				getSessionFile: () => undefined,
				getSessionId: () => "session-handle-test",
			},
			ui: {
				notify,
			},
			...overrides,
		},
	};
}

test("returns undefined when no sentinel and customEnabled is off", async () => {
	const { ctx } = makeCtx();
	const result = await handleQolCompaction({
		customInstructions: "user requested",
		preparation: {
			messagesToSummarize: [makeMessage("hi")],
			tokensBefore: 100,
			turnPrefixMessages: [],
		},
		type: "session_before_compact",
	}, ctx as any);
	expect(result).toBeUndefined();
});

test("sentinel bypasses customEnabled and produces a QOL bounded result + handoff artifact", async () => {
	const { ctx } = makeCtx();
	const result = await handleQolCompaction({
		customInstructions: `${QOL_BUDGET_GUARD_SENTINEL} fired because over budget`,
		preparation: {
			firstKeptEntryId: "abc",
			messagesToSummarize: [makeMessage("first message"), makeMessage("second message")],
			previousSummary: "prev",
			tokensBefore: 180_000,
			turnPrefixMessages: [],
		},
		signal: undefined,
		type: "session_before_compact",
	}, ctx as any);
	expect(result?.compaction?.summary).toBe("stubbed summary text");
	expect(result?.compaction?.tokensBefore).toBe(180_000);
	expect(result?.compaction?.firstKeptEntryId).toBe("abc");
	const details = result?.compaction?.details ?? {};
	expect(details.trigger).toBe("budget-guard");
	expect(details.source).toBe("pi-qol budget-guard");
	expect(details.handoffArtifact).toBeDefined();
	expect(details.handoffArtifactLatest).toBeDefined();
	expect(details.handoffArtifactError).toBeUndefined();
	expect(details.messageCount).toBe(2);
	expect(existsSync(details.handoffArtifact as string)).toBe(true);
	expect(existsSync(details.handoffArtifactLatest as string)).toBe(true);
	const saved = JSON.parse(readFileSync(details.handoffArtifact as string, "utf8"));
	expect(saved.sessionId).toBe("session-handle-test");
	expect(saved.reason).toContain(QOL_BUDGET_GUARD_SENTINEL);
	expect(saved.previousSummary).toBe("prev");
	expect(saved.tokensBefore).toBe(180_000);
});

test("sentinel-triggered compaction notifies handoff write failure but still returns a summary", async () => {
	// Make the handoff write fail by pointing PI_CODING_AGENT_DIR at a
	// child path of an existing FILE so mkdirSync ENOTDIR.
	const filePath = join(workdir, "blocking-file");
	require("node:fs").writeFileSync(filePath, "blocker");
	process.env.PI_CODING_AGENT_DIR = filePath;
	const { ctx, notify } = makeCtx({ cwd: filePath });
	const result = await handleQolCompaction({
		customInstructions: `${QOL_BUDGET_GUARD_SENTINEL} budget guard fired`,
		preparation: {
			messagesToSummarize: [makeMessage("only message")],
			tokensBefore: 180_000,
			turnPrefixMessages: [],
		},
		signal: undefined,
		type: "session_before_compact",
	}, ctx as any);
	expect(result?.compaction?.summary).toBe("stubbed summary text");
	const details = result?.compaction?.details ?? {};
	expect(details.handoffArtifact).toBeUndefined();
	expect(details.handoffArtifactError).toBeTruthy();
	// At least one notification should mention the handoff failure.
	const messages = notify.mock.calls.map((call) => call[0] as string);
	expect(messages.some((m) => m.includes("handoff artifact write failed"))).toBe(true);
});

test("returns cancel: true when summarizer throws and fallbackToDefault is off", async () => {
	mock.module("@earendil-works/pi-ai", () => ({
		complete: async () => {
			throw new Error("provider died");
		},
	}));
	// Disable fallback by writing a settings.json that turns it off.
	const settingsDir = join(workdir, ".pi");
	require("node:fs").mkdirSync(settingsDir, { recursive: true });
	require("node:fs").writeFileSync(
		join(workdir, "settings.json"),
		JSON.stringify({
			vstack: {
				extensionManager: {
					config: {
						"@vanillagreen/pi-qol": { "compaction.fallbackToDefault": false },
					},
				},
			},
		}),
	);
	const { ctx, notify } = makeCtx();
	const result = await handleQolCompaction({
		customInstructions: `${QOL_BUDGET_GUARD_SENTINEL} fired`,
		preparation: {
			messagesToSummarize: [makeMessage("x")],
			tokensBefore: 100,
			turnPrefixMessages: [],
		},
		signal: undefined,
		type: "session_before_compact",
	}, ctx as any);
	expect(result).toEqual({ cancel: true });
	const messages = notify.mock.calls.map((call) => call[0] as string);
	expect(messages.some((m) => m.includes("compaction failed"))).toBe(true);
	// Restore the default stub so later tests still get a summary.
	mock.module("@earendil-works/pi-ai", () => ({
		complete: async () => ({
			content: [{ text: "stubbed summary text", type: "text" }],
			stopReason: "end_turn",
		}),
	}));
});

test("returns undefined and falls back to Pi default when summarizer throws and fallback is on", async () => {
	mock.module("@earendil-works/pi-ai", () => ({
		complete: async () => {
			throw new Error("provider down");
		},
	}));
	const { ctx } = makeCtx();
	const result = await handleQolCompaction({
		customInstructions: `${QOL_BUDGET_GUARD_SENTINEL} fired`,
		preparation: {
			messagesToSummarize: [makeMessage("x")],
			tokensBefore: 100,
			turnPrefixMessages: [],
		},
		signal: undefined,
		type: "session_before_compact",
	}, ctx as any);
	expect(result).toBeUndefined();
	// Restore.
	mock.module("@earendil-works/pi-ai", () => ({
		complete: async () => ({
			content: [{ text: "stubbed summary text", type: "text" }],
			stopReason: "end_turn",
		}),
	}));
});

test("returns undefined when messages list is empty", async () => {
	const { ctx } = makeCtx();
	const result = await handleQolCompaction({
		customInstructions: `${QOL_BUDGET_GUARD_SENTINEL} fired`,
		preparation: {
			messagesToSummarize: [],
			tokensBefore: 0,
			turnPrefixMessages: [],
		},
		signal: undefined,
		type: "session_before_compact",
	}, ctx as any);
	expect(result).toBeUndefined();
});
