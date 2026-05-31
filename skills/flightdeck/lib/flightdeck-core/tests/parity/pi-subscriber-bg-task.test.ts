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
const PROMPT_CLASSIFY = resolve(HERE, "../../src/bin/prompt-classify.ts");

function sleep(ms: number): Promise<void> { return new Promise((res) => setTimeout(res, ms)); }
function shQuote(value: string): string { return `'${value.replace(/'/g, `'\\''`)}'`; }

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

describe("Pi subscriber connect metadata", () => {
	test("emits connected pi session id when daemon supplies expected session", async () => {
		const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-connect-"));
		stateDirs.push(stateDir);
		const wakeLog = join(stateDir, "wake-events.log");
		const log = join(stateDir, "daemon.log");
		const bridgeDir = join(stateDir, "bin");
		mkdirSync(bridgeDir, { recursive: true });
		const bridgeBin = join(bridgeDir, "pi-bridge");
		writeFileSync(bridgeBin, `#!/usr/bin/env bash
if [[ "\${1:-}" == "state" ]]; then
  echo '{"data":{"protocol":"pi-session-bridge.v1","sessionId":"pi-new","socketPath":"/tmp/pi-new.sock"}}'
  exit 0
fi
if [[ "\${1:-}" == "questions" ]]; then
  echo '{"success":true,"data":{"questions":[]}}'
  exit 0
fi
if [[ "\${1:-}" == "stream" ]]; then
  echo '{"type":"bridge_hello","protocol":"pi-session-bridge.v1","state":{"sessionId":"pi-new","socketPath":"/tmp/pi-new.sock"}}'
  sleep 30
fi
exit 0
`);
		chmodSync(bridgeBin, 0o755);

		const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
		const parentPid = fakeParent.pid!;
		try {
			const env = subscriberEnv(bridgeDir, stateDir);
			const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%1312", "2169938", "/tmp/pi-new.sock", String(parentPid), "pi-new"], {
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

			expect(lines.length).toBeGreaterThanOrEqual(1);
			const ev = JSON.parse(lines.find((line) => line.includes('"classifier_tag":"pi-session-connected"'))!);
			expect(ev.pane_id).toBe("%1312");
			expect(ev.classifier_tag).toBe("pi-session-connected");
			expect(ev.event_type).toBe("pi_session_connected");
			expect(ev.pi_session_id).toBe("pi-new");
			expect(ev.expected_pi_session_id).toBe("pi-new");
			expect(ev.pi_pid).toBe("2169938");
			expect(ev.pi_socket).toBe("/tmp/pi-new.sock");
			expect(ev.hash).toMatch(/^[0-9a-f]{12}$/);
			const subLog = readFileSync(`${log}.pi-sub-1312`, "utf8");
			expect(subLog).toContain("pi_session_id=pi-new");
		} finally {
			try { fakeParent.kill("SIGKILL"); } catch { /* */ }
			await sleep(50);
		}
	});

	test("state preflight timeout fails open to stream attach", async () => {
		const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-state-timeout-"));
		stateDirs.push(stateDir);
		const wakeLog = join(stateDir, "wake-events.log");
		const log = join(stateDir, "daemon.log");
		const bridgeDir = join(stateDir, "bin");
		mkdirSync(bridgeDir, { recursive: true });
		const bridgeBin = join(bridgeDir, "pi-bridge");
		writeFileSync(bridgeBin, `#!/usr/bin/env bash
if [[ "\${1:-}" == "state" ]]; then
  sleep 30
  exit 0
fi
if [[ "\${1:-}" == "questions" ]]; then
  echo '{"success":true,"data":{"questions":[]}}'
  exit 0
fi
if [[ "\${1:-}" == "stream" ]]; then
  echo '{"type":"bridge_hello","protocol":"pi-session-bridge.v1","state":{"sessionId":"pi-new","socketPath":"/tmp/pi-new.sock"}}'
  sleep 30
fi
exit 0
`);
		chmodSync(bridgeBin, 0o755);

		const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
		const parentPid = fakeParent.pid!;
		let subPid = 0;
		try {
			const env = subscriberEnv(bridgeDir, stateDir, { FD_ADAPTER_READ_TIMEOUT_SEC: "1" });
			const started = Date.now();
			const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%1313", "2169939", "/tmp/pi-new.sock", String(parentPid), "pi-new"], {
				env,
				stdio: "ignore",
				detached: true,
			});
			subPid = sub.pid!;

			let lines: string[] = [];
			const deadline = Date.now() + 8000;
			while (Date.now() < deadline) {
				if (existsSync(wakeLog)) {
					lines = readFileSync(wakeLog, "utf8").split("\n").filter(Boolean);
					if (lines.some((line) => line.includes('"classifier_tag":"pi-session-connected"'))) break;
				}
				await sleep(100);
			}

			expect(Date.now() - started).toBeLessThan(5000);
			expect(lines.length).toBeGreaterThan(0);
			const ev = JSON.parse(lines.find((line) => line.includes('"classifier_tag":"pi-session-connected"'))!);
			expect(ev.pi_session_id).toBe("pi-new");
			expect(ev.expected_pi_session_id).toBe("pi-new");
			const subLog = readFileSync(`${log}.pi-sub-1313`, "utf8");
			expect(subLog).toContain("[pi-sub-session-preflight-error]");
			expect(subLog).toContain("rc=124");
			expect(subLog).toContain("expected_session=pi-new");
			expect(subLog).toContain("[pi-sub-stream-connected]");
		} finally {
			if (subPid) {
				try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
				try { process.kill(subPid, "SIGTERM"); } catch { /* */ }
			}
			try { fakeParent.kill("SIGKILL"); } catch { /* */ }
			await sleep(50);
		}
	});

	test("malformed state preflight fails open to stream attach", async () => {
		const cases = [
			{ pane: "%1314", safe: "1314", body: "not-json", expect: "excerpt=not-json" },
			{ pane: "%1315", safe: "1315", body: '{"data":{"protocol":"pi-session-bridge.v1"}}', expect: "reason=missing-session" },
		];
		for (const c of cases) {
			const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-state-malformed-"));
			stateDirs.push(stateDir);
			const wakeLog = join(stateDir, "wake-events.log");
			const log = join(stateDir, "daemon.log");
			const bridgeDir = join(stateDir, "bin");
			mkdirSync(bridgeDir, { recursive: true });
			const bridgeBin = join(bridgeDir, "pi-bridge");
			writeFileSync(bridgeBin, `#!/usr/bin/env bash
if [[ "\${1:-}" == "state" ]]; then
cat <<'STATE'
${c.body}
STATE
  exit 0
fi
if [[ "\${1:-}" == "questions" ]]; then
  echo '{"success":true,"data":{"questions":[]}}'
  exit 0
fi
if [[ "\${1:-}" == "stream" ]]; then
  echo '{"type":"bridge_hello","protocol":"pi-session-bridge.v1","state":{"sessionId":"pi-new","socketPath":"/tmp/pi-new.sock"}}'
  sleep 30
fi
exit 0
`);
			chmodSync(bridgeBin, 0o755);

			const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
			const parentPid = fakeParent.pid!;
			let subPid = 0;
			try {
				const env = subscriberEnv(bridgeDir, stateDir);
				const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", c.pane, "2169940", "/tmp/pi-new.sock", String(parentPid), "pi-new"], {
					env,
					stdio: "ignore",
					detached: true,
				});
				subPid = sub.pid!;

				let lines: string[] = [];
				const deadline = Date.now() + 8000;
				while (Date.now() < deadline) {
					if (existsSync(wakeLog)) {
						lines = readFileSync(wakeLog, "utf8").split("\n").filter(Boolean);
						if (lines.some((line) => line.includes('"classifier_tag":"pi-session-connected"'))) break;
					}
					await sleep(100);
				}

				expect(lines.length).toBeGreaterThan(0);
				const ev = JSON.parse(lines.find((line) => line.includes('"classifier_tag":"pi-session-connected"'))!);
				expect(ev.pi_session_id).toBe("pi-new");
				expect(ev.expected_pi_session_id).toBe("pi-new");
				const subLog = readFileSync(`${log}.pi-sub-${c.safe}`, "utf8");
				expect(subLog).toContain("[pi-sub-session-preflight-malformed]");
				expect(subLog).toContain(c.expect);
				expect(subLog).toContain("[pi-sub-stream-connected]");
				expect(subLog).not.toContain("phase=preflight; exiting before drain");
			} finally {
				if (subPid) {
					try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
					try { process.kill(subPid, "SIGTERM"); } catch { /* */ }
				}
				try { fakeParent.kill("SIGKILL"); } catch { /* */ }
				await sleep(50);
			}
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
{"type":"event","event":"message_end","data":{"message":{"role":"system","customType":"vstack-background-tasks:event","details":{"eventType":"exit","sequence":17,"task":{"id":"bg-3","status":"failed","exitCode":null,"command":"bot-review-wait 81","outputBytes":89,"notifyOnExit":true,"notifyOnOutput":false,"exitNotified":true}}}}}
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
			expect(ev.sequence).toBe(17);
			expect(ev.hash).toMatch(/^[0-9a-f]{12}$/);
		} finally {
			try { fakeParent.kill("SIGKILL"); } catch { /* */ }
			await sleep(50);
		}
	});

	describe("pre-PR sentinel adapter classification (vstack#282)", () => {
		const marker = "PRE-PR-REVIEW-READY: tmp/ready-for-review.txt";

		async function runMarkerCase(entryKind: string, paneId: string): Promise<Record<string, any>> {
			const safePane = paneId.replace(/[^A-Za-z0-9_-]/g, "");
			const stateDir = mkdtempSync(join(tmpdir(), `fd-pi-pre-pr-${entryKind}-`));
			stateDirs.push(stateDir);
			const wakeLog = join(stateDir, "wake-events.log");
			const bridgeDir = join(stateDir, "bin");
			mkdirSync(bridgeDir, { recursive: true });
			const bridgeBin = join(bridgeDir, "pi-bridge");
			const bridgeScript = `#!/usr/bin/env bash
case "\${1:-}" in
  questions)
    echo '{"success":true,"data":{"questions":[]}}'
    ;;
  state)
    echo '{"data":{"isIdle":false,"hasPendingMessages":false}}'
    ;;
  stream)
    cat <<'JSON'
{"type":"event","event":"agent_end","data":{"message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"${marker}"}]}}}
JSON
    sleep 30
    ;;
esac
`;
			writeFileSync(bridgeBin, bridgeScript);
			chmodSync(bridgeBin, 0o755);
			const classifierBin = join(bridgeDir, "prompt-classify-wrapper");
			writeFileSync(classifierBin, `#!/usr/bin/env bash
exec ${shQuote(process.execPath)} ${shQuote(PROMPT_CLASSIFY)} "$@"
`);
			chmodSync(classifierBin, 0o755);

			const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
			const parentPid = fakeParent.pid!;
			let subPid = 0;
			try {
				const env = subscriberEnv(bridgeDir, stateDir, {
					CLASSIFIER: classifierBin,
					FD_ENTRY_HARNESS: "pi",
					FD_ENTRY_KIND: entryKind,
				});
				const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", paneId, "1184282", "", String(parentPid)], {
					env,
					stdio: "ignore",
					detached: true,
				});
				subPid = sub.pid!;

				const deadline = Date.now() + 8000;
				let rows: any[] = [];
				while (Date.now() < deadline) {
					if (existsSync(wakeLog)) {
						rows = readFileSync(wakeLog, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
						if (rows.some((row) => row.last_assistant_text === marker)) break;
					}
					await sleep(100);
				}

				try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
				try { process.kill(subPid, "SIGTERM"); } catch { /* */ }

				const ev = rows.find((row) => row.last_assistant_text === marker);
				expect(ev).toBeTruthy();
				expect(ev.pane_id).toBe(paneId);
				expect(ev.harness).toBe("pi");
				expect(ev.entry_kind).toBe(entryKind);
				expect(ev.entry_harness).toBe("pi");
				expect(ev.hash).toMatch(/^[0-9a-f]{12}$/);
				const subLog = readFileSync(join(stateDir, `daemon.log.pi-sub-${safePane}`), "utf8");
				expect(subLog).toContain(`entry_kind=${entryKind}`);
				expect(subLog).not.toContain("[classifier-error]");
				if (entryKind === "adhoc") expect(subLog).toContain("[classifier-warn]");
				return ev;
			} finally {
				if (subPid) {
					try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
					try { process.kill(subPid, "SIGTERM"); } catch { /* */ }
				}
				try { fakeParent.kill("SIGKILL"); } catch { /* */ }
				await sleep(50);
			}
		}

		test("issue agent_end marker routes to pre-pr-ready-for-review", async () => {
			const ev = await runMarkerCase("issue", "%282");
			expect(ev.classifier_tag).toBe("pre-pr-ready-for-review");
		});

		test("non-issue agent_end marker remains domain-mismatch", async () => {
			const ev = await runMarkerCase("adhoc", "%283");
			expect(ev.classifier_tag).toBe("domain-mismatch");
		});

		test("classifier failures log context and degrade to rendering", async () => {
			const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-classifier-error-"));
			stateDirs.push(stateDir);
			const wakeLog = join(stateDir, "wake-events.log");
			const bridgeDir = join(stateDir, "bin");
			mkdirSync(bridgeDir, { recursive: true });
			const bridgeBin = join(bridgeDir, "pi-bridge");
			writeFileSync(bridgeBin, `#!/usr/bin/env bash
case "\${1:-}" in
  questions) echo '{"success":true,"data":{"questions":[]}}' ;;
  stream)
    echo '{"type":"event","event":"agent_end","data":{"message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"done"}]}}}'
    sleep 30
    ;;
