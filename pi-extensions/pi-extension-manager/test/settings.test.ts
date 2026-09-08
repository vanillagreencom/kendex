import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { buildInventory } from "../extensions/manager/inventory.ts";
import { applyMessage, managerFailure, managerNotice, parseSettingInput } from "../extensions/manager/format.ts";
import { getConfigValue, getOrCreateRecord } from "../extensions/manager/settings.ts";
import { EXTERNAL_CONFIG_RESOLVER_SYMBOL, type ExternalConfigResolver, type SettingsSchema } from "../extensions/manager/types.ts";

const rootTmp = join(process.cwd(), "tmp", "pi-extension-manager-settings-tests");
const PACKAGE_ID = "@scope/external-settings";
const SCHEMA: SettingsSchema = { default: true, key: "enabled", label: "Enabled", type: "boolean" };

const originalEnv = {
	HOME: process.env.HOME,
	NPM_CONFIG_PREFIX: process.env.NPM_CONFIG_PREFIX,
	npm_config_prefix: process.env.npm_config_prefix,
	PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR,
};

function writeJson(path: string, value: unknown): void {
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function writePackage(dir: string, name: string): void {
	mkdirSync(join(dir, "extensions"), { recursive: true });
	writeFileSync(join(dir, "extensions", "index.ts"), "export default function () {}\n", "utf8");
	writeJson(join(dir, "package.json"), {
		name,
		version: "1.0.0",
		pi: { extensions: ["./extensions/index.ts"] },
		kendex: { extensionManager: { displayName: "External Settings", settings: [SCHEMA] } },
	});
}

function registerResolver(resolver: ExternalConfigResolver, extensionId = PACKAGE_ID): void {
	const host = globalThis as unknown as Record<PropertyKey, Record<string, ExternalConfigResolver>>;
	host[EXTERNAL_CONFIG_RESOLVER_SYMBOL] = { ...(host[EXTERNAL_CONFIG_RESOLVER_SYMBOL] ?? {}), [extensionId]: resolver };
}

function setupProject(managerConfig?: { scope: "project" | "user"; value: unknown }): string {
	const project = join(rootTmp, "project");
	const projectPi = join(project, ".pi");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	writePackage(join(userPi, "npm", "node_modules", ...PACKAGE_ID.split("/")), PACKAGE_ID);
	const config = managerConfig ? { kendex: { extensionManager: { config: { [PACKAGE_ID]: { enabled: managerConfig.value } } } } } : {};
	writeJson(join(userPi, "settings.json"), { packages: [`npm:${PACKAGE_ID}`], ...(managerConfig?.scope === "user" ? config : {}) });
	writeJson(join(projectPi, "settings.json"), managerConfig?.scope === "project" ? config : {});
	return project;
}

function inventory(cwd: string) {
	return buildInventory({} as never, { cwd, isProjectTrusted: () => true } as never);
}

beforeEach(() => {
	rmSync(rootTmp, { force: true, recursive: true });
	mkdirSync(rootTmp, { recursive: true });
	process.env.HOME = join(rootTmp, "home");
	process.env.NPM_CONFIG_PREFIX = join(rootTmp, "npm-prefix");
	process.env.npm_config_prefix = process.env.NPM_CONFIG_PREFIX;
	process.env.PI_CODING_AGENT_DIR = join(rootTmp, "home", ".pi", "agent");
	delete (globalThis as unknown as Record<PropertyKey, unknown>)[EXTERNAL_CONFIG_RESOLVER_SYMBOL];
});

afterEach(() => {
	delete (globalThis as unknown as Record<PropertyKey, unknown>)[EXTERNAL_CONFIG_RESOLVER_SYMBOL];
	if (originalEnv.HOME === undefined) delete process.env.HOME;
	else process.env.HOME = originalEnv.HOME;
	if (originalEnv.NPM_CONFIG_PREFIX === undefined) delete process.env.NPM_CONFIG_PREFIX;
	else process.env.NPM_CONFIG_PREFIX = originalEnv.NPM_CONFIG_PREFIX;
	if (originalEnv.npm_config_prefix === undefined) delete process.env.npm_config_prefix;
	else process.env.npm_config_prefix = originalEnv.npm_config_prefix;
	if (originalEnv.PI_CODING_AGENT_DIR === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = originalEnv.PI_CODING_AGENT_DIR;
	rmSync(rootTmp, { force: true, recursive: true });
});

test("a registered resolver supplies the value when no manager scope holds the key", () => {
	const project = setupProject();
	const seen: Array<[string, string]> = [];
	registerResolver((key, cwd) => {
		seen.push([key, cwd]);
		return { explicit: true, source: "~/.pi/agent/external.json", value: false };
	});

	const config = getConfigValue(inventory(project), PACKAGE_ID, SCHEMA);
	expect(config).toEqual({ explicit: true, scope: "external", source: "~/.pi/agent/external.json", value: false });
	expect(seen).toEqual([["enabled", project]]);
});

test("manager scopes outrank a registered resolver", () => {
	for (const scope of ["project", "user"] as const) {
		const project = setupProject({ scope, value: true });
		registerResolver(() => ({ explicit: true, source: "~/.pi/agent/external.json", value: false }));
		expect(getConfigValue(inventory(project), PACKAGE_ID, SCHEMA)).toEqual({ explicit: true, scope, value: true });
	}
});

test("a resolver without an explicit value falls back to the schema default", () => {
	const project = setupProject();
	for (const resolution of [undefined, { explicit: false, value: false }]) {
		registerResolver(() => resolution);
		expect(getConfigValue(inventory(project), PACKAGE_ID, SCHEMA)).toEqual({ explicit: false, scope: "default", value: true });
	}
});

test("a throwing resolver falls back to the schema default instead of breaking the modal", () => {
	const project = setupProject();
	registerResolver(() => {
		throw new Error("resolver exploded");
	});

	expect(getConfigValue(inventory(project), PACKAGE_ID, SCHEMA)).toEqual({ explicit: false, scope: "default", value: true });
});

test("a resolver registered for another extension is not consulted", () => {
	const project = setupProject();
	let calls = 0;
	registerResolver(() => {
		calls += 1;
		return { explicit: true, value: false };
	}, "@scope/other");

	expect(getConfigValue(inventory(project), PACKAGE_ID, SCHEMA)).toEqual({ explicit: false, scope: "default", value: true });
	expect(calls).toBe(0);
});

test("resolver results are reused across reads of one inventory", () => {
	const project = setupProject();
	let calls = 0;
	registerResolver(() => {
		calls += 1;
		return { explicit: true, source: "~/.pi/agent/external.json", value: false };
	});

	const inv = inventory(project);
	for (let i = 0; i < 5; i += 1) expect(getConfigValue(inv, PACKAGE_ID, SCHEMA).value).toBe(false);
	expect(calls).toBe(1);

	expect(getConfigValue(inventory(project), PACKAGE_ID, SCHEMA).value).toBe(false);
	expect(calls).toBe(2);
});

test("setting schema refusals and save notices expose stable keys and values", () => {
	const refusals = [
		{ schema: { key: "flag", type: "boolean" }, input: "maybe", firstLine: "pi-extension-manager: setting-boolean=flag" },
		{ schema: { key: "limit", type: "number" }, input: "many", firstLine: "pi-extension-manager: setting-number=limit" },
		{ schema: { key: "style", type: "enum", enumValues: ["plain"] }, input: "fancy", firstLine: "pi-extension-manager: setting-enum=style" },
	] as const;
	for (const row of refusals) {
		expect(() => parseSettingInput(row.schema as SettingsSchema, row.input)).toThrow(row.firstLine);
	}

	const saveModes = ["live", "reload", "session", "restart"] as const;
	for (const apply of saveModes) {
		expect(applyMessage({ key: "style", type: "string", apply }).split("\n")[0]).toBe(`pi-extension-manager: setting-saved=style:${apply}`);
	}

	expect(() => getOrCreateRecord({ config: false }, "config")).toThrow("pi-extension-manager: object-required=config");
	expect(managerNotice("sample", "line\nbreak", "details").split("\n")[0]).toBe("pi-extension-manager: sample=line?break");
	expect(managerFailure("setting-save-failed", "style", new Error(managerNotice("setting-enum", "style", "details"))).split("\n")[0]).toBe("pi-extension-manager: setting-enum=style");
	expect(managerFailure("setting-save-failed", "style", new Error("disk full")).split("\n")[0]).toBe("pi-extension-manager: setting-save-failed=style");
});
