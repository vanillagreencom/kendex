// The subagent tool renderer: the status line a result collapses to, the
// chip it forwards, and what the quiet-dashboard setting hides.

import assert from "node:assert/strict";
import test, { after } from "node:test";
import { subagentToolRenderers } from "../extensions/subagent/subagent-render.js";
import type { SingleResult, SubagentDetails } from "../extensions/subagent/types.js";
import { cleanupTempRuntimes, stripAnsi, tempRuntime, theme, writeProjectAgent, writeSettings } from "./browser-fixture.js";

after(cleanupTempRuntimes);

function singleResult(patch: Partial<SingleResult> = {}): SingleResult {
	return {
		agent: "reviewer-arch",
		agentSource: "project",
		exitCode: 0,
		messages: [{ role: "assistant", content: [{ type: "text", text: "done" }], timestamp: Date.now() } as any],
		stderr: "",
		task: "Review architecture.",
		taskId: "reviewer-arch-1700000000-aaaaaaaa",
		usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
		...patch,
	};
}

function renderResult(result: SingleResult, cwd: string): string {
	const details: SubagentDetails = { mode: "single", agentScope: "project", projectAgentsDir: null, results: [result] };
	return stripAnsi(subagentToolRenderers.renderResult({ content: [{ type: "text", text: "done" }], details }, {}, theme, { cwd }).render(220).join("\n"));
}

// The status line: `Agent <name> <status> · <lane>[ · <chip>]`, read off the
// first line so a chip can only come from the renderer's own suffix.
function statusLine(rendered: string): string {
	return rendered.split("\n")[0]!.replace(/\s+· ctrl\+o to expand$/, "").replace(/^[^A-Za-z]+/, "").trim();
}

// label | result patch | expect
const chipRows: Array<[string, Partial<SingleResult>, string]> = [
	["bg fresh", { sessionMode: "fresh" }, "Agent reviewer-arch completed · bg · fresh"],
	["bg resumed on an explicit lane", { sessionMode: "resumed", sessionKey: "very-long-session-key", sessionKeyExplicit: true }, "Agent reviewer-arch completed · bg · lane:very-l…-key"],
	["bg resumed on a minted lane hides the key", { sessionMode: "resumed", sessionKey: "very-long-session-key", sessionKeyExplicit: false }, "Agent reviewer-arch completed · bg · resumed"],
	["queued pane, new session", { paneId: "%1", paneSessionMode: "new", sessionMode: "new" }, "Agent reviewer-arch Queued task · pane · new"],
	["queued pane, live session reads as resumed", { paneId: "%1", paneSessionMode: "live" }, "Agent reviewer-arch Queued task · pane · resumed"],
	["corrupt mode carries no chip", { sessionMode: "foo" as any }, "Agent reviewer-arch completed · bg"],
	["running result reads as working", { exitCode: -1, messages: [] }, "Agent reviewer-arch working · bg"],
];

test("result status line and chip", () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { dashboard: true, quietInlineWhenDashboard: true });
	for (const [label, patch, expect] of chipRows) {
		assert.equal(statusLine(renderResult(singleResult(patch), cwd)), expect, label);
	}
});

// label | dashboard | quiet | expect call preview
const quietRows: Array<[string, boolean, boolean, string]> = [
	["dashboard on and quiet on: the single bg call preview is suppressed", true, true, ""],
	["dashboard off: the preview renders", false, true, "Agent scout\n└─ Inspect duplicate output."],
	["quiet off: the preview renders", true, false, "Agent scout\n└─ Inspect duplicate output."],
];

test("quiet dashboard hides the single bg call preview", () => {
	for (const [label, dashboard, quiet, expect] of quietRows) {
		const cwd = tempRuntime();
		writeSettings(cwd, { dashboard, quietInlineWhenDashboard: quiet });
		writeProjectAgent(cwd, "scout");
		const rendered = stripAnsi(subagentToolRenderers.renderCall({ agent: "scout", task: "Inspect duplicate output." }, theme, { cwd }).render(220).join("\n"));
		assert.equal(rendered.replace(/^[^\w\n└]+/gm, "").replace(/[ \t]+$/gm, ""), expect, label);
	}
});
