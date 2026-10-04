import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve, sep } from "node:path";
import { stringifyError } from "./format.js";
import { host } from "./host.js";
import { APPEND_SYSTEM_DEADLINE_MS } from "./append-system.js";
import { expandHome } from "./package-config.js";
import { STOP_SETTLE_MS } from "./process.js";
import { asRecord, getOrCreateRecord, loadSettingsFiles, managerStateFrom, mergedManagerState } from "./settings.js";
import {
	gitPackageDirCandidates,
	isNewer,
	loadNpmCache,
	loadSourceIndex,
	npmPackageNameFromSource,
	readPackageVersionFromDir,
	readSourceRepoVersion,
	resolveNpmPackageDir,
} from "./versions.js";
import {
	type Inventory,
	type InventoryItem,
	type ManagerState,
	type PackageManifest,
	type Scope,
	type SettingsFile,
	type SettingsSchema,
	type SettingType,
} from "./types.js";

const MAX_INVENTORY_ITEMS = 10_000;

function readPackageManifest(dir: string): { manifest?: PackageManifest; error?: string } {
	try {
		const path = join(dir, "package.json");
		const parsed = JSON.parse(readFileSync(path, "utf8"));
		return { manifest: parsed as PackageManifest };
	} catch (error) {
		return { error: stringifyError(error) };
	}
}

async function readNpmPackageManifest(signal: AbortSignal, npmName: string, scope: Scope, baseDir: string, cwd: string): Promise<{ dir?: string; manifest?: PackageManifest; error?: string }> {
	const lookup = await resolveNpmPackageDir(signal, npmName, scope, baseDir, cwd);
	switch (lookup.kind) {
		case "found":
			return { dir: lookup.dir, ...readPackageManifest(lookup.dir) };
		case "missing":
			return { error: [`package source not found: npm:${npmName}`, ...lookup.lookupFailures].join("; ") };
		default: {
			const unreachable: never = lookup;
			throw new Error(`npm-package-dir: unknown lookup ${JSON.stringify(unreachable)}`);
		}
	}
}

function readFirstPackageManifest(dirs: string[]): { dir?: string; manifest?: PackageManifest; error?: string } {
	const attempted: string[] = [];
	for (const dir of dirs) {
		attempted.push(dir);
		if (!existsSync(dir)) continue;
		try {
			if (!statSync(dir).isDirectory()) continue;
		} catch {
			continue;
		}
		const read = readPackageManifest(dir);
		return { dir, ...read };
	}
	return attempted.length > 0 ? { error: `package source not found: ${attempted.join(", ")}` } : { error: "package source not found" };
}

function resolveSource(source: string, baseDir: string): string {
	const expanded = expandHome(source);
	if (expanded.startsWith("npm:") || expanded.startsWith("git:") || expanded.startsWith("http://") || expanded.startsWith("https://") || expanded.startsWith("ssh://") || expanded.startsWith("git://")) {
		return expanded;
	}
	return resolve(baseDir, expanded);
}

function normalizePackageEntry(entry: unknown, baseDir: string): { source: string; resolved: string; disabledByFilter: boolean } | undefined {
	if (typeof entry === "string") {
		return { source: entry, resolved: resolveSource(entry, baseDir), disabledByFilter: false };
	}
	const record = asRecord(entry);
	if (!record || typeof record.source !== "string") return undefined;
	const extensionsFilter = record.extensions;
	const allDisabled = Array.isArray(extensionsFilter) && extensionsFilter.length === 0;
	return { source: record.source, resolved: resolveSource(record.source, baseDir), disabledByFilter: allDisabled };
}

export { normalizePackageEntry };

function packageDisplayName(manifest: PackageManifest, fallback: string): string {
	return manifest.kendex?.extensionManager?.displayName || manifest.name || fallback;
}

function isSettingType(value: unknown): value is SettingType {
	return value === "boolean" || value === "enum" || value === "string" || value === "number" || value === "secret" || value === "path";
}

function isSettingSchema(value: unknown): value is SettingsSchema {
	const record = asRecord(value);
	return Boolean(record && typeof record.key === "string" && isSettingType(record.type));
}

