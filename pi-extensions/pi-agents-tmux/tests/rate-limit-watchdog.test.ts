// The pane rate-limit watchdog as a state machine on an injected clock and
// scheduler: each row is a script of message_end events, fires and cancels on
// one pane, read back after every step as one line.

import assert from "node:assert/strict";
import test from "node:test";
import { buildSubagentActivity } from "../extensions/subagent/activity.js";
import { RATE_LIMIT_RESET_MARGIN_MS, RATE_LIMIT_STEER_MESSAGE } from "../extensions/subagent/rate-limit-decision.js";
import { normalizeQuotaSnapshot } from "../extensions/subagent/rate-limit-quota-normalize.js";
import { createSubagentRateLimitWatchdog, type RateLimitOutcome, type SubagentRateLimitWatchdog, type SubagentRateLimitWatchdogDeps } from "../extensions/subagent/rate-limit-watchdog.js";

const RATE_LIMITED = {
	message: {
		api: "claude-bridge",
		content: [{ text: "API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited", type: "text" }],
		errorMessage: "Claude Code returned an error result: API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited",
		role: "assistant",
		stopReason: "error",
	},
	type: "message_end",
};
const HEALTHY = { message: { content: [{ text: "Done.", type: "text" }], role: "assistant", stopReason: "stop" }, type: "message_end" };
const SESSION_LIMIT = {
	message: { api: "claude-bridge", errorMessage: "Claude Code returned an error result: You've hit your session limit · resets 7:50pm (America/Los_Angeles)", role: "assistant", stopReason: "error" },
	type: "message_end",
};
const STEER_ECHO = { message: { content: [{ text: RATE_LIMIT_STEER_MESSAGE, type: "text" }], role: "user" }, type: "message_end" };
const NO_STOP_REASON = { message: { content: [{ text: "Still working.", type: "text" }], role: "assistant" }, type: "message_end" };
const ERROR_WITHOUT_PROSE = { message: { content: [{ text: "Tool output attached below.", type: "text" }], errorMessage: "Tool execution failed", role: "assistant", stopReason: "error" }, type: "message_end" };

const SESSION_LIMIT_NOW = Date.UTC(2026, 4, 31, 1, 54, 56);
const SESSION_LIMIT_RESET_AT = Date.UTC(2026, 4, 31, 2, 50, 0) + RATE_LIMIT_RESET_MARGIN_MS;
const USAGE_RESET_AT = Date.UTC(2026, 4, 31, 3, 30, 0) + RATE_LIMIT_RESET_MARGIN_MS;
const claudeUsage = () => normalizeQuotaSnapshot("claude", "usage-endpoint", { five_hour: { utilization: 1, resets_at: new Date(USAGE_RESET_AT - RATE_LIMIT_RESET_MARGIN_MS).toISOString() } }, SESSION_LIMIT_NOW);

type Timer = { cancelled: boolean; delayMs: number; fn: () => void };

// The injected world: a clock, a scheduler that records timers, and sinks for
// steers, activity, exhaustion callbacks, warnings and the persisted mirror.
function world(overrides: Partial<SubagentRateLimitWatchdogDeps> = {}) {
	const timers: Timer[] = [];
	const steers: string[] = [];
	const activity: Array<{ event: string; payload: Record<string, unknown> }> = [];
	const exhausted: string[] = [];
	const warnings: string[] = [];
	const persisted: Array<number | null> = [];
	const clock = { value: 0 };
	const deps: SubagentRateLimitWatchdogDeps = {
		backoffLadderSec: () => [1, 2, 4],
		emitActivity: (event, payload) => activity.push({ event, payload }),
		isEnabled: () => true,
		logWarn: (message) => warnings.push(message),
		maxAttempts: () => 3,
		now: () => clock.value,
		onExhausted: (paneId, attempt, reason) => exhausted.push(`${paneId}#${attempt}:${reason}`),
		persistRetryState: (_paneId, at) => persisted.push(at),
		scheduleAfter: (delayMs, fn) => {
			const entry = { cancelled: false, delayMs, fn };
			timers.push(entry);
			return { cancel: () => { entry.cancelled = true; } };
		},
		sendUserMessage: (message) => steers.push(message),
		...overrides,
	};
	return { activity, clock, deps, exhausted, persisted, seen: { activity: 0, warnings: 0 }, steers, timers, warnings, watchdog: createSubagentRateLimitWatchdog(deps) };
}
type World = ReturnType<typeof world>;

