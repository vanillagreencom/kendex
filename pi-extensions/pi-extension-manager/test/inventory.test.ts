import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { clearPackageConfigCache } from "../extensions/manager/package-config.ts";
import { planUninstall, planUpdate, toggleItem } from "../extensions/manager/actions.ts";
import { applyUpdateMetadata, buildInventory } from "../extensions/manager/inventory.ts";
import { npmCachePath } from "../extensions/manager/paths.ts";
import { gitPackageDirCandidates } from "../extensions/manager/versions.ts";
import { packageExtensions } from "../extensions/manager/filters.ts";
import { mutantManager, writeCommand } from "./fixtures/commands.ts";

const rootTmp = join(process.cwd(), "tmp", "pi-extension-manager-inventory-tests");
const originalEnv = {
	HOME: process.env.HOME,
	NPM_CONFIG_PREFIX: process.env.NPM_CONFIG_PREFIX,
	npm_config_prefix: process.env.npm_config_prefix,
	PATH: process.env.PATH,
	PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR,
};
const nodePath = Bun.which("node");

function live(): AbortSignal {
	return new AbortController().signal;
}

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
	clearPackageConfigCache();
	// Package scripts and npm-root lookups inherit the live environment.
	if (!nodePath) throw new Error("inventory-test: node is not on PATH");
	process.env.PATH = [dirname(nodePath), "/usr/bin", "/bin"].join(":");
});

afterEach(() => {
	process.env.PATH = originalEnv.PATH;
	if (originalEnv.HOME === undefined) delete process.env.HOME;
	else process.env.HOME = originalEnv.HOME;
	if (originalEnv.NPM_CONFIG_PREFIX === undefined) delete process.env.NPM_CONFIG_PREFIX;
	else process.env.NPM_CONFIG_PREFIX = originalEnv.NPM_CONFIG_PREFIX;
	if (originalEnv.npm_config_prefix === undefined) delete process.env.npm_config_prefix;
	else process.env.npm_config_prefix = originalEnv.npm_config_prefix;
	if (originalEnv.PI_CODING_AGENT_DIR === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = originalEnv.PI_CODING_AGENT_DIR;
	clearPackageConfigCache();
	rmSync(rootTmp, { force: true, recursive: true });
});

test("leaves built-in selectors to pi config while retaining extension paths in both scopes", async () => {
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const projectPi = join(project, ".pi");
	const extensions = ["builtin:mcp", "-builtin:mcp", "builtin:tool-search", "-builtin:tool-search", "./builtin:local.ts", "./-builtin:local.ts", "./custom.ts"];
	writeJson(join(userPi, "settings.json"), { extensions });
	writeJson(join(projectPi, "settings.json"), { extensions });

	const inv = await inventoryWithTrust(project, true);
	for (const scope of ["user", "project"]) {
		const rows = inv.items.filter((item) => item.kind === "extension setting" && item.scope === scope);
		expect(rows.map((item) => item.sourceName).sort()).toEqual(["./-builtin:local.ts", "./builtin:local.ts", "./custom.ts"]);
	}
});

test("reads settings schemas from user-scoped Pi npm packages", async () => {
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const npmPackageDir = join(userPi, "npm", "node_modules", "@scope", "user-settings");
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), { packages: ["npm:@scope/user-settings"] });
	writePackage(npmPackageDir, "@scope/user-settings", "User Settings", "enabled");

	const inv = await inventory(project);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/user-settings");
	expect(item?.scope).toBe("user");
	expect(item?.state).toBe("active");
	expect(item?.displayName).toBe("User Settings");
	expect(item?.settingsSchema?.map((schema) => schema.key)).toEqual(["enabled"]);
	expect(item?.packageDir).toBe(npmPackageDir);
	expect(inv.items.some((entry) => entry.kind === "extension module" && entry.sourcePath === join(npmPackageDir, "extensions", "index.ts"))).toBe(true);
});

type InventoryModule = typeof import("../extensions/manager/inventory.ts");

