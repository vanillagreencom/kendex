// vstack#108 wiring test: the bash pi subscriber must stay in lock-step
// with the canonical decideRateLimitRetry decision module. Two halves:
//
//   1. The bash subscriber source contains the jq filter that picks up
//      the canonical rate-limit shape, plus both wake-event classifier
//      tags (pi-rate-limit-retry / pi-rate-limit-exhausted), skipped/resolved
//      activity tags, decider-error reporting, and a steer dispatch path.
//      Source-level guards catch any future refactor that
//      removes one of the contracts.
//   2. The TS decision module's CLI (`bun rate-limit-watchdog.ts decide
//      ...`) reads event JSON from stdin and emits the exact JSON shape
//      the bash branch consumes. Drives the CLI for a canonical event +
//      a healthy event and asserts the decision-kind round-trip.

import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SUBSCRIBERS_BASH = resolve(HERE, "../../../../scripts/lib/subscribers.bash");
const DECIDER_TS = resolve(HERE, "../../src/daemon/rate-limit-watchdog.ts");

const bashSrc = readFileSync(SUBSCRIBERS_BASH, "utf8");

const CANONICAL_DATA = {
	message: {
		api: "claude-bridge",
		content: [
			{
				text: "API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited",
				type: "text",
			},
		],
		errorMessage:
			"Claude Code returned an error result: API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited",
		role: "assistant",
		stopReason: "error",
	},
};

const HEALTHY_DATA = {
	message: {
		content: [{ text: "Done.", type: "text" }],
		role: "assistant",
		stopReason: "stop",
	},
};

function runDecider(event: unknown, attempt: number, paneId = "%41", now = 0): { kind: string; raw: any } {
	const r = spawnSync(
		"bun",
		[
			DECIDER_TS,
			"decide",
			"--pane",
			paneId,
			"--attempt",
			String(attempt),
			"--now",
			String(now),
		],
		{ encoding: "utf8", input: JSON.stringify(event) },
	);
	if (r.status !== 0) throw new Error(`decider CLI exit ${r.status}: ${r.stderr}`);
	const parsed = JSON.parse(r.stdout);
	return { kind: parsed.kind, raw: parsed };
}

describe("rate-limit wiring: bash subscriber mirror (vstack#108)", () => {
	test("subscribers.bash honors VSTACK_RATE_LIMIT_WATCHDOG=0 disable", () => {
		expect(bashSrc).toMatch(/VSTACK_RATE_LIMIT_WATCHDOG/);
		expect(bashSrc).toMatch(/case "\$rate_limit_enabled" in 0\|false\|FALSE\|off\|OFF/);
	});

	test("bash defaults match TS decider defaults", () => {
		// Max attempts default 5.
		expect(bashSrc).toMatch(/VSTACK_RATE_LIMIT_MAX_ATTEMPTS:-5/);
	});

	test("jq filter passes message_end events for positive and skipped rate-limit decisions", () => {
		expect(bashSrc).toMatch(/\.event == "message_end"/);
		expect(bashSrc).toContain('((.data.message.customType // "") == "")');
		expect(bashSrc).toMatch(/\.data\.message\.role/);
		expect(bashSrc).toMatch(/\.data\.message\.stopReason/);
		expect(bashSrc).toMatch(/temporarily limiting requests/);
		expect(bashSrc).toMatch(/too many requests/);
	});

	test("bash emits retry/exhausted and activity-only rate-limit tags", () => {
		expect(bashSrc).toContain('pi_rate_limit_emit_event "pi-rate-limit-retry"');
		expect(bashSrc).toContain('pi_rate_limit_emit_event "pi-rate-limit-exhausted"');
		expect(bashSrc).toContain('pi_rate_limit_emit_event "pi-rate-limit-skipped"');
		expect(bashSrc).toContain('pi_rate_limit_emit_event "pi-rate-limit-resolved"');
		expect(bashSrc).toContain('pi_rate_limit_emit_event "pi-rate-limit-decider-error"');
	});

	test("bash pipes event JSON to the decider instead of passing it via argv", () => {
		expect(bashSrc).toContain('printf \'%s\' "$rl_event_json" | bun "$rate_limit_decider" decide');
		expect(bashSrc).not.toContain('--event "$rl_event_json"');
	});

	test("bash drops non-assistant classifier rejections before prompt classification", () => {
		expect(bashSrc).toContain('[[ "$rl_role" != "assistant" ]] && continue');
	});

	test("bash reports decider failures instead of swallowing them", () => {
		expect(bashSrc).toContain("pi-rate-limit-decider-error");
		expect(bashSrc).toContain("pi-rate-limit-decider-unavailable");
		expect(bashSrc).toContain("rl_rc=$?");
		expect(bashSrc).toContain("rl_stderr=");
	});

	test("bash resets subscriber retry budget on resolved assistant turn", () => {
		expect(bashSrc).toContain("rate_limit_attempt=0");
		expect(bashSrc).toContain("pi-rate-limit-resolved");
	});

	test("bash references the canonical TS module name for parity", () => {
		expect(bashSrc).toContain("rate-limit-watchdog.ts");
		expect(bashSrc).toMatch(/decideRateLimitRetry/);
	});

	test("bash dispatches a pi-bridge --steer after the backoff delay", () => {
		expect(bashSrc).toContain("--steer");
		// Steer prose is mandated by the issue body.
		expect(bashSrc).toContain("API rate limit was detected. Try to continue from where you left off.");
	});
});

describe("rate-limit decider CLI (vstack#108)", () => {
	test("canonical event + attempt 0 returns retry-at with attempt=1", () => {
		const { kind, raw } = runDecider({ data: CANONICAL_DATA, event: "message_end", type: "event" }, 0);
		expect(kind).toBe("retry-at");
		expect(raw.attempt).toBe(1);
		expect(raw.at).toBeGreaterThan(0);
	});

	test("canonical event + attempt at max returns exhausted", () => {
		const { kind, raw } = runDecider({ data: CANONICAL_DATA, event: "message_end", type: "event" }, 5);
		expect(kind).toBe("exhausted");
		expect(raw.attempt).toBe(5);
	});

	test("healthy event returns not-rate-limited", () => {
		const { kind, raw } = runDecider({ data: HEALTHY_DATA, event: "message_end", type: "event" }, 0);
		expect(kind).toBe("not-rate-limited");
		expect(raw.reason).toBe("stopreason-mismatch");
	});

	test("rejection reasons round-trip through the CLI", () => {
		const cases = [
			{
				event: { message: { content: [{ text: "Rate limited", type: "text" }], role: "user" } },
				reason: "non-assistant",
			},
			{
				event: { message: { content: [{ text: "Rate limited", type: "text" }], role: "assistant" } },
				reason: "no-stopreason",
			},
			{
				event: HEALTHY_DATA,
				reason: "stopreason-mismatch",
			},
			{
				event: { message: { content: [{ text: "Tool failed", type: "text" }], role: "assistant", stopReason: "error" } },
				reason: "no-prose",
			},
		] as const;
		for (const { event, reason } of cases) {
			const { kind, raw } = runDecider({ data: event, event: "message_end", type: "event" }, 0);
			expect(kind).toBe("not-rate-limited");
			expect(raw.reason).toBe(reason);
		}
	});
});