// Each warning by the failure it names; an unknown one prints whole.
function warnTag(line: string): string {
	for (const [needle, tag] of [["retry-state persist failed", "persist-failed"], ["steer dispatch failed", "steer-failed"], ["activity emit failed", "emit-failed"], ["usage endpoint lookup failed", "usage-failed"], ["onExhausted handler failed", "exhausted-failed"]] as const) {
		if (line.includes(needle)) return tag;
	}
	return JSON.stringify(line);
}

function activityTag(entry: { event: string; payload: Record<string, unknown> }): string {
	const p = entry.payload;
	const name = entry.event.replace(/^subagents:rate_limit(ed|_)?/, "") || "limited";
	if (name === "skipped") return `skipped(${p.reason})`;
	if (name === "limited" || name === "retry") return `${name}(a=${p.attempt},next=${p.next_retry_at},src=${p.reset_source ?? "-"}${p.degraded_reset_source ? ",degraded" : ""})`;
	return `${name}(a=${p.attempt})`;
}

function outcomeTag(outcome: RateLimitOutcome): string {
	switch (outcome.kind) {
		case "scheduled-retry": return `retry#${outcome.attempt}@${outcome.at}:${outcome.resetSource ?? "-"}${outcome.degradedResetSource ? "(degraded)" : ""}`;
		case "exhausted": return `exhausted#${outcome.attempt}`;
		case "resolved": return `resolved#${outcome.previousAttempt}`;
		case "not-rate-limited": return `skip:${outcome.reason}`;
		case "skipped-disabled": return "disabled";
	}
}

// One step's line: what the step returned, then the pane read back (awaiting,
// timers armed/cancelled and the last delay, steers sent and whether they were
// the canonical text, the last persisted mirror value, exhaustion callbacks),
// then the activity and warnings the step added.
type Step = { at?: number; do: (w: World) => string };
function runScript(w: World, steps: Step[]): string {
	const lines: string[] = [];
	for (const step of steps) {
		if (step.at !== undefined) w.clock.value = step.at;
		const head = step.do(w);
		const added = w.activity.slice(w.seen.activity).map(activityTag);
		const warned = w.warnings.slice(w.seen.warnings).map(warnTag);
		w.seen.activity = w.activity.length;
		w.seen.warnings = w.warnings.length;
		const steer = w.steers.length ? (w.steers.every((s) => s === RATE_LIMIT_STEER_MESSAGE) ? `${w.steers.length}/canonical` : `${w.steers.length}/other`) : "0";
		const last = w.timers[w.timers.length - 1];
		lines.push(`${head} await=${w.watchdog.isAwaitingRetry("rust")} timers=${w.timers.length}/${w.timers.filter((t) => t.cancelled).length}${last ? ` delay=${last.delayMs}` : ""} steers=${steer} persist=${w.persisted.length ? w.persisted[w.persisted.length - 1] : "-"} exhausted=${w.exhausted.length ? w.exhausted.join(";") : "-"} +[${added.join(",")}]${warned.length ? ` warn=[${warned.join(",")}]` : ""}`);
	}
	return lines.join("\n");
}

const msg = (event: unknown) => (w: World) => outcomeTag(w.watchdog.onMessageEnd(event, "rust", "rust", "task-1"));
const fire = (w: World) => `fire=${w.watchdog.fireRetryNow("rust")}`;
const cancel = (w: World) => `cancel=${w.watchdog.cancel("rust")}`;
const fireTimer = (index: number) => (w: World) => { w.timers[index]!.fn(); return `timer[${index}]-fired`; };

const ARMED_1 = "retry#1@2000:backoff-only(degraded) await=true timers=1/0 delay=1000 steers=0 persist=2000 exhausted=- +[limited(a=1,next=2000,src=backoff-only,degraded)]";

