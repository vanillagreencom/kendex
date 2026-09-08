import { useWorld } from "./helpers/world.js";
import { describe, expect, test } from "bun:test";

import { visibleWidth } from "@earendil-works/pi-tui";

import { __test } from "../tool-renderer/messages.js";

const ANSI_RE = /\x1b(?:\[[0-9;:]*m|\]133;[ABC]\x07)/g;

const theme = {
	bg(_token: string, text: string) {
		return `\x1b[48;5;236m${text}\x1b[49m`;
	},
	codeBlock(text: string) {
		return text;
	},
	highlightCode(code: string) {
		return code.split("\n");
	},
};

function stripControl(text: string): string {
	return text.replace(ANSI_RE, "");
}

useWorld();

describe("styled markdown code blocks", () => {
	test("render code flush-left with background but no copy gutter", () => {
		const rendered = __test.renderStyledCodeBlock({ type: "code", lang: "bash", text: "echo hi\nprintf ok" }, 20, theme);

		expect(rendered).toHaveLength(2);
		expect(stripControl(rendered[0]!)).toBe("echo hi" + " ".repeat(12));
		expect(stripControl(rendered[1]!)).toBe("printf ok" + " ".repeat(10));
		expect(stripControl(rendered[0]!).startsWith(" ")).toBe(false);
		expect(stripControl(rendered[0]!)).not.toContain("┃");
		expect(stripControl(rendered[0]!)).not.toContain("│");
		expect(rendered[0]!).toContain("\x1b[48;5;236m");
		expect(visibleWidth(rendered[0]!)).toBe(19);
	});
});
