import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { clearPackageConfigCache } from "../extensions/manager/package-config.ts";
import { mutantManager, processAlive, settleWithin, startedPid, waitFor, writeCommand } from "./fixtures/commands.ts";

// Neutral terminal primitives; the production components own rendering.
mock.module("@earendil-works/pi-tui", () => ({
	matchesKey: (input: string, key: string) => input === key,
	truncateToWidth: (text: string) => text,
	visibleWidth: (text: string) => text.length,
	wrapTextWithAnsi: (text: string) => [text],
}));

type ManagerUiModule = typeof import("../extensions/manager/manager-ui.ts");
type InventoryModule = typeof import("../extensions/manager/inventory.ts");
interface Component { handleInput(data: string): void; render(width: number): string[] }

const rootTmp = join(import.meta.dir, "..", "tmp", "manager-ui-test");
const agent = join(rootTmp, "home", ".pi", "agent");
const project = join(rootTmp, "project");
const originalEnv = { HOME: process.env.HOME, PATH: process.env.PATH, PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR };
const leftovers: number[] = [];
const theme = { fg: (_color: string, text: string) => text, bg: (_color: string, text: string) => text, bold: (text: string) => text, inverse: (text: string) => text };

function writeJson(path: string, value: unknown): void {
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, JSON.stringify(value));
}

beforeEach(() => {
	rmSync(rootTmp, { recursive: true, force: true });
	mkdirSync(join(project, ".pi"), { recursive: true });
	// The npm the manager starts inherits the live environment.
	process.env.HOME = join(rootTmp, "home");
	process.env.PI_CODING_AGENT_DIR = agent;
	process.env.PATH = "/usr/bin:/bin";
	clearPackageConfigCache();
});

afterEach(() => {
	for (const pid of leftovers.splice(0)) {
		try { process.kill(-pid, "SIGKILL"); } catch {}
	}
	for (const [name, value] of Object.entries(originalEnv)) {
		if (value === undefined) delete process.env[name];
		else process.env[name] = value;
	}
	rmSync(rootTmp, { recursive: true, force: true });
	clearPackageConfigCache();
});

interface CancelObservation { notices: string[]; settingsKept: boolean; npmAlive: boolean }
type Trigger = "escape" | "session-end";

/**
 * Confirm an uninstall whose npm hangs and ignores SIGTERM, then cancel it by
 * `trigger` once npm has started: escape on the progress overlay, or the
 * session ending. For the session ending, `npmAlive` is read as soon as the
 * shutdown promise resolves, since Pi exits then.
 */
async function cancelHungUninstall(ui: ManagerUiModule, inventory: InventoryModule, trigger: Trigger): Promise<CancelObservation | { unsettled: true; npmAlive: boolean }> {
	const pidFile = join(rootTmp, `npm-pid-${Math.random()}`);
	// The ignored SIGTERM is inherited by sleep, so only the SIGKILL past the grace ends it.
	const npm = writeCommand(join(rootTmp, "bin", `npm-${Math.random()}`), `trap "" TERM; echo $$ > "${pidFile}"; exec sleep 30`);
	const settingsPath = join(agent, "settings.json");
	writeJson(settingsPath, { npmCommand: [npm], packages: ["npm:@example/hang"] });
	writeJson(join(agent, "npm", "node_modules", "@example", "hang", "package.json"), { name: "@example/hang", version: "1.0.0" });
	clearPackageConfigCache();
	inventory.startInventorySession(pi);
	const settingsBefore = readFileSync(settingsPath, "utf8");
	const notices: string[] = [];
	let calls = 0;
	let overlay: Component | undefined;
	const opened = ui.openManager(pi, { cwd: project, isProjectTrusted: () => true, ui: {
		custom: async (factory: (...args: unknown[]) => Component) => {
			calls += 1;
			if (calls === 1) {
				const target = inventory.inventorySession(pi).inventory!.packages.find((item) => item.packageName === "@example/hang")!;
				return { type: "uninstall-package", itemId: target.id };
			}
			if (calls > 2) return { type: "close" };
			let closed!: () => void;
			const shown = new Promise<void>((resolve) => { closed = resolve; });
			overlay = factory({ terminal: { rows: 40 }, requestRender() {} }, theme, {}, () => closed());
			return shown;
		},
		confirm: async () => true,
		notify: (message: string) => notices.push(message.split("\n")[0]!),
	} } as never);
	// npm has started before the bound below begins, so a run that never
	// reaches npm fails here rather than reading as an ignored cancel.
	const npmPid = await startedPid(pidFile);
	leftovers.push(npmPid);
	await waitFor("progress overlay", () => overlay !== undefined);
	let npmAliveAtShutdown: boolean | undefined;
	if (trigger === "escape") overlay!.handleInput("escape");
	else {
		await inventory.closeInventorySession(pi);
		npmAliveAtShutdown = processAlive(npmPid);
	}
	// A working overlay closes once the runner's SIGTERM grace has passed; one
	// still open at this bound never passed the cancel to the command.
	const outcome = await settleWithin(opened, 4_000);
	if (outcome === "unsettled") {
		const npmAlive = processAlive(npmPid);
		void inventory.closeInventorySession(pi);
		return { unsettled: true, npmAlive };
	}
	return { notices, settingsKept: readFileSync(settingsPath, "utf8") === settingsBefore, npmAlive: npmAliveAtShutdown ?? processAlive(npmPid) };
}

const pi = {} as never;

test("escape or session end cancels a running uninstall; controls: an ignored escape, an action blind to the session, or one shutdown does not wait for", async () => {
	const { selectHost } = await import("../extensions/manager/host.ts");
	await selectHost({ getAgentDir: () => agent, SettingsManager: class {} }, async () => { throw new Error("not OMP"); });
	const real = [await import("../extensions/manager/manager-ui.ts"), await import("../extensions/manager/inventory.ts")] as const;
	const expected = { notices: ["pi-extension-manager: npm-uninstall-cancelled"], settingsKept: true, npmAlive: false };
	const summary = (observed: Awaited<ReturnType<typeof cancelHungUninstall>>) => "unsettled" in observed ? observed : { ...observed, notices: observed.notices.map((line) => line.split("=")[0]) };
	for (const trigger of ["escape", "session-end"] as const) {
		expect({ trigger, observed: summary(await cancelHungUninstall(...real, trigger)) }).toEqual({ trigger, observed: expected });
	}

	const rows = [
		{ trigger: "escape", before: "cancel.abort();", after: "void cancel;" },
		{ trigger: "session-end", before: "sessionWork(pi, (session) => action(AbortSignal.any([cancel.signal, session])))", after: "action(cancel.signal)" },
		{ trigger: "session-end", before: "sessionWork(pi, (session) => action(AbortSignal.any([cancel.signal, session])))", after: "action(AbortSignal.any([cancel.signal, inventorySession(pi).controller.signal]))" },
	] as const;
	for (const [index, row] of rows.entries()) {
		const mutant = mutantManager(join(rootTmp, `mutant-cancel-${index}`), [{ file: "manager-ui.ts", before: row.before, after: row.after }]);
		const planted = summary(await cancelHungUninstall(await import(join(mutant, "manager-ui.ts")), await import(join(mutant, "inventory.ts")), row.trigger));
		expect({ edit: row.after, differs: !Bun.deepEquals(planted, expected) }).toEqual({ edit: row.after, differs: true });
	}
}, 40_000);
