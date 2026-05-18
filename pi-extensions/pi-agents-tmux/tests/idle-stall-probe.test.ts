// Round-2 fix (vstack#63 reviewer-arch + reviewer-error major): the
// idle-stall watchdog must consult the real bridge isIdle signal
// instead of returning true unconditionally. Default-busy on any
// failure so the watchdog skips rather than false-fires.

import assert from "node:assert/strict";
import test from "node:test";

import {
	probePaneIdle,
	BRIDGE_IDLE_PROBE_DEFAULT_TIMEOUT_MS,
	type ProbePaneIdleDeps,
} from "../extensions/subagent/idle-stall-probe.js";
import type { PaneRegistryEntry, PaneTaskRecord } from "../extensions/subagent/types.js";

function record(): PaneTaskRecord {
	return {
		taskId: "task-stall-1",
		agent: "planner",
		task: "Plan.",
		status: "running",
		createdAt: "2026-05-15T12:00:00.000Z",
		updatedAt: "2026-05-15T12:00:00.000Z",
	};
}

function entry(overrides: Partial<PaneRegistryEntry> = {}): PaneRegistryEntry {
	return {
		agent: "planner",
		paneId: "%7",
		windowName: "agent-planner",
		cwd: "/tmp/cwd",
		sessionFile: "/tmp/session.jsonl",
		promptFile: "/tmp/prompt.md",
		launcherFile: "/tmp/launcher.sh",
		startedAt: "2026-05-15T12:00:00.000Z",
		bridgePid: "12345",
		bridgeSocket: "/tmp/pi-bridge.sock",
		...overrides,
	};
}

function spawnEnoent(path = "/usr/bin/pi-bridge", overrides: Record<string, unknown> = {}): Error {
	return Object.assign(new Error(`spawn ${path} ENOENT`), {
		code: "ENOENT",
		syscall: "spawn",
		path,
		...overrides,
	});
}

function deps(opts: {
	bridgeBin?: string | null;
	registry?: Partial<PaneRegistryEntry> | null;
	execResult?: { code: number; stdout: string; stderr: string; error?: unknown };
	execError?: unknown;
}): { d: ProbePaneIdleDeps; calls: { args: string[]; cwd?: string }[]; warnings: string[] } {
	const calls: { args: string[]; cwd?: string }[] = [];
	const warnings: string[] = [];
	const d: ProbePaneIdleDeps = {
		resolveBridgeBin: async () => {
			if (opts.bridgeBin === null) return undefined;
			return opts.bridgeBin ?? "/usr/bin/pi-bridge";
		},
		execCapture: async (_command, args, options) => {
			calls.push({ args, cwd: options?.cwd });
			if (opts.execError) throw opts.execError;
			return opts.execResult ?? { code: 0, stdout: "", stderr: "" };
		},
		readPaneRegistryEntry: async () => {
			if (opts.registry === null) return undefined;
			return entry(opts.registry);
		},
		logWarn: (msg) => warnings.push(msg),
	};
	return { d, calls, warnings };
}

test("bridge reports isIdle:true -> idle (can fire)", async () => {
	const { d, calls } = deps({
		execResult: { code: 0, stdout: JSON.stringify({ data: { isIdle: true } }), stderr: "" },
	});
	const result = await probePaneIdle(record(), d);
	assert.equal(result.idle, true);
	assert.equal(result.reason, "bridge-idle");
	assert.equal(calls.length, 1);
	assert.deepEqual(calls[0]!.args, ["state", "--socket", "/tmp/pi-bridge.sock"]);
});

test("bridge reports isIdle:false -> busy (skip fire)", async () => {
	const { d } = deps({
		execResult: { code: 0, stdout: JSON.stringify({ data: { isIdle: false } }), stderr: "" },
	});
	const result = await probePaneIdle(record(), d);
	assert.equal(result.idle, false);
	assert.equal(result.reason, "bridge-busy");
});

test("flat state shape (no .data wrapper) is also accepted", async () => {
	const { d } = deps({
		execResult: { code: 0, stdout: JSON.stringify({ isIdle: true }), stderr: "" },
	});
	const result = await probePaneIdle(record(), d);
	assert.equal(result.idle, true);
});

test("bridge spawn ENOENT (exec throws) -> default-busy without warning toast", async () => {
	const { d, warnings } = deps({
		execError: spawnEnoent(),
	});
	const result = await probePaneIdle(record(), d);
	assert.equal(result.idle, false);
	assert.equal(result.reason, "bridge-bin-not-found");
	assert.equal(warnings.length, 0);
});

