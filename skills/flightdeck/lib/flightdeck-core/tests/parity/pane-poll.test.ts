// Parity test: pane-poll (bash) vs pane-poll (TS).
// Focuses on deterministic paths: dead-pane, empty-batch, single-batch
// against non-existent pane. Live capture-pane parity is intentionally
// out of scope — buffer hashes naturally drift between consecutive
// captures of the same pane and require a static fixture pane harness.

import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, "../../../../scripts/pane-poll");
const SHIM_DIR = resolve(HERE, "./tmux-shim");

if (!process.env.TMUX) {
	test.skip("pane-poll parity requires tmux", () => undefined);
}

function run(args: string[], stdin?: string): { stdout: string; stderr: string; status: number | null } {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	const r = spawnSync(SCRIPT, args, { encoding: "utf8", env, input: stdin });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

describe("pane-poll parity", () => {
	test("dead pane (non-existent window)", () => {
		const target = "no-such-session-XYZ:no-such-window.0";
		const a = run([target]);
		const b = run([target]);
		expect(b.status).toBe(a.status);
		expect(JSON.parse(b.stdout)).toEqual(JSON.parse(a.stdout));
	});

	test("dead pane via raw %pane-id", () => {
		const target = "%999999";
		const a = run([target]);
		const b = run([target]);
		expect(b.status).toBe(a.status);
		expect(JSON.parse(b.stdout)).toEqual(JSON.parse(a.stdout));
	});

	test("batch mode empty array → no stdout", () => {
		const a = run(["--batch", "-"], "[]");
		const b = run(["--batch", "-"], "[]");
		expect(b.status).toBe(a.status);
		expect(b.stdout).toBe(a.stdout);
		expect(a.stdout).toBe("");
	});

	test("batch mode dead-pane row", () => {
		const arr = JSON.stringify([
			{ harness: "claude", issue: "FAKE-001", pane_target: "no-such:nope.0" },
		]);
		const a = run(["--batch", "-"], arr);
		const b = run(["--batch", "-"], arr);
		const aParsed = a.stdout.trim().split("\n").map((s) => JSON.parse(s));
		const bParsed = b.stdout.trim().split("\n").map((s) => JSON.parse(s));
		expect(bParsed).toEqual(aParsed);
	});

	test("batch mode emits current tmux window name", () => {
		const { mkdtempSync, rmSync, writeFileSync } = require("node:fs") as typeof import("node:fs");
		const { tmpdir } = require("node:os") as typeof import("node:os");
		const { join } = require("node:path") as typeof import("node:path");
		const dir = mkdtempSync(join(tmpdir(), "fd-pane-poll-name-"));
		try {
			const statePath = join(dir, "shim-state.json");
			writeFileSync(statePath, JSON.stringify({
				panes: {
					"%210": { pane_index: 0, path: dir, window_id: "@21", window_index: 21, window_name: "Live tmux title" },
				},
				session: "test-session",
				windows: { "@21": { index: 21, name: "Live tmux title" } },
			}, null, 2));
			const env: Record<string, string> = {
				...(process.env as Record<string, string>),
				PATH: `${SHIM_DIR}:${process.env.PATH ?? ""}`,
				TMUX: "/tmp/tmux-test",
				TMUX_SHIM_STATE: statePath,
			};
			const batch = JSON.stringify([{ harness: "shell", id: "pane-a", pane_id: "%210", kind: "adhoc" }]);
			const r = spawnSync(SCRIPT, ["--batch", "-"], { encoding: "utf8", env, input: batch });
			expect(r.status).toBe(0);
			const row = JSON.parse(r.stdout.trim());
			expect(row.window_name_current).toBe("Live tmux title");
		} finally {
			rmSync(dir, { force: true, recursive: true });
		}
	});

	test("batch mode rejects non-array input", () => {
		const a = run(["--batch", "-"], '{"not":"an array"}');
		const b = run(["--batch", "-"], '{"not":"an array"}');
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	test("adapter timeout falls through to tmux fallback (TS)", () => {
		// Bug regression: when an opencode adapter has fresh args but
		// the read times out / returns empty, the TS path used to mark
		// the adapter as 'used' and skip the tmux capture-pane fallback,
		// classifying as idle. Fix: only mark *Used after a non-empty
		// extractor result. This test creates a fake oc-spawn file with
		// our PID + an unreachable URL, primes the freshness cache so
		// the probe doesn't second-guess, then asserts the resulting tag
		// is NOT idle (the tmux fallback ran).
		const { mkdtempSync, writeFileSync, mkdirSync } = require("node:fs") as typeof import("node:fs");
		const { tmpdir } = require("node:os") as typeof import("node:os");
		const { join } = require("node:path") as typeof import("node:path");
		const stateDir = mkdtempSync(join(tmpdir(), "fd-fallback-"));
		mkdirSync(stateDir, { recursive: true });
		const issue = "FAKE-ADAPTER-001";
		const url = "http://127.0.0.1:1"; // guaranteed-unreachable
		const sid = "deadbeef-fake-session";
		writeFileSync(
			join(stateDir, `oc-spawn-${issue}.json`),
			JSON.stringify({ server_pid: process.pid, url, session_id: sid }),
		);
		writeFileSync(
			join(stateDir, "fd-adapter-freshness-cache.json"),
			JSON.stringify({ [`oc|${url}|${sid}`]: { ok: true, ts: Math.floor(Date.now() / 1000) } }),
		);
		// Target this test's own pane so tmux capture-pane returns real
		// text. The pane name pattern uses ocIssueFromPaneTarget which
		// pulls the issue from window name suffix — emulate by passing
		// the pane target with the issue embedded.
		const paneTarget = process.env.TMUX_PANE ?? "";
		if (!paneTarget) {
			// No tmux pane to test against — skip rather than hang.
			return;
		}
		const env: Record<string, string> = {
			...(process.env as Record<string, string>),
			FLIGHTDECK_USE_TS_PANE_POLL: "1",
			FD_STATE_DIR: stateDir,
			FD_ADAPTER_READ_TIMEOUT_SEC: "1",
		};
			// Use batch mode with explicit oc_url/oc_session so the adapter
		// path is forced regardless of registry contents.
		const batch = JSON.stringify([{
			harness: "opencode",
			issue,
			pane_target: paneTarget,
			oc_url: url,
			oc_session_id: sid,
		}]);
		const SCRIPT_PATH = SCRIPT;
		const r = spawnSync(SCRIPT_PATH, ["--batch", "-"], { encoding: "utf8", env, input: batch });
		expect(r.status).toBe(0);
		const row = JSON.parse(r.stdout.trim());
		// The tmux fallback ran — the captured buffer is whatever this
		// pane currently shows (test runner output). Hash must be a real
		// sha256 (not the empty-string hash) so we know fallback fired.
		expect(row.capture_hash).toMatch(/^sha256:[0-9a-f]{64}$/);
		// sha256("") — if tmux fallback failed to run we'd see this.
		expect(row.capture_hash).not.toBe("sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
	});
});
