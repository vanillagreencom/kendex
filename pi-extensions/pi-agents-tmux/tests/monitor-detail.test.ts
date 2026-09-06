// The Monitor detail pane: the session detail's metadata lines, the task
// trace's Summary, Completion and Transcript tabs, and the subtab clamp.

import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { buildMonitorSessionGroups, monitorSubtabCount, renderMonitorDetail, renderMonitorSessionDetail, taskNumberById, traceViewerItems } from "../extensions/subagent/browser.js";
import type { PaneTaskRecord } from "../extensions/subagent/types.js";
import { ABSENT, agent, cleanupTempRuntimes, fields, labelledLines, record, stripAnsi, tempRuntime, theme, uiState } from "./browser-fixture.js";

after(cleanupTempRuntimes);

const at = (minute: number) => `2026-05-14T05:${String(minute).padStart(2, "0")}:00.000Z`;
const SESSION_LABELS = ["Agent", "Session type", "Session #", "Model", "Effort", "Session", "Start", "Latest", "Duration", "Tasks", "Usage", "Pane ID", "Transcript", "SessionKey"];
// Start and Latest print local wall time; the row pins their presence as `<local>`.
const LOCAL_TIME = /^[A-Z][a-z]{2} \d{1,2}, \d{2}:\d{2}$/;

function sessionDetail(records: PaneTaskRecord[], pick: string[], discovery?: { agents: ReturnType<typeof agent>[] }, groupIndex = 0): Record<string, string> {
	const groups = buildMonitorSessionGroups(records);
	const rendered = renderMonitorSessionDetail(groups[groupIndex], taskNumberById(records), uiState({ tab: "monitor" }), 160, 40, theme as any, true, discovery).join("\n");
	const out = fields(labelledLines(rendered), pick);
	for (const key of ["Start", "Latest"]) if (LOCAL_TIME.test(out[key] ?? "")) out[key] = "<local>";
	return out;
}

const lane = record("reviewer-arch", "reviewer-arch-session", at(0), { effort: "xhigh", model: "openai-codex/gpt-6-astra:xhigh", sessionKey: "feature-x", sessionMode: "resumed" });
const paneDone = record("planner", "planner-1700000000-aaaaaaaa", at(0), { kind: "pane", paneId: "%1", sessionMode: "resumed", transcriptPath: "/tmp/planner-session.jsonl", usage: { input: 10, output: 20, cacheRead: 30, cacheWrite: 40, cost: 0.01, contextTokens: 50, turns: 1 } });
const paneRunning = record("planner", "planner-1700000060-bbbbbbbb", at(1), { kind: "pane", paneId: "%1", sessionMode: "resumed", status: "running", completedAt: undefined, usage: { input: 1, output: 2, cacheRead: 3, cacheWrite: 4, cost: 0.02, contextTokens: 5, turns: 2 } });
const shotA = record("reviewer-arch", "reviewer-arch-1700000000-11111111", at(0), { kind: "oneshot", sessionMode: "fresh", transcriptPath: "/tmp/a.jsonl" });
const shotB = record("reviewer-arch", "reviewer-arch-1700000120-77abfc41", at(2), { kind: "oneshot", sessionMode: "fresh", transcriptPath: "/tmp/b.jsonl" });

// label | records | group index | expect metadata (every SESSION_LABELS key)
const sessionRows: Array<[string, PaneTaskRecord[], number, Record<string, string>]> = [
	["a lane record owns agent, model, effort and session", [lane], 0, {
		Agent: "reviewer-arch", "Session type": "bg-lane", "Session #": ABSENT, Model: "openai-codex/gpt-6-astra", Effort: "xhigh", Session: "resumed · lane: feature-x",
		Start: "<local>", Latest: "<local>", Duration: "0s", Tasks: "1 task · completed:1", Usage: "—", "Pane ID": ABSENT, Transcript: ABSENT, SessionKey: "feature-x",
	}],
	["a pane session carries its pane id, transcript and status breakdown", [paneDone, paneRunning], 0, {
		Agent: "planner", "Session type": "pane", "Session #": ABSENT, Model: ABSENT, Effort: ABSENT, Session: "resumed",
		Start: "<local>", Latest: "<local>", Duration: "1m 0s", Tasks: "2 tasks · completed:1 · running:1", Usage: "3 turns ↑11 ↓22 R33 W44 $0.0300 ctx:55", "Pane ID": "%1", Transcript: "/tmp/planner-session.jsonl", SessionKey: ABSENT,
	}],
	["the second launch of an agent is session #2 with its own transcript", [shotA, shotB], 0, {
		Agent: "reviewer-arch", "Session type": "bg-one-shot", "Session #": "2", Model: ABSENT, Effort: ABSENT, Session: "fresh",
		Start: "<local>", Latest: "<local>", Duration: "0s", Tasks: "1 task · completed:1", Usage: "—", "Pane ID": ABSENT, Transcript: "/tmp/b.jsonl", SessionKey: ABSENT,
	}],
];

