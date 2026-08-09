// Runtime dispatch for the long-session budget guard. Agent-end observation and
// settled-time dispatch are separate so Pi's built-in post-agent compaction gets
// first refusal. The driver owns pending, satisfied, and in-flight trigger state.

import { QOL_BUDGET_GUARD_SENTINEL, type BudgetTrigger } from "./budget-guard.js";

export type GuardLevel = "info" | "warning" | "error";

export interface GuardCompactOptions {
	customInstructions?: string;
	onComplete?: (...args: unknown[]) => void;
	onError?: (error: Error) => void;
}

export interface GuardPendingDispatchInput {
	compact: ((options: GuardCompactOptions) => void) | undefined;
	notify: (message: string, level: GuardLevel) => void;
	onStatus?: (message: string | undefined) => void;
	staleCtx?: () => boolean;
}

export type DispatchOutcome =
	| { kind: "ignored" }
	| { kind: "no-trigger" }
	| { kind: "staged"; reason: string }
	| { kind: "dedup" }
	| { kind: "in-flight" }
	| { kind: "no-compact-fn" }
	| { kind: "dispatched"; reason: string }
	| { kind: "dispatch-threw"; reason: string; error: string };

export interface GuardDispatchResult {
	outcome: DispatchOutcome;
	completion: Promise<void>;
}

interface InFlightDispatch {
	key: string;
	sessionCompactVersion: number;
	resolveCompletion: () => void;
}

export class BudgetGuardDriver {
	private satisfiedKey: string | undefined;
	private pendingTrigger: BudgetTrigger | undefined;
	private inFlight: InFlightDispatch | undefined;
	private sessionCompactVersion = 0;

	reset(): void {
		this.inFlight?.resolveCompletion();
		this.satisfiedKey = undefined;
		this.pendingTrigger = undefined;
		this.inFlight = undefined;
		this.sessionCompactVersion = 0;
	}

	/** Returns true when no compaction call is currently active. Visible for tests. */
	get canFire(): boolean {
		return this.inFlight === undefined;
	}

	get currentKey(): string | undefined {
		return this.inFlight?.key ?? this.pendingTrigger?.key ?? this.satisfiedKey;
	}

	/**
	 * Observe the trigger at agent_end without calling ctx.compact. Pi performs
	 * its built-in post-agent compaction check before agent_settled, so staging
	 * here prevents two compaction attempts from racing each other.
	 */
	stage(trigger: BudgetTrigger | undefined, staleCtx?: () => boolean): DispatchOutcome {
		if (staleCtx?.()) return { kind: "ignored" };
		if (this.inFlight) return { kind: "in-flight" };
		if (!trigger) {
			this.pendingTrigger = undefined;
			this.satisfiedKey = undefined;
			return { kind: "no-trigger" };
		}
		if (trigger.key === this.satisfiedKey || trigger.key === this.pendingTrigger?.key) {
			return { kind: "dedup" };
		}
		this.pendingTrigger = trigger;
		return { kind: "staged", reason: trigger.reason };
	}

	/**
	 * A completed Pi compaction satisfies whichever budget trigger is pending or
	 * in flight. Keep that key suppressed until usage produces no trigger or a
	 * genuinely different trigger key.
	 */
	noteSessionCompacted(): void {
		this.sessionCompactVersion += 1;
		const currentKey = this.inFlight?.key ?? this.pendingTrigger?.key;
		if (currentKey) this.satisfiedKey = currentKey;
		this.pendingTrigger = undefined;
	}

	/** Dispatch a trigger previously staged by agent_end. */
	dispatchPending(input: GuardPendingDispatchInput): GuardDispatchResult {
		const completed = (outcome: DispatchOutcome): GuardDispatchResult => ({ completion: Promise.resolve(), outcome });
		if (input.staleCtx?.()) return completed({ kind: "ignored" });
		if (this.inFlight) return completed({ kind: "in-flight" });
		const trigger = this.pendingTrigger;
		if (!trigger) return completed({ kind: "no-trigger" });
		if (trigger.key === this.satisfiedKey) {
			this.pendingTrigger = undefined;
			return completed({ kind: "dedup" });
		}
		if (typeof input.compact !== "function") {
			input.notify(`QOL budget guard cannot fire: ctx.compact is unavailable (${trigger.reason}).`, "warning");
			return completed({ kind: "no-compact-fn" });
		}

		input.notify(`QOL budget guard starting compaction: ${trigger.reason}`, "info");
		input.onStatus?.(`QOL budget guard compacting session: ${trigger.reason}`);
		let resolveCompletion = () => {};
		const completion = new Promise<void>((resolve) => {
			resolveCompletion = resolve;
		});
		const dispatch: InFlightDispatch = {
			key: trigger.key,
			resolveCompletion,
			sessionCompactVersion: this.sessionCompactVersion,
		};
		this.pendingTrigger = undefined;
		this.inFlight = dispatch;
		this.satisfiedKey = trigger.key;
		const instructions = `${QOL_BUDGET_GUARD_SENTINEL} QOL budget guard triggered at agent_end because ${trigger.reason}. Bound the summary input, preserve current task state, decisions, files, blockers, and next steps.`;

		try {
			input.compact({
				customInstructions: instructions,
				onComplete: () => {
					if (this.inFlight !== dispatch) return;
					try {
						this.inFlight = undefined;
						this.satisfiedKey = dispatch.key;
						input.onStatus?.(undefined);
						input.notify("QOL budget guard compaction completed.", "info");
					} finally {
						dispatch.resolveCompletion();
					}
				},
				onError: (error: Error) => {
					if (this.inFlight !== dispatch) return;
					const duplicateCompletedAfterDispatch =
						error.message === "Already compacted" &&
						this.sessionCompactVersion > dispatch.sessionCompactVersion;
					if (duplicateCompletedAfterDispatch) {
						try {
							this.inFlight = undefined;
							this.satisfiedKey = dispatch.key;
							input.onStatus?.(undefined);
						} finally {
							dispatch.resolveCompletion();
						}
						return;
					}

					try {
						this.inFlight = undefined;
						// A later session_compact already satisfied this key even when
						// this callback reports a different, visible error.
						if (this.sessionCompactVersion === dispatch.sessionCompactVersion) {
							this.satisfiedKey = undefined;
						}
						input.onStatus?.(undefined);
						input.notify(`QOL budget guard compaction failed: ${error.message}`, "error");
					} finally {
						dispatch.resolveCompletion();
					}
				},
			});
			return { completion, outcome: { kind: "dispatched", reason: trigger.reason } };
		} catch (error) {
			if (this.inFlight === dispatch) {
				try {
					this.inFlight = undefined;
					this.satisfiedKey = undefined;
					input.onStatus?.(undefined);
					const message = error instanceof Error ? error.message : String(error);
					input.notify(`QOL budget guard compaction failed to start: ${message}`, "error");
					return { completion, outcome: { kind: "dispatch-threw", error: message, reason: trigger.reason } };
				} finally {
					dispatch.resolveCompletion();
				}
			}
			dispatch.resolveCompletion();
			const message = error instanceof Error ? error.message : String(error);
			return { completion, outcome: { kind: "dispatch-threw", error: message, reason: trigger.reason } };
		}
	}

}
