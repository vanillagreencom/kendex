import { afterEach, beforeEach, expect, test } from "bun:test";
import { YAML } from "bun";
import { existsSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { host, selectHost, type OmpRuntime } from "../extensions/manager/host.ts";
import { buildInventory, npmCandidatesFromInventory } from "../extensions/manager/inventory.ts";
import { planUninstall, planUpdate, runUninstall, runUpdate, toggleItem } from "../extensions/manager/actions.ts";
import { setConfigValue, resetConfigKeys, updateManagerState, getConfigValue, mergedManagerState } from "../extensions/manager/settings.ts";
import { glyphStyle } from "../extensions/manager/glyphs.ts";
import { userPiDir } from "../extensions/manager/paths.ts";
import { MANAGER_ID } from "../extensions/manager/types.ts";

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
function nativePackage(rootDir = plugins, packageName = name, enabled = true): void {
	json(join(rootDir, "package.json"), { private: true, dependencies: { [packageName]: "^1.2.3" } });
	json(join(rootDir, "omp-plugins.lock.json"), { plugins: { [packageName]: { version: "1.2.3", enabled, enabledFeatures: null, custom: "keep" } }, settings: { [packageName]: { color: "blue" } }, unknown: 17 });
	const dir = join(rootDir, "node_modules", packageName);
	json(join(dir, "package.json"), { name: packageName, version: "1.2.3", pi: { extensions: ["./extensions/index.ts"] }, kendex: { extensionManager: { settings: [{ key: "glyphStyle", type: "enum", enumValues: ["unicode", "ascii"] }] } } });
	write(join(dir, "extensions", "index.ts"), "export default function () {}\n");
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
});
afterEach(async () => {
	await selectHost({ getAgentDir: userPiDir, SettingsManager: class {} }, async () => { throw new Error("not OMP"); });
	rmSync(root, { recursive: true, force: true });
});

test("native disabled package without settings.json or YAML packages is inventoried and enabled in its lock", () => {
	nativePackage(plugins, name, false);
	write(join(agent, "config.yml"), "compaction:\n  enabled: false\nunknown:\n  nested: preserved\n");
	const inv = inventory();
	const item = inv.packages.find((pkg) => pkg.packageName === name);
	expect(item?.state).toBe("disabled");
	const before = readFileSync(join(agent, "config.yml"), "utf8");
	const notices: string[] = [];
	toggleItem({} as never, { ...ctx, ui: { notify: (message: string) => notices.push(message) } } as never, inv, item!);
	const lock = JSON.parse(readFileSync(lockPath, "utf8"));
	expect(lock.plugins[name]).toEqual({ version: "1.2.3", enabled: true, enabledFeatures: null, custom: "keep" });
	expect(lock.settings[name]).toEqual({ color: "blue" });
	expect(lock.unknown).toBe(17);
	expect(inventory().packages[0]?.state).toBe("active");
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
	expect(inventory().packages[0]?.scope).toBe("project");
	const piAgent = join(root, "home", ".pi", "agent");
	await selectHost({ getAgentDir: () => piAgent, SettingsManager: class {} }, async () => { throw new Error("must not resolve OMP from disk"); });
	expect(host.agentDir()).toBe(piAgent);
	expect(host.commands.manager).toBe("extensions");
	expect(host.settings(ctx)[0]?.path).toBe(join(piAgent, "settings.json"));
	await expect(selectHost({ getAgentDir: () => piAgent }, async () => runtime)).rejects.toThrow();
});

test("config.yaml manager edits preserve nested and unknown data and feed glyph settings", () => {
	nativePackage(plugins, MANAGER_ID);
	const path = join(agent, "config.yaml");
	write(path, "compaction:\n  enabled: false\nunknown:\n  nested: preserved\nkendex:\n  custom: 12\n");
	const inv = inventory();
	setConfigValue(inv, inv.packages[0]!, { key: "glyphStyle", type: "enum" } as never, "ascii");
	const parsed = YAML.parse(readFileSync(path, "utf8"));
	expect(parsed).toMatchObject({ compaction: { enabled: false }, unknown: { nested: "preserved" }, kendex: { custom: 12 } });
	expect(glyphStyle(cwd)).toBe("ascii");
	for (const file of ["config.yml", "settings.json"]) expect(existsSync(join(agent, file))).toBe(false);
	expect(resetConfigKeys(inventory(), MANAGER_ID, ["glyphStyle"])).toBe(1);
	expect(glyphStyle(cwd)).toBe("unicode");
});

