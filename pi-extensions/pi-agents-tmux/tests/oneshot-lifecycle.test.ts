// The one-shot process lifecycle: the bg task timeout, settled shutdown
// and their interplay with continuations, aborts and signal delivery.

import assert from "node:assert/strict";
import { spawn as spawnChild } from "node:child_process";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { runSingleAgent, setBgSettledShutdownGraceMsForTests, setBgTimeoutKillGraceMsForTests, setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import test, { after } from "node:test";
import { cleanupTempRuntimes, tempRuntime, writeSettings, testAgent, installMockSpawn, installLifecycleMockSpawn, bridgeStdout, bridgeEvent, shapedStreamEvent, mockPiEvents, makeDetails, readTranscript } from "./single-agent-fixture.js";

after(cleanupTempRuntimes);

// One table for the settle-and-timeout state machine: every row is one
// process lifecycle the mock spawn can stage (what the child prints, how it
// answers a signal, when it closes) and the outcome the runner must reach.
// A row asserts once, on the whole observed outcome, so a row that stops
// distinguishing its lifecycle from a neighbour's fails on that row.
type Presence = Record<string, boolean>;

type LifecycleOutcome = {
	exitCode: number;
	stopReason?: string;
	/** Processes the run spawned; a retry would show as a second one. */
	spawns: number;
	/** Whether the result carries an error message at all; a clean success carries none. */
	error: boolean;
	kills: string[];
	/** Every lifecycle event the run emitted, `completed:<status>` and `failed:<status>:<reason>`, or `none`. */
	lifecycle?: string;
	lastContent?: unknown;
	/** Literal fragments the transcript must (true) or must not (false) carry. */
	transcript?: Presence;
	/** Literal fragments of `errorMessage`, where the message is the only carrier of the fact. */
	errorMessage?: Presence;
	/** Literal fragments of the `subagents:failed` payload's error. */
	failedEventError?: Presence;
};

type LifecycleRow = {
	label: string;
	timeoutMs: number;
	settledGraceMs?: number;
	killGraceMs?: number;
	mock: Parameters<typeof installLifecycleMockSpawn>[0];
	/** Milliseconds to wait after the result before observing, for an escalation that must not fire. */
	observeAfterMs?: number;
	expect: LifecycleOutcome;
};

function settledStdout(text: string, tail: unknown[] = []): string {
	return bridgeStdout([
		bridgeEvent("agent_start"),
		bridgeEvent("message_end", {
			message: { role: "assistant", content: [{ type: "text", text }], usage: { input: 1, output: 1, totalTokens: 2 }, stopReason: "stop" },
		}),
		bridgeEvent("agent_end", { content: [{ type: "text", text }] }),
		...tail,
	]);
}

const settledAfterEnd = (text: string) =>
	bridgeStdout([bridgeEvent("agent_start"), bridgeEvent("agent_end", { content: [{ type: "text", text }] }), bridgeEvent("agent_settled")]);

const lifecycleRows: LifecycleRow[] = [
	{
		label: "timeout: a hung child is terminated, escalated and reported unconfirmed",
		timeoutMs: 5,
		killGraceMs: 1,
		mock: { stdout: bridgeStdout([shapedStreamEvent("top-level", "message_update", { message: { role: "assistant", content: [{ type: "text", text: "stuck in tool loop" }] } })]) },
		expect: {
			exitCode: 1,
			spawns: 1,
			error: true,
			stopReason: "unresponsive_timeout",
			kills: ["SIGTERM", "SIGKILL"],
			lifecycle: "failed:failed:unresponsive_timeout",
			transcript: { "stuck in tool loop": true, '"buffered":true': true, '"reason":"timeout"': true, "Timeout termination SIGTERM": true, "Timeout termination SIGKILL": true },
			errorMessage: { "exceeded bg task timeout": true, "SIGTERM child delivered": true, "SIGKILL child delivered": true, "Timeout termination unconfirmed": true },
			failedEventError: { "Timeout termination unconfirmed": true },
		},
	},
	{
		label: "timeout: a kill the child refuses is recorded as a delivery failure",
		timeoutMs: 5,
		killGraceMs: 1,
		mock: { kill: () => false },
		expect: {
			exitCode: 1,
			spawns: 1,
			error: true,
			stopReason: "unresponsive_timeout",
			kills: ["SIGTERM", "SIGKILL"],
			errorMessage: { "SIGTERM child failed: proc.kill returned false": true, "SIGKILL child failed: proc.kill returned false": true },
			transcript: { "proc.kill returned false": true },
		},
	},
	{
		label: "timeout: a close after SIGTERM ends the escalation before SIGKILL",
		timeoutMs: 5,
		killGraceMs: 20,
		mock: { closeOnSignal: "SIGTERM" },
		expect: {
			exitCode: 1,
			spawns: 1,
			error: true,
			stopReason: "unresponsive_timeout",
			kills: ["SIGTERM"],
			errorMessage: { "Timeout termination SIGTERM": true, "Timeout termination SIGKILL": false, "Timeout termination unconfirmed": false },
			failedEventError: { "Timeout termination SIGTERM": true, "Timeout termination SIGKILL": false },
			transcript: { "Timeout termination SIGTERM": true, "Timeout termination SIGKILL": false, "Timeout termination unconfirmed": false },
		},
	},
	{
		label: "timeout disabled: a delayed successful exit completes",
		timeoutMs: 0,
		mock: {
			closeAfterMs: 10,
			stdout: bridgeStdout([bridgeEvent("message_end", { message: { role: "assistant", content: [{ type: "text", text: "done after delay" }], usage: { input: 1, output: 1, totalTokens: 2 } } })]),
		},
		expect: { exitCode: 0, spawns: 1, error: false, kills: [], lifecycle: "completed:completed" },
	},
	{
		label: "settled: a lingering print process is stopped and the run completes",
		timeoutMs: 100,
		settledGraceMs: 1,
		mock: { closeOnSignal: "SIGTERM", stdout: settledStdout("done before the print process exits", [bridgeEvent("agent_settled")]) },
		expect: {
			exitCode: 0,
			spawns: 1,
			error: false,
			stopReason: "stop",
			kills: ["SIGTERM"],
			lifecycle: "completed:completed",
			transcript: { '"type":"settled_shutdown"': true, '"semanticCompletion":"agent_settled"': true },
		},
	},
	{
		label: "settled: activity after agent_settled cancels the pending shutdown",
		timeoutMs: 100,
		settledGraceMs: 5,
		mock: {
			closeAfterMs: 20,
			stdout: settledStdout("first settled response", [
				bridgeEvent("agent_settled"),
				bridgeEvent("agent_start"),
				bridgeEvent("turn_start"),
				bridgeEvent("message_end", {
					message: { role: "assistant", content: [{ type: "text", text: "extension-started continuation" }], usage: { input: 1, output: 1, totalTokens: 2 }, stopReason: "stop" },
				}),
				bridgeEvent("agent_end", { content: [{ type: "text", text: "extension-started continuation" }] }),
			]),
		},
		expect: {
			exitCode: 0,
			spawns: 1,
			error: false,
			kills: [],
			lastContent: [{ type: "text", text: "extension-started continuation" }],
			transcript: { '"type":"settled_shutdown"': false },
		},
	},
	{
		label: "settled: activity after agent_settled hands ownership back to the task timeout",
		timeoutMs: 5,
		settledGraceMs: 20,
		mock: {
			closeAfterMs: 20,
			closeOnSignal: "SIGTERM",
			stdout: bridgeStdout([
				bridgeEvent("agent_start"),
				bridgeEvent("agent_end", { content: [{ type: "text", text: "first response" }] }),
				bridgeEvent("agent_settled"),
				bridgeEvent("agent_start"),
				bridgeEvent("turn_start"),
			]),
		},
		expect: { exitCode: 1, stopReason: "unresponsive_timeout", spawns: 1, error: true, kills: ["SIGTERM"] },
	},
	{
		label: "settled: a stale agent_settled after a continuation started is skipped",
		timeoutMs: 100,
		settledGraceMs: 1,
		mock: {
			closeOnSignal: "SIGTERM",
			stdout: settledStdout("first response", [bridgeEvent("agent_start"), bridgeEvent("turn_start"), bridgeEvent("agent_settled")]),
			stdoutChunks: [{ delayMs: 10, text: settledStdout("continuation response", [bridgeEvent("agent_settled")]) }],
		},
		expect: {
			exitCode: 0,
			spawns: 1,
			error: false,
			kills: ["SIGTERM"],
			lastContent: [{ type: "text", text: "continuation response" }],
			transcript: { '"type":"settled_shutdown_skipped"': true, '"reason":"agent_active"': true },
		},
	},
	{
		label: "settled: one settlement after several low-level agent runs is accepted",
		timeoutMs: 100,
		settledGraceMs: 1,
		mock: {
			closeOnSignal: "SIGTERM",
			stdout: bridgeStdout([
				bridgeEvent("agent_start"),
				bridgeEvent("agent_end", { content: [{ type: "text", text: "retryable response" }] }),
				bridgeEvent("agent_start"),
				bridgeEvent("message_end", {
					message: { role: "assistant", content: [{ type: "text", text: "final response" }], usage: { input: 1, output: 1, totalTokens: 2 }, stopReason: "stop" },
				}),
				bridgeEvent("agent_end", { content: [{ type: "text", text: "final response" }] }),
				bridgeEvent("agent_settled"),
			]),
		},
		expect: {
			exitCode: 0,
			spawns: 1,
			error: false,
			kills: ["SIGTERM"],
			lastContent: [{ type: "text", text: "final response" }],
			transcript: { '"type":"settled_shutdown_skipped"': false },
		},
	},
	{
		label: "settled: a valid settlement owns the shutdown ahead of the task timeout",
		timeoutMs: 1,
		settledGraceMs: 5,
		killGraceMs: 5,
		mock: { closeOnSignal: "SIGKILL", stdout: settledStdout("settled before timeout", [bridgeEvent("agent_settled")]) },
		expect: {
			exitCode: 0,
			spawns: 1,
			error: false,
			stopReason: "stop",
			kills: ["SIGTERM", "SIGKILL"],
			lifecycle: "completed:completed",
			transcript: { '"type":"timeout"': false },
		},
	},
	{
		label: "settled: a failed shutdown delivery keeps the later nonzero exit",
		timeoutMs: 0,
		settledGraceMs: 1,
		mock: {
			kill: (signal, _count, proc) => {
				if (signal === "SIGTERM") queueMicrotask(() => proc.emit("close", 1, null));
				return false;
			},
			stdout: settledStdout("semantic response before failed shutdown", [bridgeEvent("agent_settled")]),
		},
		expect: {
			exitCode: 1,
			spawns: 1,
			error: false,
			kills: ["SIGTERM"],
			lifecycle: "failed:failed:stop",
			transcript: { '"semanticCompletion":"agent_settled"': false },
		},
	},
	{
		label: "settled: a delivered signal does not mask an unrelated nonzero exit",
		timeoutMs: 0,
		settledGraceMs: 1,
		mock: {
			kill: (signal, _count, proc) => {
				if (signal === "SIGTERM") queueMicrotask(() => proc.emit("close", 1, null));
				return true;
			},
			stdout: settledAfterEnd("done"),
		},
		expect: {
			exitCode: 1,
			spawns: 1,
			error: false,
			kills: ["SIGTERM"],
			lifecycle: "failed:failed:no-reason",
			transcript: { '"semanticCompletion":"agent_settled"': false },
		},
	},
	{
		label: "settled: SIGTERM and SIGKILL both refused resolve as a bounded failure",
		timeoutMs: 0,
		settledGraceMs: 1,
		killGraceMs: 1,
		mock: { kill: () => false, stdout: settledAfterEnd("done") },
		expect: {
			exitCode: 1,
			spawns: 1,
			error: true,
			kills: ["SIGTERM", "SIGKILL"],
			errorMessage: { "Settled shutdown failed": true },
			transcript: { '"type":"settled_shutdown_failed"': true },
		},
	},
	{
		label: "settled: delivered signals with no close resolve as a bounded failure",
		timeoutMs: 0,
		settledGraceMs: 1,
		killGraceMs: 1,
		mock: { kill: () => true, stdout: settledAfterEnd("done") },
		expect: {
			exitCode: 1,
			spawns: 1,
			error: true,
			kills: ["SIGTERM", "SIGKILL"],
			errorMessage: { "did not emit close within": true, "after SIGKILL": true },
			transcript: { '"type":"settled_shutdown_failed"': true },
		},
	},
	{
		label: "settled: a terminal resolution clears the pending kill escalation",
		timeoutMs: 0,
		settledGraceMs: 1,
		killGraceMs: 5,
		mock: {
			kill: (signal, _count, proc) => {
				if (signal === "SIGTERM") queueMicrotask(() => proc.emit("error", new Error("mock process error")));
				return true;
			},
			stdout: settledAfterEnd("done"),
		},
		observeAfterMs: 10,
		expect: { exitCode: 1, spawns: 1, error: true, kills: ["SIGTERM"] },
	},
];

function presence(text: string, expected: Presence): Presence {
	return Object.fromEntries(Object.keys(expected).map((fragment) => [fragment, text.includes(fragment)]));
}

test("bg one-shot lifecycle: each staged lifecycle reaches its outcome", async () => {
	for (const row of lifecycleRows) {
		const cwd = tempRuntime();
		writeSettings(cwd, { bgTaskTimeoutMs: row.timeoutMs });
		const events: Array<{ name: string; payload: any }> = [];
		if (row.settledGraceMs !== undefined) setBgSettledShutdownGraceMsForTests(row.settledGraceMs);
		if (row.killGraceMs !== undefined) setBgTimeoutKillGraceMsForTests(row.killGraceMs);
		const calls = installLifecycleMockSpawn(row.mock);
		try {
			const result = await runSingleAgent(
				cwd,
				tempRuntime(),
				[testAgent()],
				"reviewer-test",
				row.label,
				undefined,
				undefined,
				undefined,
				undefined,
				mockPiEvents(events),
				undefined,
				undefined,
				makeDetails,
			);
			if (row.observeAfterMs !== undefined) await new Promise((resolve) => setTimeout(resolve, row.observeAfterMs));
			const failed = events.find((event) => event.name === "subagents:failed");
			const completed = events.find((event) => event.name === "subagents:completed");
			const emitted = [
				...(completed ? [`completed:${completed.payload.status}`] : []),
				...(failed ? [`failed:${failed.payload.status}:${failed.payload.reason ?? "no-reason"}`] : []),
			];
			const lifecycle = emitted.length > 0 ? emitted.join(" ") : "none";
			const observed: LifecycleOutcome = { exitCode: result.exitCode, spawns: calls.length, error: result.errorMessage !== undefined, kills: calls[0]?.kills ?? [] };
			if ("stopReason" in row.expect) observed.stopReason = result.stopReason;
			if ("lifecycle" in row.expect) observed.lifecycle = lifecycle;
			if ("lastContent" in row.expect) observed.lastContent = result.messages.at(-1)?.content;
			if (row.expect.transcript) observed.transcript = presence(readTranscript(result), row.expect.transcript);
			if (row.expect.errorMessage) observed.errorMessage = presence(result.errorMessage ?? "", row.expect.errorMessage);
			if (row.expect.failedEventError) observed.failedEventError = presence(failed?.payload.error ?? "", row.expect.failedEventError);
			assert.deepEqual(observed, row.expect, row.label);
		} finally {
			setBgSettledShutdownGraceMsForTests();
			setBgTimeoutKillGraceMsForTests();
			setSingleAgentSpawnForTests();
		}
	}
});

test("bg one-shot timeout still terminates and resolves when its update callback throws", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 5 });
	setBgTimeoutKillGraceMsForTests(1);
	const calls = installLifecycleMockSpawn();
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"throw from timeout update",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			() => { throw new Error("update callback exploded"); },
			makeDetails,
		);
		assert.equal(result.exitCode, 1);
		assert.equal(result.stopReason, "unresponsive_timeout");
		assert.deepEqual(calls[0]?.kills, ["SIGTERM", "SIGKILL"]);
		assert.match(result.errorMessage ?? "", /Timeout update callback failed: Error: update callback exploded/);
	} finally {
		setSingleAgentSpawnForTests();
		setBgTimeoutKillGraceMsForTests();
	}
});

