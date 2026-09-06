// The mini dashboard widget: which item a registry sync keeps, row order,
// the `<agent> #N` label, the working-row activity, the expanded message
// lines and the spinner setting.

import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { buildMonitorSessionGroups, monitorTreeRows, renderMonitorSessionDetail, renderMonitorTree, taskNumberById } from "../extensions/subagent/browser.js";
import { dashboardStatusIcon, latestDashboardActivity, renderDashboardWidgetLines, shouldReplaceDashboardItem, sortDashboardItems } from "../extensions/subagent/dashboard.js";
import { animateSpinnersEnabled } from "../extensions/subagent/settings.js";
import { readTaskRegistry, updateTaskRegistry } from "../extensions/subagent/tasks.js";
import { ICONS, type SubagentDashboardItem, type SubagentDashboardState } from "../extensions/subagent/types.js";
import { ABSENT, cleanupTempRuntimes, dashboardItem, record, stripAnsi, tempRuntime, theme, uiState, withTempPiUserDir, writeSettings, writeUserSettings } from "./browser-fixture.js";

after(cleanupTempRuntimes);

const SPINNER = /^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]$/;

function widget(cwd: string, items: SubagentDashboardItem[], mode: SubagentDashboardState["mode"] = "normal", numbers?: Map<string, number>): string {
	const state: SubagentDashboardState = { collapsed: false, mode, visible: true, items: Object.fromEntries(items.map((item, index) => [String(index), item])) };
	return stripAnsi(renderDashboardWidgetLines(state, theme as any, cwd, 220, numbers).join("\n"));
}

const paneA = dashboardItem({ agent: "rust", kind: "pane", startedAt: "2026-07-05T00:22:19.571Z", taskId: "rust-1783210939571-15037f22b196ea06", transcriptPath: "/tmp/rust.jsonl" });
const paneB = dashboardItem({ agent: "rust", kind: "pane", startedAt: "2026-07-06T07:17:30.697Z", taskId: "rust-1783322250697-13a5f30687e99d16", transcriptPath: "/tmp/rust.jsonl" });
const paneAAgain = dashboardItem({ agent: "rust", kind: "pane", startedAt: paneA.startedAt, taskId: "rust-1783210939571-00000000aaaaaaaa" });

// label | existing | next | expect
const replaceRows: Array<[string, SubagentDashboardItem | undefined, SubagentDashboardItem, boolean]> = [
	["no existing row", undefined, paneA, true],
	["a bg item always replaces", paneB, { ...paneA, kind: "oneshot" }, true],
	["the same pane task refreshes in place", paneB, { ...paneB, usage: { input: 1, output: 2, cacheRead: 3, cacheWrite: 4, cost: 5, contextTokens: 6, turns: 7 } }, true],
	["a newer pane task replaces", paneA, paneB, true],
	["an older pane task from a registry sweep is kept out", paneB, paneA, false],
	["the same start: the lower task id is kept out", paneA, paneAAgain, false],
	["the same start: the higher task id replaces", paneAAgain, paneA, true],
];

test("which dashboard item a registry sync keeps", () => {
	for (const [label, existing, next, expect] of replaceRows) {
		assert.equal(shouldReplaceDashboardItem(existing, next), expect, label);
	}
});

test("row order: working, attention, completed, each newest start first, never updatedAt", () => {
	const items = [
		dashboardItem({ agent: "reviewer-doc", taskId: "completed-newest", status: "completed", startedAt: "2026-05-14T05:25:00.000Z", updatedAt: "2026-05-14T05:26:00.000Z" }),
		dashboardItem({ agent: "reviewer-arch", taskId: "failed-old", status: "failed", startedAt: "2026-05-14T05:15:00.000Z", updatedAt: "2026-05-14T05:40:00.000Z" }),
		dashboardItem({ agent: "rust", taskId: "running-old", status: "running", startedAt: "2026-05-14T05:00:00.000Z", updatedAt: "2026-05-14T05:30:00.000Z" }),
		dashboardItem({ agent: "reviewer-test", taskId: "failed-new", status: "failed", startedAt: "2026-05-14T05:20:00.000Z", updatedAt: "2026-05-14T05:21:00.000Z" }),
		dashboardItem({ agent: "scout", taskId: "running-new", status: "running", startedAt: "2026-05-14T05:10:00.000Z", updatedAt: "2026-05-14T05:11:00.000Z" }),
	];
	assert.deepEqual(sortDashboardItems(items).map((item) => item.taskId), ["running-new", "running-old", "failed-new", "failed-old", "completed-newest"]);
});

