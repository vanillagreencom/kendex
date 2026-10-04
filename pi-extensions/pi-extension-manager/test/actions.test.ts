import { afterEach, beforeEach, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { clearPackageConfigCache } from "../extensions/manager/package-config.ts";
import { mutantManager, processAlive, settleWithin, startedPid, writeCommand } from "./fixtures/commands.ts";

type ActionsModule = typeof import("../extensions/manager/actions.ts");
type InventoryModule = typeof import("../extensions/manager/inventory.ts");

const rootTmp = join(import.meta.dir, "..", "tmp", "actions-test");
const bin = join(rootTmp, "bin");
const nodePath = Bun.which("node");
const originalEnv = { HOME: process.env.HOME, PATH: process.env.PATH, PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR };
// Processes a case started and its control may leave running.
const leftovers: number[] = [];
// A case with a mutant control runs real waits on two copies, past bun's 5 s default bound.
const CONTROL_CASE_MS = 20_000;

function restore(name: keyof typeof originalEnv): void {
	if (originalEnv[name] === undefined) delete process.env[name];
	else process.env[name] = originalEnv[name];
}

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
	if (!nodePath) throw new Error("actions-test: node is not on PATH");
	rmSync(rootTmp, { recursive: true, force: true });
	mkdirSync(bin, { recursive: true });
	// Every command the manager starts inherits the live environment, so the
	// child's HOME, Pi directory and PATH are pinned here.
	process.env.HOME = join(rootTmp, "home");
	process.env.PI_CODING_AGENT_DIR = join(rootTmp, "home", ".pi", "agent");
	process.env.PATH = [dirname(nodePath), "/usr/bin", "/bin"].join(":");
	clearPackageConfigCache();
});

afterEach(() => {
	for (const pid of leftovers.splice(0)) {
		try { process.kill(-pid, "SIGKILL"); } catch {}
	}
	rmSync(rootTmp, { recursive: true, force: true });
	for (const name of ["HOME", "PATH", "PI_CODING_AGENT_DIR"] as const) restore(name);
	clearPackageConfigCache();
});

function live(): AbortSignal {
	return new AbortController().signal;
}

function runVendoredScript(packageDir: string, action: string) {
	return spawnSync("node", [join(packageDir, "scripts", "append-system.mjs"), action], { encoding: "utf8", env: { PATH: process.env.PATH, HOME: process.env.HOME, PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR } });
}

const looseItem = { id: "package:@scope/pkg", displayName: "Pkg", kind: "package", state: "active", stateReason: "", description: "", provider: "npm", scope: "user", sourcePath: "", sourceName: "npm:@scope/pkg", packageName: "@scope/pkg" };

function npmMethod(command: string, cwd = rootTmp) {
	return { kind: "npm", npmName: "@scope/pkg", scope: "user", cwd, command, argsPrefix: [] };
}

test("npm update and uninstall execution use configured npmCommand and scope-local cwd", async () => {
	const { buildInventory } = await import("../extensions/manager/inventory.ts");
	const { planUninstall, planUpdate, runUninstall, runUpdate } = await import("../extensions/manager/actions.ts");
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const npmDir = join(userPi, "npm");
	const log = join(rootTmp, "mise.log");
	const mise = writeCommand(join(bin, "mise"), `printf '%s|%s\\n' "$(pwd -P)" "$*" >> "${log}"`);
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), {
		npmCommand: [mise, "exec", "node@22.19", "--", "npm"],
		packages: ["npm:@scope/pkg"],
	});
	writePackage(join(npmDir, "node_modules", "@scope", "pkg"), "@scope/pkg");
	const inv = await buildInventory({} as never, { cwd: project } as never);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/pkg")!;
	item.updateAvailable = true;
	item.updateSource = "npm";
	item.npmName = "@scope/pkg";

	const update = planUpdate(item, inv, { cwd: project } as never)!;
	expect(update.command).toContain("'exec' 'node@22.19' '--' 'npm' install @scope/pkg@latest");
	const updated = await runUpdate(update, live());
	expect([updated.ok, updated.message.split("\n")[0]]).toEqual([true, "pi-extension-manager: npm-updated=@scope/pkg"]);

	const uninstall = planUninstall(item, inv, { cwd: project } as never)!;
	expect(uninstall.command).toContain("'exec' 'node@22.19' '--' 'npm' uninstall @scope/pkg");
	const removed = await runUninstall(uninstall, inv, live());
	expect([removed.ok, removed.message.split("\n")[0]]).toEqual([true, "pi-extension-manager: npm-uninstalled=@scope/pkg"]);
	const cwd = realpathSync(npmDir);
	expect(readFileSync(log, "utf8").trim().split("\n")).toEqual([
		`${cwd}|exec node@22.19 -- npm install @scope/pkg@latest`,
		`${cwd}|exec node@22.19 -- npm uninstall @scope/pkg`,
	]);
});

