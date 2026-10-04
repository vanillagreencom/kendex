import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, rmSync } from "node:fs";
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

const CMD = String.raw`C:\Windows\System32\cmd.exe`;
const PATHEXT = ".COM;.EXE;.BAT;.CMD";

/**
 * Each row resolves against an injected Windows host: its PATH, and the files
 * that exist. Node's Windows installer and a global npm put an extensionless
 * `npm` sh script beside `npm.cmd`.
 */
const launchRows = [
	{
		name: "an extensionless name resolves through PATHEXT alone",
		command: "npm", args: [], cwd: undefined, path: String.raw`C:\nodejs`,
		files: [String.raw`C:\nodejs\npm`, String.raw`C:\nodejs\npm.cmd`, String.raw`C:\nodejs\npm.ps1`],
		expected: { kind: "spawn", file: CMD, args: ["/d", "/s", "/c", String.raw`"C:\nodejs\npm.cmd"`], verbatim: true },
	},
	{
		name: "a name absent from PATH is not found, whatever the project holds",
		command: "npm", args: ["root"], cwd: String.raw`C:\project`, path: String.raw`C:\nodejs`,
		files: [String.raw`C:\project\npm.exe`],
		expected: { kind: "not-found", command: "npm", searched: [String.raw`C:\nodejs`] },
	},
	{
		name: "a name holding a path is looked up there alone",
		command: String.raw`.\tools\kendex`, args: [], cwd: String.raw`C:\project`, path: String.raw`C:\bin`,
		files: [String.raw`C:\bin\kendex.exe`],
		expected: { kind: "not-found", command: String.raw`.\tools\kendex`, searched: [String.raw`C:\project\tools`] },
	},
	{
		name: "an executable runs as itself with its arguments as given",
		command: "kendex", args: ["remove", "a b"], cwd: String.raw`C:\project`, path: String.raw`C:\bin`,
		files: [String.raw`C:\bin\kendex.exe`],
		expected: { kind: "spawn", file: String.raw`C:\bin\kendex.exe`, args: ["remove", "a b"], verbatim: false },
	},
	{
		// npm's default install path, a --prefix with a space and `&`, and every
		// escape cross-spawn's rules handle: `%`, `^`, quotes and a trailing backslash.
		name: "a cmd entrypoint runs under System32's cmd.exe with each argument escaped",
		command: "npm", args: ["install", "--prefix", String.raw`C:\Users\A B\R&D`, "100%", "a^b", 'say "hi"', "C:\\dir\\"],
		cwd: undefined, path: String.raw`C:\Program Files\nodejs`,
		files: [String.raw`C:\Program Files\nodejs\npm.cmd`],
		expected: {
			kind: "spawn",
			file: CMD,
			args: ["/d", "/s", "/c", String.raw`"C:\Program^ Files\nodejs\npm.cmd ^"install^" ^"--prefix^" ^"C:\Users\A^ B\R^&D^" ^"100^%^" ^"a^^b^" ^"say^ \^"hi\^"^" ^"C:\dir\\^""`],
			verbatim: true,
		},
	},
	{
		// libuv strips the quotes a PATH entry holding a space often carries.
		name: "a quoted PATH directory is searched without its quotes",
		command: "node", args: [], cwd: undefined, path: String.raw`"C:\Program Files\nodejs";C:\bin`,
		files: [String.raw`C:\Program Files\nodejs\node.exe`],
		expected: { kind: "spawn", file: String.raw`C:\Program Files\nodejs\node.exe`, args: [], verbatim: false },
	},
	{
		name: "a relative PATH entry, which names a directory in the project, is never searched",
		command: "node", args: [], cwd: String.raw`C:\project`, path: String.raw`.;bin;\tools;C:\nodejs`,
		files: ["node.exe", String.raw`bin\node.exe`, String.raw`\tools\node.exe`],
		expected: { kind: "not-found", command: "node", searched: [String.raw`C:\nodejs`] },
	},
	{
		name: "off Windows, the command and arguments are spawned as given",
		command: "npm", args: ["root"], cwd: undefined, path: "/usr/bin", platform: "linux",
		files: [],
		expected: { kind: "spawn", file: "npm", args: ["root"], verbatim: false },
	},
] as const;

