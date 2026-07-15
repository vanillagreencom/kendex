import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { basename, dirname, extname, join } from "node:path";
import type { ThinkingLevel, UserMessage } from "@earendil-works/pi-ai";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { GENERATE_SKILL_SYSTEM_PROMPT } from "./constants.js";
import { frontmatterToRaw, getTargetDir, normalizeSkillName, parseSkillDocument } from "./format.js";
import { isDeletableSkill } from "./registry.js";
import { settingBoolean } from "./settings.js";
import type { ParsedSkillDocument, SkillCreationAnswers, SkillEntry, SkillGenerationOptions } from "./types.js";
import { completeSimple } from "./pi-ai-compat.js";

function buildFallbackSkill(answers: SkillCreationAnswers): string {
	const frontmatter: Record<string, unknown> = { name: answers.name, description: answers.description };
	if (answers.allowedTools.length > 0) frontmatter["allowed-tools"] = answers.allowedTools.join(" ");
	const sections = [
		frontmatterToRaw(frontmatter, "").trim(),
		`# ${answers.name}`,
		"## Core workflow",
		"- Confirm the request matches the skill description and the user's current goal.",
		"- Inspect relevant inputs before acting; do not assume project-specific conventions without evidence.",
		"- Apply the most direct workflow for the task and keep outputs concrete.",
		"- Call out important edge cases, constraints, and verification steps before finishing.",
	];
	if (answers.exampleRequests?.trim()) sections.push("## Example requests", answers.exampleRequests.trim());
	if (answers.domainContext?.trim()) sections.push("## Domain context", answers.domainContext.trim());
	return `${sections.join("\n\n").trim()}\n`;
}

function getEffectiveReasoningLevel(ctx: ExtensionContext, thinkingLevel?: ThinkingLevel | "off"): ThinkingLevel | undefined {
	if (!ctx.model?.reasoning || !thinkingLevel || thinkingLevel === "off") return undefined;
	return thinkingLevel;
}

function isAbortError(error: unknown): boolean {
	if (!error || typeof error !== "object") return false;
	const name = "name" in error ? String((error as { name?: unknown }).name) : "";
	const message = "message" in error ? String((error as { message?: unknown }).message) : "";
	return name === "AbortError" || message.toLowerCase().includes("aborted");
}

async function generateSkillDraft(ctx: ExtensionContext, answers: SkillCreationAnswers, options?: SkillGenerationOptions): Promise<string> {
	if (options?.signal?.aborted) throw new Error("Generation aborted");
	if (!settingBoolean("aiGenerationEnabled", true, ctx.cwd) || !ctx.model) return buildFallbackSkill(answers);
	const auth = await ctx.modelRegistry.getApiKeyAndHeaders(ctx.model);
	if (!auth.ok || !auth.apiKey) return buildFallbackSkill(answers);

	const userMessage: UserMessage = {
		role: "user",
		content: [{
			type: "text",
			text: [
				"Create a Pi skill SKILL.md.",
				"",
				"Inputs:",
				`- skill_slug: ${answers.name}`,
				`- requested_description: ${answers.description}`,
				`- save_location: ${answers.location}`,
				answers.allowedTools.length > 0 ? `- allowed_tools: ${answers.allowedTools.join(" ")}` : "- allowed_tools: (none)",
				`- example_requests: ${answers.exampleRequests?.trim() || "(none)"}`,
				`- domain_context: ${answers.domainContext?.trim() || "(none)"}`,
				"",
				"Make the description specific enough for Pi's skill trigger list. Keep the body compact and execution-oriented.",
			].join("\n"),
		}],
		timestamp: Date.now(),
	};
	const reasoning = getEffectiveReasoningLevel(ctx, options?.thinkingLevel);
	const response = await completeSimple(
		ctx.model,
		{ systemPrompt: GENERATE_SKILL_SYSTEM_PROMPT, messages: [userMessage] },
		{ apiKey: auth.apiKey, headers: auth.headers, ...(reasoning ? { reasoning } : {}), ...(options?.signal ? { signal: options.signal } : {}) },
	);
	if (options?.signal?.aborted) throw new Error("Generation aborted");
	const generated = response.content.filter((c): c is { type: "text"; text: string } => c.type === "text").map((c) => c.text).join("\n").trim();
	if (!generated) return buildFallbackSkill(answers);
	try {
		parseSkillDocument(generated, answers.name);
		return generated;
	} catch {
		return buildFallbackSkill(answers);
	}
}