test("malformed YAML, JSON and native records refuse without overwriting", () => {
	nativePackage();
	const cases = [
		{ path: join(agent, "config.yml"), text: "compaction: [broken" },
		{ path: join(agent, "config.yml"), text: "- not-a-mapping" },
		{ path: join(agent, "config.yml"), text: "kendex:\n  extensionManager:\n    config: invalid" },
		{ path: lockPath, text: "{" },
		{ path: lockPath, text: '{"plugins":{"@example/native":{"enabled":"false"}}}' },
	];
	for (const { path, text } of cases) {
		const original = existsSync(path) ? readFileSync(path, "utf8") : undefined;
		write(path, text);
		expect(() => inventory()).toThrow();
		expect(readFileSync(path, "utf8")).toBe(text);
		if (original === undefined) rmSync(path); else write(path, original);
	}
	const file = host.settings(ctx)[0]!;
	write(file.path, "kendex: [broken");
	expect(() => updateManagerState(file, (state) => { state.config[MANAGER_ID] = { enabled: true }; })).toThrow();
	expect(readFileSync(file.path, "utf8")).toBe("kendex: [broken");
});

test("native capabilities refuse Pi update, uninstall, module toggles and other-extension settings", () => {
	nativePackage();
	const inv = inventory();
	const item = inv.packages[0]!;
	expect(planUninstall(item, inv, ctx as never)).toBeUndefined();
	expect(planUpdate({ ...item, updateAvailable: true, updateSource: "npm", npmName: name }, inv, ctx as never)).toBeUndefined();
	expect(runUpdate({ item } as never).ok).toBe(false);
	expect(runUninstall({ item } as never, inv).ok).toBe(false);
	expect(npmCandidatesFromInventory(inv)).toEqual([]);
	expect(item.settingsSchema).toEqual([]);
	const before = readFileSync(lockPath, "utf8");
	expect(() => host.toggle(inv.items.find((i) => i.kind === "extension module")!)).toThrow();
	expect(() => setConfigValue(inv, item, { key: "enabled" } as never, true)).toThrow();
	expect(() => resetConfigKeys(inv, name, ["enabled"])).toThrow();
	expect(readFileSync(lockPath, "utf8")).toBe(before);
	expect(existsSync(join(agent, "settings.json"))).toBe(false);
});

test("native inventory retains links and disabled project records without shadowing enabled user plugins", () => {
	nativePackage();
	nativePackage(projectRoot, name, false);
	const linked = join(root, "linked");
	json(join(linked, "package.json"), { version: "2.0.0", omp: { extensions: ["index.ts"] }, pi: { extensions: ["wrong.ts"] } });
	symlinkSync(linked, join(plugins, "node_modules", "linked"), "dir");
	json(lockPath, { plugins: { linked: { version: "2.0.0", enabled: false, enabledFeatures: null }, stale: { enabled: true } } });
	json(join(plugins, "node_modules", "stale", "package.json"), { pi: { extensions: ["index.ts"] } });
	const inv = inventory();
	expect(inv.packages.find((i) => i.packageName === name && i.scope === "user")?.state).toBe("active");
	expect(inv.packages.find((i) => i.packageName === name && i.scope === "project")?.state).toBe("disabled");
	expect(inv.packages.find((i) => i.packageName === "linked")?.state).toBe("disabled");
	expect(inv.packages.find((i) => i.packageName === "stale")).toBeUndefined();
	expect(inv.items.find((i) => i.packageName === "linked" && i.kind === "extension module")?.entrypoint).toBe("index.ts");
	host.toggle(inv.packages.find((i) => i.packageName === name && i.scope === "project")!);
	expect(inventory().packages.find((i) => i.packageName === name && i.scope === "user")?.state).toBe("shadowed");
	expect(inventory().packages.find((i) => i.packageName === name && i.scope === "project")?.state).toBe("active");
});

test("project JSON and YAML layers retain raw ownership and YAML manager overrides win", () => {
	nativePackage(projectRoot, MANAGER_ID);
	const jsonPath = join(cwd, ".omp", "settings.json");
	const yamlPath = join(cwd, ".omp", "config.yml");
	json(jsonPath, { unknown: "json", kendex: { extensionManager: { config: { [MANAGER_ID]: { glyphStyle: "unicode", defaultSaveScope: "user" } } } } });
	write(yamlPath, `unknown: yaml\nkendex:\n  extensionManager:\n    config:\n      '${MANAGER_ID}':\n        glyphStyle: ascii\n`);
	const inv = inventory();
	expect(getConfigValue(inv, MANAGER_ID, { key: "glyphStyle" } as never).value).toBe("ascii");
	expect(getConfigValue(inv, MANAGER_ID, { key: "defaultSaveScope" } as never).value).toBe("user");
	const before = readFileSync(jsonPath, "utf8");
	setConfigValue(inv, inv.packages[0]!, { key: "glyphStyle" } as never, "unicode");
	expect(readFileSync(jsonPath, "utf8")).toBe(before);
	expect(YAML.parse(readFileSync(yamlPath, "utf8"))).toMatchObject({ unknown: "yaml" });
	expect(getConfigValue(inventory(), MANAGER_ID, { key: "glyphStyle" } as never).value).toBe("unicode");
});

