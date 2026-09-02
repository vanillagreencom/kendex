import { relative, dirname } from "node:path";
import { getAgentDir, SettingsManager, type PackageSource } from "@earendil-works/pi-coding-agent";
import { findProjectPiDir, projectSettingsTrusted } from "./paths.js";
import type { SkillEntry } from "./types.js";

function updatePatterns(current: string[], pattern: string, enabled: boolean): string[] {
	const updated = current.filter((entry) => {
		const stripped = entry.startsWith("!") || entry.startsWith("+") || entry.startsWith("-") ? entry.slice(1) : entry;
		return stripped !== pattern;
	});
	updated.push(`${enabled ? "+" : "-"}${pattern}`);
	return updated;
}

function getTopLevelPattern(skill: SkillEntry, cwd: string): string {
	const baseDir = skill.scope === "project" ? findProjectPiDir(cwd) : getAgentDir();
	if (!baseDir) throw new Error("The home directory is not a project skill root.");
	return relative(baseDir, skill.path);
}

function getPackagePattern(skill: SkillEntry): string {
	const baseDir = skill.baseDir ?? dirname(skill.path);
	return relative(baseDir, skill.path);
}

function hasPackageFilters(pkg: Exclude<PackageSource, string>): boolean {
	return pkg.extensions !== undefined || pkg.skills !== undefined || pkg.prompts !== undefined || pkg.themes !== undefined;
}

export async function setSkillEnabled(cwd: string, skill: SkillEntry, enabled: boolean): Promise<void> {
	if (skill.scope === "temporary") throw new Error("Temporary skills cannot be toggled.");
	if (skill.scope === "project" && !projectSettingsTrusted(cwd)) throw new Error("Project skills cannot be toggled before project trust is active.");
	const settingsManager = SettingsManager.create(cwd, getAgentDir(), { projectTrusted: projectSettingsTrusted(cwd) });

	if (skill.origin === "top-level") {
		const settings = skill.scope === "project" ? settingsManager.getProjectSettings() : settingsManager.getGlobalSettings();
		const updated = updatePatterns([...(settings.skills ?? [])], getTopLevelPattern(skill, cwd), enabled);
		if (skill.scope === "project") settingsManager.setProjectSkillPaths(updated);
		else settingsManager.setSkillPaths(updated);
		await settingsManager.flush();
		return;
	}

	const settings = skill.scope === "project" ? settingsManager.getProjectSettings() : settingsManager.getGlobalSettings();
	const packages = [...(settings.packages ?? [])];
	const packageIndex = packages.findIndex((pkg) => (typeof pkg === "string" ? pkg : pkg.source) === skill.source);
	if (packageIndex === -1) throw new Error("Could not find the package settings entry for this skill.");

	const packageEntry = packages[packageIndex];
	const packageConfig = typeof packageEntry === "string" ? { source: packageEntry } : { ...packageEntry };
	const updated = updatePatterns([...(packageConfig.skills ?? [])], getPackagePattern(skill), enabled);
	packageConfig.skills = updated.length > 0 ? updated : undefined;
	packages[packageIndex] = hasPackageFilters(packageConfig) ? packageConfig : packageConfig.source;
	if (skill.scope === "project") settingsManager.setProjectPackages(packages);
	else settingsManager.setPackages(packages);
	await settingsManager.flush();
}
