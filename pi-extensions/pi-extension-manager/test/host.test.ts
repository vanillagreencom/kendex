import { __setSpawnSyncForTests } from "../extensions/manager/process.ts";
import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { YAML } from "bun";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { host, selectHost, type OmpRuntime } from "../extensions/manager/host.ts";
import { buildInventory, closeInventorySession, inventorySession, refreshInventory, npmCandidatesFromInventory } from "../extensions/manager/inventory.ts";
import { planUninstall, planUpdate, runUninstall, runUpdate, toggleItem } from "../extensions/manager/actions.ts";
import { setConfigValue, resetConfigKeys, updateManagerState, getConfigValue, mergedManagerState, defaultWriteScope } from "../extensions/manager/settings.ts";
import { glyphStyle } from "../extensions/manager/glyphs.ts";
import { clearPackageConfigCache, piUserDir } from "../extensions/manager/package-config.ts";
import { MANAGER_ID, type ManagerUiState } from "../extensions/manager/types.ts";
import { filteredItems } from "../extensions/manager/filters.ts";
// Neutral terminal primitives; the production components own row construction and grouping.
mock.module("@earendil-works/pi-tui", () => ({
	matchesKey: (input: string, key: string) => input === key,
	truncateToWidth: (text: string) => text,
	visibleWidth: (text: string) => text.length,
	wrapTextWithAnsi: (text: string) => [text],
}));
const { openManager } = await import("../extensions/manager/manager-ui.ts");
const { openQuickSettings, quickSettingsCompletions } = await import("../extensions/manager/quick-settings-ui.ts");
import { pendingRequest } from "./fixtures/http.ts";

const root = join(process.cwd(), "tmp", "manager-host-tests");
const agent = join(root, "home", ".omp", "agent");
const plugins = join(root, "data", "omp", "plugins");
const cwd = join(root, "project", "nested");
const projectRoot = join(root, "project", ".omp", "plugins");
const lockPath = join(plugins, "omp-plugins.lock.json");
const name = "@example/native";
const runtime: OmpRuntime = {
	getAgentDir: () => agent,
	getPluginsDir: () => plugins,
	getProjectAgentDir: (dir) => join(dir, ".omp"),
	getProjectPluginOverridesPath: (dir) => join(dir, ".omp", "plugin-overrides.json"),
	resolveActiveProjectRegistryPath: async () => join(projectRoot, "installed_plugins.json"),
	YAML,
};
const ctx = { cwd, isProjectTrusted: () => true };

function write(path: string, content: string): void {
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, content);
}
function json(path: string, value: unknown): void { write(path, JSON.stringify(value)); }
function thrownFirstLine(fn: () => unknown): string {
	try { fn(); } catch (error) { return (error instanceof Error ? error.message : String(error)).split("\n")[0]!; }
	throw new Error("Expected the function to throw");
}
function nativePackage(rootDir = plugins, packageName = name, enabled = true, entrypoint = "./extensions/index.ts"): void {
	json(join(rootDir, "package.json"), { private: true, dependencies: { [packageName]: "^1.2.3" } });
	json(join(rootDir, "omp-plugins.lock.json"), { plugins: { [packageName]: { version: "1.2.3", enabled, enabledFeatures: null, custom: "keep" } }, settings: { [packageName]: { color: "blue" } }, unknown: 17 });
	const dir = join(rootDir, "node_modules", packageName);
	json(join(dir, "package.json"), { name: packageName, version: "1.2.3", pi: { extensions: [entrypoint] }, kendex: { extensionManager: { settings: [{ key: "glyphStyle", type: "enum", enumValues: ["unicode", "ascii"] }] } } });
	write(join(dir, entrypoint), "export default function () {}\n");
}
function inventory() { return buildInventory({} as never, ctx as never); }
async function selectOmp(): Promise<void> {
	await selectHost({ getAgentDir: runtime.getAgentDir, Settings: class {} }, async () => runtime);
	await host.prepare(cwd);
}

beforeEach(async () => {
	rmSync(root, { recursive: true, force: true });
	mkdirSync(cwd, { recursive: true });
	await selectOmp();
	clearPackageConfigCache();
});
afterEach(async () => {
	__setSpawnSyncForTests(undefined);
	await selectHost({ getAgentDir: piUserDir, SettingsManager: class {} }, async () => { throw new Error("not OMP"); });
	rmSync(root, { recursive: true, force: true });
	clearPackageConfigCache();
});

