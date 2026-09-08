import { useWorld } from "./helpers/world.js";
import { describe, expect, test } from "bun:test";

import {
	lineCount,
	makeTruncatedLines,
	normalizeTerminalText,
	splitTerminalLines,
} from "../tool-renderer/text.js";

useWorld();

describe("terminal output normalization", () => {
	test("normalizes CRLF and lone CR before line processing", () => {
		expect(normalizeTerminalText("one\r\ntwo\rthree")).toBe("one\ntwo\nthree");
		expect(splitTerminalLines("one\r\ntwo\rthree")).toEqual(["one", "two", "three"]);
		expect(lineCount("one\r\ntwo\rthree")).toBe(3);
	});

	test("expands visible tabs to Pi TUI's fixed three-column width", () => {
		expect(normalizeTerminalText("a\tb")).toBe("a   b");
		expect(makeTruncatedLines("a\tb").render(80)).toEqual(["a   b"]);
	});
});
