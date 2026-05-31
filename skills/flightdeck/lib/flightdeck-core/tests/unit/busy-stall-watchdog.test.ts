import { describe, expect, test } from "bun:test";

import {
	BUSY_STALL_CLASSIFIER_TAG,
	BusyStallWatchdog,
	type BusyStallConfig,
	type ProcessTreeSample,
} from "../../src/daemon/busy-stall-watchdog.ts";

const config: BusyStallConfig = {
	bridgeProbeIntervalSec: 1,
	clockTicksPerSecond: 100,
	cpuPct: 90,
	enabled: true,
	gitProbeIntervalSec: 30,
	thresholdSec: 10,
};

function sample(ticks: number, running = true): ProcessTreeSample {
	return { pid: 123, pids: [123], running, state: running ? "123:R" : "123:S", ticks };
}

describe("busy-stall watchdog", () => {
	test("fires only after sustained hot CPU, stable progress, and unresponsive bridge", () => {
		const watchdog = new BusyStallWatchdog(config);
		expect(watchdog.observeLocal({ harness: "pi", nowMs: 0, paneId: "%1", panePid: 123, processSample: sample(0), progressKey: "h1|git:a" })).toBeNull();
		expect(watchdog.observeLocal({ harness: "pi", nowMs: 1_000, paneId: "%1", panePid: 123, processSample: sample(100), progressKey: "h1|git:a" })).toBeNull();
		const candidate = watchdog.observeLocal({ harness: "pi", nowMs: 11_000, paneId: "%1", panePid: 123, processSample: sample(1_100), progressKey: "h1|git:a" });
		expect(candidate).not.toBeNull();
		const healthy = watchdog.confirmBridge(candidate!, { reason: "ok", responsive: true }, 11_000);
		expect(healthy).toBeNull();

		const candidate2 = watchdog.observeLocal({ harness: "pi", nowMs: 12_100, paneId: "%1", panePid: 123, processSample: sample(1_210), progressKey: "h1|git:a" });
		expect(candidate2).not.toBeNull();
		const decision = watchdog.confirmBridge(candidate2!, { reason: "bridge-timeout", responsive: false }, 12_100);
		expect(decision?.tag).toBe(BUSY_STALL_CLASSIFIER_TAG);
		expect(decision?.details.bridge_reason).toBe("bridge-timeout");
		expect(decision?.details.cpu_pct).toBeGreaterThanOrEqual(90);
	});

	test("progress reset suppresses stale hot sample", () => {
		const watchdog = new BusyStallWatchdog(config);
		watchdog.observeLocal({ harness: "pi", nowMs: 0, paneId: "%2", panePid: 456, processSample: sample(0), progressKey: "h1|git:a" });
		watchdog.observeLocal({ harness: "pi", nowMs: 1_000, paneId: "%2", panePid: 456, processSample: sample(100), progressKey: "h1|git:a" });
		const afterProgress = watchdog.observeLocal({ harness: "pi", nowMs: 11_000, paneId: "%2", panePid: 456, processSample: sample(1_100), progressKey: "h2|git:a" });
		expect(afterProgress).toBeNull();
	});

	test("sleeping/network-bound process does not fire despite tick growth", () => {
		const watchdog = new BusyStallWatchdog(config);
		watchdog.observeLocal({ harness: "pi", nowMs: 0, paneId: "%3", panePid: 789, processSample: sample(0, false), progressKey: "h1|git:a" });
		watchdog.observeLocal({ harness: "pi", nowMs: 1_000, paneId: "%3", panePid: 789, processSample: sample(100, false), progressKey: "h1|git:a" });
		const candidate = watchdog.observeLocal({ harness: "pi", nowMs: 11_000, paneId: "%3", panePid: 789, processSample: sample(1_100, false), progressKey: "h1|git:a" });
		expect(candidate).toBeNull();
	});
});
