// The /skill editor saves the text it opened over the skill file, so it must
// never open on a document it could not read from that file.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { showSkillsManager } from "../extensions/skills-manager/dialog.ts";
import { recordProjectTrust } from "../extensions/skills-manager/paths.ts";
import { loadSkillRegistry } from "../extensions/skills-manager/registry.ts";

const SKILL_TEXT = "---\nname: sample\ndescription: A sample skill.\n---\n\nThe sample body.\n";
// Type the name to filter the list to the one skill, select it, open its
// preview, then press edit and save.
const KEYS = { down: "\x1b[B", tab: "\t", edit: "\x05", save: "\x13" };

let root = "";
let cwd = "";
let skillPath = "";
const previousAgentDir = process.env.PI_CODING_AGENT_DIR;

beforeAll(() => {
	root = mkdtempSync(join(tmpdir(), "pi-skills-manager-editor-"));
	cwd = join(root, "project");
	const skillDir = join(cwd, ".pi", "skills", "sample");
	mkdirSync(skillDir, { recursive: true });
	mkdirSync(join(root, "agent"));
	skillPath = join(skillDir, "SKILL.md");
	writeFileSync(skillPath, SKILL_TEXT);
	process.env.PI_CODING_AGENT_DIR = join(root, "agent");
	recordProjectTrust({ cwd, isProjectTrusted: () => true } as any);
});

afterAll(() => {
	chmodSync(skillPath, 0o644);
	rmSync(root, { recursive: true, force: true });
	if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
});

test("a skill file that cannot be read opens no editor, so Save cannot write over it", async () => {
	const registry = await loadSkillRegistry(cwd);
	const notices: Array<{ level: string }> = [];
	let input: ((data: string) => void) | undefined;
	let close: (() => void) | undefined;
	const theme = { fg: (_color: string, text: string) => text, bg: (_color: string, text: string) => text, bold: (text: string) => text };
	const tui = { requestRender() {}, terminal: { rows: 40, columns: 100 } };
	const ctx = {
		cwd,
		ui: {
			notify: (_message: string, level: string) => { notices.push({ level }); },
			custom: (factory: any) => new Promise((resolve) => {
				const component = factory(tui, theme, {}, resolve);
				input = (data) => component.handleInput(data);
				close = () => resolve(null);
			}),
		},
	} as any;
	const shown = showSkillsManager(ctx, registry, {} as any);
	for (const key of "sample") input!(key);
	input!(KEYS.down);
	input!(KEYS.tab);
	// Write-only: the read fails where a write would still succeed.
	chmodSync(skillPath, 0o200);
	input!(KEYS.edit);
	input!(KEYS.save);
	await new Promise((resolve) => setImmediate(resolve));
	chmodSync(skillPath, 0o644);
	close!();
	await shown;
	expect({ notices, file: readFileSync(skillPath, "utf8") }).toEqual({ notices: [{ level: "error" }], file: SKILL_TEXT });
});
