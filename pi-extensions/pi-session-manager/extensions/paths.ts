import { realpathSync } from "node:fs";
import { dirname, isAbsolute, resolve } from "node:path";
import { expandHome } from "./package-config.js";

export function resolveSettingsRelativePath(value: string, settingsPath: string): string {
	const expanded = expandHome(value.trim());
	return isAbsolute(expanded) ? expanded : resolve(dirname(settingsPath), expanded);
}

export function canonicalPath(path: string | undefined): string | undefined {
	if (!path) return undefined;
	try {
		return realpathSync.native(path);
	} catch {
		return resolve(path);
	}
}

export function samePath(a: string | undefined, b: string | undefined): boolean {
	if (!a || !b) return false;
	return canonicalPath(a) === canonicalPath(b);
}
