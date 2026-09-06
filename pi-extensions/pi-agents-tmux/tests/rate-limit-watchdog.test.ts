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
	const persisted: string[] = [];
	const clock = { value: 0 };
	const deps: SubagentRateLimitWatchdogDeps = {
		backoffLadderSec: () => [1, 2, 4],
		emitActivity: (event, payload) => activity.push({ event, payload }),
		isEnabled: () => true,
		logWarn: (message) => warnings.push(message),
		maxAttempts: () => 3,
		now: () => clock.value,
		onExhausted: (paneId, attempt, reason) => exhausted.push(`${paneId}#${attempt}:${reason}`),
		persistRetryState: (paneId, at) => persisted.push(`${paneId}=${at}`),
		scheduleAfter: (delayMs, fn) => {
			const entry = { cancelled: false, delayMs, fn };
			timers.push(entry);
			return { cancel: () => { entry.cancelled = true; } };
		},
		sendUserMessage: (message) => steers.push(message),
		...overrides,
	};
	return { activity, clock, deps, exhausted, persisted, seen: { activity: 0, persisted: 0, warnings: 0 }, steers, timers, warnings, watchdog: createSubagentRateLimitWatchdog(deps) };
}
type World = ReturnType<typeof world>;

// Each warning by the failure it names; an unknown one prints whole.
function warnTag(line: string): string {
	for (const [needle, tag] of [["retry-state persist failed", "persist-failed"], ["steer dispatch failed", "steer-failed"], ["activity emit failed", "emit-failed"], ["usage endpoint lookup failed", "usage-failed"], ["onExhausted handler failed", "exhausted-failed"]] as const) {
		if (line.includes(needle)) return tag;
	}
	return JSON.stringify(line);
}