function settingSchema(manifest: PackageManifest): SettingsSchema[] {
	const schema = manifest.kendex?.extensionManager?.settings;
	return Array.isArray(schema) ? schema.filter(isSettingSchema) : [];
}

function safeReadDir(path: string): string[] {
	try {
		return readdirSync(path).sort();
	} catch {
		return [];
	}
}

function makeResourceItem(
	id: string,
	displayName: string,
	kind: string,
	scope: Scope,
	sourcePath: string,
	provider: string,
	sourceName: string,
	description = "",
	trigger?: string,
): InventoryItem {
	return {
		description,
		displayName,
		id,
		kind,
		provider,
		scope,
		sourceName,
		sourcePath,
		state: "active",
		stateReason: "loaded or discoverable",
		trigger,
	};
}

function collectConfiguredExtensions(file: SettingsFile, cwd: string): InventoryItem[] {
	const entries = Array.isArray(file.json.extensions) ? file.json.extensions : [];
	const items: InventoryItem[] = [];
	for (const entry of entries) {
		if (typeof entry !== "string" || entry.startsWith("!")) continue;
		// Built-in selectors belong to pi config, not the path-based inventory.
		if (entry.startsWith("builtin:") || entry.startsWith("-builtin:")) continue;
		const resolved = resolveSource(entry, host.extensionBase(file, cwd));
		items.push(makeResourceItem(`extension-setting:${file.scope}:${entry}`, entry, "extension setting", file.scope, resolved, `${file.scope}:extensions`, entry, `Configured in ${file.path} extensions[]`));
	}
	return items;
}

function collectAutoExtensions(baseDir: string, scope: Scope): InventoryItem[] {
	const roots = [join(baseDir, "extensions")];
	const items: InventoryItem[] = [];
	for (const root of roots) {
		if (!existsSync(root)) continue;
		for (const entry of safeReadDir(root)) {
			const full = join(root, entry);
			try {
				const stat = statSync(full);
				if (stat.isFile() && /\.[cm]?[jt]s$/.test(entry)) {
					items.push(makeResourceItem(`extension:${scope}:${full}`, entry, "extension module", scope, full, `${scope}:extensions`, full));
				} else if (stat.isDirectory()) {
					const index = ["index.ts", "index.js", "index.mts", "index.mjs"].map((name) => join(full, name)).find((p) => existsSync(p));
					if (index) items.push(makeResourceItem(`extension:${scope}:${index}`, entry, "extension module", scope, index, `${scope}:extensions`, root));
				}
			} catch {
				// ignore transient filesystem errors in inventory scan
			}
		}
	}
	return items;
}

function formatPackageAudit(item: InventoryItem, manifest: PackageManifest): string {
	const extensions = manifest.pi?.extensions?.join(", ") || "none";
	const settings = settingSchema(manifest);
	const settingText = settings.length === 0 ? "no declared settings schema" : settings.map((s) => `${s.key}:${s.type}:${s.apply ?? (s.requiresReload ? "reload" : "live")}`).join(", ");
	return `${manifest.name ?? item.displayName}\n  source: ${item.sourcePath}\n  entrypoints: ${extensions}\n  settings: ${settingText}`;
}

function kindRank(kind: string): number {
	const order: Record<string, number> = {
		package: 0,
		"extension module": 1,
	};
	return order[kind] ?? 9;
}

export function compareInventoryItems(a: InventoryItem, b: InventoryItem): number {
	return kindRank(a.kind) - kindRank(b.kind)
		|| (a.packageName ?? a.sourceName ?? "").localeCompare(b.packageName ?? b.sourceName ?? "")
		|| a.displayName.localeCompare(b.displayName)
		|| a.id.localeCompare(b.id);
}

function applyDisableState(items: InventoryItem[], managerState: ManagerState): void {
	const disabledItems = new Set(managerState.disabledItems);
	for (const item of items) {
		if (item.state === "shadowed" || item.state === "broken") continue;
		if (disabledItems.has(item.id)) {
			item.state = "disabled";
			item.stateReason = "explicitly disabled in kendex extension manager";
		}
	}
}

function resetUpdateMetadata(item: InventoryItem): void {
	delete item.latestVersion;
	delete item.updateAvailable;
	delete item.updateSource;
	delete item.updateCommand;
	delete item.npmName;
	delete item.sourceRepo;
}