test("native disabled package without settings.json or YAML packages is inventoried and enabled in its lock", async () => {
	nativePackage(plugins, name, false);
	write(join(agent, "config.yml"), "compaction:\n  enabled: false\nunknown:\n  nested: preserved\n");
	const inv = await inventory();
	const item = inv.packages.find((pkg) => pkg.packageName === name);
	expect(item?.state).toBe("disabled");
	const before = readFileSync(join(agent, "config.yml"), "utf8");
	const notices: string[] = [];
	await toggleItem({} as never, { ...ctx, ui: { notify: (message: string) => notices.push(message) } } as never, inv, item!);
	const lock = JSON.parse(readFileSync(lockPath, "utf8"));
	expect(lock.plugins[name]).toEqual({ version: "1.2.3", enabled: true, enabledFeatures: null, custom: "keep" });
	expect(lock.settings[name]).toEqual({ color: "blue" });
	expect(lock.unknown).toBe(17);
	expect((await inventory()).packages[0]?.state).toBe("active");
	expect(readFileSync(join(agent, "config.yml"), "utf8")).toBe(before);
	for (const path of [join(agent, "settings.json"), join(cwd, ".omp", "settings.json"), join(cwd, ".pi", "settings.json"), join(root, "home", ".pi", "agent", "settings.json"), join(agent, "APPEND_SYSTEM.md")]) expect(existsSync(path)).toBe(false);
	expect(YAML.parse(before)).not.toHaveProperty("packages");
	expect(notices).toHaveLength(1);
});

test("runtime capabilities select the host with coexisting directories and use injected resolvers", async () => {
	json(join(root, "home", ".pi", "agent", "settings.json"), {});
	write(join(agent, "config.yaml"), "compaction:\n  enabled: false\n");
	expect(host.agentDir()).toBe(agent);
	expect(host.commands.manager).toBe("kendex:extensions");
	expect(host.commands.settings).toBe("kendex:extensions:settings");
	expect(host.commands.recover).toBe("kendex:extensions:enable");
	expect(host.settings(ctx).find((f) => f.scope === "project")?.baseDir).toBe(join(cwd, ".omp"));
	nativePackage(projectRoot);
	expect((await inventory()).packages[0]?.scope).toBe("project");
	const piAgent = join(root, "home", ".pi", "agent");
	await selectHost({ getAgentDir: () => piAgent, SettingsManager: class {} }, async () => { throw new Error("must not resolve OMP from disk"); });
	expect(host.agentDir()).toBe(piAgent);
	expect(host.commands.manager).toBe("extensions");
	expect(host.settings(ctx)[0]?.path).toBe(join(piAgent, "settings.json"));
	await expect(selectHost({ getAgentDir: () => piAgent }, async () => runtime)).rejects.toThrow("pi-extension-manager: host-api-missing=settings");
	await expect(selectHost({}, async () => runtime)).rejects.toThrow("pi-extension-manager: host-api-missing=getAgentDir");
});

test("config.yaml manager edits preserve nested and unknown data and feed glyph settings", async () => {
	nativePackage(plugins, MANAGER_ID);
	const path = join(agent, "config.yaml");
	write(path, "compaction:\n  enabled: false\nunknown:\n  nested: preserved\nkendex:\n  custom: 12\n");
	const inv = await inventory();
	setConfigValue(inv, inv.packages[0]!, { key: "glyphStyle", type: "enum" } as never, "ascii");
	const parsed = YAML.parse(readFileSync(path, "utf8"));
	expect(parsed).toMatchObject({ compaction: { enabled: false }, unknown: { nested: "preserved" }, kendex: { custom: 12 } });
	expect(glyphStyle(cwd)).toBe("ascii");
	for (const file of ["config.yml", "settings.json"]) expect(existsSync(join(agent, file))).toBe(false);
	expect(resetConfigKeys((await inventory()), MANAGER_ID, ["glyphStyle"])).toBe(1);
	expect(glyphStyle(cwd)).toBe("unicode");
});

