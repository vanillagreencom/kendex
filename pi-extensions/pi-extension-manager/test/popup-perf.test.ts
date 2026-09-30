import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { clearPackageConfigCache } from "../extensions/manager/package-config.ts";

const rootTmp = join(process.cwd(), "tmp", "pi-extension-manager-popup-perf-tests");

const originalEnv = {
	HOME: process.env.HOME,
	NPM_CONFIG_PREFIX: process.env.NPM_CONFIG_PREFIX,
	npm_config_prefix: process.env.npm_config_prefix,
	PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR,
};

const spawnSyncMock = mock(() => ({ status: 0, stdout: "", stderr: "", error: undefined, signal: null, output: [], pid: 0 }));

function resetTmp(): void {
	rmSync(rootTmp, { force: true, recursive: true });
	mkdirSync(rootTmp, { recursive: true });
}

function writeJson(path: string, value: unknown): void {
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function writeNpmPackage(rootNodeModules: string, name: string, version: string): void {
	const dir = join(rootNodeModules, ...name.split("/"));
	mkdirSync(dir, { recursive: true });
	writeJson(join(dir, "package.json"), {
		name,
		version,
		description: `${name} synthetic package`,
		pi: { extensions: ["./extensions/index.ts"] },
		kendex: {
			extensionManager: {
				displayName: name,
				settings: [{ key: "enabled", label: "enabled", type: "boolean", default: true }],
			},
		},
	});
	mkdirSync(join(dir, "extensions"), { recursive: true });
	writeFileSync(join(dir, "extensions", "index.ts"), "export default function () {}\n", "utf8");
}

beforeEach(() => {
	resetTmp();
	process.env.HOME = join(rootTmp, "home");
	process.env.NPM_CONFIG_PREFIX = join(rootTmp, "npm-prefix");
	process.env.npm_config_prefix = process.env.NPM_CONFIG_PREFIX;
	process.env.PI_CODING_AGENT_DIR = join(rootTmp, "home", ".pi", "agent");
	clearPackageConfigCache();
	spawnSyncMock.mockClear();
});

afterEach(async () => {
	const processModule = await import("../extensions/manager/process.ts");
	processModule.__setSpawnSyncForTests(undefined);
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

async function loadFreshModules() {
	const processModule = await import("../extensions/manager/process.ts");
	processModule.__setSpawnSyncForTests(spawnSyncMock as never);
	const inventory = await import("../extensions/manager/inventory.ts");
	const versions = await import("../extensions/manager/versions.ts");
	(versions as { __resetNpmRootCacheForTests: () => void }).__resetNpmRootCacheForTests();
	return inventory;
}

test("buildInventory does not spawn npm when packages resolve via Pi user npm dir", async () => {
	const { buildInventory } = await loadFreshModules();
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const npmRoot = join(userPi, "npm", "node_modules");

	mkdirSync(join(project, ".pi"), { recursive: true });
	const names = Array.from({ length: 20 }, (_, i) => `@scope/perf-pkg-${i}`);
	writeJson(join(userPi, "settings.json"), { packages: names.map((n) => `npm:${n}`) });
	for (const name of names) writeNpmPackage(npmRoot, name, "1.0.0");

	const inv = buildInventory({} as never, { cwd: project } as never);
	expect(inv.packages.length).toBe(20);
	for (const pkg of inv.packages) {
		expect(pkg.state).toBe("active");
		expect(pkg.installedVersion).toBe("1.0.0");
	}
	expect(spawnSyncMock).not.toHaveBeenCalled();
});

test("buildInventory memoizes npm root spawns across many packages when cheap paths miss", async () => {
	const { buildInventory } = await loadFreshModules();
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const fakeNpmRoot = join(rootTmp, "fake-npm-root");

	mkdirSync(join(project, ".pi"), { recursive: true });
	const names = Array.from({ length: 10 }, (_, i) => `@scope/spawn-pkg-${i}`);
	for (const name of names) writeNpmPackage(fakeNpmRoot, name, "1.0.0");

	delete process.env.NPM_CONFIG_PREFIX;
	delete process.env.npm_config_prefix;
	writeJson(join(userPi, "settings.json"), { packages: names.map((n) => `npm:${n}`) });

	spawnSyncMock.mockImplementation((_cmd: string, args: string[]) => {
		const subArgs = args.slice(1);
		const minusG = subArgs.includes("-g");
		return {
			status: 0,
			stdout: minusG ? `${fakeNpmRoot}\n` : "",
			stderr: "",
			error: undefined,
			signal: null,
			output: [],
			pid: 0,
		};
	});

	const inv = buildInventory({} as never, { cwd: project } as never);
	expect(inv.packages.length).toBe(10);
	for (const pkg of inv.packages) expect(pkg.state).toBe("active");

	// Memoization: at most one `npm root -g` invocation per (args, cwd) key for the
	// whole inventory build, regardless of package count.
	expect(spawnSyncMock.mock.calls.length).toBeLessThanOrEqual(2);
});

test("buildInventory wall-clock stays under 100ms for a realistic npm-heavy inventory", async () => {
	const { buildInventory } = await loadFreshModules();
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const npmRoot = join(userPi, "npm", "node_modules");

	mkdirSync(join(project, ".pi"), { recursive: true });
	const names = Array.from({ length: 25 }, (_, i) => `@scope/wallclock-pkg-${i}`);
	writeJson(join(userPi, "settings.json"), { packages: names.map((n) => `npm:${n}`) });
	for (const name of names) writeNpmPackage(npmRoot, name, "1.0.0");

	// Warm filesystem caches once so the timed pass measures steady-state cost.
	buildInventory({} as never, { cwd: project } as never);

	const start = performance.now();
	const inv = buildInventory({} as never, { cwd: project } as never);
	const elapsed = performance.now() - start;
	expect(inv.packages.length).toBe(25);
	expect(elapsed).toBeLessThan(100);
});
