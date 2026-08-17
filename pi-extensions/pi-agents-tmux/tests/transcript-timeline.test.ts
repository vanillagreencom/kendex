import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { after } from "node:test";
import { readTranscriptTail } from "../extensions/subagent/renderers.js";
import { formatTranscriptForDisplay } from "../extensions/subagent/transcript-timeline.js";

const T0 = "2026-03-24T23:59:33.000Z";
const at = (seconds: number) => new Date(Date.parse(T0) + seconds * 1000).toISOString();
const line = (record: unknown) => JSON.stringify(record);
const stream = (seconds: number, event: unknown) => line({ ts: at(seconds), stream: "stdout", raw: "", event });

test("unrecognized event types render as type and size, never a payload dump", () => {
	const payload = "SECRET_PAYLOAD_".repeat(200);
	const out = formatTranscriptForDisplay(stream(0, { type: "weird_thing", blob: payload }));
	assert.match(out, /weird_thing/);
	assert.match(out, /KB|B\b/);
	assert.doesNotMatch(out, /SECRET_PAYLOAD/);
});

test("a tool call collapses to one row: name, target, status, duration, result size", () => {
	const out = formatTranscriptForDisplay([
		stream(0, { toolCallId: "c1", toolName: "bash", type: "tool_execution_start", args: { command: "git status" } }),
		stream(1, { toolCallId: "c1", type: "tool_execution_update", result: "PARTIAL_OUTPUT ".repeat(100) }),
		stream(3, { toolCallId: "c1", toolName: "bash", type: "tool_execution_end", status: "ok", result: "x".repeat(2500) }),
	].join("\n"));
	const rows = out.split("\n");
	assert.equal(rows.length, 1);
	assert.match(rows[0]!, /tool bash \(git status\) · ok · 3\.0s · 2\.4KB/);
	assert.doesNotMatch(out, /PARTIAL_OUTPUT/);
	assert.doesNotMatch(out, /xxxx/);
});

test("a failed tool end and a start with no end are error rows", () => {
	const failed = formatTranscriptForDisplay([
		stream(0, { toolCallId: "c1", toolName: "bash", type: "tool_execution_start", args: { command: "false" } }),
		stream(1, { isError: true, toolCallId: "c1", toolName: "bash", type: "tool_execution_end" }),
	].join("\n"));
	assert.match(failed, /^✖.*tool bash/m);
	const dangling = formatTranscriptForDisplay(stream(0, { toolCallId: "c9", toolName: "read", type: "tool_execution_start" }));
	assert.match(dangling, /^✖.*tool read.*no result recorded/m);
	// A live task legitimately has its newest call still open — no failure mark.
	const live = formatTranscriptForDisplay(stream(0, { toolCallId: "c9", toolName: "read", type: "tool_execution_start" }), { taskTerminal: false });
	assert.match(live, /^ .*tool read.*running/m);
	assert.doesNotMatch(live, /✖/);
});

test("assistant text and thinking render as capped previews", () => {
	const out = formatTranscriptForDisplay(stream(0, {
		message: { content: [{ thinking: "let me think ".repeat(100), type: "thinking" }, { text: "the answer ".repeat(100), type: "text" }], role: "assistant" },
		type: "message_end",
	}));
	const rows = out.split("\n");
	assert.equal(rows.length, 2);
	assert.match(rows[0]!, /thinking · let me think/);
	assert.match(rows[1]!, /assistant · the answer/);
	for (const row of rows) assert.ok(row.length < 220, `row too long: ${row.length}`);
});

