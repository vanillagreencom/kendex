import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { planUninstall, planUpdate, toggleItem } from "../extensions/manager/actions.ts";
import { applyUpdateMetadata, buildInventory } from "../extensions/manager/inventory.ts";
import { npmCachePath } from "../extensions/manager/paths.ts";
import { gitPackageDirCandidates } from "../extensions/manager/versions.ts";

const rootTmp = join(process.cwd(), "tmp", "pi-extension-manager-inventory-tests");
const originalEnv = {
	HOME: process.env.HOME,
	NPM_CONFIG_PREFIX: process.env.NPM_CONFIG_PREFIX,
	npm_config_prefix: process.env.npm_config_prefix,
	PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR,
};

function resetTmp(): void {
	rmSync(rootTmp, { force: true, recursive: true });
	mkdirSync(rootTmp, { recursive: true });
}

function writeJson(path: string, value: unknown): void {
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function writePackage(dir: string, name: string, displayName: string, settingsKey: string): void {
	mkdirSync(join(dir, "extensions"), { recursive: true });
	writeFileSync(join(dir, "extensions", "index.ts"), "export default function () {}\n", "utf8");
	writeJson(join(dir, "package.json"), {
		name,
		version: "1.2.3",
		description: `${displayName} package`,
		pi: { extensions: ["./extensions/index.ts"] },
		kendex: {
			extensionManager: {
				displayName,
				settings: [
					{ key: settingsKey, label: settingsKey, type: "boolean", default: true },
				],
			},
		},
	});
}

function inventory(cwd: string) {
	return buildInventory({} as never, { cwd } as never);
}

function inventoryWithTrust(cwd: string, trusted: boolean) {
	return buildInventory({} as never, { cwd, isProjectTrusted: () => trusted } as never);
}

beforeEach(() => {
	resetTmp();
	process.env.HOME = join(rootTmp, "home");
	process.env.NPM_CONFIG_PREFIX = join(rootTmp, "npm-prefix");
	process.env.npm_config_prefix = process.env.NPM_CONFIG_PREFIX;
	process.env.PI_CODING_AGENT_DIR = join(rootTmp, "home", ".pi", "agent");
});

afterEach(() => {
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

test("reads settings schemas from user-scoped Pi npm packages", () => {
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const npmPackageDir = join(userPi, "npm", "node_modules", "@scope", "user-settings");
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), { packages: ["npm:@scope/user-settings"] });
	writePackage(npmPackageDir, "@scope/user-settings", "User Settings", "enabled");

	const inv = inventory(project);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/user-settings");
	expect(item?.scope).toBe("user");
	expect(item?.state).toBe("active");
	expect(item?.displayName).toBe("User Settings");
	expect(item?.settingsSchema?.map((schema) => schema.key)).toEqual(["enabled"]);
	expect(item?.packageDir).toBe(npmPackageDir);
	expect(inv.items.some((entry) => entry.kind === "extension module" && entry.sourcePath === join(npmPackageDir, "extensions", "index.ts"))).toBe(true);
});

test("reads settings schemas from legacy npm global prefix packages", () => {
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const npmPackageDir = join(process.env.NPM_CONFIG_PREFIX!, "lib", "node_modules", "@scope", "legacy-settings");
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), { packages: ["npm:@scope/legacy-settings"] });
	writePackage(npmPackageDir, "@scope/legacy-settings", "Legacy Settings", "enabled");

	const inv = inventory(project);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/legacy-settings");
	expect(item?.scope).toBe("user");
	expect(item?.state).toBe("active");
	expect(item?.packageDir).toBe(npmPackageDir);
	expect(item?.settingsSchema?.map((schema) => schema.key)).toEqual(["enabled"]);
});

test("project npm package settings override same global npm package", () => {
	const project = join(rootTmp, "project");
	const projectPi = join(project, ".pi");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const userPackageDir = join(userPi, "npm", "node_modules", "@scope", "dupe-settings");
	const projectPackageDir = join(projectPi, "npm", "node_modules", "@scope", "dupe-settings");
	writeJson(join(userPi, "settings.json"), { packages: ["npm:@scope/dupe-settings"] });
	writeJson(join(projectPi, "settings.json"), { packages: ["npm:@scope/dupe-settings"] });
	writePackage(userPackageDir, "@scope/dupe-settings", "User Copy", "userFlag");
	writePackage(projectPackageDir, "@scope/dupe-settings", "Project Copy", "projectFlag");

	const inv = inventoryWithTrust(project, true);
	const copies = inv.packages.filter((pkg) => pkg.packageName === "@scope/dupe-settings");
	expect(copies).toHaveLength(2);
	expect(copies.find((pkg) => pkg.scope === "project")?.state).toBe("active");
	expect(copies.find((pkg) => pkg.scope === "project")?.displayName).toBe("Project Copy");
	expect(copies.find((pkg) => pkg.scope === "project")?.settingsSchema?.map((schema) => schema.key)).toEqual(["projectFlag"]);
	expect(copies.find((pkg) => pkg.scope === "user")?.state).toBe("shadowed");
});

