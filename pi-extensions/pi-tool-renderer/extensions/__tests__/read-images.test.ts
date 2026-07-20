import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { resetCapabilitiesCache, setCapabilities } from "@earendil-works/pi-tui";

import {
	clearTrackedToolExecutionComponents,
	installLiveSettingsRefresh,
	trackToolExecutionComponent,
} from "../tool-renderer/live-settings.js";
import { RESERVED_IMAGE_ROW_MARKER, TOOL_RENDER_OVERLAY_CHECK_SYMBOL } from "../tool-renderer/overlay.js";
import { recordProjectTrust } from "../tool-renderer/settings.js";
import { registerRead } from "../tool-renderer/tools.js";

const createdDirs: string[] = [];
const imageData = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";

type ReadImageSetting = "off" | "always" | "on" | boolean;

afterEach(() => {
	resetCapabilitiesCache();
	clearTrackedToolExecutionComponents();
	for (const dir of createdDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function writeSettings(cwd: string, config: Record<string, unknown>): void {
	writeFileSync(
		join(cwd, ".pi", "settings.json"),
		JSON.stringify({
			vstack: {
				extensionManager: {
					config: { "@vanillagreen/pi-tool-renderer": config },
				},
			},
		}),
	);
}

function tempCwd(showReadImages?: ReadImageSetting, overrides: Record<string, unknown> = {}): string {
	const cwd = mkdtempSync(join(tmpdir(), "pi-tool-renderer-read-images-"));
	createdDirs.push(cwd);
	mkdirSync(join(cwd, ".pi"), { recursive: true });
	const config = { ...overrides };
	if (showReadImages !== undefined) config.showReadImages = showReadImages;
	writeSettings(cwd, config);
	recordProjectTrust({ cwd, isProjectTrusted: () => true });
	return cwd;
}

function writeImageMode(cwd: string, showReadImages: ReadImageSetting): void {
	writeSettings(cwd, { showReadImages });
}

function readRenderer(cwd: string): any {
	let definition: any;
	const pi = {
		registerTool(tool: any) {
			definition = tool;
		},
	};
	const agent = {
		createReadTool: () => ({
			description: "read",
			parameters: {},
			execute: async () => ({ content: [] }),
		}),
	};
	registerRead(pi as any, agent, cwd);
	return definition;
}

function renderImageResult(
	definition: any,
	cwd: string,
	expanded: boolean,
	showImages: boolean,
	state: Record<string, unknown> = {},
	overlayCheck?: () => boolean,
): string[] {
	const context: any = {
		args: { path: "image.png" },
		cwd,
		invalidate() {},
		showImages,
		state,
	};
	if (overlayCheck) context[TOOL_RENDER_OVERLAY_CHECK_SYMBOL] = overlayCheck;
	const component = definition.renderResult(
		{
			content: [
				{ type: "text", text: "Read image file [image/png]" },
				{ type: "image", data: imageData, mimeType: "image/png" },
			],
		},
		{ expanded, isPartial: false },
		{ bold: (text: string) => text, fg: (_token: string, text: string) => text },
		context,
	);
	return component.render(40);
}

function hasTerminalImage(lines: string[]): boolean {
	return lines.some((line) => line.includes("\x1b_G"));
}

describe("read image rendering", () => {
	test("on follows expanded state across repeated toggles", () => {
		const cwd = tempCwd("on");
		const definition = readRenderer(cwd);
		const state = {};
		setCapabilities({ images: "kitty", trueColor: true, hyperlinks: true });

		expect(hasTerminalImage(renderImageResult(definition, cwd, false, false, state))).toBe(false);
		expect(hasTerminalImage(renderImageResult(definition, cwd, true, false, state))).toBe(true);
		expect(hasTerminalImage(renderImageResult(definition, cwd, false, false, state))).toBe(false);
		expect(hasTerminalImage(renderImageResult(definition, cwd, true, false, state))).toBe(true);
	});

	test("always shows images in collapsed and expanded output even when read text is hidden", () => {
		const cwd = tempCwd("always", { readOutputMode: "hidden" });
		const definition = readRenderer(cwd);
		setCapabilities({ images: "kitty", trueColor: true, hyperlinks: true });

		expect(hasTerminalImage(renderImageResult(definition, cwd, false, false))).toBe(true);
		expect(hasTerminalImage(renderImageResult(definition, cwd, true, false))).toBe(true);
	});

	test("extension settings events refresh always and off immediately", () => {
		const cwd = tempCwd("off");
		const definition = readRenderer(cwd);
		const state = {};
		const settingsHandlers = new Set<(data: unknown) => void>();
		const lifecycleHandlers = new Map<string, Array<() => void>>();
		const pi = {
			events: {
				on(channel: string, handler: (data: unknown) => void) {
					if (channel === "vstack:extension-settings-changed") settingsHandlers.add(handler);
					return () => settingsHandlers.delete(handler);
				},
			},
			on(event: string, handler: () => void) {
				const handlers = lifecycleHandlers.get(event) ?? [];
				handlers.push(handler);
				lifecycleHandlers.set(event, handlers);
			},
		};
		installLiveSettingsRefresh(pi as any);
		setCapabilities({ images: "kitty", trueColor: true, hyperlinks: true });

		let lines = renderImageResult(definition, cwd, false, false, state);
		let renderRequests = 0;
		trackToolExecutionComponent({
			invalidate() {
				lines = renderImageResult(definition, cwd, false, false, state);
			},
			ui: {
				requestRender() {
					renderRequests++;
				},
			},
		});
		const emitSetting = (value: ReadImageSetting) => {
			writeImageMode(cwd, value);
			for (const handler of settingsHandlers) {
				handler({ extensionId: "@vanillagreen/pi-tool-renderer", key: "showReadImages", value });
			}
		};

		expect(hasTerminalImage(lines)).toBe(false);
		emitSetting("always");
		expect(hasTerminalImage(lines)).toBe(true);
		emitSetting("off");
		expect(hasTerminalImage(lines)).toBe(false);
		expect(renderRequests).toBe(2);

		for (const handler of lifecycleHandlers.get("session_shutdown") ?? []) handler();
	});

	test("floating overlays hide images without removing their reserved rows", () => {
		const cwd = tempCwd("always");
		const definition = readRenderer(cwd);
		const state = {};
		let overlayActive = false;
		setCapabilities({ images: "kitty", trueColor: true, hyperlinks: true });

		const visibleLines = renderImageResult(definition, cwd, false, false, state, () => overlayActive);
		overlayActive = true;
		const hiddenLines = renderImageResult(definition, cwd, false, false, state, () => overlayActive);
		overlayActive = false;
		const restoredLines = renderImageResult(definition, cwd, false, false, state, () => overlayActive);

		expect(hasTerminalImage(visibleLines)).toBe(true);
		expect(hasTerminalImage(hiddenLines)).toBe(false);
		expect(hiddenLines).toHaveLength(visibleLines.length);
		expect(hiddenLines.some((line) => line.includes(RESERVED_IMAGE_ROW_MARKER))).toBe(true);
		expect(hasTerminalImage(restoredLines)).toBe(true);
		expect(restoredLines).toHaveLength(visibleLines.length);
	});

	test("off and an unset setting keep custom images hidden", () => {
		setCapabilities({ images: "kitty", trueColor: true, hyperlinks: true });
		for (const setting of ["off", undefined] as const) {
			const cwd = tempCwd(setting);
			const definition = readRenderer(cwd);
			expect(hasTerminalImage(renderImageResult(definition, cwd, false, false))).toBe(false);
			expect(hasTerminalImage(renderImageResult(definition, cwd, true, false))).toBe(false);
		}
	});

	test("keeps boolean true compatible with expanded-only behavior", () => {
		const cwd = tempCwd(true);
		const definition = readRenderer(cwd);
		setCapabilities({ images: "kitty", trueColor: true, hyperlinks: true });

		expect(hasTerminalImage(renderImageResult(definition, cwd, false, false))).toBe(false);
		expect(hasTerminalImage(renderImageResult(definition, cwd, true, false))).toBe(true);
	});

	test("does not duplicate Pi's built-in image rendering", () => {
		const cwd = tempCwd("always");
		const definition = readRenderer(cwd);
		setCapabilities({ images: "kitty", trueColor: true, hyperlinks: true });

		expect(hasTerminalImage(renderImageResult(definition, cwd, true, true))).toBe(false);
	});
});
