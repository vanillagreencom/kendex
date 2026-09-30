import { expect, test } from "bun:test";
import { LOG_FLUSH_DELAY_MS, LOG_WRITE_STALL_MS } from "../extensions/log-writer.js";
import { runSpawnFixture, SPAWN_FIXTURE_TIMEOUT_MS } from "./fixtures/spawn-child-runner.js";

const unit = "kendex-pi-bg-bg-1-1700000000000.service";
const term = { file: "systemctl", args: ["--user", "stop", "--no-block", unit] };
const kill = { file: "systemctl", args: ["--user", "kill", "--signal=SIGKILL", unit] };
const signalPid = process.platform === "win32" ? 4242 : -4242;
const termSignal = { pid: signalPid, signal: "SIGTERM" };
const killSignal = { pid: signalPid, signal: "SIGKILL" };
const interval = { kind: "interval", ms: 30_000 };
const timeout = { kind: "timeout", ms: 5_000 };
const flush = { kind: "timeout", ms: LOG_FLUSH_DELAY_MS };
const stall = { kind: "timeout", ms: LOG_WRITE_STALL_MS };
// The spawn-time identity read arms the windowed persist; the next lifecycle
// persist, or shutdown's, cancels it.
const persist = { kind: "timeout", ms: 1_000 };
const set = (timer: object) => ({ action: "set", ...timer });
const clear = (timer: object) => ({ action: "clear", ...timer });
// Where the row first appends a log line decides when the log flush timer is
// armed; the task's close clears its timers and then flushes its log, the
// fixture drains the log before reading it, and shutdown drains it. Each log
// write arms its stall deadline and clears it when it settles.
const timerEvents = {
	none: [set(interval), set(persist), clear(persist), clear(interval)],
	escalation: [set(interval), set(persist), clear(persist), set(timeout), set(flush), clear(timeout), set(stall), clear(flush), clear(stall), clear(interval)],
	stop: [set(interval), set(persist), clear(persist), set(flush), clear(flush), set(stall), clear(stall), clear(interval), set(flush), clear(flush), set(stall), clear(stall)],
	shutdown: [set(interval), set(persist), clear(interval), set(flush), clear(persist), clear(flush), set(stall), clear(stall)],
	shutdownQuiet: [set(interval), set(persist), clear(interval), clear(persist)],
} as const;
const running = { id: "bg-1", pid: 4242, status: "running", reason: null, exitCode: null, exitNotified: false };

const rows = [
	{ name: "tool unit stop succeeds without wrapper signals", resource: true, caller: "tool", stopFails: false, killFails: false, signalGone: false, afterStatus: "running", reason: "extension-stop", finalStatus: "stopped", escalate: true, failureLogValues: 0, logFlush: "escalation" as const },
	{ name: "tool unit stop failure returns an error without fallback signals", resource: true, caller: "tool", stopFails: true, killFails: true, signalGone: false, afterStatus: "running", reason: null, finalStatus: "running", escalate: false, failureLogValues: 1, logFlush: "stop" as const },
	{ name: "tool without resource control signals the owned task", resource: false, caller: "tool", stopFails: false, killFails: false, signalGone: false, afterStatus: "running", reason: "extension-stop", finalStatus: "stopped", escalate: true, failureLogValues: 0, logFlush: "escalation" as const },
	{ name: "tool with a gone process finalizes without an escalation timer", resource: false, caller: "tool", stopFails: false, killFails: false, signalGone: true, afterStatus: "stopped", reason: "extension-stop", finalStatus: "stopped", escalate: false, failureLogValues: 0, logFlush: "none" as const },
	{ name: "shutdown unit stop succeeds without wrapper signals", resource: true, caller: "shutdown", stopFails: false, killFails: false, signalGone: false, afterStatus: "stopped", reason: "session-shutdown", finalStatus: "stopped", escalate: false, failureLogValues: 0, logFlush: "shutdownQuiet" as const },
	{ name: "shutdown failed unit stops preserve running state without fallback", resource: true, caller: "shutdown", stopFails: true, killFails: true, signalGone: false, afterStatus: "running", reason: null, finalStatus: "running", escalate: false, failureLogValues: 3, logFlush: "shutdown" as const },
	{ name: "shutdown successful TERM still stops after failed KILL", resource: true, caller: "shutdown", stopFails: false, killFails: true, signalGone: false, afterStatus: "stopped", reason: "session-shutdown", finalStatus: "stopped", escalate: false, failureLogValues: 1, logFlush: "shutdown" as const },
	{ name: "shutdown successful KILL stops after failed TERM", resource: true, caller: "shutdown", stopFails: true, killFails: false, signalGone: false, afterStatus: "stopped", reason: "session-shutdown", finalStatus: "stopped", escalate: false, failureLogValues: 1, logFlush: "shutdown" as const },
	{ name: "shutdown without resource control signals the owned task", resource: false, caller: "shutdown", stopFails: false, killFails: false, signalGone: false, afterStatus: "stopped", reason: "session-shutdown", finalStatus: "stopped", escalate: false, failureLogValues: 0, logFlush: "shutdownQuiet" as const },
	{ name: "shutdown with a gone process refuses stopped state", resource: false, caller: "shutdown", stopFails: false, killFails: false, signalGone: true, afterStatus: "running", reason: null, finalStatus: "running", escalate: false, failureLogValues: 0, logFlush: "shutdown" as const },
];

// Only the systemd rows require Linux; native-signal rows run on every platform.
const supportedRows = rows.filter((row) => !row.resource || process.platform === "linux");

test("registered resource stop and shutdown rows", () => {
	expect.assertions(supportedRows.length + 1);
	expect(supportedRows.length, "resource stop table must contain cases").toBeGreaterThan(0);
	for (const row of supportedRows) {
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
			after: { state: afterState, timers: shutdown ? [] : row.escalate ? [interval, timeout] : row.logFlush === "stop" ? [interval, flush] : [interval], signals: afterSignals, childSignals: [], unitCalls: afterUnits },
			escalated: row.escalate ? { state: afterState, signals: allSignals, unitCalls: allUnits } : undefined,
			final: { ...running, status: row.finalStatus, reason: row.reason },
			failureLogValues: row.failureLogValues, stoppedTimers: shutdown ? [] : [interval], stopCalls: allUnits, signals: allSignals, childSignals: [],
			timerEvents: timerEvents[row.logFlush],
			remainingTimers: [], unexpected: [],
		});
	}
}, SPAWN_FIXTURE_TIMEOUT_MS * (supportedRows.length + 1));