test("malformed YAML, JSON and native records refuse without overwriting", async () => {
	nativePackage();
	const cases = [
		{ path: join(agent, "config.yml"), text: "compaction: [broken", firstLine: `pi-extension-manager: config-parse=${join(agent, "config.yml")}` },
		{ path: join(agent, "config.yml"), text: "- not-a-mapping", firstLine: `pi-extension-manager: object-required=${join(agent, "config.yml")}` },
		{ path: join(agent, "config.yml"), text: "kendex:\n  extensionManager:\n    config: invalid", firstLine: `pi-extension-manager: object-required=${join(agent, "config.yml")}: manager config` },
		{ path: lockPath, text: "{", firstLine: `pi-extension-manager: config-parse=${lockPath}` },
		{ path: lockPath, text: '{"plugins":{"@example/native":{"enabled":"false"}}}', firstLine: `pi-extension-manager: boolean-required=${lockPath}: @example/native.enabled` },
	];
	for (const { path, text, firstLine } of cases) {
		const original = existsSync(path) ? readFileSync(path, "utf8") : undefined;
		write(path, text);
		await expect(inventory()).rejects.toThrow(firstLine);
		expect(readFileSync(path, "utf8")).toBe(text);
		if (original === undefined) rmSync(path); else write(path, original);
	}
	const file = host.settings(ctx)[0]!;
	write(file.path, "kendex: [broken");
	expect(thrownFirstLine(() => updateManagerState(file, (state) => { state.config[MANAGER_ID] = { enabled: true }; }))).toBe(`pi-extension-manager: config-parse=${file.path}`);
	expect(readFileSync(file.path, "utf8")).toBe("kendex: [broken");
});

test("native capabilities refuse Pi update, uninstall, module toggles and other-extension settings", async () => {
	nativePackage();
	const inv = await inventory();
	const item = inv.packages[0]!;
	expect(planUninstall(item, inv, ctx as never)).toBeUndefined();
	expect(planUpdate({ ...item, updateAvailable: true, updateSource: "npm", npmName: name }, inv, ctx as never)).toBeUndefined();
	const update = runUpdate({ item } as never);
	const uninstall = runUninstall({ item } as never, inv);
	expect([update.ok, update.message.split("\n")[0]]).toEqual([false, `pi-extension-manager: update-unsupported=${item.id}`]);
	expect([uninstall.ok, uninstall.message.split("\n")[0]]).toEqual([false, `pi-extension-manager: uninstall-unsupported=${item.id}`]);
	expect(npmCandidatesFromInventory(inv)).toEqual([]);
	expect(item.settingsSchema).toEqual([]);
	const before = readFileSync(lockPath, "utf8");
	const module = inv.items.find((i) => i.kind === "extension module")!;
	expect(thrownFirstLine(() => host.toggle(module))).toBe(`pi-extension-manager: toggle-unsupported=${module.id}`);
	expect(thrownFirstLine(() => setConfigValue(inv, item, { key: "enabled" } as never, true))).toBe(`pi-extension-manager: settings-unsupported=${name}`);
	expect(thrownFirstLine(() => resetConfigKeys(inv, name, ["enabled"]))).toBe(`pi-extension-manager: settings-unsupported=${name}`);
	expect(readFileSync(lockPath, "utf8")).toBe(before);
	expect(existsSync(join(agent, "settings.json"))).toBe(false);
});

test("native inventory retains links and disabled project records without shadowing enabled user plugins", async () => {
	nativePackage();
	nativePackage(projectRoot, name, false);
	const linked = join(root, "linked");
	json(join(linked, "package.json"), { version: "2.0.0", omp: { extensions: ["index.ts"] }, pi: { extensions: ["wrong.ts"] } });
	symlinkSync(linked, join(plugins, "node_modules", "linked"), "dir");
	json(lockPath, { plugins: { linked: { version: "2.0.0", enabled: false, enabledFeatures: null }, stale: { enabled: true } } });
	json(join(plugins, "node_modules", "stale", "package.json"), { pi: { extensions: ["index.ts"] } });
	const inv = await inventory();
	expect(inv.packages.find((i) => i.packageName === name && i.scope === "user")?.state).toBe("active");
	expect(inv.packages.find((i) => i.packageName === name && i.scope === "project")?.state).toBe("disabled");
	expect(inv.packages.find((i) => i.packageName === "linked")?.state).toBe("disabled");
	expect(inv.packages.find((i) => i.packageName === "stale")).toBeUndefined();
	expect(inv.items.find((i) => i.packageName === "linked" && i.kind === "extension module")?.entrypoint).toBe("index.ts");
	host.toggle(inv.packages.find((i) => i.packageName === name && i.scope === "project")!);
	expect((await inventory()).packages.find((i) => i.packageName === name && i.scope === "user")?.state).toBe("shadowed");
	expect((await inventory()).packages.find((i) => i.packageName === name && i.scope === "project")?.state).toBe("active");
});

