import { it } from "node:test";
import assert from "node:assert/strict";
import { noteChildExecutedToolResults } from "../src/assistant-stream.ts";
import { QueryContext } from "../src/query-state.ts";
import { model } from "./lib/tool-stream.mjs";

const connector = "mcp__claude_ai_Slack__slack_read_user_profile";
const rows = [
	{ name: "records owned result without delivering it to Pi", message: { content: [{ type: "tool_result", tool_use_id: "toolu_conn", content: "User ID: US9TAA048" }] }, recorded: true },
	{ name: "ignores another tool's result", message: { content: [{ type: "tool_result", tool_use_id: "toolu_other", content: "x" }] }, recorded: false },
	{ name: "ignores child-internal result while connector is pending", internal: true, message: { content: [{ type: "tool_result", tool_use_id: "toolu_ts", content: "loaded 1 tool" }] }, recorded: false },
	{ name: "ignores plain user echo", message: { content: "just a prompt echo" }, recorded: false },
	{ name: "ignores absent user content", message: {}, recorded: false },
];
for (const row of rows) it(row.name, () => {
	const query = new QueryContext();
	query.resetTurnState(model);
	query.noteChildExecutedToolCall("toolu_conn", connector, 0);
	if (row.internal) query.noteChildExecutedToolCall("toolu_ts", "ToolSearch", 1);
	noteChildExecutedToolResults({ type: "user", message: row.message }, query);
	assert.deepEqual({
		queued: query.pendingResults.size,
		blocks: query.turnBlocks.length,
		childCalls: [...query.childExecutedToolCalls],
		audited: [...query.connectorCallAudit.keys()],
		recorded: query.connectorCallAudit.get("toolu_conn").recorded,
		internalIndex: query.childExecutedStreamIndexes.has(1),
	}, { queued: 0, blocks: 0, childCalls: [["toolu_conn", connector]], audited: ["toolu_conn"], recorded: row.recorded, internalIndex: row.internal === true });
});
