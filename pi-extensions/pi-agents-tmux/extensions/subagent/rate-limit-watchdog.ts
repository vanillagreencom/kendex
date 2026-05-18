/**
 * Subagent rate-limit watchdog (vstack#108).
 *
 * Rides on `pi.on("message_end")` inside a persistent subagent pane.
 * When the canonical rate-limit signature appears (assistant message_end
 * with `stopReason==="error"` and a Claude-side "temporarily limiting
 * requests" / "Rate limited" / 429 error payload), this watchdog:
 *
 *   1. Picks a retry-at delay from the shared decideRateLimitRetry
 *      decision module in flightdeck-core (so the bash subscriber and
 *      this layer share the same backoff ladder + canonical detection).
 *   2. Schedules a `pi.sendUserMessage(STEER_MESSAGE, { deliverAs })` for that retry
 *      time. The fixed steer prose is mandated by the issue body so the
 *      child agent has a deterministic recovery signal.
 *   3. Emits agent.rate_limited (first detection per pane) and
 *      agent.rate_limit_retry (each scheduled attempt) broker events so
 *      the dashboard Activity tab shows the recovery timeline.
 *   4. On every subsequent non-error assistant message_end, treats the
 *      pane as recovered: emits agent.rate_limit_resolved and resets
 *      the per-pane counter.
 *   5. After VSTACK_RATE_LIMIT_MAX_ATTEMPTS scheduled retries, emits
 *      agent.rate_limit_exhausted and calls onExhausted so the existing
 *      agent-end-watchdog can fall back to its synthetic
 *      needs_completion outbox path.
 *
 * The watchdog also exposes isAwaitingRetry(paneId) so the agent-end
 * handler in subagent/index.ts can skip its grace-timeout schedule
 * while a pane is mid-recovery — without that gate the synthetic
 * needs_completion outbox would race the steer.
 *
 * All side effects are injectable. Failures inside scheduleAfter /
 * sendUserMessage / emitActivity / onExhausted are swallowed so the
 * rate-limit recovery can never throw out of the parent pane.
 */

import {
	RATE_LIMIT_STEER_MESSAGE,
	decideRateLimitRetry,
	isAssistantMessageEvent,
	rateLimitBackoffLadderFromEnv,
	rateLimitMaxAttemptsFromEnv,
	rateLimitWatchdogEnabledFromEnv,
} from "./rate-limit-decision.js";

export type RateLimitOutcome =
	| { kind: "scheduled-retry"; at: number; attempt: number }
	| { kind: "exhausted"; attempt: number; reason: string }
	| { kind: "not-rate-limited"; reason: string }
	| { kind: "resolved"; previousAttempt: number }
	| { kind: "skipped-disabled" };

export interface SubagentRateLimitWatchdogDeps {
	now: () => number;
	scheduleAfter: (delayMs: number, fn: () => void) => { cancel: () => void };
	isEnabled: () => boolean;
	maxAttempts: () => number;
	backoffLadderSec: () => readonly number[];
	sendUserMessage: (message: string) => void | Promise<void>;
	emitActivity: (eventName: string, payload: Record<string, unknown>) => void;
	onExhausted: (paneId: string, attempt: number, reason: string) => void;
	logWarn: (message: string) => void;
}

export interface SubagentRateLimitWatchdog {
	onMessageEnd(event: unknown, paneId: string, agentName?: string, taskId?: string): RateLimitOutcome;
	isAwaitingRetry(paneId: string): boolean;
	cancel(paneId: string): boolean;
	/** Test helper: synchronously fire the pending steer for a pane. */
	fireRetryNow(paneId: string): boolean;
}

interface PaneState {
	attempt: number;
	pendingTimer: { cancel: () => void } | null;
	pendingRetry: { at: number; attempt: number; fire: () => void } | null;
	agentName?: string;
	taskId?: string;
}

export function watchdogEnabledFromEnv(env: NodeJS.ProcessEnv = process.env): boolean {
	return rateLimitWatchdogEnabledFromEnv(env);
}

export function maxAttemptsFromEnv(env: NodeJS.ProcessEnv = process.env): number {
	return rateLimitMaxAttemptsFromEnv(env);
}

export function backoffLadderSecFromEnv(env: NodeJS.ProcessEnv = process.env): readonly number[] {
	return rateLimitBackoffLadderFromEnv(env);
}

export function defaultScheduleAfter(delayMs: number, fn: () => void): { cancel: () => void } {
	const handle = setTimeout(fn, Math.max(0, delayMs));
	handle.unref?.();
	return {
		cancel: () => clearTimeout(handle),
	};
}

