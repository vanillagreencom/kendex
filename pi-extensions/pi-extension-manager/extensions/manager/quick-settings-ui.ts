import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import type { AutocompleteItem } from "@earendil-works/pi-tui";
import { matchesKey, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import {
	ansiYellow,
	applyMessage,
	formatSettingValue,
	isPlainSearchInput,
	nextSettingValue,
	notifyReset,
	packageNameForTab,
	packageTabId,
	parseSettingInput,
	stringifyError,
	stringifySettingValue,
} from "./format.js";
import { handleInlineEditInput, renderInlineEditValue } from "./inline-edit.js";
import { buildInventory } from "./inventory.js";
import { selectedPackageForSetting } from "./filters.js";
import {
	divider,
	frame,
	frameContentWidth,
	managerEntityTitle,
	managerSelectedLine,
	pad,
	renderTabBar,
	wrapDescription,
	wrapLine,
} from "./render.js";
import {
	acquireVstackModalLock,
	getConfigValue,
	quickSettingsLayout,
	resetConfigKeys,
	setConfigValue,
} from "./settings.js";
import {
	type ConfigValue,
	type Inventory,
	type InventoryItem,
	type ManagerTab,
	type PopupLayout,
	type QuickSettingRow,
	type QuickSettingsAction,
	type QuickSettingsUiState,
	type SettingsSchema,
	type TopTab,
	DEFAULT_MAX_HEIGHT,
	DEFAULT_WIDTH_PERCENT,
	SETTINGS_EVENT,
	TAB_ALL,
} from "./types.js";

const EXTERNAL_SOURCE_FALLBACK = "the extension's own config file";

function externalSource(config: ConfigValue): string {
	return config.source ?? EXTERNAL_SOURCE_FALLBACK;
}

function externalSourceNote(config: ConfigValue): string {
	return `Value comes from ${externalSource(config)}. Editing it here writes Pi settings, which override that file.`;
}

function settingPackages(inventory: Inventory): InventoryItem[] {
	return inventory.packages.filter((item) => item.packageName && item.settingsSchema?.length && item.state !== "shadowed");
}

function quickSettingRows(inventory: Inventory): QuickSettingRow[] {
	const rows: QuickSettingRow[] = [];
	for (const item of settingPackages(inventory).sort((a, b) => a.displayName.localeCompare(b.displayName))) {
		const extensionId = selectedPackageForSetting(item) ?? item.displayName;
		const schemas = (item.settingsSchema ?? []).filter((schema) => schema.type !== "secret");
		for (const schema of schemas) {
			rows.push({
				extensionId,
				id: `${item.id}::${schema.key}`,
				item,
				packageName: item.displayName,
				schema,
			});
		}
	}
	return rows;
}

function quickSettingsTabs(rows: QuickSettingRow[]): ManagerTab[] {
	const tabs: ManagerTab[] = [{ id: TAB_ALL, label: "All" }];
	const seen = new Set<string>();
	for (const row of rows) {
		if (seen.has(row.extensionId)) continue;
		seen.add(row.extensionId);
		tabs.push({ id: packageTabId(row.extensionId), label: row.packageName, packageName: row.extensionId });
	}
	return tabs;
}

function filterQuickSettingRows(rows: QuickSettingRow[], search: string, inventory: Inventory, tab: TopTab): QuickSettingRow[] {
	const packageName = packageNameForTab(tab);
	const scopedRows = packageName ? rows.filter((row) => row.extensionId === packageName) : rows;
	const query = search.trim().toLowerCase();
	if (!query) return scopedRows;
	return scopedRows.filter((row) => {
		const config = getConfigValue(inventory, row.extensionId, row.schema);
		const hay = [
			row.packageName,
			row.schema.key,
			row.schema.label,
			row.schema.description,
			row.schema.type,
			formatSettingValue({ ...row.schema, secret: false }, config.value),
		].join("\n").toLowerCase();
		return hay.includes(query);
	});
}

function quickSettingEditValue(inventory: Inventory, row: QuickSettingRow): string {
	const value = getConfigValue(inventory, row.extensionId, row.schema).value;
	return stringifySettingValue(value ?? row.schema.default ?? "");
}

function applyOf(schema: SettingsSchema): "live" | "reload" | "session" | "restart" {
	return schema.apply ?? (schema.requiresReload ? "reload" : "live");
}

function saveQuickSetting(pi: ExtensionAPI, ctx: ExtensionCommandContext | ExtensionContext, inventory: Inventory, row: QuickSettingRow, value: unknown): void {
	setConfigValue(inventory, row.item, row.schema, value);
	pi.events.emit(SETTINGS_EVENT, { extensionId: row.extensionId, key: row.schema.key, value });
	const apply = applyOf(row.schema);
	if (apply !== "live") ctx.ui.notify(applyMessage(row.schema), apply === "restart" ? "warning" : "info");
}

// resetConfigKeys only deletes from settings.json, so a value owned by another
// config file survives the reset. Report that instead of a reset that did not
// happen.
function isManagerOwned(config: ConfigValue): boolean {
	return config.scope === "project" || config.scope === "user";
}

function resetQuickSetting(pi: ExtensionAPI, ctx: ExtensionCommandContext | ExtensionContext, inventory: Inventory, row: QuickSettingRow): void {
	const config = getConfigValue(inventory, row.extensionId, row.schema);
	const label = row.schema.label ?? row.schema.key;
	if (!config.explicit) {
		ctx.ui.notify(`${label} is already using its default.`, "info");
		return;
	}
	if (!isManagerOwned(config)) {
		ctx.ui.notify(`${label} is set by ${externalSource(config)} and cannot be reset from here. Edit that file, or press enter to override it in Pi settings.`, "warning");
		return;
	}
	resetConfigKeys(inventory, row.extensionId, [row.schema.key]);
	pi.events.emit(SETTINGS_EVENT, { extensionId: row.extensionId, key: row.schema.key, value: row.schema.default });
	notifyReset(ctx, label, [row.schema]);
}

function resetQuickSettingsForExtension(pi: ExtensionAPI, ctx: ExtensionCommandContext | ExtensionContext, inventory: Inventory, rows: QuickSettingRow[], extensionId: string, label: string): void {
	const scoped = rows.filter((row) => row.extensionId === extensionId).map((row) => ({ config: getConfigValue(inventory, row.extensionId, row.schema), row }));
	const managed = scoped.filter((entry) => isManagerOwned(entry.config));
	const external = scoped.filter((entry) => entry.config.explicit && !isManagerOwned(entry.config));
	if (managed.length === 0) {
		if (external.length > 0) {
			const sources = [...new Set(external.map((entry) => externalSource(entry.config)))].join(", ");
			ctx.ui.notify(`${label} has no settings stored in Pi settings; ${external.length === 1 ? "1 value comes" : `${external.length} values come`} from ${sources}.`, "warning");
			return;
		}
		ctx.ui.notify(`${label} settings are already using defaults.`, "info");
		return;
	}
	resetConfigKeys(inventory, extensionId, managed.map((entry) => entry.row.schema.key));
	for (const entry of managed) pi.events.emit(SETTINGS_EVENT, { extensionId, key: entry.row.schema.key, value: entry.row.schema.default });
	notifyReset(ctx, `${label} settings`, managed.map((entry) => entry.row.schema));
	if (external.length > 0) {
		const sources = [...new Set(external.map((entry) => externalSource(entry.config)))].join(", ");
		ctx.ui.notify(`${external.length} ${label} value${external.length === 1 ? " is" : "s are"} still set by ${sources}.`, "warning");
	}
}

function createQuickSettingsComponent(pi: ExtensionAPI, ctx: ExtensionCommandContext | ExtensionContext, inventory: Inventory, ui: QuickSettingsUiState, theme: Theme, requestRender: () => void, getLayout: () => PopupLayout, done: (action: QuickSettingsAction) => void) {
	const rows = quickSettingRows(inventory);
	const tabs = quickSettingsTabs(rows);
	const filtered = () => filterQuickSettingRows(rows, ui.search, inventory, ui.tab);
	const clamp = () => {
		const layout = getLayout();
		if (!tabs.some((tab) => tab.id === ui.tab)) ui.tab = TAB_ALL;
		const count = filtered().length;
		ui.selected = Math.max(0, Math.min(ui.selected, Math.max(0, count - 1)));
		if (ui.selected < ui.scroll) ui.scroll = ui.selected;
		if (ui.selected >= ui.scroll + layout.listRows) ui.scroll = ui.selected - layout.listRows + 1;
		ui.scroll = Math.max(0, Math.min(ui.scroll, Math.max(0, count - layout.listRows)));
	};
	const selectedRow = () => {
		clamp();
		return filtered()[ui.selected];
	};
	const cycle = <T extends string>(values: T[], current: string, delta: number): T => {
		const idx = Math.max(0, values.indexOf(current as T));
		return values[(idx + delta + values.length) % values.length]!;
	};
	const switchTab = (delta: number): void => {
		ui.tab = cycle(tabs.map((tab) => tab.id), ui.tab, delta);
		ui.selected = 0;
		ui.scroll = 0;
		clamp();
		requestRender();
	};
	const editOrToggle = () => {
		const row = selectedRow();
		if (!row) return;
		const current = getConfigValue(inventory, row.extensionId, row.schema).value;
		if (row.schema.type === "boolean" || row.schema.type === "enum") {
			saveQuickSetting(pi, ctx, inventory, row, nextSettingValue(row.schema, current));
			requestRender();
			return;
		}
		const buffer = quickSettingEditValue(inventory, row);
		ui.editing = { buffer, cursor: buffer.length, rowId: row.id };
		requestRender();
	};

	const saveInlineEdit = () => {
		const editing = ui.editing;
		if (!editing) return;
		const row = rows.find((candidate) => candidate.id === editing.rowId);
		if (!row) {
			ui.editing = undefined;
			requestRender();
			return;
		}
		try {
			const value = parseSettingInput(row.schema, editing.buffer);
			saveQuickSetting(pi, ctx, inventory, row, value);
			ui.editing = undefined;
			requestRender();
		} catch (error) {
			ctx.ui.notify(stringifyError(error), "error");
		}
	};

	function handleInput(data: string): void {
		if (ui.editing) {
			if (data === "\u001b" || matchesKey(data, "ctrl+c")) {
				ui.editing = undefined;
				requestRender();
				return;
			}
			if (matchesKey(data, "enter") || matchesKey(data, "return")) return saveInlineEdit();
			if (handleInlineEditInput(ui.editing, data)) {
				requestRender();
			}
			return;
		}
		if (data === "\u001b" || matchesKey(data, "ctrl+c")) return done({ type: "close" });
		if (matchesKey(data, "tab")) {
			switchTab(1);
			return;
		}
		if (matchesKey(data, "shift+tab")) {
			switchTab(-1);
			return;
		}
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
		if (matchesKey(data, "delete")) {
			const row = selectedRow();
			if (row) resetQuickSetting(pi, ctx, inventory, row);
			requestRender();
			return;
		}
		if (matchesKey(data, "alt+x") || matchesKey(data, "ctrl+x")) {
			const row = selectedRow();
			if (row) resetQuickSettingsForExtension(pi, ctx, inventory, rows, row.extensionId, row.packageName);
			requestRender();
			return;
		}
		if (matchesKey(data, "enter") || matchesKey(data, "return")) return editOrToggle();
		if (isPlainSearchInput(data)) {
			ui.search += data;
			ui.selected = 0;
			clamp();
			requestRender();
		}
	}

	function render(width: number): string[] {
		clamp();
		const layout = getLayout();
		const safeWidth = Math.max(1, width);
		const bodyWidth = frameContentWidth(safeWidth);
		const visible = filtered().slice(ui.scroll, ui.scroll + layout.listRows);
		const lines: string[] = [];
		const searchLine = ui.editing
			? theme.bg("toolPendingBg", pad(` ${theme.fg("dim", "Editing inline value")}`, bodyWidth))
			: theme.bg("toolPendingBg", pad(` > ${ui.search}${theme.inverse(" ")}`, bodyWidth));
		const footer = ui.editing
			? `${theme.fg("dim", "editing value · ")}${ansiYellow("←/→")} ${theme.fg("dim", "move · ")}${ansiYellow("alt+←/→")} ${theme.fg("dim", "word · ")}${ansiYellow("backspace/delete")} ${theme.fg("dim", "delete")}`
			: `${ansiYellow("tab")} ${theme.fg("dim", "switch extension tabs · ")}${ansiYellow("-/=")} ${theme.fg("dim", "page · ")}${ansiYellow("delete")} ${theme.fg("dim", "reset setting · ")}${ansiYellow("alt+x")} ${theme.fg("dim", "reset extension · ")}${ansiYellow("backspace")} ${theme.fg("dim", "clear")}`;
		lines.push(renderTabBar(tabs, ui.tab, bodyWidth, theme));
		lines.push("");
		lines.push(searchLine);
		lines.push("");
		lines.push(divider(bodyWidth, theme));
		const footerLines = [divider(bodyWidth, theme), ...wrapLine(footer, bodyWidth)];
		const fillBeforeFooter = (): void => {
			while (lines.length + footerLines.length < layout.innerRows) lines.push("");
		};
		if (visible.length === 0) {
			lines.push(theme.fg("muted", "No matching settings."));
			fillBeforeFooter();
			lines.push(...footerLines);
			return frame(lines, safeWidth, theme, layout.innerRows, "Extension Settings");
		}
		let lastPackage = "";
		for (const [visibleIndex, row] of visible.entries()) {
			const index = ui.scroll + visibleIndex;
			if (row.packageName !== lastPackage) {
				if (lastPackage) lines.push("");
				lines.push(managerEntityTitle(theme, row.packageName));
				lastPackage = row.packageName;
			}
			const selected = index === ui.selected;
			const config = getConfigValue(inventory, row.extensionId, row.schema);
			const itemPad = " ";
			const labelText = truncateToWidth(row.schema.label ?? row.schema.key, 34, "…");
			const label = selected ? theme.fg("text", labelText) : labelText;
			const isEditing = ui.editing?.rowId === row.id;
			const value = isEditing && ui.editing ? renderInlineEditValue(ui.editing) : formatSettingValue(row.schema, config.value);
			const valueText = theme.fg(isEditing ? "accent" : config.explicit ? "success" : selected ? "text" : "muted", value);
			const rowText = truncateToWidth(`${itemPad}${label}${" ".repeat(Math.max(1, 36 - visibleWidth(labelText)))}${valueText}`, bodyWidth, "…");
			lines.push(selected ? managerSelectedLine(theme, rowText, bodyWidth) : rowText);
			if (selected && !isEditing && row.schema.description) lines.push(...wrapDescription(row.schema.description, bodyWidth, theme, "    "));
			if (selected && !isEditing && config.scope === "external") lines.push(...wrapDescription(externalSourceNote(config), bodyWidth, theme, "    ", "dim"));
		}
		const moreBefore = ui.scroll > 0 ? `↑ ${ui.scroll}` : "";
		const moreAfter = ui.scroll + layout.listRows < filtered().length ? `↓ ${filtered().length - ui.scroll - layout.listRows}` : "";
		if (moreBefore || moreAfter) lines.push("", theme.fg("dim", [moreBefore, moreAfter].filter(Boolean).join(" · ")));
		fillBeforeFooter();
		lines.push(...footerLines);
		return frame(lines, safeWidth, theme, layout.innerRows, "Extension Settings");
	}

	return { handleInput, invalidate() {}, render };
}

function resolveQuickSettingsTab(tabs: ManagerTab[], hint: string): TopTab | undefined {
	const needle = hint.trim().toLowerCase();
	if (!needle) return undefined;
	if (needle === "all") return TAB_ALL;
	for (const tab of tabs) {
		if (tab.id === TAB_ALL) continue;
		const pkg = (tab.packageName ?? "").toLowerCase();
		const label = tab.label.toLowerCase();
		if (tab.id.toLowerCase() === needle || pkg === needle || label === needle) return tab.id;
	}
	for (const tab of tabs) {
		if (tab.id === TAB_ALL) continue;
		const pkg = (tab.packageName ?? "").toLowerCase();
		const label = tab.label.toLowerCase();
		if (pkg.includes(needle) || label.includes(needle)) return tab.id;
	}
	return undefined;
}

export function quickSettingsCompletions(pi: ExtensionAPI, ctx: ExtensionCommandContext | ExtensionContext, prefix: string): AutocompleteItem[] | null {
	try {
		const inventory = buildInventory(pi, ctx as ExtensionContext);
		const tabs = quickSettingsTabs(quickSettingRows(inventory));
		const query = prefix.trim().toLowerCase();
		const items: AutocompleteItem[] = tabs
			.filter((tab) => tab.id !== TAB_ALL && tab.packageName)
			.map((tab) => ({
				value: tab.packageName!,
				label: tab.label,
				description: `Open ${tab.label} settings`,
			}));
		const filtered = query
			? items.filter((item) => item.value.toLowerCase().includes(query) || (item.label ?? item.value).toLowerCase().includes(query))
			: items;
		return filtered.length > 0 ? filtered : null;
	} catch {
		return null;
	}
}

export async function openQuickSettings(pi: ExtensionAPI, ctx: ExtensionCommandContext | ExtensionContext, initialTabHint?: string): Promise<void> {
	const inventory = buildInventory(pi, ctx as ExtensionContext);
	if (settingPackages(inventory).length === 0) {
		ctx.ui.notify("No vstack extension settings are declared by installed packages.", "info");
		return;
	}
	let initialTab: TopTab = TAB_ALL;
	if (initialTabHint && initialTabHint.trim()) {
		const tabs = quickSettingsTabs(quickSettingRows(inventory));
		const resolved = resolveQuickSettingsTab(tabs, initialTabHint);
		if (resolved) initialTab = resolved;
		else ctx.ui.notify(`No settings tab matches "${initialTabHint}". Showing All.`, "warning");
	}
	const ui: QuickSettingsUiState = { scroll: 0, search: "", selected: 0, tab: initialTab };
	const releaseModalLock = acquireVstackModalLock();
	try {
		await ctx.ui.custom<QuickSettingsAction>(
			(tui, theme, _keybindings, done) => createQuickSettingsComponent(pi, ctx, inventory, ui, theme, () => tui.requestRender(), () => quickSettingsLayout(tui.terminal.rows), done),
			{ overlay: true, overlayOptions: { anchor: "center", maxHeight: DEFAULT_MAX_HEIGHT, width: DEFAULT_WIDTH_PERCENT } },
		);
	} finally {
		releaseModalLock();
	}
}
