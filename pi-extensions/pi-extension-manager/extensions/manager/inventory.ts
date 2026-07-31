import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve, sep } from "node:path";
import { stringifyError } from "./format.js";
import { expandHome } from "./paths.js";
import { asRecord, loadSettingsFiles, mergedManagerState } from "./settings.js";
import {
	gitPackageDirCandidates,
	isNewer,
	loadNpmCache,
	loadSourceIndex,
	npmInstalledVersion,
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

function readPackageManifest(dir: string): { manifest?: PackageManifest; error?: string } {
	try {
		const path = join(dir, "package.json");
		const parsed = JSON.parse(readFileSync(path, "utf8"));
		return { manifest: parsed as PackageManifest };
	} catch (error) {
		return { error: stringifyError(error) };
	}
}

function readNpmPackageManifest(npmName: string, scope: Scope, baseDir: string, cwd: string): { dir?: string; manifest?: PackageManifest; error?: string } {
	const dir = resolveNpmPackageDir(npmName, scope, baseDir, cwd);
	if (!dir) return { error: `package source not found: npm:${npmName}` };
	return { dir, ...readPackageManifest(dir) };
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
	return manifest.vstack?.extensionManager?.displayName || manifest.name || fallback;
}

function isSettingType(value: unknown): value is SettingType {
	return value === "boolean" || value === "enum" || value === "string" || value === "number" || value === "secret" || value === "path";
}

function isSettingSchema(value: unknown): value is SettingsSchema {
	const record = asRecord(value);
	return Boolean(record && typeof record.key === "string" && isSettingType(record.type));
}

function settingSchema(manifest: PackageManifest): SettingsSchema[] {
	const schema = manifest.vstack?.extensionManager?.settings;
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

function collectConfiguredExtensions(file: SettingsFile): InventoryItem[] {
	const entries = Array.isArray(file.json.extensions) ? file.json.extensions : [];
	const items: InventoryItem[] = [];
	for (const entry of entries) {
		if (typeof entry !== "string" || entry.startsWith("!")) continue;
		const resolved = resolveSource(entry, file.baseDir);
		items.push(makeResourceItem(`extension-setting:${file.scope}:${entry}`, entry, "extension setting", file.scope, resolved, `${file.scope}:extensions`, entry, "Configured in settings.json extensions[]"));
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
			item.stateReason = "explicitly disabled in vstack extension manager";
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
	const sourceIndex = loadSourceIndex(settingsFiles);
	const npmCache = loadNpmCache();
	for (const item of items) {
		if (item.kind !== "package" || !item.packageName) continue;
		resetUpdateMetadata(item);
		item.installSource = "unknown";

		const npmName = npmPackageNameFromSource(item.sourceName);
		if (npmName) {
			item.installSource = "npm";
			item.npmName = npmName;
			item.installedVersion = item.installedVersion ?? npmInstalledVersion(npmName, cwd);
			const latest = npmCache[npmName]?.version;
			if (latest) {
				item.latestVersion = latest;
				item.updateSource = "npm";
				item.updateAvailable = isNewer(latest, item.installedVersion);
				item.updateCommand = npmUpdateCommand(item, npmName);
			}
			continue;
		}

		const sourceEntry = sourceIndex[item.packageName];
		if (sourceEntry?.sourceRepo) {
			item.installSource = "vstack";
			item.sourceRepo = sourceEntry.sourceRepo;
			const latest = readSourceRepoVersion(sourceEntry.sourceRepo, item.packageName, sourceEntry.sourcePath);
			if (latest) {
				item.latestVersion = latest;
				item.updateSource = "vstack";
				item.updateAvailable = isNewer(latest, item.installedVersion);
				const scopeFlag = item.scope === "user" ? " --global" : "";
				item.updateCommand = `vstack add ${sourceEntry.sourceRepo}${scopeFlag} --pi-extension ${item.packageName} --harness pi -y`;
			}
		}
	}
}

export function buildInventory(_pi: ExtensionAPI, ctx: ExtensionContext): Inventory {
	const settingsFiles = loadSettingsFiles(ctx);
	const managerState = mergedManagerState(settingsFiles);
	const items: InventoryItem[] = [];
	const auditLines: string[] = [];
	const seenPackages = new Map<string, InventoryItem>();

	// Project scope wins over user scope, mirroring Pi settings override behavior.
	for (const file of [...settingsFiles].sort((a, b) => (a.scope === "project" ? -1 : b.scope === "project" ? 1 : 0))) {
		const packages = Array.isArray(file.json.packages) ? file.json.packages : [];
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
				const read = readNpmPackageManifest(npmName, file.scope, file.baseDir, ctx.cwd);
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
			const pkgId = `package:${packageName}`;
			const packageItem: InventoryItem = {
				brokenError,
				description: manifest?.description ?? "Pi package",
				displayName: packageDisplayName(manifest ?? {}, packageName),
				id: pkgId,
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
						id: `extension:${packageName}:${extPath}`,
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
		items.push(...collectConfiguredExtensions(file));
		items.push(...collectAutoExtensions(file.baseDir, file.scope));
	}

	for (const item of items) {
		if (item.kind !== "package" || !item.packageName) continue;
		// Manifest was already parsed above when building the inventory entry; the version
		// is recorded on the item to avoid a second readFileSync+JSON.parse pass per
		// package on popup open (vstack#74).
		if (!item.installedVersion) item.installedVersion = readPackageVersionFromDir(item.packageDir);
	}
	applyUpdateMetadata(items, settingsFiles, ctx.cwd);

	applyDisableState(items, managerState);
	items.sort(compareInventoryItems);
	return { auditLines, cwd: ctx.cwd ?? process.cwd(), items, managerState, packages: items.filter((item) => item.kind === "package"), settingsFiles };
}

export function npmCandidatesFromInventory(inventory: Inventory): { name: string; npmName: string }[] {
	const out: { name: string; npmName: string }[] = [];
	for (const item of inventory.items) {
		if (item.kind !== "package" || !item.packageName) continue;
		const npmName = npmPackageNameFromSource(item.sourceName);
		if (npmName) out.push({ name: item.packageName, npmName });
	}
	return out;
}