// label | deps overrides | the script | expect one line per step
const rows: Array<[string, Partial<SubagentRateLimitWatchdogDeps>, Step[], string]> = [
	["the first detection arms the first ladder step and mirrors the retry time", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }], ARMED_1],
	["the fired steer is the canonical text and clears the mirror", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }], [
		ARMED_1,
		"fire=true await=false timers=1/0 delay=1000 steers=1/canonical persist=null exhausted=- +[]",
	].join("\n")],
	["a second detection after the steer climbs the ladder", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }, { at: 5_000, do: msg(RATE_LIMITED) }], [
		ARMED_1,
		"fire=true await=false timers=1/0 delay=1000 steers=1/canonical persist=null exhausted=- +[]",
		"retry#2@7000:backoff-only(degraded) await=true timers=2/0 delay=2000 steers=1/canonical persist=7000 exhausted=- +[retry(a=2,next=7000,src=backoff-only,degraded)]",
	].join("\n")],
	["a detection while a retry is pending re-arms on the latest decision", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { at: 1_500, do: msg(RATE_LIMITED) }], [
		ARMED_1,
		"retry#2@3500:backoff-only(degraded) await=true timers=2/1 delay=2000 steers=0 persist=3500 exhausted=- +[retry(a=2,next=3500,src=backoff-only,degraded)]",
	].join("\n")],
	["the fourth detection exhausts the three attempts and calls the handler", {}, [
		{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }, { do: msg(RATE_LIMITED) }, { do: fire }, { do: msg(RATE_LIMITED) }, { do: fire }, { do: msg(RATE_LIMITED) },
	], [
		ARMED_1,
		"fire=true await=false timers=1/0 delay=1000 steers=1/canonical persist=null exhausted=- +[]",
		"retry#2@3000:backoff-only(degraded) await=true timers=2/0 delay=2000 steers=1/canonical persist=3000 exhausted=- +[retry(a=2,next=3000,src=backoff-only,degraded)]",
		"fire=true await=false timers=2/0 delay=2000 steers=2/canonical persist=null exhausted=- +[]",
		"retry#3@5000:backoff-only(degraded) await=true timers=3/0 delay=4000 steers=2/canonical persist=5000 exhausted=- +[retry(a=3,next=5000,src=backoff-only,degraded)]",
		"fire=true await=false timers=3/0 delay=4000 steers=3/canonical persist=null exhausted=- +[]",
		"exhausted#3 await=false timers=3/0 delay=4000 steers=3/canonical persist=null exhausted=rust#3:rate-limit retries exhausted after 3 attempts +[exhausted(a=3)]",
	].join("\n")],
	["a healthy turn after the steer resolves and resets the ladder", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }, { do: msg(HEALTHY) }, { do: msg(RATE_LIMITED) }], [
		ARMED_1,
		"fire=true await=false timers=1/0 delay=1000 steers=1/canonical persist=null exhausted=- +[]",
		"resolved#1 await=false timers=1/0 delay=1000 steers=1/canonical persist=null exhausted=- +[skipped(stopreason-mismatch),resolved(a=1)]",
		"retry#1@2000:backoff-only(degraded) await=true timers=2/0 delay=1000 steers=1/canonical persist=2000 exhausted=- +[limited(a=1,next=2000,src=backoff-only,degraded)]",
	].join("\n")],
	["a healthy turn before the steer cancels the timer and resolves", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: msg(HEALTHY) }, { do: fire }], [
		ARMED_1,
		"resolved#1 await=false timers=1/1 delay=1000 steers=0 persist=null exhausted=- +[skipped(stopreason-mismatch),resolved(a=1)]",
		"fire=false await=false timers=1/1 delay=1000 steers=0 persist=null exhausted=- +[]",
	].join("\n")],
	["the user-role echo of the steer neither resolves nor resets", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }, { do: msg(STEER_ECHO) }, { do: msg(RATE_LIMITED) }], [
		ARMED_1,
		"fire=true await=false timers=1/0 delay=1000 steers=1/canonical persist=null exhausted=- +[]",
		"skip:non-assistant await=false timers=1/0 delay=1000 steers=1/canonical persist=null exhausted=- +[skipped(non-assistant)]",
		"retry#2@3000:backoff-only(degraded) await=true timers=2/0 delay=2000 steers=1/canonical persist=3000 exhausted=- +[retry(a=2,next=3000,src=backoff-only,degraded)]",
	].join("\n")],
	["a healthy turn with nothing pending is only skipped", {}, [{ do: msg(HEALTHY) }], "skip:stopreason-mismatch await=false timers=0/0 steers=0 persist=- exhausted=- +[skipped(stopreason-mismatch)]"],
	["an assistant turn without a stop reason after the steer does not resolve", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }, { do: msg(NO_STOP_REASON) }, { do: msg(RATE_LIMITED) }], [
		ARMED_1,
		"fire=true await=false timers=1/0 delay=1000 steers=1/canonical persist=null exhausted=- +[]",
		"skip:no-stopreason await=false timers=1/0 delay=1000 steers=1/canonical persist=null exhausted=- +[skipped(no-stopreason)]",
		"retry#2@3000:backoff-only(degraded) await=true timers=2/0 delay=2000 steers=1/canonical persist=3000 exhausted=- +[retry(a=2,next=3000,src=backoff-only,degraded)]",
	].join("\n")],
	["an error turn without rate-limit prose after the steer does not resolve", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }, { do: msg(ERROR_WITHOUT_PROSE) }, { do: msg(RATE_LIMITED) }], [
		ARMED_1,
		"fire=true await=false timers=1/0 delay=1000 steers=1/canonical persist=null exhausted=- +[]",
		"skip:no-prose await=false timers=1/0 delay=1000 steers=1/canonical persist=null exhausted=- +[skipped(no-prose)]",
		"retry#2@3000:backoff-only(degraded) await=true timers=2/0 delay=2000 steers=1/canonical persist=3000 exhausted=- +[retry(a=2,next=3000,src=backoff-only,degraded)]",
	].join("\n")],
	["an assistant turn without a stop reason is skipped", {}, [{ do: msg(NO_STOP_REASON) }], "skip:no-stopreason await=false timers=0/0 steers=0 persist=- exhausted=- +[skipped(no-stopreason)]"],
	["an error turn without rate-limit prose is skipped", {}, [{ do: msg(ERROR_WITHOUT_PROSE) }], "skip:no-prose await=false timers=0/0 steers=0 persist=- exhausted=- +[skipped(no-prose)]"],
	["a disabled watchdog does nothing", { isEnabled: () => false }, [{ at: 1_000, do: msg(RATE_LIMITED) }], "disabled await=false timers=0/0 steers=0 persist=- exhausted=- +[]"],
	["cancel clears the pending retry, the mirror and the ladder", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: cancel }, { do: cancel }, { do: msg(RATE_LIMITED) }], [
		ARMED_1,
		"cancel=true await=false timers=1/1 delay=1000 steers=0 persist=null exhausted=- +[]",
		"cancel=false await=false timers=1/1 delay=1000 steers=0 persist=null exhausted=- +[]",
		"retry#1@2000:backoff-only(degraded) await=true timers=2/1 delay=1000 steers=0 persist=2000 exhausted=- +[limited(a=1,next=2000,src=backoff-only,degraded)]",
	].join("\n")],
	["a stale timer firing after a re-arm does not steer", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { at: 1_500, do: msg(RATE_LIMITED) }, { do: fireTimer(0) }], [
		ARMED_1,
		"retry#2@3500:backoff-only(degraded) await=true timers=2/1 delay=2000 steers=0 persist=3500 exhausted=- +[retry(a=2,next=3500,src=backoff-only,degraded)]",
		"timer[0]-fired await=true timers=2/1 delay=2000 steers=0 persist=3500 exhausted=- +[]",
	].join("\n")],
	["a throwing persist hook is warned and the retry still arms", { persistRetryState: () => { throw new Error("disk gone"); } }, [{ at: 1_000, do: msg(RATE_LIMITED) }],
		"retry#1@2000:backoff-only(degraded) await=true timers=1/0 delay=1000 steers=0 persist=- exhausted=- +[limited(a=1,next=2000,src=backoff-only,degraded)] warn=[persist-failed]"],
	["a throwing steer is warned, not thrown", { sendUserMessage: () => { throw new Error("bridge socket gone"); } }, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }], [
		ARMED_1,
		"fire=true await=false timers=1/0 delay=1000 steers=0 persist=null exhausted=- +[] warn=[steer-failed]",
	].join("\n")],
	["a throwing activity sink is warned, not thrown", { emitActivity: () => { throw new Error("broker offline"); } }, [{ at: 1_000, do: msg(RATE_LIMITED) }],
		"retry#1@2000:backoff-only(degraded) await=true timers=1/0 delay=1000 steers=0 persist=2000 exhausted=- +[] warn=[emit-failed]"],
	["a throwing exhaustion handler is warned, not thrown", { maxAttempts: () => 1, onExhausted: () => { throw new Error("outbox gone"); } }, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }, { do: msg(RATE_LIMITED) }], [
		ARMED_1,
		"fire=true await=false timers=1/0 delay=1000 steers=1/canonical persist=null exhausted=- +[]",
		"exhausted#1 await=false timers=1/0 delay=1000 steers=1/canonical persist=null exhausted=- +[exhausted(a=1)] warn=[exhausted-failed]",
	].join("\n")],
	["session-limit prose with no usage source schedules on the prose reset, degraded", { getUsageSnapshot: () => null }, [{ at: SESSION_LIMIT_NOW, do: msg(SESSION_LIMIT) }],
		`retry#1@${SESSION_LIMIT_RESET_AT}:prose-fallback(degraded) await=true timers=1/0 delay=${SESSION_LIMIT_RESET_AT - SESSION_LIMIT_NOW} steers=0 persist=${SESSION_LIMIT_RESET_AT} exhausted=- +[limited(a=1,next=${SESSION_LIMIT_RESET_AT},src=prose-fallback,degraded)]`],
	["a usage snapshot wins over the prose reset", { getUsageSnapshot: () => claudeUsage() }, [{ at: SESSION_LIMIT_NOW, do: msg(SESSION_LIMIT) }],
		`retry#1@${USAGE_RESET_AT}:usage-endpoint await=true timers=1/0 delay=${USAGE_RESET_AT - SESSION_LIMIT_NOW} steers=0 persist=${USAGE_RESET_AT} exhausted=- +[limited(a=1,next=${USAGE_RESET_AT},src=usage-endpoint)]`],
	["a Codex window carrying only a reset time still schedules on it", {
		getUsageSnapshot: () => normalizeQuotaSnapshot("codex", "usage-endpoint", { rate_limit: { primary_window: { reset_after_seconds: (USAGE_RESET_AT - RATE_LIMIT_RESET_MARGIN_MS - SESSION_LIMIT_NOW) / 1000 } } }, SESSION_LIMIT_NOW),
	}, [{ at: SESSION_LIMIT_NOW, do: msg(SESSION_LIMIT) }],
		`retry#1@${USAGE_RESET_AT}:usage-endpoint await=true timers=1/0 delay=${USAGE_RESET_AT - SESSION_LIMIT_NOW} steers=0 persist=${USAGE_RESET_AT} exhausted=- +[limited(a=1,next=${USAGE_RESET_AT},src=usage-endpoint)]`],
	["a failing usage source is warned with its secret redacted and the prose reset stands", {
		getUsageSnapshot: () => ({ provider: "claude", reason: "http-401 bearer sk-ant-oauth-secret-token-warning-123456789", resetSource: "usage-endpoint", source: "quota-source-error", status: 401 }),
	}, [{ at: SESSION_LIMIT_NOW, do: msg(SESSION_LIMIT) }, { do: (w) => `redacted=${!w.warnings.some((line) => line.includes("secret-token")) && w.warnings.some((line) => line.includes("http-401"))}` }], [
		`retry#1@${SESSION_LIMIT_RESET_AT}:prose-fallback(degraded) await=true timers=1/0 delay=${SESSION_LIMIT_RESET_AT - SESSION_LIMIT_NOW} steers=0 persist=${SESSION_LIMIT_RESET_AT} exhausted=- +[limited(a=1,next=${SESSION_LIMIT_RESET_AT},src=prose-fallback,degraded)] warn=[usage-failed]`,
		`redacted=true await=true timers=1/0 delay=${SESSION_LIMIT_RESET_AT - SESSION_LIMIT_NOW} steers=0 persist=${SESSION_LIMIT_RESET_AT} exhausted=- +[]`,
	].join("\n")],
];