esac
`);
			chmodSync(bridgeBin, 0o755);
			const classifierBin = join(bridgeDir, "bad-classifier");
			writeFileSync(classifierBin, `#!/usr/bin/env bash
echo 'classifier exploded' >&2
exit 7
`);
			chmodSync(classifierBin, 0o755);

			const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
			const parentPid = fakeParent.pid!;
			let subPid = 0;
			try {
				const env = subscriberEnv(bridgeDir, stateDir, {
					CLASSIFIER: classifierBin,
					FD_ENTRY_HARNESS: "pi",
					FD_ENTRY_KIND: "issue",
				});
				const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%284", "1184283", "", String(parentPid)], {
					env,
					stdio: "ignore",
					detached: true,
				});
				subPid = sub.pid!;

				const deadline = Date.now() + 8000;
				let rows: any[] = [];
				while (Date.now() < deadline) {
					if (existsSync(wakeLog)) {
						rows = readFileSync(wakeLog, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
						if (rows.some((row) => row.last_assistant_text === "done")) break;
					}
					await sleep(100);
				}

				const ev = rows.find((row) => row.last_assistant_text === "done");
				expect(ev).toBeTruthy();
				expect(ev.classifier_tag).toBe("rendering");
				const subLog = readFileSync(join(stateDir, "daemon.log.pi-sub-284"), "utf8");
				expect(subLog).toContain("[classifier-error]");
				expect(subLog).toContain("pane=%284");
				expect(subLog).toContain("rc=7");
				expect(subLog).toContain("entry_kind=issue");
				expect(subLog).toContain("classifier exploded");
			} finally {
				if (subPid) {
					try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
					try { process.kill(subPid, "SIGTERM"); } catch { /* */ }
				}
				try { fakeParent.kill("SIGKILL"); } catch { /* */ }
				await sleep(50);
			}
		});
	});


	test("workflow terminal-state accepts wrapped pi-bridge state in bash subscriber", async () => {
		const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-terminal-wrapper-"));
		stateDirs.push(stateDir);
		const wakeLog = join(stateDir, "wake-events.log");
		const bridgeDir = join(stateDir, "bin");
		mkdirSync(bridgeDir, { recursive: true });
		const bridgeBin = join(bridgeDir, "pi-bridge");
		const bridgeScript = `#!/usr/bin/env bash
