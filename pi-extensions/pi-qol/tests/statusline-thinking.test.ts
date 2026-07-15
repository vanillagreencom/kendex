import { expect, test } from "bun:test";
import { normalizeThinkingLevel, thinkingThemeToken } from "../extensions/qol/statusline.ts";

test("statusline preserves max thinking level", () => {
	expect(normalizeThinkingLevel("max")).toBe("max");
	expect(thinkingThemeToken("max")).toBe("thinkingMax");
});

test("statusline normalizes unknown thinking levels to off", () => {
	expect(normalizeThinkingLevel("future")).toBe("off");
});