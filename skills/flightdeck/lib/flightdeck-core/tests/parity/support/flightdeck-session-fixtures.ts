import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const PARITY_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const SCRIPT = resolve(PARITY_DIR, "../../../../scripts/flightdeck-session");
export const FLIGHTDECK_STATE_SCRIPT = resolve(PARITY_DIR, "../../../../scripts/flightdeck-state");
export const PANE_ENV_SCRIPT = resolve(PARITY_DIR, "../../../../scripts/lib/pane-env.sh");
export const SHIM_DIR = resolve(PARITY_DIR, "./tmux-shim");
export const HERE = PARITY_DIR;

export interface ShimPane {
	window_id: string;
	window_name: string;
	path: string;
	window_index: number;
	pane_index: number;
	pane_pid?: number;
	sent_keys?: string[];
}

export interface ShimState {
	session: string;
	panes: Record<string, ShimPane>;
	windows: Record<string, { name: string; index: number; automatic_rename?: string }>;
	current_pane_id?: string;
	current_window_id?: string;
}

export interface RunResult {
	stdout: string;
	stderr: string;
	status: number | null;
}

export function makeRepo(prefix = "fdsession-"): string {
	const dir = mkdtempSync(join(tmpdir(), prefix));
	spawnSync("git", ["init", "-q", "-b", "main"], { cwd: dir });
	spawnSync("git", ["-C", dir, "commit", "-q", "--no-gpg-sign", "--allow-empty", "-m", "init"], {
		env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" },
	});
	return dir;
}

export function writeShimState(repo: string, state: ShimState): string {
	const path = join(repo, "shim-state.json");
	writeFileSync(path, JSON.stringify(state, null, 2));
	return path;
}

export function readShimState(path: string): ShimState {
	return JSON.parse(readFileSync(path, "utf8"));
}

// vstack#227: state lives in the active run dir; resolve via the CLI.
export function stateFile(repo: string): string {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.HOME = join(repo, "home");
	env.FLIGHTDECK_STATE_DIR = "tmp";
	env.FLIGHTDECK_RUN_STORE_ROOT = join(repo, ".vstack-run-store");
	const r = spawnSync(FLIGHTDECK_STATE_SCRIPT, ["path", "--session", "test-session"], { cwd: repo, encoding: "utf8", env });
	if (r.status !== 0) {
		throw new Error(`flightdeck-state path failed: ${r.stderr}`);
	}
	return (r.stdout ?? "").trim();
}

export function run(repo: string, statePath: string, args: string[], extraEnv: Record<string, string> = {}): RunResult {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.HOME = join(repo, "home");
	env.TMUX = "/tmp/tmux-test";
	env.TMUX_SHIM_STATE = statePath;
	env.TMUX_PARITY_SESSION = "test-session";
	env.PATH = `${SHIM_DIR}:${env.PATH ?? ""}`;
	env.FLIGHTDECK_STATE_DIR = "tmp";
	// vstack#227: per-test run-store isolation.
	env.FLIGHTDECK_RUN_STORE_ROOT = join(repo, ".vstack-run-store");
	env.FLIGHTDECK_DASHBOARD = "0";
	delete (env as Record<string, string | undefined>).PI_CODING_AGENT;
	Object.assign(env, extraEnv);
	const r = spawnSync(SCRIPT, args, { cwd: repo, encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

export function runState(repo: string, statePath: string, args: string[], extraEnv: Record<string, string> = {}): RunResult {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.HOME = join(repo, "home");
	env.TMUX = "/tmp/tmux-test";
	env.TMUX_SHIM_STATE = statePath;
	env.TMUX_PARITY_SESSION = "test-session";
	env.PATH = `${SHIM_DIR}:${env.PATH ?? ""}`;
	env.FLIGHTDECK_STATE_DIR = "tmp";
	env.FLIGHTDECK_RUN_STORE_ROOT = join(repo, ".vstack-run-store");
	env.FLIGHTDECK_DASHBOARD = "0";
	delete (env as Record<string, string | undefined>).PI_CODING_AGENT;
	Object.assign(env, extraEnv);
	const r = spawnSync(FLIGHTDECK_STATE_SCRIPT, args, { cwd: repo, encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}
