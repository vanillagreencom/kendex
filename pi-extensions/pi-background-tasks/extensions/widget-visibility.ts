export type BackgroundWidgetMode = "compact" | "expanded" | "hidden";
export type VisibleBackgroundWidgetMode = Exclude<BackgroundWidgetMode, "hidden">;

export interface BackgroundWidgetVisibilityState {
	mode: BackgroundWidgetMode;
	lastVisibleMode: VisibleBackgroundWidgetMode;
}

export function visibleBackgroundWidgetMode(mode: BackgroundWidgetMode | undefined): VisibleBackgroundWidgetMode {
	return mode === "expanded" ? "expanded" : "compact";
}

export function createBackgroundWidgetVisibility(mode: BackgroundWidgetMode = "compact"): BackgroundWidgetVisibilityState {
	return { mode, lastVisibleMode: visibleBackgroundWidgetMode(mode) };
}

export function toggleBackgroundWidgetVisibility(state: BackgroundWidgetVisibilityState): void {
	if (state.mode === "hidden") {
		state.mode = state.lastVisibleMode;
		return;
	}
	state.lastVisibleMode = visibleBackgroundWidgetMode(state.mode);
	state.mode = "hidden";
}

export function shouldRenderBackgroundWidget(input: { hasUi: boolean; trackedTaskCount: number; visibleTaskCount: number; showWidget: boolean; mode: BackgroundWidgetMode }): boolean {
	return input.hasUi && input.trackedTaskCount > 0 && input.visibleTaskCount > 0 && input.showWidget && input.mode !== "hidden";
}

export function nextBackgroundWidgetExpiryDelay(
	tasks: Iterable<{ status: string; updatedAt: number }>,
	retentionMs: number,
	now: number,
): number | null {
	let delay: number | null = null;
	for (const task of tasks) {
		if (task.status === "running") continue;
		const remaining = task.updatedAt + retentionMs - now;
		if (remaining < 0) continue;
		const candidate = remaining + 1;
		delay = delay === null ? candidate : Math.min(delay, candidate);
	}
	return delay;
}

// Expiry uses one-shot timers so relative-time labels do not restore the old
// per-second full-screen render interval.
export function createBackgroundWidgetExpiryScheduler(
	refresh: () => void,
	scheduleTimer: typeof setTimeout = setTimeout,
	clearTimer: typeof clearTimeout = clearTimeout,
): {
	clear: () => void;
	schedule: (tasks: Iterable<{ status: string; updatedAt: number }>, retentionMs: number, now: number) => void;
} {
	let timer: ReturnType<typeof setTimeout> | null = null;
	const clear = () => {
		if (timer) clearTimer(timer);
		timer = null;
	};
	return {
		clear,
		schedule(tasks, retentionMs, now) {
			clear();
			const delay = nextBackgroundWidgetExpiryDelay(tasks, retentionMs, now);
			if (delay === null) return;
			timer = scheduleTimer(() => {
				timer = null;
				refresh();
			}, delay);
			timer.unref?.();
		},
	};
}
