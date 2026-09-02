import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { piGlobalRoot, piProjectRoot } from "./pi-root.js";

export function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

export function projectSettingsPath(cwd: string): string | undefined {
	const root = piProjectRoot(cwd);
	return root ? join(root, ".pi", "settings.json") : undefined;
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
	const settingsPath = projectSettingsPath(ctx.cwd);
	if (settingsPath) registry.projectSettings.set(settingsPath, trusted);
}

function projectSettingsTrusted(settingsPath: string): boolean {
	return projectTrustRegistry().projectSettings?.get(settingsPath) === true;
}


export function piSettingsPaths(cwd = process.cwd()): string[] {
	const userDir = piGlobalRoot();
	const user = join(userDir, "settings.json");
	const project = projectSettingsPath(cwd);
	return project && projectSettingsTrusted(project) ? [user, project] : [user];
}

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