test("bg one-shot timeout uses detached process-group termination when pid is available", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 5 });
	setBgTimeoutKillGraceMsForTests(1);
	const calls = installLifecycleMockSpawn({ pid: 12345 });
	const processKillCalls: Array<{ pid: number; signal?: string | number }> = [];
	const previousKill = process.kill;
	(process as unknown as { kill: typeof process.kill }).kill = ((pid: number, signal?: string | number) => {
		processKillCalls.push({ pid, signal });
		return true;
	}) as typeof process.kill;
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"hang with pid",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.stopReason, "unresponsive_timeout");
		assert.equal(calls[0]?.detached, process.platform !== "win32");
		assert.deepEqual(calls[0]?.kills, []);
		assert.deepEqual(processKillCalls, [
			{ pid: -12345, signal: "SIGTERM" },
			{ pid: -12345, signal: "SIGKILL" },
		]);
		assert.match(result.errorMessage ?? "", /SIGTERM process-group delivered/);
		assert.match(result.errorMessage ?? "", /SIGKILL process-group delivered/);
	} finally {
		(process as unknown as { kill: typeof process.kill }).kill = previousKill;
		setSingleAgentSpawnForTests();
		setBgTimeoutKillGraceMsForTests();
	}
});

test("bg one-shot timeout falls back to child kill when process-group signal fails", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 5 });
	setBgTimeoutKillGraceMsForTests(1);
	const calls = installLifecycleMockSpawn({ pid: 12345 });
	const previousKill = process.kill;
	(process as unknown as { kill: typeof process.kill }).kill = ((pid: number, signal?: string | number) => {
		throw new Error(`cannot signal ${pid} with ${String(signal)}`);
	}) as typeof process.kill;
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"hang with failed process group",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.stopReason, "unresponsive_timeout");
		assert.equal(calls[0]?.detached, process.platform !== "win32");
		assert.deepEqual(calls[0]?.kills, ["SIGTERM", "SIGKILL"]);
		assert.match(result.errorMessage ?? "", /SIGTERM process-group failed: .*cannot signal -12345/);
		assert.match(result.errorMessage ?? "", /SIGTERM child delivered/);
		assert.match(result.errorMessage ?? "", /SIGKILL process-group failed: .*cannot signal -12345/);
		assert.match(result.errorMessage ?? "", /SIGKILL child delivered/);
	} finally {
		(process as unknown as { kill: typeof process.kill }).kill = previousKill;
		setSingleAgentSpawnForTests();
		setBgTimeoutKillGraceMsForTests();
	}
});