test("npm actions report cwd preparation failures", async () => {
	const { runUninstall, runUpdate } = await import("../extensions/manager/actions.ts");
	const badCwd = join(rootTmp, "not-a-directory");
	writeFileSync(badCwd, "file blocks mkdir");
	const marker = join(rootTmp, "npm-ran");
	const method = npmMethod(writeCommand(join(bin, "npm"), `touch "${marker}"`), badCwd);
	const rows = [
		{ run: () => runUpdate({ item: looseItem, method } as never, live()), firstLine: `pi-extension-manager: npm-update-cwd=${badCwd}` },
		{ run: () => runUninstall({ item: looseItem, method } as never, { settingsFiles: [] } as never, live()), firstLine: `pi-extension-manager: npm-uninstall-cwd=${badCwd}` },
	];
	for (const row of rows) {
		const result = await row.run();
		expect([result.ok, result.message.split("\n")[0]]).toEqual([false, row.firstLine]);
	}
	expect(existsSync(marker)).toBe(false);
});

test("invalid npmCommand is surfaced in npm action plans", async () => {
	const { buildInventory } = await import("../extensions/manager/inventory.ts");
	const { planUninstall, planUpdate } = await import("../extensions/manager/actions.ts");
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const packageDir = join(userPi, "npm", "node_modules", "@scope", "bad-command");
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), { npmCommand: "npm", packages: ["npm:@scope/bad-command"] });
	writePackage(packageDir, "@scope/bad-command");
	const inv = await buildInventory({} as never, { cwd: project } as never);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/bad-command")!;
	item.updateAvailable = true;
	item.updateSource = "npm";
	item.npmName = "@scope/bad-command";
	const plans = [planUpdate(item, inv, { cwd: project } as never)!, planUninstall(item, inv, { cwd: project } as never)!];
	for (const plan of plans) {
		expect(plan.description.split("\n")[0]).toBe("pi-extension-manager: npm-command-invalid=user");
		expect(plan.description.split("\n")).toHaveLength(3);
	}
});

interface BlockObservation { ok: boolean; firstLine: string; blockSeenByNpm: boolean; blockAfter: boolean }

/**
 * Uninstall an npm package that owns an APPEND_SYSTEM.md block, with an npm
 * that records the block as it finds it and then runs `npmTail`. With
 * `cancelAfterStart`, the uninstall is cancelled once npm writes that pid file.
 */