test("project JSON and YAML layers retain raw ownership and YAML manager overrides win", async () => {
	nativePackage(projectRoot, MANAGER_ID);
	const jsonPath = join(cwd, ".omp", "settings.json");
	const yamlPath = join(cwd, ".omp", "config.yml");
	json(jsonPath, { unknown: "json", kendex: { extensionManager: { config: { [MANAGER_ID]: { glyphStyle: "unicode", defaultSaveScope: "user" } } } } });
	write(yamlPath, `unknown: yaml\nkendex:\n  extensionManager:\n    config:\n      '${MANAGER_ID}':\n        glyphStyle: ascii\n`);
	const inv = await inventory();
	expect(getConfigValue(inv, MANAGER_ID, { key: "glyphStyle" } as never).value).toBe("ascii");
	expect(getConfigValue(inv, MANAGER_ID, { key: "defaultSaveScope" } as never).value).toBe("user");
	const before = readFileSync(jsonPath, "utf8");
	setConfigValue(inv, inv.packages[0]!, { key: "glyphStyle" } as never, "unicode");
	expect(readFileSync(jsonPath, "utf8")).toBe(before);
	expect(YAML.parse(readFileSync(yamlPath, "utf8"))).toMatchObject({ unknown: "yaml" });
	expect(getConfigValue((await inventory()), MANAGER_ID, { key: "glyphStyle" } as never).value).toBe("unicode");
});

test("project-native manager enabled uses global display, save and reset ownership", async () => {
	nativePackage(projectRoot, MANAGER_ID);
	const manifest = JSON.parse(readFileSync(join(import.meta.dir, "..", "package.json"), "utf8"));
	json(join(projectRoot, "node_modules", MANAGER_ID, "package.json"), manifest);
	const userPath = join(agent, "config.yaml");
	const projectPath = join(cwd, ".omp", "config.yml");
	const config = (values: Record<string, unknown>) => ({ unknown: "keep", kendex: { extensionManager: { config: { [MANAGER_ID]: values } } } });
	write(userPath, YAML.stringify(config({ enabled: true })));
	write(projectPath, YAML.stringify(config({ glyphStyle: "ascii" })));
	const projectBefore = readFileSync(projectPath, "utf8");
	const item = (await inventory()).packages.find((pkg) => pkg.packageName === MANAGER_ID)!;
	expect(item.scope).toBe("project");
	const schema = item.settingsSchema!.find((setting) => setting.key === "enabled")!;
	const bootstrapEnabled = () => mergedManagerState(host.settings({ cwd })).config[MANAGER_ID]?.enabled !== false;
	for (const enabled of [false, true]) {
		setConfigValue((await inventory()), item, schema, enabled);
		expect(host.read(userPath)).toMatchObject(config({ enabled }));
		expect(getConfigValue((await inventory()), MANAGER_ID, schema)).toMatchObject({ scope: "user", value: enabled });
		expect(bootstrapEnabled()).toBe(enabled);
		expect(readFileSync(projectPath, "utf8")).toBe(projectBefore);
	}
	write(projectPath, YAML.stringify(config({ enabled: false, glyphStyle: "ascii" })));
	expect(getConfigValue((await inventory()), MANAGER_ID, schema).value).toBe(true);
	expect((await inventory()).managerState.config[MANAGER_ID]?.enabled).toBe(true);
	expect(resetConfigKeys((await inventory()), MANAGER_ID, ["enabled", "glyphStyle"])).toBe(2);
	expect(host.read(projectPath)).toMatchObject(config({ enabled: false }));
	expect((await inventory()).managerState.config[MANAGER_ID]?.glyphStyle).toBeUndefined();
	expect(getConfigValue((await inventory()), MANAGER_ID, schema)).toMatchObject({ scope: "default", value: true });
	expect((await inventory()).managerState.config[MANAGER_ID]?.enabled).toBeUndefined();
	expect(bootstrapEnabled()).toBe(true);
});

const installations = [
	{ user: true, project: false, active: "user" },
	{ user: false, project: true, active: "project" },
	{ user: true, project: true, active: "project" },
] as const;

