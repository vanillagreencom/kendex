import { expect, test } from "bun:test";
import { sanitizeDetails } from "../extensions/output-policy.ts";

test("detail value limits", () => {
	let deep: unknown = { leaf: true };
	for (let i = 0; i < 10; i += 1) deep = { child: deep };
	const small = { ok: true, count: 3, label: "x", list: [1, { nested: "y" }] };
	// 40 objects of 60 numbers: 2,441 values, past the 2,000-value traversal budget.
	const wide = Array.from({ length: 40 }, (_, i) => Object.fromEntries(Array.from({ length: 60 }, (_, j) => [`k${j}`, i * j])));
	// 40 strings of 2,000 bytes each: 80,000 bytes, past the 64 KiB byte budget.
	const heavy = Array.from({ length: 40 }, (_, i) => `${i}`.padEnd(2_000, "s"));
	for (const [name, input, changed] of [
		["string", { note: "a".repeat(20_000) }, true],
		["array", Array.from({ length: 200 }, (_, i) => ({ i })), true],
		["deep", deep, true], ["small", small, false],
		["nodes", wide, true], ["bytes", heavy, true],
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
			case "bytes": {
				const array = result.value as string[];
				const kept = array.slice(0, -1);
				expect(array.at(-1)!.split("\n")[0]).toBe("[output-policy:detail-byte-budget=65536]");
				expect(kept.filter((value) => !value.includes("[output-policy:")).reduce((sum, value) => sum + Buffer.byteLength(value), 0)).toBeLessThanOrEqual(64 * 1024);
				expect(kept.at(-1)!).toContain("[output-policy:detail-chars=2000]");
				break;
			}
		}
	}
});
