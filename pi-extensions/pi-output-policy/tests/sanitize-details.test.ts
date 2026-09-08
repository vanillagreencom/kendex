import { expect, test } from "bun:test";
import { sanitizeDetails } from "../extensions/output-policy.ts";

test("detail value limits", () => {
	let deep: unknown = { leaf: true };
	for (let i = 0; i < 10; i += 1) deep = { child: deep };
	const small = { ok: true, count: 3, label: "x" };
	for (const [name, input, changed] of [
		["string", { note: "a".repeat(20_000) }, true],
		["array", Array.from({ length: 200 }, (_, i) => ({ i })), true],
		["deep", deep, true], ["small", small, false],
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
				expect(typeof array[49]).toBe("string");
				expect((array[49] as string).split("\n")[0]).toBe("[output-policy:detail-array-dropped=151]");
				break;
			}
			case "deep":
				expect(JSON.stringify(result.value)).toContain("[output-policy:detail-depth=5]");
				break;
			case "small": expect(result.value).toEqual(small); break;
		}
	}
});
