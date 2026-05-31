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
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { clearPiRateLimitRetryStateFile, piRateLimitRetryStateFile } from "../../src/daemon/loop.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const SUBSCRIBERS_BASH = resolve(HERE, "../../../../scripts/lib/subscribers.bash");
const DECIDER_TS = resolve(HERE, "../../src/daemon/rate-limit-watchdog.ts");
const LOOP_TS = resolve(HERE, "../../src/daemon/loop.ts");

const bashSrc = readFileSync(SUBSCRIBERS_BASH, "utf8");
const loopSrc = readFileSync(LOOP_TS, "utf8");

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

function runDecider(event: unknown, attempt: number, paneId = "%41", now = 0, env: NodeJS.ProcessEnv = {}): { kind: string; raw: any; stderr: string } {
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
		{ encoding: "utf8", env: { ...process.env, ...env }, input: JSON.stringify(event) },
	);
	if (r.status !== 0) throw new Error(`decider CLI exit ${r.status}: ${r.stderr}`);
	const parsed = JSON.parse(r.stdout);
	return { kind: parsed.kind, raw: parsed, stderr: r.stderr };
}

function writeFakePiBridge(dir: string, stateJson: string, sendLog: string, removeBeforeStateReturns?: string): string {
	const bin = join(dir, "fake-pi-bridge");
	writeFileSync(bin, [
		"#!/usr/bin/env bash",
		"cmd=\"$1\"; shift || true",
		"case \"$cmd\" in",
		`  state) ${removeBeforeStateReturns ? `rm -f ${JSON.stringify(removeBeforeStateReturns)}; ` : ""}cat ${JSON.stringify(stateJson)} ;;`,
		`  send) printf '%s\\n' \"$*\" >> ${JSON.stringify(sendLog)} ;;`,
		"  *) exit 2 ;;",
		"esac",
	].join("\n"));
	chmodSync(bin, 0o700);
	return bin;
}