function shellQuote(value: string): string {
	return `'${value.replace(/'/g, "'\\''")}'`;
}

function npmRootFromPackageDir(packageDir: string | undefined): string | undefined {
	if (!packageDir) return undefined;
	const marker = `${sep}node_modules${sep}`;
	const idx = packageDir.indexOf(marker);
	return idx >= 0 ? packageDir.slice(0, idx) : undefined;
}

function npmUpdateCommand(item: InventoryItem, npmName: string): string {
	const npmDir = npmRootFromPackageDir(item.packageDir);
	return npmDir ? `(cd ${shellQuote(npmDir)} && npm install ${npmName}@latest)` : `pi install npm:${npmName}@latest`;
}

export function applyUpdateMetadata(items: InventoryItem[], settingsFiles: SettingsFile[], cwd: string): void {
	if (!host.packageActions) return;
	const npmCache = loadNpmCache();
	for (const item of items) {
		if (item.kind !== "package" || !item.packageName) continue;
		resetUpdateMetadata(item);
		item.installSource = "unknown";

		const npmName = npmPackageNameFromSource(item.sourceName);
		if (npmName) {
			item.installSource = "npm";
			item.npmName = npmName;
			const latest = npmCache[npmName]?.version;
			if (latest) {
				item.latestVersion = latest;
				item.updateSource = "npm";
				item.updateAvailable = isNewer(latest, item.installedVersion);
				item.updateCommand = npmUpdateCommand(item, npmName);
			}
			continue;
		}

		const sourceEntry = loadSourceIndex(settingsFiles.filter((file) => file.scope === item.scope))[item.packageName];
		if (sourceEntry?.sourceRepo) {
			item.installSource = "kendex";
			item.sourceRepo = sourceEntry.sourceRepo;
			const latest = readSourceRepoVersion(sourceEntry.sourceRepo, item.packageName, sourceEntry.sourcePath);
			if (latest) {
				item.latestVersion = latest;
				item.updateSource = "kendex";
				item.updateAvailable = isNewer(latest, item.installedVersion);
				const scopeFlag = item.scope === "user" ? " --global" : "";
				item.updateCommand = `kendex add ${sourceEntry.sourceRepo}${scopeFlag} --pi-extension ${item.packageName} --harness pi -y`;
			}
		}
	}
}

