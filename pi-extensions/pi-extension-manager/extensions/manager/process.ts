import { existsSync } from "node:fs";
import { delimiter, extname, isAbsolute, join } from "node:path";
import { spawnSync, type SpawnSyncOptionsWithStringEncoding, type SpawnSyncReturns } from "node:child_process";

export type CommandResult = SpawnSyncReturns<string>;

type SpawnSyncFn = typeof spawnSync;

let spawnSyncImpl: SpawnSyncFn = spawnSync;

function envPath(env: NodeJS.ProcessEnv | undefined): string | undefined {
	if (!env) return process.env.PATH;
	return env.PATH ?? env.Path ?? env.path ?? process.env.PATH;
}

function pathExts(env: NodeJS.ProcessEnv | undefined): string[] {
	const raw = env?.PATHEXT ?? env?.PathExt ?? env?.pathext ?? process.env.PATHEXT ?? ".COM;.EXE;.BAT;.CMD";
	return raw
		.split(";")
		.map((entry) => entry.trim())
		.filter(Boolean)
		.map((entry) => (entry.startsWith(".") ? entry : `.${entry}`));
}

function commandCandidates(command: string, env: NodeJS.ProcessEnv | undefined): string[] {
	if (process.platform !== "win32") return [command];
	if (extname(command)) return [command];
	return [command, ...pathExts(env).map((ext) => `${command}${ext}`)];
}

function resolveWindowsCommand(command: string, options: Omit<SpawnSyncOptionsWithStringEncoding, "encoding">): string {
	if (process.platform !== "win32") return command;
	if (command.includes("/") || command.includes("\\") || isAbsolute(command)) {
		for (const candidate of commandCandidates(command, options.env)) {
			const absolute = isAbsolute(candidate) ? candidate : join(options.cwd?.toString() ?? process.cwd(), candidate);
			if (existsSync(absolute)) return absolute;
		}
		return command;
	}
	for (const dir of (envPath(options.env)?.split(delimiter) ?? [])) {
		if (!dir) continue;
		for (const candidate of commandCandidates(command, options.env)) {
			const full = join(dir, candidate);
			if (existsSync(full)) return full;
		}
	}
	return command;
}

function needsWindowsShell(command: string): boolean {
	return process.platform === "win32" && /\.(?:bat|cmd)$/i.test(command);
}

export function runCommand(command: string, args: string[], options: Omit<SpawnSyncOptionsWithStringEncoding, "encoding"> = {}): CommandResult {
	const resolved = resolveWindowsCommand(command, options);
	return spawnSyncImpl(resolved, args, { ...options, encoding: "utf8", shell: options.shell ?? needsWindowsShell(resolved) });
}

export function __setSpawnSyncForTests(fn: SpawnSyncFn | undefined): void {
	spawnSyncImpl = fn ?? spawnSync;
}
