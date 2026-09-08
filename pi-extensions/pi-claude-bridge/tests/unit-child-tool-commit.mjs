import { it } from "node:test";
import assert from "node:assert/strict";
import { QueryContext } from "../src/query-state.ts";
import { model } from "./lib/tool-stream.mjs";

const connector = "mcp__claude_ai_Slack__slack_read_user_profile";
const rows = [
	["child-internal tools", [["t1", "ToolSearch", 0], ["t2", "ScheduleWakeup"]], false],
	["connector with call id", [["c1", connector, 0]], true],
	["connector without call id or index", [[undefined, connector]], true],
];
for (const [name, calls, expected] of rows) it(name, () => {
	const query = new QueryContext();
	for (const call of calls) query.noteChildExecutedToolCall(...call);
	assert.equal(query.committedOutput, expected);
});
it("turn reset retains the query's commit boundary", () => {
	const query = new QueryContext();
	query.noteChildExecutedToolCall("c1", connector, 0);
	query.resetTurnState(model);
	assert.equal(query.committedOutput, true);
});
