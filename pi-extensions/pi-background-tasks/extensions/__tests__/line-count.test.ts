import { expect, test } from "bun:test";
import { lineCount } from "../format.js";

const rows = [
	{ name: "empty string", text: "", expected: 0 },
	{ name: "single line", text: "hello", expected: 1 },
	{ name: "two lines", text: "a\nb", expected: 2 },
	{ name: "trailing LF", text: "a\nb\n", expected: 2 },
	{ name: "trailing CRLF", text: "a\r\nb\r\n", expected: 2 },
	{ name: "lone newline", text: "\n", expected: 0 },
	{ name: "blank interior line", text: "a\n\nb\n", expected: 3 },
];

test("line count", () => {
	expect.hasAssertions();
	for (const row of rows) expect(lineCount(row.text), row.name).toBe(row.expected);
});
