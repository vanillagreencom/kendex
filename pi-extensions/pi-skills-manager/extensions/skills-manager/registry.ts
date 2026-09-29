import { readFileSync, rmSync } from "node:fs";
import { basename, dirname } from "node:path";
import {
	DefaultPackageManager,
	getAgentDir,
	parseFrontmatter,
	SettingsManager,
	type ExtensionContext,
	type ResolvedResource,
} from "@earendil-works/pi-coding-agent";
import { projectSettingsTrustedForCwd } from "./package-config.js";
import type { SkillEntry, SkillOrigin, SkillRegistry, SkillScope } from "./types.js";

function compareSkills(a: SkillEntry, b: SkillEntry): number {
	const scopeRank = (scope: SkillScope) => scope === "project" ? 0 : scope === "user" ? 1 : 2;
	const rank = scopeRank(a.scope) - scopeRank(b.scope);
	if (rank !== 0) return rank;
	if (a.origin !== b.origin) return a.origin === "top-level" ? -1 : 1;
	return a.name.localeCompare(b.name);
}

function parseSkillFile(path: string): Pick<SkillEntry, "name" | "description" | "frontmatter"> | null {
	try {
		const raw = readFileSync(path, "utf8");
		const { frontmatter } = parseFrontmatter<Record<string, unknown>>(raw);
		const name = typeof frontmatter.name === "string" ? frontmatter.name.trim() : "";
		const description = typeof frontmatter.description === "string" ? frontmatter.description.trim() : "";
		if (!name || !description) return null;
		return {
			name,
			description,
			frontmatter: Object.fromEntries(Object.entries(frontmatter).filter(([, value]) => value !== undefined)),
		};
	} catch {
		return null;
	}
}

function toSkillEntry(resource: ResolvedResource): SkillEntry | null {
	const parsed = parseSkillFile(resource.path);
	if (!parsed) return null;
	return {
		name: parsed.name,
		description: parsed.description,
		frontmatter: parsed.frontmatter,
		path: resource.path,
		scope: resource.metadata.scope as SkillScope,
		origin: resource.metadata.origin as SkillOrigin,
		source: resource.metadata.source,
		baseDir: resource.metadata.baseDir,
		enabled: resource.enabled,
	};
}

function dedupeByPath(skills: SkillEntry[]): SkillEntry[] {
	const seen = new Set<string>();
	const out: SkillEntry[] = [];
	for (const skill of skills) {
		if (seen.has(skill.path)) continue;
		seen.add(skill.path);
		out.push(skill);
	}
	return out;
}

export async function loadSkillRegistry(cwd: string): Promise<SkillRegistry> {
	const settingsManager = SettingsManager.create(cwd, getAgentDir(), { projectTrusted: projectSettingsTrustedForCwd(cwd) });
	const packageManager = new DefaultPackageManager({ cwd, agentDir: getAgentDir(), settingsManager });
	const resolved = await packageManager.resolve();
	const allSkills = dedupeByPath(resolved.skills.map(toSkillEntry).filter((entry): entry is SkillEntry => entry !== null)).sort(compareSkills);
	const byName = new Map<string, SkillEntry>();
	for (const skill of allSkills) {
		if (!skill.enabled) continue;
		if (!byName.has(skill.name)) byName.set(skill.name, skill);
	}
	const skills = Array.from(byName.values()).sort(compareSkills);
	return { skills, allSkills, byName: new Map(skills.map((skill) => [skill.name, skill])) };
}

export function isDeletableSkill(skill: SkillEntry): boolean {
	return skill.origin === "top-level" && (skill.scope === "project" || skill.scope === "user");
}

export function skillStorageTarget(skill: SkillEntry): string {
	return basename(skill.path).toLowerCase() === "skill.md" ? dirname(skill.path) : skill.path;
}

export async function deleteSkill(ctx: ExtensionContext, skill: SkillEntry): Promise<boolean> {
	if (!isDeletableSkill(skill)) {
		ctx.ui.notify("Only your own project and global skills can be deleted", "warning");
		return false;
	}
	rmSync(skillStorageTarget(skill), { recursive: true, force: true });
	ctx.ui.notify(`Deleted skill: ${skill.name}`, "info");
	return true;
}
