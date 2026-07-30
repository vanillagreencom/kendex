export const INSTALL_SYMBOL = Symbol.for("vstack.pi-extension-manager.installed");
export const MANAGER_ID = "@vanillagreen/pi-extension-manager";
export const SETTINGS_EVENT = "vstack:extension-settings-changed";
export const DEFAULT_WIDTH = 124;
export const DEFAULT_WIDTH_PERCENT = "92%";
export const DEFAULT_MAX_HEIGHT = "85%";
export const POPUP_HEIGHT_RATIO = 0.85;
export const POPUP_PADDING_X = 2;
export const POPUP_PADDING_Y = 1;
export const POPUP_FRAME_ROWS = 2 + POPUP_PADDING_Y * 2;
export const LEFT_MIN_WIDTH = 34;
export const LEFT_MAX_WIDTH = 48;
export const LIST_ROWS = 18;
export const MANAGER_INNER_ROWS = 32;
export const QUICK_SETTINGS_INNER_ROWS = 30;
export const QUICK_SETTINGS_ROWS = 18;
export const VSTACK_MODAL_LOCK_SYMBOL = Symbol.for("vstack.pi.modal-lock");
export const EXTERNAL_CONFIG_RESOLVER_SYMBOL = Symbol.for("vstack.pi.extension-config-resolver");
export const VSTACK_OPEN_QUICK_SETTINGS_SYMBOL = Symbol.for("vstack.pi.extension-manager.open-quick-settings");
export const NPM_CACHE_TTL_MS = 24 * 60 * 60 * 1000;
export const TAB_ALL = "all";
export const PACKAGE_TAB_PREFIX = "package:";

export type Scope = "user" | "project" | "temporary" | "builtin" | "unknown";
export type ExtensionState = "active" | "disabled" | "shadowed" | "broken";
export type ApplyMode = "live" | "reload" | "session" | "restart";
export type SettingType = "boolean" | "enum" | "string" | "number" | "secret" | "path";
export type TopTab = string;

export interface SettingsSchema {
	key: string;
	label?: string;
	description?: string;
	type: SettingType;
	default?: unknown;
	enumValues?: string[];
	secret?: boolean;
	category?: string;
	apply?: ApplyMode;
	requiresReload?: boolean;
	validation?: Record<string, unknown>;
}

export interface PackageManifest {
	name?: string;
	version?: string;
	description?: string;
	keywords?: string[];
	pi?: {
		extensions?: string[];
		skills?: string[];
		prompts?: string[];
		themes?: string[];
	};
	vstack?: {
		extensionManager?: {
			displayName?: string;
			settings?: SettingsSchema[];
		};
	};
}

export interface SettingsFile {
	scope: Scope;
	baseDir: string;
	path: string;
	json: Record<string, unknown>;
	exists: boolean;
	projectTrusted?: boolean;
}

export interface ManagerState {
	disabledItems: string[];
	config: Record<string, Record<string, unknown>>;
}

export interface ConfigValue {
	value: unknown;
	/** `external` — the effective value comes from a config file the manager does not own. */
	scope: Scope | "default" | "external";
	explicit: boolean;
	/** Display path of the file behind an `external` value. */
	source?: string;
}

export interface ExternalConfigResolution {
	explicit: boolean;
	value: unknown;
	source?: string;
}

/**
 * An extension that reads settings from channels beyond manager config publishes
 * one of these under EXTERNAL_CONFIG_RESOLVER_SYMBOL, keyed by package name, so
 * the settings editor can show the value the extension actually resolves.
 */
export type ExternalConfigResolver = (key: string, cwd: string) => ExternalConfigResolution | undefined;

export type ExternalConfigResolverRegistry = Record<string, ExternalConfigResolver>;

export interface PopupLayout {
	bodyRows: number;
	innerRows: number;
	listRows: number;
}

export interface VstackModalLock {
	depth: number;
}

export interface InventoryItem {
	id: string;
	displayName: string;
	kind: string;
	state: ExtensionState;
	stateReason: string;
	description: string;
	provider: string;
	scope: Scope;
	sourcePath: string;
	sourceName: string;
	packageName?: string;
	packageDir?: string;
	packageSourceName?: string;
	entrypoint?: string;
	trigger?: string;
	shadowedBy?: string;
	settingsSchema?: SettingsSchema[];
	brokenError?: string;
	metadata?: Record<string, unknown>;
	installedVersion?: string;
	latestVersion?: string;
	updateAvailable?: boolean;
	updateSource?: "vstack" | "npm";
	updateCommand?: string;
	installSource?: "vstack" | "npm" | "unknown";
	npmName?: string;
	sourceRepo?: string;
}

export interface SourceIndexEntry {
	sourceRepo?: string;
	sourcePath?: string;
	sourceVersion?: string;
	sourceCommit?: string;
	installedAt?: number;
}

export type SourceIndex = Record<string, SourceIndexEntry>;

export interface NpmCacheEntry {
	version: string;
	checkedAt: number;
}

export type NpmCache = Record<string, NpmCacheEntry>;

export interface Inventory {
	items: InventoryItem[];
	packages: InventoryItem[];
	settingsFiles: SettingsFile[];
	managerState: ManagerState;
	auditLines: string[];
	cwd: string;
}

export interface ManagerTab {
	id: TopTab;
	label: string;
	packageName?: string;
}

export interface ManagerActionToggleItem {
	type: "toggle-item";
	itemId: string;
}

export interface ManagerActionUninstallPackage {
	type: "uninstall-package";
	itemId: string;
}

export interface ManagerActionUpdatePackage {
	type: "update-package";
	itemId: string;
}

export type ManagerAction = ManagerActionToggleItem | ManagerActionUninstallPackage | ManagerActionUpdatePackage | { type: "close" } | undefined;

export interface ManagerUiState {
	search: string;
	selected: number;
	scroll: number;
	diagnosticsScroll: number;
	stateFilter: string;
	scopeFilter: string;
	showAudit: boolean;
}

export interface InlineEditState {
	buffer: string;
	cursor: number;
}

export interface InlineEditChar {
	ch: string;
	start: number;
	end: number;
}

export type UninstallMethod =
	| { kind: "vstack"; packageName: string; scope: Scope }
	| { kind: "npm"; npmName: string; scope: Scope; cwd: string; command: string; argsPrefix: string[] }
	| { kind: "orphan"; packageName: string; scope: Scope };

export interface UninstallPlan {
	item: InventoryItem;
	method: UninstallMethod;
	command: string;
	description: string;
}

export type UpdateMethod =
	| { kind: "vstack"; packageName: string; sourceRepo: string; scope: Scope }
	| { kind: "npm"; npmName: string; scope: Scope; cwd: string; command: string; argsPrefix: string[] };

export interface UpdatePlan {
	item: InventoryItem;
	method: UpdateMethod;
	command: string;
	description: string;
}

export interface QuickSettingTarget {
	item: InventoryItem;
	schema: SettingsSchema;
	extensionId: string;
}

export interface QuickSettingRow extends QuickSettingTarget {
	id: string;
	packageName: string;
}

export interface QuickSettingsUiState {
	editing?: InlineEditState & { rowId: string };
	scroll: number;
	search: string;
	selected: number;
	tab: TopTab;
}

export type QuickSettingsAction = { type: "close" } | undefined;