const first = dashboardItem({ taskId: "reviewer-arch-1700000000-aaaaaaaa", startedAt: "2026-05-14T05:00:00.000Z" });
const second = dashboardItem({ taskId: "reviewer-arch-1700000060-bbbbbbbb", startedAt: "2026-05-14T05:01:00.000Z" });

// The labels the widget prints, in row order.
function labels(rendered: string): string[] {
	return rendered.match(/reviewer-arch(?: #\d+)?/g) ?? [];
}

// label | items | persisted numbers | expect labels in row order
const labelRows: Array<[string, SubagentDashboardItem[], Map<string, number> | undefined, string[]]> = [
	["a lone task carries no number", [first], undefined, ["reviewer-arch"]],
	["the second occurrence is #2, the first stays bare", [first, second], undefined, ["reviewer-arch #2", "reviewer-arch"]],
	["persisted session-local 1s fall through to occurrence", [first, second], new Map([[first.taskId, 1], [second.taskId, 1]]), ["reviewer-arch #2", "reviewer-arch"]],
	["a persisted number above 1 wins over occurrence", [first, second], new Map([[first.taskId, 1], [second.taskId, 3]]), ["reviewer-arch #3", "reviewer-arch"]],
];

test("row label numbering", () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { dashboard: true });
	for (const [label, items, numbers, expect] of labelRows) {
		assert.deepEqual(labels(widget(cwd, items, "normal", numbers)), expect, label);
	}
});

// The chip after the lane label on the widget's only row.
function widgetChip(rendered: string): string {
	return rendered.match(/reviewer-arch · completed · (?:bg|pane)(?: · (\S+))?/)?.[1] ?? ABSENT;
}

// label | item patch | expect chip
const chipRows: Array<[string, Partial<SubagentDashboardItem>, string]> = [
	["bg fresh", { sessionMode: "fresh" }, "fresh"],
	["bg resumed on a lane", { sessionMode: "resumed", sessionKey: "very-long-session-key" }, "lane:very-l…-key"],
	["pane new", { kind: "pane", sessionMode: "new" }, "new"],
	["pane resumed", { kind: "pane", sessionMode: "resumed" }, "resumed"],
	["corrupt mode carries no chip", { sessionMode: "foo" as any }, ABSENT],
];

test("the widget row forwards the session-mode chip", () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { dashboard: true });
	for (const [label, patch, expect] of chipRows) {
		assert.equal(widgetChip(widget(cwd, [dashboardItem(patch)])), expect, label);
	}
});

test("two bg launches of one agent persist as session-local #1 each", async () => {
	const cwd = tempRuntime();
	const recordA = record("reviewer-arch", first.taskId, "2026-05-14T05:00:00.000Z", { kind: "oneshot" });
	const recordB = record("reviewer-arch", second.taskId, "2026-05-14T05:01:00.000Z", { kind: "oneshot", status: "running" });
	await updateTaskRegistry(cwd, (records) => { records[recordA.taskId] = recordA; records[recordB.taskId] = recordB; });
	const numbers = taskNumberById(Object.values(await readTaskRegistry(cwd)));
	assert.deepEqual([numbers.get(recordA.taskId), numbers.get(recordB.taskId)], [1, 1]);
});

