// One trailing call per window. The first request arms a timer; requests that
// arrive before it fires join that one call. Later requests arm a new window,
// so a steady stream of requests runs `fn` once per `delayMs`, never once per
// request and never starved by the stream.

export interface CoalescedCall {
	/** Run `fn` once, `delayMs` after the first request of this window. */
	request(): void;
	/** Drop the pending call, for a caller that just ran the work itself. */
	cancel(): void;
}

export interface CoalescedCallTimers {
	setTimer?: (cb: () => void, ms: number) => NodeJS.Timeout;
	clearTimer?: (handle: NodeJS.Timeout) => void;
}

export function createCoalescedCall(fn: () => void, delayMs: number, timers: CoalescedCallTimers = {}): CoalescedCall {
	const setTimer = timers.setTimer ?? ((cb, ms) => setTimeout(cb, ms));
	const clearTimer = timers.clearTimer ?? ((handle) => clearTimeout(handle));
	let timer: NodeJS.Timeout | null = null;
	return {
		request() {
			if (timer) return;
			timer = setTimer(() => {
				timer = null;
				fn();
			}, delayMs);
			(timer as { unref?: () => void }).unref?.();
		},
		cancel() {
			if (!timer) return;
			clearTimer(timer);
			timer = null;
		},
	};
}
