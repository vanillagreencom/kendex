import { spawnSync } from "node:child_process";

import type { CommandResult } from "./process.js";

export type CargoResult = CommandResult;

export function runCargo(args: string[], cwd: string, timeoutMs: number): CargoResult {
	const result = spawnSync("cargo", args, {
		cwd,
		// The default already is process.env, but only as it stood when the
		// runtime snapshotted it; naming it reads the live object, which is
		// what lets a test put a fake cargo on PATH.
		env: process.env,
		encoding: "utf8",
		timeout: Math.max(1, timeoutMs),
		maxBuffer: 16 * 1024 * 1024,
	});
	return {
		exitCode: typeof result.status === "number" ? result.status : -1,
		stdout: result.stdout ?? "",
		stderr: result.stderr ?? "",
		timedOut: (result as { signal?: NodeJS.Signals | null }).signal === "SIGTERM",
	};
}

/**
 * In-process cache for `cargo metadata --workspace_root`. `cargo metadata` is
 * ~0.5-1s even on a warm cache; calling it on every edit/turn adds up. The
 * workspace root for a given cwd doesn't change during a session, so caching
 * by cwd is sound.
 */
const workspaceRootCache = new Map<string, string | null>();

export function findCargoWorkspaceRoot(cwd: string, timeoutMs: number): string | null {
	if (workspaceRootCache.has(cwd)) return workspaceRootCache.get(cwd) ?? null;
	const r = runCargo(["metadata", "--format-version", "1", "--no-deps"], cwd, timeoutMs);
	if (r.exitCode !== 0) {
		workspaceRootCache.set(cwd, null);
		return null;
	}
	let root: string | null = null;
	try {
		const meta = JSON.parse(r.stdout);
		if (typeof meta?.workspace_root === "string") root = meta.workspace_root;
	} catch {
		root = null;
	}
	workspaceRootCache.set(cwd, root);
	return root;
}

/**
 * The end-of-turn check is the only caller, and it runs at most once per turn,
 * so there is nothing for a cache to save and no stale result to invalidate.
 */
export function runWorkspaceClippy(root: string, timeoutMs: number): CargoResult {
	return runCargo(["clippy", "--workspace", "--all-targets", "--", "-D", "warnings"], root, timeoutMs);
}

export function filterLinesContaining(output: string, needle: string, limit = 10): string[] {
	return output
		.split("\n")
		.filter((line) => line.includes(needle))
		.slice(0, limit);
}

export function filterClippyErrors(output: string, limit = 15): string[] {
	return output
		.split("\n")
		.filter((line) => /^error/i.test(line.trim()))
		.slice(0, limit);
}
