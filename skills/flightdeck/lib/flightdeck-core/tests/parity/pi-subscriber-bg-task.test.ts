// Parity test (vstack#15): the Pi subscriber must translate a
// `vstack-background-tasks:event` exit message into a canonical
// `pi-bg-task-exit` row in the wake-events log so the daemon can wake
// master even when the agent's own follow-up turn never lands.
//
// We stub `pi-bridge stream` with a tiny script on PATH that emits a
// canned JSONL exit event, run scripts/lib/subscribers.bash pi against
// it, and assert the canonical wake event appears.
//
// Env isolation (vstack#15 round 4 reviewer-test #2): the spawned
// subscriber inherits a filtered process.env that explicitly drops
// PI_BRIDGE_BIN (otherwise pi_resolve_bridge_bin in the bash subscriber
// would honor the host's PI_BRIDGE_BIN and bypass the stub) and places
// the stub bridge dir first on PATH. The drift test below the
// canonical-cases verifies the isolation holds under a polluted host
// env by setting PI_BRIDGE_BIN=/bin/true on the spawn call.
//
// Toolchain requirements (Linux/macOS): bash, jq, flock, sha256sum,
// awk, sleep. The subscriber loop is a shared bash body (used by both
// the bash and TS daemons), so testing its jq filter without spawning
// it would require duplicating the jq expression into TS. We instead
// stub the `pi-bridge` binary on PATH and shorten the second test's
// observation window. The mostly-pure consumer side is covered without
// subprocesses in `tests/unit/bg-task-events.test.ts`.