export async function buildInventory(pi: ExtensionAPI, ctx: ExtensionContext): Promise<Inventory> {
	const signal = inventorySession(pi).controller.signal;
	const settingsFiles = loadSettingsFiles(ctx);
	const items: InventoryItem[] = [];
	const auditLines: string[] = [];
	const seenPackages = new Map<string, InventoryItem>();
	const installed = host.installedItems(ctx.cwd);
	if (installed) items.push(...installed);

	// Project scope wins over user scope, mirroring Pi settings override behavior.
	for (const file of [...settingsFiles].sort((a, b) => (a.scope === "project" ? -1 : b.scope === "project" ? 1 : 0))) {
		const packages = installed === undefined && Array.isArray(file.json.packages) ? file.json.packages : [];
		for (const rawEntry of packages) {
			const normalized = normalizePackageEntry(rawEntry, file.baseDir);
			if (!normalized) continue;
			const npmName = npmPackageNameFromSource(normalized.source);
			const fallbackName = npmName ?? normalized.source.split("/").filter(Boolean).pop()?.replace(/\.git$/, "") ?? normalized.source;
			let manifest: PackageManifest | undefined;
			let brokenError: string | undefined;
			let packageDir = normalized.resolved;
			if (existsSync(normalized.resolved) && statSync(normalized.resolved).isDirectory()) {
				const read = readPackageManifest(normalized.resolved);
				manifest = read.manifest;
				brokenError = read.error;
			} else if (npmName) {
				const read = await readNpmPackageManifest(signal, npmName, file.scope, file.baseDir, ctx.cwd);
				packageDir = read.dir ?? normalized.resolved;
				manifest = read.manifest ?? { name: npmName, description: "External npm package source" };
				brokenError = read.error;
			} else if (normalized.resolved.startsWith("git:") || normalized.resolved.startsWith("http") || normalized.resolved.startsWith("ssh://") || normalized.resolved.startsWith("git://")) {
				const read = readFirstPackageManifest(gitPackageDirCandidates(normalized.resolved, file.scope, file.baseDir));
				packageDir = read.dir ?? normalized.resolved;
				manifest = read.manifest ?? { name: fallbackName, description: "External git package source" };
				brokenError = read.error;
			} else {
				brokenError = `package source not found: ${normalized.resolved}`;
			}

			const packageName = manifest?.name ?? fallbackName;
			// Persisted ids share the registration's scope and source, never its physical target.
			const pkgId = `package:${file.scope}:${normalized.source}:${packageName}`;
			const packageItem: InventoryItem = {
				brokenError,
				description: manifest?.description ?? "Pi package",
				displayName: packageDisplayName(manifest ?? {}, packageName),
				id: pkgId,
				installationId: pkgId,
				installedVersion: typeof manifest?.version === "string" ? manifest.version : undefined,
				kind: "package",
				packageDir,
				packageName,
				packageSourceName: normalized.source,
				provider: `${file.scope}:packages`,
				scope: file.scope,
				settingsSchema: manifest ? settingSchema(manifest) : [],
				sourceName: normalized.source,
				sourcePath: packageDir,
				state: brokenError ? "broken" : normalized.disabledByFilter ? "disabled" : "active",
				stateReason: brokenError ?? (normalized.disabledByFilter ? "package entry filters extensions: []" : "package listed in settings.json"),
			};

			const existing = seenPackages.get(packageName);
			if (existing && existing.scope === "project" && packageItem.scope === "user") {
				packageItem.state = "shadowed";
				packageItem.stateReason = `shadowed by project package ${existing.sourcePath}`;
				packageItem.shadowedBy = existing.id;
			} else if (!existing) {
				seenPackages.set(packageName, packageItem);
			}
			items.push(packageItem);

			if (manifest) {
				auditLines.push(formatPackageAudit(packageItem, manifest));
				for (const extPath of manifest.pi?.extensions ?? []) {
					const fullPath = resolve(packageDir, extPath);
					items.push({
						description: `Entrypoint from ${packageName}`,
						displayName: extPath,
						entrypoint: extPath,
						id: `extension:${pkgId}:${extPath}`,
						installationId: pkgId,
						kind: "extension module",
						packageDir,
						packageName,
						packageSourceName: normalized.source,
						provider: `${file.scope}:packages`,
						scope: file.scope,
						sourceName: packageName,
						sourcePath: fullPath,
						state: packageItem.state,
						stateReason: packageItem.state === "active" ? "declared in package pi.extensions" : packageItem.stateReason,
					});
				}
			}
		}
	}
	for (const file of host.configuredExtensionFiles(settingsFiles)) items.push(...collectConfiguredExtensions(file, ctx.cwd));
	const scanned = new Set<string>();
	for (const file of settingsFiles) {
		if (scanned.has(file.baseDir)) continue;
		scanned.add(file.baseDir);
		items.push(...collectAutoExtensions(file.baseDir, file.scope));
	}

	for (const item of items) {
		if (item.kind !== "package" || !item.packageName) continue;
		// Manifest was already parsed above when building the inventory entry; the version
		// is recorded on the item to avoid a second readFileSync+JSON.parse pass per
		// package on popup open.
		if (!item.installedVersion) item.installedVersion = readPackageVersionFromDir(item.packageDir);
	}
	applyUpdateMetadata(items, settingsFiles, ctx.cwd);

	if (installed === undefined) {
		// Read the pre-3.0.4 stored ids through 3.0.x; 3.1.0 can remove this migration.
		let legacyFound = false;
		for (const file of settingsFiles) {
			const disabled = new Set(managerStateFrom(file.json).disabledItems);
			const migrated = new Set(disabled);
			let fileLegacyFound = false;
			for (const item of items) {
				if (item.scope !== file.scope || !item.packageName) continue;
				const oldId = item.kind === "package" ? `package:${item.packageName}` : item.entrypoint ? `extension:${item.packageName}:${item.entrypoint}` : undefined;
				if (!oldId || !disabled.has(oldId)) continue;
				migrated.delete(oldId);
				migrated.add(item.id);
				fileLegacyFound = true;
			}
			if (fileLegacyFound) {
				const manager = getOrCreateRecord(getOrCreateRecord(file.json, "kendex"), "extensionManager");
				manager.disabledItems = [...migrated];
				legacyFound = true;
			}
		}
		if (legacyFound) console.warn("pi-extension-manager: legacy-disabled-ids=3.0.x\nStored toggles use old ids. Saving a toggle writes scoped ids.");
	}
	const managerState = mergedManagerState(settingsFiles);
	if (installed === undefined) applyDisableState(items, managerState);
	host.decorateItems(items, settingsFiles);
	if (items.length > MAX_INVENTORY_ITEMS) throw new Error(`inventory-limit: items=${items.length} limit=${MAX_INVENTORY_ITEMS}`);
	items.sort(compareInventoryItems);
	return { auditLines, cwd: ctx.cwd ?? process.cwd(), items, managerState, packages: items.filter((item) => item.kind === "package"), settingsFiles };
}

