import { expect, test } from "bun:test";
import { sanitizeDetails } from "../extensions/output-policy.ts";

test("detail value limits", () => {
	let deep: unknown = { leaf: true };
	for (let i = 0; i < 10; i += 1) deep = { child: deep };
	const small = { ok: true, count: 3, label: "x", list: [1, { nested: "y" }] };
	// 40 objects of 60 numbers: 2,441 values, past the 2,000-value traversal budget.
	const wide = Array.from({ length: 40 }, (_, i) => Object.fromEntries(Array.from({ length: 60 }, (_, j) => [`k${j}`, i * j])));
	// 40 x 49 objects of 79 keys each put 154,840 values at depth 5, each one
	// replaced by a detail-depth notice.
	const broad = { a: { b: Array.from({ length: 40 }, () => Array.from({ length: 49 }, () => Object.fromEntries(Array.from({ length: 79 }, (_, j) => [`k${j}`, {}])))) } };
	for (const [name, input, changed] of [
		["string", { note: "a".repeat(20_000) }, true],
		["array", Array.from({ length: 200 }, (_, i) => ({ i })), true],
		["deep", deep, true], ["small", small, false],
		["nodes", wide, true],
		["depth-nodes", broad, true],
	] as const) {
		const result = sanitizeDetails(input);
		expect(result.changed).toBe(changed);
		switch (name) {
			case "string": {
				const note = (result.value as { note: string }).note;
				expect(note.length).toBeLessThanOrEqual(8 * 1024 + 100);
				expect(note).toContain("[output-policy:detail-chars=20000]");
				break;
			}
			case "array": {
				const array = result.value as unknown[];
				expect(Array.isArray(array)).toBe(true);
				expect(array).toHaveLength(50);
				expect(array.slice(0, 49)).toEqual(input.slice(0, 49));
				expect(array[0]).toBe(input[0]);
				expect(typeof array[49]).toBe("string");
				expect((array[49] as string).split("\n")[0]).toBe("[output-policy:detail-array-dropped=151]");
				break;
			}
			case "deep":
				expect(JSON.stringify(result.value)).toContain("[output-policy:detail-depth=5]");
				break;
			case "small": expect(result.value).toBe(small); break;
			case "nodes": {
				// The array and 32 whole objects spend 1,953 values; the 33rd object
				// stops at its 47th key, and the array stops after it.
				const array = result.value as Array<Record<string, unknown> | string>;
				const notice = "[output-policy:detail-node-budget=2000]";
				expect(array).toHaveLength(34);
				expect(array[31]).toBe(wide[31]);
				const cut = array[32] as Record<string, unknown>;
				expect(Object.keys(cut)).toHaveLength(47);
				expect((cut["[output-policy:truncated]"] as string).split("\n")[0]).toBe(notice);
				expect((array[33] as string).split("\n")[0]).toBe(notice);
				break;
			}
			case "depth-nodes": {
				// A depth-capped value spends a node like any other.
				const json = JSON.stringify(result.value);
				expect(json).toContain("[output-policy:detail-node-budget=2000]");
				expect(json.split("[output-policy:detail-depth=5]").length - 1).toBeLessThan(2_000);
				break;
			}
		}
	}
});

test("detail byte budget", () => {
	const notice = "[output-policy:detail-byte-budget=65536]";
	const strings = (count: number, fill: string, chars: number) => Array.from({ length: count }, (_, i) => `${i}`.padEnd(chars, fill));
	// Each input holds more than 64 KiB of string text: 40 x 2,000 ASCII bytes;
	// 33 x 2,000 ASCII bytes whose cut string is the last key; 40 x 6,000 bytes
	// of three-byte characters, whose cut leaves bytes no whole character fits.
	for (const [name, input] of [
		["ascii", strings(40, "s", 2_000)],
		["last-key", Object.fromEntries(strings(33, "s", 2_000).map((value, i) => [`k${i}`, value]))],
		["multibyte", strings(40, "漢", 2_000)],
	] as const) {
		const result = sanitizeDetails(input);
		expect(result.changed).toBe(true);
		const values = Object.values(result.value as Record<string, string>);
		const cut = values.filter((value) => value.includes(`…\n${notice}\n`));
		expect(cut).toHaveLength(1);
		expect(values.some((value) => value.includes("[output-policy:detail-chars="))).toBe(false);
		const kept = values.filter((value) => !value.startsWith("[output-policy:")).map((value) => value.split(`…\n${notice}`)[0]);
		expect(kept.reduce((sum, value) => sum + Buffer.byteLength(value), 0)).toBeLessThanOrEqual(64 * 1024);
		expect(Buffer.from(kept.at(-1)!).toString()).toBe(kept.at(-1)!);
		if (name === "last-key") expect(values.at(-1)).toBe(cut[0]);
		else expect(values.at(-1)!.split("\n")[0]).toBe(notice);
	}
});
