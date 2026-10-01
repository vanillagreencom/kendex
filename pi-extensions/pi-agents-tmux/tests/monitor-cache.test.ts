import assert from "node:assert/strict";
import { after, test } from "node:test";
import { MonitorDetailCache } from "../extensions/subagent/browser/monitor-task-detail.js";
import { assertMonitorCacheBound, cleanupTempRuntimes, importRuntimeCopy } from "./browser-fixture.js";

after(cleanupTempRuntimes);

test("Monitor retains only the last 16 viewed traces and releases them on clear", () => {
	assertMonitorCacheBound(new MonitorDetailCache());
});

test("main's unbounded retention fails the trace cache assertion", async () => {
	const runtime = await importRuntimeCopy("browser/monitor-task-detail.ts", "if (this.size > 16) {", "if (false && this.size > 16) {") as typeof import("../extensions/subagent/browser/monitor-task-detail.js");
	assert.throws(() => assertMonitorCacheBound(new runtime.MonitorDetailCache()), { code: "ERR_ASSERTION" });
});
