import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Image, resetCapabilitiesCache, setCapabilities, visibleWidth } from "@earendil-works/pi-tui";

import { stripAnsi } from "../tool-renderer/ansi.js";
import { __test, withResultTheme } from "../tool-renderer/chrome.js";
import { clearTrackedToolExecutionComponents, refreshToolExecutionComponents } from "../tool-renderer/live-settings.js";
import { RESERVED_IMAGE_ROW_MARKER, TOOL_RENDER_OVERLAY_CHECK_SYMBOL } from "../tool-renderer/overlay.js";
import { recordProjectTrust } from "../tool-renderer/settings.js";

const createdDirs: string[] = [];

afterEach(() => {
	resetCapabilitiesCache();
	clearTrackedToolExecutionComponents();
	for (const dir of createdDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const theme = {
	fg(token: string, text: string) {
		if (token === "borderMuted") return `\x1b[90m${text}\x1b[39m`;
		return text;
	},
};

function tempCwd(config?: Record<string, unknown>): string {
	const dir = mkdtempSync(join(tmpdir(), "pi-tool-renderer-chrome-"));
	createdDirs.push(dir);
	if (config) {
		mkdirSync(join(dir, ".pi"), { recursive: true });
		writeFileSync(join(dir, ".pi", "settings.json"), JSON.stringify({
			vstack: { extensionManager: { config: { "@vanillagreen/pi-tool-renderer": config } } },
		}));
		recordProjectTrust({ cwd: dir, isProjectTrusted: () => true });
	}
	return dir;
}

function toolComponent(cwd: string): any {
	return {
		cwd,
		toolCallId: "call-1",
		toolName: "bash",
		ui: { theme },
	};
}

describe("tool chrome", () => {
	test("self-rendered tools regain outline rules after Pi trims empty shell rows", () => {
		const cwd = tempCwd();
		const rendered = ["", "● Bash $ echo hi", ""];
		const lines = __test.renderToolChromeLines(toolComponent(cwd), rendered, 40);

		expect(lines).toHaveLength(3);
		expect(stripAnsi(lines[0]!)).toBe("─".repeat(39));
		expect(stripAnsi(lines[1]!)).toBe("● Bash $ echo hi");
		expect(stripAnsi(lines[2]!)).toBe("─".repeat(39));
		expect(lines.every((line) => visibleWidth(line) <= 39)).toBe(true);
	});

	test("transparent chrome still trims blank self-render shell rows without rules", () => {
		const cwd = tempCwd({ toolChrome: "transparent" });
		const lines = __test.renderToolChromeLines(toolComponent(cwd), ["", "● Bash $ echo hi", ""], 40);

		expect(lines).toEqual(["● Bash $ echo hi"]);
	});

	test("off chrome leaves Pi-rendered shell rows unchanged", () => {
		const cwd = tempCwd({ toolChrome: "off" });
		const rendered = ["", "● Bash $ echo hi", ""];

		expect(__test.renderToolChromeLines(toolComponent(cwd), rendered, 40)).toEqual(rendered);
	});

	test("result renderers receive live overlay state and register for settings refresh", () => {
		let overlayActive = false;
		let invalidations = 0;
		let renderRequests = 0;
		const context: any = {};
		const wrapped = withResultTheme(
			{
				invalidate: () => invalidations++,
				ui: {
					hasOverlay: () => overlayActive,
					requestRender: () => renderRequests++,
				},
			},
			(_result: any, _options: any, _theme: any, renderContext: any) => renderContext,
		);

		wrapped({}, {}, theme, context);
		expect(context[TOOL_RENDER_OVERLAY_CHECK_SYMBOL]()).toBe(false);
		overlayActive = true;
		expect(context[TOOL_RENDER_OVERLAY_CHECK_SYMBOL]()).toBe(true);
		refreshToolExecutionComponents();
		expect(invalidations).toBe(1);
		expect(renderRequests).toBe(1);
	});

	test("preserves blank rows reserved by Kitty image components", () => {
		const cwd = tempCwd();
		setCapabilities({ images: "kitty", trueColor: true, hyperlinks: true });
		const image = new Image(
			"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
			"image/png",
			{ fallbackColor: (text: string) => text },
			{ maxHeightCells: 3, maxWidthCells: 4 },
		);
		const imageLines = image.render(20);
		const rendered = ["", "read image.png", "", ...imageLines];
		const lines = __test.renderToolChromeLines(toolComponent(cwd), rendered, 20);
		const imageLineIndex = lines.findIndex((line) => line.includes("\x1b_G"));

		expect(imageLines.length).toBeGreaterThan(1);
		expect(imageLineIndex).toBeGreaterThan(0);
		expect(lines.slice(imageLineIndex + 1, -1)).toEqual(imageLines.slice(1));
	});

	test("preserves hidden image padding markers and trailing rows", () => {
		const cwd = tempCwd();
		const lines = __test.renderToolChromeLines(
			toolComponent(cwd),
			["", "read image.png", "", RESERVED_IMAGE_ROW_MARKER, "", ""],
			20,
		);
		const markerIndex = lines.findIndex((line) => line.includes(RESERVED_IMAGE_ROW_MARKER));

		expect(markerIndex).toBeGreaterThan(0);
		expect(lines.slice(markerIndex + 1, -1)).toEqual(["", ""]);
	});
});
