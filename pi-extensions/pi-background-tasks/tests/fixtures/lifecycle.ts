import type { LifecycleHooks } from "../../extensions/lifecycle.js";
import type { BackgroundTaskSnapshot, ManagedTask, ProcessIdentity, TaskEventType } from "../../extensions/types.js";

export function fakeIdent(pid: number): ProcessIdentity {
	return { pid, startToken: `start-${pid}`, comm: "approval-wait" };
}

export function fakeSnapshot(overrides: Partial<BackgroundTaskSnapshot> = {}): BackgroundTaskSnapshot {
	return {
		command: "approval-wait 81", cwd: "/private/worktree", exitCode: null,
		exitNotified: false, expiresAt: null, id: "bg-3", lastOutputAt: null,
		logFile: "/private/log.txt", notifyOnExit: true, notifyOnOutput: false,
		notifyPattern: undefined, outputBytes: 0, pid: 2409160, sessionId: "sess-1",
		startedAt: 1_700_000_000_000, status: "running", title: "bot review wait PR 81",
		updatedAt: 1_700_000_000_000, ...overrides,
	};
}

export function fakeTask(overrides: Partial<ManagedTask> = {}): ManagedTask {
	return {
		...fakeSnapshot(overrides), child: null, closed: false, forceKillTimer: null,
		lastAnnouncedLength: 0, matcher: null, output: "", outputTimer: null,
		stopReason: null, timeoutTimer: null, ...overrides,
	};
}

// Hooks replace host effects only. Event fields are copied when the sender runs.
export function recordingHooks(sendReturns = true) {
	const events: { type: TaskEventType; task: ManagedTask; id: string; reason: ManagedTask["terminationReason"] }[] = [];
	let persists = 0;
	let remembers = 0;
	let refreshes = 0;
	let timerClears = 0;
	const hooks: LifecycleHooks = {
		rememberSnapshot(task) { remembers++; return { ...task }; },
		persistSnapshots() { persists++; return { appendEntry: true, sidecar: true }; },
		sendTaskEvent(type, task) {
			events.push({ type, task, id: task.id, reason: task.terminationReason });
			return sendReturns;
		},
		refreshUi() { refreshes++; },
		clearTaskTimers() { timerClears++; },
	};
	return {
		hooks,
		observe(tasks: readonly ManagedTask[]) {
			return {
				events: events.map(({ type, task, id, reason }) => ({
					type, id, reason, sameTask: tasks.find((candidate) => candidate.id === id) === task,
				})),
				persists, remembers, refreshes, timerClears,
			};
		},
	};
}
