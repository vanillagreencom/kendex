// Deleting a skill removes its directory off the event loop, reports the
// outcome when the removal settles, and holds the manager busy meanwhile.
import { expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { deleteSkill } from "../extensions/skills-manager/registry.ts";
import type { SkillEntry } from "../extensions/skills-manager/types.ts";
import { KEYS, openManager, projectSkill, registryOf, scratchProject } from "./harness.ts";

const project = scratchProject("pi-skills-manager-delete-");
// Enough files that removing them outlasts the synchronous part of the call.
const FILE_COUNT = 10_000;

function noticeRecorder() {
	const notices: Array<{ message: string; level: string }> = [];
	const ctx = { ui: { notify: (message: string, level: string) => { notices.push({ message, level }); } } } as any;
	return { ctx, notices };
}

function writeSkillDirectory(skill: SkillEntry, extraFiles: number): string {
	const dir = dirname(skill.path);
	mkdirSync(dir, { recursive: true });
	writeFileSync(skill.path, `---\nname: ${skill.name}\ndescription: ${skill.description}\n---\n`);
	for (let i = 0; i < extraFiles; i++) writeFileSync(join(dir, `file-${i}.txt`), "x");
	return dir;
}

test("delete returns before a 10,000-file directory is removed and reports completion once it is", async () => {
	const skill = projectSkill(project.cwd, "bulky");
	const dir = writeSkillDirectory(skill, FILE_COUNT);
	const { ctx, notices } = noticeRecorder();

	const pending = deleteSkill(ctx, skill);
	const atReturn = { exists: existsSync(dir), notices: [...notices] };

	expect(atReturn).toEqual({ exists: true, notices: [] });
	expect(await pending).toBe(true);
	expect({ exists: existsSync(dir), notices }).toEqual({ exists: false, notices: [{ message: "Deleted skill: bulky", level: "info" }] });
});

test("a removal that fails is reported as an error and resolves false", async () => {
	const skill = projectSkill(project.cwd, "pinned");
	const dir = writeSkillDirectory(skill, 0);
	const parent = dirname(dir);
	const { ctx, notices } = noticeRecorder();
	// The skill directory's own entry cannot leave a parent without write access.
	chmodSync(parent, 0o500);
	try {
		expect(await deleteSkill(ctx, skill)).toBe(false);
	} finally {
		chmodSync(parent, 0o755);
	}
	expect({ exists: existsSync(dir), levels: notices.map((notice) => notice.level) }).toEqual({ exists: true, levels: ["error"] });
	expect(notices[0]!.message).toStartWith("Cannot delete skill pinned: ");
});

test("the manager takes no input while a removal is in flight, then returns to the list", async () => {
	const skill = projectSkill(project.cwd, "doomed");
	let finishRemoval: (deleted: boolean) => void = () => { throw new Error("onDelete was never called"); };
	let deleteCalls = 0;
	const manager = openManager(project.cwd, registryOf([skill]), {
		onDelete: () => { deleteCalls += 1; return new Promise<boolean>((resolve) => { finishRemoval = resolve; }); },
		onRefresh: async () => registryOf([]),
	});
	manager.component.handleInput(KEYS.down);
	manager.component.handleInput(KEYS.backspace);
	manager.component.handleInput(KEYS.enter);
	for (const key of [KEYS.enter, KEYS.escape, KEYS.tab]) manager.component.handleInput(key);
	const busy = manager.component.render(100).join("\n");

	expect({ deleteCalls, closedWith: manager.closedWith, busy: busy.includes("Deleting skill") }).toEqual({ deleteCalls: 1, closedWith: [], busy: true });
	finishRemoval(true);
	// Two turns: the removal's continuation, then the catalog reload's.
	await new Promise((resolve) => setImmediate(resolve));
	await new Promise((resolve) => setImmediate(resolve));
	const after = manager.component.render(100).join("\n");
	manager.close();
	await manager.shown;
	expect({ list: after.includes("Skills Manager"), empty: after.includes("0/0 enabled") }).toEqual({ list: true, empty: true });
});