async function saveCreatedSkill(ctx: ExtensionContext, answers: SkillCreationAnswers, draft: string): Promise<SkillEntry | null> {
	let parsed: ParsedSkillDocument;
	try {
		parsed = parseSkillDocument(draft, answers.name);
	} catch (error) {
		ctx.ui.notify(error instanceof Error ? error.message : "Invalid generated SKILL.md", "error");
		return null;
	}
	const targetDir = getTargetDir(ctx, answers.location, answers.name);
	const targetPath = join(targetDir, "SKILL.md");
	await mkdir(targetDir, { recursive: true });
	await writeFile(targetPath, parsed.raw, "utf8");
	ctx.ui.notify(`Created skill: ${targetPath}`, "info");
	return {
		name: parsed.name,
		description: parsed.description,
		path: targetPath,
		content: parsed.content,
		frontmatter: parsed.frontmatter,
		scope: answers.location === "global" ? "user" : "project",
		origin: "top-level",
		source: "auto",
		baseDir: targetDir,
		enabled: true,
	};
}

export async function createSkillFromAnswers(ctx: ExtensionContext, answers: SkillCreationAnswers, options?: SkillGenerationOptions): Promise<SkillEntry | null> {
	const targetPath = join(getTargetDir(ctx, answers.location, answers.name), "SKILL.md");
	if (existsSync(targetPath)) {
		ctx.ui.notify(`Skill already exists: ${targetPath}`, "error");
		return null;
	}
	let draft: string;
	try {
		draft = await generateSkillDraft(ctx, answers, options);
	} catch (error) {
		if (isAbortError(error) || options?.signal?.aborted) return null;
		draft = buildFallbackSkill(answers);
	}
	if (options?.signal?.aborted) return null;
	return await saveCreatedSkill(ctx, answers, draft);
}

export async function renameSkillEntry(ctx: ExtensionContext, skill: SkillEntry, entered: string): Promise<SkillEntry | null> {
	if (!isDeletableSkill(skill)) {
		ctx.ui.notify("Only your own project and global skills can be renamed", "warning");
		return null;
	}
	const normalizedName = normalizeSkillName(entered);
	if (!normalizedName) throw new Error("Name must contain letters, numbers, or hyphens");
	if (normalizedName === skill.name) {
		ctx.ui.notify("Skill name unchanged", "info");
		return skill;
	}
	const isDirectorySkill = basename(skill.path).toLowerCase() === "skill.md";
	const currentTarget = isDirectorySkill ? dirname(skill.path) : skill.path;
	const parentDir = dirname(currentTarget);
	const targetPath = isDirectorySkill ? join(parentDir, normalizedName, "SKILL.md") : join(parentDir, `${normalizedName}${extname(skill.path) || ".md"}`);
	const targetTarget = isDirectorySkill ? dirname(targetPath) : targetPath;
	if (existsSync(targetTarget) || existsSync(targetPath)) throw new Error(`Skill already exists: ${normalizedName}`);
	const parsed = parseSkillDocument(readFileSync(skill.path, "utf8"), skill.name);
	const renamedFrontmatter = { ...parsed.frontmatter, name: normalizedName };
	const updatedRaw = frontmatterToRaw(renamedFrontmatter, parsed.content);
	renameSync(currentTarget, targetTarget);
	writeFileSync(targetPath, updatedRaw, "utf8");
	const renamed: SkillEntry = { ...skill, name: normalizedName, path: targetPath, frontmatter: renamedFrontmatter, baseDir: isDirectorySkill ? dirname(targetPath) : dirname(targetPath) };
	ctx.ui.notify(`Renamed skill: ${skill.name} → ${normalizedName}`, "info");
	return renamed;
}
