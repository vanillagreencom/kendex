import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { host } from "./host.js";
import {
	EXTERNAL_CONFIG_RESOLVER_SYMBOL,
	LIST_ROWS,
	MANAGER_ID,
	MANAGER_INNER_ROWS,
	POPUP_FRAME_ROWS,
	POPUP_HEIGHT_RATIO,
	QUICK_SETTINGS_INNER_ROWS,
	QUICK_SETTINGS_ROWS,
	KENDEX_MODAL_LOCK_SYMBOL,
	type ConfigValue,
	type ExternalConfigResolution,
	type ExternalConfigResolver,
	type ExternalConfigResolverRegistry,
	type Inventory,
	type InventoryItem,
	type ManagerState,
	type PopupLayout,
	type Scope,
	type SettingsFile,
	type SettingsSchema,
	type kendexModalLock,
} from "./types.js";

export function asRecord(value: unknown): Record<string, unknown> | undefined {
	return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
}

export function getOrCreateRecord(parent: Record<string, unknown>, key: string): Record<string, unknown> {
	const current = asRecord(parent[key]);
	if (current) return current;
	if (parent[key] !== undefined) throw new Error(`${key} must be an object`);
	const created: Record<string, unknown> = {};
	parent[key] = created;
	return created;
}

export function loadSettingsFiles(ctx: ExtensionContext): SettingsFile[] {
	return host.settings(ctx);
}

export function writeSettingsFile(file: SettingsFile): void {
	host.write(file);
}

export function managerStateFrom(json: Record<string, unknown>): ManagerState {
	const kendex = asRecord(json.kendex) ?? {};
	const manager = asRecord(kendex.extensionManager) ?? {};
	const config = asRecord(manager.config) ?? {};
	const normalizedConfig: Record<string, Record<string, unknown>> = {};
	for (const [id, value] of Object.entries(config)) {
		const record = asRecord(value);
		if (record) normalizedConfig[id] = { ...record };
	}
	return {
		disabledItems: Array.isArray(manager.disabledItems) ? manager.disabledItems.filter((v): v is string => typeof v === "string") : [],
		config: normalizedConfig,
	};
}

function deepMergeConfig(
	base: Record<string, Record<string, unknown>>,
	override: Record<string, Record<string, unknown>>,
): Record<string, Record<string, unknown>> {
	const out: Record<string, Record<string, unknown>> = {};
	for (const [id, values] of Object.entries(base)) out[id] = { ...values };
	for (const [id, values] of Object.entries(override)) out[id] = { ...(out[id] ?? {}), ...values };
	return out;
}

function scopedManagerState(files: SettingsFile[], scope: Scope): ManagerState {
	return files.filter((file) => file.scope === scope).reduce<ManagerState>((merged, file) => {
		const state = managerStateFrom(file.json);
		return { disabledItems: [...new Set([...merged.disabledItems, ...state.disabledItems])], config: deepMergeConfig(merged.config, state.config) };
	}, { disabledItems: [], config: {} });
}

export function mergedManagerState(files: SettingsFile[]): ManagerState {
	const user = scopedManagerState(files, "user");
	const project = scopedManagerState(files, "project");
	return {
		disabledItems: [...new Set([...user.disabledItems, ...project.disabledItems])],
		config: deepMergeConfig(user.config, project.config),
	};
}

export function updateManagerState(file: SettingsFile, updater: (state: ManagerState) => void): void {
	const kendex = getOrCreateRecord(file.json, "kendex");
	const manager = getOrCreateRecord(kendex, "extensionManager");
	const current = managerStateFrom(file.json);
	updater(current);
	manager.disabledItems = current.disabledItems;
	delete manager.disabledProviders;
	manager.config = current.config;
	writeSettingsFile(file);
}

export function findSettingsFile(files: SettingsFile[], scope: Scope): SettingsFile {
	return files.filter((file) => file.scope === scope).at(-1) ?? files[0]!;
}

function projectSettingsWritable(files: SettingsFile[]): boolean {
	return files.some((file) => file.scope === "project" && file.exists && file.projectTrusted !== false);
}

export function defaultWriteScope(item: InventoryItem | undefined, files: SettingsFile[], managerState: ManagerState): Scope {
	if (item?.scope === "project" && projectSettingsWritable(files)) return "project";
	if (item?.scope === "user") return "user";
	const configured = managerState.config[MANAGER_ID]?.defaultSaveScope;
	if (configured === "user") return "user";
	if (configured === "project" && projectSettingsWritable(files)) return "project";
	return projectSettingsWritable(files) ? "project" : "user";
}

export function externalConfigResolvers(): ExternalConfigResolverRegistry {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const existing = asRecord(host[EXTERNAL_CONFIG_RESOLVER_SYMBOL]);
	if (existing) return existing as ExternalConfigResolverRegistry;
	const created: ExternalConfigResolverRegistry = {};
	host[EXTERNAL_CONFIG_RESOLVER_SYMBOL] = created;
	return created;
}

/**
 * Ask the owning extension for the value it resolves from its own config files.
 * A missing, malformed, or throwing resolver is indistinguishable from "nothing
 * external is set" — the modal must never fail to render because of one.
 */
function externalConfigValue(extensionId: string, key: string, cwd: string): ExternalConfigResolution | undefined {
	const resolver = externalConfigResolvers()[extensionId] as ExternalConfigResolver | undefined;
	if (typeof resolver !== "function") return undefined;
	try {
		const resolved = resolver(key, cwd);
		return resolved && typeof resolved === "object" && resolved.explicit === true ? resolved : undefined;
	} catch {
		return undefined;
	}
}

