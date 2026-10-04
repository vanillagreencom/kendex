import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { clearPackageConfigCache } from "../extensions/manager/package-config.ts";
import { mutantManager, processAlive, settleWithin, startedPid, writeCommand } from "./fixtures/commands.ts";

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

/** Confirm an uninstall whose npm hangs, then press escape on the progress overlay. */
async function escapeHungUninstall(ui: ManagerUiModule, inventory: InventoryModule): Promise<CancelObservation | "unsettled"> {
	const pidFile = join(rootTmp, `npm-pid-${Math.random()}`);
	const npm = writeCommand(join(rootTmp, "bin", `npm-${Math.random()}`), `echo $$ > "${pidFile}"; exec sleep 30`);
	const settingsPath = join(agent, "settings.json");
	writeJson(settingsPath, { npmCommand: [npm], packages: ["npm:@example/hang"] });
	writeJson(join(agent, "npm", "node_modules", "@example", "hang", "package.json"), { name: "@example/hang", version: "1.0.0" });
	clearPackageConfigCache();
	const settingsBefore = readFileSync(settingsPath, "utf8");
	const pi = {} as never;
	const notices: string[] = [];
	let calls = 0;
	let npmPid: number | undefined;
	const opened = ui.openManager(pi, { cwd: project, isProjectTrusted: () => true, ui: {
		custom: async (factory: (...args: unknown[]) => Component) => {
			calls += 1;
			if (calls === 1) {
				const target = inventory.inventorySession(pi).inventory!.packages.find((item) => item.packageName === "@example/hang")!;
				return { type: "uninstall-package", itemId: target.id };
			}
			if (calls > 2) return { type: "close" };
			let closed!: () => void;
			const overlay = new Promise<void>((resolve) => { closed = resolve; });
			const component = factory({ terminal: { rows: 40 }, requestRender() {} }, theme, {}, () => closed());
			npmPid = await startedPid(pidFile);
			leftovers.push(npmPid);
			component.handleInput("escape");
			return overlay;
		},
		confirm: async () => true,
		notify: (message: string) => notices.push(message.split("\n")[0]!),
	} } as never);
	// A working overlay closes inside the runner's SIGTERM grace; one still
	// open at this bound never passed the escape to the command.
	const outcome = await settleWithin(opened, 4_000);
	if (outcome === "unsettled") {
		inventory.closeInventorySession(pi);
		return outcome;
	}
	return { notices, settingsKept: readFileSync(settingsPath, "utf8") === settingsBefore, npmAlive: npmPid !== undefined && processAlive(npmPid) };
}

test("escape on the progress overlay cancels a running uninstall; control: an overlay that ignores escape stays open", async () => {
	const { selectHost } = await import("../extensions/manager/host.ts");
	await selectHost({ getAgentDir: () => agent, SettingsManager: class {} }, async () => { throw new Error("not OMP"); });
	const real = await escapeHungUninstall(await import("../extensions/manager/manager-ui.ts"), await import("../extensions/manager/inventory.ts"));
	expect(real === "unsettled" ? real : { ...real, notices: real.notices.map((line) => line.split("=")[0]) }).toEqual({
		notices: ["pi-extension-manager: npm-uninstall-cancelled"],
		settingsKept: true,
		npmAlive: false,
	});

	const mutant = mutantManager(join(rootTmp, "mutant-escape"), [{ file: "manager-ui.ts", before: "cancel.abort();", after: "void cancel;" }]);
	expect(await escapeHungUninstall(await import(join(mutant, "manager-ui.ts")), await import(join(mutant, "inventory.ts")))).toBe("unsettled");
}, 20_000);
