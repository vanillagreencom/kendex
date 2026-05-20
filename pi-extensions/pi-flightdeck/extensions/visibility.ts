import type { FlightdeckSessionStatus } from "./state.js";

export type DashboardState = "hidden" | "compact" | "expanded";
export type VisibleDashboardState = Exclude<DashboardState, "hidden">;

export interface FlightdeckDashboardVisibilityState {
	state: DashboardState;
	lastVisibleState: VisibleDashboardState;
	hiddenByUser: boolean;
	autoShownThisSession: boolean;
}

export function normalizeDashboardState(value: unknown, fallback: DashboardState = "compact"): DashboardState {
	return value === "hidden" || value === "expanded" || value === "compact" ? value : fallback;
}

export function visibleDashboardState(value: DashboardState | undefined, fallback: VisibleDashboardState = "compact"): VisibleDashboardState {
	return value === "expanded" ? "expanded" : value === "compact" ? "compact" : fallback;
}

export function createFlightdeckDashboardVisibility(defaultState: DashboardState = "compact"): FlightdeckDashboardVisibilityState {
	return {
		state: defaultState,
		lastVisibleState: visibleDashboardState(defaultState),
		hiddenByUser: false,
		autoShownThisSession: defaultState !== "hidden",
	};
}

export function resetFlightdeckDashboardVisibility(visibility: FlightdeckDashboardVisibilityState, defaultState: DashboardState): void {
	visibility.state = normalizeDashboardState(defaultState);
	visibility.lastVisibleState = visibleDashboardState(visibility.state);
	visibility.hiddenByUser = false;
	visibility.autoShownThisSession = visibility.state !== "hidden";
}

export function userHideFlightdeckDashboard(visibility: FlightdeckDashboardVisibilityState): void {
	if (visibility.state !== "hidden") visibility.lastVisibleState = visibleDashboardState(visibility.state);
	visibility.state = "hidden";
	visibility.hiddenByUser = true;
}

export function userShowFlightdeckDashboard(visibility: FlightdeckDashboardVisibilityState, state: VisibleDashboardState = visibility.lastVisibleState): void {
	const next = visibleDashboardState(state);
	visibility.state = next;
	visibility.lastVisibleState = next;
	visibility.hiddenByUser = false;
	visibility.autoShownThisSession = true;
}

export function cycleFlightdeckDashboardVisibility(visibility: FlightdeckDashboardVisibilityState): void {
	if (visibility.state === "hidden") userShowFlightdeckDashboard(visibility);
	else if (visibility.state === "compact") userShowFlightdeckDashboard(visibility, "expanded");
	else userHideFlightdeckDashboard(visibility);
}

export function flightdeckWidgetSuppressedByUser(visibility: FlightdeckDashboardVisibilityState): boolean {
	return visibility.state === "hidden" && visibility.hiddenByUser;
}

export function shouldRenderFlightdeckInlineWidget(
	visibility: FlightdeckDashboardVisibilityState,
	options: { status: FlightdeckSessionStatus; showBanner: boolean; dashboardEnabled: boolean },
): boolean {
	if (flightdeckWidgetSuppressedByUser(visibility)) return false;
	if (options.status === "inactive" && !options.showBanner) return false;
	return options.showBanner || options.dashboardEnabled;
}
