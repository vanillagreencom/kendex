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

export interface GuardDispatchInput {
	trigger: BudgetTrigger | undefined;
	compact: ((options: GuardCompactOptions) => void) | undefined;
	notify: (message: string, level: GuardLevel) => void;
	onStatus?: (message: string | undefined) => void;
	staleCtx?: () => boolean;
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

interface InFlightDispatch {
	id: number;
	key: string;
	sessionCompactVersion: number;
}

export class BudgetGuardDriver {
	private satisfiedKey: string | undefined;
	private pendingTrigger: BudgetTrigger | undefined;
	private inFlight: InFlightDispatch | undefined;
	private sessionCompactVersion = 0;
	private nextDispatchId = 1;

	reset(): void {
		this.satisfiedKey = undefined;
		this.pendingTrigger = undefined;
		this.inFlight = undefined;
		this.sessionCompactVersion = 0;
		this.nextDispatchId = 1;
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
		this.inFlight = undefined;
	}

	/** Dispatch a trigger previously staged by agent_end. */
	dispatchPending(input: GuardPendingDispatchInput): DispatchOutcome {
		if (input.staleCtx?.()) return { kind: "ignored" };
		if (this.inFlight) return { kind: "in-flight" };
		const trigger = this.pendingTrigger;
		if (!trigger) return { kind: "no-trigger" };
		if (trigger.key === this.satisfiedKey) {
			this.pendingTrigger = undefined;
			return { kind: "dedup" };
		}
		if (typeof input.compact !== "function") {
			input.notify(`QOL budget guard cannot fire: ctx.compact is unavailable (${trigger.reason}).`, "warning");
			return { kind: "no-compact-fn" };
		}

		input.notify(`QOL budget guard starting compaction: ${trigger.reason}`, "info");
		input.onStatus?.(`QOL budget guard compacting session: ${trigger.reason}`);
		const dispatch: InFlightDispatch = {
			id: this.nextDispatchId,
			key: trigger.key,
			sessionCompactVersion: this.sessionCompactVersion,
		};
		this.nextDispatchId += 1;
		this.pendingTrigger = undefined;
		this.inFlight = dispatch;
		this.satisfiedKey = trigger.key;
		const instructions = `${QOL_BUDGET_GUARD_SENTINEL} QOL budget guard triggered at agent_end because ${trigger.reason}. Bound the summary input, preserve current task state, decisions, files, blockers, and next steps.`;

		try {
			input.compact({
				customInstructions: instructions,
				onComplete: () => {
					if (this.inFlight?.id === dispatch.id) this.inFlight = undefined;
					this.satisfiedKey = dispatch.key;
					input.onStatus?.(undefined);
					input.notify("QOL budget guard compaction completed.", "info");
				},
				onError: (error: Error) => {
					const duplicateCompletedAfterDispatch =
						error.message === "Already compacted" &&
						this.sessionCompactVersion > dispatch.sessionCompactVersion;
					if (duplicateCompletedAfterDispatch) {
						if (this.inFlight?.id === dispatch.id) this.inFlight = undefined;
						this.satisfiedKey = dispatch.key;
						input.onStatus?.(undefined);
						return;
					}

					if (this.inFlight?.id === dispatch.id) {
						this.inFlight = undefined;
						// A later session_compact already satisfied this key even when
						// this callback reports a different, visible error.
						if (this.sessionCompactVersion === dispatch.sessionCompactVersion) {
							this.satisfiedKey = undefined;
						}
					}
					input.onStatus?.(undefined);
					input.notify(`QOL budget guard compaction failed: ${error.message}`, "error");
				},
			});
			return { kind: "dispatched", reason: trigger.reason };
		} catch (error) {
			if (this.inFlight?.id === dispatch.id) this.inFlight = undefined;
			this.satisfiedKey = undefined;
			input.onStatus?.(undefined);
			const message = error instanceof Error ? error.message : String(error);
			input.notify(`QOL budget guard compaction failed to start: ${message}`, "error");
			return { kind: "dispatch-threw", error: message, reason: trigger.reason };
		}
	}

	/** Immediate convenience path retained for focused driver tests and callers. */
	dispatch(input: GuardDispatchInput): DispatchOutcome {
		const staged = this.stage(input.trigger, input.staleCtx);
		if (staged.kind !== "staged" && !(staged.kind === "dedup" && this.pendingTrigger)) return staged;
		return this.dispatchPending({
			compact: input.compact,
			notify: input.notify,
			onStatus: input.onStatus,
			staleCtx: input.staleCtx,
		});
	}
}
