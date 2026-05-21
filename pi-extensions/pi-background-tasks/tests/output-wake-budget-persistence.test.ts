// Round-trip persistence of outputWakeBudget across snapshot + restore.
// The budget must survive a session restart so a chatty task cannot get a
// fresh budget by reloading Pi (vstack#210).

import { describe, expect, test } from "bun:test";

import {
	DEFAULT_OUTPUT_WAKE_BUDGET_MAX_BYTES,
	DEFAULT_OUTPUT_WAKE_BUDGET_MAX_WAKES,
} from "../extensions/constants.js";
import { restoredTaskFromSnapshot, taskSnapshot } from "../extensions/snapshot.js";
import type { ManagedTask, BackgroundTaskSnapshot, WakeDiagnostic } from "../extensions/types.js";
import {
	emptyOutputWakeBudget,
	normalizeOutputWakeBudget,
	shouldEmitOutputWake,
} from "../extensions/wake-events.js";

function baseTask(overrides: Partial<ManagedTask> = {}): ManagedTask {
	const base: ManagedTask = {
		child: null,
		closed: false,
		command: "printf running",
		cwd: "/tmp",
		exitCode: null,
		exitNotified: false,
		expiresAt: null,
		forceKillTimer: null,
		id: "bg-budget-roundtrip",
		lastAnnouncedLength: 0,
		lastOutputAt: 1_700_000_000_000,
		logFile: "/tmp/bg-budget-roundtrip.log",
		matcher: null,
		notifyMode: "always",
		notifyOnExit: true,
		notifyOnOutput: true,
		output: "",
		outputBytes: 12,
		outputPatternMatched: false,
		outputTimer: null,
		outputWakeBudget: emptyOutputWakeBudget(),
		pendingWakes: [],
		pid: 4242,
		startedAt: 1_700_000_000_000,
		status: "running",
		stopReason: null,
		timeoutTimer: null,
		title: "round-trip task",
		updatedAt: 1_700_000_000_500,
		voidedWakeSequences: [],
		voidedWakes: new Set(),
		wakeEvents: [],
		wakeSequence: 0,
	};
	return { ...base, ...overrides };
}

describe("outputWakeBudget persistence (vstack#210)", () => {
	test("taskSnapshot carries the budget over to the persisted form", () => {
		const task = baseTask();
		task.outputWakeBudget = { wakes: 12, bytes: 4_096, exhausted: false, announcedAt: null };
		const snapshot = taskSnapshot(task);
		expect(snapshot.outputWakeBudget).toEqual({ wakes: 12, bytes: 4_096, exhausted: false, announcedAt: null });
	});

	test("restoredTaskFromSnapshot rehydrates a non-zero budget", () => {
		const task = baseTask({
			status: "running",
			outputWakeBudget: { wakes: 19, bytes: 18_000, exhausted: false, announcedAt: null },
		});
		const snapshot = taskSnapshot(task);
		// Mark the snapshot as having ended so the restore path coerces it to
		// terminal state — pid liveness is unavailable in tests.
		snapshot.status = "running";

		const restored = restoredTaskFromSnapshot(snapshot, { identityProbe: () => null });
		expect(restored.outputWakeBudget?.wakes).toBe(19);
		expect(restored.outputWakeBudget?.bytes).toBe(18_000);
		expect(restored.outputWakeBudget?.exhausted).toBe(false);
	});

	test("an exhausted budget survives restore and continues to suppress output wakes", () => {
		const task = baseTask({
			status: "running",
			outputWakeBudget: { wakes: DEFAULT_OUTPUT_WAKE_BUDGET_MAX_WAKES, bytes: DEFAULT_OUTPUT_WAKE_BUDGET_MAX_BYTES, exhausted: true, announcedAt: 1_700_000_000_400 },
		});
		const snapshot = taskSnapshot(task);
		const restored = restoredTaskFromSnapshot(snapshot, { identityProbe: () => null });
		// restoredTaskFromSnapshot may coerce the task to a terminal state when
		// the identityProbe returns null. For this test we only care about the
		// budget; flip back to running so shouldEmitOutputWake reaches the
		// budget guard.
		restored.status = "running";
		restored.stopReason = null;
		restored.closed = false;

		expect(restored.outputWakeBudget?.exhausted).toBe(true);
		expect(restored.outputWakeBudget?.announcedAt).toBe(1_700_000_000_400);

		const diagnostics: WakeDiagnostic[] = [];
		const allowed = shouldEmitOutputWake(restored, {
			eventAt: 1_700_000_001_000,
			logDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
			newOutput: "more\n",
			newOutputTail: "more\n",
			patternMatched: true,
			sequence: 99,
			wakeBudgetLimits: { maxBytes: DEFAULT_OUTPUT_WAKE_BUDGET_MAX_BYTES, maxWakes: DEFAULT_OUTPUT_WAKE_BUDGET_MAX_WAKES },
		});

		expect(allowed).toBe(false);
		expect(diagnostics.at(-1)?.reason).toBe("wake-budget-exhausted");
	});

	test("pre-1.4.0 snapshots without outputWakeBudget get a fresh zero budget on restore", () => {
		const legacy: BackgroundTaskSnapshot = {
			command: "echo legacy",
			cwd: "/tmp",
			exitCode: null,
			expiresAt: null,
			id: "bg-legacy",
			lastOutputAt: null,
			logFile: "/tmp/bg-legacy.log",
			notifyMode: "always",
			notifyOnExit: true,
			notifyOnOutput: false,
			outputBytes: 0,
			pid: 1,
			startedAt: 1,
			status: "completed",
			title: "legacy",
			updatedAt: 1,
		};
		const restored = restoredTaskFromSnapshot(legacy, { identityProbe: () => null });
		expect(restored.outputWakeBudget).toEqual({ wakes: 0, bytes: 0, exhausted: false, announcedAt: null });
	});

	test("normalizeOutputWakeBudget produces a stable shape even after JSON round-trip", () => {
		const original = { wakes: 7, bytes: 1234, exhausted: true, announcedAt: 555 };
		const restored = normalizeOutputWakeBudget(JSON.parse(JSON.stringify(original)));
		expect(restored).toEqual(original);
	});
});
