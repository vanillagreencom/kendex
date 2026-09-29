import { dirname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { projectSettingsPath } from "./package-config.js";
import type { ExtensionInstallScope } from "./types.js";

export function findProjectPiDir(cwd: string): string {
	return dirname(projectSettingsPath(cwd));
}

function normalizeDir(path: string): string {
	const normalized = resolve(path);
	return normalized.endsWith(sep) ? normalized : normalized + sep;
}

function isWithin(path: string, parent: string): boolean {
	return normalizeDir(path).startsWith(normalizeDir(parent));
}

export function detectExtensionInstallScope(cwd: string): ExtensionInstallScope {
	try {
		const extensionFile = fileURLToPath(import.meta.url);
		if (isWithin(extensionFile, findProjectPiDir(cwd))) return "project";
		if (isWithin(extensionFile, getAgentDir())) return "global";
	} catch {
		// Fall through to global for unusual loaders.
	}
	return "global";
}
