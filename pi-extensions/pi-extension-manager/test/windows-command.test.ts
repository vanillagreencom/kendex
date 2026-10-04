import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { mutantManager } from "./fixtures/commands.ts";

type WindowsCommandModule = typeof import("../extensions/manager/windows-command.ts");

const rootTmp = join(import.meta.dir, "..", "tmp", "windows-command-test");

beforeEach(() => {
	rmSync(rootTmp, { recursive: true, force: true });
	mkdirSync(rootTmp, { recursive: true });
});

afterEach(() => {
	rmSync(rootTmp, { recursive: true, force: true });
});

/**
 * Node's Windows installer and a global npm put an extensionless `npm` sh
 * script beside `npm.cmd`. The resolver runs here with `win32` injected; the
 * directory is a single PATH entry, so the host's PATH delimiter never splits it.
 */
function resolveNpm(module: WindowsCommandModule): string {
	const dir = join(rootTmp, "nodejs");
	mkdirSync(dir, { recursive: true });
	for (const name of ["npm", "npm.cmd", "npm.ps1"]) writeFileSync(join(dir, name), "");
	return module.resolveWindowsCommand("npm", undefined, { PATH: dir, PATHEXT: ".COM;.EXE;.BAT;.CMD" }, "win32");
}

test("an extensionless name resolves only through PATHEXT; control: trying the bare name first returns the sh script", async () => {
	const dir = join(rootTmp, "nodejs");
	expect(resolveNpm(await import("../extensions/manager/windows-command.ts"))).toBe(join(dir, "npm.cmd"));
	const mutant = mutantManager(join(rootTmp, "mutant-bare-first"), [{
		file: "windows-command.ts",
		before: "return pathExts(env).map((ext) => `${command}${ext.toLowerCase()}`);",
		after: "return [command, ...pathExts(env).map((ext) => `${command}${ext.toLowerCase()}`)];",
	}]);
	expect(resolveNpm(await import(join(mutant, "windows-command.ts")))).toBe(join(dir, "npm"));
});
