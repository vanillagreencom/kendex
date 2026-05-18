// Pi subscriber → generic terminal-state-reached wake decision (vstack#61/#117).
//
// This module is intentionally NOT wired into the TS daemon loop; the
// runtime emit path lives in `scripts/lib/subscribers.bash`
// `pi_subscriber_loop`, which mirrors this function 1:1. The TS export
// exists only as the canonical reference + unit-test surface.
//
// The bash Pi subscriber in scripts/lib/subscribers.bash sees assistant
// message_end events with stopReason set. For generic Pi entries (adhoc or
// workflow) we treat `isIdle: true && hasPendingMessages: false` as terminal
// and emit a wake-event row carrying classifier_tag=terminal-state-reached
// so the daemon's existing canonical-tag path delivers a wake to master.
//
// This module owns the pure decision so:
//   - The bash mirror has a clear canonical reference to stay in lock
//     step with (the CLAUDE.md parity rule).
//   - We can unit-test the row shape and gating exhaustively without
//     spawning bash + pi-bridge.

import { createHash } from "node:crypto";
import { classifyPiBridgeState, type PiBridgeStateLike } from "../classifier/pi-bridge-state.ts";

export interface PiAdhocWakeRow {
	ts: string;
	pane_id: string;
	harness: "pi";
	last_assistant_text: string;
	classifier_tag: "terminal-state-reached";
	hash: string;
}

export interface PiAdhocWakeDecision {
	emit: false;
	reason: string;
}

export interface PiAdhocWakeOk {
	emit: true;
	row: PiAdhocWakeRow;
}

export type PiAdhocWakeOutcome = PiAdhocWakeDecision | PiAdhocWakeOk;

export interface PiAdhocWakeInput {
	paneId: string;
	entryKind: string;
	entryHarness: string;
	bridgeState: PiBridgeStateLike | null | undefined;
	/**
	 * Hash of the last assistant text in the same encoding the bash
	 * subscriber uses (sha256 of the assistant text, first 12 hex chars).
	 * Required by the parity hash format `<paneId>|adhoc-pi-idle|<hash>`
	 * — the bash mirror produces this same dedup key, so the TS canonical
	 * reference must compute identically.
	 */
	assistantTextHash: string;
	now?: () => Date;
}

/** Stable middle segment of the dedup hash key; matches bash literal. */
export const ADHOC_PI_IDLE_HASH_TAG = "adhoc-pi-idle" as const;

function shortHash(parts: readonly string[]): string {
	return createHash("sha256").update(parts.join("|")).digest("hex").slice(0, 12);
}

/**
 * Compute the dedup hash that the bash subscriber would produce given
 * the same pane id and assistant-text hash. Exported so tests can
 * assert parity directly.
 *
 * Bash mirror (scripts/lib/subscribers.bash::pi_subscriber_loop):
 *   term_hash=$(printf '%s|adhoc-pi-idle|%s' "$pane_id" "$hash" \
 *                | sha256sum | awk '{print substr($1,1,12)}')
 */
export function piAdhocWakeHash(paneId: string, assistantTextHash: string): string {
	return shortHash([paneId, ADHOC_PI_IDLE_HASH_TAG, assistantTextHash]);
}

export function decidePiAdhocWake(input: PiAdhocWakeInput): PiAdhocWakeOutcome {
	if (!input.paneId) return { emit: false, reason: "missing-pane-id" };
	const classification = classifyPiBridgeState(input.bridgeState, {
		entryKind: input.entryKind,
		entryHarness: input.entryHarness,
	});
	if (classification.tag !== "terminal-state-reached") {
		return { emit: false, reason: classification.matched || classification.tag };
	}
	const ts = (input.now?.() ?? new Date()).toISOString();
	const hash = piAdhocWakeHash(input.paneId, input.assistantTextHash);
	return {
		emit: true,
		row: {
			ts,
			pane_id: input.paneId,
			harness: "pi",
			last_assistant_text: "",
			classifier_tag: "terminal-state-reached",
			hash,
		},
	};
}