async function uninstallWithBlock(actions: ActionsModule, inventory: InventoryModule, npmTail: string, cancelAfterStart?: string): Promise<BlockObservation | "unsettled"> {
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const packageDir = join(userPi, "npm", "node_modules", "@scope", "appendpkg");
	const target = join(userPi, "APPEND_SYSTEM.md");
	const seenByNpm = join(rootTmp, `append-system-seen-by-npm-${Math.random()}`);
	const npm = writeCommand(join(bin, `npm-${Math.random()}`), `cat "${target}" > "${seenByNpm}"; ${npmTail}`);
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(join(userPi, "settings.json"), { npmCommand: [npm], packages: ["npm:@scope/appendpkg"] });
	writeAppendSystemPackage(packageDir, "@scope/appendpkg");
	clearPackageConfigCache();
	// Real script, real block, so "the block is there" is a filesystem fact.
	expect(runVendoredScript(packageDir, "install").status).toBe(0);
	expect(readFileSync(target, "utf8")).toContain("Append pkg instructions");

	const inv = await inventory.buildInventory({} as never, { cwd: project } as never);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/appendpkg")!;
	const cancel = new AbortController();
	const run = actions.runUninstall(actions.planUninstall(item, inv, { cwd: project } as never)!, inv, cancel.signal);
	if (cancelAfterStart) {
		leftovers.push(await startedPid(cancelAfterStart));
		cancel.abort();
	}
	// A cancelled npm settles within the runner's SIGTERM grace, then the
	// restore runs one short script.
	const outcome = await settleWithin(run, 6_000);
	if (outcome === "unsettled") return outcome;
	return {
		ok: outcome.ok,
		firstLine: outcome.message.split("\n")[0]!.split("=")[0]!,
		blockSeenByNpm: readFileSync(seenByNpm, "utf8").includes("Append pkg instructions"),
		// The script deletes the file once its last block goes.
		blockAfter: existsSync(target) && readFileSync(target, "utf8").includes("Append pkg instructions"),
	};
}

// The strip has to precede `npm uninstall`: npm 7+ does not reliably run a
// removed package's own preuninstall, and the script that owns the block is
// deleted with the tree. An uninstall that then fails leaves the package
// installed, so its block goes back.
test("npm uninstall strips the block before npm runs and restores it when npm fails or is cancelled; control: no restore leaves it gone", async () => {
	const real = [await import("../extensions/manager/actions.ts"), await import("../extensions/manager/inventory.ts")] as const;
	const pidFile = join(rootTmp, "npm-pid");
	const rows = [
		{ npmTail: 'echo "npm ERR! network" >&2; exit 1', cancelAfterStart: undefined, firstLine: "pi-extension-manager: npm-uninstall-exit" },
		{ npmTail: `echo $$ > "${pidFile}"; exec sleep 30`, cancelAfterStart: pidFile, firstLine: "pi-extension-manager: npm-uninstall-cancelled" },
	];
	for (const row of rows) {
		expect(await uninstallWithBlock(...real, row.npmTail, row.cancelAfterStart)).toEqual({ ok: false, firstLine: row.firstLine, blockSeenByNpm: false, blockAfter: true });
	}

	const mutant = mutantManager(join(rootTmp, "mutant-restore"), [{
		file: "actions.ts",
		before: "const restore = await restoreAppendSystemBlockAfterUninstall(item);",
		after: 'const restore = { kind: "ran" } as const;',
	}]);
	const planted = await uninstallWithBlock(await import(join(mutant, "actions.ts")), await import(join(mutant, "inventory.ts")), "exit 1");
	expect(planted === "unsettled" ? planted : planted.blockAfter).toBe(false);
}, CONTROL_CASE_MS);

type RemovalObservation = { settled: "resolved"; ok: boolean; firstLine: string; settingsKept: boolean; npmRan: boolean; restored: boolean } | { settled: "rejected"; error: string } | "unsettled";