/** The broken reason of a user npm package no cheap root holds, while `npm root -g` exits 3. */
async function unrootedReason(module: InventoryModule): Promise<string | undefined> {
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const bin = join(rootTmp, "bin");
	writeCommand(join(bin, "npm"), "exit 3");
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), { packages: ["npm:@scope/unrooted"] });
	clearPackageConfigCache();
	process.env.PATH = [bin, process.env.PATH].join(":");
	// A fresh host object is a fresh session, so no earlier lookup is memoized.
	const inv = await module.buildInventory({} as never, { cwd: project } as never);
	return inv.packages.find((pkg) => pkg.packageName === "@scope/unrooted")?.stateReason;
}

test("a failed npm root lookup is named in the broken reason; control: dropping the lookup failures reads as not installed", async () => {
	expect(await unrootedReason(await import("../extensions/manager/inventory.ts"))).toBe("package source not found: npm:@scope/unrooted; npm root -g: exit=3");
	const mutant = mutantManager(join(rootTmp, "mutant-reason"), [{
		file: "inventory.ts",
		before: "[`package source not found: npm:${npmName}`, ...lookup.lookupFailures]",
		after: "[`package source not found: npm:${npmName}`]",
	}]);
	expect(await unrootedReason(await import(join(mutant, "inventory.ts")))).toBe("package source not found: npm:@scope/unrooted");
});

test("reads settings schemas from legacy npm global prefix packages", async () => {
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const npmPackageDir = join(process.env.NPM_CONFIG_PREFIX!, "lib", "node_modules", "@scope", "legacy-settings");
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), { packages: ["npm:@scope/legacy-settings"] });
	writePackage(npmPackageDir, "@scope/legacy-settings", "Legacy Settings", "enabled");

	const inv = await inventory(project);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/legacy-settings");
	expect(item?.scope).toBe("user");
	expect(item?.state).toBe("active");
	expect(item?.packageDir).toBe(npmPackageDir);
	expect(item?.settingsSchema?.map((schema) => schema.key)).toEqual(["enabled"]);
});

test("project npm package settings override same global npm package", async () => {
	const project = join(rootTmp, "project");
	const projectPi = join(project, ".pi");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const userPackageDir = join(userPi, "npm", "node_modules", "@scope", "dupe-settings");
	const projectPackageDir = join(projectPi, "npm", "node_modules", "@scope", "dupe-settings");
	writeJson(join(userPi, "settings.json"), { packages: ["npm:@scope/dupe-settings"] });
	writeJson(join(projectPi, "settings.json"), { packages: ["npm:@scope/dupe-settings"] });
	writePackage(userPackageDir, "@scope/dupe-settings", "User Copy", "userFlag");
	writePackage(projectPackageDir, "@scope/dupe-settings", "Project Copy", "projectFlag");

	const inv = await inventoryWithTrust(project, true);
	const copies = inv.packages.filter((pkg) => pkg.packageName === "@scope/dupe-settings");
	expect(copies).toHaveLength(2);
	expect(copies.find((pkg) => pkg.scope === "project")?.state).toBe("active");
	expect(copies.find((pkg) => pkg.scope === "project")?.displayName).toBe("Project Copy");
	expect(copies.find((pkg) => pkg.scope === "project")?.settingsSchema?.map((schema) => schema.key)).toEqual(["projectFlag"]);
	expect(copies.find((pkg) => pkg.scope === "user")?.state).toBe("shadowed");
	for (const pkg of copies) expect(packageExtensions(inv.items, pkg).map((item) => item.scope)).toEqual([pkg.scope]);
	expect(new Set(copies.map((pkg) => pkg.id)).size).toBe(2);
});

test("ignores project settings when Pi reports project untrusted", async () => {
	const project = join(rootTmp, "project");
	const projectPi = join(project, ".pi");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const userPackageDir = join(userPi, "npm", "node_modules", "@scope", "dupe-settings");
	const projectPackageDir = join(projectPi, "npm", "node_modules", "@scope", "dupe-settings");
	writeJson(join(userPi, "settings.json"), { packages: ["npm:@scope/dupe-settings"] });
	writeJson(join(projectPi, "settings.json"), { packages: ["npm:@scope/dupe-settings"], kendex: { extensionManager: { config: { "@scope/dupe-settings": { enabled: false } } } } });
	writePackage(userPackageDir, "@scope/dupe-settings", "User Copy", "userFlag");
	writePackage(projectPackageDir, "@scope/dupe-settings", "Project Copy", "projectFlag");

	const inv = await inventoryWithTrust(project, false);
	expect(inv.settingsFiles.find((file) => file.scope === "project")?.projectTrusted).toBe(false);
	expect(inv.packages.filter((pkg) => pkg.packageName === "@scope/dupe-settings")).toHaveLength(1);
	expect(inv.packages.find((pkg) => pkg.packageName === "@scope/dupe-settings")?.scope).toBe("user");
	expect(inv.managerState.config["@scope/dupe-settings"]).toBeUndefined();
});

