// Shared fixtures for this package's suites: an isolated project and Pi user
// directory, and the /skill manager overlay driven the way Pi's
// ctx.ui.custom drives it.
import { afterAll, beforeAll } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { showSkillsManager } from "../extensions/skills-manager/dialog.ts";
import { clearPackageConfigCache, recordProjectTrust } from "../extensions/skills-manager/package-config.ts";
import type { SkillEntry, SkillRegistry, SkillsManagerOptions } from "../extensions/skills-manager/types.ts";

export const KEYS = { down: "\x1b[B", tab: "\t", enter: "\r", escape: "\x1b", backspace: "\x7f", edit: "\x05", save: "\x13", toggle: "\x18" };

/** A theme that adds no styling, so rendered text compares as plain text. */
export const plainTheme = { fg: (_color: string, text: string) => text, bg: (_color: string, text: string) => text, bold: (text: string) => text };

export interface ScratchProject {
	/** The suite's scratch root, removed after the suite. */
	root: string;
	/** A trusted project directory under the root. */
	cwd: string;
}

/**
 * Registers hooks that give the suite a trusted project and an empty Pi user
 * directory, so settings reads never reach the developer's own files. The
 * fields fill in before the suite's first test.
 */
export function scratchProject(prefix: string): ScratchProject {
	const project: ScratchProject = { root: "", cwd: "" };
	const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
	beforeAll(() => {
		project.root = mkdtempSync(join(tmpdir(), prefix));
		project.cwd = join(project.root, "project");
		mkdirSync(project.cwd);
		mkdirSync(join(project.root, "agent"));
		process.env.PI_CODING_AGENT_DIR = join(project.root, "agent");
		clearPackageConfigCache();
		recordProjectTrust({ cwd: project.cwd, isProjectTrusted: () => true } as any);
	});
	afterAll(() => {
		rmSync(project.root, { recursive: true, force: true });
		if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
		clearPackageConfigCache();
	});
	return project;
}

/** A top-level project skill, which the manager lists under Your Skills. */
export function projectSkill(cwd: string, name: string, description = `The ${name} skill.`): SkillEntry {
	const baseDir = join(cwd, ".pi", "skills");
	return { name, description, frontmatter: { name, description }, path: join(baseDir, name, "SKILL.md"), scope: "project", origin: "top-level", source: "local", baseDir, enabled: true };
}

export function registryOf(allSkills: SkillEntry[]): SkillRegistry {
	const skills = allSkills.filter((skill) => skill.enabled);
	return { skills, allSkills, byName: new Map(skills.map((skill) => [skill.name, skill])) };
}

export interface OpenManager {
	component: { render(width: number): string[]; handleInput(data: string): void };
	notices: Array<{ message: string; level: string }>;
	/** Each value the manager closed with: a skill to insert, or null. */
	closedWith: Array<SkillEntry | null>;
	shown: Promise<SkillEntry | null>;
	close(): void;
}

export function openManager(cwd: string, registry: SkillRegistry, options: Partial<SkillsManagerOptions> = {}): OpenManager {
	const notices: OpenManager["notices"] = [];
	const closedWith: OpenManager["closedWith"] = [];
	let component: OpenManager["component"] | undefined;
	let close: (() => void) | undefined;
	const tui = { requestRender() {}, terminal: { rows: 40, columns: 100 } };
	const ctx = {
		cwd,
		ui: {
			notify: (message: string, level: string) => { notices.push({ message, level }); },
			custom: (factory: any) => new Promise((resolve) => {
				component = factory(tui, plainTheme, {}, (value: SkillEntry | null) => { closedWith.push(value); resolve(value); });
				close = () => resolve(null);
			}),
		},
	} as any;
	const shown = showSkillsManager(ctx, registry, options as SkillsManagerOptions);
	if (!component || !close) throw new Error("showSkillsManager did not open its overlay through ctx.ui.custom");
	return { component, notices, closedWith, shown, close };
}
