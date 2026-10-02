// The browse list matches a query against text built once per catalog load:
// a keystroke or a frame reads no catalog entry the query does not match.
import { expect, test } from "bun:test";

import type { SkillEntry } from "../extensions/skills-manager/types.ts";
import { KEYS, openManager, projectSkill, registryOf, scratchProject } from "./harness.ts";

const project = scratchProject("pi-skills-manager-search-");
// Catalog paths sit under a fixed root rather than the random scratch
// directory, so no fixture field holds an "x" and every prefix of this query
// matches nothing. Nothing reads these paths.
const CATALOG_ROOT = "/catalog";
const QUERY = "xxxxxxxxxx";

test("typing a query and rendering read no catalog entry once the catalog is loaded", async () => {
	let reads = 0;
	const counted = (skill: SkillEntry): SkillEntry => new Proxy(skill, { get(target, key, receiver) { reads += 1; return Reflect.get(target, key, receiver); } });
	const catalog = Array.from({ length: 50 }, (_, i) => counted(projectSkill(CATALOG_ROOT, `skill-${i}`)));
	const manager = openManager(project.cwd, registryOf(catalog));
	const loaded = manager.component.render(100).join("\n");
	reads = 0;
	const frames: string[] = [];
	for (const key of QUERY) {
		manager.component.handleInput(key);
		frames.push(manager.component.render(100).join("\n"));
	}
	manager.close();
	await manager.shown;

	expect(loaded).toContain("skill-0");
	expect({ reads, lastFrameEmpty: frames.at(-1)!.includes("No skills match your search.") }).toEqual({ reads: 0, lastFrameEmpty: true });
});

test("a catalog reload rebuilds the text a query matches against", async () => {
	const original = projectSkill(project.cwd, "original");
	const added = projectSkill(project.cwd, "added", "Arrived with the reload.");
	const manager = openManager(project.cwd, registryOf([original]), {
		onToggle: async () => {},
		onRefresh: async () => registryOf([original, added]),
	});
	manager.component.handleInput(KEYS.down);
	manager.component.handleInput(KEYS.toggle);
	// Two turns: the toggle's continuation, then the catalog reload's.
	await new Promise((resolve) => setImmediate(resolve));
	await new Promise((resolve) => setImmediate(resolve));
	for (const key of "arrived") manager.component.handleInput(key);
	const frame = manager.component.render(100).join("\n");
	manager.close();
	await manager.shown;

	expect({ added: frame.includes("added"), original: frame.includes("original") }).toEqual({ added: true, original: false });
});