test("bridge spawn ENOENT (non-zero result) -> default-busy without warning toast", async () => {
	const { d, warnings } = deps({
		execResult: { code: 1, stdout: "", stderr: "Error: spawn /usr/bin/pi-bridge ENOENT", error: spawnEnoent() },
	});
	const result = await probePaneIdle(record(), d);
	assert.equal(result.idle, false);
	assert.equal(result.reason, "bridge-bin-not-found");
	assert.equal(warnings.length, 0);
});

test("text-only spawn ENOENT is not treated as expected bridge-bin missing", async () => {
	const { d, warnings } = deps({
		execError: new Error("spawn /usr/bin/pi-bridge ENOENT"),
	});
	const result = await probePaneIdle(record(), d);
	assert.equal(result.idle, false);
	assert.equal(result.reason, "bridge-error");
	assert.ok(warnings.some((w) => w.includes("exec threw")));
});

test("structured ENOENT for a different path is logged as a real failure", async () => {
	const { d, warnings } = deps({
		execError: spawnEnoent("/tmp/not-pi-bridge"),
	});
	const result = await probePaneIdle(record(), d);
	assert.equal(result.idle, false);
	assert.equal(result.reason, "bridge-error");
	assert.ok(warnings.some((w) => w.includes("exec threw")));
});

test("bridge unreachable (non-ENOENT exec throws) -> default-busy with bridge-error", async () => {
	const { d, warnings } = deps({
		execError: new Error("ECONNRESET"),
	});
	const result = await probePaneIdle(record(), d);
	assert.equal(result.idle, false);
	assert.equal(result.reason, "bridge-error");
	assert.ok(warnings.some((w) => w.includes("exec threw")));
});

test("bridge times out -> default-busy with bridge-timeout", async () => {
	const { d } = deps({ execError: new Error("pi-bridge state timed out after 2000ms") });
	const result = await probePaneIdle(record(), d);
	assert.equal(result.idle, false);
	assert.equal(result.reason, "bridge-timeout");
});

test("non-zero exit code -> default-busy with bridge-error", async () => {
	const { d, warnings } = deps({
		execResult: { code: 1, stdout: "", stderr: "no such session" },
	});
	const result = await probePaneIdle(record(), d);
	assert.equal(result.idle, false);
	assert.equal(result.reason, "bridge-error");
	assert.ok(warnings.some((w) => w.includes("exit 1")));
});

test("malformed JSON output -> default-busy with bridge-malformed-json", async () => {
	const { d } = deps({
		execResult: { code: 0, stdout: "not json", stderr: "" },
	});
	const result = await probePaneIdle(record(), d);
	assert.equal(result.idle, false);
	assert.equal(result.reason, "bridge-malformed-json");
});

test("registry miss (no entry for agent) -> default-busy with registry-miss", async () => {
	const { d } = deps({ registry: null });
	const result = await probePaneIdle(record(), d);
	assert.equal(result.idle, false);
	assert.equal(result.reason, "registry-miss");
});

test("entry missing bridge metadata -> default-busy with bridge-missing-metadata", async () => {
	const { d } = deps({
		registry: { bridgePid: undefined, bridgeSocket: undefined },
	});
	const result = await probePaneIdle(record(), d);
	assert.equal(result.idle, false);
	assert.equal(result.reason, "bridge-missing-metadata");
});

test("pi-bridge binary not found -> default-busy with bridge-bin-not-found", async () => {
	const { d } = deps({ bridgeBin: null });
	const result = await probePaneIdle(record(), d);
	assert.equal(result.idle, false);
	assert.equal(result.reason, "bridge-bin-not-found");
});

test("falls back to --pid when only bridgePid is present", async () => {
	const { d, calls } = deps({
		registry: { bridgeSocket: undefined, bridgePid: "9999" },
		execResult: { code: 0, stdout: JSON.stringify({ data: { isIdle: true } }), stderr: "" },
	});
	const result = await probePaneIdle(record(), d);
	assert.equal(result.idle, true);
	assert.deepEqual(calls[0]!.args, ["state", "--pid", "9999"]);
});

test("default timeout constant is 2000ms", () => {
	assert.equal(BRIDGE_IDLE_PROBE_DEFAULT_TIMEOUT_MS, 2000);
});