case "\${1:-}" in
  questions)
    echo '{"success":true,"data":{"questions":[]}}'
    ;;
  state)
    echo '{"data":{"isIdle":true,"hasPendingMessages":false}}'
    ;;
  stream)
    cat <<'JSON'
{"type":"event","event":"message_end","data":{"message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"workflow done"}]}}}
JSON
    sleep 30
    ;;
esac
`;
		writeFileSync(bridgeBin, bridgeScript);
		chmodSync(bridgeBin, 0o755);

		const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
		const parentPid = fakeParent.pid!;
		try {
			const env = subscriberEnv(bridgeDir, stateDir, { FD_ENTRY_KIND: "workflow", FD_ENTRY_HARNESS: "pi" });
			const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%20", "1184234", "", String(parentPid)], {
				env,
				stdio: "ignore",
				detached: true,
			});
			const subPid = sub.pid!;
			const deadline = Date.now() + 8000;
			let rows: any[] = [];
			while (Date.now() < deadline) {
				if (existsSync(wakeLog)) {
					rows = readFileSync(wakeLog, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
					if (rows.some((row) => row.classifier_tag === "terminal-state-reached")) break;
				}
				await sleep(100);
			}

			try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
			try { process.kill(subPid, "SIGTERM"); } catch { /* */ }

			const ev = rows.find((row) => row.classifier_tag === "terminal-state-reached");
			expect(ev).toBeTruthy();
			expect(ev.pane_id).toBe("%20");
			expect(ev.harness).toBe("pi");
			expect(ev.last_assistant_text).toBe("");
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
{"type":"event","event":"message_end","data":{"message":{"role":"system","customType":"vstack-background-tasks:event","details":{"eventType":"output","sequence":18,"task":{"id":"bg-3","status":"running","exitCode":null}}}}}
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
			const deadline = Date.now() + 3000;
			let lines: string[] = [];
			while (Date.now() < deadline) {
				if (existsSync(wakeLog)) {
					lines = readFileSync(wakeLog, "utf8").split("\n").filter(Boolean);
					if (lines.some((raw) => raw.includes("pi-bg-task-activity"))) break;
				}
				await sleep(50);
			}

			try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
			try { process.kill(subPid, "SIGTERM"); } catch { /* */ }

			expect(lines).toHaveLength(1);
			const ev = JSON.parse(lines[0]!);
			expect(ev.classifier_tag).toBe("pi-bg-task-activity");
			expect(ev.classifier_tag).not.toBe("pi-bg-task-exit");
			expect(ev.event_type).toBe("bg-task-activity");
			expect(ev.activity_event_type).toBe("output");
			expect(ev.task?.id).toBe("bg-3");
			expect(ev.sequence).toBe("18");
		} finally {
			try { fakeParent.kill("SIGKILL"); } catch { /* */ }
			await sleep(50);
		}
	});

	test("vstack_activity stream event emits activity-only wake row", async () => {
		const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-activity-"));
		stateDirs.push(stateDir);
		const wakeLog = join(stateDir, "wake-events.log");
		const bridgeDir = join(stateDir, "bin");
		mkdirSync(bridgeDir, { recursive: true });
		const bridgeBin = join(bridgeDir, "pi-bridge");
		const bridgeScript = `#!/usr/bin/env bash
if [[ "\${1:-}" != "stream" ]]; then exit 0; fi
cat <<'JSON'
{"type":"event","event":"vstack_activity","data":{"type":"agent.task_completed","source":"pi-agents","severity":"success","importance":"normal","summary":"agent task completed","refs":{"task_id":"task-7","agent":"rust"},"details":{"status":"completed"},"ts":"2026-05-16T00:00:00.000Z"}}
JSON
sleep 30
`;
		writeFileSync(bridgeBin, bridgeScript);
		chmodSync(bridgeBin, 0o755);

		const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
		const parentPid = fakeParent.pid!;
		try {
			const env = subscriberEnv(bridgeDir, stateDir);
			const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%19", "1184234", "", String(parentPid)], {
				env,
				stdio: "ignore",
				detached: true,
			});
			const subPid = sub.pid!;
			const deadline = Date.now() + 3000;
			let lines: string[] = [];
			while (Date.now() < deadline) {
				if (existsSync(wakeLog)) {
					lines = readFileSync(wakeLog, "utf8").split("\n").filter(Boolean);
					if (lines.some((raw) => raw.includes("pi-activity-broker"))) break;
				}
				await sleep(50);
			}

			try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
			try { process.kill(subPid, "SIGTERM"); } catch { /* */ }

			expect(lines).toHaveLength(1);
			const ev = JSON.parse(lines[0]!);
			expect(ev.classifier_tag).toBe("pi-activity-broker");
			expect(ev.event_type).toBe("vstack_activity");
			expect(ev.pane_id).toBe("%19");
			expect(ev.activity).toMatchObject({ source: "pi-agents", type: "agent.task_completed", refs: { task_id: "task-7", agent: "rust" } });
			expect(ev.hash).toMatch(/^[0-9a-f]{12}$/);
		} finally {
			try { fakeParent.kill("SIGKILL"); } catch { /* */ }
			await sleep(50);
		}
	});

	test("vstack_activity broker consumption can be disabled", async () => {
		const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-activity-off-"));
		stateDirs.push(stateDir);
		const wakeLog = join(stateDir, "wake-events.log");
		const bridgeDir = join(stateDir, "bin");
		mkdirSync(bridgeDir, { recursive: true });
		const bridgeBin = join(bridgeDir, "pi-bridge");
		const bridgeScript = `#!/usr/bin/env bash
if [[ "\${1:-}" != "stream" ]]; then exit 0; fi
cat <<'JSON'
{"type":"event","event":"vstack_activity","data":{"type":"agent.task_completed","source":"pi-agents","severity":"success","importance":"normal","summary":"agent task completed"}}
JSON
sleep 30
`;
		writeFileSync(bridgeBin, bridgeScript);
		chmodSync(bridgeBin, 0o755);

		const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
		const parentPid = fakeParent.pid!;
		try {
			const env = subscriberEnv(bridgeDir, stateDir, { FLIGHTDECK_PI_ACTIVITY_BROKER: "0" });
			const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%20", "1184234", "", String(parentPid)], {
				env,
				stdio: "ignore",
				detached: true,
			});
			const subPid = sub.pid!;
			await sleep(500);
			try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
			try { process.kill(subPid, "SIGTERM"); } catch { /* */ }
			expect(existsSync(wakeLog) ? readFileSync(wakeLog, "utf8").trim() : "").toBe("");
		} finally {
			try { fakeParent.kill("SIGKILL"); } catch { /* */ }
			await sleep(50);
		}
	});

	test("vstack_activity append failure logs error and stream loop continues", async () => {
		const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-activity-err-"));
		stateDirs.push(stateDir);
		const badWakeLog = join(stateDir, "wake-events-dir");
		mkdirSync(badWakeLog, { recursive: true });
		const subLog = join(stateDir, "daemon.log.pi-sub-21");
		const bridgeDir = join(stateDir, "bin");
		mkdirSync(bridgeDir, { recursive: true });
		const bridgeBin = join(bridgeDir, "pi-bridge");
		const bridgeScript = `#!/usr/bin/env bash
if [[ "\${1:-}" != "stream" ]]; then exit 0; fi
cat <<'JSON'
{"type":"event","event":"vstack_activity","data":{"type":"agent.task_started","source":"pi-agents","severity":"info","importance":"normal","summary":"agent task started","refs":{"task_id":"task-err"}}}
{"type":"event","event":"vstack_activity","data":{"type":"agent.task_completed","source":"pi-agents","severity":"success","importance":"normal","summary":"agent task completed","refs":{"task_id":"task-err"}}}
JSON
sleep 30
`;
		writeFileSync(bridgeBin, bridgeScript);
		chmodSync(bridgeBin, 0o755);

		const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
		const parentPid = fakeParent.pid!;
		try {
			const env = subscriberEnv(bridgeDir, stateDir, { WAKE_EVENTS_LOG: badWakeLog });
			const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%21", "1184234", "", String(parentPid)], {
				env,
				stdio: "ignore",
				detached: true,
			});
			const subPid = sub.pid!;
			const deadline = Date.now() + 3000;
			let logBody = "";
			while (Date.now() < deadline) {
				if (existsSync(subLog)) {
					logBody = readFileSync(subLog, "utf8");
					const errors = logBody.match(/\[pi-activity-broker-emit-error\]/g) ?? [];
					if (errors.length >= 2) break;
				}
				await sleep(50);
			}

			try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
			try { process.kill(subPid, "SIGTERM"); } catch { /* */ }

			const errors = logBody.match(/\[pi-activity-broker-emit-error\]/g) ?? [];
			expect(errors).toHaveLength(2);
			expect(logBody).toContain("type=agent.task_started");
			expect(logBody).toContain("type=agent.task_completed");
			expect(logBody).toContain("rc=");
			expect(logBody).toContain("error=");
		} finally {
			try { fakeParent.kill("SIGKILL"); } catch { /* */ }
			await sleep(50);
		}
	});

	test("rate-limit classifier rejections emit skipped activity rows and do not steer", async () => {
		const stateDir = mkdtempSync(join(tmpdir(), "fd-pi-rate-skip-"));
		stateDirs.push(stateDir);
		const wakeLog = join(stateDir, "wake-events.log");
		const sendLog = join(stateDir, "send.log");
		const bridgeDir = join(stateDir, "bin");
		mkdirSync(bridgeDir, { recursive: true });
		const bridgeBin = join(bridgeDir, "pi-bridge");
		const bridgeScript = `#!/usr/bin/env bash
case "\${1:-}" in
  questions)
    echo '{"success":true,"data":{"questions":[]}}'
    ;;
  send)
    printf '%s\n' "$*" >> "$SEND_LOG"
    ;;
  stream)
    cat <<'JSON'
{"type":"event","event":"message_end","data":{"message":{"role":"user","content":[{"type":"text","text":"API rate limit was detected. Try to continue from where you left off."}]}}}
{"type":"event","event":"message_end","data":{"message":{"role":"assistant","content":[{"type":"text","text":"Still working."}]}}}
{"type":"event","event":"message_end","data":{"message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"The API returned 429 last time but I retried and it worked."}]}}}
{"type":"event","event":"message_end","data":{"message":{"role":"assistant","stopReason":"error","errorMessage":"Tool execution failed","content":[{"type":"text","text":"Tool output attached below."}]}}}
JSON
    sleep 30
    ;;
esac
`;
		writeFileSync(bridgeBin, bridgeScript);
		chmodSync(bridgeBin, 0o755);

		const fakeParent = spawn("sleep", ["30"], { stdio: "ignore" });
		const parentPid = fakeParent.pid!;
		try {
			const env = subscriberEnv(bridgeDir, stateDir, { SEND_LOG: sendLog });
			const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%22", "1184234", "", String(parentPid)], {
				detached: true,
				env,
				stdio: "ignore",
			});
			const subPid = sub.pid!;
			const deadline = Date.now() + 8000;
			let rows: any[] = [];
			while (Date.now() < deadline) {
				if (existsSync(wakeLog)) {
					rows = readFileSync(wakeLog, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
					if (rows.filter((row) => row.classifier_tag === "pi-rate-limit-skipped").length >= 4) break;
				}
				await sleep(100);
			}

			try { process.kill(-subPid, "SIGTERM"); } catch { /* */ }
			try { process.kill(subPid, "SIGTERM"); } catch { /* */ }

			const skipped = rows.filter((row) => row.classifier_tag === "pi-rate-limit-skipped");
			expect(skipped).toHaveLength(4);
			expect(rows.filter((row) => row.classifier_tag === "rendering")).toHaveLength(3);
			expect(skipped.map((row) => row.classifier_tag)).toEqual([
				"pi-rate-limit-skipped",
				"pi-rate-limit-skipped",
				"pi-rate-limit-skipped",
				"pi-rate-limit-skipped",
			]);
			expect(skipped.map((row) => row.reason)).toEqual([
				"non-assistant",
				"no-stopreason",
				"stopreason-mismatch",
				"no-prose",
			]);
			expect(rows.some((row) => row.classifier_tag === "pi-rate-limit-retry")).toBe(false);
			expect(existsSync(sendLog) ? readFileSync(sendLog, "utf8") : "").toBe("");
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