const toolCallTranscript = [
	JSON.stringify({ event: { type: "message_end", message: { role: "user", content: [{ type: "text", text: "Task: initial prompt" }] } } }),
	JSON.stringify({ event: { type: "message_end", message: { role: "assistant", content: [{ type: "toolCall", name: "Bash" }] } } }),
];
const bridgeTranscript = [
	JSON.stringify({ ts: "2026-05-14T05:00:00.000Z", event: { type: "event", event: "message_end", data: { message: { role: "assistant", content: [{ type: "text", text: "Bridge summary" }] } } } }),
	JSON.stringify({ ts: "2026-05-14T05:02:00.000Z", type: "event", event: "message_end", data: { message: { role: "assistant", content: [{ type: "text", text: "Raw bridge summary" }] } } }),
];

// label | transcript lines (none = no transcript) | item patch | expect
const activityRows: Array<[string, string[] | undefined, Partial<SubagentDashboardItem>, string]> = [
	["the latest agent action, not the prompt", toolCallTranscript, { status: "running", task: "initial prompt", message: "initial prompt" }, "tool: Bash"],
	["the latest assistant text through a raw bridge shape", bridgeTranscript, { status: "running" }, "said: Raw bridge summary"],
	["no transcript while running: nothing, never the prompt", undefined, { status: "running", task: "initial prompt", message: "initial prompt" }, ABSENT],
	["queued with a task", undefined, { status: "queued", task: "initial  prompt" }, "queued: initial prompt"],
	["queued without a task", undefined, { status: "queued", task: undefined }, "queued"],
];

test("latest activity of a working row", () => {
	const cwd = tempRuntime();
	for (const [index, [label, lines, patch, expect]] of activityRows.entries()) {
		let transcriptPath: string | undefined;
		if (lines) {
			transcriptPath = join(cwd, `activity-${index}.jsonl`);
			writeFileSync(transcriptPath, lines.join("\n"));
		}
		assert.equal(latestDashboardActivity(dashboardItem({ ...patch, transcriptPath })) ?? ABSENT, expect, label);
	}
});

test("the compact widget prints the activity, not the prompt", () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { dashboard: true });
	const transcriptPath = join(cwd, "compact.jsonl");
	writeFileSync(transcriptPath, toolCallTranscript.join("\n"));
	const rendered = widget(cwd, [dashboardItem({ status: "running", task: "initial prompt", message: "initial prompt", transcriptPath })], "compact");
	const promptOnly = widget(cwd, [dashboardItem({ status: "running", task: "initial prompt", message: "initial prompt" })], "compact");
	assert.equal([/tool: Bash/.test(rendered), /initial prompt/.test(rendered), /initial prompt/.test(promptOnly)].join(","), "true,false,false");
});