test("session detail metadata", () => {
	for (const [label, records, groupIndex, expect] of sessionRows) {
		assert.deepEqual(sessionDetail(records, SESSION_LABELS, { agents: [agent("reviewer-arch"), agent("planner", true)] }, groupIndex), expect, label);
	}
});

// A running task's time is its elapsed run-time (minute-granular), never a wall clock; read back as `<elapsed>`.
const ELAPSED = /^(\d+h \d{2}m|\d+m|<1m)$/;

test("the session detail header names the pane, not the session; a running row shows elapsed time", () => {
	const groups = buildMonitorSessionGroups([paneDone, paneRunning]);
	const lines = renderMonitorSessionDetail(groups[0], taskNumberById([paneDone, paneRunning]), uiState({ tab: "monitor" }), 140, 40, theme as any).map((line) => stripAnsi(line).replace(/\s+/g, " ").trim());
	const taskRows = lines.filter((line) => /^\S+ Task /.test(line)).map((line) => line.replace(/^\S+ Task /, "Task ").replace(/ · ([^·]+) · /, (_m, time: string) => ` · ${ELAPSED.test(time) ? "<elapsed>" : time} · `));
	assert.deepEqual([lines[0], taskRows], ["Detail", ["Task #2 · <elapsed> · running", "Task · 0s · completed"]]);
});

const SUMMARY_LABELS = ["Ref", "Task #", "Status", "Task ID", "Usage", "Delivery", "Created", "Done", "Duration", "Transcript", "Archive", "Completion", "Source", "Task file", "Agent", "Model", "Effort", "Session"];

// The Summary tab: its labelled lines, and each section after the labels as `heading=first body line`.
async function summaryTab(taskRecord: PaneTaskRecord, taskNumber?: number): Promise<{ lines: Record<string, string>; sections: string[] }> {
	const items = await traceViewerItems(taskRecord, taskNumber, { agents: [agent("planner", true, { effort: "xhigh" })] });
	const text = items[0]!.text;
	const all = text.split("\n");
	return { lines: fields(labelledLines(text), SUMMARY_LABELS), sections: all.flatMap((line, index) => (/^-{3,}$/.test(all[index + 1] ?? "") ? [`${line}=${all[index + 2] ?? ""}`] : [])) };
}

const fullRecord = record("planner", "planner-1700000120-bbbbbbbb", at(2), {
	model: "openai-codex/gpt-6-astra:xhigh",
	effort: "xhigh",
	summary: "completed planner summary",
	completionArchivePath: "/tmp/planner-completion.json",
	completionSourcePath: "/tmp/planner-source.json",
	transcriptPath: "/tmp/planner-transcript.jsonl",
	deliverAs: "follow-up",
});

test("the Summary tab carries the task's own lines and artifacts, never the session's metadata", async () => {
	const { lines, sections } = await summaryTab(fullRecord, 1);
	assert.deepEqual([lines, sections], [{
		Ref: lines.Ref, "Task #": ABSENT, Status: "completed", "Task ID": "planner-1700000120-bbbbbbbb", Usage: ABSENT, Delivery: "follow-up", Created: lines.Created, Done: lines.Done, Duration: "0s",
		Transcript: "/tmp/planner-transcript.jsonl", Archive: "/tmp/planner-completion.json", Completion: ABSENT, Source: "/tmp/planner-source.json", "Task file": ABSENT,
		Agent: ABSENT, Model: ABSENT, Effort: ABSENT, Session: ABSENT,
	}, ["Artifacts=Transcript  /tmp/planner-transcript.jsonl", "Task=Task for planner"]]);
	assert.notEqual(lines.Ref, ABSENT);
	assert.notEqual(lines.Created, ABSENT);
	assert.notEqual(lines.Done, ABSENT);
});

// label | task number | expect `Task #` line
const numberRows: Array<[string, number | undefined, string]> = [
	["#1 is suppressed", 1, ABSENT],
	["#2 is printed", 2, "2"],
	["no number is suppressed", undefined, ABSENT],
];

test("the Summary tab's task number", async () => {
	for (const [label, number, expect] of numberRows) {
		assert.equal((await summaryTab(fullRecord, number)).lines["Task #"], expect, label);
	}
});

// The Completion tab as `section=first line` pairs plus the item's path and type.
function completionShape(item: { path?: string; type: string; text: string }): string {
	const lines = item.text.split("\n");
	const sections = lines.flatMap((line, index) => (/^-{3,}$/.test(lines[index + 1] ?? "") ? [`${line}=${lines[index + 2] ?? ""}`] : []));
	return `path=${item.path ?? ABSENT} type=${item.type} ${sections.join(" | ")}`;
}

const longSummary = Array.from({ length: 80 }, (_, index) => `finding-${index}`).join(" ");