test("bg one-shot settled cancellation re-arms at the ORIGINAL deadline, not a fresh window", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 300 });
	// Grace far beyond the test window: settlement suspends the timeout but
	// never delivers its SIGTERM, so the only kill can come from the timeout.
	setBgSettledShutdownGraceMsForTests(10_000);
	setBgTimeoutKillGraceMsForTests(1);
	// Margins are deliberately wide (>=140ms between every ordered pair) so
	// only an extreme event-loop stall could reorder them: the immediate
	// re-armed timeout at ~320ms races the 460ms close, and the 460ms close
	// must land before a fresh-window mutant's 620ms deadline.
	const calls = installLifecycleMockSpawn({
		closeAfterMs: 460,
		closeOnSignal: "SIGTERM",
		stdout: bridgeStdout([
			bridgeEvent("agent_start"),
			bridgeEvent("agent_end", { content: [{ type: "text", text: "first response" }] }),
		]),
		stdoutChunks: [
			{ delayMs: 10, text: bridgeStdout([bridgeEvent("agent_settled")]) },
			{ delayMs: 320, text: bridgeStdout([bridgeEvent("agent_start"), bridgeEvent("turn_start")]) },
		],
	});
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"cancel settled shutdown after the original deadline passed",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		// Settlement at 10ms suspends the 300ms deadline; the continuation at
		// 320ms re-arms AGAINST THAT ORIGINAL deadline, which has already
		// passed, so the timeout fires immediately — before the 460ms close.
		// A fresh-window re-arm (320ms + 300ms = 620ms) would let close(0) at
		// 460ms win and report success.
		assert.equal(result.exitCode, 1);
		assert.equal(result.stopReason, "unresponsive_timeout");
		assert.deepEqual(calls[0]?.kills, ["SIGTERM"]);
	} finally {
		setBgSettledShutdownGraceMsForTests();
		setBgTimeoutKillGraceMsForTests();
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot abort during settled grace clears the pending settled SIGTERM", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 0 });
	setBgSettledShutdownGraceMsForTests(60);
	setBgTimeoutKillGraceMsForTests(10_000);
	const controller = new AbortController();
	const calls = installLifecycleMockSpawn({
		closeAfterMs: 100,
		stdout: bridgeStdout([
			bridgeEvent("agent_start"),
			bridgeEvent("agent_end", { content: [{ type: "text", text: "done" }] }),
		]),
		stdoutChunks: [
			{ delayMs: 5, text: bridgeStdout([bridgeEvent("agent_settled")]) },
		],
	});
	setTimeout(() => controller.abort(), 25);
	try {
		// The abort at 25ms lands inside the settled grace window (armed at
		// 5ms, SIGTERM due at 65ms). Abort must take over the lifecycle: the
		// run rejects as aborted — never a settled semantic completion — and
		// exactly one SIGTERM is delivered by the abort path; a surviving
		// settled grace timer would deliver a second one at 65ms before the
		// 100ms close.
		await assert.rejects(
			runSingleAgent(
				cwd,
				tempRuntime(),
				[testAgent()],
				"reviewer-test",
				"abort while a settled shutdown is pending",
				undefined,
				undefined,
				undefined,
				undefined,
				mockPiEvents([]),
				controller.signal,
				undefined,
				makeDetails,
			),
			/Agent was aborted/,
		);
		assert.deepEqual(calls[0]?.kills, ["SIGTERM"]);
	} finally {
		setBgSettledShutdownGraceMsForTests();
		setBgTimeoutKillGraceMsForTests();
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot activity emitted after delivered settled SIGTERM cannot cancel shutdown", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 0 });
	setBgSettledShutdownGraceMsForTests(1);
	setBgTimeoutKillGraceMsForTests(500);
	const childPath = join(cwd, "sigterm-disposal-child.mjs");
	writeFileSync(childPath, `
const emit = (event, data = {}, callback) => process.stdout.write(JSON.stringify({ type: "event", event, data }) + "\\n", callback);
process.on("SIGTERM", () => {
	emit("agent_start");
	emit("turn_start");
	emit("agent_end", { content: [{ type: "text", text: "signal disposal" }] });
	emit("agent_settled", {}, () => {
		clearInterval(keepalive);
		process.exitCode = 143;
	});
});
emit("agent_start");
emit("agent_end", { content: [{ type: "text", text: "done" }] });
emit("agent_settled");
const keepalive = setInterval(() => {}, 1000);
`, "utf8");
	let child: ReturnType<typeof spawnChild> | undefined;
	setSingleAgentSpawnForTests(((_command: string, _args: string[], spawnOptions?: { detached?: boolean }) => {
		child = spawnChild(process.execPath, [childPath], {
			cwd,
			detached: spawnOptions?.detached,
			stdio: ["ignore", "pipe", "pipe"],
		});
		return child;
	}) as any);
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"ignore disposal activity after settled SIGTERM",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.exitCode, 0);
		assert.equal(result.messages.length, 0);
		const content = readTranscript(result);
		assert.match(content, /"type":"settled_shutdown_cancellation_skipped"/);
		assert.match(content, /"reason":"signal_delivered"/);
		assert.match(content, /"type":"settled_shutdown_skipped"/);
		assert.doesNotMatch(content, /"type":"settled_shutdown_cancelled"/);
		assert.match(content, /"semanticCompletion":"agent_settled"/);
	} finally {
		if (child?.exitCode === null && child.pid) {
			try {
				if (process.platform === "win32") child.kill("SIGKILL");
				else process.kill(-child.pid, "SIGKILL");
			} catch {
				child.kill("SIGKILL");
			}
		}
		setBgSettledShutdownGraceMsForTests();
		setBgTimeoutKillGraceMsForTests();
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot normal exits before active timeout keep original lifecycle", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 250 });
	const cases: Array<{ code?: number | null; expectedEvent: string; expectedExitCode: number; expectedStatus: string; label: string; signal?: string }> = [
		{ code: 0, expectedEvent: "subagents:completed", expectedExitCode: 0, expectedStatus: "completed", label: "success" },
		{ code: 2, expectedEvent: "subagents:failed", expectedExitCode: 2, expectedStatus: "failed", label: "nonzero" },
		{ code: null, expectedEvent: "subagents:failed", expectedExitCode: 1, expectedStatus: "failed", label: "signal", signal: "SIGTERM" },
	];
	for (const item of cases) {
		const events: Array<{ name: string; payload: any }> = [];
		const calls = installMockSpawn([{ code: item.code, delayMs: 5, signal: item.signal }]);
		try {
			const result = await runSingleAgent(
				cwd,
				tempRuntime(),
				[testAgent()],
				"reviewer-test",
				`finish before timeout ${item.label}`,
				undefined,
				undefined,
				undefined,
				undefined,
				mockPiEvents(events),
				undefined,
				undefined,
				makeDetails,
			);
			assert.equal(result.exitCode, item.expectedExitCode, item.label);
			assert.notEqual(result.stopReason, "unresponsive_timeout", item.label);
			assert.deepEqual(calls[0]?.kills, [], item.label);
			const lifecycle = events.find((event) => event.name === item.expectedEvent);
			assert.equal(lifecycle?.payload.status, item.expectedStatus, item.label);
			assert.notEqual(lifecycle?.payload.reason, "unresponsive_timeout", item.label);
		} finally {
			setSingleAgentSpawnForTests();
		}
	}
});
