import assert from "node:assert/strict";
import { it } from "node:test";
import { extractAllToolResults } from "../src/extract-tool-results.ts";

const user = (content = "prompt") => ({ role: "user", content });
const assistant = (...ids) => ({ role: "assistant", content: ids.map((id) => ({ type: "toolCall", id })) });
const result = (id, content, isError) => ({ role: "toolResult", toolCallId: id, content, isError });
const rows = [
	{ name: "single turn", messages: [user(), assistant("t1", "t2"), result("t1", "file1"), result("t2", "file2")], expected: [["t1", "file1"], ["t2", "file2"]], stopIdx: 1 },
	{ name: "multi-turn current results only", messages: [user(), assistant("t1", "t2"), result("t1", "old1"), result("t2", "old2"), assistant("t3"), result("t3", "new")], expected: [["t3", "new"]], stopIdx: 4 },
	{ name: "three turns", messages: [user(), assistant("t1"), result("t1", "turn1"), assistant("t2"), result("t2", "turn2"), assistant("t3", "t4"), result("t3", "turn3a"), result("t4", "turn3b")], expected: [["t3", "turn3a"], ["t4", "turn3b"]], stopIdx: 5 },
	{ name: "user tail without result", messages: [user(), assistant("t1"), user("steer")], expected: [], stopIdx: 1 },
	{ name: "user tail after result", messages: [user(), assistant("t1"), result("t1", "result"), user("steer")], expected: [["t1", "result"]], stopIdx: 1 },
	{ name: "user splits two results", messages: [user(), assistant("t1", "t2"), result("t1", "first"), user(), result("t2", "second")], expected: [["t1", "first"], ["t2", "second"]], stopIdx: 1 },
	{ name: "user splits five results", messages: [user(), assistant("t1", "t2", "t3", "t4", "t5"), result("t1", "r1"), result("t2", "r2"), result("t3", "r3"), user(), result("t4", "r4"), result("t5", "r5")], expected: [["t1", "r1"], ["t2", "r2"], ["t3", "r3"], ["t4", "r4"], ["t5", "r5"]], stopIdx: 1 },
	{ name: "multiple interleaved users", messages: [user(), assistant("t1", "t2", "t3"), result("t1", "r1"), user(), result("t2", "r2"), user(), result("t3", "r3")], expected: [["t1", "r1"], ["t2", "r2"], ["t3", "r3"]], stopIdx: 1 },
	{ name: "user before every result", messages: [user(), assistant("t1", "t2"), user(), result("t1", "r1"), user(), result("t2", "r2")], expected: [["t1", "r1"], ["t2", "r2"]], stopIdx: 1 },
	{ name: "assistant splits results", messages: [user(), assistant("t1", "t2"), result("t1", "old"), assistant(), result("t2", "new")], expected: [["t2", "new"]], stopIdx: 3 },
	{ name: "complete results across one injected user", messages: [user(), assistant("t1", "t2", "t3"), result("t1", "r1"), user(), result("t2", "r2"), result("t3", "r3")], expected: [["t1", "r1"], ["t2", "r2"], ["t3", "r3"]], stopIdx: 1 },
	{ name: "current turn interleaved after clean turn", messages: [user(), assistant("t1"), result("t1", "old"), assistant("t2", "t3"), result("t2", "r2"), user(), result("t3", "r3")], expected: [["t2", "r2"], ["t3", "r3"]], stopIdx: 3 },
	{ name: "interleaved error propagation", messages: [user(), assistant("t1", "t2"), result("t1", "ok", false), user(), result("t2", "failed", true)], expected: [["t1", "ok", false], ["t2", "failed", true]], stopIdx: 1 },
	{ name: "empty context", messages: [], expected: [], stopIdx: -1 },
	{ name: "only user", messages: [user()], expected: [], stopIdx: -1 },
	{ name: "orphan results", messages: [result("t1", "orphan1"), result("t2", "orphan2")], expected: [["t1", "orphan1"], ["t2", "orphan2"]], stopIdx: -1 },
	{ name: "single result", messages: [assistant("t1"), result("t1", "only")], expected: [["t1", "only"]], stopIdx: 0 },
	{ name: "consecutive user tail", messages: [assistant("t1"), result("t1", "result"), user(), user()], expected: [["t1", "result"]], stopIdx: 0 },
	{ name: "unanswered calls", messages: [user(), assistant("t1", "t2")], expected: [], stopIdx: 1 },
	{ name: "completed text without results", messages: [user(), { role: "assistant", content: [{ type: "text", text: "done" }] }], expected: [], stopIdx: 1 },
];
for (const row of rows) it(row.name, () => {
	assert.deepEqual(extractAllToolResults(row.messages), {
		results: row.expected.map(([toolCallId, text, isError]) => ({ toolCallId, content: [{ type: "text", text }], isError })),
		stopIdx: row.stopIdx,
	});
});
