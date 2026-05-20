import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { glyphs, glyphStyle } from "../tool-renderer/glyphs.js";

const previousAgentDir = process.env.PI_CODING_AGENT_DIR;

afterEach(() => {
	if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
});

function fixture(config: Record<string, unknown>): string {
	const root = mkdtempSync(join(tmpdir(), "vstack-glyphs-"));
	const user = join(root, "agent");
	const project = join(root, "project");
	mkdirSync(user, { recursive: true });
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeFileSync(join(user, "settings.json"), JSON.stringify({ vstack: { extensionManager: { config } } }));
	process.env.PI_CODING_AGENT_DIR = user;
	return project;
}

describe("glyph style precedence", () => {
	test("local glyphStyle=ascii selects ASCII chrome", () => {
		const cwd = fixture({ "@vanillagreen/pi-tool-renderer": { glyphStyle: "ascii" } });
		expect(glyphStyle(cwd)).toBe("ascii");
		expect(glyphs(cwd).frame.tl).toBe("+");
		expect(glyphs(cwd).bullet).toBe("* ");
	});

	test("global override wins over local unicode", () => {
		const cwd = fixture({ "@vanillagreen/pi-tool-renderer": { glyphStyle: "unicode", globalGlyphStyleOverride: "ascii" } });
		expect(glyphStyle(cwd)).toBe("ascii");
	});

	test("legacy treeStyle remains fallback", () => {
		const cwd = fixture({ "@vanillagreen/pi-tool-renderer": { treeStyle: "ascii" } });
		expect(glyphStyle(cwd)).toBe("ascii");
	});
});
