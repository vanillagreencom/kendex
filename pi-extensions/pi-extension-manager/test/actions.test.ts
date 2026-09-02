import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { spawnSync as realSpawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const rootTmp = join(import.meta.dir, "..", "tmp", "actions-test");
const originalEnv = { PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR };
const spawnSyncMock = mock(() => ({ status: 0, stdout: "", stderr: "", error: undefined, signal: null, output: [], pid: 0 }));

function writeJson(path: string, value: unknown): void {
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, JSON.stringify(value, null, 2));
}

function writePackage(dir: string, name: string): void {
	mkdirSync(dir, { recursive: true });
	writeFileSync(join(dir, "package.json"), JSON.stringify({ name, version: "1.0.0", pi: { extensions: ["./extension.ts"] } }));
	writeFileSync(join(dir, "extension.ts"), "export default function activate() {}\n");
}

// A package shaped like the six this repo ships: a pi.appendSystem manifest,
// its instructions, and the vendored script npm runs at postinstall.
function writeAppendSystemPackage(dir: string, name: string): void {
	mkdirSync(join(dir, "scripts"), { recursive: true });
	writeFileSync(join(dir, "package.json"), JSON.stringify({
		name,
		version: "1.0.0",
		pi: { extensions: ["./extension.ts"], appendSystem: "instructions.md" },
	}));
	writeFileSync(join(dir, "extension.ts"), "export default function activate() {}\n");
	writeFileSync(join(dir, "instructions.md"), "Append pkg instructions\n");
	copyFileSync(join(import.meta.dir, "..", "..", "pi-session-bridge", "scripts", "append-system.mjs"), join(dir, "scripts", "append-system.mjs"));
}

beforeEach(() => {
	rmSync(rootTmp, { recursive: true, force: true });
	mkdirSync(rootTmp, { recursive: true });
	process.env.PI_CODING_AGENT_DIR = join(rootTmp, "home", ".pi", "agent");
	spawnSyncMock.mockClear();
});

afterEach(async () => {
	const processModule = await import("../extensions/manager/process.ts");
	processModule.__setSpawnSyncForTests(undefined);
	rmSync(rootTmp, { recursive: true, force: true });
	if (originalEnv.PI_CODING_AGENT_DIR === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = originalEnv.PI_CODING_AGENT_DIR;
});

// spawnSync snapshots the environment the process started with, so a child
// spawned from these tests would resolve the developer's real ~/.pi/agent and
// write into their live APPEND_SYSTEM.md. Every test that lets a real node run
// goes through this, which pins the child's HOME and PI_CODING_AGENT_DIR.
function sandboxedEnv(): NodeJS.ProcessEnv {
	return { ...process.env, HOME: join(rootTmp, "home"), PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR };
}

function runVendoredScript(packageDir: string, action: string) {
	return realSpawnSync("node", [join(packageDir, "scripts", "append-system.mjs"), action], { encoding: "utf8", env: sandboxedEnv() });
}

interface SpawnRecord { command: string; args: string[]; options: Record<string, unknown> }

// Real node for the append-system script, a canned result for anything else.
async function useSandboxedSpawn(nonNodeResult?: object): Promise<SpawnRecord[]> {
	const seen: SpawnRecord[] = [];
	const processModule = await import("../extensions/manager/process.ts");
	processModule.__setSpawnSyncForTests(((command: string, args: string[], options?: never) => {
		seen.push({ command, args, options: (options ?? {}) as Record<string, unknown> });
		if (command !== "node" && nonNodeResult) return nonNodeResult as never;
		return realSpawnSync(command, args, { ...(options ?? {}), encoding: "utf8", env: sandboxedEnv() } as never);
	}) as never);
	return seen;
}

async function useSpawnMock(): Promise<void> {
	const processModule = await import("../extensions/manager/process.ts");
	processModule.__setSpawnSyncForTests(spawnSyncMock as never);
}

test("npm update and uninstall execution use configured npmCommand and scope-local cwd", async () => {
	await useSpawnMock();
	const { buildInventory } = await import("../extensions/manager/inventory.ts");
	const { planUninstall, planUpdate, runUninstall, runUpdate } = await import("../extensions/manager/actions.ts");
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const npmDir = join(userPi, "npm");
	const packageDir = join(npmDir, "node_modules", "@scope", "pkg");
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), {
		npmCommand: ["mise", "exec", "node@22.19", "--", "npm"],
		packages: ["npm:@scope/pkg"],
	});
	writePackage(packageDir, "@scope/pkg");
	const inv = buildInventory({} as never, { cwd: project } as never);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/pkg")!;
	item.updateAvailable = true;
	item.updateSource = "npm";
	item.npmName = "@scope/pkg";

	const update = planUpdate(item, inv, { cwd: project } as never)!;
	expect(update.command).toContain("'mise' 'exec' 'node@22.19' '--' 'npm' install @scope/pkg@latest");
	expect(runUpdate(update).ok).toBe(true);
	expect(spawnSyncMock).toHaveBeenLastCalledWith("mise", ["exec", "node@22.19", "--", "npm", "install", "@scope/pkg@latest"], expect.objectContaining({ cwd: npmDir }));

	const uninstall = planUninstall(item, inv, { cwd: project } as never)!;
	expect(uninstall.command).toContain("'mise' 'exec' 'node@22.19' '--' 'npm' uninstall @scope/pkg");
	expect(runUninstall(uninstall, inv).ok).toBe(true);
	expect(spawnSyncMock).toHaveBeenLastCalledWith("mise", ["exec", "node@22.19", "--", "npm", "uninstall", "@scope/pkg"], expect.objectContaining({ cwd: npmDir }));
});