/** An npm uninstall cancelled while the package's own removal script hangs. */
async function cancelHungRemoval(actions: ActionsModule, inventory: InventoryModule): Promise<RemovalObservation> {
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const settingsPath = join(userPi, "settings.json");
	const packageDir = join(userPi, "npm", "node_modules", "@scope", "hungscript");
	const pidFile = join(rootTmp, `script-pid-${Math.random()}`);
	const restoredMarker = join(rootTmp, `restored-${Math.random()}`);
	const npmMarker = join(rootTmp, `npm-ran-${Math.random()}`);
	writeAppendSystemPackage(packageDir, "@scope/hungscript");
	writeFileSync(join(packageDir, "scripts", "append-system.mjs"), [
		'import { writeFileSync } from "node:fs";',
		`if (process.argv[2] === "remove") { writeFileSync(${JSON.stringify(pidFile)}, String(process.pid)); setInterval(() => {}, 1000); }`,
		`else writeFileSync(${JSON.stringify(restoredMarker)}, process.argv[2]);`,
	].join("\n"));
	const npm = writeCommand(join(bin, `npm-${Math.random()}`), `touch "${npmMarker}"`);
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(settingsPath, { npmCommand: [npm], packages: ["npm:@scope/hungscript"] });
	clearPackageConfigCache();
	const inv = await inventory.buildInventory({} as never, { cwd: project } as never);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/hungscript")!;
	const settingsBefore = readFileSync(settingsPath, "utf8");
	const cancel = new AbortController();
	const run = actions.runUninstall(actions.planUninstall(item, inv, { cwd: project } as never)!, inv, cancel.signal);
	leftovers.push(await startedPid(pidFile));
	cancel.abort();
	// The script's own deadline is 10 s; a cancelled one ends inside the 2 s
	// SIGTERM grace, so a run still going at this bound never saw the cancel.
	const outcome = await settleWithin(run.then((value) => ({ value }), (error: unknown) => ({ error: String(error) })), 5_000);
	if (outcome === "unsettled") return outcome;
	if ("error" in outcome) return { settled: "rejected", error: outcome.error.split("\n")[0]! };
	return {
		settled: "resolved",
		ok: outcome.value.ok,
		firstLine: outcome.value.message.split("\n")[0]!,
		settingsKept: readFileSync(settingsPath, "utf8") === settingsBefore,
		npmRan: existsSync(npmMarker),
		restored: existsSync(restoredMarker) && readFileSync(restoredMarker, "utf8") === "install",
	};
}

test("cancelling during the block removal returns a cancelled notice and restores the block; controls: a fresh signal or a thrown cancel", async () => {
	const real = await cancelHungRemoval(await import("../extensions/manager/actions.ts"), await import("../extensions/manager/inventory.ts"));
	const script = join(process.env.PI_CODING_AGENT_DIR!, "npm", "node_modules", "@scope", "hungscript", "scripts", "append-system.mjs");
	expect(real).toEqual({ settled: "resolved", ok: false, firstLine: `pi-extension-manager: append-system-cancelled=remove:${script}`, settingsKept: true, npmRan: false, restored: true });

	const rows = [
		{ file: "append-system.ts", before: 'runAppendSystemScript(item.packageDir, "remove", signal)', after: 'runAppendSystemScript(item.packageDir, "remove", new AbortController().signal)', expected: "unsettled" },
		{ file: "actions.ts", before: 'if (removal.reason === "cancelled") return', after: 'if (removal.reason === "cancelled" && false) return', expected: "rejected" },
	] as const;
	for (const [index, row] of rows.entries()) {
		const mutant = mutantManager(join(rootTmp, `mutant-removal-${index}`), [{ file: row.file, before: row.before, after: row.after }]);
		const planted = await cancelHungRemoval(await import(join(mutant, "actions.ts")), await import(join(mutant, "inventory.ts")));
		expect({ file: row.file, settled: planted === "unsettled" ? planted : planted.settled }).toEqual({ file: row.file, settled: row.expected });
	}
}, 30_000);

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

	const off = await buildInventory({} as never, ctx);
	await toggleItem({} as never, ctx, off, off.packages.find((pkg) => pkg.packageName === "@scope/clonepkg")!, live());
	expect(existsSync(target) ? readFileSync(target, "utf8") : "").not.toContain("Append pkg instructions");

	const on = await buildInventory({} as never, ctx);
	await toggleItem({} as never, ctx, on, on.packages.find((pkg) => pkg.packageName === "@scope/clonepkg")!, live());
	expect(readFileSync(target, "utf8")).toContain("Append pkg instructions");
});

test("append-system launch failures expose the action and script path", async () => {
	const packageDir = join(rootTmp, "append-launch");
	mkdirSync(join(packageDir, "scripts"), { recursive: true });
	writeFileSync(join(packageDir, "scripts", "append-system.mjs"), "");
	const { syncAppendSystemForPackage } = await import("../extensions/manager/append-system.ts");
	// No directory on PATH holds node.
	process.env.PATH = bin;
	await expect(syncAppendSystemForPackage({ kind: "package", packageName: "@scope/append", packageDir } as never, false, live()))
		.rejects.toThrow(`pi-extension-manager: append-system-launch=install:${join(packageDir, "scripts", "append-system.mjs")}`);
});