test("a tool-call-only assistant message renders as its calls, not message JSON", () => {
	const out = formatTranscriptForDisplay(stream(0, {
		message: { content: [{ id: "a", name: "bash", type: "toolCall" }, { id: "b", name: "read", type: "toolCall" }], role: "assistant" },
		type: "message_end",
	}));
	assert.match(out, /assistant · 2 tool calls: bash, read/);
	assert.doesNotMatch(out, /\{/);
});

test("tool durations never render 60s; sizes are UTF-8 bytes", () => {
	const out = formatTranscriptForDisplay([
		stream(0, { toolCallId: "c1", toolName: "bash", type: "tool_execution_start" }),
		stream(119.5, { toolCallId: "c1", toolName: "bash", type: "tool_execution_end", result: "café" }),
	].join("\n"));
	assert.match(out, /2m 0s/);
	assert.doesNotMatch(out, /60s/);
	assert.match(out, /5B/);
});

test("id-less same-named tool calls pair first-started-first-ended", () => {
	const out = formatTranscriptForDisplay([
		stream(0, { args: { command: "first" }, toolName: "bash", type: "tool_execution_start" }),
		stream(1, { args: { command: "second" }, toolName: "bash", type: "tool_execution_start" }),
		stream(2, { toolName: "bash", type: "tool_execution_end", status: "ok" }),
		stream(10, { toolName: "bash", type: "tool_execution_end", status: "ok" }),
	].join("\n"));
	const rows = out.split("\n");
	assert.match(rows[0]!, /tool bash \(first\) · ok · 2\.0s/);
	assert.match(rows[1]!, /tool bash \(second\) · ok · 9\.0s/);
});

test("user input, turn boundaries, and elapsed stamps", () => {
	const out = formatTranscriptForDisplay([
		line({ agent: "reviewer", task: "review the diff", ts: at(0), type: "start" }),
		stream(0, { source: "user", streamingBehavior: "steer", text: "look again", type: "input" }),
		stream(83, { type: "turn_end" }),
	].join("\n"));
	assert.match(out, /\[0:00\] session start · reviewer/);
	assert.match(out, /\[0:00\] input \(steer, user\) · look again/);
	assert.match(out, /\[1:23\] turn end/);
});

test("message_start and turn_start are deliberately elided", () => {
	const out = formatTranscriptForDisplay([
		stream(0, { type: "turn_start" }),
		stream(0, { message: { role: "assistant" }, type: "message_start" }),
	].join("\n"));
	assert.equal(out, "");
});

test("process_error carries its message and the failure tone", () => {
	const out = formatTranscriptForDisplay(line({ error: "spawn ENOENT", ts: at(0), type: "process_error" }));
	assert.match(out, /^✖\[0:00\] process_error · spawn ENOENT$/);
});

test("errors, diagnostics, and non-zero exits are distinct rows; exit 0 is not", () => {
	const out = formatTranscriptForDisplay([
		line({ diagnostic: "transcript write failed", ts: at(0), type: "diagnostic" }),
		stream(1, { message: "boom", type: "error" }),
		line({ code: 1, ts: at(2), type: "exit" }),
	].join("\n"));
	for (const row of out.split("\n")) assert.match(row, /^✖/);
	assert.match(formatTranscriptForDisplay(line({ code: 0, ts: at(0), type: "exit" })), /^ \[0:00\] exit · code 0$/);
});

test("an unparseable line renders labeled with its size, not verbatim", () => {
	const fragment = '":{"partial json fragment' + "z".repeat(100);
	const out = formatTranscriptForDisplay(fragment);
	assert.match(out, /^✖.*unparseable line · 125B$/m);
	assert.doesNotMatch(out, /partial json fragment/);
});

test("decoded control sequences never reach the terminal", () => {
	const out = formatTranscriptForDisplay(stream(0, {
		message: { content: [{ text: "safe\u001b]52;c;evil\u0007text\u009bmore", type: "text" }], role: "assistant" },
		type: "message_end",
	}));
	assert.doesNotMatch(out, /[\u0000-\u0008\u000B-\u001F\u007F-\u009F]/);
	assert.match(out, /safe.*text.*more/);
});

test("native pane-session message records render as content, not failures", () => {
	const out = formatTranscriptForDisplay(line({ message: { content: [{ text: "pane says hi", type: "text" }], role: "assistant" }, ts: at(0), type: "message" }));
	assert.match(out, /^ \[0:00\] assistant · pane says hi$/);
});

test("benign lifecycle records are neutral rows; trouble-shaped ones are not", () => {
	const benign = formatTranscriptForDisplay(line({ ts: at(0), type: "settled_shutdown" }));
	assert.match(benign, /^ \[0:00\] settled_shutdown/);
	const trouble = formatTranscriptForDisplay(line({ diagnostic: "close hung", ts: at(0), type: "abort_close_timeout" }));
	assert.match(trouble, /^✖\[0:00\] abort_close_timeout · close hung$/);
});

test("droppedEvents is stated up front", () => {
	const out = formatTranscriptForDisplay(stream(0, { type: "turn_end" }), { droppedEvents: 3 });
	assert.match(out.split("\n")[0]!, /↑ 3 earlier events not shown/);
});

const TMP = mkdtempSync(join(tmpdir(), "transcript-tail-"));
after(() => rmSync(TMP, { force: true, recursive: true }));

test("readTranscriptTail cuts on a line boundary and counts dropped events", async () => {
	const path = join(TMP, "t.jsonl");
	const records = Array.from({ length: 50 }, (_, index) => line({ index, ts: at(index), type: "turn_end" }));
	writeFileSync(path, `${records.join("\n")}\n`);
	const whole = await readTranscriptTail(path);
	assert.equal(whole?.droppedLines, 0);
	const tail = await readTranscriptTail(path, 500);
	assert.ok(tail && tail.droppedLines > 0, "expected a cut");
	assert.equal(tail!.droppedLines + tail!.text.split("\n").filter(Boolean).length, 50);
	for (const kept of tail!.text.split("\n").filter(Boolean)) assert.doesNotThrow(() => JSON.parse(kept));
	assert.equal(await readTranscriptTail(join(TMP, "missing.jsonl")), undefined);
});
