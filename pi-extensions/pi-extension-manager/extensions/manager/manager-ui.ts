import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import { matchesKey, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { planUninstall, planUpdate, runUninstall, runUpdate, toggleItem } from "./actions.js";
import { filteredItems, packageExtensions } from "./filters.js";
import { ansiGreen, ansiRed, ansiYellow, isPlainSearchInput, kindLabel, scopeFilterLabel } from "./format.js";
import { applyUpdateMetadata, buildInventory, npmCandidatesFromInventory } from "./inventory.js";
import { compactPath } from "./paths.js";
import { glyphs } from "./glyphs.js";
import {
	countBy,
	divider,
	frame,
	frameContentWidth,
	managerEntityTitle,
	managerMutedForSelection,
	managerPaneTitle,
	managerSectionTitle,
	managerSelectedLine,
	pad,
	wrapLine,
} from "./render.js";
import { acquireVstackModalLock, managerLayout } from "./settings.js";
import { kickNpmUpdateCheck } from "./versions.js";
import {
	DEFAULT_MAX_HEIGHT,
	DEFAULT_WIDTH,
	DEFAULT_WIDTH_PERCENT,
	LEFT_MAX_WIDTH,
	LEFT_MIN_WIDTH,
	LIST_ROWS,
	MANAGER_ID,
	type Inventory,
	type InventoryItem,
	type ManagerAction,
	type ManagerUiState,
	type PopupLayout,
} from "./types.js";

function makeInitialUiState(): ManagerUiState {
	return {
		scopeFilter: "all",
		search: "",
		selected: 0,
		diagnosticsScroll: 0,
		showAudit: false,
		stateFilter: "all",
		scroll: 0,
	};
}

function syncManagerListViewport(ui: ManagerUiState, itemCount: number, visibleItemRows: number): void {
	const rows = Math.max(1, visibleItemRows);
	ui.selected = Math.max(0, Math.min(ui.selected, Math.max(0, itemCount - 1)));
	if (ui.selected < ui.scroll) ui.scroll = ui.selected;
	else if (ui.selected >= ui.scroll + rows) ui.scroll = ui.selected - rows + 1;
	ui.scroll = Math.max(0, Math.min(ui.scroll, Math.max(0, itemCount - rows)));
}

function managerListItemRows(itemCount: number, scroll: number, tableRows: number): number {
	let rows = Math.max(1, Math.min(LIST_ROWS, tableRows - 2)); // title + spacer
	for (let i = 0; i < 3; i += 1) {
		const topIndicatorRows = scroll > 0 ? 1 : 0;
		const bottomIndicatorRows = itemCount > scroll + rows ? 1 : 0;
		rows = Math.max(1, Math.min(LIST_ROWS, tableRows - 2 - topIndicatorRows - bottomIndicatorRows));
	}
	return rows;
}

function renderDiagnostics(inventory: Inventory, width: number, theme: Theme): string[] {
	const counts = countBy(inventory.items, (item) => item.state);
	const kinds = countBy(inventory.items, (item) => item.kind);
	const lines = [
		managerEntityTitle(theme, "Diagnostics"),
		`Inventory: ${inventory.items.length} packages/extensions · ${counts.active ?? 0} active · ${counts.disabled ?? 0} disabled · ${counts.shadowed ?? 0} shadowed · ${counts.broken ?? 0} broken`,
		`Kinds: ${Object.entries(kinds).map(([kind, count]) => `${kind}=${count}`).join(", ")}`,
		"",
		managerSectionTitle(theme, "Settings files"),
	];
	for (const file of inventory.settingsFiles) lines.push(`${file.scope}: ${compactPath(file.path)}${file.exists ? "" : " (not created yet)"}`);
	lines.push("", managerSectionTitle(theme, "Package manifests"));
	if (inventory.auditLines.length === 0) lines.push(theme.fg("dim", "No package manifests found in current Pi settings."));
	for (const block of inventory.auditLines) {
		const [head, ...rest] = block.split("\n");
		lines.push(managerSectionTitle(theme, head ?? "package"));
		for (const line of rest.slice(0, 3)) lines.push(theme.fg("dim", line));
	}
	lines.push("", theme.fg("warning", "Runtime note"));
	lines.push("Pi cannot unload already-loaded extension modules live. Package and extension toggles apply after /reload or restart.");
	return lines.flatMap((line) => wrapLine(line, width));
}

function renderDiagnosticsViewport(inventory: Inventory, ui: ManagerUiState, width: number, theme: Theme, viewportRows: number): string[] {
	const all = renderDiagnostics(inventory, width, theme);
	viewportRows = Math.max(1, viewportRows);
	if (all.length <= viewportRows) {
		ui.diagnosticsScroll = 0;
		return all;
	}
	const contentRows = Math.max(1, viewportRows - 1);
	ui.diagnosticsScroll = Math.max(0, Math.min(ui.diagnosticsScroll, Math.max(0, all.length - contentRows)));
	const visible = all.slice(ui.diagnosticsScroll, ui.diagnosticsScroll + contentRows);
	const before = ui.diagnosticsScroll > 0 ? `↑ ${ui.diagnosticsScroll}` : "";
	const afterCount = Math.max(0, all.length - ui.diagnosticsScroll - contentRows);
	const after = afterCount > 0 ? `↓ ${afterCount}` : "";
	return [...visible, theme.fg("dim", [before, after].filter(Boolean).join(glyphs().dot))];
}

function itemToggleHintLabel(item: InventoryItem | undefined): string | undefined {
	if (!item || item.state === "broken" || item.state === "shadowed") return undefined;
	const verb = item.state === "disabled" ? "enable" : "disable";
	if (item.kind === "package") return verb;
	if (item.kind === "extension module") return `${verb} extension`;
	return `${verb} ${kindLabel(item.kind)}`;
}

function stateToken(item: InventoryItem): string {
	if (item.state === "active") return ansiGreen(glyphs().bullet.trim());
	if (item.state === "broken") return ansiRed(glyphs().fail);
	return ansiYellow(glyphs().emptyBullet.trim());
}

function installSourceLabel(item: InventoryItem): string {
	if (item.installSource === "npm") return "NPM";
	if (item.installSource === "vstack") return "Vstack";
	return "Unknown";
}

function listDisplayName(item: InventoryItem): string {
	if (item.kind === "extension module") return (item.entrypoint ?? item.displayName).replace(/^\.\//, "");
	return item.displayName;
}

function renderList(items: InventoryItem[], ui: ManagerUiState, width: number, theme: Theme, listRows: number): string[] {
	const lines = [`${managerPaneTitle(theme, "Packages", true)} ${theme.fg("dim", `(${items.length})`)}`, ""];
	if (items.length === 0) {
		lines.push(theme.fg("dim", "No matching items."));
		return lines;
	}
	if (ui.scroll > 0) lines.push(theme.fg("dim", `↑ ${ui.scroll} earlier`));
	for (const [visibleIndex, item] of items.slice(ui.scroll, ui.scroll + listRows).entries()) {
		const index = ui.scroll + visibleIndex;
		const selected = index === ui.selected;
		const marker = " ";
		const stateIcon = stateToken(item);
		const name = selected ? theme.fg("text", listDisplayName(item)) : listDisplayName(item);
		const scopeText = scopeFilterLabel(item.scope);
		const meta = item.kind === "package"
			? managerMutedForSelection(theme, ` ${scopeText}`, selected)
			: managerMutedForSelection(theme, ` ${kindLabel(item.kind)}${glyphs().dot}${scopeText}`, selected);
		const updateBadge = item.updateAvailable ? ` ${ansiRed("Update Needed")}` : "";
		const row = truncateToWidth(`${marker}${stateIcon} ${name}${meta}${updateBadge}`, width, glyphs().ellipsis);
		lines.push(selected ? managerSelectedLine(theme, row, width) : row);
	}
	const hidden = Math.max(0, items.length - (ui.scroll + listRows));
	if (hidden > 0) lines.push(theme.fg("dim", `↓ ${hidden} more`));
	return lines;
}

function shortResourceName(item: InventoryItem): string {
	if (item.kind === "extension module") return (item.entrypoint ?? item.displayName).replace(/^\.\//, "");
	return item.trigger ?? item.displayName;
}

function packageExtensionLines(inventory: Inventory, item: InventoryItem, width: number, theme: Theme): string[] {
	if (item.kind !== "package" || !item.packageName) return [];
	const extensions = packageExtensions(inventory.items, item.packageName);
	if (extensions.length === 0) return [];
	const names = extensions.slice(0, 5).map(shortResourceName).join(", ");
	const suffix = extensions.length > 5 ? `, +${extensions.length - 5} more` : "";
	const lines = ["", managerSectionTitle(theme, `Extensions (${extensions.length})`), truncateToWidth(`${names}${suffix}`, width, "…")];
	return lines;
}

function renderInspector(inventory: Inventory, item: InventoryItem | undefined, width: number, theme: Theme, viewportRows: number): string[] {
	if (!item) return [theme.fg("dim", "Select an item to inspect it.")];
	const updateText = item.updateAvailable && item.latestVersion
		? `${ansiRed("Update Needed")} ${theme.fg("dim", `${item.installedVersion ?? "unknown"} -> ${item.latestVersion}`)}`
		: item.latestVersion
			? theme.fg("dim", `latest ${item.latestVersion}`)
			: theme.fg("dim", "not checked");
	const detailLines = [
		`${managerEntityTitle(theme, item.displayName)} ${stateToken(item)}${item.updateAvailable ? ` ${ansiRed("Update Needed")}` : ""}`,
		item.description ? theme.fg("text", item.description) : theme.fg("dim", "No description."),
		"",
		`${theme.fg("muted", "Scope")}: ${scopeFilterLabel(item.scope)}    ${theme.fg("muted", "Installed with")}: ${installSourceLabel(item)}`,
		`${theme.fg("muted", "Source")}: ${compactPath(item.sourcePath)}`,
		`${theme.fg("muted", "State")}: ${item.stateReason}`,
		`${theme.fg("muted", "Version")}: ${item.installedVersion ?? "unknown"}`,
		`${theme.fg("muted", "Update")}: ${updateText}`,
	];
	if (item.updateAvailable && item.updateCommand) {
		detailLines.push(`${theme.fg("muted", "Action")}: ${ansiYellow(`alt+u update via ${item.updateSource ?? "source"}`)}`);
		detailLines.push(`${theme.fg("muted", "Command")}: ${item.updateCommand}`);
	}
	if (item.trigger) detailLines.push(`${theme.fg("muted", "Trigger")}: ${item.trigger}`);
	if (item.shadowedBy) detailLines.push(`${theme.fg("muted", "Shadowed by")}: ${item.shadowedBy}`);
	if (item.brokenError) detailLines.push(`${theme.fg("error", "Error")}: ${item.brokenError}`);
	detailLines.push(...packageExtensionLines(inventory, item, width, theme));
	const safeViewportRows = Math.max(1, viewportRows);
	return detailLines.flatMap((line) => wrapLine(line, width)).slice(0, safeViewportRows);
}

function renderExtensions(inventory: Inventory, ui: ManagerUiState, width: number, theme: Theme, layout: PopupLayout, footerRows = 0): string[] {
	const list = filteredItems(inventory.items, ui);
	const leftWidth = Math.max(Math.min(LEFT_MIN_WIDTH, Math.floor(width * 0.45)), Math.min(LEFT_MAX_WIDTH, Math.floor(width * 0.38)));
	const rightWidth = Math.max(20, width - leftWidth - 3);
	const rows = layout.bodyRows;
	let selected = list[ui.selected];
	const searchText = ` > ${ui.search}${theme.inverse(" ")}`;
	const searchLine = theme.bg("toolPendingBg", pad(searchText, width));
	const filterValue = (label: string, value: string): string => `${theme.fg("muted", `${label}:`)} ${value === "all" ? theme.fg("dim", value) : theme.fg("accent", label === "scope" ? scopeFilterLabel(value) : value)}`;
	const filterLine = `${theme.fg("muted", "filters:")} ${filterValue("state", ui.stateFilter)}  ${filterValue("scope", ui.scopeFilter)}   ${ansiYellow("alt+s")} ${theme.fg("dim", "state · ")}${ansiYellow("alt+o")} ${theme.fg("dim", "scope")}`;
	const hintParts: string[] = [];
	const toggleLabel = itemToggleHintLabel(selected);
	if (toggleLabel) hintParts.push(`${ansiYellow("alt+x")} ${theme.fg("dim", toggleLabel)}`);
	if (selected?.updateAvailable) hintParts.push(`${ansiYellow("alt+u")} ${theme.fg("dim", `update via ${selected.updateSource ?? "source"}`)}`);
	if (selected?.kind === "package") hintParts.push(`${ansiYellow("alt+d")} ${theme.fg("dim", "uninstall")}`);
	const hintLine = hintParts.join(theme.fg("dim", " · "));
	const lines = [searchLine, ...wrapLine(filterLine, width), "", ...wrapLine(hintLine, width), divider(width, theme)];
	const tableRows = Math.max(1, rows - Math.max(0, lines.length - 5) - footerRows);
	let listRows = managerListItemRows(list.length, ui.scroll, tableRows);
	syncManagerListViewport(ui, list.length, listRows);
	listRows = managerListItemRows(list.length, ui.scroll, tableRows);
	syncManagerListViewport(ui, list.length, listRows);
	selected = list[ui.selected];
	const left = renderList(list, ui, leftWidth, theme, listRows);
	const right = renderInspector(inventory, selected, rightWidth, theme, rows);
	for (let i = 0; i < tableRows; i += 1) {
		lines.push(`${pad(left[i] ?? "", leftWidth)} ${theme.fg("dim", "│")} ${truncateToWidth(right[i] ?? "", rightWidth, "")}`);
	}
	return lines;
}

function createManagerComponent(
	ctx: ExtensionCommandContext | ExtensionContext,
	inventory: Inventory,
	ui: ManagerUiState,
	theme: Theme,
	requestRender: () => void,
	getLayout: () => PopupLayout,
	done: (value: ManagerAction) => void,
) {
	const states = ["all", "active", "inactive"];
	const scopes = ["all", "user", "project", "temporary"];
	kickNpmUpdateCheck(npmCandidatesFromInventory(inventory), () => {
		applyUpdateMetadata(inventory.items, inventory.settingsFiles, ctx.cwd);
		requestRender();
	});

	function clamp(): void {
		const layout = getLayout();
		const list = filteredItems(inventory.items, ui);
		syncManagerListViewport(ui, list.length, layout.listRows);
	}

	function cycle<T extends string>(values: T[], current: string, delta: number): T {
		const idx = Math.max(0, values.indexOf(current as T));
		return values[(idx + delta + values.length) % values.length]!;
	}

	function diagnosticsMaxScroll(): number {
		const width = frameContentWidth(DEFAULT_WIDTH);
		return Math.max(0, renderDiagnostics(inventory, width, theme).length - diagnosticsPageRows());
	}

	function diagnosticsPageRows(): number {
		return Math.max(1, getLayout().innerRows - 5);
	}

	function scrollDiagnostics(delta: number): void {
		ui.diagnosticsScroll = Math.max(0, Math.min(ui.diagnosticsScroll + delta, diagnosticsMaxScroll()));
		requestRender();
	}

	function handleInput(data: string): void {
		if (ui.showAudit) {
			if (matchesKey(data, "escape") || matchesKey(data, "backspace")) {
				ui.showAudit = false;
				ui.diagnosticsScroll = 0;
				requestRender();
				return;
			}
			if (matchesKey(data, "ctrl+c")) return done({ type: "close" });
			if (matchesKey(data, "up")) return scrollDiagnostics(-1);
			if (matchesKey(data, "down")) return scrollDiagnostics(1);
			if (matchesKey(data, "-") || matchesKey(data, "pageUp")) return scrollDiagnostics(-diagnosticsPageRows());
			if (matchesKey(data, "=") || matchesKey(data, "pageDown")) return scrollDiagnostics(diagnosticsPageRows());
			if (matchesKey(data, "home")) {
				ui.diagnosticsScroll = 0;
				requestRender();
				return;
			}
			if (matchesKey(data, "end")) {
				ui.diagnosticsScroll = diagnosticsMaxScroll();
				requestRender();
				return;
			}
			return;
		}
		if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) return done({ type: "close" });
		if (matchesKey(data, "alt+a")) {
			ui.showAudit = true;
			ui.diagnosticsScroll = 0;
			requestRender();
			return;
		}
		const list = filteredItems(inventory.items, ui);
		const selected = list[ui.selected];
		if (matchesKey(data, "up")) {
			ui.selected -= 1;
			clamp();
			requestRender();
			return;
		}
		if (matchesKey(data, "down")) {
			ui.selected += 1;
			clamp();
			requestRender();
			return;
		}
		if (matchesKey(data, "-") || matchesKey(data, "pageUp")) {
			ui.selected -= getLayout().listRows;
			clamp();
			requestRender();
			return;
		}
		if (matchesKey(data, "=") || matchesKey(data, "pageDown")) {
			ui.selected += getLayout().listRows;
			clamp();
			requestRender();
			return;
		}
		if (matchesKey(data, "backspace")) {
			ui.search = ui.search.slice(0, -1);
			ui.selected = 0;
			clamp();
			requestRender();
			return;
		}
		if (matchesKey(data, "ctrl+u")) {
			ui.search = "";
			ui.selected = 0;
			clamp();
			requestRender();
			return;
		}
		if (matchesKey(data, "alt+x") && selected) return done({ type: "toggle-item", itemId: selected.id });
		if (matchesKey(data, "alt+u") && selected?.updateAvailable) return done({ type: "update-package", itemId: selected.id });
		if (matchesKey(data, "alt+d") && selected && selected.kind === "package") return done({ type: "uninstall-package", itemId: selected.id });
		if (isPlainSearchInput(data)) {
			ui.search += data;
			ui.selected = 0;
			clamp();
			requestRender();
			return;
		}
		if (matchesKey(data, "alt+s")) {
			ui.stateFilter = cycle(states, ui.stateFilter, 1);
			ui.selected = 0;
			clamp();
			requestRender();
			return;
		}
		if (matchesKey(data, "alt+o")) {
			ui.scopeFilter = cycle(scopes, ui.scopeFilter, 1);
			ui.selected = 0;
			clamp();
			requestRender();
			return;
		}
		if ((matchesKey(data, "enter") || matchesKey(data, "return")) && selected) {
			return done({ type: "toggle-item", itemId: selected.id });
		}
	}

	function render(width: number): string[] {
		clamp();
		const layout = getLayout();
		const safeWidth = Math.max(1, width);
		const bodyWidth = frameContentWidth(safeWidth);
		let lines: string[] = [];
		const primaryHint = ui.showAudit
			? `${theme.fg("dim", "diagnostics · ")}${ansiYellow("-/=")} ${theme.fg("dim", "page · ")}${ansiYellow("backspace")} ${theme.fg("dim", "back")}`
			: `${ansiYellow("-/=")} ${theme.fg("dim", "page · ")}${ansiYellow("alt+a")} ${theme.fg("dim", "diagnostics")}`;
		const footerLines = ["", ...wrapLine(primaryHint, bodyWidth)];
		const availableRows = Math.max(1, layout.innerRows - lines.length - footerLines.length);
		if (ui.showAudit) lines.push(...renderDiagnosticsViewport(inventory, ui, bodyWidth, theme, availableRows));
		else lines.push(...renderExtensions(inventory, ui, bodyWidth, theme, layout, footerLines.length));
		lines.push(...footerLines);
		return frame(lines, safeWidth, theme, layout.innerRows, "Extension Manager");
	}

	return { handleInput, invalidate() {}, render };
}

export async function openManager(pi: ExtensionAPI, ctx: ExtensionCommandContext | ExtensionContext): Promise<void> {
	const releaseModalLock = acquireVstackModalLock();
	try {
		let ui = makeInitialUiState();
		while (true) {
			const inventory = buildInventory(pi, ctx as ExtensionContext);
			const action = await ctx.ui.custom<ManagerAction>(
				(tui, theme, _keybindings, done) => createManagerComponent(ctx, inventory, ui, theme, () => tui.requestRender(), () => managerLayout(tui.terminal.rows), done),
				{ overlay: true, overlayOptions: { anchor: "center", maxHeight: DEFAULT_MAX_HEIGHT, width: DEFAULT_WIDTH_PERCENT } },
			);

			if (!action || action.type === "close") return;
			if (action.type === "toggle-item") {
				const item = inventory.items.find((candidate) => candidate.id === action.itemId);
				if (item) toggleItem(pi, ctx, inventory, item);
				continue;
			}
			if (action.type === "update-package") {
				const item = inventory.items.find((candidate) => candidate.id === action.itemId);
				if (!item) continue;
				const plan = planUpdate(item, inventory, ctx);
				if (!plan) {
					ctx.ui.notify(`${item.displayName} does not have an available update.`, "info");
					continue;
				}
				const body = [
					`Package: ${plan.item.packageName}`,
					`Scope: ${plan.item.scope}`,
					`Current: ${plan.item.installedVersion ?? "unknown"}`,
					`Latest: ${plan.item.latestVersion ?? "unknown"}`,
					"",
					plan.description,
					"",
					`Will run: ${plan.command}`,
				].join("\n");
				const confirmed = await ctx.ui.confirm(`Update ${plan.item.displayName}?`, body);
				if (!confirmed) continue;
				const result = runUpdate(plan);
				if (result.ok) ctx.ui.notify(`${result.message} Run /reload to apply.`, "warning");
				else ctx.ui.notify(result.message, "error");
				continue;
			}
			if (action.type === "uninstall-package") {
				const item = inventory.items.find((candidate) => candidate.id === action.itemId);
				if (!item) continue;
				if (item.packageName === MANAGER_ID) {
					ctx.ui.notify("Refusing to uninstall pi-extension-manager from inside itself.", "warning");
					continue;
				}
				const plan = planUninstall(item, inventory, ctx);
				if (!plan) {
					ctx.ui.notify(`${item.displayName} is not an uninstallable package.`, "warning");
					continue;
				}
				const body = [
					`Package: ${plan.item.packageName}`,
					`Scope: ${plan.item.scope}`,
					`Source: ${plan.item.sourceName}`,
					"",
					plan.description,
					"",
					`Will run: ${plan.command}`,
				].join("\n");
				const confirmed = await ctx.ui.confirm(`Uninstall ${plan.item.displayName}?`, body);
				if (!confirmed) continue;
				const result = runUninstall(plan, inventory);
				if (result.ok) ctx.ui.notify(`${result.message} Run /reload to apply.`, "warning");
				else ctx.ui.notify(result.message, "error");
				continue;
			}
		}
	} finally {
		releaseModalLock();
	}
}
