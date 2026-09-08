import { expect, test } from "bun:test";
import { lineCount } from "../tool-renderer/text.js";

for (const row of [
	{ text: "", expected: 0 },
	{ text: "hello", expected: 1 },
	{ text: "a\nb", expected: 2 },
	{ text: "a\nb\n", expected: 2 },
	{ text: "a\r\nb\r\n", expected: 2 },
	{ text: "\n", expected: 0 },
	{ text: "a\n\nb\n", expected: 3 },
]) {
	test(`lineCount ${JSON.stringify(row.text)}`, () => expect(lineCount(row.text)).toBe(row.expected));
}
