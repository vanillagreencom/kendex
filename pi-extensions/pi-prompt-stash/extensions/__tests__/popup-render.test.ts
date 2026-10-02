import { afterEach, beforeEach, expect, test } from "bun:test";

import { SELECTED, stashWorld, type StashWorld } from "./stash-fixture.ts";

let world: StashWorld;

beforeEach(() => { world = stashWorld(); });
afterEach(() => world.dispose());

async function openPopup(): Promise<{ closed: Promise<void> }> {
	const closed = world.command();
	await world.popupOpened;
	return { closed };
}

test("frames and keystrokes after the first reuse each draft's search text, preview and line count", async () => {
	const draftLength = 10_000;
	world.writeStore(Array.from({ length: 50 }, (_, index) => ({ text: `Draft ${index} NEEDLE\n${"x".repeat(draftLength)}` })));
	const { closed } = await openPopup();
	world.popup!.handleInput("n");
	world.popup!.render(92);

	// Counts each named String method call made on a whole draft while `run` runs.
	const draftCalls = (methods: Array<"split" | "toLowerCase" | "includes">, run: () => void): number => {
		const originals = methods.map((method) => [method, String.prototype[method]] as const);
		let calls = 0;
		for (const [method, original] of originals) {
			(String.prototype as Record<string, unknown>)[method] = function (this: string, ...args: unknown[]) {
				if (this.length > draftLength) calls += 1;
				return (original as (...args: unknown[]) => unknown).apply(this, args);
			};
		}
		try {
			run();
		} finally {
			for (const [method, original] of originals) (String.prototype as Record<string, unknown>)[method] = original;
		}
		return calls;
	};
	let lines: string[] = [];
	expect(draftCalls(["split", "toLowerCase"], () => {
		for (const key of "eedle") {
			world.popup!.handleInput(key);
			lines = world.popup!.render(92);
		}
	})).toBe(0);
	expect(draftCalls(["split", "toLowerCase", "includes"], () => {
		for (let frame = 0; frame < 3; frame += 1) lines = world.popup!.render(92);
	})).toBe(0);
	expect(lines.some((line) => line.includes("Draft 49 NEEDLE"))).toBe(true);

	world.popup!.handleInput("escape");
	await closed;
});

test("the list fits the overlay height and keeps the selected draft on screen", async () => {
	world.writeSettings({ listRows: 100_000 });
	world.terminalRows = 40;
	world.writeStore(Array.from({ length: 60 }, (_, index) => ({ text: `draft-${String(index).padStart(2, "0")}|` })));
	const { closed } = await openPopup();
	// pi-tui cuts the overlay at its maxHeight: the default 80% of 40 rows.
	expect(world.overlayOptions?.maxHeight).toBe("80%");
	const overlayRows = 32;
	const lines = world.popup!.render(92);
	expect(lines).toHaveLength(overlayRows);
	expect(lines.some((line) => line.includes("delete all"))).toBe(true);
	// Drafts list newest first, so draft-59 is row 0; 24 list rows fit in 32.
	for (const row of [
		{ keys: Array<string>(28).fill("down"), selected: "draft-31|" },
		{ keys: ["ctrl+u", "pagedown"], selected: "draft-35|" },
	]) {
		for (const key of row.keys) world.popup!.handleInput(key);
		const shown = world.popup!.render(92).slice(0, overlayRows).find((line) => line.includes(SELECTED));
		expect(shown).toContain(row.selected);
	}
	world.popup!.handleInput("escape");
	await closed;
});
