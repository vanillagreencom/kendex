import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { mkdirSync } from "node:fs";
import { join, sep } from "node:path";
import { removeAppendSystemBlockForUninstall, syncAppendSystemForPackage } from "./append-system.js";
import { managerFailure, managerNotice, stringifyError } from "./format.js";
import { host } from "./host.js";
import { normalizePackageEntry } from "./inventory.js";
import { runCommand } from "./process.js";
import { asRecord, defaultWriteScope, findSettingsFile, updateManagerState, writeSettingsFile } from "./settings.js";
import { loadSourceIndex, npmPackageNameFromSource } from "./versions.js";
import {
	MANAGER_ID,
	type Inventory,
	type InventoryItem,
	type SettingsFile,
	type UninstallPlan,
	type UpdatePlan,
} from "./types.js";

function launchFailure(command: string, error: unknown): string {
	return managerNotice("command-launch", command, `Could not start the command: ${stringifyError(error)}`);
}

function exitFailure(key: string, result: ReturnType<typeof runCommand>): string {
	const value = result.status ?? result.signal ?? "unknown";
	const detail = (result.stderr ?? "").trim() || (result.stdout ?? "").trim()
		|| (result.signal ? `signal ${result.signal}` : result.status !== null ? `exit ${result.status}` : "unknown termination");
	return managerNotice(key, value, detail);
}

function npmRootFromPackageDir(packageDir: string | undefined): string | undefined {
	if (!packageDir) return undefined;
	const marker = `${sep}node_modules${sep}`;
	const idx = packageDir.indexOf(marker);
	return idx >= 0 ? packageDir.slice(0, idx) : undefined;
}

function npmWorkingDir(item: InventoryItem, inventory: Inventory, ctx: ExtensionCommandContext | ExtensionContext): string {
	const file = findSettingsFile(inventory.settingsFiles, item.scope);
	return npmRootFromPackageDir(item.packageDir) ?? (item.scope === "project" || item.scope === "user" ? join(file.baseDir, "npm") : ctx.cwd);
}

function shellQuote(value: string): string {
	return `'${value.replace(/'/g, "'\\''")}'`;
}

function shellJoin(argv: string[]): string {
	return argv.map(shellQuote).join(" ");
}

function npmCommandForScope(files: SettingsFile[], scope: InventoryItem["scope"]): { command: string; argsPrefix: string[]; display: string; warning?: string } {
	const file = findSettingsFile(files, scope);
	const raw = file.json.npmCommand;
	if (Array.isArray(raw)) {
		const argv = raw.filter((value): value is string => typeof value === "string" && value.length > 0);
		if (argv.length > 0) return { command: argv[0], argsPrefix: argv.slice(1), display: shellJoin(argv) };
	}
	if (raw !== undefined) return { command: "npm", argsPrefix: [], display: "npm", warning: managerNotice("npm-command-invalid", scope, "The npmCommand setting is invalid. Falling back to npm.") };
	return { command: "npm", argsPrefix: [], display: "npm" };
}

function ensureWorkingDir(cwd: string): { ok: true } | { ok: false; message: string } {
	try {
		mkdirSync(cwd, { recursive: true });
		return { ok: true };
	} catch (error) {
		return { ok: false, message: managerNotice("npm-cwd", cwd, `Could not prepare the npm working directory: ${stringifyError(error)}`) };
	}
}