test("ignores project settings when Pi reports project untrusted", () => {
	const project = join(rootTmp, "project");
	const projectPi = join(project, ".pi");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const userPackageDir = join(userPi, "npm", "node_modules", "@scope", "dupe-settings");
	const projectPackageDir = join(projectPi, "npm", "node_modules", "@scope", "dupe-settings");
	writeJson(join(userPi, "settings.json"), { packages: ["npm:@scope/dupe-settings"] });
	writeJson(join(projectPi, "settings.json"), { packages: ["npm:@scope/dupe-settings"], kendex: { extensionManager: { config: { "@scope/dupe-settings": { enabled: false } } } } });
	writePackage(userPackageDir, "@scope/dupe-settings", "User Copy", "userFlag");
	writePackage(projectPackageDir, "@scope/dupe-settings", "Project Copy", "projectFlag");

	const inv = inventoryWithTrust(project, false);
	expect(inv.settingsFiles.find((file) => file.scope === "project")?.projectTrusted).toBe(false);
	expect(inv.packages.filter((pkg) => pkg.packageName === "@scope/dupe-settings")).toHaveLength(1);
	expect(inv.packages.find((pkg) => pkg.packageName === "@scope/dupe-settings")?.scope).toBe("user");
	expect(inv.managerState.config["@scope/dupe-settings"]).toBeUndefined();
});

test("npm update and uninstall plans use Pi scope-local npm directories", () => {
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const npmPackageDir = join(userPi, "npm", "node_modules", "@scope", "updatable");
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), { packages: ["npm:@scope/updatable"] });
	writePackage(npmPackageDir, "@scope/updatable", "Updatable", "enabled");
	writeJson(npmCachePath(), {
		"@scope/updatable": { version: "1.2.4", checkedAt: Date.now() },
		"@scope/missing": { version: "1.2.4", checkedAt: Date.now() },
	});

	const inv = inventory(project);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/updatable")!;
	expect(item.updateCommand).toBe(`(cd '${join(userPi, "npm")}' && npm install @scope/updatable@latest)`);
	const missing = { ...item, id: "package:@scope/missing", sourceName: "npm:@scope/missing", packageName: "@scope/missing", packageDir: undefined, installedVersion: "1.0.0" };
	applyUpdateMetadata([missing], inv.settingsFiles, project);
	expect(missing.updateCommand).toBe("pi install npm:@scope/missing@latest");

	const update = planUpdate(item, inv, { cwd: project } as never);
	const uninstall = planUninstall(item, inv, { cwd: project } as never);
	expect(update?.command).toBe(`(cd '${join(userPi, "npm")}' && npm install @scope/updatable@latest)`);
	expect(uninstall?.command).toBe(`(cd '${join(userPi, "npm")}' && npm uninstall @scope/updatable)`);
});

test("vendored append-system script installs and removes from Pi npm scope", () => {
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const packageDir = join(userPi, "npm", "node_modules", "@scope", "append-test");
	mkdirSync(join(packageDir, "scripts"), { recursive: true });
	writeJson(join(packageDir, "package.json"), { name: "@scope/append-test", pi: { appendSystem: "instructions.md" } });
	writeFileSync(join(packageDir, "instructions.md"), "Append instructions\n");
	writeFileSync(
		join(packageDir, "scripts", "append-system.mjs"),
		readFileSync(join(import.meta.dir, "..", "..", "pi-session-bridge", "scripts", "append-system.mjs"), "utf8"),
	);

	const script = join(packageDir, "scripts", "append-system.mjs");
	const childEnv = { ...process.env, PI_CODING_AGENT_DIR: userPi } as Record<string, string>;
	expect(Bun.spawnSync(["node", script, "install"], { env: childEnv }).exitCode).toBe(0);
	expect(readFileSync(join(userPi, "APPEND_SYSTEM.md"), "utf8")).toContain("Append instructions");
	expect(Bun.spawnSync(["node", script, "remove"], { env: childEnv }).exitCode).toBe(0);
	const target = join(userPi, "APPEND_SYSTEM.md");
	expect(existsSync(target) ? readFileSync(target, "utf8") : "").not.toContain("Append instructions");
});

