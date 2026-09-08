import { expect, test } from "bun:test";
import { runSpawnFixture } from "./fixtures/spawn-child-runner.js";

const unit = "kendex-pi-bg-bg-1-1700000000000.service";
const term = { file: "systemctl", args: ["--user", "stop", "--no-block", unit] };
const kill = { file: "systemctl", args: ["--user", "kill", "--signal=SIGKILL", unit] };
const termSignal = { pid: -4242, signal: "SIGTERM" };
const killSignal = { pid: -4242, signal: "SIGKILL" };
const interval = { kind: "interval", ms: 30_000 };
const timeout = { kind: "timeout", ms: 5_000 };
const running = { id: "bg-1", pid: 4242, status: "running", reason: null, exitCode: null, exitNotified: false };

const rows = [
	{ name: "tool unit stop succeeds without wrapper signals", resource: true, caller: "tool", stopFails: false, killFails: false, signalGone: false, afterStatus: "running", reason: "extension-stop", finalStatus: "stopped", escalate: true, failureLogValues: 0 },
	{ name: "tool unit stop failure returns an error without fallback signals", resource: true, caller: "tool", stopFails: true, killFails: true, signalGone: false, afterStatus: "running", reason: null, finalStatus: "running", escalate: false, failureLogValues: 1 },
	{ name: "tool without resource control signals the owned process group", resource: false, caller: "tool", stopFails: false, killFails: false, signalGone: false, afterStatus: "running", reason: "extension-stop", finalStatus: "stopped", escalate: true, failureLogValues: 0 },
	{ name: "tool with a gone process finalizes without an escalation timer", resource: false, caller: "tool", stopFails: false, killFails: false, signalGone: true, afterStatus: "stopped", reason: "extension-stop", finalStatus: "stopped", escalate: false, failureLogValues: 0 },
	{ name: "shutdown unit stop succeeds without wrapper signals", resource: true, caller: "shutdown", stopFails: false, killFails: false, signalGone: false, afterStatus: "stopped", reason: "session-shutdown", finalStatus: "stopped", escalate: false, failureLogValues: 0 },
	{ name: "shutdown failed unit stops preserve running state without fallback", resource: true, caller: "shutdown", stopFails: true, killFails: true, signalGone: false, afterStatus: "running", reason: null, finalStatus: "running", escalate: false, failureLogValues: 3 },
	{ name: "shutdown successful TERM still stops after failed KILL", resource: true, caller: "shutdown", stopFails: false, killFails: true, signalGone: false, afterStatus: "stopped", reason: "session-shutdown", finalStatus: "stopped", escalate: false, failureLogValues: 1 },
	{ name: "shutdown successful KILL stops after failed TERM", resource: true, caller: "shutdown", stopFails: true, killFails: false, signalGone: false, afterStatus: "stopped", reason: "session-shutdown", finalStatus: "stopped", escalate: false, failureLogValues: 1 },
	{ name: "shutdown without resource control signals the owned group", resource: false, caller: "shutdown", stopFails: false, killFails: false, signalGone: false, afterStatus: "stopped", reason: "session-shutdown", finalStatus: "stopped", escalate: false, failureLogValues: 0 },
	{ name: "shutdown with a gone process refuses stopped state", resource: false, caller: "shutdown", stopFails: false, killFails: false, signalGone: true, afterStatus: "running", reason: null, finalStatus: "running", escalate: false, failureLogValues: 0 },
];

// systemd-run is a Linux execution path. The child intercepts its native boundary.
test.skipIf(process.platform !== "linux")("registered resource stop and shutdown rows", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "resource stop table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const result = runSpawnFixture("spawn-extension.ts", { mode: "stop", ...row }) as Record<string, unknown>;
		const shutdown = row.caller === "shutdown";
		const outcome = result.outcome as { kind: string; action?: string; message?: string };
		const afterState = { ...running, status: row.afterStatus, reason: row.reason };
		const afterSignals = row.resource ? [] : shutdown ? [termSignal, killSignal] : [termSignal];
		const allSignals = row.resource ? [] : row.escalate || shutdown ? [termSignal, killSignal] : [termSignal];
		const afterUnits = row.resource ? shutdown ? [term, kill] : [term] : [];
		const allUnits = row.resource ? row.escalate || shutdown ? [term, kill] : [term] : [];
		expect({ before: result.before, outcome: { kind: outcome.kind, action: outcome.action, failureValue: outcome.message?.includes("fixture_systemctl.exit=1") ?? false }, after: result.after, escalated: result.escalated, final: result.final, failureLogValues: (result.log as string).split("fixture_systemctl.exit=1").length - 1, stoppedTimers: result.stoppedTimers, stopCalls: result.stopCalls, signals: result.signals, childSignals: result.childSignals, timerEvents: result.timerEvents, remainingTimers: result.remainingTimers, unexpected: result.unexpected }, row.name).toStrictEqual({
			before: running,
			outcome: { kind: shutdown ? "shutdown" : row.stopFails ? "error" : "tool", action: shutdown || row.stopFails ? undefined : "stop", failureValue: !shutdown && row.stopFails },
			after: { state: afterState, timers: shutdown ? [] : row.escalate ? [interval, timeout] : [interval], signals: afterSignals, childSignals: [], unitCalls: afterUnits },
			escalated: row.escalate ? { state: afterState, signals: allSignals, unitCalls: allUnits } : undefined,
			final: { ...running, status: row.finalStatus, reason: row.reason },
			failureLogValues: row.failureLogValues, stoppedTimers: shutdown ? [] : [interval], stopCalls: allUnits, signals: allSignals, childSignals: [],
			timerEvents: [{ action: "set", ...interval }, ...(row.escalate ? [{ action: "set", ...timeout }, { action: "clear", ...timeout }] : []), { action: "clear", ...interval }],
			remainingTimers: [], unexpected: [],
		});
	}
});
