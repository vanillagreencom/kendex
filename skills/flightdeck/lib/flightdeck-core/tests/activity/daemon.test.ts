import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
	daemonStoppedSeverity,
	emitActivityForWakeRow,
	emitDaemonStarted,
	emitDaemonStopped,
	emitMaxLifetimeHandoff,
	emitSubscriberDead,
	emitSubscriberReattached,
	emitSubscriberStarted,
	type DaemonActivityContext,
} from "../../src/daemon/activity.ts";
import { appendEvent } from "../../src/daemon/events.ts";
import { wakeMaster } from "../../src/daemon/wake.ts";

interface ActivityRow {
	type: string;
	severity: string;
	importance: string;
	summary: string;
	source?: string;
	pane_id?: string;
	harness?: string;
	refs?: Record<string, unknown>;
	details?: Record<string, unknown>;
}

let dir = "";
function path(name: string): string { return join(dir, name); }
function activityPath(): string { return path("activity.jsonl"); }
function ctx(): DaemonActivityContext { return { activityPath: activityPath(), sessionId: "S" }; }

beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "fd-daemon-activity-")); });
afterEach(() => { if (dir && existsSync(dir)) rmSync(dir, { force: true, recursive: true }); });

function activityRows(): ActivityRow[] {
	if (!existsSync(activityPath())) return [];
	return readFileSync(activityPath(), "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line) as ActivityRow);
}

function wakeRows(): unknown[] {
	const file = path("events.jsonl");
	if (!existsSync(file)) return [];
	return readFileSync(file, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line) as unknown);
}

function appendWake(tag: string, extraJson?: string): boolean {
	return appendEvent({
		ageSec: 0,
		eventsFile: path("events.jsonl"),
		hash: `hash-${tag}`,
		isBell: false,
		lastEventKey: new Map(),
		paneId: "%101",
		reason: "test",
		sessionLock: path("session.lock"),
		tag,
		wakePending: path("wake.pending"),
		extraJson,
	});
}

describe("daemon lifecycle activity", () => {
	test("daemon.started includes pid and mode", () => {
		emitDaemonStarted(ctx(), { lifetimeMax: 14400, mode: "detach", pid: 1234 });
		const rows = activityRows();
		expect(rows).toHaveLength(1);
		expect(rows[0]).toMatchObject({
			importance: "important",
			severity: "info",
			type: "daemon.started",
		});
		expect(rows[0]?.details).toMatchObject({ lifetime_max: 14400, mode: "detach", pid: 1234 });
	});

	test("daemon.stopped severity follows reason", () => {
		expect(daemonStoppedSeverity("master-gone")).toBe("warning");
		expect(daemonStoppedSeverity("session-gone")).toBe("warning");
		expect(daemonStoppedSeverity("signal-term")).toBe("warning");
		expect(daemonStoppedSeverity("signal-int")).toBe("info");
		expect(daemonStoppedSeverity("other")).toBe("error");
		expect(daemonStoppedSeverity("crash")).toBe("error");

		for (const [idx, reason] of ["master-gone", "session-gone", "signal-term", "signal-int", "other", "crash"].entries()) {
			emitDaemonStopped(ctx(), { masterId: "%master", pid: 90 + idx, reason });
		}
		const rows = activityRows();
		expect(rows.map((row) => [row.details?.reason, row.severity])).toEqual([
			["master-gone", "warning"],
			["session-gone", "warning"],
			["signal-term", "warning"],
			["signal-int", "info"],
			["other", "error"],
			["crash", "error"],
		]);
		expect(rows[3]).toMatchObject({ pane_id: "%master", severity: "info", type: "daemon.stopped" });
		expect(rows[3]?.details).toMatchObject({ event_type: "daemon-exited", pid: 93, reason: "signal-int" });
	});
});

