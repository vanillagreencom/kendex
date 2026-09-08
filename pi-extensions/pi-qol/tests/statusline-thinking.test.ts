import { expect, test } from "bun:test";
import { normalizeThinkingLevel, thinkingThemeToken } from "../extensions/qol/statusline.ts";

const thinkingRows = [
	{ name: "max thinking level", input: "max", expected: "max" },
	{ name: "unknown thinking level", input: "future", expected: "off" },
];

if (thinkingRows.length === 0) throw new Error("Thinking normalization table is empty");

for (const row of thinkingRows) {
	test(row.name, () => {
		expect.hasAssertions();
		expect(normalizeThinkingLevel(row.input)).toBe(row.expected);
	});
}

test("max thinking theme token", () => {
	expect.hasAssertions();
	expect(thinkingThemeToken("max")).toBe("thinkingMax");
});
