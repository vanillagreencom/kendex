// How a one-shot run classifies its end from the bridge stream (compact-then-
// empty, the context-overflow retry, abort), the overflow detector's grammar,
// and the reused-session budget guard that runs before the spawn.

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import test, { after } from "node:test";
import { runSingleAgent, setGitExecFileForTests, setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import { isContextLengthExceededEnvelope, isContextLengthExceededText, resolveBgSession, setSessionCompactorForTests } from "../extensions/subagent/sessions.js";
import type { SingleResult } from "../extensions/subagent/types.js";
import { bridgeEvent, bridgeStdout, cleanupTempRuntimes, installMockSpawn, makeDetails, mockPiEvents, shapedStreamEvent, tempGitRepo, tempRuntime, testAgent, transcriptEventName, writeSettings } from "./single-agent-fixture.js";

after(cleanupTempRuntimes);

type Emitted = Array<{ name: string; payload: any }>;

function runOneShot(options: { cwd: string; pi: any; runtimeRoot?: string; sessionKey?: string; signal?: AbortSignal }): Promise<SingleResult> {
	return runSingleAgent(options.cwd, options.runtimeRoot ?? tempRuntime(), [testAgent()], "reviewer-test", "review code", undefined, undefined, undefined, undefined, options.pi, options.signal, undefined, makeDetails, options.sessionKey);
}

// The pi bus as one line, in emit order. A `needs_completion` event must carry
// what the result carries (status, reason, diagnostics, the snapshot's cwd);
// it prints the fields that differ, or `mirrors-result`. `retrying` prints its reason.
function busLine(emitted: Emitted, result: SingleResult): string {
	const names = emitted.map((event) => {
		const name = event.name.replace(/^subagents:/, "");
		if (name === "needs_completion") {
			const p = event.payload;
			const differs = [
				p.status !== result.status ? "status" : "",
				p.reason !== result.needsCompletionReason ? "reason" : "",
				JSON.stringify(p.diagnostics ?? null) !== JSON.stringify(result.diagnostics ?? null) ? "diagnostics" : "",
				(p.cwdSnapshot?.cwd ?? "-") !== (result.cwdSnapshot?.cwd ?? "-") ? "snapshot" : "",
			].filter(Boolean);
			return `needs_completion(${differs.length ? differs.join("+") : "mirrors-result"})`;
		}
		if (name === "retrying") return `retrying(${event.payload.reason})`;
		return name;
	});
	return names.length ? names.join(",") : "none";
}

// Each diagnostic by the detector that wrote it; an unknown one prints whole.
function diagTags(result: SingleResult): string {
	const tags = (result.diagnostics ?? []).map((d) => {
		if (d.startsWith("compact-then-empty detector skipped malformed agent_end content")) return "malformed-agent-end";
		if (d.startsWith("cwdSnapshot git failed")) return "git-failed";
		if (d.startsWith("Failed to emit subagents:needs_completion")) return "emit-failed";
		return JSON.stringify(d);
	});
	return tags.length ? tags.join(",") : "-";
}

// The envelope an attempt recorded (the raw stream line), read back as the
// overflow it carried: the error code, or the assistant message's error text
// (top-level or under a bridge event's `data`); anything else prints whole.
function envelopeTag(raw: string | undefined): string {
	if (raw === undefined) return "-";
	try {
		const parsed = JSON.parse(raw);
		if (typeof parsed?.error?.code === "string") return `code:${parsed.error.code}`;
		const message = parsed?.message ?? parsed?.data?.message;
		if (typeof message?.errorMessage === "string") return `message:${message.errorMessage}`;
	} catch {
		/* not JSON: printed whole below */
	}
	return JSON.stringify(raw);
}

// The classification as one line: spawns and the returned attempt; when there
// were two attempts, their count and whether the retry ran on a fresh session,
// and the first attempt's summary as `stop/envelope` with the envelope read
// back by `envelopeTag`; then the status, reason and stop of the
// returned result, its snapshot, its diagnostics, whether stderr carries text,
// and the bus.
function classification(result: SingleResult, emitted: Emitted, spawns: number, cwd: string): string {
	const attempts = result.attempts;
	const retry = attempts ? `${attempts.length}/${attempts[0]?.sessionKey !== attempts[1]?.sessionKey ? "fresh-session" : "same-session"}` : "-";
	const first = attempts ? `${attempts[0]?.stopReason ?? "-"}/${envelopeTag(attempts[0]?.errorEnvelope)}` : "-";
	const snapshot = result.cwdSnapshot ? (result.cwdSnapshot.cwd === cwd ? "cwd" : "other") : "-";
	return `spawns=${spawns} exit=${result.exitCode} attempt=${result.attempt ?? "-"} retry=${retry} first=${first} status=${result.status ?? "-"} reason=${result.needsCompletionReason ?? "-"} stop=${result.stopReason ?? "-"} snapshot=${snapshot} diags=${diagTags(result)} stderr=${result.stderr ? "text" : "-"} bus=${busLine(emitted, result)}`;
}

const OVERFLOW_ENVELOPE = `${JSON.stringify({ error: { type: "invalid_request_error", code: "context_length_exceeded" } })}\n`;
const textEnd = (text: string) => bridgeEvent("agent_end", { content: [{ type: "text", text }] });
const assistantText = (text: string) => bridgeEvent("message_end", { message: { role: "assistant", content: [{ type: "text", text }] } });
const EMPTY_END = bridgeEvent("agent_end", { content: [] });
// An assistant turn that pi ends with an error instead of an error envelope.
const OVERFLOW_TURN = bridgeEvent("message_end", { message: { role: "assistant", content: [], stopReason: "error", errorMessage: "context_length_exceeded" } });
const COMPACT = bridgeEvent("session_compact");

type World = { git?: "missing"; pi?: (emitted: Emitted) => any; stream: Array<{ code?: number; stdout?: string }> };

const COMPLETED = "spawns=1 exit=0 attempt=1 retry=- first=- status=- reason=- stop=- snapshot=- diags=- stderr=- bus=started,completed";
const NEEDS_COMPLETION = "spawns=1 exit=0 attempt=1 retry=- first=- status=needs_completion reason=compact-then-empty stop=needs_completion snapshot=cwd diags=- stderr=- bus=started,needs_completion(mirrors-result)";
const RETRIED_OK = "spawns=2 exit=0 attempt=2 retry=2/fresh-session first=-/code:context_length_exceeded status=- reason=- stop=- snapshot=- diags=- stderr=text bus=started,failed,retrying(context_length_exceeded),started,completed";

// label | the spawn's stdout per attempt (and the world around it) | expect the classification line
// Every row runs in a fresh git repo, so a needs_completion row's snapshot is the cwd's.
const endRows: Array<[string, World, string]> = [
	["a compact then an empty agent_end is needs_completion with the cwd's snapshot", { stream: [{ stdout: bridgeStdout([COMPACT, EMPTY_END]) }] }, NEEDS_COMPLETION],
	["assistant text before the compact does not mask it", { stream: [{ stdout: bridgeStdout([assistantText("pre-compact progress"), COMPACT, EMPTY_END]) }] }, NEEDS_COMPLETION],
	["a null agent_end content is empty", { stream: [{ stdout: bridgeStdout([COMPACT, bridgeEvent("agent_end", { content: null })]) }] }, NEEDS_COMPLETION],
	["an omitted agent_end content is empty", { stream: [{ stdout: bridgeStdout([COMPACT, bridgeEvent("agent_end")]) }] }, NEEDS_COMPLETION],
	["assistant text after the compact completes", { stream: [{ stdout: bridgeStdout([COMPACT, assistantText("post-compact answer"), EMPTY_END]) }] }, COMPLETED],
	["a compact then a text agent_end completes", { stream: [{ stdout: bridgeStdout([COMPACT, textEnd("ok")]) }] }, COMPLETED],
	["an empty agent_end without a compact completes", { stream: [{ stdout: bridgeStdout([EMPTY_END]) }] }, COMPLETED],
	["a compact with no agent_end (bridge gone) completes", { stream: [{ stdout: bridgeStdout([COMPACT]) }] }, COMPLETED],
	["a compact after an empty agent_end, with no further end, completes", { stream: [{ stdout: bridgeStdout([COMPACT, EMPTY_END, COMPACT]) }] }, COMPLETED],
	["a second compact re-arms the empty-end rule", { stream: [{ stdout: bridgeStdout([COMPACT, assistantText("first answer"), EMPTY_END, COMPACT, EMPTY_END]) }] }, NEEDS_COMPLETION],
	["a malformed agent_end content is logged and completes", { stream: [{ stdout: bridgeStdout([COMPACT, bridgeEvent("agent_end", { content: "bad-shape" })]) }] },
		"spawns=1 exit=0 attempt=1 retry=- first=- status=- reason=- stop=- snapshot=- diags=malformed-agent-end stderr=- bus=started,completed"],
	["a missing git keeps needs_completion without the snapshot", { git: "missing", stream: [{ stdout: bridgeStdout([COMPACT, EMPTY_END]) }] },
		"spawns=1 exit=0 attempt=1 retry=- first=- status=needs_completion reason=compact-then-empty stop=needs_completion snapshot=- diags=git-failed stderr=- bus=started,needs_completion(mirrors-result)"],
	["a needs_completion emit that throws is a diagnostic on the result", {
		pi: (emitted) => ({ getActiveTools: () => [], events: { emit: (name: string, payload: unknown) => {
			if (name === "subagents:needs_completion") throw new Error("bus disposed");
			emitted.push({ name, payload });
		} } }),
		stream: [{ stdout: bridgeStdout([COMPACT, EMPTY_END]) }],
	}, "spawns=1 exit=0 attempt=1 retry=- first=- status=needs_completion reason=compact-then-empty stop=needs_completion snapshot=cwd diags=emit-failed stderr=- bus=started"],
	["a context overflow envelope retries once on a fresh session", { stream: [{ code: 1, stdout: OVERFLOW_ENVELOPE }, { stdout: bridgeStdout([textEnd("ok after retry")]) }] }, RETRIED_OK],
	["an assistant turn ending in a context-length error retries", { stream: [{ stdout: bridgeStdout([OVERFLOW_TURN]) }, { stdout: bridgeStdout([textEnd("ok after retry")]) }] },
		"spawns=2 exit=0 attempt=2 retry=2/fresh-session first=error/message:context_length_exceeded status=- reason=- stop=- snapshot=- diags=- stderr=text bus=started,failed,retrying(context_length_exceeded),started,completed"],
	["an overflow on the retry too fails, whatever the retry's exit code", { stream: [{ code: 1, stdout: OVERFLOW_ENVELOPE }, { code: 0, stdout: bridgeStdout([OVERFLOW_TURN]) }] },
		"spawns=2 exit=1 attempt=2 retry=2/fresh-session first=-/code:context_length_exceeded status=- reason=- stop=error snapshot=- diags=- stderr=text bus=started,failed,retrying(context_length_exceeded),started,failed"],
	["a compact-then-empty on the retry is needs_completion", { stream: [{ code: 1, stdout: OVERFLOW_ENVELOPE }, { stdout: bridgeStdout([COMPACT, EMPTY_END]) }] },
		"spawns=2 exit=0 attempt=2 retry=2/fresh-session first=-/code:context_length_exceeded status=needs_completion reason=compact-then-empty stop=needs_completion snapshot=cwd diags=- stderr=text bus=started,failed,retrying(context_length_exceeded),started,needs_completion(mirrors-result)"],
	["a compact-then-empty beside an overflow in the same attempt is the retry's, not needs_completion", { stream: [{ code: 1, stdout: bridgeStdout([COMPACT, EMPTY_END, JSON.parse(OVERFLOW_ENVELOPE)]) }, { stdout: bridgeStdout([textEnd("ok after retry")]) }] }, RETRIED_OK],
	["overflow wording inside a tool result is not an overflow", { stream: [{ stdout: bridgeStdout([
		{ type: "tool_execution_end", toolCallId: "call-grep", toolName: "grep", result: { content: [{ type: "text", text: "tests/session-lanes.test.ts: context_length_exceeded detection triggers one retry" }] } },
		assistantText("Reviewed context_length_exceeded docs/tests; no runtime overflow."),
		textEnd("done"),
	]) }] }, COMPLETED],
];

test("the end of a one-shot run", async () => {
	for (const [label, world, expect] of endRows) {
		const cwd = tempGitRepo();
		const emitted: Emitted = [];
		const calls = installMockSpawn(world.stream.map((attempt) => ({ code: attempt.code ?? 0, stdout: attempt.stdout })));
		if (world.git === "missing") {
			setGitExecFileForTests(((command: string, args: string[], options: any, callback: any) => {
				void command;
				void args;
				const cb = typeof options === "function" ? options : callback;
				queueMicrotask(() => cb(Object.assign(new Error("spawn git ENOENT"), { code: "ENOENT" }), "", "spawn git ENOENT"));
				return new EventEmitter() as any;
			}) as any);
		}
		try {
			const result = await runOneShot({ cwd, pi: world.pi ? world.pi(emitted) : mockPiEvents(emitted) });
			assert.equal(classification(result, emitted, calls.length, cwd), expect, label);
		} finally {
			setGitExecFileForTests();
			setSingleAgentSpawnForTests();
		}
	}
});

test("an aborted run fails with the partial answer flushed to its transcript", async () => {
	const emitted: Emitted = [];
	const cwd = tempRuntime();
	const calls = installMockSpawn([{ code: 0, stdout: bridgeStdout([
		shapedStreamEvent("top-level", "message_update", { message: { role: "assistant", content: [{ type: "text", text: "aborted partial" }] } }),
	]) }]);
	const controller = new AbortController();
	controller.abort();
	try {
		await assert.rejects(runOneShot({ cwd, pi: mockPiEvents(emitted), signal: controller.signal }), /Agent was aborted/);
		const failed = emitted.find((event) => event.name === "subagents:failed");
		const records = readFileSync(failed?.payload.transcriptPath, "utf8").trim().split(/\r?\n/).map((line) => JSON.parse(line));
		const updates = records.filter((record) => record.event && transcriptEventName(record.event) === "message_update");
		assert.equal(
			`spawns=${calls.length} bus=${emitted.map((event) => event.name.replace(/^subagents:/, "")).join(",")} status=${failed?.payload.status} updates=${updates.length} buffered=${updates.every((record) => record.buffered === true)} partial=${updates.some((record) => JSON.stringify(record.event).includes("aborted partial"))}`,
			"spawns=1 bus=started,failed status=aborted updates=1 buffered=true partial=true",
		);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

// label | the text or envelope under test | expect
const overflowRows: Array<[string, unknown, boolean]> = [
	["text: the error code as a word", 'Codex error: {"type":"error","error":{"type":"invalid_request_error","code":"context_length_exceeded"}}', true],
	["text: hyphenated code", "context-length-exceeded", true],
	["text: exceeds the model's maximum context length with a parenthesised size", "Input length (265330) exceeds model's maximum context length (262144).", true],
	["text: exceeds maximum context length of N tokens", "Prompt exceeds maximum context length of 200,000 tokens", true],
	["text: exceeds the context window", "Your input exceeds the context window of this model", true],
	["text: maximum context length without a size is not an overflow", "This model's maximum context length is large.", false],
	["text: an ordinary completion", "Reviewed the diff; no findings.", false],
	["envelope: error.code", { error: { code: "context_length_exceeded" } }, true],
	["envelope: error.type", { error: { type: "context_length_exceeded" } }, true],
	["envelope: top-level code", { code: "context_length_exceeded" }, true],
	["envelope: top-level type", { type: "context_length_exceeded" }, true],
	["envelope: error as a string", { error: "request failed: context_length_exceeded" }, true],
	["envelope: errorMessage", { errorMessage: "context_length_exceeded" }, true],
	["envelope: stopReason", { stopReason: "context_length_exceeded" }, true],
	["envelope: message.errorMessage", { type: "turn_end", message: { errorMessage: "context_length_exceeded" } }, true],
	["envelope: message.stopReason", { type: "turn_end", message: { stopReason: "context_length_exceeded" } }, true],
	["envelope: an ordinary message_end", { type: "message_end", message: { role: "assistant", stopReason: "stop", content: [{ type: "text", text: "ok" }] } }, false],
	["envelope: the code in a tool result is not read", { type: "tool_execution_end", result: { content: [{ type: "text", text: "context_length_exceeded" }] } }, false],
];

test("the context-overflow detector", () => {
	for (const [label, input, expect] of overflowRows) {
		const actual = typeof input === "string" ? isContextLengthExceededText(input) : isContextLengthExceededEnvelope(input);
		assert.equal(actual, expect, label);
	}
});

const OK_STDOUT = bridgeStdout([textEnd("ok")]);

type BudgetWorld = { compactor?: "fails" | "truncates"; key?: string; session?: "absent" | number; settings?: Record<string, unknown> };

// The guard's outcome as one line: spawns, compactor calls, the exit and stop
// reason, the session mode, whether the result names the requested key, and
// whether stderr carries the guard's line.
function budgetLine(result: SingleResult, spawns: number, compactions: number, key: string): string {
	return `spawns=${spawns} compactions=${compactions} exit=${result.exitCode} refused=${result.refused ?? false} stop=${result.stopReason ?? "-"} mode=${result.sessionMode ?? "-"} key=${result.sessionKey === key ? "key" : result.sessionKey ?? "-"} stderr=${result.stderr ? "guard-line" : "-"}`;
}

const TIGHT = { reusedSessionBudgetThreshold: 0.5, reusedSessionContextLimitTokens: 100 };
const REFUSED = "spawns=0 compactions=0 exit=1 refused=true stop=session_budget_exceeded mode=resumed key=key stderr=guard-line";
const SPAWNED = "spawns=1 compactions=0 exit=0 refused=false stop=- mode=resumed key=key stderr=-";

// A session estimates at one token per four bytes, rounded up, against the
// limit; the default limit is 272k tokens and the default threshold 80%, so
// 870,400 bytes sit exactly on the default line and one more byte is over it.
// label | the reused session's size in bytes and the project's budget settings | expect the guard's line
const budgetRows: Array<[string, BudgetWorld, string]> = [
	["one byte over the default line is refused before the spawn", { session: 870_401 }, REFUSED],
	["exactly on the default line spawns", { session: 870_400 }, SPAWNED],
	["a configured limit decides under the default threshold", { session: 1_000, settings: { reusedSessionContextLimitTokens: 100 } }, REFUSED],
	["a configured threshold decides under a configured limit", { session: 100, settings: { ...TIGHT, reusedSessionBudgetThreshold: 0.2 } }, REFUSED],
	["a threshold above 1 is a percentage", { session: 100, settings: { ...TIGHT, reusedSessionBudgetThreshold: 20 } }, REFUSED],
	["a percentage above 100 clamps to the whole limit", { session: 600, settings: { ...TIGHT, reusedSessionBudgetThreshold: 150 } }, REFUSED],
	["a zero threshold falls back to the default: on the 80% line spawns", { session: 320, settings: { reusedSessionContextLimitTokens: 100, reusedSessionBudgetThreshold: 0 } }, SPAWNED],
	["a zero threshold falls back to the default: over the 80% line is refused", { session: 324, settings: { reusedSessionContextLimitTokens: 100, reusedSessionBudgetThreshold: 0 } }, REFUSED],
	["under a configured threshold spawns", { session: 100, settings: TIGHT }, SPAWNED],
	["an explicit key with no session file yet spawns", { session: "absent", settings: TIGHT }, SPAWNED],
	["a one-shot session key is never guarded", { key: "oneshot-fixed", session: 1_000, settings: TIGHT }, "spawns=1 compactions=0 exit=0 refused=false stop=- mode=fresh key=key stderr=-"],
	["the warn policy spawns with the guard's line on stderr", { session: 1_000, settings: { ...TIGHT, reusedSessionBudgetPolicy: "warn" } }, "spawns=1 compactions=0 exit=0 refused=false stop=- mode=resumed key=key stderr=guard-line"],
	["compact-then-resume compacts once, then spawns", { compactor: "truncates", session: 1_000, settings: { ...TIGHT, reusedSessionBudgetPolicy: "compact-then-resume" } }, "spawns=1 compactions=1 exit=0 refused=false stop=- mode=resumed key=key stderr=guard-line"],
	["a failed compaction refuses", { compactor: "fails", session: 1_000, settings: { ...TIGHT, reusedSessionBudgetPolicy: "compact-then-resume" } }, "spawns=0 compactions=1 exit=1 refused=true stop=session_budget_exceeded mode=resumed key=key stderr=guard-line"],
];

test("the reused-session budget guard", async () => {
	// The user-scope settings layer is read from PI_CODING_AGENT_DIR; a temp dir
	// keeps the developer's own settings out of the rows.
	const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = tempRuntime();
	try {
		await runBudgetRows();
	} finally {
		if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
	}
});

async function runBudgetRows(): Promise<void> {
	for (const [label, world, expect] of budgetRows) {
		const runtimeRoot = tempRuntime();
		const cwd = tempRuntime();
		if (world.settings) writeSettings(cwd, world.settings);
		const key = world.key ?? "reuse";
		const session = resolveBgSession(runtimeRoot, "reviewer-test", key);
		if (world.session !== "absent") {
			mkdirSync(dirname(session.path), { recursive: true });
			writeFileSync(session.path, "x".repeat(world.session ?? 0), "utf8");
		}
		let compactions = 0;
		setSessionCompactorForTests(async (request) => {
			compactions += 1;
			if (world.compactor === "fails") throw new Error("archive disk full");
			writeFileSync(request.sessionPath, "", "utf8");
			return { archivePath: `${request.sessionPath}.archive` };
		});
		const calls = installMockSpawn([{ code: 0, stdout: OK_STDOUT }]);
		try {
			const result = await runOneShot({ cwd, pi: mockPiEvents([]), runtimeRoot, sessionKey: key });
			assert.equal(budgetLine(result, calls.length, compactions, key), expect, label);
		} finally {
			setSessionCompactorForTests();
			setSingleAgentSpawnForTests();
		}
	}
}