function runRetryDispatcher(args: {
	retryState?: string;
	expectedState?: string;
	state: Record<string, unknown>;
	expectedPid?: number | string;
	expectedSession?: string;
	expectedSocket?: string;
	expectedSubscriberPid?: number | string;
	removeRetryStateDuringState?: boolean;
}): { sendLogText: string; status: number | null; stderr: string } {
	const dir = mkdtempSync(join(tmpdir(), "fd-rate-limit-dispatch-"));
	try {
		const retryStateFile = join(dir, "retry.state");
		const expectedState = args.expectedState ?? args.retryState ?? "nonce\tsess\t123\tsock\t%41\tsub";
		if (args.retryState !== undefined) writeFileSync(retryStateFile, args.retryState);
		const stateJson = join(dir, "state.json");
		const sendLog = join(dir, "send.log");
		writeFileSync(stateJson, JSON.stringify(args.state));
		const fakePi = writeFakePiBridge(dir, stateJson, sendLog, args.removeRetryStateDuringState ? retryStateFile : undefined);
		const r = spawnSync("bash", [
			SUBSCRIBERS_BASH,
			"pi-rate-limit-dispatch",
			"0",
			retryStateFile,
			expectedState,
			String(process.pid),
			String(args.expectedPid ?? process.pid),
			args.expectedSession ?? "sess",
			args.expectedSocket ?? "sock",
			String(args.expectedSubscriberPid ?? process.pid),
			fakePi,
			"--socket",
			args.expectedSocket ?? "sock",
		], { encoding: "utf8" });
		return {
			sendLogText: existsSync(sendLog) ? readFileSync(sendLog, "utf8") : "",
			status: r.status,
			stderr: r.stderr ?? "",
		};
	} finally {
		rmSync(dir, { force: true, recursive: true });
	}
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

	test("bash emits sanitized quota-source diagnostics before retry fallback", () => {
		expect(bashSrc).toContain("quotaSourceFailureSummary");
		expect(bashSrc).toContain("pi-rate-limit-quota-source-error");
		expect(bashSrc).toContain("rate_limit_quota_source_error");
		expect(bashSrc).toContain("quota_source_failure");
		expect(bashSrc).toContain('pi_rate_limit_emit_event "pi-rate-limit-retry" "rate_limit_retry"');
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
		expect(bashSrc).toContain('pi_rate_limit_clear_retry "resolved"');
		expect(bashSrc).toContain("pi-rate-limit-resolved");
	});

	test("bash cancels stale detached rate-limit retries with a nonce state file", () => {
		expect(bashSrc).toContain("rate_limit_retry_state_file=");
		expect(bashSrc).toContain("rate_limit_retry_nonce=");
		expect(bashSrc).toContain("pi_rate_limit_clear_retry");
		expect(bashSrc).toContain("pi_rate_limit_retry_state_file_for_pane");
		expect(bashSrc).toContain("rl_expected_state=");
		expect(bashSrc).toContain("expected_pi_pid");
		expect(bashSrc).toContain("expected_session");
		expect(bashSrc).toContain("expected_socket");
		expect(bashSrc).toContain("expected_subscriber_pid");
		expect(bashSrc).toContain('current=$(cat "$state_file" 2>/dev/null || true)');
		expect(bashSrc).toContain('[[ "$current" == "$expected_state" ]] || exit 0');
		expect(bashSrc).toContain('state=$("$pi_bin" state "$@" 2>/dev/null) || exit 0');
		expect(bashSrc).toContain('[[ "$actual_pid" == "$expected_pi_pid" ]] || exit 0');
		expect(bashSrc).toContain('[[ "$actual_session" == "$expected_session" ]] || exit 0');
		expect(bashSrc).toContain('[[ "$actual_socket" == "$expected_socket" ]] || exit 0');
		expect(bashSrc).toContain('pi_rate_limit_clear_retry "subagent-completion"');
		expect(bashSrc).toContain('pi_rate_limit_clear_retry "subscriber-stream-end"');
		expect(bashSrc).toContain("pi_rate_limit_tombstone_retry_file");
		expect(bashSrc).not.toContain('rm -f "$cleanup_file"');
	});

	test("daemon reap/dead paths clear Pi rate-limit retry state files", () => {
		expect(loopSrc).toContain("piRateLimitRetryStateFile");
		expect(loopSrc).toContain("pi-rate-limit-retry-");
		expect(loopSrc).toContain("clearPiRateLimitRetryState");
		expect(loopSrc).toContain('if (h === "pi") clearPiRateLimitRetryState(paneId, reason);');
		expect(loopSrc).toContain('if (subHarness === "pi") clearPiRateLimitRetryState(innerId, "subscriber-dead");');
	});

	test("daemon cleanup removes the exact Pi rate-limit retry state path", () => {
		const dir = mkdtempSync(join(tmpdir(), "fd-rate-limit-cleanup-"));
		try {
			const target = piRateLimitRetryStateFile(dir, "%41");
			const other = piRateLimitRetryStateFile(dir, "%42");
			writeFileSync(target, "armed\n");
			writeFileSync(other, "other\n");
			const result = clearPiRateLimitRetryStateFile(dir, "%41", "test");
			expect(result.disarmed).toBe(true);
			expect(result.removed).toBe(true);
			expect(existsSync(target)).toBe(false);
			expect(readFileSync(other, "utf8")).toBe("other\n");
		} finally {
			rmSync(dir, { force: true, recursive: true });
		}
	});

	test("daemon cleanup disarms with tombstone when unlink cannot remove the file", () => {
		const dir = mkdtempSync(join(tmpdir(), "fd-rate-limit-tombstone-"));
		try {
			const target = piRateLimitRetryStateFile(dir, "%41");
			writeFileSync(target, "armed\n", { mode: 0o600 });
			chmodSync(dir, 0o500);
			const result = clearPiRateLimitRetryStateFile(dir, "%41", "test");
			expect(result.disarmed).toBe(true);
			expect(result.tombstoned).toBe(true);
			expect(result.removed).toBe(false);
			chmodSync(dir, 0o700);
			expect(readFileSync(target, "utf8")).toContain("cancelled\ttest");
		} finally {
			try { chmodSync(dir, 0o700); } catch {}
			rmSync(dir, { force: true, recursive: true });
		}
	});

	test("retry dispatcher sends only when nonce, pid, session, socket, and subscriber match", () => {
		const expectedState = `nonce\tsess\t${process.pid}\tsock\t%41\t${process.pid}`;
		const ok = runRetryDispatcher({
			expectedPid: process.pid,
			expectedSession: "sess",
			expectedSocket: "sock",
			expectedSubscriberPid: process.pid,
			retryState: expectedState,
			state: { state: { pid: process.pid, sessionId: "sess", socket: "sock" } },
		});
		expect(ok.status).toBe(0);
		expect(ok.sendLogText).toContain("--steer");

		for (const blocked of [
			{ name: "missing retry state", retryState: undefined, state: { state: { pid: process.pid, sessionId: "sess", socket: "sock" } } },
			{ name: "tombstoned retry state", expectedState, retryState: "cancelled\tresolved\t123\tnonce", state: { state: { pid: process.pid, sessionId: "sess", socket: "sock" } } },
			{ name: "retry state removed during bridge state", retryState: expectedState, removeRetryStateDuringState: true, state: { state: { pid: process.pid, sessionId: "sess", socket: "sock" } } },
			{ name: "pid mismatch", retryState: expectedState, state: { state: { pid: process.pid + 10_000, sessionId: "sess", socket: "sock" } } },
			{ name: "session mismatch", retryState: expectedState, state: { state: { pid: process.pid, sessionId: "other", socket: "sock" } } },
			{ name: "socket mismatch", retryState: expectedState, state: { state: { pid: process.pid, sessionId: "sess", socket: "other" } } },
			{ name: "subscriber mismatch", retryState: expectedState, expectedSubscriberPid: 999_999_999, state: { state: { pid: process.pid, sessionId: "sess", socket: "sock" } } },
		] as const) {
			const result = runRetryDispatcher({
				expectedPid: process.pid,
				expectedSession: "sess",
				expectedSocket: "sock",
				expectedSubscriberPid: (blocked as { expectedSubscriberPid?: number }).expectedSubscriberPid ?? process.pid,
				expectedState: (blocked as { expectedState?: string }).expectedState,
				removeRetryStateDuringState: (blocked as { removeRetryStateDuringState?: boolean }).removeRetryStateDuringState,
				retryState: blocked.retryState,
				state: blocked.state,
			});
			if (result.status !== 0 || result.sendLogText !== "") {
				throw new Error(`${blocked.name}: status=${result.status} send=${JSON.stringify(result.sendLogText)} stderr=${JSON.stringify(result.stderr)}`);
			}
		}
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

	test("quota-source diagnostics round-trip through CLI without leaking tokens", () => {
		const token = "sk-ant-oauth-secret-token-cli-123456789";
		const failure = {
			provider: "claude",
			reason: `http-401 bearer ${token}`,
			resetSource: "usage-endpoint",
			source: "quota-source-error",
			status: 401,
		};
		const { kind, raw, stderr } = runDecider(
			{ data: CANONICAL_DATA, event: "message_end", type: "event" },
			0,
			"%41",
			0,
			{ VSTACK_RATE_LIMIT_USAGE_JSON: JSON.stringify(failure) },
		);
		expect(kind).toBe("retry-at");
		expect(raw.quotaSourceFailureSummary).toContain("http-401");
		expect(raw.quotaSourceFailureSummary).toContain("status=401");
		expect(raw.quotaSourceFailureSummary).not.toContain(token);
		expect(stderr).toContain("quota-source-error");
		expect(stderr).not.toContain(token);
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
