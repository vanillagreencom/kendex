import { expect, test } from "bun:test";
import { recordScheduledOutputDrop, scheduleTaskWake } from "../extensions/wake-events.js";
import type { WakeDiagnostic } from "../extensions/types.js";
import { fakeTask } from "./fixtures/lifecycle.js";

test("scheduled output drop records task-exit cleanup", () => {
	const task = fakeTask({ id: "bg-7", status: "completed" });
	const diagnostics: WakeDiagnostic[] = [];
	const pending = scheduleTaskWake(task, "output", 1_666);
	recordScheduledOutputDrop({ task, pending, reason: "cleared-on-task-exit", now: () => 1_777,
		logDiagnostic: (diagnostic) => diagnostics.push(diagnostic) });
	expect({ pending: task.pendingWakes, events: task.wakeEvents,
		diagnostics: diagnostics.map(({ reason, timestamp, sequence }) => ({ reason, timestamp, sequence })) }).toStrictEqual({
		pending: [], events: [{ deliveredAt: null, droppedReason: "cleared-on-task-exit", eventAt: 1_666,
			eventType: "output", sequence: 1, taskStatusAtEmit: "completed" }],
		diagnostics: [{ reason: "cleared-on-task-exit", timestamp: 1_777, sequence: 1 }],
	});
});
