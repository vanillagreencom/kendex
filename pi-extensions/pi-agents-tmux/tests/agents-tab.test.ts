// The Agents tab: the catalog order, the list row chips, the Inspector's
// static lines and the frontmatter-edit key.

import assert from "node:assert/strict";
import test from "node:test";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import { buildAgentRows, isAgentFrontmatterEditShortcut, renderAgentInspector, renderAgentList } from "../extensions/subagent/browser.js";
import type { AgentPaneStatus } from "../extensions/subagent/types.js";
import { ABSENT, agent, fields, labelledLines, livePaneStatus, stripAnsi, theme, uiState } from "./browser-fixture.js";

const statuses = (entries: Array<[string, AgentPaneStatus]>) => new Map<string, AgentPaneStatus>(entries);

// label | agents | statuses | expect row labels
const orderRows: Array<[string, AgentConfig[], Map<string, AgentPaneStatus>, string[]]> = [
	["a flat catalog: panes before bg, then by name", [agent("scout"), agent("planner", true)], statuses([]), ["planner", "scout"]],
	["live panes, stopped panes, unstarted panes, bg", [agent("alpha"), agent("zeta", true), agent("mid", true), agent("beta", true)], statuses([["zeta", livePaneStatus("zeta")], ["mid", livePaneStatus("mid", {}, false)]]), ["zeta", "mid", "beta", "alpha"]],
];

test("catalog order", () => {
	for (const [label, agents, paneStatuses, expect] of orderRows) {
		assert.deepEqual(buildAgentRows(agents, paneStatuses).map((row) => row.label), expect, label);
	}
});

// Each list row as `[live ]name · kind · scope`.
function listRows(agents: AgentConfig[], paneStatuses: Map<string, AgentPaneStatus>): string[] {
	const rows = buildAgentRows(agents, paneStatuses);
	return renderAgentList(rows, paneStatuses, uiState({ selected: 0 }), 160, theme as any, 20)
		.map(stripAnsi)
		.flatMap((line) => {
			const match = line.match(/^\s*\S+ (live )?(\S+) · (pane|bg) · (project|user)\s*$/);
			return match ? [`${match[1] ?? ""}${match[2]} · ${match[3]} · ${match[4]}`] : [];
		});
}

test("list rows carry the kind and scope chips only", () => {
	const agents = [
		agent("planner", true, { model: "openai-codex/gpt-6-astra", source: "project" }),
		agent("scout", false, { model: "openai-codex/gpt-6-astra", source: "user", effort: "xhigh" }),
	];
	assert.deepEqual(listRows(agents, statuses([["planner", livePaneStatus("planner")]])), ["live planner · pane · project", "scout · bg · user"]);
});

const INSPECTOR_LABELS = ["Kind", "Scope", "Model", "Effort", "Deny tools", "Color", "Source path", "Pane", "Task ID", "Transcript", "Latest Message", "Last task", "Pane session"];

// The Inspector's first line, its labelled lines (the pane's clock time
// normalised) and whether the prompt body follows the System Prompt heading.
function inspector(config: AgentConfig, paneStatuses: Map<string, AgentPaneStatus>): { first: string; description: string; lines: Record<string, string>; prompt: boolean } {
	const rendered = renderAgentInspector(config, paneStatuses, uiState(), 120, 40, theme as any).map(stripAnsi);
	const text = rendered.join("\n");
	const lines = fields(labelledLines(text), INSPECTOR_LABELS);
	lines.Pane = lines.Pane!.replace(/\d{2}:\d{2}/, "<clock>");
	return {
		first: rendered[0]!.replace(/\s+/g, " ").trim(),
		description: rendered[2]!.trim(),
		lines,
		prompt: /System Prompt\n[\s\S]*Planner system prompt body\./.test(text),
	};
}

const full = agent("planner", true, {
	color: "orange",
	denyTools: ["subagent", "question"],
	description: "Plans implementation work.",
	effort: "xhigh",
	filePath: ".pi/agents/planner.md",
	model: "openai-codex/gpt-6-astra",
	systemPrompt: "Planner system prompt body.",
});
const fullLines = { Kind: "persistent pane", Scope: "project", Model: "openai-codex/gpt-6-astra", Effort: "xhigh", "Deny tools": "subagent, question", Color: "orange", "Source path": ".pi/agents/planner.md", "Task ID": ABSENT, Transcript: ABSENT, "Latest Message": ABSENT, "Last task": ABSENT, "Pane session": ABSENT };
const liveWithTask = statuses([["planner", livePaneStatus("planner", { lastTaskAt: "2026-05-14T05:02:00.000Z", lastTaskId: "planner-1700000120-bbbbbbbb", sessionFile: "/tmp/planner-transcript.jsonl" })]]);

// label | config | statuses | expect
const inspectorRows: Array<[string, AgentConfig, Map<string, AgentPaneStatus>, ReturnType<typeof inspector>]> = [
	["a live pane with a task shows static config only", full, liveWithTask, { first: "Inspector planner", description: "Plans implementation work.", lines: { ...fullLines, Pane: "running (started <clock>)" }, prompt: true }],
	["a stopped pane", full, statuses([["planner", livePaneStatus("planner", {}, false)]]), { first: "Inspector planner", description: "Plans implementation work.", lines: { ...fullLines, Pane: "stopped" }, prompt: true }],
	["an unstarted pane", full, statuses([]), { first: "Inspector planner", description: "Plans implementation work.", lines: { ...fullLines, Pane: "not started" }, prompt: true }],
	["a bg agent with defaults; effort read off the model suffix", agent("scout", false, { systemPrompt: "Planner system prompt body.", model: "openai-codex/gpt-6-astra:xhigh" }), statuses([]), {
		first: "Inspector scout",
		description: "scout agent",
		lines: { Kind: "bg", Scope: "project", Model: "openai-codex/gpt-6-astra", Effort: "xhigh", "Deny tools": "none", Color: "default", "Source path": "scout.md", Pane: ABSENT, "Task ID": ABSENT, Transcript: ABSENT, "Latest Message": ABSENT, "Last task": ABSENT, "Pane session": ABSENT },
		prompt: true,
	}],
];

test("the Inspector", () => {
	for (const [label, config, paneStatuses, expect] of inspectorRows) {
		assert.deepEqual(inspector(config, paneStatuses), expect, label);
	}
});

// label | input bytes | expect
const keyRows: Array<[string, string, boolean]> = [
	["ESC g", "\x1bg", true],
	["CSI u alt+g", "\x1b[103;3u", true],
	["ESC m", "\x1bm", false],
	["CSI u alt+m", "\x1b[109;3u", false],
	["CSI u ctrl+g", "\x1b[103;5u", false],
];

test("the frontmatter-edit key", () => {
	for (const [label, input, expect] of keyRows) {
		assert.equal(isAgentFrontmatterEditShortcut(input), expect, label);
	}
});
