import { expect, test } from "bun:test";
import { DEFAULT_OUTPUT_WAKE_BUDGET_MAX_BYTES, DEFAULT_OUTPUT_WAKE_BUDGET_MAX_WAKES } from "../extensions/constants.js";
import type { ManagedTask, WakeDiagnostic } from "../extensions/types.js";
import { noteOutputWakeSent, shouldEmitOutputWake } from "../extensions/wake-events.js";
import type { OutputWakeBudgetLimits } from "../extensions/wake-events.js";
import { fakeTask } from "./fixtures/lifecycle.js";

test("output wake decision traces", () => {
	const limits = { maxWakes: DEFAULT_OUTPUT_WAKE_BUDGET_MAX_WAKES, maxBytes: DEFAULT_OUTPUT_WAKE_BUDGET_MAX_BYTES };
	const rows: Array<{ name: string; tasks: ManagedTask[]; limits?: OutputWakeBudgetLimits;
		steps: { task: number; at: number; text: string; sequence: number; key?: string; note?: boolean }[];
		expected: { allowed: boolean[]; diagnostics: { reason: string; taskId: string }[] } }> = [
		{ name: "same tail suppressed then changed tail allowed", tasks: [fakeTask({ id: "bg-7", notifyOnOutput: true, notifyMode: "transition", dedupeKey: "pane-idle" })],
			steps: [{ task: 0, at: 1_000, text: "IDLE pid=123\n", sequence: 1 }, { task: 0, at: 1_100, text: "IDLE pid=123\n", sequence: 2 }, { task: 0, at: 1_200, text: "BUSY pid=123\n", sequence: 3 }],
			expected: { allowed: [true, false, true], diagnostics: [{ reason: "output-transition-dedupe", taskId: "bg-7" }] } },
		{ name: "shared key coalesces different tasks", tasks: [fakeTask({ id: "bg-first", notifyOnOutput: true, notifyMode: "transition", dedupeKey: "shared-monitor" }), fakeTask({ id: "bg-second", notifyOnOutput: true, notifyMode: "transition", dedupeKey: "shared-monitor" })],
			steps: [{ task: 0, at: 2_000, text: "IDLE pid=777\n", sequence: 1 }, { task: 1, at: 2_100, text: "IDLE pid=777\n", sequence: 1 }],
			expected: { allowed: [true, false], diagnostics: [{ reason: "output-transition-dedupe", taskId: "bg-second" }] } },
		{ name: "different keys stay independent on one task", tasks: [fakeTask({ id: "bg-shared", notifyOnOutput: true, notifyMode: "transition", dedupeKey: "monitor-a" })],
			steps: [{ task: 0, at: 2_200, text: "IDLE pid=777\n", sequence: 1 }, { task: 0, at: 2_300, text: "IDLE pid=777\n", sequence: 2, key: "monitor-b" }],
			expected: { allowed: [true, true], diagnostics: [] } },
		{ name: "first match suppresses output only after delivery", tasks: [fakeTask({ id: "bg-7", notifyOnOutput: true, notifyMode: "first-match-only", notifyPattern: "READY" })],
			steps: [{ task: 0, at: 1_000, text: "READY\n", sequence: 1, note: true }, { task: 0, at: 1_100, text: "READY again\n", sequence: 2 }],
			expected: { allowed: [true, false], diagnostics: [{ reason: "first-match-only-suppressed", taskId: "bg-7" }] } },
		{ name: "configured budget suppresses output at the cap", tasks: [fakeTask({ id: "bg-budget", notifyOnOutput: true, notifyMode: "always", outputWakeBudget: { wakes: limits.maxWakes, bytes: 0, exhausted: false, announcedAt: null } })], limits,
			steps: [{ task: 0, at: 3_000, text: "more output\n", sequence: 9 }], expected: { allowed: [false], diagnostics: [{ reason: "wake-budget-exhausted", taskId: "bg-budget" }] } },
		{ name: "omitted limits leave the budget guard disabled", tasks: [fakeTask({ id: "bg-budget", notifyOnOutput: true, notifyMode: "always", outputWakeBudget: { wakes: limits.maxWakes * 10, bytes: limits.maxBytes * 10, exhausted: false, announcedAt: null } })],
			steps: [{ task: 0, at: 4_000, text: "still going\n", sequence: 10 }], expected: { allowed: [true], diagnostics: [] } },
	];
	expect.assertions(rows.length + 1);
	expect(rows.length).toBeGreaterThan(0);
	for (const row of rows) {
		const diagnostics: WakeDiagnostic[] = [];
		const dedupeHashes = new Map<string, string>();
		const allowed = row.steps.map((step) => {
			const task = row.tasks[step.task]!;
			if (step.key !== undefined) task.dedupeKey = step.key;
			const result = shouldEmitOutputWake(task, { dedupeHashes, eventAt: step.at, now: () => 8_000,
				newOutput: step.text, newOutputTail: step.text, patternMatched: true, sequence: step.sequence,
				wakeBudgetLimits: row.limits, logDiagnostic: (diagnostic) => diagnostics.push(diagnostic) });
			if (step.note) noteOutputWakeSent(task);
			return result;
		});
		expect({ allowed, diagnostics: diagnostics.map(({ reason, taskId }) => ({ reason, taskId })) }, row.name).toStrictEqual(row.expected);
	}
});
