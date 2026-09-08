import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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
	try { rmSync(workdir, { force: true, recursive: true }); }
	finally {
		if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
		if (originalHome === undefined) delete process.env.HOME;
		else process.env.HOME = originalHome;
		mock.module("@earendil-works/pi-ai", () => ({
			complete: async () => ({ content: [{ text: "stubbed summary text", type: "text" }], stopReason: "end_turn" }),
		}));
	}
});
function makeMessage(text: string) {
	return { content: [{ text, type: "text" }], role: "user", timestamp: 1_700_000_000_000 };
}
function makeCtx(cwd = workdir) {
	const notify = mock((_message: string, _level: string) => {});
	const ctx = {
		cwd, getContextUsage: () => ({ contextWindow: 200_000, percent: 50, tokens: 100_000 }), hasUI: true,
		model: { contextWindow: 200_000, id: "test-model", provider: "test" },
		modelRegistry: {
			find: () => ({ contextWindow: 200_000, id: "test-model", provider: "test" }),
			getApiKeyAndHeaders: async () => ({ apiKey: "k", headers: {}, ok: true }),
		},
		sessionManager: { getBranch: () => [], getSessionFile: () => undefined, getSessionId: () => "session-handle-test" },
		ui: { notify },
	};
	return { ctx: ctx as unknown as Parameters<typeof handleQolCompaction>[1], notify };
}
const cases = [
	{
		name: "disabled custom compaction without sentinel",
		run: async () => {
			const { ctx } = makeCtx();
			return { result: await handleQolCompaction({ customInstructions: "user requested", preparation: {
				messagesToSummarize: [makeMessage("hi")], tokensBefore: 100, turnPrefixMessages: [],
			}, type: "session_before_compact" }, ctx) };
		},
		expected: { result: undefined },
	},
	{
		name: "sentinel bypass writes the bounded summary and handoff",
		run: async () => {
			const { ctx } = makeCtx();
			const result = await handleQolCompaction({ customInstructions: `${QOL_BUDGET_GUARD_SENTINEL} fired because over budget`, preparation: {
				firstKeptEntryId: "abc", messagesToSummarize: [makeMessage("first message"), makeMessage("second message")],
				previousSummary: "prev", tokensBefore: 180_000, turnPrefixMessages: [],
			}, type: "session_before_compact" }, ctx);
			const details = result?.compaction?.details ?? {};
			const stampedExists = typeof details.handoffArtifact === "string" && existsSync(details.handoffArtifact);
			const latestExists = typeof details.handoffArtifactLatest === "string" && existsSync(details.handoffArtifactLatest);
			const saved = stampedExists ? JSON.parse(readFileSync(details.handoffArtifact as string, "utf8")) : undefined;
			return {
				summary: result?.compaction?.summary, tokensBefore: result?.compaction?.tokensBefore, firstKeptEntryId: result?.compaction?.firstKeptEntryId,
				trigger: details.trigger, source: details.source, pathDefined: details.handoffArtifact !== undefined,
				latestDefined: details.handoffArtifactLatest !== undefined, errorAbsent: details.handoffArtifactError === undefined,
				messageCount: details.messageCount, stampedExists, latestExists, sessionId: saved?.sessionId,
				sentinel: saved?.reason?.includes(QOL_BUDGET_GUARD_SENTINEL), previousSummary: saved?.previousSummary, savedTokens: saved?.tokensBefore,
			};
		},
		expected: {
			summary: "stubbed summary text", tokensBefore: 180_000, firstKeptEntryId: "abc", trigger: "budget-guard", source: "pi-qol budget-guard",
			pathDefined: true, latestDefined: true, errorAbsent: true, messageCount: 2, stampedExists: true, latestExists: true,
			sessionId: "session-handle-test", sentinel: true, previousSummary: "prev", savedTokens: 180_000,
		},
	},
	{
		name: "handoff filesystem failure warns while retaining the summary",
		run: async () => {
			const file = join(workdir, "blocking-file");
			writeFileSync(file, "blocker");
			process.env.PI_CODING_AGENT_DIR = file;
			const { ctx, notify } = makeCtx(file);
			const result = await handleQolCompaction({ customInstructions: `${QOL_BUDGET_GUARD_SENTINEL} budget guard fired`, preparation: {
				messagesToSummarize: [makeMessage("only message")], tokensBefore: 180_000, turnPrefixMessages: [],
			}, type: "session_before_compact" }, ctx);
			const details = result?.compaction?.details ?? {};
			return { summary: result?.compaction?.summary, pathAbsent: details.handoffArtifact === undefined,
				code: String(details.handoffArtifactError).includes("ENOTDIR"),
				warned: notify.mock.calls.some(([message, level]) => level === "warning" && message.includes("ENOTDIR")),
			};
		},
		expected: { summary: "stubbed summary text", pathAbsent: true, code: true, warned: true },
	},
	{
		name: "summarizer failure cancels when fallback is disabled",
		run: async () => {
			mock.module("@earendil-works/pi-ai", () => ({ complete: async () => { throw new Error("provider died"); } }));
			writeFileSync(join(workdir, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: {
				"@vanillagreen/pi-qol": { "compaction.fallbackToDefault": false },
			} } } }));
			const { ctx, notify } = makeCtx();
			const result = await handleQolCompaction({ customInstructions: `${QOL_BUDGET_GUARD_SENTINEL} fired`, preparation: {
				messagesToSummarize: [makeMessage("x")], tokensBefore: 100, turnPrefixMessages: [],
			}, type: "session_before_compact" }, ctx);
			return { result, notified: notify.mock.calls.some(([, level]) => level === "error") };
		},
		expected: { result: { cancel: true }, notified: true },
	},
	{
		name: "summarizer failure falls back to Pi by default",
		run: async () => {
			mock.module("@earendil-works/pi-ai", () => ({ complete: async () => { throw new Error("provider down"); } }));
			const { ctx } = makeCtx();
			return { result: await handleQolCompaction({ customInstructions: `${QOL_BUDGET_GUARD_SENTINEL} fired`, preparation: {
				messagesToSummarize: [makeMessage("x")], tokensBefore: 100, turnPrefixMessages: [],
			}, type: "session_before_compact" }, ctx) };
		},
		expected: { result: undefined },
	},
	{
		name: "empty messages skip custom compaction",
		run: async () => {
			const { ctx } = makeCtx();
			return { result: await handleQolCompaction({ customInstructions: `${QOL_BUDGET_GUARD_SENTINEL} fired`, preparation: {
				messagesToSummarize: [], tokensBefore: 0, turnPrefixMessages: [],
			}, type: "session_before_compact" }, ctx) };
		},
		expected: { result: undefined },
	},
];
if (cases.length === 0) throw new Error("compaction handler cases are empty");
for (const row of cases) {
	test(`handleQolCompaction: ${row.name}`, async () => { expect(await row.run()).toStrictEqual(row.expected); });
}
