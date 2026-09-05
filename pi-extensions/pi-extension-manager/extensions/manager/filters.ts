import { compareInventoryItems } from "./inventory.js";
import type { ExtensionState, InventoryItem, ManagerUiState } from "./types.js";

export function itemBelongsToPackage(item: InventoryItem, pkg: InventoryItem): boolean {
	if (pkg.installationId !== undefined || item.installationId !== undefined) return pkg.installationId !== undefined && item.installationId === pkg.installationId;
	const packageName = pkg.packageName;
	if (!packageName) return false;
	return item.packageName === packageName || item.sourceName === packageName || item.provider === packageName || item.sourcePath.includes(`/packages/${packageName}/`);
}

export function selectedPackageForSetting(item: InventoryItem): string | undefined {
	return item.packageName ?? (item.kind === "package" ? item.displayName : undefined);
}

export function packageExtensions(items: InventoryItem[], pkg: InventoryItem): InventoryItem[] {
	return items.filter((item) => item.kind === "extension module" && itemBelongsToPackage(item, pkg)).sort(compareInventoryItems);
}

function stateMatchesFilter(state: ExtensionState, filter: string): boolean {
	if (filter === "all") return true;
	if (filter === "active") return state === "active";
	if (filter === "inactive") return state !== "active";
	return true;
}

function itemSearchText(item: InventoryItem, allItems: InventoryItem[]): string {
	const own = [item.displayName, item.kind, item.provider, item.description, item.sourcePath, item.stateReason, item.trigger].join("\n");
	if (item.kind !== "package" || !item.packageName) return own.toLowerCase();
	const children = packageExtensions(allItems, item)
		.map((child) => [child.displayName, child.kind, child.description, child.trigger, child.sourcePath].join("\n"))
		.join("\n");
	return `${own}\n${children}`.toLowerCase();
}

function packageSummaryMatches(item: InventoryItem, allItems: InventoryItem[], ui: ManagerUiState): boolean {
	const related = item.packageName ? [item, ...packageExtensions(allItems, item)] : [item];
	if (!related.some((candidate) => stateMatchesFilter(candidate.state, ui.stateFilter))) return false;
	if (ui.scopeFilter !== "all" && !related.some((candidate) => candidate.scope === ui.scopeFilter)) return false;
	return true;
}

function itemMatchesFilters(item: InventoryItem, allItems: InventoryItem[], ui: ManagerUiState, packageSummary: boolean): boolean {
	if (packageSummary) return packageSummaryMatches(item, allItems, ui);
	if (!stateMatchesFilter(item.state, ui.stateFilter)) return false;
	if (ui.scopeFilter !== "all" && item.scope !== ui.scopeFilter) return false;
	return true;
}

export function filteredItems(items: InventoryItem[], ui: ManagerUiState): InventoryItem[] {
	const query = ui.search.trim().toLowerCase();
	const base = items.filter((item) => item.kind === "package");
	return base.filter((item) => {
		if (query && !itemSearchText(item, items).includes(query)) return false;
		return itemMatchesFilters(item, items, ui, true);
	});
}
