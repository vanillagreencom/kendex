import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";

import { stashWorld, type StashWorld } from "./stash-fixture.ts";

const MAX_ITEMS = 500;
const MAX_STORE_BYTES = 8 * 1024 * 1024;

let world: StashWorld;

beforeEach(() => { world = stashWorld(); });
afterEach(() => world.dispose());

for (const row of [
	{ name: "item limit", seed: Array.from({ length: MAX_ITEMS }, (_, index) => ({ text: `draft ${index}` })), stash: "one more", key: "prompt_stash_refused=item-limit value=501" },
	{ name: "byte limit", seed: [{ text: "x".repeat(MAX_STORE_BYTES - 1024) }], stash: "y".repeat(2048), key: "prompt_stash_refused=byte-limit value=" },
	{ name: "oversized store file", seed: [{ text: "x".repeat(MAX_STORE_BYTES) }], stash: "draft", key: "prompt_stash_refused=store-too-large value=" },
]) {
	test(`stash refuses past the ${row.name}`, async () => {
		world.writeStore(row.seed);
		world.editorText = row.stash;
		await world.shortcut();
		expect(world.notices).toHaveLength(1);
		expect(world.notices[0]!.message.split("\n")[0]!.startsWith(row.key)).toBe(true);
		expect(world.notices[0]!.level).toBe("error");
		expect(world.editorText).toBe(row.stash);
		expect(world.storedItems()).toHaveLength(row.seed.length);
	});
}

test("popup refuses to load an oversized store file", async () => {
	world.writeStore([{ text: "x".repeat(MAX_STORE_BYTES) }]);
	await world.command();
	expect(world.notices.map((notice) => notice.message.split("\n")[0])).toEqual([`prompt_stash_refused=store-too-large value=${world.storeFile}`]);
	expect(world.popup).toBeUndefined();
});

test("concurrent stashes both land and keep text typed during the write", async () => {
	world.editorText = "first";
	const first = world.shortcut();
	world.editorText = "second";
	const second = world.shortcut();
	await first;
	expect(world.editorText).toBe("second");
	await second;
	expect(world.editorText).toBe("");
	expect(world.storedItems().map((item) => item.text).sort()).toEqual(["first", "second"]);
	expect(world.notices.map((notice) => notice.message.split("\n")[0])).toEqual(["prompt_stash_items=1", "prompt_stash_items=2"]);
});

const firstLines = () => world.notices.map((notice) => notice.message.split("\n")[0]);

for (const row of [
	{ name: "alt+d deletes the selected draft", keys: ["alt+d"], kept: ["older"] },
	{ name: "alt+x then return deletes every draft", keys: ["alt+x", "return"], kept: [] },
]) {
	test(`popup ${row.name} from the store`, async () => {
		world.writeStore([{ text: "older" }, { text: "newer" }]);
		const closed = world.command();
		await world.popupOpened;
		for (const key of row.keys) world.popup!.handleInput(key);
		await world.nextHostCall();
		world.popup!.handleInput("escape");
		await closed;
		expect(world.storedItems().map((item) => item.text)).toEqual(row.kept);
		expect(firstLines()).toEqual([]);
	});
}

test("a popup delete keeps a draft stashed while the popup was loading", async () => {
	world.writeStore([{ text: "older" }]);
	const closed = world.command();
	world.editorText = "newer";
	await world.shortcut();
	await world.popupOpened;
	world.popup!.handleInput("alt+d");
	await world.nextHostCall();
	expect(world.storedItems().map((item) => item.text)).toEqual(["newer"]);
	expect(world.popup!.render(92).some((line) => line.includes("newer"))).toBe(true);
	world.popup!.handleInput("escape");
	await closed;
});

test("a popup delete that cannot write reports prompt_stash_save_failed", async () => {
	world.writeStore([{ text: "older" }, { text: "newer" }]);
	const closed = world.command();
	await world.popupOpened;
	rmSync(world.storeFile);
	mkdirSync(join(world.storeFile, "blocker"), { recursive: true });
	world.popup!.handleInput("alt+d");
	await world.nextHostCall();
	expect(firstLines()).toEqual(["prompt_stash_save_failed"]);
	expect(world.notices[0]!.level).toBe("error");
	world.popup!.handleInput("escape");
	await closed;
});