test("npm update and uninstall plans use Pi scope-local npm directories", async () => {
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

	const inv = await inventory(project);
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

test("vendored append-system script installs and removes from Pi npm scope", async () => {
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

test("toggle runs the package's own append-system script", async () => {
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

	const disable = await inventoryWithTrust(project, true);
	await toggleItem({} as never, ctx, disable, disable.packages.find((pkg) => pkg.packageName === "@scope/append-toggle")!, live());
	expect(existsSync(target) ? readFileSync(target, "utf8") : "").not.toContain("Toggle instructions");

	const enable = await inventoryWithTrust(project, true);
	await toggleItem({} as never, ctx, enable, enable.packages.find((pkg) => pkg.packageName === "@scope/append-toggle")!, live());
	expect(readFileSync(target, "utf8")).toContain("Toggle instructions");
});

test("reads settings schemas from project git package clones", async () => {
	const project = join(rootTmp, "project");
	const projectPi = join(project, ".pi");
	const gitPackageDir = join(projectPi, "git", "github.com", "acme", "pi-package");
	writeJson(join(projectPi, "settings.json"), { packages: ["git:github.com/acme/pi-package@v1.0.0"] });
	writePackage(gitPackageDir, "acme-pi-package", "Git Package", "gitFlag");

	const inv = await inventoryWithTrust(project, true);
	const item = inv.packages.find((pkg) => pkg.packageName === "acme-pi-package");
	expect(item?.scope).toBe("project");
	expect(item?.state).toBe("active");
	expect(item?.settingsSchema?.map((schema) => schema.key)).toEqual(["gitFlag"]);
	expect(item?.packageDir).toBe(gitPackageDir);
});

test("rejects unsafe git package clone components", async () => {
	const project = join(rootTmp, "project");
	const projectPi = join(project, ".pi");
	const validPackageDir = join(projectPi, "git", "github.com", "acme", "pi-package");
	const maliciousSource = "git:github.com/acme/../../escape@v1.0.0";

	expect(gitPackageDirCandidates("git:github.com/acme/pi-package@v1.0.0", "project", projectPi)).toEqual([validPackageDir]);
	expect(gitPackageDirCandidates("git:git@github.com:acme/pi-package.git@v1.0.0", "project", projectPi)).toEqual([validPackageDir]);
	expect(gitPackageDirCandidates(maliciousSource, "project", projectPi)).toEqual([]);

	writeJson(join(projectPi, "settings.json"), { packages: [maliciousSource] });
	writePackage(join(projectPi, "escape"), "escaped-package", "Escaped Package", "escapedFlag");

	const inv = await inventoryWithTrust(project, true);
	expect(inv.packages.some((pkg) => pkg.packageName === "escaped-package")).toBe(false);
	const item = inv.packages.find((pkg) => pkg.sourceName === maliciousSource);
	expect(item?.state).toBe("broken");
	expect(item?.sourcePath).toBe(maliciousSource);
});

// Pi SettingsManager.setProjectPackages retains rooted registrations; CLI installs use relative paths.
test.each([
	[["./packages/first", "./packages/second"], [join(rootTmp, "original", ".pi", "packages", "first"), join(rootTmp, "original", ".pi", "packages", "second")]],
	[[join(rootTmp, "external", "first"), join(rootTmp, "external", "second")], [join(rootTmp, "external", "first"), join(rootTmp, "external", "second")]],
	[["npm:@scope/relocate"], [join(rootTmp, "original", ".pi", "npm", "node_modules", "@scope", "relocate")]],
	[["git:github.com/acme/relocate@v1.0.0"], [join(rootTmp, "original", ".pi", "git", "github.com", "acme", "relocate")]],
])("relocated registrations retain ids, grouping and first-enable behavior: %j", async (sources, dirs) => {
	const project = join(rootTmp, "original");
	writeJson(join(project, ".pi", "settings.json"), { packages: sources });
	for (const dir of dirs) writePackage(dir, "@scope/relocate", "Relocate", "enabled");
	const ctx = { cwd: project, isProjectTrusted: () => true, ui: { notify() {} } } as never;
	const original = await buildInventory({} as never, ctx);
	for (const pkg of original.packages) expect(packageExtensions(original.items, pkg)).toHaveLength(1);
	const selected = packageExtensions(original.items, original.packages[0]!)[0]!;
	expect(original.packages.map((pkg) => pkg.packageDir)).toEqual(dirs);
	await toggleItem({} as never, ctx, original, selected, live());
	const moved = join(rootTmp, "deeper", "relocated");
	cpSync(project, moved, { recursive: true });
	const movedCtx = { cwd: moved, isProjectTrusted: () => true, ui: { notify() {} } } as never;
	const relocated = await buildInventory({} as never, movedCtx);
	expect(relocated.packages.map((pkg) => pkg.id)).toEqual(sources.map((source) => `package:project:${source}:@scope/relocate`));
	const module = relocated.items.find((item) => item.id === selected.id)!;
	expect(module.state).toBe("disabled");
	expect(packageExtensions(relocated.items, relocated.packages[0]!)[0]!.id).toBe(selected.id);
	await toggleItem({} as never, movedCtx, relocated, module, live());
	const settingsPath = join(moved, ".pi", "settings.json");
	const saved = JSON.parse(readFileSync(settingsPath, "utf8"));
	expect(saved.packages).toEqual(sources);
	expect(saved.kendex.extensionManager.disabledItems).toEqual([]);
	const enabled = await buildInventory({} as never, movedCtx);
	await toggleItem({} as never, movedCtx, enabled, enabled.packages[0]!, live());
	expect(JSON.parse(readFileSync(settingsPath, "utf8")).packages).toEqual([{ source: sources[0], extensions: [] }, ...sources.slice(1)]);
});

test("inventory refuses more than 10000 package and extension rows", async () => {
	const project = join(rootTmp, "project");
	const packageDir = join(process.env.PI_CODING_AGENT_DIR!, "packages", "large");
	writeJson(join(process.env.PI_CODING_AGENT_DIR!, "settings.json"), { packages: [packageDir] });
	writeJson(join(packageDir, "package.json"), { name: "large", pi: { extensions: Array.from({ length: 10000 }, (_, i) => `extension-${i}.ts`) } });
	await expect(inventory(project)).rejects.toThrow("inventory-limit: items=10001 limit=10000");
});

test("toggle writes stay in the selected scope through disable, other-scope toggle and re-enable", async () => {
	const project = join(rootTmp, "project");
	const roots = [{ scope: "project", base: join(project, ".pi") }, { scope: "user", base: process.env.PI_CODING_AGENT_DIR! }];
	for (const row of roots) {
		writePackage(join(row.base, "packages", row.scope), `@scope/${row.scope}-toggle`, row.scope, "enabled");
		writeJson(join(row.base, "settings.json"), {
			packages: [`./packages/${row.scope}`], customSetting: row.scope,
			kendex: { extensionManager: { disabledItems: [`unrelated:${row.scope}`], config: { owned: { scope: row.scope } } } },
		});
	}
	const ctx = { cwd: project, isProjectTrusted: () => true, ui: { notify() {} } } as never;
	const first = await buildInventory({} as never, ctx);
	const projectPackage = first.packages.find((pkg) => pkg.scope === "project")!;
	const userModule = packageExtensions(first.items, first.packages.find((pkg) => pkg.scope === "user")!)[0]!;
	const steps = [projectPackage.id, userModule.id, projectPackage.id];
	for (const [step, id] of steps.entries()) {
		const inv = await buildInventory({} as never, ctx);
		await toggleItem({} as never, ctx, inv, inv.items.find((item) => item.id === id)!, live());
		for (const row of roots) {
			const saved = JSON.parse(readFileSync(join(row.base, "settings.json"), "utf8"));
			const selected = row.scope === "project" ? (step < 2 ? [projectPackage.id] : []) : (step > 0 ? [userModule.id] : []);
			expect(saved.kendex.extensionManager.disabledItems).toEqual([...selected, `unrelated:${row.scope}`].sort());
			expect(saved.kendex.extensionManager.config).toEqual({ owned: { scope: row.scope } });
			expect(saved.customSetting).toBe(row.scope);
		}
	}
	const final = await buildInventory({} as never, ctx);
	expect(final.items.find((item) => item.id === projectPackage.id)?.state).toBe("active");
	expect(final.items.find((item) => item.id === userModule.id)?.state).toBe("disabled");
	expect(JSON.parse(readFileSync(join(project, ".pi", "settings.json"), "utf8")).packages).toEqual(["./packages/project"]);
	expect(JSON.parse(readFileSync(join(process.env.PI_CODING_AGENT_DIR!, "settings.json"), "utf8")).packages).toEqual([{ source: "./packages/user", extensions: ["-./extensions/index.ts"] }]);
});

test("legacy toggle ids migrate to the owning installation with a warning", async () => {
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const name = "@scope/legacy-toggle";
	const roots = [{ scope: "project", base: join(project, ".pi") }, { scope: "user", base: userPi }];
	for (const row of roots) {
		writePackage(join(row.base, "npm", "node_modules", ...name.split("/")), name, "Legacy", "enabled");
		writeJson(join(row.base, "settings.json"), { packages: [`npm:${name}`], kendex: { extensionManager: {
			disabledItems: [`package:${name}`, `extension:${name}:./extensions/index.ts`, `unrelated:${row.scope}`], config: { owned: { scope: row.scope } },
		} } });
	}
	const warning = spyOn(console, "warn").mockImplementation(() => {});
	try {
		const inv = await inventoryWithTrust(project, true);
		expect(inv.packages.find((pkg) => pkg.scope === "project")!.state).toBe("disabled");
		expect(inv.managerState.disabledItems.sort()).toEqual([...inv.items.map((item) => item.id), "unrelated:project", "unrelated:user"].sort());
		expect(warning).toHaveBeenCalledTimes(1);
		for (const row of roots) {
			const current = await inventoryWithTrust(project, true);
			const pkg = current.packages.find((pkg) => pkg.scope === row.scope)!;
			const module = packageExtensions(current.items, pkg)[0]!;
			await toggleItem({} as never, { cwd: project, ui: { notify() {} } } as never, current, pkg, live());
			const saved = JSON.parse(readFileSync(join(row.base, "settings.json"), "utf8"));
			expect(saved.kendex.extensionManager.disabledItems).toEqual([module.id, `unrelated:${row.scope}`].sort());
			expect(saved.kendex.extensionManager.config).toEqual({ owned: { scope: row.scope } });
			const enabled = await inventoryWithTrust(project, true);
			expect(enabled.managerState.disabledItems).not.toContain(pkg.id);
			await toggleItem({} as never, { cwd: project, ui: { notify() {} } } as never, enabled, enabled.items.find((item) => item.id === module.id)!, live());
			expect(JSON.parse(readFileSync(join(row.base, "settings.json"), "utf8")).kendex.extensionManager.disabledItems).toEqual([`unrelated:${row.scope}`]);
		}
	} finally { warning.mockRestore(); }
});

test("kendex update metadata and plans read the selected scope source index", async () => {
	const project = join(rootTmp, "project");
	const roots = [{ scope: "user", base: process.env.PI_CODING_AGENT_DIR!, version: "2.0.0" }, { scope: "project", base: join(project, ".pi"), version: "3.0.0" }];
	for (const row of roots) {
		const installed = join(row.base, "packages", "scoped");
		const repo = join(row.base, "source-repo");
		writePackage(installed, "scoped", row.scope, "enabled");
		writeJson(join(repo, "package.json"), { name: "scoped", version: row.version });
		writeJson(join(row.base, "settings.json"), { packages: [installed] });
		writeJson(join(row.base, ".kendex-source.json"), { scoped: { sourceRepo: repo, sourcePath: repo } });
	}
	const inv = await inventoryWithTrust(project, true);
	for (const row of roots) {
		const item = inv.packages.find((pkg) => pkg.scope === row.scope)!;
		expect(item.latestVersion).toBe(row.version);
		expect(planUpdate(item, inv, { cwd: project } as never)?.method).toEqual({ kind: "kendex", packageName: "scoped", sourceRepo: join(row.base, "source-repo"), scope: row.scope, cwd: project });
	}
});
