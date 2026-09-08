import { expect, test } from "bun:test";
import { chunkConversationText } from "../extensions/qol/budget-guard.ts";

const cases = [
	{ name: "under the cap", text: "short", cap: 200, expected: ["short"] },
	{ name: "disabled cap", text: "any text", cap: 0, expected: ["any text"] },
	{
		name: "paragraph boundaries preserve the complete conversation",
		text: ["msg-a-line1\nmsg-a-line2", "msg-b-line1", "msg-c-line1", "msg-d-line1"].join("\n\n"),
		cap: 30,
		expected: ["msg-a-line1\nmsg-a-line2\n\n", "msg-b-line1\n\nmsg-c-line1\n\n", "msg-d-line1"],
	},
	{ name: "hard split without paragraph boundaries", text: "a".repeat(500), cap: 100, expected: Array(5).fill("a".repeat(100)) },
];

if (cases.length === 0) throw new Error("chunk cases are empty");
for (const row of cases) {
	test(`chunkConversationText: ${row.name}`, () => {
		expect(chunkConversationText(row.text, row.cap)).toEqual(row.expected);
	});
}