// label | record | expect
const completionRows: Array<[string, PaneTaskRecord, string]> = [
	["a completion path adds the JSON section, unreadable here", fullRecord, "path=/tmp/planner-completion.json type=summary Summary=completed planner summary | Files changed=None reported | Validation=None reported | Completion JSON=Completion JSON file could not be read."],
	["a bg record without a completion file has no JSON section", record("reviewer-doc", "reviewer-doc-1700000120-bg", at(2), { kind: "oneshot", sessionMode: "fresh", summary: "completed reviewer summary" }), `path=${ABSENT} type=summary Summary=completed reviewer summary | Files changed=None reported | Validation=None reported`],
	["a persisted summary is printed whole", record("reviewer-arch", "reviewer-arch-1700000000-77abfc41", at(0), { summary: longSummary, transcriptPath: "/tmp/reviewer-arch.jsonl" }), `path=${ABSENT} type=summary Summary=${longSummary} | Files changed=None reported | Validation=None reported`],
	["files and validation are listed", record("rust", "rust-1700000000-11111111", at(0), { summary: "done", filesChanged: ["a.rs", "b.rs"], validation: ["cargo test"] }), `path=${ABSENT} type=summary Summary=done | Files changed=- a.rs | Validation=- cargo test`],
	["a completed record without a summary reads unavailable", record("rust", "rust-1700000000-22222222", at(0), {}), `path=${ABSENT} type=summary Summary=completion summary unavailable; see transcript | Files changed=None reported | Validation=None reported`],
	["a running record has no summary yet", record("rust", "rust-1700000000-33333333", at(0), { status: "running", completedAt: undefined }), `path=${ABSENT} type=summary Summary=No summary yet. | Files changed=None reported | Validation=None reported`],
];

test("the Completion tab", async () => {
	for (const [label, taskRecord, expect] of completionRows) {
		const items = await traceViewerItems(taskRecord, 1);
		assert.equal(completionShape(items[1]!), expect, label);
	}
});

test("the Transcript tab exists only with a transcript path and reads the file", async () => {
	const dir = tempRuntime();
	const transcript = join(dir, "child-session.jsonl");
	writeFileSync(transcript, [
		JSON.stringify({ event: { type: "input", textPreview: "Please follow up after current turn", source: "extension", streamingBehavior: "followUp", textBytes: 35, imagesCount: 0 } }),
		JSON.stringify({ event: { type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "done with follow-up" }] } } }),
	].join("\n"));
	const withFile = await traceViewerItems(record("planner", "planner-1700000120-follow", at(2), { transcriptPath: transcript, summary: "s" }), 1);
	const missing = await traceViewerItems(record("planner", "planner-1700000120-missing", at(2), { transcriptPath: "/tmp/planner-transcript.jsonl", summary: "s" }), 1);
	const none = await traceViewerItems(record("planner", "planner-1700000120-none", at(2), { summary: "s" }), 1);
	assert.deepEqual(
		[withFile.map((item) => item.label), withFile[2]!.type, withFile[2]!.path, /assistant · done with follow-up/.test(withFile[2]!.text), missing[2]!.text, none.map((item) => item.label)],
		[["Summary", "Completion", "Transcript"], "transcript", transcript, true, "Transcript file could not be read.", ["Summary", "Completion"]],
	);
});

// label | entry | expect count
const countRows: Array<[string, Parameters<typeof monitorSubtabCount>[0], number]> = [
	["before items load: the placeholder count", undefined, 2],
	["while loading: the placeholder count", { loading: true }, 2],
	["loaded items: their count", { items: [{ label: "a", text: "", type: "summary" }, { label: "b", text: "", type: "summary" }, { label: "c", text: "", type: "transcript" }] as any }, 3],
];

test("subtab count", () => {
	for (const [label, entry, expect] of countRows) {
		assert.equal(monitorSubtabCount(entry), expect, label);
	}
});

// label | requested subtab | items loaded | expect `subtab after render, active tab text marker`
const clampRows: Array<[string, number, boolean, string]> = [
	["the Transcript subtab is reachable", 2, true, "2 Transcript file could not be read."],
	["a subtab past the end clamps to the last", 5, true, "2 Transcript file could not be read."],
	["before items load the placeholder tabs bound the clamp", 2, false, "1 Loading…"],
];

test("detail subtab clamp", async () => {
	const items = await traceViewerItems(fullRecord, 1);
	for (const [label, subtab, loaded, expect] of clampRows) {
		const ui = uiState({ tab: "monitor", pane: "inspector", monitorSubtab: subtab });
		const rendered = renderMonitorDetail(fullRecord, new Map([[fullRecord.taskId, loaded ? { items } : { loading: true }]]), ui, 120, 40, theme as any).map(stripAnsi).join("\n");
		const marker = /Transcript file could not be read\./.test(rendered) ? "Transcript file could not be read." : /Loading…/.test(rendered) ? "Loading…" : "other";
		assert.equal(`${ui.monitorSubtab} ${marker}`, expect, label);
	}
});