describe("subscriber lifecycle activity", () => {
	test("subscriber start and death emit rows", () => {
		emitSubscriberStarted(ctx(), "pi", "%42", 4242);
		emitSubscriberDead(ctx(), "pi", "%42", 4242);
		const rows = activityRows();
		expect(rows.map((row) => row.type)).toEqual(["subscriber.started", "subscriber.dead"]);
		expect(rows[0]).toMatchObject({ harness: "pi", importance: "normal", pane_id: "%42", severity: "info" });
		expect(rows[1]).toMatchObject({ harness: "pi", importance: "important", pane_id: "%42", severity: "warning" });
	});

	test("subscriber reattach emits daemon warning", () => {
		emitSubscriberReattached(ctx(), "pi", "%42", 4242);
		const rows = activityRows();
		expect(rows[0]).toMatchObject({ harness: "pi", importance: "important", pane_id: "%42", severity: "warning", type: "daemon.warning" });
		expect(rows[0]?.details).toMatchObject({ event_type: "subscriber-reattach", pid: 4242 });
	});

	test("max-lifetime handoff emits daemon warning", () => {
		emitMaxLifetimeHandoff(ctx(), 5151);
		const rows = activityRows();
		expect(rows[0]).toMatchObject({ importance: "important", severity: "warning", type: "daemon.warning" });
		expect(rows[0]?.details).toMatchObject({ event_type: "max-lifetime-handoff", successor_pid: 5151 });
	});
});

