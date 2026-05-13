// Parity test (vstack#15): the Pi subscriber must translate a
// `vstack-background-tasks:event` exit message into a canonical
// `pi-bg-task-exit` row in the wake-events log so the daemon can wake
// master even when the agent's own follow-up turn never lands.
//
// We stub `pi-bridge stream` with a tiny script on PATH that emits a
// canned JSONL exit event, run scripts/lib/subscribers.bash pi against
// it, and assert the canonical wake event appears.

import { afterAll, describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SUBSCRIBERS_BASH = resolve(HERE, "../../../../scripts/lib/subscribers.bash");

function sleep(ms: number): Promise<void> { return new Promise((res) => setTimeout(res, ms)); }
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
			const env: NodeJS.ProcessEnv = {
				...(process.env as NodeJS.ProcessEnv),
				PATH: `${bridgeDir}:${process.env.PATH ?? ""}`,
				FD_STATE_DIR: stateDir,
				SESSION_LOCK: sessionLock,
				WAKE_EVENTS_LOG: wakeLog,
				LOG: log,
				CLASSIFIER: "",
				PI_LAST_ASSISTANT_JQ: ".message.content // []",
			};
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
			const env: NodeJS.ProcessEnv = {
				...(process.env as NodeJS.ProcessEnv),
				PATH: `${bridgeDir}:${process.env.PATH ?? ""}`,
				FD_STATE_DIR: stateDir,
				SESSION_LOCK: sessionLock,
				WAKE_EVENTS_LOG: wakeLog,
				LOG: log,
				CLASSIFIER: "",
				PI_LAST_ASSISTANT_JQ: ".message.content // []",
			};
			const sub = spawn("bash", [SUBSCRIBERS_BASH, "pi", "%18", "1184234", "", String(parentPid)], {
				env,
				stdio: "ignore",
				detached: true,
			});
			const subPid = sub.pid!;
			await sleep(2000);

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

// Compile-time use of pidAlive helper to avoid unused-import warnings in
// future refactors. The runtime tests above intentionally don't poll the
// fake parent's liveness since the watchdog isn't under test here.
void pidAlive;