// External lookups touch the filesystem, and the settings popup re-reads every
// visible row on each keystroke. One resolver call per (extension, key) per
// inventory keeps that cost off the render path; the inventory is rebuilt each
// time the popup opens, so edits to the external file still show up.
const externalConfigCache = new WeakMap<Inventory, Map<string, ExternalConfigResolution | undefined>>();

function cachedExternalConfigValue(inventory: Inventory, extensionId: string, key: string): ExternalConfigResolution | undefined {
	let cache = externalConfigCache.get(inventory);
	if (!cache) {
		cache = new Map();
		externalConfigCache.set(inventory, cache);
	}
	const cacheKey = `${extensionId}::${key}`;
	if (cache.has(cacheKey)) return cache.get(cacheKey);
	const resolved = externalConfigValue(extensionId, key, inventory.cwd);
	cache.set(cacheKey, resolved);
	return resolved;
}

export function getConfigValue(inventory: Inventory, extensionId: string, schema: SettingsSchema): ConfigValue {
	const project = scopedManagerState(inventory.settingsFiles, "project");
	const user = scopedManagerState(inventory.settingsFiles, "user");
	if (Object.prototype.hasOwnProperty.call(project.config[extensionId] ?? {}, schema.key)) {
		return { explicit: true, scope: "project", value: project.config[extensionId]![schema.key] };
	}
	if (Object.prototype.hasOwnProperty.call(user.config[extensionId] ?? {}, schema.key)) {
		return { explicit: true, scope: "user", value: user.config[extensionId]![schema.key] };
	}
	// Manager config outranks the extension's own files, matching how extensions
	// layer the two, so this runs only when neither manager scope holds the key.
	const external = cachedExternalConfigValue(inventory, extensionId, schema.key);
	if (external) return { explicit: true, scope: "external", value: external.value, source: external.source };
	return { explicit: false, scope: "default", value: schema.default };
}

export function setConfigValue(inventory: Inventory, item: InventoryItem, schema: SettingsSchema, value: unknown): void {
	const extensionId = item.packageName ?? item.displayName;
	host.assertSettingsSupported(extensionId);
	const scope = defaultWriteScope(item, inventory.settingsFiles, inventory.managerState);
	const file = findSettingsFile(inventory.settingsFiles, scope);
	updateManagerState(file, (state) => {
		state.config[extensionId] = { ...(state.config[extensionId] ?? {}), [schema.key]: value };
	});
}

function deleteConfigKeysFromFile(file: SettingsFile, extensionId: string, keys: Set<string>): number {
	const kendex = asRecord(file.json.kendex);
	const manager = asRecord(kendex?.extensionManager);
	const config = asRecord(manager?.config);
	const record = asRecord(config?.[extensionId]);
	if (!manager || !config || !record) return 0;
	let deleted = 0;
	for (const key of keys) {
		if (!Object.prototype.hasOwnProperty.call(record, key)) continue;
		delete record[key];
		deleted += 1;
	}
	if (deleted === 0) return 0;
	if (Object.keys(record).length === 0) delete config[extensionId];
	if (Object.keys(config).length === 0) delete manager.config;
	writeSettingsFile(file);
	return deleted;
}

export function resetConfigKeys(inventory: Inventory, extensionId: string, keys: Iterable<string>): number {
	host.assertSettingsSupported(extensionId);
	const keySet = new Set(keys);
	if (keySet.size === 0) return 0;
	let deleted = 0;
	for (const file of inventory.settingsFiles.filter((candidate) => candidate.scope === "user" || candidate.scope === "project")) {
		deleted += deleteConfigKeysFromFile(file, extensionId, keySet);
	}
	return deleted;
}

export function acquirekendexModalLock(): () => void {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const existing = host[KENDEX_MODAL_LOCK_SYMBOL] as kendexModalLock | undefined;
	const lock = existing && typeof existing.depth === "number" ? existing : { depth: 0 };
	host[KENDEX_MODAL_LOCK_SYMBOL] = lock;
	lock.depth += 1;
	let released = false;
	return () => {
		if (released) return;
		released = true;
		lock.depth = Math.max(0, lock.depth - 1);
	};
}

function responsiveInnerRows(terminalRows: number, preferred: number, minimum = 12): number {
	const available = Math.max(minimum + POPUP_FRAME_ROWS, Math.floor(Math.max(1, terminalRows) * POPUP_HEIGHT_RATIO));
	return Math.max(minimum, Math.min(preferred, available - POPUP_FRAME_ROWS));
}

export function managerLayout(terminalRows: number): PopupLayout {
	const innerRows = responsiveInnerRows(terminalRows, MANAGER_INNER_ROWS, 14);
	const bodyRows = Math.max(4, innerRows - 10);
	return {
		bodyRows,
		innerRows,
		listRows: Math.max(3, Math.min(LIST_ROWS, bodyRows - 6)),
	};
}

export function quickSettingsLayout(terminalRows: number): PopupLayout {
	const innerRows = responsiveInnerRows(terminalRows, QUICK_SETTINGS_INNER_ROWS, 12);
	const bodyRows = Math.max(4, innerRows - 8);
	return {
		bodyRows,
		innerRows,
		listRows: Math.max(3, Math.min(QUICK_SETTINGS_ROWS, bodyRows)),
	};
}
