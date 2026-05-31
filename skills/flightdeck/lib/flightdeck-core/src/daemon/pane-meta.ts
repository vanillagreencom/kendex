// Port of flightdeck-daemon.bash::{resolve_pane_id, refresh_pane_cache,
// pane_target_from_id, window_id_for_pane, bell_flag_for_pane,
// activity_flag_for_pane, pane_in_mode_for_pane, pane_alive,
// session_alive, capture_pane, capture_hash_12, stability_for_harness,
// classify_buffer}.
//
// Per-tick cache: one `tmux list-panes -a` call refreshes a Map keyed
// by pane_id. Bash quirk: PANE_TARGET_CACHE empty entry means "pane
// gone" — pane_alive returns false when the cache has no entry.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";

import { FINAL_GITHUB_PULL_URL_PATTERN } from "../classifier/github-pr-url.ts";

export interface PaneMeta {
	target: string;
	windowId: string;
	bell: number;
	activity: number;
	inMode: number;
	panePid: number;
}

export class PaneCache {
	private map: Map<string, PaneMeta> = new Map();

	refresh(): void {
		this.map.clear();
		const r = spawnSync(
			"tmux",
			["list-panes", "-a", "-F", "#{pane_id}|#{session_name}:#{window_index}.#{pane_index}|#{window_id}|#{window_bell_flag}|#{window_activity_flag}|#{pane_in_mode}|#{pane_pid}"],
			{ encoding: "utf8" },
		);
		if (r.status !== 0) return;
		for (const line of (r.stdout ?? "").split("\n")) {
			if (!line) continue;
			const parts = line.split("|");
			if (parts.length < 6) continue;
			const [pid, target, windowId, bell, activity, inMode, panePidRaw] = parts as [string, string, string, string, string, string, string | undefined];
			if (!pid) continue;
			this.map.set(pid, {
				target,
				windowId,
				bell: Number.parseInt(bell || "0", 10) || 0,
				activity: Number.parseInt(activity || "0", 10) || 0,
				inMode: Number.parseInt(inMode || "0", 10) || 0,
				panePid: Number.parseInt(panePidRaw || "0", 10) || 0,
			});
		}
	}

	target(paneId: string): string { return this.map.get(paneId)?.target ?? ""; }
	windowId(paneId: string): string { return this.map.get(paneId)?.windowId ?? ""; }
	bell(paneId: string): number { return this.map.get(paneId)?.bell ?? 0; }
	activity(paneId: string): number { return this.map.get(paneId)?.activity ?? 0; }
	inMode(paneId: string): number { return this.map.get(paneId)?.inMode ?? 0; }
	panePid(paneId: string): number { return this.map.get(paneId)?.panePid ?? 0; }
	alive(paneId: string): boolean { return this.map.has(paneId); }
}

// Resolve a tmux pane target (e.g. "session:window.0") to a stable
// %pane_id. Gates on `tmux list-panes -t <target>` first because
// `display-message -t <bogus>` silently falls back to the active pane
// (bash daemon footgun comment + worktree rule).
export function resolvePaneId(target: string): string {
	const exists = spawnSync("tmux", ["list-panes", "-t", target], { stdio: ["ignore", "ignore", "ignore"] });
	if (exists.status !== 0) return "";
	const r = spawnSync("tmux", ["display-message", "-p", "-t", target, "#{pane_id}"], { encoding: "utf8" });
	if (r.status !== 0) return "";
	const id = (r.stdout ?? "").trim();
	if (!id || !id.startsWith("%")) return "";
	return id;
}

export function sessionAlive(sessionId: string): boolean {
	if (!sessionId) return false;
	const r = spawnSync("tmux", ["list-sessions", "-F", "#{session_id}"], { encoding: "utf8" });
	if (r.status !== 0) return false;
	for (const line of (r.stdout ?? "").split("\n")) {
		if (line.trim() === sessionId) return true;
	}
	return false;
}

// Capture a pane buffer. Returns empty string on failure (the bash
// daemon's `|| echo ""` shape).
export function capturePane(target: string, captureLines: number): string {
	const r = spawnSync(
		"tmux",
		["capture-pane", "-t", target, "-p", "-S", `-${captureLines}`],
		{ encoding: "utf8" },
	);
	if (r.status !== 0) return "";
	return r.stdout ?? "";
}

// SHA256 prefix (first 12 hex chars) matches the bash daemon's hash
// domain — adapter events, pane-poll output, and capture fallback all
// share the same hash space so dedup keys align across paths.
export function captureHash12(text: string): string {
	return createHash("sha256").update(text).digest("hex").slice(0, 12);
}

// Bash's stability_for_harness only returns STABILITY_SEC; harness-
// specific tuning was historically in this function but flattened. Keep
// the indirection so future per-harness tuning has a place to land.
export function stabilityForHarness(_harness: string, defaultStability: number): number {
	return defaultStability;
}

// Classify a buffer. When CLASSIFIER is set + executable, pipe stdin
// to it and read the tag. Otherwise apply the bash daemon's built-in
// regex stub. The CLASSIFIER subprocess is the production path; the
// regex stub is for prototype/test mode and matches bash's fallback.
export interface ClassifyOpts {
	classifierBin?: string;
	noFooterGate?: boolean;
}

export function classifyBuffer(buf: string, opts: ClassifyOpts = {}): string {
	const { classifierBin, noFooterGate } = opts;
	if (classifierBin) {
		const args = noFooterGate ? ["--no-footer-gate"] : [];
		const r = spawnSync(classifierBin, args, { encoding: "utf8", input: buf });
		if (r.status === 0) {
			const tag = (r.stdout ?? "").trim();
			return tag || "rendering";
		}
		return "rendering";
	}
	// Built-in stub. Order matters for parity with bash daemon classifier
	// fallback (line 422 onwards).
	if (/merged.*please end|terminal.state|please end the session/i.test(buf)) return "terminal-state-reached";
	if (/force.?push|--force-with-lease/i.test(buf)) return "force-push-prompt";
	if (/merge now|merge.?ready|ready to merge/i.test(buf)) return "merge-now";
	if (/cleanup|delete worktree|keep worktree/i.test(buf)) return "cleanup-prompt";
	if (/rebase.*conflict|how.*resolve.*conflict/i.test(buf)) return "rebase-multi-choice";
	if (noFooterGate && FINAL_GITHUB_PULL_URL_PATTERN.test(buf)) return "terminal-state-reached";
	if (/\[1\][^\n]*\[2\]|\(1\)[^\n]*\(2\)/.test(buf)) return "generic-multi-choice";
	if (/allow.*\?|permission.*to run|approve this command/i.test(buf)) return "bash-permission-prompt";
	return "rendering";
}