type LaunchRow = (typeof launchRows)[number];

function launch(module: WindowsCommandModule, row: LaunchRow): unknown {
	const files = new Set<string>(row.files);
	const host = { platform: "platform" in row ? row.platform : "win32", env: { PATH: row.path, PATHEXT }, exists: (path: string) => files.has(path) } as const;
	return module.commandLaunch(row.command, [...row.args], row.cwd, host);
}

const taskkillRows = [
	{ name: "SystemRoot names the System32 directory", env: { SystemRoot: String.raw`D:\Win` }, expected: String.raw`D:\Win\System32\taskkill.exe` },
	{ name: "without SystemRoot, the default Windows directory", env: {}, expected: String.raw`C:\Windows\System32\taskkill.exe` },
] as const;

function observe(module: WindowsCommandModule): Record<string, unknown> {
	const observed: Record<string, unknown> = {};
	for (const row of launchRows) observed[row.name] = launch(module, row);
	for (const row of taskkillRows) observed[row.name] = module.taskkillPath(row.env);
	return observed;
}

test("every Windows launch resolves to an absolute file or to not-found", async () => {
	const observed = observe(await import("../extensions/manager/windows-command.ts"));
	for (const row of [...launchRows, ...taskkillRows]) expect({ name: row.name, observed: observed[row.name] }).toEqual({ name: row.name, observed: row.expected });
});

test("launch controls: each planted gap changes what its row observes", async () => {
	const controls = [
		{
			name: "trying the bare name before PATHEXT",
			row: "an extensionless name resolves through PATHEXT alone",
			before: "return pathExts(env).map((ext) => `${name}${ext.toLowerCase()}`);",
			after: "return [name, ...pathExts(env).map((ext) => `${name}${ext.toLowerCase()}`)];",
		},
		{
			name: "falling back to the bare name, which spawn searches for in the project",
			row: "a name absent from PATH is not found, whatever the project holds",
			before: 'if (resolved.kind === "not-found") return { kind: "not-found", command, searched: resolved.searched };',
			after: 'if (resolved.kind === "not-found") return { kind: "spawn", file: command, args, verbatim: false };',
		},
		{
			name: "joining the arguments unquoted",
			row: "a cmd entrypoint runs under System32's cmd.exe with each argument escaped",
			before: '...args.map(cmdArgument)].join(" ")',
			after: '...args].join(" ")',
		},
		{
			name: "searching a quoted PATH entry as written",
			row: "a quoted PATH directory is searched without its quotes",
			before: `.map((entry) => (entry.length > 1 && entry.startsWith('"') && entry.endsWith('"') ? entry.slice(1, -1) : entry))`,
			after: ".map((entry) => entry)",
		},
		{
			name: "keeping a relative PATH entry, which yields a project-relative file",
			row: "a relative PATH entry, which names a directory in the project, is never searched",
			before: ".filter((dir) => win32.isAbsolute(dir) && win32.parse(dir).root.length > 1);",
			after: ".filter(Boolean);",
		},
		{
			name: "a bare taskkill, which Windows searches for in the project",
			row: "SystemRoot names the System32 directory",
			before: 'return system32(env, "taskkill.exe");',
			after: 'return "taskkill.exe";',
		},
	] as const;
	const expected = Object.fromEntries([...launchRows, ...taskkillRows].map((row) => [row.name, row.expected]));
	for (const [index, control] of controls.entries()) {
		const mutant = mutantManager(join(rootTmp, `mutant-${index}`), [{ file: "windows-command.ts", before: control.before, after: control.after }]);
		const observed = observe(await import(join(mutant, "windows-command.ts")));
		expect({ name: control.name, differs: !Bun.deepEquals(observed[control.row], expected[control.row]) }).toEqual({ name: control.name, differs: true });
	}
});