export function planUninstall(item: InventoryItem, inventory: Inventory, ctx: ExtensionCommandContext | ExtensionContext): UninstallPlan | undefined {
	if (!host.packageActions) return undefined;
	if (item.kind !== "package" || !item.packageName) return undefined;
	const sourceIndex = loadSourceIndex(inventory.settingsFiles);
	const scopeFlag = item.scope === "user" ? " --global" : "";
	if (sourceIndex[item.packageName]) {
		return {
			item,
			method: { kind: "kendex", packageName: item.packageName, scope: item.scope },
			command: `kendex remove ${item.packageName}${scopeFlag}`,
			description: "Installed via kendex — runs the kendex remove command (deletes the package directory, the settings.json entry, and the source-index entry).",
		};
	}
	const npmName = npmPackageNameFromSource(item.sourceName);
	if (npmName) {
		const cwd = npmWorkingDir(item, inventory, ctx);
		const npm = npmCommandForScope(inventory.settingsFiles, item.scope);
		return {
			item,
			method: { kind: "npm", npmName, scope: item.scope, cwd, command: npm.command, argsPrefix: npm.argsPrefix },
			command: `(cd ${shellQuote(cwd)} && ${npm.display} uninstall ${npmName})`,
			description: `${npm.warning ? `${npm.warning}\n` : ""}Installed via npm — runs npm uninstall in Pi's scope-local npm directory, then strips the npm: entry from Pi settings.json.`,
		};
	}
	return {
		item,
		method: { kind: "orphan", packageName: item.packageName, scope: item.scope },
		command: `(strip ${item.sourceName} from ${item.scope} settings.json)`,
		description: "No kendex source-index entry and no npm: prefix — only the Pi settings.json entry will be removed.",
	};
}

function removePackageEntryFromSettings(item: InventoryItem, files: SettingsFile[]): boolean {
	const file = findSettingsFile(files, item.scope);
	if (!Array.isArray(file.json.packages)) return false;
	const before = file.json.packages.length;
	const next = file.json.packages.filter((entry) => {
		const normalized = normalizePackageEntry(entry, file.baseDir);
		if (!normalized) return true;
		return !packageEntryMatches(item, normalized);
	});
	if (next.length === before) return false;
	if (next.length === 0) delete file.json.packages;
	else file.json.packages = next;
	writeSettingsFile(file);
	return true;
}

function packageEntryMatches(item: InventoryItem, normalized: { source: string; resolved: string }): boolean {
	return normalized.resolved === item.sourcePath
		|| normalized.resolved === item.packageDir
		|| normalized.source === item.sourceName
		|| normalized.source === item.packageSourceName;
}

export function runUninstall(plan: UninstallPlan, inventory: Inventory): { ok: boolean; message: string } {
	if (!host.packageActions) return { ok: false, message: managerNotice("uninstall-unsupported", plan.item.id, "Package uninstall is unsupported on this host; use its native plugin manager.") };
	if (plan.method.kind === "kendex") {
		const args = ["remove", plan.method.packageName];
		if (plan.method.scope === "user") args.push("--global");
		const result = runCommand("kendex", args);
		if (result.error) return { ok: false, message: launchFailure("kendex", result.error) };
		if ((result.status ?? 1) !== 0) {
			return { ok: false, message: exitFailure("kendex-uninstall-exit", result) };
		}
		// `kendex remove` already handled APPEND_SYSTEM.md, so no extra cleanup here.
		return { ok: true, message: managerNotice("kendex-uninstalled", plan.item.packageName!, `Removed ${plan.item.displayName} via kendex.`) };
	}
	if (plan.method.kind === "npm") {
		const args = ["uninstall", plan.method.npmName];
		const prepared = ensureWorkingDir(plan.method.cwd);
		if (!prepared.ok) return prepared;
		// Before npm deletes the package tree: npm 7+ does not reliably run a
		// removed package's own `preuninstall`, and the script that owns the
		// APPEND_SYSTEM.md block goes with the tree.
		removeAppendSystemBlockForUninstall(plan.item);
		const result = runCommand(plan.method.command, [...plan.method.argsPrefix, ...args], { cwd: plan.method.cwd });
		if (result.error) return { ok: false, message: launchFailure(plan.method.command, result.error) };
		if ((result.status ?? 1) !== 0) {
			return { ok: false, message: exitFailure("npm-uninstall-exit", result) };
		}
		const stripped = removePackageEntryFromSettings(plan.item, inventory.settingsFiles);
		return { ok: true, message: managerNotice("npm-uninstalled", plan.method.npmName, `Uninstall succeeded${stripped ? "; removed Pi settings entry." : " (no settings entry to remove)."}`) };
	}
	const stripped = removePackageEntryFromSettings(plan.item, inventory.settingsFiles);
	// Orphan branch: the settings.json strip is the only other cleanup, so
	// remove this package's APPEND_SYSTEM.md block too.
	removeAppendSystemBlockForUninstall(plan.item);
	return stripped
		? { ok: true, message: managerNotice("settings-entry-removed", plan.item.sourceName, `Removed the entry from ${plan.item.scope} settings.json.`) }
		: { ok: false, message: managerNotice("settings-entry-missing", plan.item.sourceName, `No matching entry exists in ${plan.item.scope} settings.json.`) };
}

