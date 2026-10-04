import { existsSync } from "node:fs";
import { delimiter, extname, isAbsolute, join } from "node:path";

/*
 * Windows executable lookup for the manager's command runner. Windows process
 * creation does no PATHEXT lookup and searches the current directory first,
 * so every executable the runner starts on Windows is resolved here.
 */

function envPath(env: NodeJS.ProcessEnv): string | undefined {
	return env.PATH ?? env.Path ?? env.path;
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
function commandCandidates(command: string, env: NodeJS.ProcessEnv): string[] {
	if (extname(command)) return [command];
	return pathExts(env).map((ext) => `${command}${ext.toLowerCase()}`);
}

/** On `win32`, the file `command` names on PATH (or under `cwd` for a path); elsewhere `command` unchanged. */
export function resolveWindowsCommand(command: string, cwd: string | undefined, env: NodeJS.ProcessEnv, platform: NodeJS.Platform): string {
	if (platform !== "win32") return command;
	if (command.includes("/") || command.includes("\\") || isAbsolute(command)) {
		for (const candidate of commandCandidates(command, env)) {
			const absolute = isAbsolute(candidate) ? candidate : join(cwd ?? process.cwd(), candidate);
			if (existsSync(absolute)) return absolute;
		}
		return command;
	}
	for (const dir of (envPath(env)?.split(delimiter) ?? [])) {
		if (!dir) continue;
		for (const candidate of commandCandidates(command, env)) {
			const full = join(dir, candidate);
			if (existsSync(full)) return full;
		}
	}
	return command;
}

/** A `.cmd` or `.bat` entrypoint runs only under cmd.exe. */
export function needsWindowsShell(command: string, platform: NodeJS.Platform): boolean {
	return platform === "win32" && /\.(?:bat|cmd)$/i.test(command);
}

/** System32's taskkill by absolute path, so a `taskkill.exe` in the open project is never the one run. */
export function taskkillPath(env: NodeJS.ProcessEnv): string {
	return join(env.SystemRoot ?? "C:\\Windows", "System32", "taskkill.exe");
}