describe("subscriber wake row activity mapping", () => {
	test("successful subagent completion emits activity without wake", () => {
		emitActivityForWakeRow(ctx(), {
			classifier_tag: "pi-subagent-completion-ok",
			completion: { completions: [{ status: "completed", taskId: "task-ok" }] },
			event_type: "subagent-completion",
			harness: "pi",
			hash: "okhash",
			pane_id: "%21",
		});
		expect(wakeRows()).toHaveLength(0);
		const rows = activityRows();
		expect(rows).toHaveLength(1);
		expect(rows[0]).toMatchObject({
			importance: "normal",
			pane_id: "%21",
			severity: "success",
			type: "agent.task_completed",
		});
		expect(rows[0]?.refs).toMatchObject({ task_id: "task-ok" });
	});

	test("failed subagent completion keeps wake and emits failure activity", () => {
		expect(appendWake("pi-subagent-completion", JSON.stringify({
			completion: { completions: [{ status: "failed", taskId: "task-failed" }] },
			event_type: "subagent-completion",
			harness: "pi",
		}))).toBe(true);
		emitActivityForWakeRow(ctx(), {
			classifier_tag: "pi-subagent-completion",
			completion: { completions: [{ status: "failed", taskId: "task-failed" }] },
			event_type: "subagent-completion",
			harness: "pi",
			hash: "badhash",
			pane_id: "%22",
		});
		expect(wakeRows()).toHaveLength(1);
		const rows = activityRows();
		expect(rows[0]).toMatchObject({ importance: "important", severity: "error", type: "agent.task_failed" });
		expect(rows[0]?.refs).toMatchObject({ task_id: "task-failed" });
	});

	test.each([
		["completed", "bg-task-exit", "pi-bg-task-exit", "bg_task.completed", "success", "normal"],
		["failed", "bg-task-exit", "pi-bg-task-exit", "bg_task.failed", "error", "important"],
		["timed_out", "bg-task-exit", "pi-bg-task-exit", "bg_task.timed_out", "error", "important"],
		["stopped", "bg-task-exit", "pi-bg-task-exit", "bg_task.stopped", "warning", "important"],
		["running", "output", "pi-bg-task-activity", "bg_task.output_matched", "info", "noisy"],
	] as const)("bg-task %s/%s maps to %s", (status, eventType, tag, expectedType, expectedSeverity, expectedImportance) => {
		const task = { command: "bot-review-wait 81", exitCode: null, id: `bg-${status}`, outputBytes: 89, status };
		if (tag === "pi-bg-task-exit") {
			expect(appendWake(tag, JSON.stringify({ event_type: eventType, harness: "pi", sequence: 42, task }))).toBe(true);
		}
		emitActivityForWakeRow(ctx(), {
			activity_event_type: eventType,
			classifier_tag: tag,
			event_type: eventType,
			harness: "pi",
			hash: `hash-${status}`,
			pane_id: "%23",
			sequence: 42,
			task,
		});
		if (tag === "pi-bg-task-exit") expect(wakeRows()).toHaveLength(1);
		else expect(wakeRows()).toHaveLength(0);
		const rows = activityRows();
		expect(rows[0]).toMatchObject({ importance: expectedImportance, severity: expectedSeverity, type: expectedType });
		expect(rows[0]?.refs).toMatchObject({ bg_task_id: `bg-${status}` });
		expect(rows[0]?.details).toMatchObject({ dedup_key: `%23:${expectedType}:bg-${status}:42`, exit_code: null, output_bytes: 89, status: expectedType === "bg_task.output_matched" ? "output_matched" : status });
	});

	test("domain mismatch emits daemon.warning activity", () => {
		expect(appendWake("domain-mismatch")).toBe(true);
		emitActivityForWakeRow(ctx(), {
			classifier_tag: "domain-mismatch",
			hash: "mismatch",
			pane_id: "%24",
			ts: "2026-05-15T00:00:00Z",
		});
		const rows = activityRows();
		expect(rows[0]).toMatchObject({ importance: "important", pane_id: "%24", severity: "warning", type: "daemon.warning" });
	});

	test.each([
		["pi-rate-limit-skipped", "rate_limit_skipped", "agent.rate_limit_skipped", "debug", "noisy", "rate-limit skipped: no-stopreason"],
		["pi-rate-limit-retry", "rate_limit_retry", "agent.rate_limit_retry", "info", "important", "rate-limit retry scheduled: attempt 2"],
		["pi-rate-limit-resolved", "rate_limit_resolved", "agent.rate_limit_resolved", "success", "normal", "rate-limit resolved after attempt 2"],
		["pi-rate-limit-exhausted", "rate_limit_exhausted", "agent.rate_limit_exhausted", "error", "important", "rate-limit exhausted after attempt 2"],
	] as const)("%s maps to activity", (tag, eventType, type, severity, importance, summary) => {
		emitActivityForWakeRow(ctx(), {
			attempt: 2,
			classifier_tag: tag,
			event_type: eventType,
			harness: "pi",
			hash: `${tag}-hash`,
			next_retry_at: tag === "pi-rate-limit-retry" ? 1_700_000_000_000 : undefined,
			pane_id: "%24",
			reason: tag === "pi-rate-limit-skipped" ? "no-stopreason" : undefined,
			ts: "2026-05-15T00:00:00Z",
		});
		expect(wakeRows()).toHaveLength(0);
		const rows = activityRows();
		expect(rows[0]).toMatchObject({
			harness: "pi",
			importance,
			pane_id: "%24",
			severity,
			summary,
			type,
		});
		expect(rows[0]?.details).toMatchObject({
			event_type: eventType,
			hash: `${tag}-hash`,
		});
	});

	test("rate-limit decider error maps to daemon warning activity", () => {
		emitActivityForWakeRow(ctx(), {
			classifier_tag: "pi-rate-limit-decider-error",
			error: "boom",
			event_type: "rate_limit_decider_error",
			exit_code: 2,
			harness: "pi",
			hash: "deciderhash",
			pane_id: "%24",
			reason: "decider-exit",
		});
		const rows = activityRows();
		expect(rows[0]).toMatchObject({ importance: "important", severity: "warning", summary: "rate-limit decider error: decider-exit", type: "daemon.warning" });
		expect(rows[0]?.details).toMatchObject({ error: "boom", event_type: "rate_limit_decider_error", exit_code: 2, reason: "decider-exit" });
	});

	test("question opened maps to question.opened", () => {
		emitActivityForWakeRow(ctx(), {
			classifier_tag: "pi-question",
			event_type: "question",
			harness: "pi",
			hash: "qhash",
			pane_id: "%25",
			request_id: "que_1",
		});
		const rows = activityRows();
		expect(rows[0]).toMatchObject({ importance: "important", severity: "warning", type: "question.opened" });
		expect(rows[0]?.refs).toMatchObject({ question_id: "que_1" });
	});

	test("Pi broker activity maps directly to activity JSONL", () => {
		emitActivityForWakeRow(ctx(), {
			activity: {
				details: { sequence: 7 },
				importance: "noisy",
				refs: { bg_task_id: "bg-7" },
				severity: "info",
				source: "pi-bg-task",
				summary: "background task bg-7 matched output",
				ts: "2026-05-16T00:00:00.000Z",
				type: "bg_task.output_matched",
			},
			classifier_tag: "pi-activity-broker",
			event_type: "vstack_activity",
			harness: "pi",
			hash: "activityhash",
			pane_id: "%26",
		});
		const rows = activityRows();
		expect(rows[0]).toMatchObject({ harness: "pi", importance: "noisy", pane_id: "%26", severity: "info", source: "pi-bg-task", type: "bg_task.output_matched" });
		expect(rows[0]?.refs).toMatchObject({ bg_task_id: "bg-7" });
		expect(rows[0]?.details).toMatchObject({ broker_hash: "activityhash", dedup_key: "%26:bg_task.output_matched:bg-7:7", event_type: "vstack_activity", sequence: 7 });
	});

	test("Pi broker bg-task event dedupes against legacy custom-message activity", () => {
		const task = { command: "echo done", exitCode: 0, id: "bg-same", outputBytes: 10, status: "completed" };
		emitActivityForWakeRow(ctx(), {
			activity: {
				details: { sequence: 42, status: "completed" },
				importance: "normal",
				refs: { bg_task_id: "bg-same" },
				severity: "success",
				source: "pi-bg-task",
				summary: "background task bg-same completed",
				ts: "2026-05-16T00:00:00.000Z",
				type: "bg_task.completed",
			},
			classifier_tag: "pi-activity-broker",
			event_type: "vstack_activity",
			harness: "pi",
			hash: "broker-same",
			pane_id: "%27",
		});
		emitActivityForWakeRow(ctx(), {
			classifier_tag: "pi-bg-task-exit",
			event_type: "bg-task-exit",
			harness: "pi",
			hash: "legacy-same",
			pane_id: "%27",
			sequence: 42,
			task,
		});

		const rows = activityRows();
		expect(rows).toHaveLength(1);
		expect(rows[0]).toMatchObject({ pane_id: "%27", source: "pi-bg-task", type: "bg_task.completed" });
		expect(rows[0]?.details).toMatchObject({ dedup_key: "%27:bg_task.completed:bg-same:42" });
	});
});