test("toggle runs the package's own append-system script", () => {
	const project = join(rootTmp, "project");
	const projectPi = join(project, ".pi");
	const packageDir = join(projectPi, "npm", "node_modules", "@scope", "append-toggle");
	const settingsPath = join(projectPi, "settings.json");
	writeJson(settingsPath, { packages: ["npm:@scope/append-toggle"] });
	writePackage(packageDir, "@scope/append-toggle", "Append Toggle", "enabled");
	writeJson(join(packageDir, "package.json"), {
		name: "@scope/append-toggle",
		pi: { extensions: ["./extensions/index.ts"], appendSystem: "instructions.md" },
		kendex: { extensionManager: { displayName: "Append Toggle", settings: [] } },
	});
	writeFileSync(join(packageDir, "instructions.md"), "Toggle instructions\n");
	mkdirSync(join(packageDir, "scripts"), { recursive: true });
	writeFileSync(
		join(packageDir, "scripts", "append-system.mjs"),
		readFileSync(join(import.meta.dir, "..", "..", "pi-session-bridge", "scripts", "append-system.mjs"), "utf8"),
	);
	const target = join(projectPi, "APPEND_SYSTEM.md");
	const ctx = { cwd: project, ui: { notify() {} } } as never;

	const disable = inventoryWithTrust(project, true);
	toggleItem({} as never, ctx, disable, disable.packages.find((pkg) => pkg.packageName === "@scope/append-toggle")!);
	expect(existsSync(target) ? readFileSync(target, "utf8") : "").not.toContain("Toggle instructions");

	const enable = inventoryWithTrust(project, true);
	toggleItem({} as never, ctx, enable, enable.packages.find((pkg) => pkg.packageName === "@scope/append-toggle")!);
	expect(readFileSync(target, "utf8")).toContain("Toggle instructions");
});

test("reads settings schemas from project git package clones", () => {
	const project = join(rootTmp, "project");
	const projectPi = join(project, ".pi");
	const gitPackageDir = join(projectPi, "git", "github.com", "acme", "pi-package");
	writeJson(join(projectPi, "settings.json"), { packages: ["git:github.com/acme/pi-package@v1.0.0"] });
	writePackage(gitPackageDir, "acme-pi-package", "Git Package", "gitFlag");

	const inv = inventoryWithTrust(project, true);
	const item = inv.packages.find((pkg) => pkg.packageName === "acme-pi-package");
	expect(item?.scope).toBe("project");
	expect(item?.state).toBe("active");
	expect(item?.settingsSchema?.map((schema) => schema.key)).toEqual(["gitFlag"]);
	expect(item?.packageDir).toBe(gitPackageDir);
});

test("rejects unsafe git package clone components", () => {
	const project = join(rootTmp, "project");
	const projectPi = join(project, ".pi");
	const validPackageDir = join(projectPi, "git", "github.com", "acme", "pi-package");
	const maliciousSource = "git:github.com/acme/../../escape@v1.0.0";

	expect(gitPackageDirCandidates("git:github.com/acme/pi-package@v1.0.0", "project", projectPi)).toEqual([validPackageDir]);
	expect(gitPackageDirCandidates("git:git@github.com:acme/pi-package.git@v1.0.0", "project", projectPi)).toEqual([validPackageDir]);
	expect(gitPackageDirCandidates(maliciousSource, "project", projectPi)).toEqual([]);

	writeJson(join(projectPi, "settings.json"), { packages: [maliciousSource] });
	writePackage(join(projectPi, "escape"), "escaped-package", "Escaped Package", "escapedFlag");

	const inv = inventoryWithTrust(project, true);
	expect(inv.packages.some((pkg) => pkg.packageName === "escaped-package")).toBe(false);
	const item = inv.packages.find((pkg) => pkg.sourceName === maliciousSource);
	expect(item?.state).toBe("broken");
	expect(item?.sourcePath).toBe(maliciousSource);
});

test("toggles project npm packages by original settings source", () => {
	const project = join(rootTmp, "project");
	const projectPi = join(project, ".pi");
	const projectPackageDir = join(projectPi, "npm", "node_modules", "@scope", "toggle-settings");
	const settingsPath = join(projectPi, "settings.json");
	writeJson(settingsPath, { packages: ["npm:@scope/toggle-settings"] });
	writePackage(projectPackageDir, "@scope/toggle-settings", "Toggle Settings", "enabled");

	const inv = inventoryWithTrust(project, true);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/toggle-settings");
	expect(item?.sourcePath).toBe(projectPackageDir);
	toggleItem({} as never, { cwd: project, ui: { notify() {} } } as never, inv, item!);

	const saved = JSON.parse(readFileSync(settingsPath, "utf8"));
	expect(saved.packages).toEqual([{ source: "npm:@scope/toggle-settings", extensions: [] }]);
});