import { afterAll, describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SUBSCRIBERS_BASH = resolve(HERE, "../../../../scripts/lib/subscribers.bash");

function sleep(ms: number): Promise<void> { return new Promise((res) => setTimeout(res, ms)); }

// Build a subscriber env that:
//   - explicitly removes PI_BRIDGE_BIN (pi_resolve_bridge_bin in the
//     bash subscriber prefers this env var over PATH; an inherited
//     value from the host shell would bypass the stub bridge),
//   - places the stub bridge directory first on PATH,
//   - inherits only the small handful of vars actually needed (HOME,
//     SHELL, TMPDIR, LANG, LC_*).
function subscriberEnv(stubBin: string, stateDir: string, extra: Record<string, string> = {}): NodeJS.ProcessEnv {
	const env: NodeJS.ProcessEnv = {
		PATH: `${stubBin}:/usr/bin:/bin`,
		HOME: process.env.HOME ?? "/tmp",
		SHELL: "/bin/bash",
		TMPDIR: process.env.TMPDIR ?? "/tmp",
		LANG: process.env.LANG ?? "C.UTF-8",
		FD_STATE_DIR: stateDir,
		SESSION_LOCK: `${stateDir}/session.lock`,
		WAKE_EVENTS_LOG: `${stateDir}/wake-events.log`,
		LOG: `${stateDir}/daemon.log`,
		CLASSIFIER: "",
		PI_LAST_ASSISTANT_JQ: ".message.content // []",
		...extra,
	};
	// Belt-and-suspenders: even if `extra` later picks up PI_BRIDGE_BIN
	// via spread, drop it. The pi-bridge stub must come from PATH only.
	delete env.PI_BRIDGE_BIN;
	return env;
}

function pidAlive(pid: number): boolean {
	if (!Number.isFinite(pid) || pid <= 0) return false;
	try { process.kill(pid, 0); return true; }
	catch (e) { return (e as NodeJS.ErrnoException).code === "EPERM"; }
}

const stateDirs: string[] = [];
afterAll(() => {
	for (const d of stateDirs) {
		if (d && existsSync(d)) rmSync(d, { recursive: true, force: true });
	}
});

describe("subscriber env isolation (vstack#15 round 4)", () => {
	test("subscriberEnv drops PI_BRIDGE_BIN even when passed via extras", () => {
		// Belt-and-suspenders guarantee for reviewer-test #2: a caller can
		// not accidentally smuggle PI_BRIDGE_BIN into the spawned env.
		const env = subscriberEnv("/tmp/bin", "/tmp/state", { PI_BRIDGE_BIN: "/bin/true" } as Record<string, string>);
		expect(env.PI_BRIDGE_BIN).toBeUndefined();
		expect(env.PATH).toContain("/tmp/bin");
	});

	test("subscriberEnv does not inherit PI_BRIDGE_BIN from process.env", () => {
		// Even with a polluted host env, the spawned subscriber sees the
		// stub bridge first on PATH and no PI_BRIDGE_BIN override.
		const saved = process.env.PI_BRIDGE_BIN;
		try {
			process.env.PI_BRIDGE_BIN = "/bin/true";
			const env = subscriberEnv("/tmp/bin", "/tmp/state");
			expect(env.PI_BRIDGE_BIN).toBeUndefined();
		} finally {
			if (saved === undefined) delete process.env.PI_BRIDGE_BIN;
			else process.env.PI_BRIDGE_BIN = saved;
		}
	});
});

describe("Pi subscriber bg-task exit translation (vstack#15)", () => {
	test("emits pi-bg-task-exit wake event with task payload", async () => {
		const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-bg-"));
		stateDirs.push(stateDir);
		const sessionLock = join(stateDir, "session.lock");
		const wakeLog = join(stateDir, "wake-events.log");
		const log = join(stateDir, "daemon.log");
		const bridgeDir = join(stateDir, "bin");
		mkdirSync(bridgeDir, { recursive: true });
		const bridgeBin = join(bridgeDir, "pi-bridge");
		const bridgeScript = `#!/usr/bin/env bash
# Stub pi-bridge for parity test. Only handles "stream".
if [[ "\${1:-}" != "stream" ]]; then
  exit 0
fi
cat <<'JSON'
{"type":"event","event":"message_end","data":{"message":{"role":"system","customType":"vstack-background-tasks:event","details":{"eventType":"exit","task":{"id":"bg-3","status":"failed","exitCode":null,"command":"bot-review-wait 81","outputBytes":89,"notifyOnExit":true,"notifyOnOutput":false,"exitNotified":true}}}}}
JSON
# Hold the stream open like a real bridge so the watchdog has time to act.
sleep 30
`;
		writeFileSync(bridgeBin, bridgeScript);
		chmodSync(bridgeBin, 0o755);

		const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
		const parentPid = fakeParent.pid!;
		try {
			const env = subscriberEnv(bridgeDir, stateDir);
			const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%18", "1184234", "", String(parentPid)], {
				env,
				stdio: "ignore",
				detached: true,
			});
			const subPid = sub.pid!;

			const deadline = Date.now() + 8000;
			let lines: string[] = [];
			while (Date.now() < deadline) {
				if (existsSync(wakeLog)) {
					lines = readFileSync(wakeLog, "utf8").split("\n").filter(Boolean);
					if (lines.length > 0) break;
				}
				await sleep(100);
			}

			try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
			try { process.kill(subPid, "SIGTERM"); } catch { /* */ }

			expect(lines.length).toBeGreaterThan(0);
			const ev = JSON.parse(lines[0]!);
			expect(ev.pane_id).toBe("%18");
			expect(ev.harness).toBe("pi");
			expect(ev.classifier_tag).toBe("pi-bg-task-exit");
			expect(ev.event_type).toBe("bg-task-exit");
			expect(ev.task?.id).toBe("bg-3");
			expect(ev.task?.status).toBe("failed");
			expect(ev.hash).toMatch(/^[0-9a-f]{12}$/);
		} finally {
			try { fakeParent.kill("SIGKILL"); } catch { /* */ }
			await sleep(50);
		}
	});

	test("non-exit bg-task event (output) does not produce pi-bg-task-exit", async () => {
		const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-bg-out-"));
		stateDirs.push(stateDir);
		const sessionLock = join(stateDir, "session.lock");
		const wakeLog = join(stateDir, "wake-events.log");
		const log = join(stateDir, "daemon.log");
		const bridgeDir = join(stateDir, "bin");
		mkdirSync(bridgeDir, { recursive: true });
		const bridgeBin = join(bridgeDir, "pi-bridge");
		const bridgeScript = `#!/usr/bin/env bash
if [[ "\${1:-}" != "stream" ]]; then exit 0; fi
cat <<'JSON'
{"type":"event","event":"message_end","data":{"message":{"role":"system","customType":"vstack-background-tasks:event","details":{"eventType":"output","task":{"id":"bg-3","status":"running","exitCode":null}}}}}
JSON
sleep 30
`;
		writeFileSync(bridgeBin, bridgeScript);
		chmodSync(bridgeBin, 0o755);

		const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
		const parentPid = fakeParent.pid!;
		try {
			const env = subscriberEnv(bridgeDir, stateDir);
			const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%18", "1184234", "", String(parentPid)], {
				env,
				stdio: "ignore",
				detached: true,
			});
			const subPid = sub.pid!;
			// Watch the wake-events log for up to 1s; any pi-bg-task-exit
			// row would have been written almost immediately after the
			// stub emitted, so a short window catches the failure case
			// without paying a 2s sleep.
			const deadline = Date.now() + 1000;
			while (Date.now() < deadline) {
				if (existsSync(wakeLog)) {
					const peek = readFileSync(wakeLog, "utf8").split("\n").filter(Boolean);
					if (peek.some((raw) => raw.includes("pi-bg-task-exit"))) break;
				}
				await sleep(50);
			}

			try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
			try { process.kill(subPid, "SIGTERM"); } catch { /* */ }

			const lines = existsSync(wakeLog)
				? readFileSync(wakeLog, "utf8").split("\n").filter(Boolean)
				: [];
			// Output events are filtered out by the jq select; no wake-events row.
			for (const raw of lines) {
				const ev = JSON.parse(raw);
				expect(ev.classifier_tag).not.toBe("pi-bg-task-exit");
			}
		} finally {
			try { fakeParent.kill("SIGKILL"); } catch { /* */ }
			await sleep(50);
		}
	});
});

