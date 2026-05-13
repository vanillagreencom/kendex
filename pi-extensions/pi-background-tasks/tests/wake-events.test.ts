import { describe, expect, test } from "bun:test";

import { createPersistence } from "../extensions/persistence.js";
import { taskSnapshot } from "../extensions/snapshot.js";
import type { BackgroundTaskSnapshot, ManagedTask, WakeDiagnostic } from "../extensions/types.js";
import {
	noteOutputWakeSent,
	recordScheduledOutputDrop,
	scheduleTaskWake,
	sendTaskWake,
	shouldEmitOutputWake,
	voidPendingTaskWakes,
} from "../extensions/wake-events.js";

function fakeSnapshot(overrides: Partial<BackgroundTaskSnapshot> = {}): BackgroundTaskSnapshot {
	return {
		command: "printf ready",
		cwd: "/tmp/worktree",
		dedupeKey: undefined,
		exitCode: null,
		exitNotified: false,
		expiresAt: null,
		id: "bg-7",
		lastOutputAt: 1_700_000_000_050,
		logFile: "/tmp/bg-7.log",
		notifyMode: "always",
		notifyOnExit: true,
		notifyOnOutput: true,
		notifyPattern: undefined,
		outputBytes: 12,
		pid: 4242,
		startedAt: 1_700_000_000_000,
		status: "running",
		title: "fake task",
		updatedAt: 1_700_000_000_050,
		voidedWakeSequences: [],
		wakeEvents: [],
		wakeSequence: 0,
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
		...overrides,
	};
}

function sendDeps(taskOutput = "ready\n", diagnostics: WakeDiagnostic[] = []) {
	const messages: { message: Record<string, unknown>; options: Record<string, unknown> }[] = [];
	let now = 2_000;
	return {
		deps: {
			isShuttingDown: () => false,
			logDiagnostic: (diagnostic: WakeDiagnostic) => diagnostics.push(diagnostic),
			messageType: "pi-bg-task",
			now: () => now++,
			outputTail: () => taskOutput,
			rememberSnapshot: (task: ManagedTask) => taskSnapshot(task),
			sendMessage: (message: Record<string, unknown>, options: Record<string, unknown>) => {
				messages.push({ message, options });
			},
		},
		messages,
	};
}

