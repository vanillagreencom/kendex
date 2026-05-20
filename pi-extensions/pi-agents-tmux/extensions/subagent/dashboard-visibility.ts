export type AgentDashboardDisplayMode = "compact" | "normal" | "expanded";

export interface AgentDashboardVisibilityState {
	mode: AgentDashboardDisplayMode;
	visible: boolean;
	lastVisibleMode?: AgentDashboardDisplayMode;
	hiddenByUser?: boolean;
	autoShownThisSession?: boolean;
}

function visibleMode(mode: AgentDashboardDisplayMode | undefined, fallback: AgentDashboardDisplayMode): AgentDashboardDisplayMode {
	return mode === "compact" || mode === "normal" || mode === "expanded" ? mode : fallback;
}

export function normalizeAgentDashboardVisibility(state: AgentDashboardVisibilityState, fallback: AgentDashboardDisplayMode = "compact"): void {
	state.mode = visibleMode(state.mode, fallback);
	state.lastVisibleMode = visibleMode(state.lastVisibleMode, state.mode === "compact" || state.mode === "normal" || state.mode === "expanded" ? state.mode : fallback);
	state.hiddenByUser = state.hiddenByUser === true;
	state.autoShownThisSession = state.autoShownThisSession === true;
}

export function autoShowAgentDashboardOnce(state: AgentDashboardVisibilityState, fallback: AgentDashboardDisplayMode = "compact"): void {
	normalizeAgentDashboardVisibility(state, fallback);
	if (state.hiddenByUser || state.autoShownThisSession) return;
	if (!state.visible) {
		state.mode = state.lastVisibleMode ?? fallback;
		state.visible = true;
	}
	state.autoShownThisSession = true;
}

export function userHideAgentDashboard(state: AgentDashboardVisibilityState): void {
	normalizeAgentDashboardVisibility(state);
	if (state.visible) state.lastVisibleMode = state.mode;
	state.visible = false;
	state.hiddenByUser = true;
}

export function userShowAgentDashboard(state: AgentDashboardVisibilityState, mode?: AgentDashboardDisplayMode): void {
	normalizeAgentDashboardVisibility(state);
	const next = visibleMode(mode, state.lastVisibleMode ?? state.mode ?? "compact");
	state.mode = next;
	state.lastVisibleMode = next;
	state.visible = true;
	state.hiddenByUser = false;
	state.autoShownThisSession = true;
}

export function cycleAgentDashboard(state: AgentDashboardVisibilityState): void {
	normalizeAgentDashboardVisibility(state);
	if (!state.visible) {
		userShowAgentDashboard(state);
	} else if (state.mode === "compact") {
		userShowAgentDashboard(state, "normal");
	} else if (state.mode === "normal") {
		userShowAgentDashboard(state, "expanded");
	} else {
		userHideAgentDashboard(state);
	}
}
