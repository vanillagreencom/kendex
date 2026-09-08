import type { LifecycleHooks } from "../../extensions/lifecycle.js";
import { fakeTask } from "./lifecycle.js";
import { interceptNativeEffects } from "./spawn-native.js";

const input: { identity: "gone" | "reused" | "matching" } = JSON.parse(await Bun.stdin.text());
const native = await interceptNativeEffects();
try {
	const { createOrphanWatcher } = await import("../../extensions/orphan-watcher.js");
	const { taskSnapshot } = await import("../../extensions/snapshot.js");
	const task = fakeTask({ id: "bg-97", pid: 4242, restored: true, procIdent: { comm: "bash", pid: 4242, startToken: "start-4242" } });
	const calls: string[] = [];
	const events: unknown[] = [];
	const hooks: LifecycleHooks = {
		clearTaskTimers() { calls.push("clearTaskTimers"); },
		persistSnapshots() { calls.push("persistSnapshots"); },
		refreshUi() { calls.push("refreshUi"); },
		rememberSnapshot(value) { calls.push("rememberSnapshot"); return taskSnapshot(value); },
		sendTaskEvent(type, value) { calls.push("sendTaskEvent"); events.push({ type, sameTask: value === task, id: value.id, status: value.status, reason: value.terminationReason }); return true; },
	};
	const watcher = createOrphanWatcher({
		getTasks: () => [task], hooks,
		identityProbe: (pid) => input.identity === "gone" ? null : { comm: "bash", pid, startToken: input.identity === "matching" ? "start-4242" : "reused-start" },
	});
	const result = watcher.checkOnce();
	process.stdout.write(JSON.stringify({
		result, calls, events,
		task: { id: task.id, status: task.status, reason: task.terminationReason ?? null, reasonIsUndefined: task.terminationReason === undefined, exitCode: task.exitCode, closed: task.closed, exitNotified: task.exitNotified, stopReason: task.stopReason },
		signals: native.signals, childSignals: native.childSignals, spawns: native.spawns, syncCalls: native.syncCalls, unexpected: native.unexpected,
	}));
} finally { native.restore(); }
