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

	// Issue #37(A): pane_id (%NNN) target with no registry match should
	// still error with the explicit-pane-index message — confirms both
	// implementations attempt resolution and fall through identically.
	test("%pane_id with no registry match → pane-index error", () => {
		const a = run(false, ["%999999", "hi"]);
		const b = run(true, ["%999999", "hi"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(2);
		expect(a.stderr).toContain("target must include explicit pane index");
		expect(b.stderr).toContain("target must include explicit pane index");
	});
});
