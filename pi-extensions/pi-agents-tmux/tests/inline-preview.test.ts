// The inline JSON highlighter: keys are protected before status values are
// toned, so a key that spells a status word is never coloured as one.

import assert from "node:assert/strict";
import test from "node:test";
import { highlightInlinePreview } from "../extensions/subagent/format.js";

// A theme that tags each tone so the output reads as the spans it emitted.
const tagged = {
	bg: (_tone: string, text: string) => text,
	bold: (text: string) => text,
	fg: (tone: string, text: string) => `<${tone}>${text}</${tone}>`,
	inverse: (text: string) => text,
};

// label | input | expect
const rows: Array<[string, string, string]> = [
	["a key spelling a status word stays a key", '{"ok": "passed', '{<accent>"ok"</accent><dim>:</dim> "passed'],
	["a dangling key is a key, never a value", '{"passed": }', '{<accent>"passed"</accent><dim>:</dim> }'],
	["a success value", '{"status": "passed"}', '{<accent>"status"</accent><dim>:</dim> <dim>"</dim><success>passed</success><dim>"</dim>}'],
	["a warning value", '"pending"', '<dim>"</dim><warning>pending</warning><dim>"</dim>'],
	["an error value", '"changes-requested" "failed"', '<dim>"</dim><warning>changes-requested</warning><dim>"</dim> <dim>"</dim><error>failed</error><dim>"</dim>'],
	["an unlisted value is plain", '{"status": "other"}', '{<accent>"status"</accent><dim>:</dim> "other"}'],
	["empty stays empty", "", ""],
];

test("inline JSON highlighting", () => {
	for (const [label, input, expect] of rows) {
		assert.equal(highlightInlinePreview(input, tagged as any), expect, label);
	}
});
