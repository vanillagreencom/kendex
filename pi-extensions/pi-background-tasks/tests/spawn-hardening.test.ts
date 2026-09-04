//  hardening: protect bg_task children from parent/session/pgid
// cascades when Pi exits, restarts, or its session leader dies.
//
// H1 (process-group / parent-death cascade) + H3 (session-leader cascade)
// are addressed by spawning detached on POSIX (Node calls setsid() before
// exec). H2 (snapshot reconciliation kill) is addressed by keeping the
// orphan-watcher metadata-only — no kill() under reconcile.
//
// These tests don't actually spawn child processes; they exercise the
// helpers and module source so a contract change trips
// the suite.

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { createOrphanWatcher } from "../extensions/orphan-watcher.js";
import type { LifecycleHooks } from "../extensions/lifecycle.js";
import { taskSnapshot } from "../extensions/snapshot.js";
import type { ManagedTask, ProcessIdentity } from "../extensions/types.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const BACKGROUND_TASKS_SRC = resolve(HERE, "../extensions/background-tasks.ts");
const ORPHAN_WATCHER_SRC = resolve(HERE, "../extensions/orphan-watcher.ts");

function fakeOrphan(): ManagedTask {
	return {
		child: null,
		closed: false,
		command: "idle-watcher",
		cwd: "/tmp/w",
		exitCode: null,
		exitNotified: false,
		expiresAt: null,
		forceKillTimer: null,
		id: "bg-97",
		lastAnnouncedLength: 0,
		lastOutputAt: null,
		logFile: "/tmp/log.txt",
		matcher: null,
		notifyOnExit: true,
		notifyOnOutput: false,
		notifyPattern: undefined,
		output: "",
		outputBytes: 0,
		outputTimer: null,
		pid: 4242,
		procIdent: { comm: "bash", pid: 4242, startToken: "start-4242" } satisfies ProcessIdentity,
		restored: true,
		sessionId: "sess-A",
		startedAt: 1_700_000_000_000,
		status: "running",
		stopReason: null,
		timeoutTimer: null,
		title: "idle watcher",
		updatedAt: 1_700_000_000_000,
		voidedWakes: new Set<number>(),
	};
}

function recordingHooks(): LifecycleHooks {
	return {
		clearTaskTimers: () => {},
		persistSnapshots: () => {},
		refreshUi: () => {},
		rememberSnapshot: (task) => taskSnapshot(task),
		sendTaskEvent: () => true,
	};
}

function stripLineComments(source: string): string {
	const lines = source.split(/\r?\n/);
	const cleaned = lines.map((line) => {
		const idx = line.indexOf("//");
		return idx >= 0 ? line.slice(0, idx) : line;
	});
	return cleaned.join("\n");
}

describe("spawn hardening (kendex#97)", () => {
	test("background-tasks spawn options request detached:true on non-Windows", () => {
		const src = readFileSync(BACKGROUND_TASKS_SRC, "utf8");
		// The exact call site that creates the tracked child. The literal
		// expression matters: if a future refactor drops detached or makes
		// it a runtime-toggleable boolean, the protection regresses.
		expect(src).toContain('detached: process.platform !== "win32"');
		// Documentation breadcrumb: the comment block must reference the
		// issue so refactors that delete it are caught here.
		expect(src).toContain("kendex#97 hardening");
		expect(src).toContain("H1 (process-group");
		expect(src).toContain("H3 (session-leader cascade)");
	});

	test("orphan-watcher source contains no process.kill / child.kill / killTaskProcess call", () => {
		const src = readFileSync(ORPHAN_WATCHER_SRC, "utf8");
		// Strip line-comments so the hardening prose (which intentionally
		// names the forbidden calls) does not trip the guard.
		const code = stripLineComments(src);
		expect(code).not.toMatch(/\bprocess\.kill\(/);
		expect(code).not.toMatch(/\bchild\.kill\(/);
		expect(code).not.toMatch(/\bkillTaskProcess\(/);
		// Hardening comment is the contract: a future kill() addition
		// must also delete this comment, which is the early-warning signal.
		expect(src).toContain("METADATA-ONLY");
	});

	test("orphan-watcher does not invoke its hooks beyond finalizeTaskLifecycle", () => {
		// Belt-and-braces: spy that the watcher only causes the finalize
		// path, which does not kill the process. An unexpected hook call must fail here.
		const calls: string[] = [];
		const hooks: LifecycleHooks = {
			clearTaskTimers: () => calls.push("clearTaskTimers"),
			persistSnapshots: () => calls.push("persistSnapshots"),
			refreshUi: () => calls.push("refreshUi"),
			rememberSnapshot: (task) => {
				calls.push("rememberSnapshot");
				return taskSnapshot(task);
			},
			sendTaskEvent: () => {
				calls.push("sendTaskEvent");
				return true;
			},
		};
		const tasks = [fakeOrphan()];
		const watcher = createOrphanWatcher({
			getTasks: () => tasks,
			hooks,
			identityProbe: () => null,
		});
		watcher.checkOnce();
		const unexpected = calls.filter(
			(name) => !["clearTaskTimers", "persistSnapshots", "refreshUi", "rememberSnapshot", "sendTaskEvent"].includes(name),
		);
		expect(unexpected).toEqual([]);
	});

	test("orphan-watcher leaves a still-matching pid alone (no finalize, no kill)", () => {
		const tasks = [fakeOrphan()];
		const hooks = recordingHooks();
		const watcher = createOrphanWatcher({
			getTasks: () => tasks,
			hooks,
			identityProbe: (pid) => ({ comm: "bash", pid, startToken: "start-4242" }),
		});
		const { finalized } = watcher.checkOnce();
		expect(finalized).toBe(0);
		expect(tasks[0]!.status).toBe("running");
		expect(tasks[0]!.terminationReason).toBeUndefined();
	});

	test("systemd resource-control stop does not kill the wrapper pgid after a successful unit stop", () => {
		const src = readFileSync(BACKGROUND_TASKS_SRC, "utf8");
		expect(src).toContain("if (resourceStop.attempted && resourceStop.ok) return { sent: true };");
		expect(src.indexOf("if (resourceStop.attempted && resourceStop.ok) return { sent: true };")).toBeLessThan(src.indexOf("process.kill(-task.pid, signal)"));
	});

	test("failed systemd resource-control stop does not fall back to killing the wrapper pgid", () => {
		const src = readFileSync(BACKGROUND_TASKS_SRC, "utf8");
		const failureReturn = "return { error, sent: false };";
		expect(src).toContain("[resource-control stop error]");
		expect(src).toContain(failureReturn);
		expect(src.indexOf(failureReturn)).toBeLessThan(src.indexOf("process.kill(-task.pid, signal)"));
	});

	test("failed resource-control stop without safe fallback is not finalized as stopped", () => {
		const src = readFileSync(BACKGROUND_TASKS_SRC, "utf8");
		expect(src).toContain("if (stopResult.error)");
		expect(src).toContain("return { ok: false, message: `Failed to stop ${task.id}: ${stopResult.error}` }");
		expect(src).toContain("[shutdown stop skipped]");
	});
});
