// Tests for vstack#210: bounded inline wake payloads, default notifyMode
// resolution, and the per-task output-wake budget guard.

import { describe, expect, test } from "bun:test";

import {
	DEFAULT_OUTPUT_ALERT_MAX_CHARS,
	DEFAULT_OUTPUT_WAKE_BUDGET_MAX_BYTES,
	DEFAULT_OUTPUT_WAKE_BUDGET_MAX_WAKES,
} from "../extensions/constants.js";
import { tailText } from "../extensions/format.js";
import { taskSnapshot } from "../extensions/snapshot.js";
import type { BackgroundTaskSnapshot, ManagedTask, WakeDiagnostic } from "../extensions/types.js";
import {
	WAKE_CONTENT_COMMAND_MAX_CHARS,
	WAKE_MANIFEST_FIELD_MAX_CHARS,
	compactBackgroundTaskSnapshot,
	defaultNotifyMode,
	emptyOutputWakeBudget,
	normalizeOutputWakeBudget,
	resolveNotifyMode,
	scheduleTaskWake,
	sendOutputWakeBudgetExhaustedNotice,
	sendTaskWake,
	shouldEmitOutputWake,
	wouldExhaustOutputWakeBudget,
} from "../extensions/wake-events.js";

function fakeSnapshot(overrides: Partial<BackgroundTaskSnapshot> = {}): BackgroundTaskSnapshot {
	return {
		command: "printf ready",
		cwd: "/tmp/worktree",
		dedupeKey: undefined,
		exitCode: null,
		exitNotified: false,
		expiresAt: null,
		id: "bg-budget",
		lastOutputAt: 1_700_000_000_050,
		logFile: "/tmp/bg-budget.log",
		notifyMode: "always",
		notifyOnExit: true,
		notifyOnOutput: true,
		notifyPattern: undefined,
		outputBytes: 12,
		pid: 4243,
		startedAt: 1_700_000_000_000,
		status: "running",
		title: "fake budget task",
		updatedAt: 1_700_000_000_050,
		voidedWakeSequences: [],
		wakeEvents: [],
		wakeSequence: 0,
		outputWakeBudget: emptyOutputWakeBudget(),
		...overrides,
	};
}

function fakeTask(overrides: Partial<ManagedTask> = {}): ManagedTask {
	const snapshot = fakeSnapshot(overrides);
	return {
		...snapshot,
		child: null,
		closed: false,
		forceKillTimer: null,
		lastAnnouncedLength: 0,
		matcher: null,
		output: "ready\n",
		outputPatternMatched: false,
		outputTimer: null,
		pendingWakes: [],
		stopReason: null,
		timeoutTimer: null,
		voidedWakes: new Set(snapshot.voidedWakeSequences ?? []),
		outputWakeBudget: snapshot.outputWakeBudget,
		...overrides,
	};
}

interface SendRecord {
	message: Record<string, unknown>;
	options: Record<string, unknown>;
}

function sendDeps(taskOutput: string, diagnostics: WakeDiagnostic[] = []) {
	const messages: SendRecord[] = [];
	let now = 2_000;
	return {
		deps: {
			isShuttingDown: () => false,
			logDiagnostic: (diagnostic: WakeDiagnostic) => diagnostics.push(diagnostic),
			messageType: "pi-bg-task",
			now: () => now++,
			outputTail: () => tailText(taskOutput, DEFAULT_OUTPUT_ALERT_MAX_CHARS),
			rememberSnapshot: (task: ManagedTask) => taskSnapshot(task),
			sendMessage: (message: Record<string, unknown>, options: Record<string, unknown>) => {
				messages.push({ message, options });
			},
		},
		messages,
	};
}

function detailsBytes(message: Record<string, unknown>): number {
	return Buffer.byteLength(JSON.stringify(message.details), "utf8");
}

function messageBytes(record: SendRecord): number {
	return Buffer.byteLength(JSON.stringify({ content: record.message.content, details: record.message.details }), "utf8");
}

