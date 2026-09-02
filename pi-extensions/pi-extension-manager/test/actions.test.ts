import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { spawnSync as realSpawnSync } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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
test("npm uninstall strips the APPEND_SYSTEM.md block before npm runs, and restores it when npm fails", async () => {
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
	// npm left the package installed, so the block has to be back.
	expect(readFileSync(target, "utf8")).toContain("Append pkg instructions");

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

// The four sites the failure boolean reaches. Each was a surviving mutant.
test("a failed append-system strip is reported at every uninstall and toggle site", async () => {
	const { buildInventory } = await import("../extensions/manager/inventory.ts");
	const { planUninstall, runUninstall, toggleItem } = await import("../extensions/manager/actions.ts");
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const packageDir = join(userPi, "npm", "node_modules", "@scope", "failpkg");
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), { packages: ["npm:@scope/failpkg"] });
	writeAppendSystemPackage(packageDir, "@scope/failpkg");
	// A script that reports a problem the way the real one does: exit 0, its
	// own prefix on stderr.
	writeFileSync(join(packageDir, "scripts", "append-system.mjs"), 'console.error("append-system.mjs: unable to resolve Pi scope");\n');

	await useSandboxedSpawn({ status: 0, stdout: "", stderr: "", error: undefined, signal: null, output: [], pid: 0 });

	// Toggle: the notice says the block was not written.
	const notices: string[] = [];
	const ctx = { cwd: project, ui: { notify: (text: string) => notices.push(text) } } as never;
	const toggleInv = buildInventory({} as never, ctx);
	toggleItem({} as never, ctx, toggleInv, toggleInv.packages.find((pkg) => pkg.packageName === "@scope/failpkg")!);
	expect(notices.join(" ")).toContain("APPEND_SYSTEM.md block could not be");

	// Orphan branch: the dir is still on disk, so the message says retry.
	const inv = buildInventory({} as never, { cwd: project } as never);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/failpkg")!;
	const orphanOutcome = runUninstall({ item, method: { kind: "settings-only" } } as never, inv);
	expect(orphanOutcome.message).toContain("still on disk, so retry");

	// npm succeeds and deletes the tree, so the stale block is permanent.
	const outcome = runUninstall(planUninstall(item, inv, { cwd: project } as never)!, inv);
	expect(outcome.ok).toBe(true);
	expect(outcome.message).toContain("could not be removed before the package tree was deleted");
});

// runCommand inherits the environment, so node's own stderr is not a verdict.
test("node chatter on stderr is not read as an append-system failure", async () => {
	const { buildInventory } = await import("../extensions/manager/inventory.ts");
	const { toggleItem } = await import("../extensions/manager/actions.ts");
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const packageDir = join(userPi, "npm", "node_modules", "@scope", "noisypkg");
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), { packages: ["npm:@scope/noisypkg"] });
	writeAppendSystemPackage(packageDir, "@scope/noisypkg");
	// After the shebang: a #! line anywhere else is a syntax error.
	const real = readFileSync(join(packageDir, "scripts", "append-system.mjs"), "utf8").split("\n");
	real.splice(1, 0, 'console.error("(node:1) ExperimentalWarning: nothing to see here");');
	writeFileSync(join(packageDir, "scripts", "append-system.mjs"), real.join("\n"));

	await useSandboxedSpawn();
	const notices: string[] = [];
	const ctx = { cwd: project, ui: { notify: (text: string) => notices.push(text) } } as never;
	const inv = buildInventory({} as never, ctx);
	toggleItem({} as never, ctx, inv, inv.packages.find((pkg) => pkg.packageName === "@scope/noisypkg")!);
	expect(notices.join(" ")).not.toContain("APPEND_SYSTEM.md block could not be");
});