test("the pane rate-limit watchdog", () => {
	for (const [label, overrides, steps, expect] of rows) {
		assert.equal(runScript(world(overrides), steps), expect, label);
	}
});

test("a usage snapshot that arrives late re-arms the degraded prose timer before it can steer", async () => {
	let resolveSnapshot!: (value: unknown) => void;
	const pending = new Promise<unknown>((resolve) => { resolveSnapshot = resolve; });
	const w = world({ getUsageSnapshot: () => pending });
	const first = runScript(w, [{ at: SESSION_LIMIT_NOW, do: msg(SESSION_LIMIT) }]);
	resolveSnapshot(claudeUsage());
	await pending;
	await Promise.resolve();
	await Promise.resolve();
	const after = runScript(w, [{ do: fireTimer(0) }]);
	assert.equal(`${first}\n${after}`, [
		`retry#1@${SESSION_LIMIT_RESET_AT}:prose-fallback(degraded) await=true timers=1/0 delay=${SESSION_LIMIT_RESET_AT - SESSION_LIMIT_NOW} steers=0 persist=${SESSION_LIMIT_RESET_AT} exhausted=- +[limited(a=1,next=${SESSION_LIMIT_RESET_AT},src=prose-fallback,degraded)]`,
		// The re-arm happened between the two scripts, so its `retry` event
		// appears on the stale timer's line.
		`timer[0]-fired await=true timers=2/1 delay=${USAGE_RESET_AT - SESSION_LIMIT_NOW} steers=0 persist=${USAGE_RESET_AT} exhausted=- +[retry(a=1,next=${USAGE_RESET_AT},src=usage-endpoint)]`,
	].join("\n"));
});

