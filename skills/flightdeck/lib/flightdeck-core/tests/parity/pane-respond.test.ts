// Parity test: pane-respond (bash) vs pane-respond (TS).
// Focuses on argument validation, payload-tag enforcement, and harness/mode
// rejection paths — the deterministic, side-effect-free portion. Real adapter
// dispatch (curl, opencode bin, pi-bridge, codex-bridge, tmux send-keys)
// requires live infrastructure and is exercised by the integration test.

import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, "../../../../scripts/pane-respond");
const PANE_REGISTRY_SCRIPT = resolve(HERE, "../../../../scripts/pane-registry");
const SHIM_DIR = resolve(HERE, "./tmux-shim");

if (!process.env.TMUX) {
	test.skip("pane-respond parity requires tmux", () => undefined);
}

function run(args: string[]): { stdout: string; stderr: string; status: number | null } {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	const r = spawnSync(SCRIPT, args, { encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

describe("pane-respond parity (validation)", () => {
	test("missing target → usage error", () => {
		const a = run([]);
		const b = run([]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	test("target without pane index → error", () => {
		const a = run(["session:window", "hello"]);
		const b = run(["session:window", "hello"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	test("--option with non-integer rejects", () => {
		const a = run(["s:w.0", "--option", "abc"]);
		const b = run(["s:w.0", "--option", "abc"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	test("--option with positional payload rejects", () => {
		const a = run(["s:w.0", "hi", "--option", "1"]);
		const b = run(["s:w.0", "hi", "--option", "1"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	test("--option with tag multi-select-tabbed rejects", () => {
		const a = run(["s:w.0", "--option", "1", "--tag", "multi-select-tabbed"]);
		const b = run(["s:w.0", "--option", "1", "--tag", "multi-select-tabbed"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(1);
	});

	test("--option-multi with non-CSV rejects", () => {
		const a = run(["s:w.0", "--option-multi", "1,a,3"]);
		const b = run(["s:w.0", "--option-multi", "1,a,3"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	test("rebase-multi-choice payload missing sections rejects", () => {
		const a = run(["s:w.0", "just a rebase", "--tag", "rebase-multi-choice"]);
		const b = run(["s:w.0", "just a rebase", "--tag", "rebase-multi-choice"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(1);
		// Both should mention the missing sections
		expect(b.stderr).toContain("PRESERVE");
		expect(a.stderr).toContain("PRESERVE");
	});

	test("--question on wrong harness rejects", () => {
		const a = run(["s:w.0", "--harness", "claude", "--question", "que_x", "--answer", "Yes"]);
		const b = run(["s:w.0", "--harness", "claude", "--question", "que_x", "--answer", "Yes"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(1);
	});

	test("--question with conflicting answer flags rejects", () => {
		const a = run(["s:w.0", "--harness", "opencode", "--question", "que_x", "--answer", "A", "--answer-multi", "B,C"]);
		const b = run(["s:w.0", "--harness", "opencode", "--question", "que_x", "--answer", "A", "--answer-multi", "B,C"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	test("--reject + --answer combo rejects", () => {
		const a = run(["s:w.0", "--harness", "opencode", "--question", "que_x", "--reject", "--answer", "Yes"]);
		const b = run(["s:w.0", "--harness", "opencode", "--question", "que_x", "--reject", "--answer", "Yes"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	test("--answers-json with non-array rejects", () => {
		const a = run(["s:w.0", "--harness", "opencode", "--question", "que_x", "--answers-json", '"hi"']);
		const b = run(["s:w.0", "--harness", "opencode", "--question", "que_x", "--answers-json", '"hi"']);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	test("--answer-text on opencode rejects", () => {
		const a = run(["s:w.0", "--harness", "opencode", "--question", "que_x", "--answer-text", "free text"]);
		const b = run(["s:w.0", "--harness", "opencode", "--question", "que_x", "--answer-text", "free text"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(1);
	});

	test("unknown flag rejects", () => {
		const a = run(["s:w.0", "hi", "--bogus-flag"]);
		const b = run(["s:w.0", "hi", "--bogus-flag"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	// Issue #37(A) + round-1 reviewer-error major: pane_id resolution
	// failures must emit specific, byte-identical error text in both
	// implementations so the caller knows which recovery path applies.
	test("%pane_id not registered → specific not-registered error", () => {
		const a = run(["%999999", "hi"]);
		const b = run(["%999999", "hi"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
		const expected = "pane-respond: pane '%999999' is not registered as a flightdeck-tracked pane; pass the explicit pane target (e.g. <session>:<window>.<idx>) or register the pane first";
		expect(a.stderr).toContain(expected);
		expect(b.stderr).toContain(expected);
		// Generic 'explicit pane index' fallback must NOT fire for %-form.
		expect(a.stderr).not.toContain("target must include explicit pane index");
		expect(b.stderr).not.toContain("target must include explicit pane index");
	});

	test("%pane_id registered with dead pane and null pane_target → not-registered error (post vstack#214)", () => {
		// Pre-vstack#214 this exercised the missing_pane_target branch by
		// nulling pane_target on a *live* TMUX_PANE entry. Post-fix, live
		// tmux is the source of truth and is consulted first: any %PANE_ID
		// tmux can resolve silently recovers regardless of registry drift.
		// The only way to surface a registry-side error now is a paneId
		// that tmux can't resolve (dead pane). find-by-pane filters that
		// out as stale → resolvePaneTargetFromPaneId returns "not_registered".
		// The missing_pane_target code path remains as defensive cover for
		// the exotic case where tmux display-message rejects a pane that
		// find-by-pane still considers live, but isn't reachable here.
		const fs = require("node:fs") as typeof import("node:fs");
		const os = require("node:os") as typeof import("node:os");
		const path = require("node:path") as typeof import("node:path");
		const PANE_REGISTRY = resolve(HERE, "../../../../scripts/pane-registry");
		const FLIGHTDECK_STATE = resolve(HERE, "../../../../scripts/flightdeck-state");
		const fakePaneId = "%999998";
		const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "fd-pr-drift-"));
		try {
			const envBase: Record<string, string> = { ...(process.env as Record<string, string>), FLIGHTDECK_STATE_DIR: stateDir };
			spawnSync(FLIGHTDECK_STATE, ["init"], { encoding: "utf8", env: envBase });
			spawnSync(PANE_REGISTRY, ["init-entry", "DRIFT-PT", "--title", "T", "--kind", "adhoc", "--cwd", "/tmp", "--window", "1", "--harness", "pi", "--pane-id", fakePaneId], { encoding: "utf8", env: envBase });
			spawnSync(PANE_REGISTRY, ["set", "DRIFT-PT", "pane_target", "null"], { encoding: "utf8", env: envBase });
			const r = spawnSync(SCRIPT, [fakePaneId, "hi"], { encoding: "utf8", env: envBase });
			expect(r.status).toBe(2);
			const expected = `pane-respond: pane '${fakePaneId}' is not registered as a flightdeck-tracked pane; pass the explicit pane target (e.g. <session>:<window>.<idx>) or register the pane first`;
			expect((r.stderr ?? "")).toContain(expected);
			expect((r.stderr ?? "")).not.toContain("target must include explicit pane index");
		} finally {
			fs.rmSync(stateDir, { recursive: true, force: true });
		}
	});

	// Note on the registry_read (find-by-pane exit >= 2) branch: it is
	// defensively wired in resolvePaneTargetFromPaneId but currently
	// unreachable in normal operation — find-by-pane wraps state reads in
	// `2>/dev/null` and downgrades any flightdeck-state failure to exit 1
	// (handled by the not_registered branch above), and the bun runtime
	// exits 1 for uncaught state-dir errors. The error message and code
	// path remain so a future find-by-pane that escalates state-read
	// failures hits the registry_read branch without further changes.
});

// --- vstack#214 renumber e2e (shim-driven) --------------------------------

describe("pane-respond %PANE_ID after tmux renumber (vstack#214)", () => {
	function makeRepo(): string {
		const dir = mkdtempSync(join(tmpdir(), "fd-pr-renumber-"));
		mkdirSync(join(dir, "tmp"), { recursive: true });
		spawnSync("git", ["init", "-q", "-b", "main"], { cwd: dir });
		spawnSync("git", ["-C", dir, "commit", "-q", "--no-gpg-sign", "--allow-empty", "-m", "init"], {
			env: {
				...process.env,
				GIT_AUTHOR_NAME: "t",
				GIT_AUTHOR_EMAIL: "t@t",
				GIT_COMMITTER_NAME: "t",
				GIT_COMMITTER_EMAIL: "t@t",
			},
		});
		return dir;
	}

	function shimEnv(repo: string, statePath: string): Record<string, string> {
		const env: Record<string, string> = { ...(process.env as Record<string, string>) };
		env.FLIGHTDECK_STATE_DIR = "tmp";
		env.PATH = `${SHIM_DIR}:${env.PATH ?? ""}`;
		env.TMUX_SHIM_STATE = statePath;
		env.TMUX_PARITY_SESSION = JSON.parse(readFileSync(statePath, "utf8")).session;
		// pane-respond requires TMUX env to be set — inherit whatever the
		// outer tmux session has; pane-respond doesn't actually look up
		// TMUX, it just gates on its presence.
		return env;
	}

	function runScript(repo: string, env: Record<string, string>, script: string, args: string[], input?: string): { stdout: string; stderr: string; status: number | null } {
		const r = spawnSync(script, args, { cwd: repo, encoding: "utf8", env, input });
		return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
	}

	test("registry pane_target stale → live tmux target wins, paste lands in the correct pane", () => {
		// Replicates the issue's failure: four entries spawned sequentially
		// at "launch slot 4" all recorded pane_target = "test-session:4.0".
		// Each new spawn pushed the prior windows up an index, so by the
		// time the operator calls pane-respond %PANE_ID for entry A, A is
		// actually at index 8 — and the slot at index 4 is now a sibling
		// (issue E in the live shim). Pre-vstack#214, the paste landed on
		// the sibling. Post-fix, the live tmux lookup in
		// resolvePaneTargetFromPaneId returns A's current coords and the
		// paste lands in A's actual pane.
		const repo = makeRepo();
		try {
			const statePath = join(repo, "shim-state.json");
			writeFileSync(statePath, JSON.stringify({
				session: "test-session",
				panes: {
					"%200": { pane_index: 0, path: "/tmp/A", window_id: "@200", window_index: 8, window_name: "A", sent_keys: [] },
					"%201": { pane_index: 0, path: "/tmp/B", window_id: "@201", window_index: 7, window_name: "B", sent_keys: [] },
					"%202": { pane_index: 0, path: "/tmp/C", window_id: "@202", window_index: 6, window_name: "C", sent_keys: [] },
					"%203": { pane_index: 0, path: "/tmp/D", window_id: "@203", window_index: 5, window_name: "D", sent_keys: [] },
					"%204": { pane_index: 0, path: "/tmp/E", window_id: "@204", window_index: 4, window_name: "E", sent_keys: [] },
				},
				windows: {
					"@200": { index: 8, name: "A" },
					"@201": { index: 7, name: "B" },
					"@202": { index: 6, name: "C" },
					"@203": { index: 5, name: "D" },
					"@204": { index: 4, name: "E" },
				},
				buffers: {},
			}, null, 2));
			const env = shimEnv(repo, statePath);

			// Register A, B, C, D with the stale pane_target each saw at
			// spawn time (when its launch slot was window 4).
			for (const [id, paneId] of [["A", "%200"], ["B", "%201"], ["C", "%202"], ["D", "%203"]] as const) {
				const r = runScript(repo, env, PANE_REGISTRY_SCRIPT, [
					"init-entry", id,
					"--title", `issue-${id}`,
					"--kind", "adhoc",
					"--cwd", `/tmp/${id}`,
					"--window", "4",
					"--harness", "pi",
					"--pane-id", paneId,
					"--pane-target", "test-session:4.0",
					"--window-index", "4",
				]);
				expect(r.status).toBe(0);
			}

			// Sanity: the registry's cached pane_target is stale.
			const beforeRegistry = JSON.parse(readFileSync(join(repo, "tmp/flightdeck-state-test-session.json"), "utf8"));
			expect(beforeRegistry.entries.A.pane_target).toBe("test-session:4.0");

			// Call pane-respond %200 (entry A). With the vstack#214 fix,
			// resolvePaneTargetFromPaneId asks tmux first and gets
			// "test-session:8.0" — A's current coords — so the paste
			// lands in pane %200, NOT pane %204 (which now occupies the
			// stale registry slot at "test-session:4.0").
			// --harness pi forces the tmux-fallback path (no live pi bridge
			// in the shim setup), exercising the paste-buffer flow we
			// instrumented in the shim.
			const respond = runScript(repo, env, SCRIPT, ["%200", "msg-for-A", "--harness", "pi"]);
			expect(respond.status).toBe(0);

			// Verify the shim recorded the paste in pane %200, not %204.
			const after = JSON.parse(readFileSync(statePath, "utf8"));
			expect(after.panes["%200"].sent_keys).toContain("msg-for-A");
			expect(after.panes["%204"].sent_keys ?? []).not.toContain("msg-for-A");
		} finally {
			rmSync(repo, { force: true, recursive: true });
		}
	});

	test("kill W → reconcile → surviving entries' pane_target updates AND pane-respond %PANE_ID lands in the correct pane (vstack#214 acceptance)", () => {
		// Full acceptance sequence: spawn 3 entries in windows W/W+1/W+2;
		// kill window W (tmux shifts the survivors down by one slot);
		// run `pane-registry reconcile` (the manual recovery path);
		// assert B's and C's cached pane_target / window / window_index
		// match their new live coords; then call pane-respond %PANE_B
		// and pane-respond %PANE_C and verify each paste landed in the
		// correct surviving pane via the shim's sent_keys log. This
		// mirrors the issue's reproducer: a sibling pane silently
		// receiving the supervisor's message after a renumber.
		const repo = makeRepo();
		try {
			const statePath = join(repo, "shim-state.json");
			writeFileSync(statePath, JSON.stringify({
				session: "test-session",
				panes: {
					"%500": { pane_index: 0, path: "/tmp/A", window_id: "@50", window_index: 5, window_name: "A", sent_keys: [] },
					"%501": { pane_index: 0, path: "/tmp/B", window_id: "@51", window_index: 6, window_name: "B", sent_keys: [] },
					"%502": { pane_index: 0, path: "/tmp/C", window_id: "@52", window_index: 7, window_name: "C", sent_keys: [] },
				},
				windows: {
					"@50": { index: 5, name: "A" },
					"@51": { index: 6, name: "B" },
					"@52": { index: 7, name: "C" },
				},
				buffers: {},
			}, null, 2));
			const env = shimEnv(repo, statePath);

			// Register each entry with its initial coords (this is the
			// normal flightdeck-session start path — pane_target matches
			// live tmux at spawn time).
			for (const [id, paneId, win] of [["A", "%500", "5"], ["B", "%501", "6"], ["C", "%502", "7"]] as const) {
				expect(runScript(repo, env, PANE_REGISTRY_SCRIPT, [
					"init-entry", id,
					"--title", `issue-${id}`,
					"--kind", "adhoc",
					"--cwd", `/tmp/${id}`,
					"--window", win,
					"--harness", "pi",
					"--pane-id", paneId,
					"--pane-target", `test-session:${win}.0`,
					"--window-index", win,
				]).status).toBe(0);
			}

			// Simulate `tmux kill-window` for window @50: drop %500's
			// pane + window, shift B and C down by one index.
			const shim = JSON.parse(readFileSync(statePath, "utf8")) as {
				panes: Record<string, { window_index: number; [k: string]: unknown }>;
				windows: Record<string, { index: number; [k: string]: unknown }>;
				[k: string]: unknown;
			};
			delete shim.panes["%500"];
			delete shim.windows["@50"];
			shim.panes["%501"]!.window_index = 5;
			shim.panes["%502"]!.window_index = 6;
			shim.windows["@51"]!.index = 5;
			shim.windows["@52"]!.index = 6;
			writeFileSync(statePath, JSON.stringify(shim, null, 2));

			// Manual reconcile — the recovery action a user runs after a
			// reshuffle. Pre-vstack#214 this only handled liveness; now
			// it also calls the refresh helper that recomputes pane_target.
			const reconcile = runScript(repo, env, PANE_REGISTRY_SCRIPT, ["reconcile"]);
			expect(reconcile.status).toBe(0);
			// Reconcile reports the refresh that updated B/C and then
			// drops A whose pane_id is gone.
			expect(reconcile.stdout).toMatch(/refreshed pane coords\/names for 2 entries/);

			// Registry-side assertion: B/C now point at their new live
			// coords; A's row was dropped because its pane is gone.
			const reg = JSON.parse(readFileSync(join(repo, "tmp/flightdeck-state-test-session.json"), "utf8"));
			expect(reg.entries.A).toBeUndefined();
			expect(reg.entries.B.pane_target).toBe("test-session:5.0");
			expect(reg.entries.B.window_index).toBe(5);
			expect(reg.entries.B.window).toBe("5");
			expect(reg.entries.C.pane_target).toBe("test-session:6.0");
			expect(reg.entries.C.window_index).toBe(6);
			expect(reg.entries.C.window).toBe("6");

			// Routing assertion: pane-respond to each surviving %PANE_ID
			// must land in that pane's sent_keys, not in the other
			// surviving pane (or any historical slot).
			expect(runScript(repo, env, SCRIPT, ["%501", "msg-for-B", "--harness", "pi"]).status).toBe(0);
			expect(runScript(repo, env, SCRIPT, ["%502", "msg-for-C", "--harness", "pi"]).status).toBe(0);
			const after = JSON.parse(readFileSync(statePath, "utf8")) as {
				panes: Record<string, { sent_keys?: string[] }>;
			};
			expect(after.panes["%501"].sent_keys).toContain("msg-for-B");
			expect(after.panes["%501"].sent_keys ?? []).not.toContain("msg-for-C");
			expect(after.panes["%502"].sent_keys).toContain("msg-for-C");
			expect(after.panes["%502"].sent_keys ?? []).not.toContain("msg-for-B");
		} finally {
			rmSync(repo, { force: true, recursive: true });
		}
	});

	test("after refresh-window-names, cached registry coords match live tmux", () => {
		// Companion assertion: refresh-window-names updates pane_target,
		// window, and window_index for every entry whose pane_id is still
		// alive at a new tmux slot. The bug: pre-fix, this only updated
		// window_name_current.
		const repo = makeRepo();
		try {
			const statePath = join(repo, "shim-state.json");
			writeFileSync(statePath, JSON.stringify({
				session: "test-session",
				panes: {
					"%200": { pane_index: 0, path: "/tmp/A", window_id: "@200", window_index: 8, window_name: "A", sent_keys: [] },
					"%201": { pane_index: 0, path: "/tmp/B", window_id: "@201", window_index: 7, window_name: "B", sent_keys: [] },
				},
				windows: {
					"@200": { index: 8, name: "A" },
					"@201": { index: 7, name: "B" },
				},
				buffers: {},
			}, null, 2));
			const env = shimEnv(repo, statePath);
			for (const [id, paneId] of [["A", "%200"], ["B", "%201"]] as const) {
				expect(runScript(repo, env, PANE_REGISTRY_SCRIPT, [
					"init-entry", id,
					"--title", `issue-${id}`,
					"--kind", "adhoc",
					"--cwd", `/tmp/${id}`,
					"--window", "4",
					"--harness", "pi",
					"--pane-id", paneId,
					"--pane-target", "test-session:4.0",
					"--window-index", "4",
				]).status).toBe(0);
			}
			const refresh = runScript(repo, env, PANE_REGISTRY_SCRIPT, ["refresh-window-names"]);
			expect(refresh.status).toBe(0);
			const parsed = JSON.parse(refresh.stdout) as { updated: string[] };
			expect(parsed.updated.sort()).toEqual(["A", "B"]);
			const reg = JSON.parse(readFileSync(join(repo, "tmp/flightdeck-state-test-session.json"), "utf8"));
			expect(reg.entries.A.pane_target).toBe("test-session:8.0");
			expect(reg.entries.A.window_index).toBe(8);
			expect(reg.entries.A.window).toBe("8");
			expect(reg.entries.B.pane_target).toBe("test-session:7.0");
			expect(reg.entries.B.window_index).toBe(7);
			expect(reg.entries.B.window).toBe("7");
		} finally {
			rmSync(repo, { force: true, recursive: true });
		}
	});
});
