export type PanelState = "hidden" | "compact" | "expanded";
export type VisiblePanelState = Exclude<PanelState, "hidden">;

export interface TaskPanelVisibilityState {
	panel: PanelState;
	lastVisiblePanel: VisiblePanelState;
	hiddenByUser: boolean;
	autoShownThisSession: boolean;
}

export function normalizePanelState(value: unknown, fallback: PanelState = "compact"): PanelState {
	return value === "hidden" || value === "expanded" || value === "compact" ? value : fallback;
}

export function visiblePanelFor(panel: PanelState | undefined, fallback: VisiblePanelState = "compact"): VisiblePanelState {
	return panel === "expanded" ? "expanded" : panel === "compact" ? "compact" : fallback;
}

export function createTaskPanelVisibility(panel: PanelState = "compact"): TaskPanelVisibilityState {
	return {
		panel,
		lastVisiblePanel: visiblePanelFor(panel),
		hiddenByUser: false,
		autoShownThisSession: false,
	};
}

export function ensureTaskPanelVisibility(state: TaskPanelVisibilityState): void {
	state.panel = normalizePanelState(state.panel);
	state.lastVisiblePanel = visiblePanelFor(state.lastVisiblePanel, visiblePanelFor(state.panel));
	state.hiddenByUser = state.hiddenByUser === true;
	state.autoShownThisSession = state.autoShownThisSession === true;
}

export function rememberTaskPanelVisibility(state: TaskPanelVisibilityState): TaskPanelVisibilityState {
	ensureTaskPanelVisibility(state);
	return {
		panel: state.panel,
		lastVisiblePanel: state.lastVisiblePanel,
		hiddenByUser: state.hiddenByUser,
		autoShownThisSession: state.autoShownThisSession,
	};
}

export function restoreTaskPanelVisibility(state: TaskPanelVisibilityState, snapshot: TaskPanelVisibilityState): void {
	ensureTaskPanelVisibility(snapshot);
	state.panel = snapshot.panel;
	state.lastVisiblePanel = snapshot.lastVisiblePanel;
	state.hiddenByUser = snapshot.hiddenByUser;
	state.autoShownThisSession = snapshot.autoShownThisSession;
}

export function autoHideTaskPanel(state: TaskPanelVisibilityState): void {
	ensureTaskPanelVisibility(state);
	if (state.panel !== "hidden") state.lastVisiblePanel = state.panel;
	state.panel = "hidden";
}

export function userHideTaskPanel(state: TaskPanelVisibilityState): void {
	autoHideTaskPanel(state);
	state.hiddenByUser = true;
}

export function userShowTaskPanel(state: TaskPanelVisibilityState, panel: VisiblePanelState = state.lastVisiblePanel): void {
	ensureTaskPanelVisibility(state);
	const next = visiblePanelFor(panel);
	state.panel = next;
	state.lastVisiblePanel = next;
	state.hiddenByUser = false;
	state.autoShownThisSession = true;
}

export function autoShowTaskPanelOnce(state: TaskPanelVisibilityState, options: { autoShowOnFirstTask: boolean; defaultPanel: PanelState }): void {
	ensureTaskPanelVisibility(state);
	if (!options.autoShowOnFirstTask || state.hiddenByUser || state.autoShownThisSession) return;
	state.autoShownThisSession = true;
	if (state.panel !== "hidden") {
		state.lastVisiblePanel = state.panel;
		return;
	}
	const next = normalizePanelState(options.defaultPanel);
	if (next !== "hidden") {
		state.panel = next;
		state.lastVisiblePanel = visiblePanelFor(next);
	}
}

export function applyTaskPanelContentVisibility(
	state: TaskPanelVisibilityState,
	options: { remainingTasks: number; hasTasks: boolean; autoShowOnFirstTask: boolean; defaultPanel: PanelState },
): void {
	if (options.remainingTasks === 0 && options.hasTasks) {
		autoHideTaskPanel(state);
		return;
	}
	if (options.remainingTasks > 0) autoShowTaskPanelOnce(state, options);
}

export function cycleTaskPanelVisibility(state: TaskPanelVisibilityState): void {
	ensureTaskPanelVisibility(state);
	if (state.panel === "hidden") userShowTaskPanel(state);
	else if (state.panel === "compact") userShowTaskPanel(state, "expanded");
	else userHideTaskPanel(state);
}