test("a usage snapshot that arrives after the pane resolved does not re-arm it", async () => {
	let resolveSnapshot!: (value: unknown) => void;
	const pending = new Promise<unknown>((resolve) => { resolveSnapshot = resolve; });
	const w = world({ getUsageSnapshot: () => pending });
	const before = runScript(w, [{ at: SESSION_LIMIT_NOW, do: msg(SESSION_LIMIT) }, { do: msg(HEALTHY) }]);
	resolveSnapshot(claudeUsage());
	await pending;
	await Promise.resolve();
	await Promise.resolve();
	const after = runScript(w, [{ do: (w) => "settled" }]);
	assert.equal(`${before}\n${after}`, [
		`retry#1@${SESSION_LIMIT_RESET_AT}:prose-fallback(degraded) await=true timers=1/0 delay=${SESSION_LIMIT_RESET_AT - SESSION_LIMIT_NOW} steers=0 persist=${SESSION_LIMIT_RESET_AT} exhausted=- +[limited(a=1,next=${SESSION_LIMIT_RESET_AT},src=prose-fallback,degraded)]`,
		`resolved#1 await=false timers=1/1 delay=${SESSION_LIMIT_RESET_AT - SESSION_LIMIT_NOW} steers=0 persist=null exhausted=- +[skipped(stopreason-mismatch),resolved(a=1)]`,
		`settled await=false timers=1/1 delay=${SESSION_LIMIT_RESET_AT - SESSION_LIMIT_NOW} steers=0 persist=null exhausted=- +[]`,
	].join("\n"));
});

test("an async steer rejection is warned with its cause", async () => {
	const w = world({ sendUserMessage: () => Promise.reject(new Error("agent still streaming")) });
	runScript(w, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }]);
	await Promise.resolve();
	await Promise.resolve();
	assert.equal(w.warnings.map((line) => `${warnTag(line)}:${line.includes("agent still streaming")}`).join(","), "steer-failed:true");
});

test("the skipped broker event renders as noisy debug activity", () => {
	const record = buildSubagentActivity("subagents:rate_limit_skipped", { agent: "rust", paneId: "%41", reason: "no-prose", taskId: "task-1" }) as any;
	assert.equal(
		`type=${record.type} importance=${record.importance} severity=${record.severity} source=${record.source} agent=${record.refs?.agent} task=${record.refs?.task_id} pane=${record.details?.pane_id} reason=${record.details?.reason}`,
		"type=agent.rate_limit_skipped importance=noisy severity=debug source=pi-agents agent=rust task=task-1 pane=%41 reason=no-prose",
	);
});
