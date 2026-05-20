import { describe, expect, test } from "bun:test";

import { visibleWidth } from "@earendil-works/pi-tui";

import { __test } from "../tool-renderer/messages.js";

const OSC133_ZONE_START = "\x1b]133;A\x07";
const OSC133_ZONE_END = "\x1b]133;B\x07";
const OSC133_ZONE_FINAL = "\x1b]133;C\x07";
const ANSI_RE = /\x1b(?:\[[0-9;:]*m|\]133;[ABC]\x07)/g;

const theme = {
	fg(_token: string, text: string) {
		return text;
	},
};

function stripControl(text: string): string {
	return text.replace(ANSI_RE, "");
}

describe("compact user-message OSC 133 prompt zones", () => {
	test("single-line upstream message markers move from content row to outer frame", () => {
		const upstreamSingleLine = `${OSC133_ZONE_END}${OSC133_ZONE_FINAL}${OSC133_ZONE_START}hello`;
		const rendered = __test.renderUserMessageBorder([upstreamSingleLine], 20, theme);

		expect(rendered).toHaveLength(3);
		expect(rendered[0]!.startsWith(OSC133_ZONE_START)).toBe(true);
		expect(rendered[1]!).not.toContain(OSC133_ZONE_START);
		expect(rendered[1]!).not.toContain(OSC133_ZONE_END);
		expect(rendered[1]!).not.toContain(OSC133_ZONE_FINAL);
		expect(rendered[2]!.startsWith(`${OSC133_ZONE_END}${OSC133_ZONE_FINAL}`)).toBe(true);
		expect(rendered.join("").match(/\]133;[ABC]\x07/g)).toHaveLength(3);

		const middle = stripControl(rendered[1]!);
		expect(middle).toMatch(/^┃hello +┃$/);
		expect(visibleWidth(rendered[0]!)).toBe(20);
		expect(visibleWidth(rendered[1]!)).toBe(20);
		expect(visibleWidth(rendered[2]!)).toBe(20);
	});

	test("strips prompt zone markers from all inner lines before framing", () => {
		const stripped = __test.stripPromptZoneMarkers([
			`${OSC133_ZONE_START}first`,
			`middle${OSC133_ZONE_END}`,
			`${OSC133_ZONE_FINAL}last`,
		]);

		expect(stripped.lines).toEqual(["first", "middle", "last"]);
		expect(stripped.markers).toEqual({ start: true, end: true, final: true });
	});
});
