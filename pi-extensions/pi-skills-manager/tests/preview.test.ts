// The skill preview lays its content out once per width; scrolling and
// repeated frames reuse that layout, and a theme or content change rebuilds it.
import { afterAll, expect, spyOn, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { Markdown } from "@earendil-works/pi-tui";

import { ScrollableSkillPreview } from "../extensions/skills-manager/components.ts";
import { KEYS, plainTheme, projectSkill, scratchProject } from "./harness.ts";

const project = scratchProject("pi-skills-manager-preview-");
const markdownRender = spyOn(Markdown.prototype, "render");
afterAll(() => markdownRender.mockRestore());

// Each step's count is the number of times the skill body is laid out anew.
const STEPS: Array<{ step: string; act: (preview: ScrollableSkillPreview) => void; layouts: number }> = [
	{ step: "first frame", act: (preview) => preview.render(100), layouts: 1 },
	{ step: "same width again", act: (preview) => preview.render(100), layouts: 0 },
	{ step: "scroll down a line", act: (preview) => { preview.handleInput(KEYS.down); preview.render(100); }, layouts: 0 },
	{ step: "new width", act: (preview) => preview.render(80), layouts: 1 },
	{ step: "invalidate, as on a theme change", act: (preview) => { preview.invalidate(); preview.render(80); }, layouts: 1 },
	{ step: "new content", act: (preview) => { preview.setSkill(projectSkill(project.cwd, "long", "Edited.")); preview.render(80); }, layouts: 1 },
];

test.each(STEPS.map((row, index) => ({ ...row, index })))("preview layout: $step", (row) => {
	const preview = previewFor();
	for (const earlier of STEPS.slice(0, row.index)) earlier.act(preview);
	markdownRender.mockClear();
	row.act(preview);
	expect(markdownRender).toHaveBeenCalledTimes(row.layouts);
});

function previewFor(): ScrollableSkillPreview {
	const skill = projectSkill(project.cwd, "long");
	mkdirSync(dirname(skill.path), { recursive: true });
	const body = Array.from({ length: 200 }, (_, i) => `Line ${i} of a long skill body.`).join("\n\n");
	writeFileSync(skill.path, `---\nname: long\ndescription: ${skill.description}\n---\n\n${body}\n`);
	return new ScrollableSkillPreview(skill, plainTheme as any, () => 40);
}
