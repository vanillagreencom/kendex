import { existsSync, lstatSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, extname, join, resolve } from "node:path";
import { findProjectPiDir, rootAnchored, userPiDir } from "./paths.js";
import { MANAGER_ID, type InventoryItem, type PackageManifest, type SettingsFile } from "./types.js";

/** Host-owned resolvers are injected so profiles and XDG rules stay in the host. */
export interface OmpRuntime {
	getAgentDir(): string;
	getPluginsDir(): string;
	getProjectAgentDir(cwd: string): string;
	getProjectPluginOverridesPath(cwd: string): string;
	resolveActiveProjectRegistryPath(cwd: string): Promise<string | null>;
	YAML: { parse(text: string): unknown; stringify(value: unknown): string };
}

type Context = { cwd: string; isProjectTrusted?: () => boolean };

function record(value: unknown, label: string): Record<string, unknown> {
	if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object`);
	return value as Record<string, unknown>;
}

function optionalRecord(value: unknown, label: string): Record<string, unknown> {
	return value === undefined ? {} : record(value, label);
}

function strings(value: unknown, label: string): string[] {
	if (value === undefined) return [];
	if (!Array.isArray(value) || value.some((v) => typeof v !== "string")) throw new Error(`${label} must be a string array`);
	return value;
}

/** One boundary for host paths, persisted documents, native inventory and mutations. */
export class HostAdapter {
	private omp?: OmpRuntime;
	private agent: () => string;
	private projectRoots = new Map<string, string | null>();
	readonly commands: { manager: string; settings: string; recover: string };
	readonly packageActions: boolean;

	constructor(agent: () => string = userPiDir, omp?: OmpRuntime) {
		this.agent = agent;
		this.omp = omp;
		this.packageActions = !omp;
		const manager = omp ? "kendex:extensions" : "extensions";
		this.commands = { manager, settings: `${manager}:settings`, recover: `${manager}:enable` };
	}

	agentDir(): string { return this.agent(); }
	projectDir(cwd: string): string { return this.omp ? this.omp.getProjectAgentDir(cwd) : findProjectPiDir(cwd); }

	/** Refresh the host's asynchronous project anchor before opening an inventory. */
	async prepare(cwd: string): Promise<void> {
		if (this.omp) this.projectRoots.set(cwd, await this.omp.resolveActiveProjectRegistryPath(cwd));
	}

	settingsPath(scope: "user" | "project", cwd: string): string {
		const base = scope === "user" ? this.agentDir() : this.projectDir(cwd);
		if (!this.omp) return join(base, "settings.json");
		const names = scope === "user" ? ["config.yml", "config.yaml"] : ["config.yml", "settings.json"];
		return names.map((name) => join(base, name)).find(existsSync) ?? join(base, "config.yml");
	}

	read(path: string): Record<string, unknown> {
		if (!existsSync(path)) return {};
		const text = readFileSync(path, "utf8");
		const parsed = this.omp && /\.ya?ml$/.test(path) ? this.omp.YAML.parse(text) : JSON.parse(text);
		const json = record(parsed, path);
		const kendex = optionalRecord(json.kendex, `${path}: kendex`);
		const manager = optionalRecord(kendex.extensionManager, `${path}: extensionManager`);
		const config = optionalRecord(manager.config, `${path}: manager config`);
		for (const [name, value] of Object.entries(config)) record(value, `${path}: ${name} config`);
		strings(manager.disabledItems, `${path}: disabledItems`);
		return json;
	}

	settings(ctx: Context): SettingsFile[] {
		let trusted = false;
		try { trusted = ctx.isProjectTrusted?.() === true; } catch { trusted = false; }
		return (["user", "project"] as const).flatMap((scope) => {
			const selected = this.settingsPath(scope, ctx.cwd);
			const readable = scope === "user" || trusted;
			const projectPaths = this.omp && scope === "project"
				? ["settings.json", "config.yml"].map((name) => join(this.projectDir(ctx.cwd), name)).filter(existsSync)
				: [];
			const paths = projectPaths.length > 0 ? projectPaths : [selected];
			return paths.map((path) => ({ scope, path, baseDir: dirname(path), exists: readable && existsSync(path), json: readable ? this.read(path) : {}, projectTrusted: scope === "project" ? trusted : undefined }));
		});
	}

	/** Native trusted project documents are creatable; Pi retains its existing-file fallback. */
	projectSettingsWritable(files: SettingsFile[]): boolean {
		return files.some((file) => file.scope === "project" && file.projectTrusted !== false && (file.exists || (this.omp !== undefined && file.projectTrusted === true)));
	}

	write(file: SettingsFile): void {
		if (file.projectTrusted === false) throw new Error(`Project settings are not trusted: ${file.path}`);
		// Revalidate before writing: malformed persisted input is never replaced with defaults.
		this.read(file.path);
		const text = this.omp && /\.ya?ml$/.test(file.path) ? this.omp.YAML.stringify(file.json) : JSON.stringify(file.json, null, 2);
		mkdirSync(dirname(file.path), { recursive: true });
		writeFileSync(file.path, `${text.trimEnd()}\n`, "utf8");
		file.exists = true;
	}

	/** OMP replaces the configured extension array and resolves its paths against cwd. */
	configuredExtensionFiles(files: SettingsFile[]): SettingsFile[] {
		if (!this.omp) return files;
		const file = files.filter((candidate) => candidate.json.extensions !== undefined).at(-1);
		if (!file) return [];
		strings(file.json.extensions, `${file.path}: extensions`);
		return [file];
	}

	extensionBase(file: SettingsFile, cwd: string): string { return this.omp ? cwd : file.baseDir; }

	/** Bootstrap enablement belongs to the global layer, independent of package installation scope. */
	configScope(packageName: string, key: string): "user" | undefined {
		return packageName === MANAGER_ID && key === "enabled" ? "user" : undefined;
	}

	settingsSupported(packageName: string): boolean { return !this.omp || packageName === MANAGER_ID; }

	assertSettingsSupported(packageName: string): void {
		if (!this.settingsSupported(packageName)) throw new Error("Settings for other extensions are unsupported on this host; use the owning extension's settings.");
	}

	private lock(path: string): Record<string, unknown> {
		const json = this.read(path);
		const plugins = optionalRecord(json.plugins, `${path}: plugins`);
		for (const [name, value] of Object.entries(plugins)) {
			const state = record(value, `${path}: ${name}`);
			if (typeof state.enabled !== "boolean") throw new Error(`${path}: ${name}.enabled must be boolean`);
			if (state.enabledFeatures !== null) strings(state.enabledFeatures, `${path}: ${name}.enabledFeatures`);
		}
		return json;
	}

	/** Undefined selects Pi's package-settings inventory, not an empty native inventory. */
	installedItems(cwd: string): InventoryItem[] | undefined {
		if (!this.omp) return undefined;
		if (!this.projectRoots.has(cwd)) throw new Error("Host project paths have not been prepared");
		const registry = this.projectRoots.get(cwd);
		const userRoot = this.omp.getPluginsDir();
		const roots: { root: string; scope: "user" | "project" }[] = [{ root: userRoot, scope: "user" }];
		if (registry && dirname(registry) !== userRoot) roots.push({ root: dirname(registry), scope: "project" });
		const overridesPath = this.omp.getProjectPluginOverridesPath(cwd);
		const overrides = this.read(overridesPath);
		const disabled = strings(overrides.disabled, `${overridesPath}: disabled`);
		const items: InventoryItem[] = [];
		for (const { root, scope } of roots) {
			if (!existsSync(join(root, "node_modules"))) continue;
			const packagePath = join(root, "package.json");
			const dependencies = optionalRecord(this.read(packagePath).dependencies, `${packagePath}: dependencies`);
			const lockPath = join(root, "omp-plugins.lock.json");
			const lock = this.lock(lockPath);
			const plugins = optionalRecord(lock.plugins, `${lockPath}: plugins`);
			for (const name of new Set([...Object.keys(dependencies), ...Object.keys(plugins)])) {
				const dir = join(root, "node_modules", name);
				if (!existsSync(dir)) continue;
				if (existsSync(packagePath) && !Object.hasOwn(dependencies, name) && !lstatSync(dir).isSymbolicLink()) continue;
				if (!existsSync(join(dir, "package.json"))) continue;
				const pkg = this.read(join(dir, "package.json"));
				const native = pkg.omp ?? pkg.pi;
				if (native === undefined) continue;
				const manifest = record(native, `${name}: manifest`);
				const state = optionalRecord(plugins[name], `${name}: state`);
				const suppressed = disabled.includes(name);
				const installationId = `package:${scope}:${name}`;
				const item: InventoryItem = {
					id: installationId, installationId, packageName: name, packageDir: dir, kind: "package", scope,
					displayName: (pkg as PackageManifest).kendex?.extensionManager?.displayName ?? name,
					description: typeof pkg.description === "string" ? pkg.description : "Installed plugin",
					sourceName: name, sourcePath: dir, provider: `${scope}:plugins`,
					installedVersion: typeof pkg.version === "string" ? pkg.version : undefined,
					state: state.enabled === false || suppressed ? "disabled" : "active",
					stateReason: suppressed ? `suppressed by ${overridesPath}` : state.enabled === false ? "native plugin disabled" : "native plugin enabled",
					settingsSchema: this.settingsSupported(name) ? (pkg as PackageManifest).kendex?.extensionManager?.settings ?? [] : [],
					metadata: { lockPath, overridesPath, suppressed },
				};
				items.push(item);
				for (const entrypoint of strings(manifest.extensions, `${name}: extensions`)) {
					items.push({ ...item, id: `extension:${scope}:${name}:${entrypoint}`, kind: "extension module", displayName: entrypoint, sourcePath: resolve(dir, entrypoint), entrypoint, settingsSchema: [] });
				}
			}
		}
		const projectNames = new Set(items.filter((item) => item.scope === "project" && item.kind === "package" && item.state === "active").map((item) => item.packageName));
		for (const item of items) {
			if (item.scope === "user" && item.state === "active" && projectNames.has(item.packageName)) {
				item.state = "shadowed";
				item.stateReason = "shadowed by enabled project plugin";
			}
			if (item.state !== "active") item.settingsSchema = [];
		}
		return items;
	}

	/** Normalize native module suppression; module writes remain read-only. */
	decorateItems(items: InventoryItem[], files: SettingsFile[]): void {
		if (!this.omp) return;
		const disabled = files.reduce<string[]>((current, file) => file.json.disabledExtensions === undefined ? current : strings(file.json.disabledExtensions, `${file.path}: disabledExtensions`), []);
		for (const item of items) {
			if (item.kind === "package" || item.state !== "active") continue;
			const name = /^index\.[jt]s$/.test(basename(item.sourcePath)) ? basename(dirname(item.sourcePath)) : basename(item.sourcePath, extname(item.sourcePath));
			if (disabled.includes(`extension-module:${name}`)) {
				item.state = "disabled";
				item.stateReason = "disabled by host module ID";
			}
		}
	}

	/** A refusal shared by the action handler and its UI hint. */
	toggleUnavailable(item: InventoryItem): string | undefined {
		if (!this.omp) return undefined;
		if (item.kind !== "package" || !item.packageName || item.state === "shadowed" || typeof item.metadata?.lockPath !== "string") return "Module and shadowed-item toggles are unsupported; use the host extension controls.";
		if (item.metadata.suppressed) return `Enable is blocked by project plugin overrides: ${item.metadata.overridesPath}`;
		return undefined;
	}

	/** Returns false only when Pi's existing filter implementation owns the toggle. */
	toggle(item: InventoryItem): boolean {
		if (!this.omp) return false;
		const refusal = this.toggleUnavailable(item);
		if (refusal) throw new Error(refusal);
		const path = item.metadata!.lockPath as string;
		const json = this.lock(path);
		const plugins = optionalRecord(json.plugins, `${path}: plugins`);
		const state = optionalRecord(plugins[item.packageName!], item.packageName!);
		plugins[item.packageName!] = { version: item.installedVersion, enabledFeatures: null, ...state, enabled: item.state === "disabled" };
		json.plugins = plugins;
		this.write({ path, baseDir: dirname(path), scope: item.scope, json, exists: existsSync(path) });
		return true;
	}
}

/** The factory replaces the test/default Pi adapter once using the running host exports. */
export let host = new HostAdapter();

/** Select by runtime API, never by the existence of another host's directories. */
export async function selectHost(runtime: Record<string, unknown>, loadOmp: () => Promise<OmpRuntime>): Promise<HostAdapter> {
	if (typeof runtime.getAgentDir !== "function") throw new Error("Unsupported host: missing getAgentDir");
	const agent = runtime.getAgentDir as () => string;
	if (typeof runtime.Settings === "function") return host = new HostAdapter(agent, await loadOmp());
	if (typeof runtime.SettingsManager === "function") {
		return host = new HostAdapter(() => {
			const reported = agent();
			return rootAnchored(reported, process.platform === "win32") ? resolve(reported) : userPiDir();
		});
	}
	throw new Error("Unsupported host settings API");
}

export async function initializeHost(): Promise<void> {
	const runtime = await import("@earendil-works/pi-coding-agent");
	host = await selectHost(runtime, async () => {
		const utils = await import("@oh-my-pi/pi-utils");
		const discovery = await import("@oh-my-pi/pi-coding-agent/discovery/helpers");
		const { YAML } = await import("bun");
		return { ...utils, resolveActiveProjectRegistryPath: discovery.resolveActiveProjectRegistryPath, YAML };
	});
}
