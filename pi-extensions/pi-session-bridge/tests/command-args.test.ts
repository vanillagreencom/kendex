import { expect, test } from "bun:test";
import { parseCommandArgs } from "../extensions/session-bridge.ts";

for (const row of [
	{ input: "one 'two words' \"three words\" four", expected: ["one", "two words", "three words", "four"] },
	{ input: "one\ntwo 'three\nfour'\tfive", expected: ["one", "two", "three\nfour", "five"] },
]) {
	test(`parse command arguments ${JSON.stringify(row.input)}`, () => expect(parseCommandArgs(row.input)).toEqual(row.expected));
}