describe("sendTaskWake", () => {
	test("suppresses output wake after stop/status transition", () => {
		const diagnostics: WakeDiagnostic[] = [];
		const task = fakeTask({ status: "stopped", stopReason: "user" });
		const pending = scheduleTaskWake(task, "output", 1_001);
		const { deps, messages } = sendDeps("late output\n", diagnostics);

		const sent = sendTaskWake(deps, "output", task, { eventAt: pending.eventAt, sequence: pending.sequence });

		expect(sent).toBe(false);
		expect(messages).toHaveLength(0);
		expect(diagnostics.at(-1)?.reason).toBe("output-after-stop-suppressed");
		expect(task.wakeEvents?.at(-1)?.droppedReason).toBe("output-after-stop-suppressed");
	});

	test("adds wake metadata to output and exit events and snapshots", () => {
		const diagnostics: WakeDiagnostic[] = [];
		const { deps, messages } = sendDeps("ready\n", diagnostics);
		const outputTask = fakeTask({ status: "running", lastOutputAt: 1_111 });
		const pending = scheduleTaskWake(outputTask, "output", 1_111);

		expect(sendTaskWake(deps, "output", outputTask, {
			eventAt: pending.eventAt,
			newOutputTail: "ready\n",
			sequence: pending.sequence,
		})).toBe(true);

		const exitTask = fakeTask({ id: "bg-exit", status: "completed", updatedAt: 1_222, notifyOnOutput: false });
		expect(sendTaskWake(deps, "exit", exitTask, { eventAt: 1_222 })).toBe(true);

		expect(messages).toHaveLength(2);
		const outputDetails = messages[0]?.message.details as Record<string, unknown>;
		const exitDetails = messages[1]?.message.details as Record<string, unknown>;
		for (const details of [outputDetails, exitDetails]) {
			expect(typeof details.eventAt).toBe("number");
			expect(typeof details.deliveredAt).toBe("number");
			expect(typeof details.taskStatusAtEmit).toBe("string");
			expect(typeof details.sequence).toBe("number");
		}
		expect(outputDetails.eventAt).toBe(1_111);
		expect(outputDetails.taskStatusAtEmit).toBe("running");
		expect(exitDetails.eventAt).toBe(1_222);
		expect(exitDetails.taskStatusAtEmit).toBe("completed");
		expect((taskSnapshot(outputTask).wakeEvents ?? [])).toHaveLength(1);
		expect(taskSnapshot(outputTask).wakeEvents?.[0]?.deliveredAt).toBe(outputDetails.deliveredAt);
	});

	test("persisted snapshot payload carries wake metadata through appendEntry", () => {
		const task = fakeTask({ status: "running", lastOutputAt: 1_555 });
		const pending = scheduleTaskWake(task, "output", 1_555);
		const { deps } = sendDeps("ready\n");
		expect(sendTaskWake(deps, "output", task, {
			eventAt: pending.eventAt,
			newOutputTail: "ready\n",
			sequence: pending.sequence,
		})).toBe(true);

		const appended: { customType: string; payload: any }[] = [];
		const persistence = createPersistence({
			customType: "pi-bg-state",
			getActiveCtx: () => null,
			listSnapshots: () => [taskSnapshot(task)],
			pi: {
				appendEntry: (customType: string, payload: any) => appended.push({ customType, payload }),
			} as any,
		});
		const result = persistence.persistSnapshots();

		expect(result.appendEntry).toBe(true);
		expect(appended).toHaveLength(1);
		expect(appended[0]?.payload.tasks[0].wakeEvents[0].sequence).toBe(pending.sequence);
		expect(typeof appended[0]?.payload.tasks[0].wakeEvents[0].deliveredAt).toBe("number");
	});

	test("voided wake firing after stop logs diagnostic without sendMessage", () => {
		const diagnostics: WakeDiagnostic[] = [];
		const task = fakeTask({ status: "running" });
		const pending = scheduleTaskWake(task, "output", 1_333);
		const voided = voidPendingTaskWakes(task, "stop", (diagnostic) => diagnostics.push(diagnostic), () => 1_400);
		const { deps, messages } = sendDeps("late output\n", diagnostics);

		expect(voided).toBe(1);
		expect(sendTaskWake(deps, "output", task, { eventAt: pending.eventAt, sequence: pending.sequence })).toBe(false);

		expect(messages).toHaveLength(0);
		expect(task.voidedWakes.has(pending.sequence)).toBe(true);
		expect(diagnostics.some((diagnostic) => diagnostic.reason === "voided-wake-fired" && diagnostic.sequence === pending.sequence)).toBe(true);
		expect(task.wakeEvents?.at(-1)?.droppedReason).toBe("voided");
	});

	test("scheduled output drop helper records task-exit timer cleanup", () => {
		const diagnostics: WakeDiagnostic[] = [];
		const task = fakeTask({ status: "completed" });
		const pending = scheduleTaskWake(task, "output", 1_666);

		recordScheduledOutputDrop({
			logDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
			now: () => 1_777,
			pending,
			reason: "cleared-on-task-exit",
			task,
		});

		expect(task.pendingWakes).toHaveLength(0);
		expect(task.wakeEvents?.at(-1)?.droppedReason).toBe("cleared-on-task-exit");
		expect(diagnostics.at(-1)?.reason).toBe("cleared-on-task-exit");
		expect(diagnostics.at(-1)?.timestamp).toBe(1_777);
	});
});

