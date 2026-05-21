// Runtime dispatch for the agent_end budget guard. Owns the last-crossing
// key and in-flight flag so the guard fires exactly once per threshold
// crossing, validates ctx.compact before marking in-flight, and clears the
// crossing key on failure so the next agent_end can retry.

import { QOL_BUDGET_GUARD_SENTINEL, type BudgetTrigger } from "./budget-guard.js";

export type GuardLevel = "info" | "warning" | "error";

export interface GuardCompactOptions {
	customInstructions?: string;
	onComplete?: (...args: unknown[]) => void;
	onError?: (error: Error) => void;
}

export interface GuardDispatchInput {
	trigger: BudgetTrigger | undefined;
	compact: ((options: GuardCompactOptions) => void) | undefined;
	notify: (message: string, level: GuardLevel) => void;
	staleCtx?: () => boolean;
}

export type DispatchOutcome =
	| { kind: "ignored" }
	| { kind: "no-trigger" }
	| { kind: "dedup" }
	| { kind: "in-flight" }
	| { kind: "no-compact-fn" }
	| { kind: "dispatched"; reason: string }
	| { kind: "dispatch-threw"; reason: string; error: string }
	| { kind: "complete" }
	| { kind: "failed"; error: string };

export class BudgetGuardDriver {
	private lastKey: string | undefined;
	private inFlight = false;

	reset(): void {
		this.lastKey = undefined;
		this.inFlight = false;
	}

	/** Returns true if the next call to dispatch is allowed to fire. Visible for tests. */
	get canFire(): boolean {
		return !this.inFlight;
	}

	get currentKey(): string | undefined {
		return this.lastKey;
	}

	noteSessionCompacted(): void {
		// Successful compaction drops usage below the budget; let the next
		// crossing re-fire.
		this.lastKey = undefined;
		this.inFlight = false;
	}

	dispatch(input: GuardDispatchInput): DispatchOutcome {
		if (input.staleCtx?.()) return { kind: "ignored" };
		if (this.inFlight) return { kind: "in-flight" };
		const trigger = input.trigger;
		if (!trigger) {
			this.lastKey = undefined;
			return { kind: "no-trigger" };
		}
		if (trigger.key === this.lastKey) return { kind: "dedup" };
		if (typeof input.compact !== "function") {
			input.notify(`QOL budget guard cannot fire: ctx.compact is unavailable (${trigger.reason}).`, "warning");
			return { kind: "no-compact-fn" };
		}
		input.notify(`QOL budget guard starting compaction: ${trigger.reason}`, "info");
		this.inFlight = true;
		this.lastKey = trigger.key;
		const instructions = `${QOL_BUDGET_GUARD_SENTINEL} QOL budget guard triggered at agent_end because ${trigger.reason}. Bound the summary input, preserve current task state, decisions, files, blockers, and next steps.`;
		try {
			input.compact({
				customInstructions: instructions,
				onComplete: () => {
					this.inFlight = false;
					input.notify("QOL budget guard compaction completed.", "info");
				},
				onError: (error: Error) => {
					this.inFlight = false;
					// Allow the next agent_end to retry rather than poisoning the
					// crossing key after a transient failure.
					this.lastKey = undefined;
					input.notify(`QOL budget guard compaction failed: ${error.message}`, "error");
				},
			});
			return { kind: "dispatched", reason: trigger.reason };
		} catch (error) {
			this.inFlight = false;
			this.lastKey = undefined;
			const message = error instanceof Error ? error.message : String(error);
			input.notify(`QOL budget guard compaction failed to start: ${message}`, "error");
			return { kind: "dispatch-threw", error: message, reason: trigger.reason };
		}
	}
}
