import { existsSync } from "node:fs";
import { join, resolve, sep } from "node:path";
import { piGlobalRoot, piProjectRoot } from "./pi-root.js";
import { fileURLToPath } from "node:url";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import type { ExtensionInstallScope } from "./types.js";

export function userPiDir(): string {
	return piGlobalRoot();
}

export function findProjectPiDir(cwd: string): string {
	return join(piProjectRoot(cwd) ?? resolve(cwd), ".pi");
}

export function projectSettingsPath(cwd: string): string {
	return join(findProjectPiDir(cwd), "settings.json");
}

const PROJECT_TRUST_SYMBOL = Symbol.for("kendex.pi.project-trust");

interface ProjectTrustRegistry {
	projectSettings?: Map<string, boolean>;
}

function projectTrustRegistry(): ProjectTrustRegistry {
	const host = globalThis as unknown as Record<PropertyKey, ProjectTrustRegistry | undefined>;
	const existing = host[PROJECT_TRUST_SYMBOL];
	if (existing) return existing;
	const created: ProjectTrustRegistry = {};
	host[PROJECT_TRUST_SYMBOL] = created;
	return created;
}

export function recordProjectTrust(ctx: { cwd?: string; isProjectTrusted?: () => boolean }): void {
	if (!ctx.cwd) return;
	let trusted = true;
	try {
		trusted = ctx.isProjectTrusted?.() === true;
	} catch {
		trusted = false;
	}
	const registry = projectTrustRegistry();
	if (!registry.projectSettings) registry.projectSettings = new Map();
	registry.projectSettings.set(projectSettingsPath(ctx.cwd), trusted);
}

export function projectSettingsTrusted(cwd = process.cwd()): boolean {
	return projectTrustRegistry().projectSettings?.get(projectSettingsPath(cwd)) === true;
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