export function planUpdate(item: InventoryItem, inventory: Inventory, ctx: ExtensionCommandContext | ExtensionContext): UpdatePlan | undefined {
	if (!host.packageActions) return undefined;
	if (item.kind !== "package" || !item.packageName || !item.updateAvailable) return undefined;
	if (item.updateSource === "kendex" && item.sourceRepo) {
		const scopeFlag = item.scope === "user" ? " --global" : "";
		return {
			item,
			method: { kind: "kendex", packageName: item.packageName, sourceRepo: item.sourceRepo, scope: item.scope },
			command: `kendex add ${item.sourceRepo}${scopeFlag} --pi-extension ${item.packageName} --harness pi -y`,
			description: "Installed via kendex — copies the selected package from its tracked source repo into the same Pi scope.",
		};
	}
	if (item.updateSource === "npm" && item.npmName) {
		const cwd = npmWorkingDir(item, inventory, ctx);
		const npm = npmCommandForScope(inventory.settingsFiles, item.scope);
		return {
			item,
			method: { kind: "npm", npmName: item.npmName, scope: item.scope, cwd, command: npm.command, argsPrefix: npm.argsPrefix },
			command: `(cd ${shellQuote(cwd)} && ${npm.display} install ${item.npmName}@latest)`,
			description: `${npm.warning ? `${npm.warning}\n` : ""}Installed via npm — installs the latest published package version in Pi's scope-local npm directory, then Pi can load it after /reload or restart.`,
		};
	}
	return undefined;
}

export function runUpdate(plan: UpdatePlan): { ok: boolean; message: string } {
	if (!host.packageActions) return { ok: false, message: managerNotice("update-unsupported", plan.item.id, "Package update is unsupported on this host; use its native plugin manager.") };
	if (plan.method.kind === "kendex") {
		const args = ["add", plan.method.sourceRepo];
		if (plan.method.scope === "user") args.push("--global");
		args.push("--pi-extension", plan.method.packageName, "--harness", "pi", "-y");
		const result = runCommand("kendex", args);
		if (result.error) return { ok: false, message: launchFailure("kendex", result.error) };
		if ((result.status ?? 1) !== 0) {
			return { ok: false, message: exitFailure("kendex-update-exit", result) };
		}
		return { ok: true, message: managerNotice("kendex-updated", plan.item.packageName!, `Updated ${plan.item.displayName} via kendex.`) };
	}
	const args = ["install", `${plan.method.npmName}@latest`];
	const prepared = ensureWorkingDir(plan.method.cwd);
	if (!prepared.ok) return prepared;
	const result = runCommand(plan.method.command, [...plan.method.argsPrefix, ...args], { cwd: plan.method.cwd });
	if (result.error) return { ok: false, message: launchFailure(plan.method.command, result.error) };
	if ((result.status ?? 1) !== 0) {
		return { ok: false, message: exitFailure("npm-update-exit", result) };
	}
	return { ok: true, message: managerNotice("npm-updated", plan.method.npmName, "Package updated via npm.") };
}

function setPackageFiltered(item: InventoryItem, files: SettingsFile[], disabled: boolean): boolean {
	const file = findSettingsFile(files, item.scope);
	const packages = Array.isArray(file.json.packages) ? file.json.packages : [];
	let changed = false;
	const next = packages.map((entry) => {
		const normalized = normalizePackageEntry(entry, file.baseDir);
		if (!normalized || !packageEntryMatches(item, normalized)) return entry;
		changed = true;
		const record = asRecord(entry);
		if (disabled) {
			return record ? { ...record, extensions: [] } : { source: normalized.source, extensions: [] };
		}
		if (record) {
			const restored = { ...record };
			if (Array.isArray(restored.extensions) && restored.extensions.length === 0) delete restored.extensions;
			return Object.keys(restored).length === 1 && restored.source === normalized.source ? normalized.source : restored;
		}
		return normalized.source;
	});
	if (changed) {
		file.json.packages = next;
		writeSettingsFile(file);
	}
	return changed;
}

