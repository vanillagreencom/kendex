import { readFileSync } from "node:fs";
import { join } from "node:path";
import { getAgentDir, parseFrontmatter, stripFrontmatter, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { findProjectPiDir } from "./paths.js";
import type { ParsedSkillDocument, SkillEntry, SkillLocation } from "./types.js";

export function normalizeSkillName(name: string): string {
	return name
		.toLowerCase()
		.trim()
		.replace(/[^a-z0-9-\s]/g, "")
		.replace(/\s+/g, "-")
		.replace(/-+/g, "-")
		.replace(/^-|-$/g, "");
}

export function getTargetDir(ctx: ExtensionContext, location: SkillLocation, skillName: string): string {
	if (location === "global") return join(getAgentDir(), "skills", skillName);
	const project = findProjectPiDir(ctx.cwd);
	if (!project) throw new Error("The home directory is not a project skill root.");
	return join(project, "skills", skillName);
}

function formatScalar(value: unknown): string {
	if (typeof value === "string") {
		if (value.length === 0) return '""';
		if (/^[A-Za-z0-9_./@,+()[\]\- ]+$/.test(value) && !value.includes(": ") && !/^\s|\s$/.test(value)) return value;
		return JSON.stringify(value);
	}
	if (typeof value === "number" || typeof value === "boolean") return String(value);
	if (value === null) return "null";
	return JSON.stringify(value);
}

export function formatYamlValue(key: string, value: unknown, indent = ""): string[] {
	if (typeof value === "string" && value.includes("\n")) {
		return [`${indent}${key}: |`, ...value.split("\n").map((line) => `${indent}  ${line}`)];
	}
	if (Array.isArray(value)) {
		if (value.length === 0) return [`${indent}${key}: []`];
		return [
			`${indent}${key}:`,
			...value.flatMap((item) => {
				if (item && typeof item === "object") {
					return [`${indent}  -`, ...Object.entries(item as Record<string, unknown>).flatMap(([nestedKey, nestedValue]) => formatYamlValue(nestedKey, nestedValue, `${indent}    `))];
				}
				return [`${indent}  - ${formatScalar(item)}`];
			}),
		];
	}
	if (value && typeof value === "object") {
		const entries = Object.entries(value as Record<string, unknown>);
		if (entries.length === 0) return [`${indent}${key}: {}`];
		return [`${indent}${key}:`, ...entries.flatMap(([nestedKey, nestedValue]) => formatYamlValue(nestedKey, nestedValue, `${indent}  `))];
	}
	return [`${indent}${key}: ${formatScalar(value)}`];
}

export function buildFrontmatterBlock(skill: SkillEntry): string {
	const frontmatter = skill.frontmatter ?? { name: skill.name, description: skill.description };
	const lines = Object.entries(frontmatter).flatMap(([key, value]) => formatYamlValue(key, value));
	return ["---", ...lines, "---"].join("\n");
}

export function buildSkillDocument(skill: SkillEntry): string {
	const frontmatter = buildFrontmatterBlock(skill);
	const content = skill.content.trim();
	return content ? `${frontmatter}\n\n${content}\n` : `${frontmatter}\n`;
}

export function buildEditableSkillDocument(skill: SkillEntry, raw?: string): string {
	const source = raw ?? buildSkillDocument(skill);
	const parsed = parseFrontmatter<Record<string, unknown>>(source);
	const frontmatter = { ...parsed.frontmatter };
	delete frontmatter.name;
	const editableBlock = ["---", ...Object.entries(frontmatter).flatMap(([key, value]) => formatYamlValue(key, value)), "---"].join("\n");
	const content = stripFrontmatter(source).trim();
	return content ? `${editableBlock}\n\n${content}\n` : `${editableBlock}\n`;
}

export function readSkillDocument(skill: SkillEntry): string {
	try {
		return readFileSync(skill.path, "utf8");
	} catch {
		return buildSkillDocument(skill);
	}
}

export function frontmatterToRaw(frontmatter: Record<string, unknown>, content: string): string {
	const block = ["---", ...Object.entries(frontmatter).flatMap(([key, value]) => formatYamlValue(key, value)), "---"].join("\n");
	return content.trim() ? `${block}\n\n${content.trim()}\n` : `${block}\n`;
}

export function parseSkillDocument(raw: string, expectedName: string): ParsedSkillDocument {
	const parsed = parseFrontmatter<Record<string, unknown>>(raw);
	const name = typeof parsed.frontmatter.name === "string" ? parsed.frontmatter.name.trim() : "";
	const description = typeof parsed.frontmatter.description === "string" ? parsed.frontmatter.description.trim() : "";
	if (!name || !description) throw new Error("Skill must include frontmatter fields 'name' and 'description'");
	if (name !== expectedName) throw new Error(`Frontmatter name must stay '${expectedName}'`);
	const frontmatter = Object.fromEntries(Object.entries(parsed.frontmatter).filter(([, value]) => value !== undefined));
	const content = stripFrontmatter(raw).trim();
	return { name, description, frontmatter, content, raw: frontmatterToRaw(frontmatter, content) };
}

export function parseEditableSkillDocument(raw: string, expectedName: string): ParsedSkillDocument {
	const parsed = parseFrontmatter<Record<string, unknown>>(raw);
	if (typeof parsed.frontmatter.name === "string") throw new Error("Name is immutable here. Use Rename instead.");
	const frontmatter: Record<string, unknown> = {
		name: expectedName,
		...Object.fromEntries(Object.entries(parsed.frontmatter).filter(([, value]) => value !== undefined)),
	};
	const description = typeof frontmatter.description === "string" ? frontmatter.description.trim() : "";
	if (!description) throw new Error("Skill must include frontmatter field 'description'");
	const content = stripFrontmatter(raw).trim();
	return { name: expectedName, description, frontmatter, content, raw: frontmatterToRaw(frontmatter, content) };
}

export function toUpdatedSkill(skill: SkillEntry, parsed: ParsedSkillDocument): SkillEntry {
	return { ...skill, name: parsed.name, description: parsed.description, content: parsed.content, frontmatter: parsed.frontmatter };
}
