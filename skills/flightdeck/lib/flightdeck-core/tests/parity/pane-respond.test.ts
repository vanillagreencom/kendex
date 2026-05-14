// Parity test: pane-respond (bash) vs pane-respond (TS).
// Focuses on argument validation, payload-tag enforcement, and harness/mode
// rejection paths — the deterministic, side-effect-free portion. Real adapter
// dispatch (curl, opencode bin, pi-bridge, codex-bridge, tmux send-keys)
// requires live infrastructure and is exercised by the integration test.

import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, "../../../../scripts/pane-respond");

if (!process.env.TMUX) {
	test.skip("pane-respond parity requires tmux", () => undefined);
}

function run(useTs: boolean, args: string[]): { stdout: string; stderr: string; status: number | null } {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	if (useTs) env.FLIGHTDECK_USE_TS_PANE_RESPOND = "1";
	else delete env.FLIGHTDECK_USE_TS_PANE_RESPOND;
	delete env.FLIGHTDECK_USE_TS;
	const r = spawnSync(SCRIPT, args, { encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

describe("pane-respond parity (validation)", () => {
	test("missing target → usage error", () => {
		const a = run(false, []);
		const b = run(true, []);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	test("target without pane index → error", () => {
		const a = run(false, ["session:window", "hello"]);
		const b = run(true, ["session:window", "hello"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	test("--option with non-integer rejects", () => {
		const a = run(false, ["s:w.0", "--option", "abc"]);
		const b = run(true, ["s:w.0", "--option", "abc"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	test("--option with positional payload rejects", () => {
		const a = run(false, ["s:w.0", "hi", "--option", "1"]);
		const b = run(true, ["s:w.0", "hi", "--option", "1"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	test("--option with tag multi-select-tabbed rejects", () => {
		const a = run(false, ["s:w.0", "--option", "1", "--tag", "multi-select-tabbed"]);
		const b = run(true, ["s:w.0", "--option", "1", "--tag", "multi-select-tabbed"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(1);
	});

	test("--option-multi with non-CSV rejects", () => {
		const a = run(false, ["s:w.0", "--option-multi", "1,a,3"]);
		const b = run(true, ["s:w.0", "--option-multi", "1,a,3"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	test("rebase-multi-choice payload missing sections rejects", () => {
		const a = run(false, ["s:w.0", "just a rebase", "--tag", "rebase-multi-choice"]);
		const b = run(true, ["s:w.0", "just a rebase", "--tag", "rebase-multi-choice"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(1);
		// Both should mention the missing sections
		expect(b.stderr).toContain("PRESERVE");
		expect(a.stderr).toContain("PRESERVE");
	});

	test("--question on wrong harness rejects", () => {
		const a = run(false, ["s:w.0", "--harness", "claude", "--question", "que_x", "--answer", "Yes"]);
		const b = run(true, ["s:w.0", "--harness", "claude", "--question", "que_x", "--answer", "Yes"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(1);
	});

	test("--question with conflicting answer flags rejects", () => {
		const a = run(false, ["s:w.0", "--harness", "opencode", "--question", "que_x", "--answer", "A", "--answer-multi", "B,C"]);
		const b = run(true, ["s:w.0", "--harness", "opencode", "--question", "que_x", "--answer", "A", "--answer-multi", "B,C"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	test("--reject + --answer combo rejects", () => {
		const a = run(false, ["s:w.0", "--harness", "opencode", "--question", "que_x", "--reject", "--answer", "Yes"]);
		const b = run(true, ["s:w.0", "--harness", "opencode", "--question", "que_x", "--reject", "--answer", "Yes"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	test("--answers-json with non-array rejects", () => {
		const a = run(false, ["s:w.0", "--harness", "opencode", "--question", "que_x", "--answers-json", '"hi"']);
		const b = run(true, ["s:w.0", "--harness", "opencode", "--question", "que_x", "--answers-json", '"hi"']);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	test("--answer-text on opencode rejects", () => {
		const a = run(false, ["s:w.0", "--harness", "opencode", "--question", "que_x", "--answer-text", "free text"]);
		const b = run(true, ["s:w.0", "--harness", "opencode", "--question", "que_x", "--answer-text", "free text"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(1);
	});

	test("unknown flag rejects", () => {
		const a = run(false, ["s:w.0", "hi", "--bogus-flag"]);
		const b = run(true, ["s:w.0", "hi", "--bogus-flag"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
	});

	// Issue #37(A) + round-1 reviewer-error major: pane_id resolution
	// failures must emit specific, byte-identical error text in both
	// implementations so the caller knows which recovery path applies.
	test("%pane_id not registered → specific not-registered error", () => {
		const a = run(false, ["%999999", "hi"]);
		const b = run(true, ["%999999", "hi"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
		const expected = "pane-respond: pane '%999999' is not registered as a flightdeck-tracked pane; pass the explicit pane target (e.g. <session>:<window>.<idx>) or register the pane first";
		expect(a.stderr).toContain(expected);
		expect(b.stderr).toContain(expected);
		// Generic 'explicit pane index' fallback must NOT fire for %-form.
		expect(a.stderr).not.toContain("target must include explicit pane index");
		expect(b.stderr).not.toContain("target must include explicit pane index");
	});

	test("%pane_id entry found but pane_target null → registry-drift error", () => {
		// Drive the missing_pane_target branch: init-entry sets
		// pane_target from the live pane, so we explicitly null it via
		// `pane-registry set` to simulate registry drift. Both bash and
		// TS implementations must surface the same drift recovery hint
		// (pane-registry reconcile) rather than 'not registered'.
		const tmuxPane = process.env.TMUX_PANE;
		if (!tmuxPane) {
			// Skip transparently when TMUX_PANE is unset (already gated by
			// the file-level TMUX guard above; defensive fallback for
			// nested tmux invocations that scrub the env).
			return;
		}
		const fs = require("node:fs") as typeof import("node:fs");
		const os = require("node:os") as typeof import("node:os");
		const path = require("node:path") as typeof import("node:path");
		const PANE_REGISTRY = resolve(HERE, "../../../../scripts/pane-registry");
		const FLIGHTDECK_STATE = resolve(HERE, "../../../../scripts/flightdeck-state");
		for (const useTs of [false, true]) {
			const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "fd-pr-drift-"));
			try {
				const envBase: Record<string, string> = { ...(process.env as Record<string, string>), FLIGHTDECK_STATE_DIR: stateDir };
				spawnSync(FLIGHTDECK_STATE, ["init"], { encoding: "utf8", env: envBase });
				spawnSync(PANE_REGISTRY, ["init-entry", "DRIFT-PT", "--title", "T", "--kind", "adhoc", "--cwd", "/tmp", "--window", "1", "--harness", "pi", "--pane-id", tmuxPane], { encoding: "utf8", env: envBase });
				// init-entry auto-derives pane_target from the live pane;
				// stomp it to null to simulate registry drift.
				spawnSync(PANE_REGISTRY, ["set", "DRIFT-PT", "pane_target", "null"], { encoding: "utf8", env: envBase });
				const env: Record<string, string> = { ...envBase };
				if (useTs) env.FLIGHTDECK_USE_TS_PANE_RESPOND = "1";
				else delete env.FLIGHTDECK_USE_TS_PANE_RESPOND;
				delete env.FLIGHTDECK_USE_TS;
				const r = spawnSync(SCRIPT, [tmuxPane, "hi"], { encoding: "utf8", env });
				expect(r.status).toBe(2);
				const expected = `pane-respond: registry entry for '${tmuxPane}' is missing pane_target (registry drift); recover via pane-registry reconcile`;
				expect((r.stderr ?? "")).toContain(expected);
				// Generic 'explicit pane index' fallback must NOT fire.
				expect((r.stderr ?? "")).not.toContain("target must include explicit pane index");
			} finally {
				fs.rmSync(stateDir, { recursive: true, force: true });
			}
		}
	});

	// Note on the registry_read (find-by-pane exit >= 2) branch: it is
	// defensively wired in resolvePaneTargetFromPaneId / the bash helper
	// but currently unreachable in normal operation — find-by-pane wraps
	// state reads in `2>/dev/null` and downgrades any flightdeck-state
	// failure to exit 1 (handled by the not_registered branch above), and
	// the bun runtime exits 1 for uncaught state-dir errors. The error
	// message and code path remain so a future find-by-pane that
	// escalates state-read failures hits the registry_read branch in
	// both bash and TS without further changes.
});
