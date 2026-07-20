import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

import { CONFIG_ID } from "./settings.js";

const SETTINGS_EVENT = "vstack:extension-settings-changed";

interface ToolExecutionUi {
	requestRender?: () => void;
}

interface TrackedToolExecutionComponent {
	invalidate?: () => void;
	ui?: ToolExecutionUi;
}

const activeToolExecutionComponents = new Set<TrackedToolExecutionComponent>();

interface ExtensionSettingChange {
	extensionId?: unknown;
	key?: unknown;
}

export function trackToolExecutionComponent(component: unknown): void {
	if (component && typeof component === "object") activeToolExecutionComponents.add(component as TrackedToolExecutionComponent);
}

export function refreshToolExecutionComponents(): void {
	const userInterfaces = new Set<ToolExecutionUi>();
	for (const component of activeToolExecutionComponents) {
		if (component.ui) userInterfaces.add(component.ui);
		try {
			component.invalidate?.();
		} catch {
			// Ignore stale components left behind by a session transition.
		}
	}
	for (const ui of userInterfaces) {
		try {
			ui.requestRender?.();
		} catch {
			// Ignore stale TUI instances left behind by a session transition.
		}
	}
}

export function clearTrackedToolExecutionComponents(): void {
	activeToolExecutionComponents.clear();
}

export function installLiveSettingsRefresh(pi: ExtensionAPI): void {
	const unsubscribe = pi.events.on(SETTINGS_EVENT, (data: unknown) => {
		const change = data as ExtensionSettingChange | undefined;
		if (change?.extensionId !== CONFIG_ID || change.key !== "showReadImages") return;
		refreshToolExecutionComponents();
	});
	pi.on("session_start", clearTrackedToolExecutionComponents);
	pi.on("session_shutdown", () => {
		unsubscribe();
		clearTrackedToolExecutionComponents();
	});
}