test("failed instruction scripts keep toggle and orphan settings unchanged", async () => {
	const { buildInventory } = await import("../extensions/manager/inventory.ts");
	const { planUninstall, runUninstall, toggleItem } = await import("../extensions/manager/actions.ts");
	for (const action of ["disable", "enable", "orphan"] as const) {
		const project = join(rootTmp, action);
		const packageDir = join(project, ".pi", "packages", "blocked");
		const source = "./packages/blocked";
		const settingsPath = join(project, ".pi", "settings.json");
		writeJson(settingsPath, { packages: action === "enable" ? [{ source, extensions: [] }] : [source] });
		writeAppendSystemPackage(packageDir, "@scope/blocked");
		expect(runVendoredScript(packageDir, "install").status).toBe(0);
		const appendPath = join(project, ".pi", "APPEND_SYSTEM.md");
		const instructionsBefore = readFileSync(appendPath, "utf8");
		writeFileSync(join(packageDir, "scripts", "append-system.mjs"), "process.exit(7);\n");
		const ctx = { cwd: project, isProjectTrusted: () => true, ui: { notify() {} } } as never;
		const inv = await buildInventory({} as never, ctx);
		const item = inv.packages.find((pkg) => pkg.packageName === "@scope/blocked")!;
		const diskBefore = readFileSync(settingsPath, "utf8");
		const memoryBefore = JSON.stringify(inv);
		await expect(action === "orphan"
			? runUninstall(planUninstall(item, inv, ctx)!, inv, live())
			: toggleItem({} as never, ctx, inv, item, live())).rejects.toThrow("pi-extension-manager: append-system-exit=");
		expect(readFileSync(settingsPath, "utf8")).toBe(diskBefore);
		expect(JSON.stringify(inv)).toBe(memoryBefore);
		expect(readFileSync(appendPath, "utf8")).toBe(instructionsBefore);
	}
});

test("npm action exits expose an exit code or signal", async () => {
	const { runUninstall, runUpdate } = await import("../extensions/manager/actions.ts");
	const rows = [
		{ body: "exit 7", run: (plan: never) => runUpdate(plan, live()), firstLine: "pi-extension-manager: npm-update-exit=7" },
		{ body: "kill -TERM $$", run: (plan: never) => runUninstall(plan, { settingsFiles: [] } as never, live()), firstLine: "pi-extension-manager: npm-uninstall-exit=SIGTERM" },
	];
	for (const [index, row] of rows.entries()) {
		const method = npmMethod(writeCommand(join(bin, `npm-${index}`), row.body));
		const outcome = await row.run({ item: looseItem, method } as never);
		expect([outcome.ok, outcome.message.split("\n")[0]]).toEqual([false, row.firstLine]);
	}
});

test("npm action launch failures identify the action", async () => {
	const { runUninstall, runUpdate } = await import("../extensions/manager/actions.ts");
	const missing = join(bin, "missing-npm");
	const method = npmMethod(missing);
	const rows = [
		{ outcome: await runUpdate({ item: looseItem, method } as never, live()), firstLine: `pi-extension-manager: npm-update-launch=${missing}` },
		{ outcome: await runUninstall({ item: looseItem, method } as never, { settingsFiles: [] } as never, live()), firstLine: `pi-extension-manager: npm-uninstall-launch=${missing}` },
	];
	for (const row of rows) expect([row.outcome.ok, row.outcome.message.split("\n")[0]]).toEqual([false, row.firstLine]);
});

interface UninstallObservation { ok: boolean; firstLine: string; diskKept: boolean; memoryKept: boolean }