describe("wake payload byte budget (vstack#210)", () => {
	test("output wake outputTail is bounded by outputAlertMaxChars default and no newOutputTail field is emitted", () => {
		const huge = "x".repeat(1_000_000);
		const task = fakeTask({ status: "running", lastOutputAt: 1_111 });
		const { deps, messages } = sendDeps(huge);
		const pending = scheduleTaskWake(task, "output", 1_111);
		const newOutputTail = tailText(huge, DEFAULT_OUTPUT_ALERT_MAX_CHARS);

		expect(sendTaskWake(deps, "output", task, {
			eventAt: pending.eventAt,
			newOutputTail,
			sequence: pending.sequence,
		})).toBe(true);

		const details = messages[0]?.message.details as Record<string, unknown>;
		expect(typeof details.outputTail).toBe("string");
		expect("newOutputTail" in details).toBe(false);
		expect((details.outputTail as string).length).toBeLessThanOrEqual(DEFAULT_OUTPUT_ALERT_MAX_CHARS + 32);
		expect(details.outputTailTruncated).toBe(true);
	});

	test("output wake details stay under 4 KB even with the maximum inline tail", () => {
		const huge = "y".repeat(1_000_000);
		const task = fakeTask({ status: "running", lastOutputAt: 1_111 });
		const { deps, messages } = sendDeps(huge);
		const pending = scheduleTaskWake(task, "output", 1_111);
		const newOutputTail = tailText(huge, DEFAULT_OUTPUT_ALERT_MAX_CHARS);

		expect(sendTaskWake(deps, "output", task, {
			eventAt: pending.eventAt,
			newOutputTail,
			sequence: pending.sequence,
		})).toBe(true);

		expect(messages).toHaveLength(1);
		// Inline tail is capped at ~2KB, the rest of details is metadata. The
		// whole payload (content + details) targets <4 KB.
		expect(messageBytes(messages[0]!)).toBeLessThan(4_096);
		expect(detailsBytes(messages[0]!.message)).toBeLessThan(4_096);
	});

	test("exit wake outputTail uses the full-output tail when no newOutputTail is supplied", () => {
		const output = "line-a\nline-b\nline-c\n";
		const task = fakeTask({ id: "bg-exit", status: "completed", notifyOnOutput: false, updatedAt: 1_222 });
		const { deps, messages } = sendDeps(output);

		expect(sendTaskWake(deps, "exit", task, { eventAt: 1_222 })).toBe(true);
		const details = messages[0]?.message.details as Record<string, unknown>;
		expect(details.outputTail).toBe(output);
		expect(details.outputTailTruncated).toBe(false);
	});

	test("oversized command/title/cwd/notifyPattern/dedupeKey are bounded in wake details and content", () => {
		const heredoc = "Z".repeat(100_000);
		const title = "T".repeat(2_000);
		const cwd = "/path/" + "C".repeat(2_000);
		const notifyPattern = "P".repeat(2_000);
		const dedupeKey = "D".repeat(2_000);
		const logFile = "/tmp/" + "L".repeat(2_000);
		const task = fakeTask({
			command: heredoc,
			cwd,
			dedupeKey,
			lastOutputAt: 1_111,
			logFile,
			notifyPattern,
			status: "running",
			title,
		});
		const newOutputTail = tailText("y".repeat(1_000_000), DEFAULT_OUTPUT_ALERT_MAX_CHARS);
		const { deps, messages } = sendDeps("y".repeat(1_000_000));
		const pending = scheduleTaskWake(task, "output", 1_111);

		expect(sendTaskWake(deps, "output", task, {
			eventAt: pending.eventAt,
			newOutputTail,
			sequence: pending.sequence,
		})).toBe(true);

		const record = messages[0]!;
		expect(messageBytes(record)).toBeLessThan(4_096);
		const content = String(record.message.content);
		// Content carries a bounded command preview only.
		expect(content.length).toBeLessThan(WAKE_CONTENT_COMMAND_MAX_CHARS + 128);
		expect(content).not.toContain("Z".repeat(WAKE_CONTENT_COMMAND_MAX_CHARS + 1));

		const detailsTask = (record.message.details as Record<string, unknown>).task as Record<string, unknown>;
		// Long text fields clipped to the manifest cap.
		expect((detailsTask.command as string).length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		expect((detailsTask.title as string).length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		expect((detailsTask.cwd as string).length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		expect((detailsTask.notifyPattern as string).length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		expect((detailsTask.dedupeKey as string).length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		expect((detailsTask.logFile as string).length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		// Internal arrays / sensitive state are dropped from the wake manifest.
		expect("wakeEvents" in detailsTask).toBe(false);
		expect("pendingWakes" in detailsTask).toBe(false);
		expect("voidedWakeSequences" in detailsTask).toBe(false);
		expect("lastOutputDedupeByKey" in detailsTask).toBe(false);
		expect("procIdent" in detailsTask).toBe(false);
	});

	test("details.matchedPattern is bounded by the manifest cap (vstack#210 round 2)", () => {
		const hugePattern = "P".repeat(100_000);
		const task = fakeTask({ status: "running", lastOutputAt: 1_111, notifyPattern: hugePattern });
		const newOutputTail = tailText("y".repeat(1_000), DEFAULT_OUTPUT_ALERT_MAX_CHARS);
		const { deps, messages } = sendDeps("y".repeat(1_000));
		const pending = scheduleTaskWake(task, "output", 1_111);

		expect(sendTaskWake(deps, "output", task, {
			eventAt: pending.eventAt,
			matchedPattern: hugePattern,
			newOutputTail,
			sequence: pending.sequence,
		})).toBe(true);

		const record = messages[0]!;
		const details = record.message.details as Record<string, unknown>;
		expect((details.matchedPattern as string).length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		expect(messageBytes(record)).toBeLessThan(4_096);
	});

	test("budget-exhausted notice stays under 4 KB and uses bounded log path", () => {
		const longLogFile = "/tmp/" + "B".repeat(5_000);
		const task = fakeTask({ command: "Q".repeat(200_000), logFile: longLogFile, title: "T".repeat(5_000) });
		task.outputWakeBudget = emptyOutputWakeBudget();
		task.outputWakeBudget.wakes = 20;
		const { deps, messages } = sendDeps("ready\n");

		expect(sendOutputWakeBudgetExhaustedNotice(deps, task, { maxWakes: 20, maxBytes: 20_000 })).toBe(true);
		const record = messages[0]!;
		expect(messageBytes(record)).toBeLessThan(4_096);
		const details = record.message.details as Record<string, unknown>;
		expect((details.logFile as string).length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		const detailsTask = details.task as Record<string, unknown>;
		expect((detailsTask.command as string).length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		expect((detailsTask.title as string).length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
	});
});

describe("compactBackgroundTaskSnapshot", () => {
	test("truncates text fields and drops internal arrays", () => {
		const full = taskSnapshot(fakeTask({
			command: "X".repeat(5_000),
			title: "Y".repeat(5_000),
			cwd: "Z".repeat(5_000),
			notifyPattern: "P".repeat(5_000),
			dedupeKey: "D".repeat(5_000),
			logFile: "L".repeat(5_000),
		}));
		full.wakeEvents = [{ deliveredAt: 1, eventAt: 1, eventType: "output", sequence: 1, taskStatusAtEmit: "running" }];
		full.voidedWakeSequences = [1, 2, 3];
		full.pendingWakes = [{ eventAt: 1, eventType: "output", sequence: 9 }];
		full.lastOutputDedupeByKey = { key: "hash" };

		const compact = compactBackgroundTaskSnapshot(full);
		expect(compact.command.length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		expect(compact.title.length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		expect(compact.cwd.length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		expect(compact.notifyPattern?.length ?? 0).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		expect(compact.dedupeKey?.length ?? 0).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		expect(compact.logFile.length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		expect("wakeEvents" in compact).toBe(false);
		expect("pendingWakes" in compact).toBe(false);
		expect("voidedWakeSequences" in compact).toBe(false);
		expect("lastOutputDedupeByKey" in compact).toBe(false);
	});

	test("preserves short text and lifecycle fields verbatim", () => {
		const full = taskSnapshot(fakeTask({ command: "echo ok", title: "Hi", cwd: "/repo", notifyPattern: "READY" }));
		const compact = compactBackgroundTaskSnapshot(full);
		expect(compact.command).toBe("echo ok");
		expect(compact.title).toBe("Hi");
		expect(compact.cwd).toBe("/repo");
		expect(compact.notifyPattern).toBe("READY");
		expect(compact.id).toBe(full.id);
		expect(compact.pid).toBe(full.pid);
		expect(compact.status).toBe(full.status);
		expect(compact.exitCode).toBe(full.exitCode);
		expect(compact.outputBytes).toBe(full.outputBytes);
		expect(compact.logFile).toBe(full.logFile);
		expect(compact.startedAt).toBe(full.startedAt);
		expect(compact.updatedAt).toBe(full.updatedAt);
	});
});

describe("normalizeOutputWakeBudget", () => {
	test("coerces missing / invalid values to a fresh budget", () => {
		expect(normalizeOutputWakeBudget(undefined)).toEqual({ wakes: 0, bytes: 0, exhausted: false, announcedAt: null });
		expect(normalizeOutputWakeBudget(null)).toEqual({ wakes: 0, bytes: 0, exhausted: false, announcedAt: null });
		expect(normalizeOutputWakeBudget({ wakes: "garbage", bytes: -5, exhausted: "yes", announcedAt: "later" })).toEqual({
			wakes: 0,
			bytes: 0,
			exhausted: false,
			announcedAt: null,
		});
	});

	test("returns an independent object so callers cannot accidentally share state", () => {
		const source = { wakes: 3, bytes: 100, exhausted: true, announcedAt: 999 };
		const normalized = normalizeOutputWakeBudget(source);
		normalized.wakes = 7;
		expect(source.wakes).toBe(3);
	});
});

describe("default notifyMode resolution (vstack#210)", () => {
	test("defaultNotifyMode picks first-match-only with a pattern, transition without", () => {
		expect(defaultNotifyMode("READY")).toBe("first-match-only");
		expect(defaultNotifyMode(undefined)).toBe("transition");
		expect(defaultNotifyMode("   ")).toBe("transition");
	});

	test("resolveNotifyMode preserves explicit choices and falls back to default", () => {
		expect(resolveNotifyMode("always", undefined)).toBe("always");
		expect(resolveNotifyMode("transition", "READY")).toBe("transition");
		expect(resolveNotifyMode("first-match-only", undefined)).toBe("first-match-only");
		expect(resolveNotifyMode(undefined, "READY")).toBe("first-match-only");
		expect(resolveNotifyMode(undefined, undefined)).toBe("transition");
		expect(resolveNotifyMode("garbage" as unknown, "READY")).toBe("first-match-only");
	});
});

describe("output wake budget guard (vstack#210)", () => {
	const limits = {
		maxWakes: DEFAULT_OUTPUT_WAKE_BUDGET_MAX_WAKES,
		maxBytes: DEFAULT_OUTPUT_WAKE_BUDGET_MAX_BYTES,
	};

	test("wouldExhaustOutputWakeBudget trips on wake count cap", () => {
		const budget = emptyOutputWakeBudget();
		budget.wakes = limits.maxWakes;
		expect(wouldExhaustOutputWakeBudget(budget, limits, 0)).toBe(true);
	});

	test("wouldExhaustOutputWakeBudget trips on byte cap", () => {
		const budget = emptyOutputWakeBudget();
		budget.bytes = limits.maxBytes;
		expect(wouldExhaustOutputWakeBudget(budget, limits, 1)).toBe(true);
	});

	test("wouldExhaustOutputWakeBudget honors zero (disabled) caps", () => {
		const budget = emptyOutputWakeBudget();
		budget.wakes = 100;
		budget.bytes = 1_000_000;
		expect(wouldExhaustOutputWakeBudget(budget, { maxWakes: 0, maxBytes: 0 }, 1_000)).toBe(false);
	});

	test("shouldEmitOutputWake suppresses wakes once the budget is exhausted", () => {
		const diagnostics: WakeDiagnostic[] = [];
		const task = fakeTask({ notifyMode: "always" });
		task.outputWakeBudget = emptyOutputWakeBudget();
		task.outputWakeBudget.wakes = limits.maxWakes;

		expect(shouldEmitOutputWake(task, {
			eventAt: 3_000,
			logDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
			newOutput: "more output\n",
			newOutputTail: "more output\n",
			patternMatched: true,
			sequence: 9,
			wakeBudgetLimits: limits,
		})).toBe(false);
		expect(diagnostics.at(-1)?.reason).toBe("wake-budget-exhausted");
	});

	test("budget guard does not engage without wakeBudgetLimits", () => {
		const diagnostics: WakeDiagnostic[] = [];
		const task = fakeTask({ notifyMode: "always" });
		task.outputWakeBudget = emptyOutputWakeBudget();
		task.outputWakeBudget.wakes = limits.maxWakes * 10;
		task.outputWakeBudget.bytes = limits.maxBytes * 10;

		// Note: when wakeBudgetLimits is omitted, the older test surface ignores
		// the budget entirely so legacy callers keep their behavior.
		expect(shouldEmitOutputWake(task, {
			eventAt: 4_000,
			logDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
			newOutput: "still going\n",
			newOutputTail: "still going\n",
			patternMatched: true,
			sequence: 10,
		})).toBe(true);
		expect(diagnostics.some((diagnostic) => diagnostic.reason === "wake-budget-exhausted")).toBe(false);
	});

	test("sendTaskWake updates budget counters for output wakes only", () => {
		const tail = "y".repeat(64);
		const task = fakeTask({ notifyMode: "always", status: "running" });
		const { deps } = sendDeps(tail);

		const outputPending = scheduleTaskWake(task, "output", 5_000);
		expect(sendTaskWake(deps, "output", task, { eventAt: outputPending.eventAt, newOutputTail: tail, sequence: outputPending.sequence })).toBe(true);
		expect(task.outputWakeBudget?.wakes).toBe(1);
		expect(task.outputWakeBudget?.bytes).toBe(Buffer.byteLength(tail, "utf8"));

		const exitTask = fakeTask({ id: "bg-exit", status: "completed", notifyOnOutput: false, updatedAt: 6_000 });
		expect(sendTaskWake(deps, "exit", exitTask, { eventAt: 6_000 })).toBe(true);
		expect(exitTask.outputWakeBudget?.wakes ?? 0).toBe(0);
		expect(exitTask.outputWakeBudget?.bytes ?? 0).toBe(0);
	});

	test("sendOutputWakeBudgetExhaustedNotice emits exactly one notice with the log file path", () => {
		const diagnostics: WakeDiagnostic[] = [];
		const task = fakeTask();
		task.outputWakeBudget = emptyOutputWakeBudget();
		task.outputWakeBudget.wakes = limits.maxWakes;
		const { deps, messages } = sendDeps("ready\n", diagnostics);

		expect(sendOutputWakeBudgetExhaustedNotice(deps, task, limits)).toBe(true);
		expect(sendOutputWakeBudgetExhaustedNotice(deps, task, limits)).toBe(false);

		expect(messages).toHaveLength(1);
		const message = messages[0]!.message;
		expect(String(message.content)).toContain(task.logFile);
		expect(String(message.content)).toContain("budget exhausted");
		const details = message.details as Record<string, unknown>;
		expect(details.eventType).toBe("output-budget-exhausted");
		expect(details.logFile).toBe(task.logFile);
		expect(messageBytes(messages[0]!)).toBeLessThan(4_096);
		expect(task.outputWakeBudget?.announcedAt).not.toBeNull();
		expect(task.outputWakeBudget?.exhausted).toBe(true);
		expect(diagnostics.some((d) => d.reason === "wake-budget-exhausted")).toBe(true);
	});

	test("budget exhaustion does not suppress exit wakes", () => {
		const task = fakeTask({ id: "bg-budget-exit", status: "completed", notifyOnOutput: true, updatedAt: 7_000 });
		task.outputWakeBudget = emptyOutputWakeBudget();
		task.outputWakeBudget.exhausted = true;
		task.outputWakeBudget.wakes = limits.maxWakes;
		const { deps, messages } = sendDeps("ready\n");

		expect(sendTaskWake(deps, "exit", task, { eventAt: 7_000 })).toBe(true);
		expect(messages).toHaveLength(1);
		expect((messages[0]!.message.details as Record<string, unknown>).eventType).toBe("exit");
	});
});
