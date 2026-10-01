import { compareInventoryItems } from "./inventory.js";
import type { ExtensionState, InventoryItem, ManagerUiState } from "./types.js";

export function itemBelongsToPackage(item: InventoryItem, pkg: InventoryItem): boolean {
	if (pkg.installationId !== undefined || item.installationId !== undefined) return pkg.installationId !== undefined && item.installationId === pkg.installationId;
	return item.scope === pkg.scope && item.packageDir === pkg.packageDir && item.packageName === pkg.packageName;
}

export function selectedPackageForSetting(item: InventoryItem): string | undefined {
	return item.packageName ?? (item.kind === "package" ? item.displayName : undefined);
}

interface PackageIndex {
	packages: InventoryItem[];
	children: Map<InventoryItem, InventoryItem[]>;
	search: Map<InventoryItem, string>;
	filtered?: { key: string; items: InventoryItem[] };
}
const indexes = new WeakMap<InventoryItem[], PackageIndex>();

function packageIndex(items: InventoryItem[]): PackageIndex {
	const existing = indexes.get(items);
	if (existing) return existing;
	const packages = items.filter((item) => item.kind === "package");
	const modules = items.filter((item) => item.kind === "extension module");
	const children = new Map<InventoryItem, InventoryItem[]>();
	const search = new Map<InventoryItem, string>();
	for (const pkg of packages) {
		const entries = modules.filter((item) => itemBelongsToPackage(item, pkg)).sort(compareInventoryItems);
		children.set(pkg, entries);
		search.set(pkg, [pkg, ...entries].map((item) => [item.displayName, item.kind, item.provider, item.description, item.sourcePath, item.stateReason, item.trigger].join("\n")).join("\n").toLowerCase());
	}
	const index = { packages, children, search };
	indexes.set(items, index);
	return index;
}

/** Children are indexed once for an inventory snapshot, never during each row redraw. */
export function packageExtensions(items: InventoryItem[], pkg: InventoryItem): InventoryItem[] {
	return packageIndex(items).children.get(pkg) ?? [];
}

function stateMatchesFilter(state: ExtensionState, filter: string): boolean {
	if (filter === "active") return state === "active";
	if (filter === "inactive") return state !== "active";
	return true;
}

/** Keep one result for the current query and filters. Selection changes reuse it. */
export function filteredItems(items: InventoryItem[], ui: ManagerUiState): InventoryItem[] {
	const index = packageIndex(items);
	const query = ui.search.trim().toLowerCase();
	const key = JSON.stringify([query, ui.stateFilter, ui.scopeFilter]);
	if (index.filtered?.key === key) return index.filtered.items;
	const filtered = index.packages.filter((item) => {
		if (query && !index.search.get(item)!.includes(query)) return false;
		const related = [item, ...index.children.get(item)!];
		return related.some((candidate) => stateMatchesFilter(candidate.state, ui.stateFilter))
			&& (ui.scopeFilter === "all" || related.some((candidate) => candidate.scope === ui.scopeFilter));
	});
	index.filtered = { key, items: filtered };
	return filtered;
}