// Each broker payload as its event, its own fields and its refs (agent, task,
// pane), which the activity tab's attribution is built from.
function activityTag(entry: { event: string; payload: Record<string, unknown> }): string {
	const p = entry.payload;
	const refs = `@${p.agent}/${p.taskId}/${p.paneId}`;
	const name = entry.event.replace(/^subagents:rate_limit(ed|_)?/, "") || "limited";
	if (name === "skipped") return `skipped(${p.reason})${refs}`;
	if (name === "limited" || name === "retry") return `${name}(a=${p.attempt},next=${p.next_retry_at},src=${p.reset_source ?? "-"}${p.degraded_reset_source ? ",degraded" : ""})${refs}`;
	if (name === "exhausted") return `exhausted(a=${p.attempt},${JSON.stringify(p.reason)})${refs}`;
	return `${name}(a=${p.attempt})${refs}`;
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
// timers armed and which were cancelled, the last delay, steers sent and
// whether they were the canonical text, exhaustion callbacks), then the mirror
// writes, activity and warnings the step added.
type Step = { at?: number; do: (w: World) => string };
function runScript(w: World, steps: Step[]): string {
	const lines: string[] = [];
	for (const step of steps) {
		if (step.at !== undefined) w.clock.value = step.at;
		const head = step.do(w);
		const added = w.activity.slice(w.seen.activity).map(activityTag);
		const warned = w.warnings.slice(w.seen.warnings).map(warnTag);
		const written = w.persisted.slice(w.seen.persisted);
		w.seen.activity = w.activity.length;
		w.seen.warnings = w.warnings.length;
		w.seen.persisted = w.persisted.length;
		const steer = w.steers.length ? (w.steers.every((s) => s === RATE_LIMIT_STEER_MESSAGE) ? `${w.steers.length}/canonical` : `${w.steers.length}/other`) : "0";
		const last = w.timers[w.timers.length - 1];
		const cancelled = w.timers.map((t, i) => (t.cancelled ? i : -1)).filter((i) => i >= 0);
		lines.push(`${head} await=${w.watchdog.isAwaitingRetry("rust")} timers=${w.timers.length} cancelled=[${cancelled.join(",")}]${last ? ` delay=${last.delayMs}` : ""} steers=${steer} exhausted=${w.exhausted.length ? w.exhausted.join(";") : "-"} persist=[${written.join(",")}] +[${added.join(",")}]${warned.length ? ` warn=[${warned.join(",")}]` : ""}`);
	}
	return lines.join("\n");
}

const msg = (event: unknown) => (w: World) => outcomeTag(w.watchdog.onMessageEnd(event, "rust", "rust", "task-1"));
const fire = (w: World) => `fire=${w.watchdog.fireRetryNow("rust")}`;
const cancel = (w: World) => `cancel=${w.watchdog.cancel("rust")}`;
const fireTimer = (index: number) => (w: World) => { w.timers[index]!.fn(); return `timer[${index}]-fired`; };

const ARMED_1 = "retry#1@2000:backoff-only(degraded) await=true timers=1 cancelled=[] delay=1000 steers=0 exhausted=- persist=[rust=2000] +[limited(a=1,next=2000,src=backoff-only,degraded)@rust/task-1/rust]";

// label | deps overrides | the script | expect one line per step
const rows: Array<[string, Partial<SubagentRateLimitWatchdogDeps>, Step[], string]> = [
	["the first detection arms the first ladder step and mirrors the retry time", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }], ARMED_1],
	["the fired steer is the canonical text and clears the mirror", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }], [
		ARMED_1,
		"fire=true await=false timers=1 cancelled=[] delay=1000 steers=1/canonical exhausted=- persist=[rust=null] +[]",
	].join("\n")],
	["a second detection after the steer climbs the ladder", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }, { at: 5_000, do: msg(RATE_LIMITED) }], [
		ARMED_1,
		"fire=true await=false timers=1 cancelled=[] delay=1000 steers=1/canonical exhausted=- persist=[rust=null] +[]",
		"retry#2@7000:backoff-only(degraded) await=true timers=2 cancelled=[] delay=2000 steers=1/canonical exhausted=- persist=[rust=7000] +[retry(a=2,next=7000,src=backoff-only,degraded)@rust/task-1/rust]",
	].join("\n")],
	["a detection while a retry is pending re-arms on the latest decision", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { at: 1_500, do: msg(RATE_LIMITED) }], [
		ARMED_1,
		"retry#2@3500:backoff-only(degraded) await=true timers=2 cancelled=[0] delay=2000 steers=0 exhausted=- persist=[rust=3500] +[retry(a=2,next=3500,src=backoff-only,degraded)@rust/task-1/rust]",
	].join("\n")],
	["the fourth detection exhausts the three attempts and calls the handler", {}, [
		{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }, { do: msg(RATE_LIMITED) }, { do: fire }, { do: msg(RATE_LIMITED) }, { do: fire }, { do: msg(RATE_LIMITED) },
	], [
		ARMED_1,
		"fire=true await=false timers=1 cancelled=[] delay=1000 steers=1/canonical exhausted=- persist=[rust=null] +[]",
		"retry#2@3000:backoff-only(degraded) await=true timers=2 cancelled=[] delay=2000 steers=1/canonical exhausted=- persist=[rust=3000] +[retry(a=2,next=3000,src=backoff-only,degraded)@rust/task-1/rust]",
		"fire=true await=false timers=2 cancelled=[] delay=2000 steers=2/canonical exhausted=- persist=[rust=null] +[]",
		"retry#3@5000:backoff-only(degraded) await=true timers=3 cancelled=[] delay=4000 steers=2/canonical exhausted=- persist=[rust=5000] +[retry(a=3,next=5000,src=backoff-only,degraded)@rust/task-1/rust]",
		"fire=true await=false timers=3 cancelled=[] delay=4000 steers=3/canonical exhausted=- persist=[rust=null] +[]",
		"exhausted#3 await=false timers=3 cancelled=[] delay=4000 steers=3/canonical exhausted=rust#3:rate-limit retries exhausted after 3 attempts persist=[rust=null] +[exhausted(a=3,\"rate-limit retries exhausted after 3 attempts\")@rust/task-1/rust]",
	].join("\n")],
	["a detection with a retry still pending exhausts a one-attempt ladder and disarms it", { maxAttempts: () => 1 }, [{ at: 1_000, do: msg(RATE_LIMITED) }, { at: 1_500, do: msg(RATE_LIMITED) }], [
		ARMED_1,
		'exhausted#1 await=false timers=1 cancelled=[0] delay=1000 steers=0 exhausted=rust#1:rate-limit retries exhausted after 1 attempt persist=[rust=null] +[exhausted(a=1,"rate-limit retries exhausted after 1 attempt")@rust/task-1/rust]',
	].join("\n")],
	["a healthy turn after the steer resolves and resets the ladder", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }, { do: msg(HEALTHY) }, { do: msg(RATE_LIMITED) }], [
		ARMED_1,
		"fire=true await=false timers=1 cancelled=[] delay=1000 steers=1/canonical exhausted=- persist=[rust=null] +[]",
		"resolved#1 await=false timers=1 cancelled=[] delay=1000 steers=1/canonical exhausted=- persist=[rust=null] +[skipped(stopreason-mismatch)@rust/task-1/rust,resolved(a=1)@rust/task-1/rust]",
		"retry#1@2000:backoff-only(degraded) await=true timers=2 cancelled=[] delay=1000 steers=1/canonical exhausted=- persist=[rust=2000] +[limited(a=1,next=2000,src=backoff-only,degraded)@rust/task-1/rust]",
	].join("\n")],
	["a healthy turn before the steer cancels the timer and resolves", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: msg(HEALTHY) }, { do: fire }], [
		ARMED_1,
		"resolved#1 await=false timers=1 cancelled=[0] delay=1000 steers=0 exhausted=- persist=[rust=null] +[skipped(stopreason-mismatch)@rust/task-1/rust,resolved(a=1)@rust/task-1/rust]",
		"fire=false await=false timers=1 cancelled=[0] delay=1000 steers=0 exhausted=- persist=[] +[]",
	].join("\n")],
	["the user-role echo of the steer neither resolves nor resets", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }, { do: msg(STEER_ECHO) }, { do: msg(RATE_LIMITED) }], [
		ARMED_1,
		"fire=true await=false timers=1 cancelled=[] delay=1000 steers=1/canonical exhausted=- persist=[rust=null] +[]",
		"skip:non-assistant await=false timers=1 cancelled=[] delay=1000 steers=1/canonical exhausted=- persist=[] +[skipped(non-assistant)@rust/task-1/rust]",
		"retry#2@3000:backoff-only(degraded) await=true timers=2 cancelled=[] delay=2000 steers=1/canonical exhausted=- persist=[rust=3000] +[retry(a=2,next=3000,src=backoff-only,degraded)@rust/task-1/rust]",
	].join("\n")],
	["a healthy turn with nothing pending is only skipped", {}, [{ do: msg(HEALTHY) }], "skip:stopreason-mismatch await=false timers=0 cancelled=[] steers=0 exhausted=- persist=[] +[skipped(stopreason-mismatch)@rust/task-1/rust]"],
	["an assistant turn without a stop reason after the steer does not resolve", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }, { do: msg(NO_STOP_REASON) }, { do: msg(RATE_LIMITED) }], [
		ARMED_1,
		"fire=true await=false timers=1 cancelled=[] delay=1000 steers=1/canonical exhausted=- persist=[rust=null] +[]",
		"skip:no-stopreason await=false timers=1 cancelled=[] delay=1000 steers=1/canonical exhausted=- persist=[] +[skipped(no-stopreason)@rust/task-1/rust]",
		"retry#2@3000:backoff-only(degraded) await=true timers=2 cancelled=[] delay=2000 steers=1/canonical exhausted=- persist=[rust=3000] +[retry(a=2,next=3000,src=backoff-only,degraded)@rust/task-1/rust]",
	].join("\n")],
	["an error turn without rate-limit prose after the steer does not resolve", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }, { do: msg(ERROR_WITHOUT_PROSE) }, { do: msg(RATE_LIMITED) }], [
		ARMED_1,
		"fire=true await=false timers=1 cancelled=[] delay=1000 steers=1/canonical exhausted=- persist=[rust=null] +[]",
		"skip:no-prose await=false timers=1 cancelled=[] delay=1000 steers=1/canonical exhausted=- persist=[] +[skipped(no-prose)@rust/task-1/rust]",
		"retry#2@3000:backoff-only(degraded) await=true timers=2 cancelled=[] delay=2000 steers=1/canonical exhausted=- persist=[rust=3000] +[retry(a=2,next=3000,src=backoff-only,degraded)@rust/task-1/rust]",
	].join("\n")],
	["an assistant turn without a stop reason is skipped", {}, [{ do: msg(NO_STOP_REASON) }], "skip:no-stopreason await=false timers=0 cancelled=[] steers=0 exhausted=- persist=[] +[skipped(no-stopreason)@rust/task-1/rust]"],
	["an error turn without rate-limit prose is skipped", {}, [{ do: msg(ERROR_WITHOUT_PROSE) }], "skip:no-prose await=false timers=0 cancelled=[] steers=0 exhausted=- persist=[] +[skipped(no-prose)@rust/task-1/rust]"],
	["a disabled watchdog does nothing", { isEnabled: () => false }, [{ at: 1_000, do: msg(RATE_LIMITED) }], "disabled await=false timers=0 cancelled=[] steers=0 exhausted=- persist=[] +[]"],
	["cancel clears the pending retry, the mirror and the ladder", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: cancel }, { do: cancel }, { do: msg(RATE_LIMITED) }], [
		ARMED_1,
		"cancel=true await=false timers=1 cancelled=[0] delay=1000 steers=0 exhausted=- persist=[rust=null] +[]",
		"cancel=false await=false timers=1 cancelled=[0] delay=1000 steers=0 exhausted=- persist=[rust=null] +[]",
		"retry#1@2000:backoff-only(degraded) await=true timers=2 cancelled=[0] delay=1000 steers=0 exhausted=- persist=[rust=2000] +[limited(a=1,next=2000,src=backoff-only,degraded)@rust/task-1/rust]",
	].join("\n")],
	["a stale timer firing after a re-arm does not steer", {}, [{ at: 1_000, do: msg(RATE_LIMITED) }, { at: 1_500, do: msg(RATE_LIMITED) }, { do: fireTimer(0) }], [
		ARMED_1,
		"retry#2@3500:backoff-only(degraded) await=true timers=2 cancelled=[0] delay=2000 steers=0 exhausted=- persist=[rust=3500] +[retry(a=2,next=3500,src=backoff-only,degraded)@rust/task-1/rust]",
		"timer[0]-fired await=true timers=2 cancelled=[0] delay=2000 steers=0 exhausted=- persist=[] +[]",
	].join("\n")],
	["a throwing persist hook is warned and the retry still arms", { persistRetryState: () => { throw new Error("disk gone"); } }, [{ at: 1_000, do: msg(RATE_LIMITED) }],
		"retry#1@2000:backoff-only(degraded) await=true timers=1 cancelled=[] delay=1000 steers=0 exhausted=- persist=[] +[limited(a=1,next=2000,src=backoff-only,degraded)@rust/task-1/rust] warn=[persist-failed]"],
	["a throwing steer is warned, not thrown", { sendUserMessage: () => { throw new Error("bridge socket gone"); } }, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }], [
		ARMED_1,
		"fire=true await=false timers=1 cancelled=[] delay=1000 steers=0 exhausted=- persist=[rust=null] +[] warn=[steer-failed]",
	].join("\n")],
	["a throwing activity sink is warned, not thrown", { emitActivity: () => { throw new Error("broker offline"); } }, [{ at: 1_000, do: msg(RATE_LIMITED) }],
		"retry#1@2000:backoff-only(degraded) await=true timers=1 cancelled=[] delay=1000 steers=0 exhausted=- persist=[rust=2000] +[] warn=[emit-failed]"],
	["a throwing exhaustion handler is warned, not thrown", { maxAttempts: () => 1, onExhausted: () => { throw new Error("outbox gone"); } }, [{ at: 1_000, do: msg(RATE_LIMITED) }, { do: fire }, { do: msg(RATE_LIMITED) }], [
		ARMED_1,
		"fire=true await=false timers=1 cancelled=[] delay=1000 steers=1/canonical exhausted=- persist=[rust=null] +[]",
		"exhausted#1 await=false timers=1 cancelled=[] delay=1000 steers=1/canonical exhausted=- persist=[rust=null] +[exhausted(a=1,\"rate-limit retries exhausted after 1 attempt\")@rust/task-1/rust] warn=[exhausted-failed]",
	].join("\n")],
	["session-limit prose with no usage source schedules on the prose reset, degraded", { getUsageSnapshot: () => null }, [{ at: SESSION_LIMIT_NOW, do: msg(SESSION_LIMIT) }],
		`retry#1@${SESSION_LIMIT_RESET_AT}:prose-fallback(degraded) await=true timers=1 cancelled=[] delay=${SESSION_LIMIT_RESET_AT - SESSION_LIMIT_NOW} steers=0 exhausted=- persist=[rust=${SESSION_LIMIT_RESET_AT}] +[limited(a=1,next=${SESSION_LIMIT_RESET_AT},src=prose-fallback,degraded)@rust/task-1/rust]`],
	["a usage snapshot wins over the prose reset", { getUsageSnapshot: () => claudeUsage() }, [{ at: SESSION_LIMIT_NOW, do: msg(SESSION_LIMIT) }],
		`retry#1@${USAGE_RESET_AT}:usage-endpoint await=true timers=1 cancelled=[] delay=${USAGE_RESET_AT - SESSION_LIMIT_NOW} steers=0 exhausted=- persist=[rust=${USAGE_RESET_AT}] +[limited(a=1,next=${USAGE_RESET_AT},src=usage-endpoint)@rust/task-1/rust]`],
	// collectCodexQuotaWindows emits a window from a reset timestamp alone when
	// the endpoint carries no utilization and no limit flag; dropping it would
	// lose the usage-endpoint reset and fall back to the ladder.
	["a Codex window carrying only a reset time still schedules on it", {
		getUsageSnapshot: () => normalizeQuotaSnapshot("codex", "usage-endpoint", { rate_limit: { primary_window: { reset_after_seconds: (USAGE_RESET_AT - RATE_LIMIT_RESET_MARGIN_MS - SESSION_LIMIT_NOW) / 1000 } } }, SESSION_LIMIT_NOW),
	}, [{ at: SESSION_LIMIT_NOW, do: msg(SESSION_LIMIT) }],
		`retry#1@${USAGE_RESET_AT}:usage-endpoint await=true timers=1 cancelled=[] delay=${USAGE_RESET_AT - SESSION_LIMIT_NOW} steers=0 exhausted=- persist=[rust=${USAGE_RESET_AT}] +[limited(a=1,next=${USAGE_RESET_AT},src=usage-endpoint)@rust/task-1/rust]`],
	["a failing usage source is warned with its secret redacted and the prose reset stands", {
		getUsageSnapshot: () => ({ provider: "claude", reason: "http-401 bearer sk-ant-oauth-secret-token-warning-123456789", resetSource: "usage-endpoint", source: "quota-source-error", status: 401 }),
	}, [{ at: SESSION_LIMIT_NOW, do: msg(SESSION_LIMIT) }, { do: (w) => `status-kept=${w.warnings.some((line) => line.includes("http-401"))} token-redacted=${!w.warnings.some((line) => line.includes("secret-token"))}` }], [
		`retry#1@${SESSION_LIMIT_RESET_AT}:prose-fallback(degraded) await=true timers=1 cancelled=[] delay=${SESSION_LIMIT_RESET_AT - SESSION_LIMIT_NOW} steers=0 exhausted=- persist=[rust=${SESSION_LIMIT_RESET_AT}] +[limited(a=1,next=${SESSION_LIMIT_RESET_AT},src=prose-fallback,degraded)@rust/task-1/rust] warn=[usage-failed]`,
		`status-kept=true token-redacted=true await=true timers=1 cancelled=[] delay=${SESSION_LIMIT_RESET_AT - SESSION_LIMIT_NOW} steers=0 exhausted=- persist=[] +[]`,
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
		`retry#1@${SESSION_LIMIT_RESET_AT}:prose-fallback(degraded) await=true timers=1 cancelled=[] delay=${SESSION_LIMIT_RESET_AT - SESSION_LIMIT_NOW} steers=0 exhausted=- persist=[rust=${SESSION_LIMIT_RESET_AT}] +[limited(a=1,next=${SESSION_LIMIT_RESET_AT},src=prose-fallback,degraded)@rust/task-1/rust]`,
		// The re-arm happened between the two scripts, so its `retry` event
		// appears on the stale timer's line.
		`timer[0]-fired await=true timers=2 cancelled=[0] delay=${USAGE_RESET_AT - SESSION_LIMIT_NOW} steers=0 exhausted=- persist=[rust=${USAGE_RESET_AT}] +[retry(a=1,next=${USAGE_RESET_AT},src=usage-endpoint)@rust/task-1/rust]`,
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
		`retry#1@${SESSION_LIMIT_RESET_AT}:prose-fallback(degraded) await=true timers=1 cancelled=[] delay=${SESSION_LIMIT_RESET_AT - SESSION_LIMIT_NOW} steers=0 exhausted=- persist=[rust=${SESSION_LIMIT_RESET_AT}] +[limited(a=1,next=${SESSION_LIMIT_RESET_AT},src=prose-fallback,degraded)@rust/task-1/rust]`,
		`resolved#1 await=false timers=1 cancelled=[0] delay=${SESSION_LIMIT_RESET_AT - SESSION_LIMIT_NOW} steers=0 exhausted=- persist=[rust=null] +[skipped(stopreason-mismatch)@rust/task-1/rust,resolved(a=1)@rust/task-1/rust]`,
		`settled await=false timers=1 cancelled=[0] delay=${SESSION_LIMIT_RESET_AT - SESSION_LIMIT_NOW} steers=0 exhausted=- persist=[] +[]`,
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