// A disabled package has no block; restoring one would write back instructions
// the user switched off.
test("a failed npm uninstall does not restore the block of a disabled package", async () => {
	const { buildInventory } = await import("../extensions/manager/inventory.ts");
	const { planUninstall, runUninstall } = await import("../extensions/manager/actions.ts");
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const packageDir = join(userPi, "npm", "node_modules", "@scope", "offpkg");
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), {
		packages: ["npm:@scope/offpkg"],
		kendex: { extensionManager: { disabledItems: ["package:@scope/offpkg"] } },
	});
	writeAppendSystemPackage(packageDir, "@scope/offpkg");
	const target = join(userPi, "APPEND_SYSTEM.md");

	await useSandboxedSpawn({ status: 1, stdout: "", stderr: "npm ERR! network", error: undefined, signal: null, output: [], pid: 0 });

	const inv = buildInventory({} as never, { cwd: project } as never);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/offpkg")!;
	expect(item.state === "disabled" || inv.managerState.disabledItems.includes(item.id)).toBe(true);
	const outcome = runUninstall(planUninstall(item, inv, { cwd: project } as never)!, inv);

	expect(outcome.ok).toBe(false);
	expect(existsSync(target) ? readFileSync(target, "utf8") : "").not.toContain("Append pkg instructions");
});

// The branch DEVELOPMENT.md calls out in bold and nothing pinned: no packages/
// and no npm/node_modules/ segment above the package, so the script falls back
// to PI_CODING_AGENT_DIR and writes into the user-global system prompt.
test("a package outside any Pi-managed tree writes its block to the user-global APPEND_SYSTEM.md", async () => {
	const { buildInventory } = await import("../extensions/manager/inventory.ts");
	const { toggleItem } = await import("../extensions/manager/actions.ts");
	const project = join(rootTmp, "project");
	const projectPi = join(project, ".pi");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const packageDir = join(rootTmp, "not-pi", "lib", "@scope", "straypkg");
	mkdirSync(userPi, { recursive: true });
	writeJson(join(userPi, "settings.json"), {});
	// Start disabled so the single toggle is the enable that writes the block.
	writeJson(join(projectPi, "settings.json"), {
		packages: [packageDir],
		kendex: { extensionManager: { disabledItems: ["package:@scope/straypkg"] } },
	});
	writeAppendSystemPackage(packageDir, "@scope/straypkg");
	const ctx = { cwd: project, isProjectTrusted: () => true, ui: { notify() {} } } as never;

	await useSandboxedSpawn();
	const inv = buildInventory({} as never, ctx);
	toggleItem({} as never, ctx, inv, inv.packages.find((pkg) => pkg.packageName === "@scope/straypkg")!);

	// Not beside the package, and not in the project: the user-global file.
	expect(readFileSync(join(userPi, "APPEND_SYSTEM.md"), "utf8")).toContain("Append pkg instructions");
	expect(existsSync(join(projectPi, "APPEND_SYSTEM.md"))).toBe(false);
	expect(existsSync(join(packageDir, "APPEND_SYSTEM.md"))).toBe(false);
});

// A package that asks for a block but ships no script: the manager cannot
// write one, and the manifest is the only thing that can tell it apart from a
// package that wants no block at all.
test("a package declaring pi.appendSystem with no script is reported, not skipped silently", async () => {
	const { buildInventory } = await import("../extensions/manager/inventory.ts");
	const { toggleItem } = await import("../extensions/manager/actions.ts");
	const { syncAppendSystemForPackage } = await import("../extensions/manager/append-system.ts");
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const packageDir = join(userPi, "npm", "node_modules", "@scope", "noscriptpkg");
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), { packages: ["npm:@scope/noscriptpkg"] });
	writeAppendSystemPackage(packageDir, "@scope/noscriptpkg");
	rmSync(join(packageDir, "scripts"), { force: true, recursive: true });
	await useSandboxedSpawn();

	const notices: string[] = [];
	const ctx = { cwd: project, ui: { notify: (text: string) => notices.push(text) } } as never;
	const inv = buildInventory({} as never, ctx);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/noscriptpkg")!;
	expect(syncAppendSystemForPackage(item, false)).toBe(false);

	toggleItem({} as never, ctx, inv, item);
	expect(notices.join(" ")).toContain("APPEND_SYSTEM.md block could not be");
});

// A package that declares no block at all stays silent: the manifest read is
// what separates this from the case above.
test("a package declaring no pi.appendSystem is skipped without a warning", async () => {
	const { buildInventory } = await import("../extensions/manager/inventory.ts");
	const { syncAppendSystemForPackage } = await import("../extensions/manager/append-system.ts");
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const packageDir = join(userPi, "npm", "node_modules", "@scope", "plainpkg");
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), { packages: ["npm:@scope/plainpkg"] });
	writePackage(packageDir, "@scope/plainpkg");
	await useSandboxedSpawn();

	const inv = buildInventory({} as never, { cwd: project } as never);
	expect(syncAppendSystemForPackage(inv.packages.find((pkg) => pkg.packageName === "@scope/plainpkg")!, false)).toBe(true);
});

