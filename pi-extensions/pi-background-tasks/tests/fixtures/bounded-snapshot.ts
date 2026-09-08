import type { BackgroundTaskSnapshot } from "../../extensions/types.js";

export function boundedSnapshot(overrides: Partial<BackgroundTaskSnapshot> = {}): BackgroundTaskSnapshot {
	return {
		command: "printf ready",
		cwd: "/tmp/worktree",
		exitCode: null,
		exitNotified: false,
		expiresAt: null,
		id: "bg-1",
		lastOutputAt: 0,
		logFile: "/tmp/bg-1.log",
		notifyMode: "always",
		notifyOnExit: true,
		notifyOnOutput: false,
		outputBytes: 0,
		pid: 1234,
		startedAt: 1_700_000_000_000,
		status: "completed",
		title: "fake task",
		updatedAt: 1_700_000_000_500,
		voidedWakeSequences: [],
		wakeEvents: [],
		wakeSequence: 0,
		...overrides,
	};
}