type PopupComponent = { handleInput(input: string): void; render(width: number): string[] };
async function popup(open: typeof openManager, search = ""): Promise<string> {
	let output = "";
	const theme = { fg: (_color: string, text: string) => text, bg: (_color: string, text: string) => text, bold: (text: string) => text, inverse: (text: string) => text };
	await open({} as never, { ...ctx, ui: {
		custom: async (factory: (...args: unknown[]) => PopupComponent) => {
			const component = factory({ terminal: { rows: 60 }, requestRender() {} }, theme, {}, () => {});
			for (const character of search) component.handleInput(character);
			output = component.render(180).join("\n");
			return { type: "close" };
		},
		notify(message: string) { throw new Error(message); },
	} } as never);
	return output;
}

test("manager and quick-settings notices expose stable keys and values", async () => {
	const emptyNotices: string[] = [];
	await openQuickSettings({} as never, { ...ctx, ui: {
		notify: (message: string) => emptyNotices.push(message.split("\n")[0]!),
	} } as never);
	expect(emptyNotices).toEqual(["pi-extension-manager: settings-packages=0"]);

	nativePackage(plugins, MANAGER_ID);
	const item = (await inventory()).packages[0]!;
	for (const row of [
		{ action: { type: "update-package", itemId: item.id }, firstLine: `pi-extension-manager: update-unsupported=${item.id}` },
		{ action: { type: "uninstall-package", itemId: item.id }, firstLine: `pi-extension-manager: self-uninstall=${MANAGER_ID}` },
	] as const) {
		const notices: string[] = [];
		let first = true;
		await openManager({} as never, { ...ctx, ui: {
			custom: async () => first ? (first = false, row.action) : { type: "close" },
			notify: (message: string) => notices.push(message.split("\n")[0]!),
		} } as never);
		expect(notices).toEqual([row.firstLine]);
	}

	const notices: string[] = [];
	await openQuickSettings({} as never, { ...ctx, ui: {
		custom: async () => ({ type: "close" }),
		notify: (message: string) => notices.push(message.split("\n")[0]!),
	} } as never, "missing-tab");
	expect(notices).toEqual(["pi-extension-manager: settings-tab-missing=missing-tab"]);
});

for (const row of installations) {
	test(`native installation grouping user=${row.user} project=${row.project}`, async () => {
		nativePackage(plugins, MANAGER_ID, row.user, "./useronly.ts");
		nativePackage(projectRoot, MANAGER_ID, row.project, "./projectonly.ts");
		const inv = await inventory();
		const ui = { search: "", scopeFilter: "all", stateFilter: "active" } as ManagerUiState;
		const visible = filteredItems(inv.items, ui);
		expect(visible.map((item) => item.scope)).toEqual([row.active]);
		expect(filteredItems(inv.items, { ...ui, selected: 1 })).toBe(visible);
		for (const scope of ["user", "project"] as const) {
			expect(filteredItems(inv.items, { ...ui, scopeFilter: scope }).map((item) => item.scope)).toEqual(scope === row.active ? [scope] : []);
			expect(filteredItems(inv.items, { ...ui, stateFilter: "all", search: `${scope}only` }).map((item) => item.scope)).toEqual([scope]);
			const rendered = await popup(openManager, `${scope}only`);
			expect(rendered).toContain(`${scope}only.ts`);
			expect(rendered).not.toContain(`${scope === "user" ? "project" : "user"}only.ts`);
		}
	});

	test(`native manager settings belong to active installation user=${row.user} project=${row.project}`, async () => {
		nativePackage(plugins, MANAGER_ID, row.user);
		nativePackage(projectRoot, MANAGER_ID, row.project);
		expect((await popup(openQuickSettings)).match(/glyphStyle/g)).toHaveLength(1);
		expect((await inventory()).packages.filter((item) => item.settingsSchema?.length).map((item) => item.scope)).toEqual([row.active]);
	});
}

test("trusted native project settings are creatable without redirecting global-only enable", async () => {
	nativePackage(projectRoot, MANAGER_ID);
	const userPath = join(agent, "config.yml");
	write(userPath, "unknown: keep\n");
	const before = readFileSync(userPath, "utf8");
	const inv = await inventory();
	const file = inv.settingsFiles.find((candidate) => candidate.scope === "project")!;
	expect(file.exists).toBe(false);
	const item = inv.packages[0]!;
	setConfigValue(inv, item, item.settingsSchema![0]!, "ascii");
	expect(readFileSync(userPath, "utf8")).toBe(before);
	expect(file.path).toBe(join(cwd, ".omp", "config.yml"));
	expect(host.read(file.path)).toMatchObject({ kendex: { extensionManager: { config: { [MANAGER_ID]: { glyphStyle: "ascii" } } } } });
	const projectBefore = readFileSync(file.path, "utf8");
	setConfigValue((await inventory()), item, { key: "enabled", type: "boolean", default: true }, false);
	expect(readFileSync(file.path, "utf8")).toBe(projectBefore);
	expect(getConfigValue((await inventory()), MANAGER_ID, { key: "enabled", type: "boolean" })).toMatchObject({ scope: "user", value: false });
});

