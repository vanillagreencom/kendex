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
