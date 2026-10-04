import { win32 } from "node:path";

/*
 * How the manager's command runner launches a command: the one owner of the
 * Windows launch. Windows process creation does no PATHEXT lookup, and both
 * it and libuv search the child's working directory, the open project, before
 * PATH. So on Windows every command resolves here to an absolute file: a bare
 * name through PATH's absolute directories alone, a name holding a path
 * through that path alone. A
 * miss is `not-found`, and the runner spawns nothing. A `.cmd` or `.bat` file
 * runs under System32's cmd.exe by absolute path with a command line escaped
 * here, never through Node's `shell` option, which joins the arguments
 * unquoted.
 */

/** What to spawn: the file, its arguments, and whether they are already escaped for cmd.exe. */
export type CommandLaunch =
	| { kind: "spawn"; file: string; args: string[]; verbatim: boolean }
	| { kind: "not-found"; command: string; searched: string[] };

/** The platform facts a launch resolves against; the runner passes the live ones. */
export interface LaunchHost {
	platform: NodeJS.Platform;
	env: NodeJS.ProcessEnv;
	exists: (path: string) => boolean;
}

/**
 * PATH's directories as Windows searches them, each with one pair of
 * surrounding double quotes stripped as libuv and cmd.exe do. An entry with no
 * drive or UNC root is skipped: it names a directory relative to the child's
 * working directory, the open project.
 */
function pathDirs(env: NodeJS.ProcessEnv): string[] {
	const entries = (env.PATH ?? env.Path ?? env.path)?.split(";") ?? [];
	return entries
		.map((entry) => (entry.length > 1 && entry.startsWith('"') && entry.endsWith('"') ? entry.slice(1, -1) : entry))
		.filter((dir) => win32.isAbsolute(dir) && win32.parse(dir).root.length > 1);
}

function pathExts(env: NodeJS.ProcessEnv): string[] {
	const raw = env.PATHEXT ?? env.PathExt ?? env.pathext ?? ".COM;.EXE;.BAT;.CMD";
	return raw
		.split(";")
		.map((entry) => entry.trim())
		.filter(Boolean)
		.map((entry) => (entry.startsWith(".") ? entry : `.${entry}`));
}

/**
 * cmd.exe's order: a name with an extension is tried as given, a name without
 * one only with each PATHEXT extension. npm ships an extensionless sh script
 * beside `npm.cmd`, and Windows cannot start that script. Extensions are
 * lowercased to match the files npm and Node install; Windows matches either
 * case.
 */
function commandCandidates(name: string, env: NodeJS.ProcessEnv): string[] {
	if (win32.extname(name)) return [name];
	return pathExts(env).map((ext) => `${name}${ext.toLowerCase()}`);
}

/** System32's `exe` by absolute path, so a same-named file in the open project is never the one run. */
function system32(env: NodeJS.ProcessEnv, exe: string): string {
	return win32.join(env.SystemRoot ?? "C:\\Windows", "System32", exe);
}

/** System32's taskkill, by absolute path. */
export function taskkillPath(env: NodeJS.ProcessEnv): string {
	return system32(env, "taskkill.exe");
}

/** The absolute file `command` names, or every directory searched for it. */
function resolveWindowsCommand(command: string, cwd: string | undefined, host: LaunchHost): { kind: "found"; file: string } | { kind: "not-found"; searched: string[] } {
	const searched = /[\\/]/.test(command) || win32.isAbsolute(command)
		? [win32.dirname(win32.resolve(cwd ?? process.cwd(), command))]
		: pathDirs(host.env);
	for (const dir of searched) {
		for (const candidate of commandCandidates(win32.basename(command), host.env)) {
			const file = win32.join(dir, candidate);
			if (host.exists(file)) return { kind: "found", file };
		}
	}
	return { kind: "not-found", searched };
}

// cmd.exe metacharacters, each escaped with a caret: cross-spawn's set.
const CMD_META = /([()\][%!^"`<>&|;, *?])/g;

/**
 * One argument for `cmd /d /s /c`, by cross-spawn's rules: double each run of
 * backslashes before a quote or the end, escape each quote, quote the whole
 * argument, then caret-escape every metacharacter, the quotes included, so
 * cmd.exe passes `&`, `|`, `%` and the rest through as text.
 */
function cmdArgument(arg: string): string {
	const quoted = `"${arg.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\*)$/, "$1$1")}"`;
	return quoted.replace(CMD_META, "^$1");
}

/** The single `/c` argument that runs `file` with `args` under cmd.exe. */
function cmdCommandLine(file: string, args: string[]): string {
	return `"${[file.replace(CMD_META, "^$1"), ...args.map(cmdArgument)].join(" ")}"`;
}

/**
 * How to spawn `command` with `args`. Off Windows, the command and arguments
 * as given, since POSIX exec searches PATH alone. On Windows, see the module
 * header.
 */
export function commandLaunch(command: string, args: string[], cwd: string | undefined, host: LaunchHost): CommandLaunch {
	if (host.platform !== "win32") return { kind: "spawn", file: command, args, verbatim: false };
	const resolved = resolveWindowsCommand(command, cwd, host);
	if (resolved.kind === "not-found") return { kind: "not-found", command, searched: resolved.searched };
	if (!/\.(?:bat|cmd)$/i.test(resolved.file)) return { kind: "spawn", file: resolved.file, args, verbatim: false };
	return { kind: "spawn", file: system32(host.env, "cmd.exe"), args: ["/d", "/s", "/c", cmdCommandLine(resolved.file, args)], verbatim: true };
}