for (const row of [
	{ kind: "omp", trusted: true, exists: false, writable: true },
	{ kind: "omp", trusted: false, exists: false, writable: false },
	{ kind: "pi", trusted: true, exists: false, writable: false },
	{ kind: "pi", trusted: true, exists: true, writable: true },
	{ kind: "pi", trusted: false, exists: true, writable: false },
]) {
	test(`project write capability ${JSON.stringify(row)}`, async () => {
		mkdirSync(join(cwd, ".pi"), { recursive: true });
		if (row.kind === "pi") await selectHost({ getAgentDir: () => agent, SettingsManager: class {} }, async () => runtime);
		if (row.exists) write(host.settingsPath("project", cwd), "{}");
		const files = host.settings({ cwd, isProjectTrusted: () => row.trusted });
		expect(defaultWriteScope(undefined, files, { config: {}, disabledItems: [] })).toBe(row.writable ? "project" : "user");
	});
}

test("native module suppression shows basename collisions without offering package-specific toggles", async () => {
	nativePackage();
	nativePackage(projectRoot, "@example/other");
	write(join(agent, "config.yml"), "disabledExtensions:\n  - extension-module:extensions\n");
	const modules = (await inventory()).items.filter((item) => item.kind === "extension module");
	expect(modules).toHaveLength(2);
	for (const item of modules) {
		expect(item.state).toBe("disabled");
		expect(thrownFirstLine(() => host.toggle(item))).toBe(`pi-extension-manager: toggle-unsupported=${item.id}`);
	}
});

test("configured native extensions use cwd and project arrays replace user arrays", async () => {
	write(join(agent, "config.yml"), "extensions:\n  - ./user.ts\n");
	write(join(cwd, ".omp", "config.yml"), "extensions:\n  - ./project.ts\n");
	const configured = (await inventory()).items.filter((item) => item.kind === "extension setting");
	expect(configured.map((item) => item.sourcePath)).toEqual([join(cwd, "project.ts")]);
});

test("Pi retains root-anchored override policy when the runtime returns a relative directory", async () => {
	const previous = process.env.PI_CODING_AGENT_DIR;
	try {
		process.env.PI_CODING_AGENT_DIR = "relative";
		clearPackageConfigCache();
		await selectHost({ getAgentDir: () => "relative", SettingsManager: class {} }, async () => runtime);
		expect(host.agentDir()).toBe(piUserDir());
	} finally {
		if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR; else process.env.PI_CODING_AGENT_DIR = previous;
		clearPackageConfigCache();
	}
});

test("native project suppression is visible and refuses a misleading global enable", async () => {
	nativePackage();
	const path = runtime.getProjectPluginOverridesPath(cwd);
	json(path, { disabled: [name], settings: { [name]: { color: "red" } } });
	const item = (await inventory()).packages[0]!;
	expect(item.state).toBe("disabled");
	const before = readFileSync(path, "utf8");
	expect(thrownFirstLine(() => host.toggle(item))).toBe(`pi-extension-manager: plugin-override=${path}`);
	expect(readFileSync(path, "utf8")).toBe(before);
});