/** An npm uninstall whose npm dies by `npmBody`, observed through the given module copies. */
async function observeFailedUninstall(actions: ActionsModule, inventory: InventoryModule, npmBody: string, cancelAfterStart?: string): Promise<UninstallObservation | "unsettled"> {
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const settingsPath = join(userPi, "settings.json");
	const npm = writeCommand(join(bin, `npm-${Math.random()}`), npmBody);
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeJson(settingsPath, { npmCommand: [npm], packages: ["npm:@scope/crash"] });
	writePackage(join(userPi, "npm", "node_modules", "@scope", "crash"), "@scope/crash");
	clearPackageConfigCache();
	const inv = await inventory.buildInventory({} as never, { cwd: project } as never);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/crash")!;
	const diskBefore = readFileSync(settingsPath, "utf8");
	const memoryBefore = JSON.stringify(inv);
	const cancel = new AbortController();
	const run = actions.runUninstall(actions.planUninstall(item, inv, { cwd: project } as never)!, inv, cancel.signal);
	if (cancelAfterStart) {
		leftovers.push(await startedPid(cancelAfterStart));
		cancel.abort();
	}
	// A working runner settles a crashed npm at once and a cancelled one within
	// its SIGTERM grace; a run still going at this bound ignored the cancel.
	const outcome = await settleWithin(run, 4_000);
	if (outcome === "unsettled") return outcome;
	return {
		ok: outcome.ok,
		firstLine: outcome.message.split("\n")[0]!,
		diskKept: readFileSync(settingsPath, "utf8") === diskBefore,
		memoryKept: JSON.stringify(inv) === memoryBefore,
	};
}

test("a natural-signal npm crash keeps disk and in-memory installation settings; control: an unchecked failure strips them", async () => {
	// npm's heap exhaustion ends in SIGABRT with no exit code.
	const crash = "kill -ABRT $$";
	const real = [await import("../extensions/manager/actions.ts"), await import("../extensions/manager/inventory.ts")] as const;
	expect(await observeFailedUninstall(...real, crash)).toEqual({ ok: false, firstLine: "pi-extension-manager: npm-uninstall-exit=SIGABRT", diskKept: true, memoryKept: true });

	const mutant = mutantManager(join(rootTmp, "mutant-uninstall"), [{
		file: "actions.ts",
		before: "if (npmUninstallFailure) return",
		after: "if (npmUninstallFailure && false) return",
	}]);
	const planted = await observeFailedUninstall(await import(join(mutant, "actions.ts")), await import(join(mutant, "inventory.ts")), crash);
	expect(planted === "unsettled" ? planted : [planted.ok, planted.diskKept, planted.memoryKept]).toEqual([true, false, false]);
}, CONTROL_CASE_MS);

test("cancelling an npm uninstall stops npm and keeps settings; control: a signal the runner never sees leaves it running", async () => {
	const pidFile = () => join(rootTmp, `npm-pid-${Math.random()}`);
	const hung = (path: string) => `echo $$ > "${path}"; exec sleep 30`;
	const real = [await import("../extensions/manager/actions.ts"), await import("../extensions/manager/inventory.ts")] as const;
	const realPid = pidFile();
	const observed = await observeFailedUninstall(...real, hung(realPid), realPid);
	expect(observed === "unsettled" ? observed : { ...observed, firstLine: observed.firstLine.split("=")[0] }).toEqual({ ok: false, firstLine: "pi-extension-manager: npm-uninstall-cancelled", diskKept: true, memoryKept: true });
	expect(processAlive(leftovers.at(-1)!)).toBe(false);

	const mutant = mutantManager(join(rootTmp, "mutant-cancel"), [{
		file: "actions.ts",
		before: "{ cwd, deadlineMs: PACKAGE_COMMAND_DEADLINE_MS, signal }",
		after: "{ cwd, deadlineMs: PACKAGE_COMMAND_DEADLINE_MS, signal: new AbortController().signal }",
	}]);
	const mutantPid = pidFile();
	expect(await observeFailedUninstall(await import(join(mutant, "actions.ts")), await import(join(mutant, "inventory.ts")), hung(mutantPid), mutantPid)).toBe("unsettled");
}, CONTROL_CASE_MS);