test("project-native manager enabled uses global display, save and reset ownership", () => {
	nativePackage(projectRoot, MANAGER_ID);
	const manifest = JSON.parse(readFileSync(join(import.meta.dir, "..", "package.json"), "utf8"));
	json(join(projectRoot, "node_modules", MANAGER_ID, "package.json"), manifest);
	const userPath = join(agent, "config.yaml");
	const projectPath = join(cwd, ".omp", "config.yml");
	const config = (values: Record<string, unknown>) => ({ unknown: "keep", kendex: { extensionManager: { config: { [MANAGER_ID]: values } } } });
	write(userPath, YAML.stringify(config({ enabled: true })));
	write(projectPath, YAML.stringify(config({ glyphStyle: "ascii" })));
	const projectBefore = readFileSync(projectPath, "utf8");
	const item = inventory().packages.find((pkg) => pkg.packageName === MANAGER_ID)!;
	expect(item.scope).toBe("project");
	const schema = item.settingsSchema!.find((setting) => setting.key === "enabled")!;
	const bootstrapEnabled = () => mergedManagerState(host.settings({ cwd })).config[MANAGER_ID]?.enabled !== false;
	for (const enabled of [false, true]) {
		setConfigValue(inventory(), item, schema, enabled);
		expect(host.read(userPath)).toMatchObject(config({ enabled }));
		expect(getConfigValue(inventory(), MANAGER_ID, schema)).toMatchObject({ scope: "user", value: enabled });
		expect(bootstrapEnabled()).toBe(enabled);
		expect(readFileSync(projectPath, "utf8")).toBe(projectBefore);
	}
	write(projectPath, YAML.stringify(config({ enabled: false, glyphStyle: "ascii" })));
	expect(getConfigValue(inventory(), MANAGER_ID, schema).value).toBe(true);
	expect(inventory().managerState.config[MANAGER_ID]?.enabled).toBe(true);
	expect(resetConfigKeys(inventory(), MANAGER_ID, ["enabled", "glyphStyle"])).toBe(2);
	expect(host.read(projectPath)).toMatchObject(config({ enabled: false }));
	expect(inventory().managerState.config[MANAGER_ID]?.glyphStyle).toBeUndefined();
	expect(getConfigValue(inventory(), MANAGER_ID, schema)).toMatchObject({ scope: "default", value: true });
	expect(inventory().managerState.config[MANAGER_ID]?.enabled).toBeUndefined();
	expect(bootstrapEnabled()).toBe(true);
});

test("native module suppression shows basename collisions without offering package-specific toggles", () => {
	nativePackage();
	nativePackage(projectRoot, "@example/other");
	write(join(agent, "config.yml"), "disabledExtensions:\n  - extension-module:extensions\n");
	const modules = inventory().items.filter((item) => item.kind === "extension module");
	expect(modules).toHaveLength(2);
	for (const item of modules) {
		expect(item.state).toBe("disabled");
		expect(() => host.toggle(item)).toThrow();
	}
});

test("configured native extensions use cwd and project arrays replace user arrays", () => {
	write(join(agent, "config.yml"), "extensions:\n  - ./user.ts\n");
	write(join(cwd, ".omp", "config.yml"), "extensions:\n  - ./project.ts\n");
	const configured = inventory().items.filter((item) => item.kind === "extension setting");
	expect(configured.map((item) => item.sourcePath)).toEqual([join(cwd, "project.ts")]);
});

test("Pi retains root-anchored override policy when the runtime returns a relative directory", async () => {
	const previous = process.env.PI_CODING_AGENT_DIR;
	try {
		process.env.PI_CODING_AGENT_DIR = "relative";
		await selectHost({ getAgentDir: () => "relative", SettingsManager: class {} }, async () => runtime);
		expect(host.agentDir()).toBe(userPiDir());
	} finally {
		if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR; else process.env.PI_CODING_AGENT_DIR = previous;
	}
});

test("native project suppression is visible and refuses a misleading global enable", () => {
	nativePackage();
	const path = runtime.getProjectPluginOverridesPath(cwd);
	json(path, { disabled: [name], settings: { [name]: { color: "red" } } });
	const item = inventory().packages[0]!;
	expect(item.state).toBe("disabled");
	const before = readFileSync(path, "utf8");
	expect(() => host.toggle(item)).toThrow();
	expect(readFileSync(path, "utf8")).toBe(before);
});