test("Pi popup actions address the selected user install when both scopes are visible", async () => {
	await selectHost({ getAgentDir: () => agent, SettingsManager: class {} }, async () => { throw new Error("not OMP"); });
	const projectPi = join(cwd, ".pi");
	const source = "npm:@example/duplicate";
	for (const base of [agent, projectPi]) {
		json(join(base, "settings.json"), { packages: [source] });
		json(join(base, "npm", "node_modules", "@example", "duplicate", "package.json"), { name: "@example/duplicate", version: "1.0.0", pi: { extensions: ["index.ts"] } });
	}
	const calls: Array<{ command: string; args: string[]; cwd?: string }> = [];
	const pi = {} as never;
	__setSpawnSyncForTests(((command: string, args: string[], options: { cwd?: string }) => {
		calls.push({ command, args, cwd: options?.cwd });
		return { status: 0, signal: null, stdout: "", stderr: "", output: [], pid: 0 };
	}) as never);
	const inv = await refreshInventory(pi, ctx as never);
	const user = inv.packages.find((item) => item.scope === "user")!;
	const project = inv.packages.find((item) => item.scope === "project")!;
	expect(user.id).not.toBe(project.id);
	expect(user.id).toBe("package:user:npm:@example/duplicate:@example/duplicate");
	expect(project.id).toBe("package:project:npm:@example/duplicate:@example/duplicate");
	for (const type of ["toggle-item", "update-package", "uninstall-package"] as const) {
		let selected = false;
		await openManager(pi, { ...ctx, ui: {
			custom: async () => {
				if (selected) return { type: "close" };
				selected = true;
				const current = inventorySession(pi).inventory!;
				const target = current.packages.find((item) => item.scope === "user")!;
				if (type === "update-package") Object.assign(target, { updateAvailable: true, updateSource: "npm", npmName: "@example/duplicate" });
				return { type, itemId: target.id };
			},
			confirm: async () => true,
			notify: (message: string, kind: string) => { if (kind === "error") throw new Error(message); },
		} } as never);
		const projectSettings = JSON.parse(readFileSync(join(projectPi, "settings.json"), "utf8"));
		expect(projectSettings.packages).toEqual([source]);
	}
	expect(calls).toEqual([
		{ command: "npm", args: ["install", "@example/duplicate@latest"], cwd: join(agent, "npm") },
		{ command: "npm", args: ["uninstall", "@example/duplicate"], cwd: join(agent, "npm") },
	]);
	expect(JSON.parse(readFileSync(join(agent, "settings.json"), "utf8")).packages).toBeUndefined();
	closeInventorySession(pi);
});

test("completion labels reuse the session inventory until a refresh boundary", async () => {
	nativePackage(plugins, MANAGER_ID);
	const pi = {} as never;
	await refreshInventory(pi, ctx as never);
	const first = quickSettingsCompletions(pi, "");
	expect(first?.map((item) => item.value)).toEqual([MANAGER_ID]);
	rmSync(join(plugins, "node_modules", MANAGER_ID, "package.json"));
	for (let i = 0; i < 20; i++) expect(quickSettingsCompletions(pi, "")).toBe(first);
	await refreshInventory(pi, ctx as never);
	expect(quickSettingsCompletions(pi, "")).toBeNull();
	closeInventorySession(pi);
	expect(quickSettingsCompletions(pi, "")).toBeNull();
});

test("closing the package popup cancels its pending npm response", async () => {
	const copy = join(root, "popup-runtime");
	cpSync(join(import.meta.dir, "../extensions/manager"), copy, { recursive: true });
	const versionPath = join(copy, "versions.ts");
	const versionSource = readFileSync(versionPath, "utf8");
	const before = 'from "node:https"';
	expect(versionSource.split(before).length - 1).toBe(1);
	writeFileSync(versionPath, versionSource.replace(before, `from ${JSON.stringify(join(import.meta.dir, "fixtures/http.ts"))}`));
	const copiedHost = await import(join(copy, "host.ts"));
	await copiedHost.selectHost({ getAgentDir: () => agent, SettingsManager: class {} }, async () => { throw new Error("not OMP"); });
	json(join(agent, "settings.json"), { packages: ["npm:@example/popup-cancel"] });
	json(join(agent, "npm/node_modules/@example/popup-cancel/package.json"), { name: "@example/popup-cancel", version: "1.0.0" });
	const { openManager: open } = await import(join(copy, "manager-ui.ts"));
	const theme = { fg: (_color: string, text: string) => text, bg: (_color: string, text: string) => text, bold: (text: string) => text, inverse: (text: string) => text };
	await open({} as never, { ...ctx, ui: {
		custom: async (factory: (...args: unknown[]) => PopupComponent) => {
			factory({ terminal: { rows: 60 }, requestRender() { throw new Error("Closed popup must not redraw"); } }, theme, {}, () => {});
			expect(pendingRequest().destroyedCount).toBe(0);
			return { type: "close" };
		},
		notify(message: string) { throw new Error(message); },
	} } as never);
	expect(pendingRequest().destroyedCount).toBe(1);
});