describe("Pi subscriber question drain on attach (#37 D)", () => {
	// The bridge stub returns one already-open question from
	// `pi-bridge questions` and a stream that never emits, so the
	// only path that can land a pi-question wake row is the new
	// on-attach drain.
	test("emits pi-question wake row for questions opened before subscribe", async () => {
		const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-drain-"));
		stateDirs.push(stateDir);
		const wakeLog = join(stateDir, "wake-events.log");
		const bridgeDir = join(stateDir, "bin");
		mkdirSync(bridgeDir, { recursive: true });
		const bridgeBin = join(bridgeDir, "pi-bridge");
		const bridgeScript = `#!/usr/bin/env bash
if [[ "\${1:-}" == "questions" ]]; then
  cat <<'JSON'
{"type":"response","id":1,"command":"questions","success":true,"data":{"available":true,"questions":[{"requestId":"que_drain_1","openedAt":"2026-05-13T00:00:00Z","request":{"id":"que_drain_1","header":"H","questions":[{"header":"H","question":"Q?","options":[{"label":"yes"},{"label":"no"}]}]}}]}}
JSON
  exit 0
fi
if [[ "\${1:-}" == "stream" ]]; then
  sleep 30
fi
exit 0
`;
		writeFileSync(bridgeBin, bridgeScript);
		chmodSync(bridgeBin, 0o755);

		const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
		const parentPid = fakeParent.pid!;
		try {
			const env = subscriberEnv(bridgeDir, stateDir);
			const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%42", "99999", "", String(parentPid)], {
				env,
				stdio: "ignore",
				detached: true,
			});
			const subPid = sub.pid!;

			const deadline = Date.now() + 5000;
			let lines: string[] = [];
			while (Date.now() < deadline) {
				if (existsSync(wakeLog)) {
					lines = readFileSync(wakeLog, "utf8").split("\n").filter(Boolean);
					if (lines.length > 0) break;
				}
				await sleep(100);
			}

			try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
			try { process.kill(subPid, "SIGTERM"); } catch { /* */ }

			expect(lines.length).toBeGreaterThan(0);
			const ev = JSON.parse(lines[0]!);
			expect(ev.pane_id).toBe("%42");
			expect(ev.harness).toBe("pi");
			expect(ev.event_type).toBe("question");
			expect(ev.classifier_tag).toBe("pi-question");
			expect(ev.request_id).toBe("que_drain_1");
			expect(ev.question?.id).toBe("que_drain_1");
			expect(ev.hash).toMatch(/^[0-9a-f]{12}$/);
		} finally {
			try { fakeParent.kill("SIGKILL"); } catch { /* */ }
			await sleep(50);
		}
	});

	// Round-1 reviewer-error blocker (#37): drain must fail open with
	// observable diagnostics when the bridge call errors, hangs, or
	// returns malformed JSON. Each case writes a structured tag to the
	// per-pane sub_log and never blocks the live stream branch.
	test("non-zero pi-bridge questions exit → [pi-sub-drain-error], no wake row", async () => {
		const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-drain-err-"));
		stateDirs.push(stateDir);
		const wakeLog = join(stateDir, "wake-events.log");
		const subLog = join(stateDir, "daemon.log.pi-sub-44");
		const bridgeDir = join(stateDir, "bin");
		mkdirSync(bridgeDir, { recursive: true });
		const bridgeBin = join(bridgeDir, "pi-bridge");
		const bridgeScript = `#!/usr/bin/env bash
if [[ "\${1:-}" == "questions" ]]; then
  echo "bridge unreachable: ECONNREFUSED" >&2
  exit 2
fi
if [[ "\${1:-}" == "stream" ]]; then sleep 30; fi
exit 0
`;
		writeFileSync(bridgeBin, bridgeScript);
		chmodSync(bridgeBin, 0o755);
		const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
		const parentPid = fakeParent.pid!;
		try {
			const env = subscriberEnv(bridgeDir, stateDir);
			const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%44", "99999", "", String(parentPid)], {
				env,
				stdio: "ignore",
				detached: true,
			});
			const subPid = sub.pid!;
			const deadline = Date.now() + 3000;
			while (Date.now() < deadline) {
				if (existsSync(subLog) && readFileSync(subLog, "utf8").includes("[pi-sub-drain-error]")) break;
				await sleep(50);
			}
			try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
			try { process.kill(subPid, "SIGTERM"); } catch { /* */ }
			const logBody = existsSync(subLog) ? readFileSync(subLog, "utf8") : "";
			expect(logBody).toContain("[pi-sub-drain-error]");
			expect(logBody).toContain("pane=%44");
			expect(logBody).toContain("rc=2");
			expect(logBody).toContain("ECONNREFUSED");
			const wake = existsSync(wakeLog) ? readFileSync(wakeLog, "utf8").split("\n").filter(Boolean) : [];
			expect(wake.length).toBe(0);
		} finally {
			try { fakeParent.kill("SIGKILL"); } catch { /* */ }
			await sleep(50);
		}
	});

	test("hanging pi-bridge questions → timeout, [pi-sub-drain-error] rc=124", async () => {
		const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-drain-hang-"));
		stateDirs.push(stateDir);
		const subLog = join(stateDir, "daemon.log.pi-sub-45");
		const bridgeDir = join(stateDir, "bin");
		mkdirSync(bridgeDir, { recursive: true });
		const bridgeBin = join(bridgeDir, "pi-bridge");
		const bridgeScript = `#!/usr/bin/env bash
if [[ "\${1:-}" == "questions" ]]; then sleep 30; fi
if [[ "\${1:-}" == "stream" ]]; then sleep 30; fi
exit 0
`;
		writeFileSync(bridgeBin, bridgeScript);
		chmodSync(bridgeBin, 0o755);
		const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
		const parentPid = fakeParent.pid!;
		try {
			// Cap the drain timeout to 1s so the test completes quickly.
			const env = subscriberEnv(bridgeDir, stateDir, { FD_ADAPTER_READ_TIMEOUT_SEC: "1" });
			const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%45", "99999", "", String(parentPid)], {
				env,
				stdio: "ignore",
				detached: true,
			});
			const subPid = sub.pid!;
			const deadline = Date.now() + 4000;
			while (Date.now() < deadline) {
				if (existsSync(subLog) && readFileSync(subLog, "utf8").includes("[pi-sub-drain-error]")) break;
				await sleep(50);
			}
			try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
			try { process.kill(subPid, "SIGTERM"); } catch { /* */ }
			const logBody = existsSync(subLog) ? readFileSync(subLog, "utf8") : "";
			expect(logBody).toContain("[pi-sub-drain-error]");
			expect(logBody).toContain("rc=124");
		} finally {
			try { fakeParent.kill("SIGKILL"); } catch { /* */ }
			await sleep(50);
		}
	});

	test("malformed JSON from pi-bridge questions → [pi-sub-drain-malformed], no wake row", async () => {
		const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-drain-malformed-"));
		stateDirs.push(stateDir);
		const wakeLog = join(stateDir, "wake-events.log");
		const subLog = join(stateDir, "daemon.log.pi-sub-46");
		const bridgeDir = join(stateDir, "bin");
		mkdirSync(bridgeDir, { recursive: true });
		const bridgeBin = join(bridgeDir, "pi-bridge");
		const bridgeScript = `#!/usr/bin/env bash
if [[ "\${1:-}" == "questions" ]]; then
  # Valid JSON but wrong envelope: success=false, missing data.questions array.
  echo '{"type":"response","success":false,"error":"no bridge"}'
  exit 0
fi
if [[ "\${1:-}" == "stream" ]]; then sleep 30; fi
exit 0
`;
		writeFileSync(bridgeBin, bridgeScript);
		chmodSync(bridgeBin, 0o755);
		const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
		const parentPid = fakeParent.pid!;
		try {
			const env = subscriberEnv(bridgeDir, stateDir);
			const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%46", "99999", "", String(parentPid)], {
				env,
				stdio: "ignore",
				detached: true,
			});
			const subPid = sub.pid!;
			const deadline = Date.now() + 3000;
			while (Date.now() < deadline) {
				if (existsSync(subLog) && readFileSync(subLog, "utf8").includes("[pi-sub-drain-malformed]")) break;
				await sleep(50);
			}
			try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
			try { process.kill(subPid, "SIGTERM"); } catch { /* */ }
			const logBody = existsSync(subLog) ? readFileSync(subLog, "utf8") : "";
			expect(logBody).toContain("[pi-sub-drain-malformed]");
			expect(logBody).toContain("no bridge");
			const wake = existsSync(wakeLog) ? readFileSync(wakeLog, "utf8").split("\n").filter(Boolean) : [];
			expect(wake.length).toBe(0);
		} finally {
			try { fakeParent.kill("SIGKILL"); } catch { /* */ }
			await sleep(50);
		}
	});

	// Round-1 reviewer-arch major (#37): race fix. A question opened
	// between the initial drain and the moment the stream connection
	// registers with the bridge must still land. Stub `pi-bridge
	// questions` so the first call (initial drain) returns empty and
	// the second call (re-drain triggered by bridge_hello) returns
	// Q; stream emits bridge_hello only, never the live `opened`
	// event.
	test("question opened between drain and stream connect → re-drain catches it", async () => {
		const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-race-"));
		stateDirs.push(stateDir);
		const wakeLog = join(stateDir, "wake-events.log");
		const subLog = join(stateDir, "daemon.log.pi-sub-47");
		const bridgeDir = join(stateDir, "bin");
		mkdirSync(bridgeDir, { recursive: true });
		const bridgeBin = join(bridgeDir, "pi-bridge");
		const counter = join(stateDir, "q-call-count");
		const bridgeScript = `#!/usr/bin/env bash
if [[ "\${1:-}" == "questions" ]]; then
  n=0
  if [[ -f "${counter}" ]]; then n=\$(cat "${counter}"); fi
  printf '%s' "\$((n+1))" > "${counter}"
  if (( n == 0 )); then
    echo '{"type":"response","id":1,"command":"questions","success":true,"data":{"available":true,"questions":[]}}'
  else
    cat <<'JSON'
{"type":"response","id":1,"command":"questions","success":true,"data":{"available":true,"questions":[{"requestId":"que_race_1","openedAt":"2026-05-13T00:00:00Z","request":{"id":"que_race_1","header":"H","questions":[{"header":"H","question":"Q?","options":[{"label":"yes"}]}]}}]}}
JSON
  fi
  exit 0
fi
if [[ "\${1:-}" == "stream" ]]; then
  echo '{"type":"bridge_hello","protocol":"pi-session-bridge.v1"}'
  sleep 30
fi
exit 0
`;
		writeFileSync(bridgeBin, bridgeScript);
		chmodSync(bridgeBin, 0o755);
		const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
		const parentPid = fakeParent.pid!;
		try {
			const env = subscriberEnv(bridgeDir, stateDir);
			const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%47", "99999", "", String(parentPid)], {
				env,
				stdio: "ignore",
				detached: true,
			});
			const subPid = sub.pid!;
			const deadline = Date.now() + 5000;
			let lines: string[] = [];
			while (Date.now() < deadline) {
				if (existsSync(wakeLog)) {
					lines = readFileSync(wakeLog, "utf8").split("\n").filter(Boolean);
					if (lines.length > 0) break;
				}
				await sleep(100);
			}
			try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
			try { process.kill(subPid, "SIGTERM"); } catch { /* */ }
			expect(lines.length).toBe(1);
			const ev = JSON.parse(lines[0]!);
			expect(ev.request_id).toBe("que_race_1");
			expect(ev.classifier_tag).toBe("pi-question");
			const logBody = existsSync(subLog) ? readFileSync(subLog, "utf8") : "";
			expect(logBody).toContain("[pi-sub-stream-connected]");
			// Initial drain (n=0) emitted no row; re-drain (n=1) did.
			expect(readFileSync(counter, "utf8")).toBe("2");
		} finally {
			try { fakeParent.kill("SIGKILL"); } catch { /* */ }
			await sleep(50);
		}
	});

	// Dedupe guarantee: re-drain and the live `question opened` event
	// both see the same id; only one wake row is written.
	test("re-drain and live stream both see the same question → single wake row", async () => {
		const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-race-dedupe-"));
		stateDirs.push(stateDir);
		const wakeLog = join(stateDir, "wake-events.log");
		const bridgeDir = join(stateDir, "bin");
		mkdirSync(bridgeDir, { recursive: true });
		const bridgeBin = join(bridgeDir, "pi-bridge");
		const bridgeScript = `#!/usr/bin/env bash
if [[ "\${1:-}" == "questions" ]]; then
  # Both drain calls return the same open question, so the re-drain
  # would attempt to re-emit it without dedup. seen_qids must skip.
  cat <<'JSON'
{"type":"response","id":1,"command":"questions","success":true,"data":{"available":true,"questions":[{"requestId":"que_dedupe_1","openedAt":"2026-05-13T00:00:00Z","request":{"id":"que_dedupe_1","header":"H","questions":[{"header":"H","question":"Q?","options":[{"label":"y"}]}]}}]}}
JSON
  exit 0
fi
if [[ "\${1:-}" == "stream" ]]; then
  echo '{"type":"bridge_hello","protocol":"pi-session-bridge.v1"}'
  # Live event for the same id; must be deduped by seen_qids.
  echo '{"type":"event","event":"question","data":{"action":"opened","requestId":"que_dedupe_1","request":{"id":"que_dedupe_1","header":"H","questions":[]}}}'
  sleep 30
fi
exit 0
`;
		writeFileSync(bridgeBin, bridgeScript);
		chmodSync(bridgeBin, 0o755);
		const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
		const parentPid = fakeParent.pid!;
		try {
			const env = subscriberEnv(bridgeDir, stateDir);
			const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%48", "99999", "", String(parentPid)], {
				env,
				stdio: "ignore",
				detached: true,
			});
			const subPid = sub.pid!;
			// Wait long enough for any duplicate emission to land.
			await sleep(1500);
			try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
			try { process.kill(subPid, "SIGTERM"); } catch { /* */ }
			const lines = existsSync(wakeLog)
				? readFileSync(wakeLog, "utf8").split("\n").filter(Boolean)
				: [];
			expect(lines.length).toBe(1);
			const ev = JSON.parse(lines[0]!);
			expect(ev.request_id).toBe("que_dedupe_1");
		} finally {
			try { fakeParent.kill("SIGKILL"); } catch { /* */ }
			await sleep(50);
		}
	});

	test("empty questions response yields no wake row", async () => {
		const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-drain-empty-"));
		stateDirs.push(stateDir);
		const wakeLog = join(stateDir, "wake-events.log");
		const bridgeDir = join(stateDir, "bin");
		mkdirSync(bridgeDir, { recursive: true });
		const bridgeBin = join(bridgeDir, "pi-bridge");
		const bridgeScript = `#!/usr/bin/env bash
if [[ "\${1:-}" == "questions" ]]; then
  echo '{"type":"response","id":1,"command":"questions","success":true,"data":{"available":true,"questions":[]}}'
  exit 0
fi
if [[ "\${1:-}" == "stream" ]]; then
  sleep 30
fi
exit 0
`;
		writeFileSync(bridgeBin, bridgeScript);
		chmodSync(bridgeBin, 0o755);

		const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
		const parentPid = fakeParent.pid!;
		try {
			const env = subscriberEnv(bridgeDir, stateDir);
			const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%43", "99999", "", String(parentPid)], {
				env,
				stdio: "ignore",
				detached: true,
			});
			const subPid = sub.pid!;
			await sleep(800);
			try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
			try { process.kill(subPid, "SIGTERM"); } catch { /* */ }
			const lines = existsSync(wakeLog)
				? readFileSync(wakeLog, "utf8").split("\n").filter(Boolean)
				: [];
			expect(lines.length).toBe(0);
		} finally {
			try { fakeParent.kill("SIGKILL"); } catch { /* */ }
			await sleep(50);
		}
	});
});

// Compile-time use of pidAlive helper to avoid unused-import warnings in
// future refactors. The runtime tests above intentionally don't poll the
// fake parent's liveness since the watchdog isn't under test here.
void pidAlive;
