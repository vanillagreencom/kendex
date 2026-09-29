import { afterAll, beforeAll, expect, mock, spyOn, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import * as registryModule from "../extensions/skills-manager/registry.ts";
import { readSkillBody } from "../extensions/skills-manager/format.ts";
import { recordProjectTrust } from "../extensions/skills-manager/paths.ts";
import skillsManager from "../extensions/skills-manager.ts";

let root = "";
let cwd = "";
const previousAgentDir = process.env.PI_CODING_AGENT_DIR;

beforeAll(() => {
	root = mkdtempSync(join(tmpdir(), "pi-skills-manager-inventory-"));
	cwd = join(root, "project");
	const skillDir = join(cwd, ".pi", "skills", "sample");
	mkdirSync(skillDir, { recursive: true });
	mkdirSync(join(root, "agent"));
	writeFileSync(join(skillDir, "SKILL.md"), "---\nname: sample\ndescription: A sample skill.\n---\n\nThe sample body.\n");
	process.env.PI_CODING_AGENT_DIR = join(root, "agent");
	recordProjectTrust({ cwd, isProjectTrusted: () => true } as any);
});

afterAll(() => {
	rmSync(root, { recursive: true, force: true });
	if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
	mock.restore();
});

test("the inventory holds no skill body; the body is read for the skill shown", async () => {
	const registry = await registryModule.loadSkillRegistry(cwd);
	const sample = registry.allSkills.find((skill) => skill.name === "sample");
	expect(sample).toBeDefined();
	expect("content" in sample!).toBe(false);
	expect(readSkillBody(sample!)).toBe("The sample body.");
});

test("session_start loads no inventory, with or without a UI", async () => {
	const load = spyOn(registryModule, "loadSkillRegistry");
	const handlers = new Map<string, (event: unknown, ctx: unknown) => unknown>();
	skillsManager({
		on: (name: string, handler: (event: unknown, ctx: unknown) => unknown) => handlers.set(name, handler),
		registerCommand() {},
	} as any);
	for (const hasUI of [false, true]) {
		await handlers.get("session_start")!({ type: "session_start" }, { cwd, hasUI, isProjectTrusted: () => true, ui: { notify() {} } });
	}
	expect(load).toHaveBeenCalledTimes(0);
});
