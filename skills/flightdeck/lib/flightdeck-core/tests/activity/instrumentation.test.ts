import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, "../../../../scripts/pane-registry");
const FLIGHTDECK_STATE = resolve(HERE, "../../../../scripts/flightdeck-state");
const SHIM_DIR = resolve(HERE, "../parity/tmux-shim");
const SESSION = "test-session";

interface ShimPane {
	window_id: string;
	window_name: string;
	path: string;
	window_index: number;
	pane_index: number;
}

interface ShimState {
	session: string;
	panes: Record<string, ShimPane>;
	windows: Record<string, { name: string; index: number }>;
}

interface ActivityEvent {
	type: string;
	severity: string;
	importance: string;
	summary: string;
	entry_id?: string;
	entry_title?: string;
	entry_kind?: string;
	pane_id?: string;
	harness?: string;
	refs?: Record<string, unknown>;
	details?: Record<string, unknown>;
}

let repo = "";
let shimState = "";

beforeEach(() => {
	repo = mkdtempSync(join(tmpdir(), "fd-activity-instrument-"));
	spawnSync("git", ["init", "-q", "-b", "main"], { cwd: repo });
	spawnSync("git", ["-C", repo, "commit", "-q", "--no-gpg-sign", "--allow-empty", "-m", "init"], {
		env: { ...process.env, GIT_AUTHOR_EMAIL: "t@t", GIT_AUTHOR_NAME: "t", GIT_COMMITTER_EMAIL: "t@t", GIT_COMMITTER_NAME: "t" },
	});
	shimState = writeShimState({ panes: {}, session: SESSION, windows: {} });
});

afterEach(() => {
	if (repo && existsSync(repo)) rmSync(repo, { force: true, recursive: true });
});

function writeShimState(state: ShimState): string {
	const path = join(repo, "shim-state.json");
	writeFileSync(path, JSON.stringify(state, null, 2), "utf8");
	return path;
}

function registryEnv(): Record<string, string> {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.FLIGHTDECK_STATE_DIR = "tmp";
	env.FLIGHTDECK_MANAGED = "1";
	env.PATH = `${SHIM_DIR}:${env.PATH ?? ""}`;
	env.TMUX = env.TMUX || "shim";
	env.TMUX_PANE = env.TMUX_PANE || "%master";
	env.TMUX_PARITY_SESSION = SESSION;
	env.TMUX_SHIM_STATE = shimState;
	return env;
}

