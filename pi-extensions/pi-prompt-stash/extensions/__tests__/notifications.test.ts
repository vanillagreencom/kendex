import { afterEach, beforeEach, expect, test } from "bun:test";

import { stashWorld, type StashWorld } from "./stash-fixture.ts";

let world: StashWorld;

beforeEach(() => { world = stashWorld(); });
afterEach(() => world.dispose());

for (const row of [
	{ name: "empty command", editorText: "", expected: "prompt_stash_items=0" },
	{ name: "saved shortcut", editorText: "draft", expected: "prompt_stash_items=1" },
]) {
	test(row.name, async () => {
		world.editorText = row.editorText;
		if (row.editorText) await world.shortcut();
		else await world.command();
		expect(world.notices).toHaveLength(1);
		expect(world.notices[0]!.message.split("\n")[0]).toBe(row.expected);
		expect(world.notices[0]!.level).toBe("info");
		if (row.editorText) {
			expect(world.storedItems()).toHaveLength(1);
			expect(world.editorText).toBe("");
		}
	});
}