export function npmCandidatesFromInventory(inventory: Inventory): { name: string; npmName: string }[] {
	if (!host.packageActions) return [];
	const out: { name: string; npmName: string }[] = [];
	for (const item of inventory.items) {
		if (item.kind !== "package" || !item.packageName) continue;
		const npmName = npmPackageNameFromSource(item.sourceName);
		if (npmName) out.push({ name: item.packageName, npmName });
	}
	return out;
}

/**
 * Longest shutdown waits for the session's work: the stop of the command the
 * abort reached, then the script a failed uninstall runs to put its block
 * back, which the abort does not stop, up to its deadline and its own stop.
 */
const SHUTDOWN_WAIT_MS = STOP_SETTLE_MS + APPEND_SYSTEM_DEADLINE_MS + STOP_SETTLE_MS;

interface InventorySession {
	controller: AbortController;
	inventory?: Inventory;
	/** Work started by `sessionWork`, each settled to undefined, until it settles. */
	running: Set<Promise<void>>;
}
const sessions = new WeakMap<ExtensionAPI, InventorySession>();

function newSession(): InventorySession {
	return { controller: new AbortController(), running: new Set() };
}

/** The current session owns commands, root memoization, and one inventory snapshot. */
export function inventorySession(pi: ExtensionAPI): InventorySession {
	let session = sessions.get(pi);
	if (!session) {
		session = newSession();
		sessions.set(pi, session);
	}
	return session;
}

/**
 * Run `work` under the session's signal. Shutdown aborts that signal and waits
 * for the work to settle, so what a stop or a failed uninstall does after the
 * abort (the SIGKILL past the grace, the block restore) runs before Pi exits.
 */
export function sessionWork<T>(pi: ExtensionAPI, work: (signal: AbortSignal) => Promise<T>): Promise<T> {
	const session = inventorySession(pi);
	const running = work(session.controller.signal);
	const settled = running.then(() => undefined, () => undefined);
	session.running.add(settled);
	void settled.then(() => session.running.delete(settled));
	return running;
}

/** Refresh only at session, popup-open, or mutation boundaries. */
export async function refreshInventory(pi: ExtensionAPI, ctx: ExtensionContext): Promise<Inventory> {
	const session = inventorySession(pi);
	await host.prepare(ctx.cwd);
	const inventory = await sessionWork(pi, () => buildInventory(pi, ctx));
	if (!session.controller.signal.aborted) session.inventory = inventory;
	return inventory;
}

/**
 * Release every session resource on shutdown or replacement: abort the
 * session's work, then wait for it to settle, at most `SHUTDOWN_WAIT_MS`.
 */
export async function closeInventorySession(pi: ExtensionAPI): Promise<void> {
	const session = sessions.get(pi);
	if (!session) return;
	session.controller.abort();
	session.inventory = undefined;
	let bound: ReturnType<typeof setTimeout> | undefined;
	await Promise.race([Promise.all(session.running), new Promise<void>((resolve) => { bound = setTimeout(resolve, SHUTDOWN_WAIT_MS); })]);
	clearTimeout(bound);
}

/** Replace the closed session owner at the host's session-start boundary. */
export function startInventorySession(pi: ExtensionAPI): void {
	// The replaced session's work stops on its own; the new session does not wait for it.
	void closeInventorySession(pi);
	sessions.set(pi, newSession());
}