// npm failed AND the rewrite failed: the caller must not read "npm failed" as
// "nothing else changed".
test("a restore that itself fails is named in the uninstall message", async () => {
	const { buildInventory } = await import("../extensions/manager/inventory.ts");
	const { planUninstall, runUninstall } = await import("../extensions/manager/actions.ts");
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const packageDir = join(userPi, "npm", "node_modules", "@scope", "norestorepkg");
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), { packages: ["npm:@scope/norestorepkg"] });
	writeAppendSystemPackage(packageDir, "@scope/norestorepkg");
	writeFileSync(join(packageDir, "scripts", "append-system.mjs"), 'console.error("append-system.mjs: unable to resolve Pi scope");\n');
	await useSandboxedSpawn({ status: 1, stdout: "", stderr: "npm ERR! network", error: undefined, signal: null, output: [], pid: 0 });

	const inv = buildInventory({} as never, { cwd: project } as never);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/norestorepkg")!;
	const outcome = runUninstall(planUninstall(item, inv, { cwd: project } as never)!, inv);

	expect(outcome.ok).toBe(false);
	expect(outcome.message).toContain("could not be restored");
});

// The one write-failure the script has a handler for. Its six other
// diagnostics are pre-flight refusals where nothing was going to be written;
// this is the branch that fires when the write itself fails, and it is the
// only one whose message does not use the colon form.
test("a failed APPEND_SYSTEM.md write is reported as failed", async () => {
	const { buildInventory } = await import("../extensions/manager/inventory.ts");
	const { syncAppendSystemForPackage } = await import("../extensions/manager/append-system.ts");
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const packageDir = join(userPi, "npm", "node_modules", "@scope", "readonlypkg");
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), { packages: ["npm:@scope/readonlypkg"] });
	writeAppendSystemPackage(packageDir, "@scope/readonlypkg");
	await useSandboxedSpawn();

	const inv = buildInventory({} as never, { cwd: project } as never);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/readonlypkg")!;
	chmodSync(userPi, 0o555);
	try {
		expect(syncAppendSystemForPackage(item, false)).toBe(false);
		expect(existsSync(join(userPi, "APPEND_SYSTEM.md"))).toBe(false);
	} finally {
		chmodSync(userPi, 0o755);
	}
});

// spawnSync sets error ETIMEDOUT and a signal when it kills on the deadline,
// so the two failure causes have to be told apart by more than result.error.
test("a killed script is reported as the deadline, a missing one as a launch failure", async () => {
	const { syncAppendSystemForPackage } = await import("../extensions/manager/append-system.ts");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const packageDir = join(userPi, "npm", "node_modules", "@scope", "slowpkg");
	writeAppendSystemPackage(packageDir, "@scope/slowpkg");
	const item = { kind: "package", packageName: "@scope/slowpkg", packageDir } as never;

	const warnings: string[] = [];
	const warn = console.warn;
	console.warn = (text: string) => warnings.push(text);
	try {
		const processModule = await import("../extensions/manager/process.ts");
		const timedOut = Object.assign(new Error("spawnSync node ETIMEDOUT"), { code: "ETIMEDOUT" });
		processModule.__setSpawnSyncForTests((() => ({ status: null, stdout: "", stderr: "", error: timedOut, signal: "SIGKILL", output: [], pid: 0 })) as never);
		expect(syncAppendSystemForPackage(item, false)).toBe(false);
		expect(warnings.at(-1)).toContain("exceeded");

		const missing = Object.assign(new Error("spawnSync node ENOENT"), { code: "ENOENT" });
		processModule.__setSpawnSyncForTests((() => ({ status: null, stdout: "", stderr: "", error: missing, signal: null, output: [], pid: 0 })) as never);
		expect(syncAppendSystemForPackage(item, false)).toBe(false);
		expect(warnings.at(-1)).toContain("failed to launch");
	} finally {
		console.warn = warn;
	}
});