export function createSubagentRateLimitWatchdog(
	deps: SubagentRateLimitWatchdogDeps,
): SubagentRateLimitWatchdog {
	const panes = new Map<string, PaneState>();

	function paneState(paneId: string): PaneState {
		let state = panes.get(paneId);
		if (!state) {
			state = { attempt: 0, pendingRetry: null, pendingTimer: null };
			panes.set(paneId, state);
		}
		return state;
	}

	function clearPending(state: PaneState): void {
		if (state.pendingTimer) {
			try {
				state.pendingTimer.cancel();
			} catch {
				// best-effort
			}
			state.pendingTimer = null;
		}
		state.pendingRetry = null;
	}

	function emit(eventName: string, payload: Record<string, unknown>): void {
		try {
			deps.emitActivity(eventName, payload);
		} catch (error) {
			deps.logWarn(`rate-limit-watchdog: activity emit failed (${(error as Error)?.message ?? error})`);
		}
	}

	return {
		onMessageEnd(event, paneId, agentName, taskId): RateLimitOutcome {
			if (!deps.isEnabled()) return { kind: "skipped-disabled" };
			const state = paneState(paneId);
			if (agentName) state.agentName = agentName;
			if (taskId) state.taskId = taskId;

			const decision = decideRateLimitRetry(
				{
					attempt: state.attempt,
					event,
					lastRetryAt: state.pendingRetry?.at ?? null,
					now: deps.now(),
					paneId,
				},
				{ backoffLadderSec: deps.backoffLadderSec(), maxAttempts: deps.maxAttempts() },
			);

			if (decision.kind === "not-rate-limited") {
				emit("subagents:rate_limit_skipped", {
					agent: state.agentName,
					paneId,
					reason: decision.reason,
					taskId: state.taskId,
				});
				// Recovery branch: if the pane had been mid-rate-limit and just
				// produced a healthy assistant turn, emit resolved + reset state.
				// Non-assistant message_end events (toolResult/user echo of our own
				// steer) are ignored so they cannot retrigger or falsely resolve the
				// retry ladder.
				if (!isAssistantMessageEvent(event)) return { kind: "not-rate-limited", reason: decision.reason };
				if (state.pendingRetry === null && state.attempt > 0) {
					const previousAttempt = state.attempt;
					state.attempt = 0;
					emit("subagents:rate_limit_resolved", {
						agent: state.agentName,
						attempt: previousAttempt,
						paneId,
						taskId: state.taskId,
					});
					return { kind: "resolved", previousAttempt };
				}
				return { kind: "not-rate-limited", reason: decision.reason };
			}

			if (decision.kind === "exhausted") {
				clearPending(state);
				const exhaustedAttempt = decision.attempt;
				state.attempt = exhaustedAttempt;
				emit("subagents:rate_limit_exhausted", {
					agent: state.agentName,
					attempt: exhaustedAttempt,
					paneId,
					reason: decision.reason,
					taskId: state.taskId,
				});
				try {
					deps.onExhausted(paneId, exhaustedAttempt, decision.reason);
				} catch (error) {
					deps.logWarn(`rate-limit-watchdog: onExhausted handler failed (${(error as Error)?.message ?? error})`);
				}
				return { kind: "exhausted", attempt: exhaustedAttempt, reason: decision.reason };
			}

			// retry-at: cancel any pre-existing timer for the same pane (a
			// follow-up rate-limit before the first retry has fired) so the
			// schedule reflects the latest decision, then arm the retry.
			clearPending(state);
			const firstDetection = state.attempt === 0;
			const delayMs = Math.max(0, decision.at - deps.now());
			const eventName = firstDetection ? "subagents:rate_limited" : "subagents:rate_limit_retry";
			emit(eventName, {
				agent: state.agentName,
				attempt: decision.attempt,
				next_retry_at: decision.at,
				paneId,
				taskId: state.taskId,
			});
			state.attempt = decision.attempt;
			const fire = () => {
				const current = panes.get(paneId);
				if (!current || current.pendingRetry?.at !== decision.at) return;
				current.pendingTimer = null;
				current.pendingRetry = null;
				try {
					const dispatch = deps.sendUserMessage(RATE_LIMIT_STEER_MESSAGE);
					if (dispatch && typeof (dispatch as PromiseLike<void>).then === "function") {
						void Promise.resolve(dispatch).catch((error) => {
							deps.logWarn(`rate-limit-watchdog: steer dispatch failed (${(error as Error)?.message ?? error})`);
						});
					}
				} catch (error) {
					deps.logWarn(`rate-limit-watchdog: steer dispatch failed (${(error as Error)?.message ?? error})`);
				}
			};
			state.pendingTimer = deps.scheduleAfter(delayMs, fire);
			state.pendingRetry = { at: decision.at, attempt: decision.attempt, fire };
			return { kind: "scheduled-retry", at: decision.at, attempt: decision.attempt };
		},
		isAwaitingRetry(paneId: string): boolean {
			return panes.get(paneId)?.pendingRetry !== null && panes.get(paneId)?.pendingRetry !== undefined;
		},
		cancel(paneId: string): boolean {
			const state = panes.get(paneId);
			if (!state) return false;
			const had = state.pendingRetry !== null;
			clearPending(state);
			state.attempt = 0;
			return had;
		},
		fireRetryNow(paneId: string): boolean {
			const state = panes.get(paneId);
			if (!state?.pendingRetry) return false;
			const { fire } = state.pendingRetry;
			fire();
			return true;
		},
	};
}