function run(args: string[]): { stdout: string; stderr: string; status: number | null } {
	const r = spawnSync(SCRIPT, args, { cwd: repo, encoding: "utf8", env: registryEnv() });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function runWithEnv(args: string[], extraEnv: Record<string, string>): { stdout: string; stderr: string; status: number | null } {
	const env = { ...registryEnv(), ...extraEnv };
	const r = spawnSync(SCRIPT, args, { cwd: repo, encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function runFlightdeckState(args: string[]): { stdout: string; stderr: string; status: number | null } {
	const env = registryEnv();
	const r = spawnSync(FLIGHTDECK_STATE, [args[0]!, "--session", SESSION, ...args.slice(1)], { cwd: repo, encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function activityPath(): string {
	return join(repo, "tmp", `flightdeck-activity-${SESSION}.jsonl`);
}

function statePath(): string {
	return join(repo, "tmp", `flightdeck-state-${SESSION}.json`);
}

function events(): ActivityEvent[] {
	const file = activityPath();
	if (!existsSync(file)) return [];
	return readFileSync(file, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line) as ActivityEvent);
}

function eventsOf(type: string): ActivityEvent[] {
	return events().filter((event) => event.type === type);
}

function initEntry(id = "E1", extra: string[] = []): void {
	const result = run(["init-entry", id, "--title", "Example Entry", "--kind", "adhoc", "--cwd", "/tmp/example", "--window", "example", "--harness", "pi", "--pane-id", "%101", ...extra]);
	expect(result.status).toBe(0);
}

describe("pane-registry activity instrumentation", () => {
	test("init-entry emits one registered event with entry context", () => {
		initEntry("REG-1", ["--kind", "workflow"]);
		const registered = eventsOf("entry.registered");
		expect(registered).toHaveLength(1);
		expect(registered[0]).toMatchObject({
			entry_id: "REG-1",
			entry_kind: "workflow",
			entry_title: "Example Entry",
			harness: "pi",
			importance: "important",
			pane_id: "%101",
			severity: "info",
			summary: "workflow REG-1 registered: Example Entry",
		});
	});

	test("set-state emits state change once and skips no-op transitions", () => {
		initEntry("STATE-1");
		expect(run(["set-state", "STATE-1", "ready"]).status).toBe(0);
		expect(run(["set-state", "STATE-1", "ready"]).status).toBe(0);
		const changes = eventsOf("entry.state_changed").filter((event) => event.entry_id === "STATE-1" && event.details?.new === "ready");
		expect(changes).toHaveLength(1);
		expect(changes[0]?.details).toMatchObject({ new: "ready", old: "waiting" });
		expect(changes[0]?.importance).toBe("normal");
	});

	test("set-substate emits noisy state_changed with parent state", () => {
		initEntry("SUB-1");
		expect(run(["set-substate", "SUB-1", "scope-creep-detected"]).status).toBe(0);
		const changes = eventsOf("entry.state_changed").filter((event) => event.entry_id === "SUB-1" && event.details?.substate === "scope-creep-detected");
		expect(changes).toHaveLength(1);
		expect(changes[0]).toMatchObject({ importance: "noisy", severity: "info", summary: "SUB-1 substate: scope-creep-detected" });
		expect(changes[0]?.details).toMatchObject({ parentState: "waiting", substate: "scope-creep-detected" });
	});

	test("log-decision emits info and warning decision events", () => {
		initEntry("DEC-1");
		expect(run(["log-decision", "DEC-1", "merge-now", "Approved merge"]).status).toBe(0);
		expect(run(["log-decision", "DEC-1", "bot-review", "BLOCKED: missing approval"]).status).toBe(0);
		expect(run(["log-decision", "DEC-1", "scope", "ESCALATED: needs operator"]).status).toBe(0);
		const decisions = eventsOf("decision.recorded").filter((event) => event.entry_id === "DEC-1");
		expect(decisions).toHaveLength(3);
		expect(decisions[0]).toMatchObject({ importance: "important", severity: "info", summary: "Approved merge" });
		expect(decisions[1]).toMatchObject({ importance: "important", severity: "warning", summary: "BLOCKED: missing approval" });
		expect(decisions[2]).toMatchObject({ importance: "important", severity: "warning", summary: "ESCALATED: needs operator" });
	});

	test("teardown-entry emits terminal completed cancelled and dead events", () => {
		const cases = [
			["DONE-1", "complete", "entry.completed", "success"],
			["CANCEL-1", "cancelled", "entry.cancelled", "warning"],
			["DEAD-1", "aborted", "entry.dead", "error"],
		] as const;
		for (const [id, state, type, severity] of cases) {
			initEntry(id, ["--pane-id", `%${id}`]);
			expect(run(["set-state", id, state]).status).toBe(0);
			expect(run(["teardown-entry", id]).status).toBe(0);
			const terminal = eventsOf(type).filter((event) => event.entry_id === id);
			expect(terminal).toHaveLength(1);
			expect(terminal[0]).toMatchObject({ importance: "important", severity });
		}
	});

	test("teardown-entry emits terminal event after live pane kill succeeds", () => {
		shimState = writeShimState({
			panes: { "%200": { pane_index: 0, path: "/tmp/live", window_id: "@20", window_index: 1, window_name: "live-window" } },
			session: SESSION,
			windows: { "@20": { index: 1, name: "live-window" } },
		});
		expect(run(["init-entry", "LIVE-1", "--title", "Live", "--kind", "adhoc", "--cwd", "/tmp/live", "--window", "live-window", "--harness", "pi", "--pane-id", "%200", "--pane-target", `${SESSION}:1.0`]).status).toBe(0);
		expect(run(["set-state", "LIVE-1", "complete"]).status).toBe(0);
		expect(run(["teardown-entry", "LIVE-1"]).status).toBe(0);
		const terminal = eventsOf("entry.completed").filter((event) => event.entry_id === "LIVE-1");
		expect(terminal).toHaveLength(1);
		expect(terminal[0]).toMatchObject({ importance: "important", severity: "success" });
		expect(terminal[0]?.details).toMatchObject({ teardown: "killed" });
		expect(JSON.parse(readFileSync(shimState, "utf8")).panes["%200"]).toBeUndefined();
	});

	test("reconcile stale pane drops row and emits entry.dead", () => {
		initEntry("STALE-1", ["--pane-id", "%999"]);
		expect(run(["reconcile"]).status).toBe(0);
		const dead = eventsOf("entry.dead").filter((event) => event.entry_id === "STALE-1");
		expect(dead).toHaveLength(1);
		expect(dead[0]).toMatchObject({ importance: "important", severity: "warning" });
		expect(dead[0]?.details).toMatchObject({ reason: "reconcile-stale-pane" });
	});

	// vstack#85 Fix A: shell adhoc has no idle subscriber, so pane-gone
	// IS the terminal signal. Reconcile transitions state to `complete`
	// and emits `entry.completed` (success) instead of dropping the row
	// with `entry.dead` (warning).
	test("reconcile adhoc shell with gone pane transitions to complete and emits entry.completed", () => {
		expect(run(["init-entry", "SHELL-1", "--title", "Adhoc Shell", "--kind", "adhoc", "--cwd", "/tmp/shell", "--window", "shell-win", "--harness", "shell", "--pane-id", "%999"]).status).toBe(0);
		expect(run(["reconcile"]).status).toBe(0);
		const completed = eventsOf("entry.completed").filter((event) => event.entry_id === "SHELL-1");
		expect(completed).toHaveLength(1);
		expect(completed[0]).toMatchObject({ importance: "important", severity: "success" });
		expect(completed[0]?.details).toMatchObject({ reason: "reconcile-pane-gone", teardown: "shell-pane-gone" });
		expect(eventsOf("entry.dead").filter((event) => event.entry_id === "SHELL-1")).toHaveLength(0);
		const entry = JSON.parse(run(["get", "SHELL-1"]).stdout) as Record<string, unknown>;
		expect(entry.state).toBe("complete");
	});

	test("reconcile adhoc shell is idempotent: second pass on terminal state does not re-emit", () => {
		expect(run(["init-entry", "SHELL-IDEM", "--title", "Idempotent", "--kind", "adhoc", "--cwd", "/tmp/shell", "--window", "shell-win", "--harness", "shell", "--pane-id", "%998"]).status).toBe(0);
		expect(run(["reconcile"]).status).toBe(0);
		expect(run(["reconcile"]).status).toBe(0);
		const completed = eventsOf("entry.completed").filter((event) => event.entry_id === "SHELL-IDEM");
		expect(completed).toHaveLength(1);
		expect(eventsOf("entry.dead").filter((event) => event.entry_id === "SHELL-IDEM")).toHaveLength(0);
	});

	test("reconcile adhoc pi with gone pane keeps legacy entry.dead drop (not-shell skip)", () => {
		initEntry("PI-STALE", ["--pane-id", "%997"]);
		expect(run(["reconcile"]).status).toBe(0);
		const dead = eventsOf("entry.dead").filter((event) => event.entry_id === "PI-STALE");
		expect(dead).toHaveLength(1);
		expect(eventsOf("entry.completed").filter((event) => event.entry_id === "PI-STALE")).toHaveLength(0);
	});

	// vstack#85 Fix B: teardown-entry --force on a gone-pane waiting
	// entry must drop the stale row and emit entry.cancelled. Without
	// --force the existing #16 drift refusal (exit 3) must stand.
	test("teardown-entry --force on gone-pane waiting entry drops row and emits entry.cancelled", () => {
		expect(run(["init-entry", "FORCE-WAIT", "--title", "Stuck Waiting", "--kind", "adhoc", "--cwd", "/tmp/force", "--window", "force-win", "--harness", "shell", "--pane-id", "%996"]).status).toBe(0);
		// Non-force path: existing drift refusal still applies.
		const refused = run(["teardown-entry", "FORCE-WAIT"]);
		expect(refused.status).toBe(3);
		expect(refused.stderr).toContain("registry drift");
		expect(refused.stderr).toContain("--force");
		// --force path: drops row + emits entry.cancelled.
		const forced = run(["teardown-entry", "FORCE-WAIT", "--force"]);
		expect(forced.status).toBe(0);
		expect(forced.stdout).toContain("removed stale entry 'FORCE-WAIT'");
		const cancelled = eventsOf("entry.cancelled").filter((event) => event.entry_id === "FORCE-WAIT");
		expect(cancelled).toHaveLength(1);
		expect(cancelled[0]).toMatchObject({ importance: "important", severity: "warning" });
		expect(cancelled[0]?.details).toMatchObject({ force: true, reason: "force-gone-pane", teardown: "force-gone-pane", prior_state: "waiting" });
		// Entry is gone from the registry.
		expect(run(["get", "FORCE-WAIT"]).status).toBe(1);
	});

	test("teardown-entry --force on gone-pane non-waiting entry emits entry.dead", () => {
		expect(run(["init-entry", "FORCE-PROMPT", "--title", "Stuck Prompting", "--kind", "adhoc", "--cwd", "/tmp/force", "--window", "force-win", "--harness", "shell", "--pane-id", "%995"]).status).toBe(0);
		expect(run(["set-state", "FORCE-PROMPT", "prompting"]).status).toBe(0);
		const forced = run(["teardown-entry", "FORCE-PROMPT", "--force"]);
		expect(forced.status).toBe(0);
		const dead = eventsOf("entry.dead").filter((event) => event.entry_id === "FORCE-PROMPT");
		expect(dead).toHaveLength(1);
		expect(dead[0]).toMatchObject({ importance: "important", severity: "error" });
		expect(dead[0]?.details).toMatchObject({ force: true, prior_state: "prompting", reason: "force-gone-pane" });
		expect(eventsOf("entry.cancelled").filter((event) => event.entry_id === "FORCE-PROMPT")).toHaveLength(0);
		expect(run(["get", "FORCE-PROMPT"]).status).toBe(1);
	});

	// vstack#85 F1 (round-2 follow-up): a transient `tmux list-panes -a`
	// failure (SIGPIPE, EAGAIN, mid-session restart) must NOT mass-
	// transition every adhoc-shell row to `complete` or mass-drop every
	// other entry as `entry.dead`. Reconcile bails with a structured
	// warn line and exit 0 so the next healthy probe can drive the
	// actual reconciliation.
	test("reconcile bails on tmux probe failure: no transitions, no drops, single warn line", () => {
		for (let i = 0; i < 5; i += 1) {
			const id = `PROBE-SHELL-${i}`;
			expect(run(["init-entry", id, "--title", `Shell ${i}`, "--kind", "adhoc", "--cwd", "/tmp/shell", "--window", `shell-${i}`, "--harness", "shell", "--pane-id", `%${900 + i}`]).status).toBe(0);
		}
		for (let i = 0; i < 3; i += 1) {
			const id = `PROBE-PI-${i}`;
			expect(run(["init-entry", id, "--title", `Pi ${i}`, "--kind", "adhoc", "--cwd", "/tmp/pi", "--window", `pi-${i}`, "--harness", "pi", "--pane-id", `%${950 + i}`]).status).toBe(0);
		}
		// Baseline activity snapshot: drop all the entry.registered events
		// emitted during init; only post-baseline rows matter for the
		// assertion below.
		const registeredBefore = eventsOf("entry.registered").length;
		const completedBefore = eventsOf("entry.completed").length;
		const deadBefore = eventsOf("entry.dead").length;
		const stateChangedBefore = eventsOf("entry.state_changed").length;
		const result = runWithEnv(["reconcile"], { TMUX_SHIM_FAIL_LIST_PANES_A: "1" });
		expect(result.status).toBe(0);
		expect(result.stderr).toContain("reconcile: tmux probe failed");
		expect(result.stderr).toContain("skipping tick");
		// Exactly one warn line — no per-entry chatter.
		expect(result.stderr.split("\n").filter((line) => line.includes("tmux probe failed"))).toHaveLength(1);
		// No new transition / drop emits.
		expect(eventsOf("entry.completed").length).toBe(completedBefore);
		expect(eventsOf("entry.dead").length).toBe(deadBefore);
		expect(eventsOf("entry.state_changed").length).toBe(stateChangedBefore);
		expect(eventsOf("entry.registered").length).toBe(registeredBefore);
		// Every entry still in the registry, state unchanged.
		for (let i = 0; i < 5; i += 1) {
			const entry = JSON.parse(run(["get", `PROBE-SHELL-${i}`]).stdout) as Record<string, unknown>;
			expect(entry.state).toBe("waiting");
		}
		for (let i = 0; i < 3; i += 1) {
			const entry = JSON.parse(run(["get", `PROBE-PI-${i}`]).stdout) as Record<string, unknown>;
			expect(entry.state).toBe("waiting");
		}
	});

	test("teardown-entry --force bails on tmux probe failure (refuses, exit 5)", () => {
		expect(run(["init-entry", "PROBE-TD", "--title", "Probe Teardown", "--kind", "adhoc", "--cwd", "/tmp/probe", "--window", "probe-win", "--harness", "shell", "--pane-id", "%994"]).status).toBe(0);
		const result = runWithEnv(["teardown-entry", "PROBE-TD", "--force"], { TMUX_SHIM_FAIL_LIST_PANES_A: "1" });
		expect(result.status).toBe(5);
		expect(result.stderr).toContain("tmux probe failed");
		// Entry still in registry, no terminal emit.
		expect(run(["get", "PROBE-TD"]).status).toBe(0);
		expect(eventsOf("entry.cancelled").filter((event) => event.entry_id === "PROBE-TD")).toHaveLength(0);
		expect(eventsOf("entry.dead").filter((event) => event.entry_id === "PROBE-TD")).toHaveLength(0);
	});

	// vstack#85 F2 (round-2 follow-up): teardown --force must refuse to
	// drop an entry whose pane_id is empty when the recorded window is
	// still alive in tmux — there's no way to verify the pane is
	// actually gone, and a force-drop would lose state for a
	// possibly-live session.
	test("teardown-entry --force refuses when pane_id empty but recorded window is still alive", () => {
		// Stage a live window in the shim that the registry entry will
		// reference. No pane is associated with the entry (pane_id null).
		shimState = writeShimState({
			panes: { "%993": { pane_index: 0, path: "/tmp/other", window_id: "@93", window_index: 9, window_name: "stuck-win" } },
			session: SESSION,
			windows: { "@93": { index: 9, name: "stuck-win" } },
		});
		expect(run(["init-entry", "WIN-ALIVE", "--title", "Window Alive", "--kind", "adhoc", "--cwd", "/tmp/stuck", "--window", "stuck-win", "--harness", "shell"]).status).toBe(0);
		expect(run(["set", "WIN-ALIVE", "pane_id", "null"]).status).toBe(0);
		const result = run(["teardown-entry", "WIN-ALIVE", "--force"]);
		expect(result.status).toBe(3);
		expect(result.stderr).toContain("pane_id is empty");
		expect(result.stderr).toContain("stuck-win");
		expect(result.stderr).toContain("still alive");
		expect(result.stderr).toContain("--force refused");
		// Entry still in registry, no terminal emit.
		expect(run(["get", "WIN-ALIVE"]).status).toBe(0);
		expect(eventsOf("entry.cancelled").filter((event) => event.entry_id === "WIN-ALIVE")).toHaveLength(0);
		expect(eventsOf("entry.dead").filter((event) => event.entry_id === "WIN-ALIVE")).toHaveLength(0);
	});

	test("teardown-entry --force proceeds when pane_id empty AND recorded window is also gone", () => {
		// No matching window in the shim — the recorded window vanished.
		expect(run(["init-entry", "WIN-GONE", "--title", "Window Gone", "--kind", "adhoc", "--cwd", "/tmp/gone", "--window", "never-existed-win", "--harness", "shell"]).status).toBe(0);
		expect(run(["set", "WIN-GONE", "pane_id", "null"]).status).toBe(0);
		const result = run(["teardown-entry", "WIN-GONE", "--force"]);
		expect(result.status).toBe(0);
		expect(result.stdout).toContain("removed stale entry 'WIN-GONE'");
		const cancelled = eventsOf("entry.cancelled").filter((event) => event.entry_id === "WIN-GONE");
		expect(cancelled).toHaveLength(1);
		expect(run(["get", "WIN-GONE"]).status).toBe(1);
	});

	test("reconcile drift emits daemon.warning without dropping row", () => {
		shimState = writeShimState({
			panes: { "%500": { pane_index: 0, path: "/tmp/other", window_id: "@50", window_index: 1, window_name: "other-window" } },
			session: SESSION,
			windows: { "@50": { index: 1, name: "other-window" } },
		});
		expect(run(["init-entry", "DRIFT-1", "--title", "Drift", "--kind", "adhoc", "--cwd", "/tmp/original", "--window", "original", "--harness", "pi", "--pane-target", `${SESSION}:1.0`]).status).toBe(0);
		expect(run(["set", "DRIFT-1", "pane_id", "null"]).status).toBe(0);
		expect(run(["reconcile"]).status).toBe(0);
		const warnings = eventsOf("daemon.warning").filter((event) => event.entry_id === "DRIFT-1");
		expect(warnings).toHaveLength(1);
		expect(warnings[0]?.summary).toContain("reconcile drift: DRIFT-1");
		expect(JSON.parse(run(["get", "DRIFT-1"]).stdout).pane_id).toBeNull();
	});

	test("direct flightdeck-state set emits state_changed once and skips no-op", () => {
		mkdirSync(join(repo, "tmp"), { recursive: true });
		writeFileSync(statePath(), JSON.stringify({
			activity_path: activityPath(),
			activity_schema_version: 1,
			entries: {
				"DIRECT-1": { id: "DIRECT-1", kind: "adhoc", state: "waiting", title: "Direct", window: "direct", harness: "pi", pane_id: "%303" },
			},
			session_id: SESSION,
		}), "utf8");
		expect(runFlightdeckState(["set", `.entries[\"DIRECT-1\"].state`, '"ready"']).status).toBe(0);
		expect(runFlightdeckState(["set", `.entries[\"DIRECT-1\"].state`, '"ready"']).status).toBe(0);
		const changes = eventsOf("entry.state_changed").filter((event) => event.entry_id === "DIRECT-1" && event.details?.new === "ready");
		expect(changes).toHaveLength(1);
		expect(changes[0]).toMatchObject({ entry_kind: "adhoc", entry_title: "Direct", harness: "pi", pane_id: "%303" });
		expect(changes[0]?.details).toMatchObject({ new: "ready", old: "waiting" });
	});

	test("activity disabled succeeds silently without creating activity JSONL", () => {
		mkdirSync(join(repo, "tmp"), { recursive: true });
		writeFileSync(statePath(), JSON.stringify({
			entries: {
				"DISABLED-1": { id: "DISABLED-1", kind: "adhoc", state: "waiting", title: "Disabled", window: "disabled", harness: "pi" },
			},
			session_id: SESSION,
		}), "utf8");
		const result = run(["set-state", "DISABLED-1", "ready"]);
		expect(result.status).toBe(0);
		expect(existsSync(activityPath())).toBe(false);
	});
});
