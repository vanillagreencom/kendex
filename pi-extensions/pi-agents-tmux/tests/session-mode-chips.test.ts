// The session-mode chip and detail labels: one rule each, read by the
// result renderer, the dashboard row and the Monitor session detail.

import assert from "node:assert/strict";
import test from "node:test";
import { paneSessionModeToRecordMode, sessionModeChipLabel, sessionModeDetailLabel, truncateSessionKeyForChip } from "../extensions/subagent/format.js";
import { ABSENT } from "./browser-fixture.js";

// label | kind | sessionMode | sessionKey | expect
const chipRows: Array<[string, string | undefined, unknown, string | undefined, string]> = [
	["bg fresh", "oneshot", "fresh", undefined, "fresh"],
	["bg resumed on a lane", "oneshot", "resumed", "issue-27", "lane:issue-27"],
	["bg resumed, no lane key", "oneshot", "resumed", undefined, "resumed"],
	["bg resumed, blank lane key", "oneshot", "resumed", "  ", "resumed"],
	["long lane key keeps its suffix", "oneshot", "resumed", "feature-x-iss-12345", "lane:featur…2345"],
	["a sibling long key differs by suffix", "oneshot", "resumed", "feature-x-iss-12399", "lane:featur…2399"],
	["pane new", "pane", "new", undefined, "new"],
	["pane resumed", "pane", "resumed", undefined, "resumed"],
	["pane with a fresh mode falls through to the mode", "pane", "fresh", undefined, "fresh"],
	["corrupt mode", "oneshot", "foo", "issue-27", ABSENT],
	["no mode", "oneshot", undefined, "issue-27", ABSENT],
	["no kind", undefined, "fresh", undefined, ABSENT],
];

test("session-mode chip label", () => {
	for (const [label, kind, sessionMode, sessionKey, expect] of chipRows) {
		assert.equal(sessionModeChipLabel({ kind, sessionMode, sessionKey }) ?? ABSENT, expect, label);
	}
});

// label | sessionMode | sessionKey | expect
const detailRows: Array<[string, unknown, string | undefined, string]> = [
	["resumed on a lane", "resumed", "feature-x", "resumed · lane: feature-x"],
	["fresh", "fresh", undefined, "fresh"],
	["blank key reads as no lane", "new", " ", "new"],
	["corrupt mode", "foo", "feature-x", ABSENT],
];

test("session-mode detail label", () => {
	for (const [label, sessionMode, sessionKey, expect] of detailRows) {
		assert.equal(sessionModeDetailLabel({ sessionMode, sessionKey }) ?? ABSENT, expect, label);
	}
});

// label | key | maxChars | expect
const truncateRows: Array<[string, string | undefined, number, string]> = [
	["under the cap is whole", "issue-27", 14, "issue-27"],
	["at the cap is whole", "abcdefghijklmn", 14, "abcdefghijklmn"],
	["over the cap keeps six and four", "abcdefghijklmno", 14, "abcdef…lmno"],
	["blank is absent", "  ", 14, ABSENT],
	["undefined is absent", undefined, 14, ABSENT],
];

test("lane key truncation for a chip", () => {
	for (const [label, key, maxChars, expect] of truncateRows) {
		assert.equal(truncateSessionKeyForChip(key, maxChars) ?? ABSENT, expect, label);
	}
});

// label | paneSessionMode | expect
const paneModeRows: Array<[string, "live" | "resumed" | "new" | undefined, string]> = [
	["live pane resumed its session", "live", "resumed"],
	["resumed", "resumed", "resumed"],
	["new", "new", "new"],
	["unset", undefined, ABSENT],
];

test("pane session mode to record mode", () => {
	for (const [label, mode, expect] of paneModeRows) {
		assert.equal(paneSessionModeToRecordMode(mode) ?? ABSENT, expect, label);
	}
});
