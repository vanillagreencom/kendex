// flightdeck-daemon CLI behavior — no-daemon paths + tmux gating.

import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, "../../../../scripts/flightdeck-daemon");

if (!process.env.TMUX) {
	test.skip("flightdeck-daemon tests require tmux", () => undefined);
}

function run(args: string[]): { stdout: string; stderr: string; status: number | null } {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	const r = spawnSync(SCRIPT, args, { encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

const SESSION = process.env.TMUX_PARITY_SESSION ?? sessionName();

function sessionName(): string {
	const r = spawnSync("tmux", ["display-message", "-p", "#S"], { encoding: "utf8" });
	return (r.stdout ?? "").trim();
}

describe("flightdeck-daemon (no-daemon paths)", () => {
	test("status: no daemon → exit 1", () => {
		const r = run(["status", "--session", "NO-SUCH-SESSION"]);
		expect(r.status).toBe(1);
		expect(r.stdout).toContain("no daemon");
	});

	test("find-window: unresolved session → exit 1", () => {
		const r = run(["find-window", "--session", "NO-SUCH-SESSION"]);
		expect(r.status).toBe(1);
	});

	test("health: no daemon → exit 1", () => {
		const r = run(["health", "--session", "NO-SUCH-SESSION"]);
		expect(r.status).toBe(1);
	});

	test("stop: no daemon → exit 1", () => {
		const r = run(["stop", "--session", "NO-SUCH-SESSION"]);
		expect(r.status).toBe(1);
	});

	test("missing --session → exit 2", () => {
		const r = run(["status"]);
		expect(r.status).toBe(2);
	});

	test("unknown action → exit 2", () => {
		const r = run(["bogus", "--session", SESSION]);
		expect(r.status).toBe(2);
	});

	test("ack --session s999999 → no-daemon path without tmux preflight", () => {
		// Session-key form (sN) doesn't need tmux. Should return cleanly.
		const r = run(["ack", "--session", "s999999"]);
		expect(r.status).toBe(0);
		expect(r.stdout).toBe("");
	});
});

describe("flightdeck-daemon preflight (tmux gating)", () => {
	function sandboxPathWithout(exclude: string[]): string {
		const { mkdtempSync, mkdirSync, symlinkSync, readdirSync } = require("node:fs") as typeof import("node:fs");
		const { tmpdir } = require("node:os") as typeof import("node:os");
		const { join } = require("node:path") as typeof import("node:path");
		const dir = mkdtempSync(join(tmpdir(), "fd-preflight-"));
		const binDir = join(dir, "bin");
		mkdirSync(binDir);
		for (const pathDir of (process.env.PATH ?? "").split(":")) {
			if (!pathDir) continue;
			let entries: string[];
			try { entries = readdirSync(pathDir); } catch { continue; }
			for (const entry of entries) {
				if (exclude.includes(entry)) continue;
				const dst = join(binDir, entry);
				try { symlinkSync(join(pathDir, entry), dst); } catch { /* skip dupes */ }
			}
		}
		return binDir;
	}

	test("status --session <name> with tmux missing → exit 2", () => {
		const path = sandboxPathWithout(["tmux"]);
		const env = { ...(process.env as Record<string, string>), PATH: path } as Record<string, string>;
		delete (env as Record<string, string | undefined>).TMUX;
		const r = spawnSync(SCRIPT, ["status", "--session", "some-name"], { encoding: "utf8", env });
		expect(r.status).toBe(2);
	});

	test("ack --session s999999 with tmux missing → not gated on tmux", () => {
		// Session-key form (sN) means we don't need tmux. Preflight
		// should pass and the ack should succeed (empty output, exit 0).
		const path = sandboxPathWithout(["tmux"]);
		const env = { ...(process.env as Record<string, string>), PATH: path } as Record<string, string>;
		delete (env as Record<string, string | undefined>).TMUX;
		const r = spawnSync(SCRIPT, ["ack", "--session", "s999999"], { encoding: "utf8", env });
		expect(r.status).not.toBe(2);
	});
});

// vstack#216 (pre-PR round-1 follow-up): `health` reads
// fd-daemon-<sessionKey>.subscribers.json and renders per-pane
// `subscriber_status` lines. The daemon writes the snapshot every
// heartbeat; we forge one here so the CLI test doesn't have to start a
// real daemon. The pid file uses process.pid so cmdHealth's pidAlive
// check succeeds without spawning anything else.
describe("flightdeck-daemon health subscriber_status rendering (vstack#216)", () => {
	const stateDirs: string[] = [];
	afterEach(() => {
		for (const dir of stateDirs) rmSync(dir, { recursive: true, force: true });
		stateDirs.length = 0;
	});

	function runHealthWithSnapshot(snapshot: object | null): { stdout: string; stderr: string; status: number | null } {
		const dir = mkdtempSync(join(tmpdir(), "fd-health-"));
		stateDirs.push(dir);
		// Resolve the running tmux session id so cmdHealth's resolveSessionId
		// returns a real sessionKey (we already gate the suite on TMUX env).
		const sid = (spawnSync("tmux", ["display-message", "-p", "#{session_id}"], { encoding: "utf8" }).stdout ?? "").trim();
		const sname = (spawnSync("tmux", ["display-message", "-p", "#S"], { encoding: "utf8" }).stdout ?? "").trim();
		const sessionKey = `s${sid.replace(/^\$/, "")}`;
		const pidFile = join(dir, `fd-daemon-${sessionKey}.pid`);
		const snapFile = join(dir, `fd-daemon-${sessionKey}.subscribers.json`);
		writeFileSync(pidFile, `${process.pid}\n`);
		if (snapshot !== null) writeFileSync(snapFile, JSON.stringify(snapshot, null, 2));
		const env = { ...(process.env as Record<string, string>), FD_STATE_DIR: dir };
		const r = spawnSync(SCRIPT, ["health", "--session", sname], { encoding: "utf8", env });
		return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
	}

	test("renders one row per pane with status/harness/subscriber_pid", () => {
		const snapshot = {
			session_id: "$0",
			session_key: "sX",
			daemon_pid: 1,
			updated_at_epoch: Math.floor(Date.now() / 1000),
			panes: [
				{ pane_id: "%101", harness: "claude", status: "bound", subscriber_pid: 99001, consecutive_bind_skips: 0, last_bind_skip_reason: null },
				{ pane_id: "%102", harness: "opencode", status: "skipped", subscriber_pid: null, consecutive_bind_skips: 4, last_bind_skip_reason: "missing-oc-attach-meta" },
				{ pane_id: "%103", harness: "codex", status: "stuck", subscriber_pid: null, consecutive_bind_skips: 13, last_bind_skip_reason: "missing-cx-bridge-meta" },
			],
		};
		const r = runHealthWithSnapshot(snapshot);
		expect(r.status).toBe(0);
		expect(r.stdout).toContain("subscriber_status snapshot_age=");
		expect(r.stdout).toContain("bound=1 skipped=1 stuck=1 dead=0");
		expect(r.stdout).toContain("pane=%101 harness=claude status=bound subscriber_pid=99001");
		expect(r.stdout).toContain("pane=%102 harness=opencode status=skipped consecutive_bind_skips=4 reason=missing-oc-attach-meta");
		expect(r.stdout).toContain("pane=%103 harness=codex status=stuck consecutive_bind_skips=13 reason=missing-cx-bridge-meta");
	});

	test("reports `(missing — daemon hasn't written snapshot yet)` when snapshot file is absent", () => {
		const r = runHealthWithSnapshot(null);
		expect(r.status).toBe(0);
		expect(r.stdout).toContain("subscriber_status=(missing");
	});

	test("reports `(no inner panes registered)` when daemon wrote an empty pane list", () => {
		const r = runHealthWithSnapshot({
			session_id: "$0",
			session_key: "sX",
			daemon_pid: 1,
			updated_at_epoch: Math.floor(Date.now() / 1000),
			panes: [],
		});
		expect(r.status).toBe(0);
		expect(r.stdout).toContain("subscriber_status=(no inner panes registered)");
	});
});
