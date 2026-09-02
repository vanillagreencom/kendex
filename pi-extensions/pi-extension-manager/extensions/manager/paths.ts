import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { piGlobalRoot, piProjectRoot } from "./pi-root.js";
import { homedir } from "node:os";

export function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

export function userPiDir(): string {
	return piGlobalRoot();
}

export function findProjectPiDir(cwd: string): string {
	return join(piProjectRoot(cwd) ?? resolve(cwd), ".pi");
}

export function compactPath(path: string): string {
	const home = homedir();
	if (path.startsWith(home)) return `~${path.slice(home.length)}`;
	return path;
}

export function npmCachePath(): string {
	return join(homedir(), ".pi", "agent", ".kendex-update-cache.json");
}