describe("output notify modes", () => {
	test("notifyMode=transition deduplicates identical consecutive output tails", () => {
		const diagnostics: WakeDiagnostic[] = [];
		const task = fakeTask({ notifyMode: "transition", dedupeKey: "pane-idle" });
		const dedupeHashes = new Map<string, string>();

		expect(shouldEmitOutputWake(task, {
			dedupeHashes,
			eventAt: 1_000,
			logDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
			newOutput: "IDLE pid=123\n",
			newOutputTail: "IDLE pid=123\n",
			patternMatched: true,
			sequence: 1,
		})).toBe(true);
		expect(shouldEmitOutputWake(task, {
			dedupeHashes,
			eventAt: 1_100,
			logDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
			newOutput: "IDLE pid=123\n",
			newOutputTail: "IDLE pid=123\n",
			patternMatched: true,
			sequence: 2,
		})).toBe(false);
		expect(shouldEmitOutputWake(task, {
			dedupeHashes,
			eventAt: 1_200,
			logDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
			newOutput: "BUSY pid=123\n",
			newOutputTail: "BUSY pid=123\n",
			patternMatched: true,
			sequence: 3,
		})).toBe(true);
		expect(diagnostics.at(-1)?.reason).toBe("output-transition-dedupe");
	});

	test("notifyMode=transition coalesces different tasks sharing one dedupeKey", () => {
		const diagnostics: WakeDiagnostic[] = [];
		const dedupeHashes = new Map<string, string>();
		const first = fakeTask({ id: "bg-first", notifyMode: "transition", dedupeKey: "shared-monitor" });
		const second = fakeTask({ id: "bg-second", notifyMode: "transition", dedupeKey: "shared-monitor" });

		expect(shouldEmitOutputWake(first, {
			dedupeHashes,
			eventAt: 2_000,
			logDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
			newOutput: "IDLE pid=777\n",
			newOutputTail: "IDLE pid=777\n",
			patternMatched: true,
			sequence: 1,
		})).toBe(true);
		expect(shouldEmitOutputWake(second, {
			dedupeHashes,
			eventAt: 2_100,
			logDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
			newOutput: "IDLE pid=777\n",
			newOutputTail: "IDLE pid=777\n",
			patternMatched: true,
			sequence: 1,
		})).toBe(false);
		expect(diagnostics.at(-1)?.reason).toBe("output-transition-dedupe");
		expect(diagnostics.at(-1)?.taskId).toBe("bg-second");
	});

	test("notifyMode=transition keeps different dedupeKeys independent on same task", () => {
		const diagnostics: WakeDiagnostic[] = [];
		const dedupeHashes = new Map<string, string>();
		const task = fakeTask({ id: "bg-shared", notifyMode: "transition", dedupeKey: "monitor-a" });

		expect(shouldEmitOutputWake(task, {
			dedupeHashes,
			eventAt: 2_200,
			logDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
			newOutput: "IDLE pid=777\n",
			newOutputTail: "IDLE pid=777\n",
			patternMatched: true,
			sequence: 1,
		})).toBe(true);
		task.dedupeKey = "monitor-b";
		expect(shouldEmitOutputWake(task, {
			dedupeHashes,
			eventAt: 2_300,
			logDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
			newOutput: "IDLE pid=777\n",
			newOutputTail: "IDLE pid=777\n",
			patternMatched: true,
			sequence: 2,
		})).toBe(true);
		expect(diagnostics.some((diagnostic) => diagnostic.reason === "output-transition-dedupe")).toBe(false);
	});

	test("notifyMode=first-match-only fires once for notifyPattern", () => {
		const diagnostics: WakeDiagnostic[] = [];
		const task = fakeTask({ notifyMode: "first-match-only", notifyPattern: "READY" });

		expect(shouldEmitOutputWake(task, {
			eventAt: 1_000,
			logDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
			newOutput: "READY\n",
			newOutputTail: "READY\n",
			patternMatched: true,
			sequence: 1,
		})).toBe(true);
		noteOutputWakeSent(task);
		expect(shouldEmitOutputWake(task, {
			eventAt: 1_100,
			logDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
			newOutput: "READY again\n",
			newOutputTail: "READY again\n",
			patternMatched: true,
			sequence: 2,
		})).toBe(false);
		expect(diagnostics.at(-1)?.reason).toBe("first-match-only-suppressed");
	});
});
