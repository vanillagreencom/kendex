import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { homedir } from "node:os";
import { host } from "./host.js";

export function findProjectPiDir(cwd: string): string {
	let current = resolve(cwd);
	while (true) {
		const candidate = join(current, ".pi");
		if (existsSync(candidate)) return candidate;
		if (existsSync(join(current, ".git")) || existsSync(join(current, ".kendex-lock.json"))) return candidate;
		const parent = dirname(current);
		if (parent === current) return join(resolve(cwd), ".pi");
		current = parent;
	}
}

export function compactPath(path: string): string {
	const home = homedir();
	if (path.startsWith(home)) return `~${path.slice(home.length)}`;
	return path;
}

export function npmCachePath(): string {
	return join(host.agentDir(), ".kendex-update-cache.json");
}