test("npm update reports cwd preparation failures", async () => {
	await useSpawnMock();
	const { runUpdate } = await import("../extensions/manager/actions.ts");
	const badCwd = join(rootTmp, "not-a-directory");
	writeFileSync(badCwd, "file blocks mkdir");
	spawnSyncMock.mockClear();
	const result = runUpdate({
		item: { id: "package:@scope/pkg", displayName: "Pkg", kind: "package", state: "active", stateReason: "", description: "", provider: "npm", scope: "user", sourcePath: "", sourceName: "npm:@scope/pkg", packageName: "@scope/pkg" },
		method: { kind: "npm", npmName: "@scope/pkg", scope: "user", cwd: badCwd, command: "npm", argsPrefix: [] },
		command: "npm install @scope/pkg@latest",
		description: "",
	});
	expect(result.ok).toBe(false);
	expect(result.message).toContain("Failed to prepare npm working directory");
	expect(spawnSyncMock).not.toHaveBeenCalled();
});

test("invalid npmCommand is surfaced in npm action plans", async () => {
	await useSpawnMock();
	const { buildInventory } = await import("../extensions/manager/inventory.ts");
	const { planUpdate } = await import("../extensions/manager/actions.ts");
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const packageDir = join(userPi, "npm", "node_modules", "@scope", "bad-command");
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), { npmCommand: "npm", packages: ["npm:@scope/bad-command"] });
	writePackage(packageDir, "@scope/bad-command");
	const inv = buildInventory({} as never, { cwd: project } as never);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/bad-command")!;
	item.updateAvailable = true;
	item.updateSource = "npm";
	item.npmName = "@scope/bad-command";
	const plan = planUpdate(item, inv, { cwd: project } as never)!;
	expect(plan.description).toContain("invalid npmCommand");
});

// The strip has to precede `npm uninstall`: npm 7+ does not reliably run a
// removed package's own preuninstall, and the script that owns the block is
// deleted with the tree.
test("npm uninstall strips the APPEND_SYSTEM.md block before npm runs", async () => {
	const { buildInventory } = await import("../extensions/manager/inventory.ts");
	const { planUninstall, runUninstall } = await import("../extensions/manager/actions.ts");
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const packageDir = join(userPi, "npm", "node_modules", "@scope", "appendpkg");
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), { packages: ["npm:@scope/appendpkg"] });
	writeAppendSystemPackage(packageDir, "@scope/appendpkg");
	const target = join(userPi, "APPEND_SYSTEM.md");

	// Real script, real block, so "the block is gone" is a filesystem fact.
	expect(runVendoredScript(packageDir, "install").status).toBe(0);
	expect(readFileSync(target, "utf8")).toContain("Append pkg instructions");

	// npm fails; the append-system spawn passes through to the real node.
	const seen = await useSandboxedSpawn({ status: 1, stdout: "", stderr: "npm ERR! network", error: undefined, signal: null, output: [], pid: 0 });

	const inv = buildInventory({} as never, { cwd: project } as never);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/appendpkg")!;
	const plan = planUninstall(item, inv, { cwd: project } as never)!;
	const outcome = runUninstall(plan, inv);

	const removeIndex = seen.findIndex((call) => call.command === "node" && call.args.at(-1) === "remove");
	const npmIndex = seen.findIndex((call) => call.args.includes("uninstall"));
	expect(removeIndex).toBeGreaterThanOrEqual(0);
	expect(npmIndex).toBeGreaterThanOrEqual(0);
	expect(removeIndex).toBeLessThan(npmIndex);

	expect(outcome.ok).toBe(false);

	// A package-supplied script runs on Pi's TUI thread; an unbounded wait
	// wedges it. spawnSync only honours a deadline it is given.
	const nodeCalls = seen.filter((call) => call.command === "node");
	expect(nodeCalls.length).toBeGreaterThan(0);
	for (const { options } of nodeCalls) {
		expect(typeof options.timeout).toBe("number");
		expect(options.timeout as number).toBeGreaterThan(0);
		expect(options.killSignal).toBe("SIGKILL");
	}
});

test("toggling a package under the kendex packages/ layout writes and removes its block", async () => {
	const { buildInventory } = await import("../extensions/manager/inventory.ts");
	const { toggleItem } = await import("../extensions/manager/actions.ts");
	const project = join(rootTmp, "project");
	const projectPi = join(project, ".pi");
	const packageDir = join(projectPi, "packages", "@scope", "clonepkg");
	writeJson(join(projectPi, "settings.json"), { packages: ["packages/@scope/clonepkg"] });
	writeAppendSystemPackage(packageDir, "@scope/clonepkg");
	const target = join(projectPi, "APPEND_SYSTEM.md");
	const ctx = { cwd: project, isProjectTrusted: () => true, ui: { notify() {} } } as never;
	await useSandboxedSpawn();

	const off = buildInventory({} as never, ctx);
	toggleItem({} as never, ctx, off, off.packages.find((pkg) => pkg.packageName === "@scope/clonepkg")!);
	expect(existsSync(target) ? readFileSync(target, "utf8") : "").not.toContain("Append pkg instructions");

	const on = buildInventory({} as never, ctx);
	toggleItem({} as never, ctx, on, on.packages.find((pkg) => pkg.packageName === "@scope/clonepkg")!);
	expect(readFileSync(target, "utf8")).toContain("Append pkg instructions");
});
