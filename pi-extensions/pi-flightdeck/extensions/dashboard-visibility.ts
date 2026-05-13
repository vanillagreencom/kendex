import type { Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth } from "@earendil-works/pi-tui";

import type { FlightdeckSnapshot } from "./state.js";

export type DashboardVisibility = "owner" | "tmux-session" | "always";

export function normalizeDashboardVisibility(value: unknown): DashboardVisibility {
	return value === "tmux-session" || value === "always" ? value : "owner";
}

export function isInFlightdeckChildPane(env: NodeJS.ProcessEnv = process.env): boolean {
	return Boolean(env.PI_SUBAGENT_CHILD_AGENT || env.FLIGHTDECK_CHILD_PANE);
}

export function dashboardVisibleInPane(options: { visibility: DashboardVisibility; currentPaneId?: string | null; ownerPaneId?: string | null; inChildPane?: boolean }): boolean {
	if (options.inChildPane) return false;
	if (options.visibility === "always") return true;
	if (options.visibility === "tmux-session") return true;
	return Boolean(options.currentPaneId && options.ownerPaneId && options.currentPaneId === options.ownerPaneId);
}

export function dashboardVisibleForSnapshot(snapshot: FlightdeckSnapshot | undefined, visibility: DashboardVisibility, env: NodeJS.ProcessEnv = process.env): boolean {
	return dashboardVisibleInPane({
		currentPaneId: snapshot?.tmux.paneId,
		inChildPane: isInFlightdeckChildPane(env),
		ownerPaneId: snapshot?.master?.owner?.pane_id,
		visibility,
	});
}

export function isFlightdeckOwnerPane(snapshot: FlightdeckSnapshot | undefined): boolean {
	return Boolean(snapshot?.tmux.paneId && snapshot.master?.owner?.pane_id && snapshot.tmux.paneId === snapshot.master.owner.pane_id);
}

export function isFlightdeckObserverPane(snapshot: FlightdeckSnapshot | undefined): boolean {
	return Boolean(snapshot?.tmux.paneId && snapshot.master?.owner?.pane_id && snapshot.tmux.paneId !== snapshot.master.owner.pane_id);
}

export function renderObserverHeader(snapshot: FlightdeckSnapshot, theme: Theme, width: number): string | undefined {
	if (!isFlightdeckObserverPane(snapshot)) return undefined;
	const ownerPane = snapshot.master?.owner?.pane_id;
	if (!ownerPane) return undefined;
	const current = snapshot.tmux.paneId ? ` ${theme.fg("dim", `(current ${snapshot.tmux.paneId})`)}` : "";
	const discovery = typeof snapshot.master?.owner?.discovery_error === "string" && snapshot.master.owner.discovery_error.trim()
		? ` ${theme.fg("dim", "·")} ${theme.fg("warning", "owner metadata warning")}`
		: "";
	return truncateToWidth(`${theme.fg("warning", "Observed Flightdeck")} ${theme.fg("dim", "owned by")} ${theme.fg("accent", ownerPane)}${current}${discovery}`, width, "");
}
