// Liveness watcher for orphan-running tasks rehydrated by
// restoredTaskFromSnapshot when the recorded child pid is still alive.
//
// This module polls an asynchronous identity probe per orphan. When the pid
// disappears, it routes through finalizeTaskLifecycle so the same
// canonical exit wake (and pi-bg-task-exit daemon path) fires that
// would have fired if Pi had stayed alive.
//
// A pass runs at most PROBE_CONCURRENCY probes at once, never overlaps the
// previous pass, and finalizes nothing once stop() has run.
//
// This module is METADATA-ONLY. It MUST NOT call process.kill() or child.kill() on
// the tracked pid under any reconcile or polling path. The only
// observation it makes is the identity probe (defaultReadProcessIdentity
// reads /proc or shells out to `ps`, neither of which signals); the
// only mutation it makes is finalizeTaskLifecycle, which updates the
// in-memory + persisted snapshot and emits the canonical exit wake.
// If a future change adds a real kill here it would resurrect the H2
// failure mode where a tracked pid + start-time pair flickering across
// snapshot writes could be proactively terminated.
//
// Pure logic; tests inject deterministic probes + timers.

import { finalizeTaskLifecycle, type LifecycleHooks } from "./lifecycle.js";
import { mapWithConcurrency, PROBE_CONCURRENCY } from "./probes.js";
import { defaultSystemdUnitActive } from "./resource-control.js";
import { defaultReadProcessIdentity, identityMatches } from "./snapshot.js";
import type { ManagedTask, ProcessIdentity } from "./types.js";

export interface OrphanWatcherDeps {
	getTasks: () => Iterable<ManagedTask>;
	hooks: LifecycleHooks;
	pollMs?: number;
	// PID-reuse-safe identity probe. Returns null when the pid is gone
	// (orphan exited cleanly) and a ProcessIdentity when it is alive.
	// The watcher compares against task.procIdent so a recycled PID
	// hitting an unrelated process is detected as a mismatch and treated
	// like the pid is gone.
	identityProbe?: (pid: number) => Promise<ProcessIdentity | null>;
	// For resource-controlled systemd units, the wrapper pid can be less
	// authoritative than the transient unit. true = still running, false =
	// known inactive, null = unavailable so the watcher falls back to pid.
	unitActiveProbe?: (unitName: string) => Promise<boolean | null>;
	// The callback returns the pass it started, so a caller can await it.
	setIntervalFn?: (cb: () => Promise<unknown>, ms: number) => NodeJS.Timeout;
	clearIntervalFn?: (handle: NodeJS.Timeout) => void;
	onFinalize?: (task: ManagedTask, reason: "pid-gone" | "pid-reused") => void;
}

export interface OrphanWatcher {
	/** Run one pass, or join the pass already running. */
	checkOnce(): Promise<{ finalized: number }>;
	start(): void;
	stop(): void;
}

export const DEFAULT_ORPHAN_POLL_MS = 30_000;

// A task is "orphan-running" when status=running AND it was restored
// from a snapshot (child handle is gone) AND its recorded pid is real.
// This identifies exactly the alive-at-restore branch from
// restoredTaskFromSnapshot.
export function isOrphanRunning(task: ManagedTask): boolean {
	if (task.status !== "running") return false;
	if (task.restored !== true) return false;
	if (task.child !== null) return false;
	if (!Number.isFinite(task.pid) || task.pid <= 0) return false;
	return true;
}

export function createOrphanWatcher(deps: OrphanWatcherDeps): OrphanWatcher {
	const pollMs = deps.pollMs ?? DEFAULT_ORPHAN_POLL_MS;
	const probe = deps.identityProbe ?? defaultReadProcessIdentity;
	const unitProbe = deps.unitActiveProbe ?? defaultSystemdUnitActive;
	const startTimer = deps.setIntervalFn ?? ((cb, ms) => setInterval(cb, ms));
	const stopTimer = deps.clearIntervalFn ?? ((h) => clearInterval(h));
	let timer: NodeJS.Timeout | null = null;
	let pass: Promise<{ finalized: number }> | null = null;
	// stop() bumps the generation, so a pass it interrupts finalizes nothing.
	let generation = 0;

	async function orphanVerdict(task: ManagedTask): Promise<"alive" | "pid-gone" | "pid-reused"> {
		const unitName = task.resourceControl?.mode === "systemd-run" ? task.resourceControl.unitName : undefined;
		const unitActive = unitName ? await unitProbe(unitName) : null;
		if (unitActive === true) return "alive";
		if (unitActive === false) return "pid-gone";
		const current = await probe(task.pid);
		if (current === null) return "pid-gone";
		return identityMatches(task.procIdent, current) ? "alive" : "pid-reused";
	}

	async function runPass(passGeneration: number): Promise<{ finalized: number }> {
		const orphans = [...deps.getTasks()].filter(isOrphanRunning);
		const verdicts = await mapWithConcurrency(orphans, PROBE_CONCURRENCY, orphanVerdict);
		let finalized = 0;
		for (const [index, task] of orphans.entries()) {
			const reason = verdicts[index];
			if (reason === "alive") continue;
			// The task may have been stopped, finalized or cleared while the
			// probes ran, or the watcher stopped.
			if (passGeneration !== generation || !isOrphanRunning(task)) continue;
			// PID disappeared or was recycled by an unrelated process. We
			// can't recover the real exit code; the orphan is gone. Use
			// exitCode=null and let finalizeTaskLifecycle classify as
			// 'failed' (no stopReason, non-zero exit). The canonical exit
			// event fires here, and the subscriber/daemon routes the
			// resulting pi-bg-task-exit wake to master.
			//
			// stamp terminationReason so callers can distinguish
			// an orphan-watcher finalize from an explicit extension-stop or
			// reconcile-on-restart.
			finalizeTaskLifecycle(
				task,
				null,
				deps.hooks,
				undefined,
				reason === "pid-gone" ? "orphaned-pid-gone" : "orphaned-pid-reused",
			);
			deps.onFinalize?.(task, reason);
			finalized += 1;
		}
		return { finalized };
	}

	function checkOnce(): Promise<{ finalized: number }> {
		if (pass) return pass;
		const current = runPass(generation).finally(() => {
			if (pass === current) pass = null;
		});
		pass = current;
		return current;
	}

	function start(): void {
		if (timer) return;
		timer = startTimer(checkOnce, pollMs);
		// unref so the timer never blocks Pi shutdown.
		(timer as { unref?: () => void }).unref?.();
	}

	function stop(): void {
		generation += 1;
		pass = null;
		if (!timer) return;
		stopTimer(timer);
		timer = null;
	}

	return { checkOnce, start, stop };
}