describe("wake delivery failure activity", () => {
	test.each([
		["load-buffer", "tmux-load-buffer-failed"],
		["paste-buffer", "tmux-paste-buffer-failed"],
		["send-keys", "tmux-send-keys-enter-failed"],
	] as const)("tmux %s failure emits daemon.error and clears wake.pending", (failCommand, expectedReason) => {
		const logs: string[] = [];
		const ok = wakeMaster({
			activity: ctx(),
			busyFile: path("busy"),
			combined: "adapter:%101:pi-question",
			daemonPid: process.pid,
			inFlightJson: JSON.stringify([{ hash: "h1", is_bell: false, pane_id: "%101", tag: "pi-question" }]),
			isMasterBusy: () => false,
			log: (tag, msg) => logs.push(`${tag}:${msg}`),
			masterHarness: "claude",
			masterId: "%master",
			masterTurnTtl: 3600,
			paneTargetFor: () => "S:1.0",
			sessionKey: "sTest",
			sessionLock: path("lock"),
			spawnSyncOverride: (_command, args) => {
				const arg0 = args[0] ?? "";
				return { output: [], signal: null, status: arg0 === failCommand ? 1 : 0, stderr: "fail", stdout: "" };
			},
			wakePending: path("wake.pending"),
		});
		expect(ok).toBe(false);
		expect(existsSync(path("wake.pending"))).toBe(false);
		const rows = activityRows();
		expect(rows[0]).toMatchObject({ importance: "important", severity: "error", type: "daemon.error" });
		expect(rows[0]?.details).toMatchObject({ kind: "wake-delivery-failed", reason: expectedReason, target_master_pid: "%master" });
	});

	test("wake failure emits daemon.error and does not throw", () => {
		const logs: string[] = [];
		const ok = wakeMaster({
			activity: ctx(),
			busyFile: path("busy"),
			combined: "adapter:%101:pi-question",
			daemonPid: process.pid,
			inFlightJson: "[]",
			isMasterBusy: () => false,
			log: (tag, msg) => logs.push(`${tag}:${msg}`),
			masterHarness: "claude",
			masterId: "%missing",
			masterTurnTtl: 3600,
			paneTargetFor: () => "",
			sessionKey: "sTest",
			sessionLock: path("lock"),
			wakePending: path("wake.pending"),
		});
		expect(ok).toBe(false);
		expect(logs.some((line) => line.includes("master-gone"))).toBe(true);
		const rows = activityRows();
		expect(rows[0]).toMatchObject({ importance: "important", severity: "error", type: "daemon.error" });
		expect(rows[0]?.details).toMatchObject({ kind: "wake-delivery-failed", reason: "master-pane-unresolved", target_master_pid: "%missing" });
	});
});
