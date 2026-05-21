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
	defaultNotifyMode,
	emptyOutputWakeBudget,
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