// The expanded message lines, each as `<branch> <direction> <text>`.
function messageLines(rendered: string): string[] {
	return rendered.split("\n").flatMap((line) => {
		const match = line.match(/(├─|└─|\|--|`--)\s*(->|<-) (.*?)\s*$/);
		return match ? [`${match[1]} ${match[2]} ${match[3]}`] : [];
	});
}

// label | settings | item patch | expect message lines
const expandedRows: Array<[string, Record<string, unknown>, Partial<SubagentDashboardItem>, string[]]> = [
	["inbound prompt then outbound result", { dashboard: true }, { status: "completed", task: "Inspect tests", message: "No gaps found.", messageProvenance: "persisted" }, ["├─ -> Inspect tests", "└─ <- No gaps found."]],
	["a steer delivery is labelled; a working row has no outbound line", { dashboard: true }, { status: "running", task: "Focus on failing tests", message: "partial", deliverAs: "steer" }, ["└─ -> steer Focus on failing tests"]],
	["ascii tree connectors", { dashboard: true, treeStyle: "ascii" }, { status: "completed", task: "Inspect tests", message: "No gaps found.", messageProvenance: "persisted" }, ["|-- -> Inspect tests", "`-- <- No gaps found."]],
	["a message echoing the task is not an outbound line", { dashboard: true }, { status: "completed", task: "Inspect tests", message: "Inspect  tests", messageProvenance: "persisted" }, ["└─ -> Inspect tests"]],
	["a task-echo fallback is not an outbound line", { dashboard: true }, { status: "completed", task: "Inspect tests", message: "No gaps found.", messageProvenance: "task-echo-fallback" }, ["└─ -> Inspect tests"]],
	["a placeholder is not an outbound line", { dashboard: true }, { status: "completed", task: "Inspect tests", message: "No gaps found.", messageProvenance: "placeholder" }, ["└─ -> Inspect tests"]],
];

test("expanded message lines", () => {
	for (const [label, settings, patch, expect] of expandedRows) {
		const cwd = tempRuntime();
		writeSettings(cwd, settings);
		assert.deepEqual(messageLines(widget(cwd, [dashboardItem(patch)], "expanded")), expect, label);
	}
});

// label | status | animateSpinners | expect icon class
const iconRows: Array<[string, SubagentDashboardItem["status"], boolean, "spinner" | "cog" | "check"]> = [
	["running, animated", "running", true, "spinner"],
	["running, static gear", "running", false, "cog"],
	["completed ignores the setting", "completed", false, "check"],
];

function iconClass(icon: string): string {
	if (SPINNER.test(icon)) return "spinner";
	if (icon === ICONS.cog) return "cog";
	if (icon === ICONS.check) return "check";
	return `other:${icon}`;
}

test("status icon under the spinner setting", () => {
	for (const [label, status, animate, expect] of iconRows) {
		assert.equal(iconClass(dashboardStatusIcon(status, theme as any, { animateSpinners: animate })), expect, label);
	}
});

// The icon each surface prints for a running task: the first character of
// its task line after the frame and the tree branch.
function runningIcon(lines: string[], marker: RegExp): string {
	const line = lines.map(stripAnsi).find((candidate) => marker.test(candidate)) ?? "";
	return iconClass(line.replace(/^[┃|]\s*/, "").replace(/^(├─|└─|\|--|`--)\s*/, "").trim().charAt(0));
}

// label | surface | expect icon class with animateSpinners=false in the project settings
const surfaceRows: Array<[string, "widget" | "tree" | "detail", string]> = [
	["the widget reads the setting", "widget", "cog"],
	["the Monitor tree takes the flag", "tree", "cog"],
	["the session detail takes the flag", "detail", "cog"],
];

test("a static gear replaces the spinner on every surface", () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { dashboard: true, animateSpinners: false });
	const running = record("planner", "planner-1700000000-aaaaaaaa", "2026-05-14T05:00:00.000Z", { kind: "pane", status: "running" });
	const animate = animateSpinnersEnabled(cwd);
	const groups = buildMonitorSessionGroups([running]);
	for (const [label, surface, expect] of surfaceRows) {
		const observed = surface === "widget"
			? runningIcon(widget(cwd, [dashboardItem({ status: "running" })]).split("\n"), /reviewer-arch/)
			: surface === "tree"
				? runningIcon(renderMonitorTree(monitorTreeRows(groups), [running], new Set(), uiState({ tab: "monitor", pane: "list" }), 120, theme as any, 10, animate), /Task ·/)
				: runningIcon(renderMonitorSessionDetail(groups[0], taskNumberById([running]), uiState({ tab: "monitor" }), 140, 20, theme as any, animate), /Task ·/);
		assert.equal(observed, expect, label);
	}
});

// label | user settings | project settings | expect animateSpinnersEnabled
const precedenceRows: Array<[string, Record<string, unknown> | undefined, Record<string, unknown> | undefined, boolean]> = [
	["no settings: on", undefined, undefined, true],
	["a non-boolean project value is ignored", undefined, { animateSpinners: "no" }, true],
	["a user false holds when the project is silent", { animateSpinners: false }, undefined, false],
	["a project true overrides a user false", { animateSpinners: false }, { animateSpinners: true }, true],
	["a project false overrides a user true", { animateSpinners: true }, { animateSpinners: false }, false],
];

test("spinner setting precedence", () => {
	for (const [label, user, project, expect] of precedenceRows) {
		withTempPiUserDir((userDir) => {
			const cwd = tempRuntime();
			if (user) writeUserSettings(userDir, user);
			if (project) writeSettings(cwd, project);
			assert.equal(animateSpinnersEnabled(cwd), expect, label);
		});
	}
});