function setPackageExtensionFiltered(item: InventoryItem, files: SettingsFile[], disabled: boolean): boolean {
	if (!item.packageDir || !item.entrypoint) return false;
	const file = findSettingsFile(files, item.scope);
	const packages = Array.isArray(file.json.packages) ? file.json.packages : [];
	const exclude = `-${item.entrypoint}`;
	let changed = false;
	const next = packages.map((entry) => {
		const normalized = normalizePackageEntry(entry, file.baseDir);
		if (!normalized || !packageEntryMatches(item, normalized)) return entry;
		changed = true;
		const record = asRecord(entry);
		const filters = Array.isArray(record?.extensions) ? record!.extensions.filter((value): value is string => typeof value === "string") : [];
		const withoutThis = filters.filter((value) => value !== exclude && value !== `!${item.entrypoint}`);
		if (disabled) {
			const extensions = withoutThis.includes(exclude) ? withoutThis : [...withoutThis, exclude];
			return record ? { ...record, extensions } : { source: normalized.source, extensions };
		}
		if (record) {
			const restored = { ...record };
			if (withoutThis.length > 0) restored.extensions = withoutThis;
			else delete restored.extensions;
			return Object.keys(restored).length === 1 && restored.source === normalized.source ? normalized.source : restored;
		}
		return normalized.source;
	});
	if (changed) {
		file.json.packages = next;
		writeSettingsFile(file);
	}
	return changed;
}

export function toggleItem(_pi: ExtensionAPI, ctx: ExtensionCommandContext | ExtensionContext, inventory: Inventory, item: InventoryItem): void {
	if ((item.id === `package:${MANAGER_ID}` || item.packageName === MANAGER_ID) && item.state !== "disabled") {
		ctx.ui.notify(managerNotice("self-disable", MANAGER_ID, "The manager cannot disable itself. Use the host controls outside this manager."), "warning");
		return;
	}
	try {
		if (host.toggle(item)) {
			ctx.ui.notify(managerNotice("native-state-updated", item.id, "Native plugin state updated. Restart the host to apply all plugin contributions."), "warning");
			return;
		}
	} catch (error) {
		ctx.ui.notify(managerFailure("toggle-failed", item.id, error), "error");
		return;
	}
	const scope = defaultWriteScope(item, inventory.settingsFiles, inventory.managerState);
	const file = findSettingsFile(inventory.settingsFiles, scope);
	const disabled = new Set(inventory.managerState.disabledItems);
	const currentlyDisabled = item.state === "disabled" || disabled.has(item.id);
	const willDisable = !currentlyDisabled;
	if (willDisable) disabled.add(item.id);
	else disabled.delete(item.id);
	updateManagerState(file, (state) => {
		state.disabledItems = [...disabled].sort();
	});

	if (item.kind === "package" && item.packageName) {
		const changed = setPackageFiltered(item, inventory.settingsFiles, willDisable);
		syncAppendSystemForPackage(item, willDisable);
		ctx.ui.notify(managerNotice("package-toggle-saved", item.id, changed ? "Package setting updated. Run /reload or restart Pi to apply module loading changes." : "Item toggle saved. Reload may be required."), "warning");
		return;
	}

	if (item.kind === "extension module" && item.packageName && item.entrypoint) {
		const changed = setPackageExtensionFiltered(item, inventory.settingsFiles, willDisable);
		ctx.ui.notify(managerNotice("module-toggle-saved", item.id, changed ? "Extension module filter updated. Run /reload or restart Pi to apply." : "Module toggle saved. Reload may be required."), "warning");
		return;
	}

	ctx.ui.notify(managerNotice("item-toggle-saved", item.id, "Item toggle saved. Pi cannot unload this resource type live; /reload or restart may be required."), "warning");
}
