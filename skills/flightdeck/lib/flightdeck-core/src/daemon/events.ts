// Port of flightdeck-daemon.bash::append_event + recover_stranded_drains.
//
// drain_events and ack_and_drain are already implemented via
// src/state/locking.ts::lockedEventsDrain — same flock-held mv + cat
// pattern as bash. recover_stranded_drains runs inside lockedEventsDrain
// (the bash script handles orphan .draining.<pid> sweeps under the
// same SESSION_LOCK).
//
// Dedup contract (bash daemon):
//   key = "${pane_id}|${hash}|${tag}"
//   if LAST_EVENT_KEY[key] is set → no-op
//   otherwise append + extend in-flight in WAKE_PENDING if present, all
//   under SESSION_LOCK to serialize with drain_events / ack_and_drain.
//
// `reason` and `stable_age_sec` are payload fields but NOT part of the
// dedup key — longer-stable updates don't re-fire (bash comment).

import { spawnSync } from "node:child_process";

import { BG_TASK_EXIT_CLASSIFIER_TAG } from "../events/bg-task-exit.ts";

export interface AppendEventOpts {
	paneId: string;
	hash: string;
	tag: string;
	reason: string;
	ageSec?: number;
	isBell?: boolean;
	extraJson?: string; // JSON serialization or "null"
	sessionLock: string;
	eventsFile: string;
	wakePending: string;
	lastEventKey: Map<string, true>;
}

// Returns true if appended, false if deduped.
export function appendEvent(opts: AppendEventOpts): boolean {
	const { paneId, hash, tag, reason, sessionLock, eventsFile, wakePending, lastEventKey } = opts;
	const age = opts.ageSec ?? 0;
	const isBell = opts.isBell ?? false;
	const extraJson = opts.extraJson ?? "null";

	const dedup = `${paneId}|${hash}|${tag}`;
	if (lastEventKey.has(dedup)) return false;
	lastEventKey.set(dedup, true);

	// Single bash child holds SESSION_LOCK for the append + in-flight
	// extend. Mirrors bash exec 202>SESSION_LOCK / flock 202 / jq -nc.
	// Inputs pass through positional args — no interpolation. The `is_bell`
	// argument arrives as JSON true/false so --argjson treats it as bool.
	const isoNow = new Date().toISOString();
	const script = `
		set -e
		ef="$1"; wp="$2"; ts="$3"; pid="$4"; hash="$5"; tag="$6"; reason="$7"; age="$8"; is_bell="$9"; extra="\${10}"
		jq -nc --arg ts "$ts" \\
			--arg pid "$pid" \\
			--arg hash "$hash" \\
			--arg tag "$tag" \\
			--arg reason "$reason" \\
			--argjson age "$age" \\
			--argjson extra "$extra" \\
			'{ts:$ts, pane_id:$pid, hash:$hash, tag:$tag, reason:$reason, stable_age_sec:$age} + (if $extra == null then {} else {details:$extra} end)' >> "$ef"
		if [[ -f "$wp" ]]; then
			tmp="$wp.tmp.$$"
			if jq --arg p "$pid" --arg h "$hash" --arg t "$tag" --argjson ib "$is_bell" \\
				'.in_flight += [{pane_id:$p, hash:$h, tag:$t, is_bell:$ib}]' \\
				"$wp" > "$tmp" 2>/dev/null; then
				mv "$tmp" "$wp"
			else
				rm -f "$tmp"
			fi
		fi
	`;
	const r = spawnSync("flock", [
		"-x", sessionLock, "bash", "-c", script, "_",
		eventsFile, wakePending,
		isoNow, paneId, hash, tag, reason,
		String(age), String(isBell), extraJson,
	], { encoding: "utf8" });
	if (r.status !== 0) {
		process.stderr.write(`append_event failed: ${r.stderr ?? ""}`);
		// Roll back the dedup marker so the next tick can retry.
		lastEventKey.delete(dedup);
		return false;
	}
	return true;
}

// Bash's CANONICAL_TAGS allowlist (lines 130-145). Stable-wake events
// only fire when the classifier tag matches one of these; non-canonical
// tags are recorded as "notified" so the daemon stops re-classifying
// the same hash but does not deliver a wake.
// Byte-equivalent to the bash CANONICAL_TAGS array (flightdeck-daemon.bash
// line 130). Order doesn't matter for set membership.
const CANONICAL_TAGS = new Set<string>([
	"terminal-state-reached",
	"force-push-prompt",
	"merge-now",
	"cleanup-prompt",
	// Flightdeck cleanup-scope defensive tags (issue #18). Per-issue
	// orchestration should never surface these under FLIGHTDECK_MANAGED=1,
	// but if an older orchestration build does, master needs to wake on
	// the stable buffer so the handler in handle-prompt.md § 4.6 can
	// answer Keep. Without these in the allowlist the daemon records the
	// hash as notified and never fires wake.
	"stale-no-pr-branch",
	"stale-orphan-worktree",
	"rebase-multi-choice",
	"generic-multi-choice",
	"multi-select-tabbed",
	"awaiting-direction",
	"bash-permission-prompt",
	"modal-prompt",
	"bot-review-wait-stuck",
	"audit-relation-prompt",
	"merge-ready-but-unknown",
	"force-merge-confirm",
	"external-fix-suggestions",
	"cycle-fix-suggestions",
	"descope-related",
	"oc-question",
	"pi-question",
	"pi-subagent-completion",
	BG_TASK_EXIT_CLASSIFIER_TAG,
	"domain-mismatch",
]);

export function isCanonicalTag(tag: string): boolean {
	return CANONICAL_TAGS.has(tag);
}
