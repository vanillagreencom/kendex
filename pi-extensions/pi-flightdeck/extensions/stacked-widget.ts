import type { ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import type { Component, TUI } from "@earendil-works/pi-tui";
import { truncateToWidth } from "@earendil-works/pi-tui";

export type MiniDashboardPlacement = "aboveEditor" | "belowEditor";
export type MiniDashboardComponent = Component & { dispose?(): void };
export type MiniDashboardFactory = (tui: TUI, theme: Theme) => MiniDashboardComponent;

export const MINI_DASHBOARD_RANK = {
	FLIGHTDECK: 10,
	TASKS: 20,
	AGENTS: 30,
	BACKGROUND_TASKS: 40,
} as const;

interface MiniDashboardEntry {
	key: string;
	rank: number;
	sequence: number;
	version: number;
	placement: MiniDashboardPlacement;
	factory: MiniDashboardFactory;
}

interface StackHandle {
	active: boolean;
	requestRender?: () => void;
}

interface MiniDashboardRegistry {
	entries: Map<string, MiniDashboardEntry>;
	handles: Record<MiniDashboardPlacement, StackHandle>;
	legacyCleared: Set<string>;
	nextSequence: number;
}

const REGISTRY_SYMBOL = Symbol.for("vstack.pi.mini-dashboard-stack");
const STACK_WIDGET_KEY: Record<MiniDashboardPlacement, string> = {
	aboveEditor: "vstack-mini-dashboard-stack-above",
	belowEditor: "vstack-mini-dashboard-stack-below",
};

function registry(): MiniDashboardRegistry {
	const globals = globalThis as unknown as Record<PropertyKey, MiniDashboardRegistry | undefined>;
	let value = globals[REGISTRY_SYMBOL];
	if (!value) {
		value = {
			entries: new Map(),
			handles: {
				aboveEditor: { active: false },
				belowEditor: { active: false },
			},
			legacyCleared: new Set(),
			nextSequence: 1,
		};
		globals[REGISTRY_SYMBOL] = value;
	}
	return value;
}

export function resetMiniDashboardRegistryForTests(): void {
	const globals = globalThis as unknown as Record<PropertyKey, MiniDashboardRegistry | undefined>;
	delete globals[REGISTRY_SYMBOL];
}

function sortedEntries(value: MiniDashboardRegistry, placement: MiniDashboardPlacement): MiniDashboardEntry[] {
	return [...value.entries.values()]
		.filter((entry) => entry.placement === placement)
		.sort((a, b) => a.rank - b.rank || a.sequence - b.sequence || a.key.localeCompare(b.key));
}

function stackComponent(value: MiniDashboardRegistry, placement: MiniDashboardPlacement, tui: TUI, theme: Theme): MiniDashboardComponent {
	const components = new Map<string, { version: number; component: MiniDashboardComponent }>();
	value.handles[placement] = { active: true, requestRender: () => tui.requestRender() };

	const ensureComponent = (entry: MiniDashboardEntry): MiniDashboardComponent => {
		const existing = components.get(entry.key);
		if (existing?.version === entry.version) return existing.component;
		existing?.component.dispose?.();
		const component = entry.factory(tui, theme);
		components.set(entry.key, { version: entry.version, component });
		return component;
	};

	const disposeRemoved = (entries: MiniDashboardEntry[]) => {
		const activeKeys = new Set(entries.map((entry) => entry.key));
		for (const [key, cached] of components) {
			if (!activeKeys.has(key)) {
				cached.component.dispose?.();
				components.delete(key);
			}
		}
	};

	return {
		invalidate() {
			for (const cached of components.values()) cached.component.invalidate();
		},
		render(width: number): string[] {
			const entries = sortedEntries(value, placement);
			disposeRemoved(entries);
			const lines: string[] = [];
			for (const entry of entries) {
				lines.push(...ensureComponent(entry).render(width));
			}
			return lines.map((line) => truncateToWidth(line, Math.max(1, width), ""));
		},
		dispose() {
			for (const cached of components.values()) cached.component.dispose?.();
			components.clear();
			value.handles[placement] = { active: false };
		},
	};
}

function syncStack(ctx: ExtensionContext, placement: MiniDashboardPlacement): void {
	const value = registry();
	const entries = sortedEntries(value, placement);
	const handle = value.handles[placement];
	const stackKey = STACK_WIDGET_KEY[placement];
	if (entries.length === 0) {
		if (handle.active) ctx.ui.setWidget(stackKey, undefined, { placement });
		return;
	}
	if (!handle.active) {
		ctx.ui.setWidget(stackKey, (tui, theme) => stackComponent(value, placement, tui, theme), { placement });
		return;
	}
	handle.requestRender?.();
}

export function setMiniDashboardWidget(
	ctx: ExtensionContext,
	key: string,
	rank: number,
	factory: MiniDashboardFactory | undefined,
	options: { placement?: MiniDashboardPlacement } = {},
): void {
	const value = registry();
	if (!value.legacyCleared.has(key)) {
		ctx.ui.setWidget(key, undefined);
		value.legacyCleared.add(key);
	}

	const previous = value.entries.get(key);
	const previousPlacement = previous?.placement;
	if (!ctx.hasUI || !factory) {
		value.entries.delete(key);
		if (previousPlacement) syncStack(ctx, previousPlacement);
		return;
	}

	const placement = options.placement ?? "aboveEditor";
	value.entries.set(key, {
		key,
		rank,
		placement,
		factory,
		sequence: previous?.sequence ?? value.nextSequence++,
		version: (previous?.version ?? 0) + 1,
	});

	if (previousPlacement && previousPlacement !== placement) syncStack(ctx, previousPlacement);
	syncStack(ctx, placement);
}
