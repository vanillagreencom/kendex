import { afterEach, beforeEach, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { clearPackageConfigCache } from "../extensions/manager/package-config.ts";
import { mutantManager, processAlive, settleWithin, startedPid, writeCommand, type SourceEdit } from "./fixtures/commands.ts";

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

interface BlockScenario {
	/** What npm does after recording the block it finds. */
	npmTail: string;
	/** Cancel the uninstall once npm writes its pid here. */
	cancelAfterStart?: string;
	/** The package is disabled, so it has no block. */
	disabled?: boolean;
	/**
	 * The restore's install: `exits` ends with code 1, `source-missing` finds no
	 * instructions, `hangs` writes its pid to `pidFile`, ignores SIGTERM and never exits.
	 */
	restore?: "exits" | "source-missing" | { kind: "hangs"; pidFile: string };
	/** Once npm writes its pid here, end the session through a host that then exits, as Pi's quit does. */
	quitAfterStart?: string;
}

interface BlockObservation { ok: boolean; firstLine: string; blockSeenByNpm: boolean; blockAfter: boolean; restoreNotice: string | null }

/**
 * Uninstall an npm package that owns an APPEND_SYSTEM.md block, with an npm
 * that records the block as it finds it and then runs `npmTail`, through the
 * manager sources in `managerDir`. `restoreNotice` is the key of the notice
 * line that says the block was not put back, or null when there is none.
 */
async function uninstallWithBlock(managerDir: string, scenario: BlockScenario): Promise<BlockObservation | "unsettled"> {
	const actions: ActionsModule = await import(join(managerDir, "actions.ts"));
	const inventory: InventoryModule = await import(join(managerDir, "inventory.ts"));
	const project = join(rootTmp, "project");
	const userPi = process.env.PI_CODING_AGENT_DIR!;
	const packageDir = join(userPi, "npm", "node_modules", "@scope", "appendpkg");
	const target = join(userPi, "APPEND_SYSTEM.md");
	const seenByNpm = join(rootTmp, `append-system-seen-by-npm-${Math.random()}`);
	const npm = writeCommand(join(bin, `npm-${Math.random()}`), `cat "${target}" > "${seenByNpm}" 2>/dev/null; ${scenario.npmTail}`);
	mkdirSync(join(project, ".pi"), { recursive: true });
	const source = "npm:@scope/appendpkg";
	writeJson(join(userPi, "settings.json"), scenario.disabled
		? { npmCommand: [npm], packages: [{ source, extensions: [] }], kendex: { extensionManager: { disabledItems: ["package:user:npm:@scope/appendpkg"] } } }
		: { npmCommand: [npm], packages: [source] });
	writeAppendSystemPackage(packageDir, "@scope/appendpkg");
	clearPackageConfigCache();
	// Real script, real block, so "the block is there" is a filesystem fact; a
	// disabled package's block went when it was disabled.
	if (!scenario.disabled) {
		expect(runVendoredScript(packageDir, "install").status).toBe(0);
		expect(readFileSync(target, "utf8")).toContain("Append pkg instructions");
	}
	const scripts = join(packageDir, "scripts");
	const restore = scenario.restore;
	if (restore === "exits" || typeof restore === "object") {
		const install = restore === "exits"
			? "process.exit(1);"
			: `process.on("SIGTERM", () => {}); (await import("node:fs")).writeFileSync(${JSON.stringify(restore.pidFile)}, String(process.pid)); setInterval(() => {}, 1_000);`;
		renameSync(join(scripts, "append-system.mjs"), join(scripts, "vendored.mjs"));
		writeFileSync(join(scripts, "append-system.mjs"), `if (process.argv[2] === "install") { ${install} }\nelse await import("./vendored.mjs");\n`);
	}
	if (scenario.restore === "source-missing") rmSync(join(packageDir, "instructions.md"));

	const inv = await inventory.buildInventory({} as never, { cwd: project } as never);
	const item = inv.packages.find((pkg) => pkg.packageName === "@scope/appendpkg")!;
	expect(item.state === "disabled").toBe(scenario.disabled === true);
	let outcome: { ok: boolean; message: string } | "unsettled";
	if (scenario.quitAfterStart) {
		outcome = quitDuringUninstall(managerDir, project, scenario.quitAfterStart);
		leftovers.push(await startedPid(scenario.quitAfterStart));
	} else {
		const cancel = new AbortController();
		const run = actions.runUninstall(actions.planUninstall(item, inv, { cwd: project } as never)!, inv, cancel.signal);
		if (scenario.cancelAfterStart) {
			leftovers.push(await startedPid(scenario.cancelAfterStart));
			cancel.abort();
		}
		// A cancelled npm settles within the runner's SIGTERM grace, then the
		// restore runs one short script.
		outcome = await settleWithin(run, 6_000);
	}
	if (outcome === "unsettled") return outcome;
	const lines = outcome.message.split("\n");
	const notice = lines.slice(1).find((line) => line.startsWith("pi-extension-manager: append-system-") || line.startsWith("append-system: "));
	return {
		ok: outcome.ok,
		firstLine: lines[0]!.split("=")[0]!,
		blockSeenByNpm: existsSync(seenByNpm) && readFileSync(seenByNpm, "utf8").includes("Append pkg instructions"),
		// The script deletes the file once its last block goes.
		blockAfter: existsSync(target) && readFileSync(target, "utf8").includes("Append pkg instructions"),
		restoreNotice: notice ? notice.split("=")[0]! : null,
	};
}

/**
 * Pi's quit: a host process runs the uninstall as session work, ends the
 * session once npm has started, awaits the shutdown and exits. The uninstall's
 * result, or `unsettled` when it had not settled by the exit.
 */
function quitDuringUninstall(managerDir: string, project: string, pidFile: string): { ok: boolean; message: string } | "unsettled" {
	const host = join(rootTmp, `quit-host-${Math.random()}.ts`);
	writeFileSync(host, [
		'import { existsSync } from "node:fs";',
		'import { join } from "node:path";',
		"const [managerDir, project, pidFile] = process.argv.slice(2);",
		'const inventory = await import(join(managerDir, "inventory.ts"));',
		'const actions = await import(join(managerDir, "actions.ts"));',
		"const pi = {};",
		"const ctx = { cwd: project };",
		"const inv = await inventory.buildInventory(pi, ctx);",
		'const item = inv.packages.find((pkg) => pkg.packageName === "@scope/appendpkg");',
		"const run = inventory.sessionWork(pi, (signal) => actions.runUninstall(actions.planUninstall(item, inv, ctx), inv, signal));",
		"while (!existsSync(pidFile)) await Bun.sleep(10);",
		"await inventory.closeInventorySession(pi);",
		"// A run that has settled wins the race over the already-resolved null.",
		"console.log(JSON.stringify((await Promise.race([run, null])) ?? \"unsettled\"));",
		"process.exit(0);",
	].join("\n"));
	const env = { PATH: process.env.PATH, HOME: process.env.HOME, PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR };
	const quit = spawnSync(process.execPath, ["--no-install", host, managerDir, project, pidFile], { encoding: "utf8", env, timeout: 20_000 });
	if (quit.status !== 0) throw new Error(`quit host exited ${quit.status ?? quit.signal}: ${quit.stderr}`);
	return JSON.parse(quit.stdout);
}

const managerSource = join(import.meta.dir, "..", "extensions", "manager");
const npmExits = 'echo "npm ERR! network" >&2; exit 1';
const npmHangs = (pidFile: string) => `echo $$ > "${pidFile}"; exec sleep 30`;

// The strip has to precede `npm uninstall`: npm 7+ does not reliably run a
// removed package's own preuninstall, and the script that owns the block is
// deleted with the tree. An uninstall that then fails leaves the package
// installed, so a block that was live goes back.
function blockRows(pidFile: string) {
	return [
		{ name: "npm exits", scenario: { npmTail: npmExits }, expected: { ok: false, firstLine: "pi-extension-manager: npm-uninstall-exit", blockSeenByNpm: false, blockAfter: true, restoreNotice: null } },
		{ name: "npm cancelled", scenario: { npmTail: npmHangs(`${pidFile}-live`), cancelAfterStart: `${pidFile}-live` }, expected: { ok: false, firstLine: "pi-extension-manager: npm-uninstall-cancelled", blockSeenByNpm: false, blockAfter: true, restoreNotice: null } },
		{ name: "disabled, npm exits", scenario: { npmTail: npmExits, disabled: true }, expected: { ok: false, firstLine: "pi-extension-manager: npm-uninstall-exit", blockSeenByNpm: false, blockAfter: false, restoreNotice: null } },
		{ name: "disabled, npm cancelled", scenario: { npmTail: npmHangs(`${pidFile}-disabled`), cancelAfterStart: `${pidFile}-disabled`, disabled: true }, expected: { ok: false, firstLine: "pi-extension-manager: npm-uninstall-cancelled", blockSeenByNpm: false, blockAfter: false, restoreNotice: null } },
		{ name: "restore exits", scenario: { npmTail: npmExits, restore: "exits" }, expected: { ok: false, firstLine: "pi-extension-manager: npm-uninstall-exit", blockSeenByNpm: false, blockAfter: false, restoreNotice: "pi-extension-manager: append-system-exit" } },
		{ name: "restore finds no source", scenario: { npmTail: npmExits, restore: "source-missing" }, expected: { ok: false, firstLine: "pi-extension-manager: npm-uninstall-exit", blockSeenByNpm: false, blockAfter: false, restoreNotice: "pi-extension-manager: append-system-notice" } },
		// npm runs in the scope's npm directory and removed the script before failing.
		{ name: "restore finds no script", scenario: { npmTail: `rm -f node_modules/@scope/appendpkg/scripts/append-system.mjs; ${npmExits}` }, expected: { ok: false, firstLine: "pi-extension-manager: npm-uninstall-exit", blockSeenByNpm: false, blockAfter: false, restoreNotice: "pi-extension-manager: append-system-gone" } },
		{ name: "session ends during npm", scenario: { npmTail: npmHangs(`${pidFile}-quit`), quitAfterStart: `${pidFile}-quit` }, expected: { ok: false, firstLine: "pi-extension-manager: npm-uninstall-cancelled", blockSeenByNpm: false, blockAfter: true, restoreNotice: null } },
	] as const;
}

test("a failed npm uninstall puts back only a block that was live, and says when it cannot", async () => {
	for (const row of blockRows(join(rootTmp, `npm-pid-${Math.random()}`))) {
		expect({ name: row.name, observed: await uninstallWithBlock(managerSource, row.scenario) }).toEqual({ name: row.name, observed: row.expected });
	}
}, CONTROL_CASE_MS);

test("restore controls: each planted gap changes what its row observes", async () => {
	const controls = [
		{ name: "no restore", row: "npm exits", file: "actions.ts", before: "const restore = await restoreAppendSystemBlockAfterUninstall(item);", after: 'const restore = { kind: "restored" } as const;' },
		{ name: "restoring a disabled package's block", row: "disabled, npm exits", file: "actions.ts", before: 'if (removal.kind === "absent" || itemDisabled(item, inventory)) return', after: 'if (removal.kind === "absent") return' },
		{ name: "dropping the not-restored line", row: "restore exits", file: "actions.ts", before: "Restoring the package's APPEND_SYSTEM.md instructions failed, so they may be missing:\\n${restore.cause}", after: "" },
		{ name: "reading an exit 0 that printed a notice as a run", row: "restore finds no source", file: "append-system.ts", before: '.some((line) => line.startsWith("append-system: "))', after: ".some(() => false)" },
		{ name: "reading a gone script as restored", row: "restore finds no script", file: "append-system.ts", before: 'return { kind: "not-restored", cause: managerNotice("append-system-gone"', after: 'return { kind: "restored", cause: managerNotice("append-system-gone"' },
		{ name: "a shutdown that does not wait for the session's work", row: "session ends during npm", file: "inventory.ts", before: "await Promise.race([Promise.all(session.running), new Promise<void>((resolve) => { bound = setTimeout(resolve, SHUTDOWN_WAIT_MS); })]);", after: "" },
	] as const;
	for (const [index, control] of controls.entries()) {
		const row = blockRows(join(rootTmp, `npm-pid-${Math.random()}`)).find((entry) => entry.name === control.row)!;
		const mutant = mutantManager(join(rootTmp, `mutant-restore-${index}`), [{ file: control.file, before: control.before, after: control.after }]);
		const observed = await uninstallWithBlock(mutant, row.scenario);
		expect({ name: control.name, differs: !Bun.deepEquals(observed, row.expected) }).toEqual({ name: control.name, differs: true });
	}
}, 30_000);

test("quitting during an uninstall whose npm and restore ignore SIGTERM ends the restore before exit; control: a bound without the restore's stop", async () => {
	const quit = async (managerDir: string) => {
		const npmPid = join(rootTmp, `npm-pid-${Math.random()}`);
		const restorePid = join(rootTmp, `restore-pid-${Math.random()}`);
		const observed = await uninstallWithBlock(managerDir, { npmTail: `trap "" TERM; ${npmHangs(npmPid)}`, quitAfterStart: npmPid, restore: { kind: "hangs", pidFile: restorePid } });
		const pid = await startedPid(restorePid);
		leftovers.push(pid);
		// A killed restore is reaped by its new parent asynchronously; one that
		// never got SIGKILL is still running at this bound.
		const until = Date.now() + 1_000;
		while (processAlive(pid) && Date.now() < until) await Bun.sleep(20);
		return { observed, restoreAlive: processAlive(pid) };
	};
	expect(await quit(managerSource)).toEqual({
		observed: { ok: false, firstLine: "pi-extension-manager: npm-uninstall-cancelled", blockSeenByNpm: false, blockAfter: false, restoreNotice: "pi-extension-manager: append-system-timeout" },
		restoreAlive: false,
	});
	const mutant = mutantManager(join(rootTmp, "mutant-shutdown-bound"), [{ file: "inventory.ts", before: "const SHUTDOWN_WAIT_MS = STOP_SETTLE_MS + APPEND_SYSTEM_DEADLINE_MS + STOP_SETTLE_MS;", after: "const SHUTDOWN_WAIT_MS = STOP_SETTLE_MS + APPEND_SYSTEM_DEADLINE_MS;" }]);
	expect((await quit(mutant)).restoreAlive).toBe(true);
}, 45_000);

type RemovalObservation = { settled: "resolved"; ok: boolean; firstLine: string; settingsKept: boolean; npmRan: boolean; restored: boolean } | { settled: "rejected"; error: string } | "unsettled";

// The vendored script's notice when APPEND_SYSTEM.md is read-only; it still exits 0.
const removalNotice = 'console.error(\'append-system: operation="remove:@scope/hungscript:EACCES"\'); console.error("Unable to update APPEND_SYSTEM.md: EACCES");';

/**
 * An npm uninstall whose package's own removal script fails: it hangs until the
 * uninstall is cancelled or reaches its deadline, or exits 0 after a notice.
 */
async function failedRemoval(actions: ActionsModule, inventory: InventoryModule, trigger: "cancel" | "deadline" | "notice"): Promise<RemovalObservation> {
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
		`if (process.argv[2] === "remove") { ${trigger === "notice" ? removalNotice : `writeFileSync(${JSON.stringify(pidFile)}, String(process.pid)); setInterval(() => {}, 1000);`} }`,
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
	if (trigger !== "notice") leftovers.push(await startedPid(pidFile));
	if (trigger === "cancel") cancel.abort();
	// A cancelled script ends inside the 2 s SIGTERM grace, and the deadline
	// row's copy has a 500 ms deadline; a run still going at this bound never
	// saw its stop.
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

// The script's 10 s deadline, shortened in a copy so the deadline row runs in test time.
const shortScriptDeadline: SourceEdit = { file: "append-system.ts", before: "const APPEND_SYSTEM_DEADLINE_MS = 10_000;", after: "const APPEND_SYSTEM_DEADLINE_MS = 500;" };

const removalRows = [
	{ name: "cancelled removal", trigger: "cancel", edits: [], reason: "cancelled" },
	{ name: "removal past its deadline", trigger: "deadline", edits: [shortScriptDeadline], reason: "timeout" },
	{ name: "removal that printed a notice", trigger: "notice", edits: [], reason: "notice" },
] as const;

async function removalModules(dir: string, edits: SourceEdit[]): Promise<[ActionsModule, InventoryModule]> {
	if (edits.length === 0) return [await import("../extensions/manager/actions.ts"), await import("../extensions/manager/inventory.ts")];
	const copy = mutantManager(join(rootTmp, dir), edits);
	return [await import(join(copy, "actions.ts")), await import(join(copy, "inventory.ts"))];
}

test("a failed block removal ends the uninstall with its notice and restores the block; controls: a fresh signal or a thrown failure", async () => {
	const script = join(process.env.PI_CODING_AGENT_DIR!, "npm", "node_modules", "@scope", "hungscript", "scripts", "append-system.mjs");
	for (const [index, row] of removalRows.entries()) {
		const observed = await failedRemoval(...await removalModules(`row-${index}`, [...row.edits]), row.trigger);
		expect({ name: row.name, observed }).toEqual({ name: row.name, observed: { settled: "resolved", ok: false, firstLine: `pi-extension-manager: append-system-${row.reason}=remove:${script}`, settingsKept: true, npmRan: false, restored: true } });
	}

	const controls = [
		{ row: 0, edit: { file: "append-system.ts", before: 'runAppendSystemScript(item.packageDir, "remove", signal)', after: 'runAppendSystemScript(item.packageDir, "remove", new AbortController().signal)' }, expected: "unsettled" },
		{ row: 1, edit: { file: "actions.ts", before: "goes with the tree.\n\t\tconst removal = await removeAppendSystemBlockForUninstall(plan.item, signal);\n\t\tif (removal.kind === \"failed\") return failedUninstall(plan.item, inventory, removal, removal.message);", after: "goes with the tree.\n\t\tconst removal = await removeAppendSystemBlockForUninstall(plan.item, signal);\n\t\tif (removal.kind === \"failed\") throw new Error(removal.message);" }, expected: "rejected" },
	] as const;
	for (const [index, control] of controls.entries()) {
		const row = removalRows[control.row];
		const planted = await failedRemoval(...await removalModules(`mutant-removal-${index}`, [...row.edits, control.edit]), row.trigger);
		expect({ edit: control.edit.after, settled: planted === "unsettled" ? planted : planted.settled }).toEqual({ edit: control.edit.after, settled: control.expected });
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

// A script that exits non-zero, and one that exits 0 after a notice, as the
// vendored script does when its instructions source is missing.
const failingScripts = [
	{ body: "process.exit(7);\n", key: "append-system-exit" },
	{ body: 'console.error(\'append-system: source-missing="/pkg/instructions.md"\');\n', key: "append-system-notice" },
] as const;

test("failed instruction scripts keep toggle and orphan settings unchanged", async () => {
	const { buildInventory } = await import("../extensions/manager/inventory.ts");
	const { planUninstall, runUninstall, toggleItem } = await import("../extensions/manager/actions.ts");
	for (const [index, { action, script }] of (["disable", "enable", "orphan"] as const).flatMap((action) => failingScripts.map((script) => ({ action, script }))).entries()) {
		const project = join(rootTmp, `${action}-${index}`);
		const packageDir = join(project, ".pi", "packages", "blocked");
		const source = "./packages/blocked";
		const settingsPath = join(project, ".pi", "settings.json");
		writeJson(settingsPath, { packages: action === "enable" ? [{ source, extensions: [] }] : [source] });
		writeAppendSystemPackage(packageDir, "@scope/blocked");
		expect(runVendoredScript(packageDir, "install").status).toBe(0);
		const appendPath = join(project, ".pi", "APPEND_SYSTEM.md");
		const instructionsBefore = readFileSync(appendPath, "utf8");
		writeFileSync(join(packageDir, "scripts", "append-system.mjs"), script.body);
		const ctx = { cwd: project, isProjectTrusted: () => true, ui: { notify() {} } } as never;
		const inv = await buildInventory({} as never, ctx);
		const item = inv.packages.find((pkg) => pkg.packageName === "@scope/blocked")!;
		const diskBefore = readFileSync(settingsPath, "utf8");
		const memoryBefore = JSON.stringify(inv);
		if (action === "orphan") {
			const outcome = await runUninstall(planUninstall(item, inv, ctx)!, inv, live());
			expect([outcome.ok, outcome.message.split("=")[0]]).toEqual([false, `pi-extension-manager: ${script.key}`]);
		} else {
			await expect(toggleItem({} as never, ctx, inv, item, live())).rejects.toThrow(`pi-extension-manager: ${script.key}=`);
		}
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
