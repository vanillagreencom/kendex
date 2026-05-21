// bg_task / bg_status log tool-result transcript bounds (vstack#210).
//
// `bg_task log` and `bg_status log` add `details.tasks[i].outputTail` to the
// transcript; their text content is bounded by `logTailMaxChars` (default
// 10000) and the `details.task` snapshot is bounded by the wake manifest.
// The reviewer-test concern: the issue specifically calls out log
// tool-result transcript growth and the new default needed direct coverage.

import { describe, expect, test } from "bun:test";

import { DEFAULT_LOG_TAIL_MAX_CHARS } from "../extensions/constants.js";
import { formatTaskLog, taskLogTruncation } from "../extensions/format.js";
import { taskSnapshot } from "../extensions/snapshot.js";
import type { ManagedTask } from "../extensions/types.js";
import { WAKE_MANIFEST_FIELD_MAX_CHARS, compactBackgroundTaskSnapshot, emptyOutputWakeBudget } from "../extensions/wake-events.js";

function logTask(overrides: Partial<ManagedTask> = {}): ManagedTask {
	const base: ManagedTask = {
		child: null,
		closed: true,
		command: "echo log",
		cwd: "/tmp",
		exitCode: 0,
		exitNotified: true,
		expiresAt: null,
		forceKillTimer: null,
		id: "bg-log-1",
		lastAnnouncedLength: 0,
		lastOutputAt: 1_700_000_000_500,
		logFile: "/tmp/bg-log-1.log",
		matcher: null,
		notifyMode: "always",
		notifyOnExit: true,
		notifyOnOutput: false,
		output: "",
		outputBytes: 0,
		outputPatternMatched: false,
		outputTimer: null,
		outputWakeBudget: emptyOutputWakeBudget(),
		pendingWakes: [],
		pid: 4242,
		startedAt: 1_700_000_000_000,
		status: "completed",
		stopReason: null,
		timeoutTimer: null,
		title: "log",
		updatedAt: 1_700_000_000_500,
		voidedWakeSequences: [],
		voidedWakes: new Set(),
		wakeEvents: [],
		wakeSequence: 0,
	};
	return { ...base, ...overrides };
}

describe("taskLogTruncation (vstack#210)", () => {
	test("returns undefined for output below the cap", () => {
		const output = "short\n".repeat(10);
		expect(taskLogTruncation(output, "/tmp/log")).toBeUndefined();
	});

	test("returns a truncation descriptor pointing at the log file for huge output", () => {
		const huge = "x".repeat(DEFAULT_LOG_TAIL_MAX_CHARS * 4);
		const t = taskLogTruncation(huge, "/tmp/log");
		expect(t).toBeDefined();
		expect(t!.direction).toBe("tail");
		expect(t!.truncated).toBe(true);
		expect(t!.fullOutputPath).toBe("/tmp/log");
		expect(t!.shownChars).toBe(DEFAULT_LOG_TAIL_MAX_CHARS);
		expect(t!.totalChars).toBe(huge.length);
	});
});

describe("formatTaskLog (vstack#210)", () => {
	test("emits the full output when below the cap", () => {
		const output = "all good\n".repeat(50);
		expect(formatTaskLog(output, "/tmp/log")).toBe(output);
	});

	test("clips to the default cap and points at the on-disk log path", () => {
		const huge = "y".repeat(DEFAULT_LOG_TAIL_MAX_CHARS * 5);
		const formatted = formatTaskLog(huge, "/tmp/big.log");
		expect(formatted.startsWith("[...truncated]\n")).toBe(true);
		expect(formatted).toContain("/tmp/big.log");
		expect(formatted).toContain(`Showing last ${DEFAULT_LOG_TAIL_MAX_CHARS} of ${huge.length} character(s)`);
		// Allow the truncation banner + path tail to add a small amount of
		// envelope text on top of the bounded slice.
		expect(formatted.length).toBeLessThan(DEFAULT_LOG_TAIL_MAX_CHARS + 256);
	});

	test("(empty) sentinel for falsy output", () => {
		expect(formatTaskLog("", "/tmp/log")).toBe("(empty)");
	});
});

describe("log tool-result details bound the task snapshot (vstack#210)", () => {
	test("log action keeps task command/title/cwd/logFile under the wake manifest cap", () => {
		const task = logTask({
			command: "C".repeat(200_000),
			title: "T".repeat(2_000),
			cwd: "/path/" + "P".repeat(5_000),
			logFile: "/tmp/" + "L".repeat(5_000),
		});
		const compact = compactBackgroundTaskSnapshot(taskSnapshot(task));
		expect(compact.command.length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		expect(compact.title.length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		expect(compact.cwd.length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
		expect(compact.logFile.length).toBeLessThanOrEqual(WAKE_MANIFEST_FIELD_MAX_CHARS);
	});

	test("a log tool-result-shaped payload stays under the byte cap with huge output and metadata", () => {
		const huge = "z".repeat(DEFAULT_LOG_TAIL_MAX_CHARS * 4);
		// Realistic log path (~60 chars). The reviewer-security concern targets
		// command/title/cwd bombs, which the compact manifest bounds.
		const realisticLogFile = "/tmp/vstack-pi-bg/bg-log-1-1700000000000.log";
		const task = logTask({
			command: "Q".repeat(200_000),
			title: "T".repeat(5_000),
			cwd: "/" + "C".repeat(5_000),
			logFile: realisticLogFile,
		});
		const compactSnapshot = compactBackgroundTaskSnapshot(taskSnapshot(task));
		const truncation = taskLogTruncation(huge, task.logFile);

		// Approximate the tool result that registrations.ts produces: bounded
		// text + bounded task manifest + fullOutputPath + truncation marker.
		const payload = {
			content: [{ type: "text", text: formatTaskLog(huge, task.logFile) }],
			details: {
				action: "log",
				task: compactSnapshot,
				...(truncation ? { fullOutputPath: task.logFile, truncation } : {}),
			},
		};
		const payloadBytes = Buffer.byteLength(JSON.stringify(payload), "utf8");
		// Bounded text (~10KB) + bounded manifest (~1KB) + envelope <= 16KB.
		expect(payloadBytes).toBeLessThan(16_384);
		expect(payload.details.fullOutputPath).toBe(task.logFile);
		expect(payload.details.truncation?.fullOutputPath).toBe(task.logFile);
		expect(payload.details.truncation?.shownChars).toBe(DEFAULT_LOG_TAIL_MAX_CHARS);
	});
});
