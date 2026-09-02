/**
 * The package's one settings reader: trust registry, settings-file order and
 * the kendex.extensionManager.config walk. A leaf module so glyphs.ts and the
 * extension entry can both import it without importing each other.
 */
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

export function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

export function piUserDir(): string {
	return resolve(expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "~/.pi/agent"));
}

export function projectSettingsPath(cwd: string): string {
	let current = resolve(cwd);
	while (true) {
		const candidate = join(current, ".pi", "settings.json");
		if (existsSync(candidate)) return candidate;
		if (existsSync(join(current, ".pi")) || existsSync(join(current, ".git")) || existsSync(join(current, ".kendex-lock.json"))) return candidate;
		const parent = dirname(current);
		if (parent === current) return join(resolve(cwd), ".pi", "settings.json");
		current = parent;
	}
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

export function projectSettingsTrustedForCwd(cwd = process.cwd()): boolean {
	return projectTrustRegistry().projectSettings?.get(projectSettingsPath(cwd)) === true;
}

export function piSettingsPaths(cwd = process.cwd()): string[] {
	const user = join(piUserDir(), "settings.json");
	const project = projectSettingsPath(cwd);
	return projectSettingsTrustedForCwd(cwd) ? [user, project] : [user];
}

export function readPackageConfig(packageId: string, cwd?: string): Record<string, unknown> {
	const merged: Record<string, unknown> = {};
	for (const settingsPath of piSettingsPaths(cwd)) {
		if (!existsSync(settingsPath)) continue;
		try {
			const parsed = JSON.parse(readFileSync(settingsPath, "utf8"));
			const config = parsed?.kendex?.extensionManager?.config?.[packageId];
			if (config && typeof config === "object" && !Array.isArray(config)) Object.assign(merged, config);
		} catch {
			// Ignore malformed optional manager config.
		}
	}
	return merged;
}
