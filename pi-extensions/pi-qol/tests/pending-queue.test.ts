import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Text } from "@earendil-works/pi-tui";

import * as ansi from "../extensions/qol/ansi.ts";
import { STATUS_TEXT_ALIGNMENT_PATCH_SYMBOL } from "../extensions/qol/constants.ts";
import { clearPackageConfigCache } from "../extensions/qol/package-config.ts";

// Counts the classification's scans: each classification strips ANSI from the
// whole text once, so a stripAnsi call is one scan. The wrapper delegates, so
// every other suite sharing this module sees the real behaviour.
const realStripAnsi = ansi.stripAnsi;
let stripAnsiCalls = 0;
mock.module("../extensions/qol/ansi.ts", () => ({
	...ansi,
	stripAnsi: (text: string) => {
		stripAnsiCalls += 1;
		return realStripAnsi(text);
	},
}));

const { installStatusTextAlignmentPatch, restoreStatusTextAlignmentPatch } = await import("../extensions/qol/pending-queue.ts");
const { default: qolDefault } = await import("../extensions/qol.ts");

type Renderable = { text: string; paddingX: number; setText(text: string): void; render(width: number): string[] };

const proto = Text.prototype as unknown as Record<PropertyKey, unknown>;

/** Stands in for pi-tui's render: shows the padding it was called with. */
function hostRender(this: Renderable, width: number): string[] {
	return [`${this.paddingX}|${this.text}|${width}`];
}

function makeText(text: string): Renderable {
	const component = new Text() as unknown as Renderable;
	component.setText(text);
	component.paddingX = 1;
	return component;
}

const uiCtx = { hasUI: true } as never;
let workdir = "";
const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
const originalHome = process.env.HOME;

beforeEach(() => {
	proto.render = hostRender;
	proto.invalidate = () => undefined;
	stripAnsiCalls = 0;
	workdir = mkdtempSync(join(tmpdir(), "pi-qol-pending-queue-"));
	mkdirSync(join(workdir, ".pi"), { recursive: true });
	process.env.PI_CODING_AGENT_DIR = workdir;
	process.env.HOME = workdir;
	clearPackageConfigCache();
});

afterEach(() => {
	restoreStatusTextAlignmentPatch();
	delete proto[STATUS_TEXT_ALIGNMENT_PATCH_SYMBOL];
	delete proto.render;
	delete proto.invalidate;
	if (workdir) rmSync(workdir, { force: true, recursive: true });
	if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
	if (originalHome === undefined) delete process.env.HOME;
	else process.env.HOME = originalHome;
	clearPackageConfigCache();
});

const alignmentRows = [
	{ name: "a restored-queue status line renders with no side padding", text: "\x1b[2mRestored 2 queued messages to editor\x1b[22m", expected: { lines: ["0|\x1b[2mRestored 2 queued messages to editor\x1b[22m|40"], paddingX: 1 } },
	{ name: "an empty-queue status line renders with no side padding", text: "No queued messages to restore", expected: { lines: ["0|No queued messages to restore|40"], paddingX: 1 } },
	{ name: "any other text keeps its padding", text: "Restored 2 queued messages to editor and more", expected: { lines: ["1|Restored 2 queued messages to editor and more|40"], paddingX: 1 } },
];

if (alignmentRows.length === 0) throw new Error("Status text alignment table is empty");

for (const row of alignmentRows) {
	test(row.name, () => {
		expect.hasAssertions();
		installStatusTextAlignmentPatch(uiCtx);
		const component = makeText(row.text);
		expect({ lines: component.render(40), paddingX: component.paddingX }).toEqual(row.expected);
	});
}

test("an unchanged Text is scanned once, and again only when its text changes", () => {
	expect.hasAssertions();
	installStatusTextAlignmentPatch(uiCtx);
	const component = makeText(`\x1b[31m${"tool output line\n".repeat(12_000)}\x1b[39m`);
	for (let pass = 0; pass < 5; pass++) component.render(80);
	const afterRepeatedRenders = stripAnsiCalls;
	component.setText("No queued messages to restore");
	const lines = component.render(80);
	expect({ afterRepeatedRenders, afterTextChange: stripAnsiCalls, lines }).toEqual({
		afterRepeatedRenders: 1,
		afterTextChange: 2,
		lines: ["0|No queued messages to restore|80"],
	});
});

test("restore puts pi-tui's own render back, and a later install patches again", () => {
	expect.hasAssertions();
	installStatusTextAlignmentPatch(uiCtx);
	const patched = proto.render;
	restoreStatusTextAlignmentPatch();
	const restored = proto.render;
	installStatusTextAlignmentPatch(uiCtx);
	expect({ patched: patched !== hostRender, restored: restored === hostRender, reinstalled: proto.render !== hostRender }).toEqual({ patched: true, restored: true, reinstalled: true });
});

test("a marker this module did not write keeps its render through install, restore and install", () => {
	expect.hasAssertions();
	// pi-qol 2.2.0 marks the prototype with `true` at load, and Pi's /reload
	// keeps that marker, and the 2.2.0 wrapper, on pi-tui's prototype.
	proto[STATUS_TEXT_ALIGNMENT_PATCH_SYMBOL] = true;
	installStatusTextAlignmentPatch(uiCtx);
	restoreStatusTextAlignmentPatch();
	installStatusTextAlignmentPatch(uiCtx);
	expect({ render: proto.render, marker: proto[STATUS_TEXT_ALIGNMENT_PATCH_SYMBOL] }).toEqual({ render: hostRender, marker: true });
});

test("a session without a UI leaves Text unpatched", () => {
	expect.hasAssertions();
	installStatusTextAlignmentPatch({ hasUI: false } as never);
	expect(proto.render).toBe(hostRender);
});

function makeFakeApi() {
	const handlers: Record<string, (event: unknown, ctx: unknown) => unknown> = {};
	const api = {
		events: { on() {}, emit() {} },
		exec: mock(async () => ({ code: 1, killed: false, stdout: "", stderr: "" })),
		getActiveTools: () => [],
		getAllTools: () => [],
		getCommands: () => [],
		getSessionName: () => undefined,
		getThinkingLevel: () => "off",
		on(name: string, handler: (event: unknown, ctx: unknown) => unknown) {
			handlers[name] = handler;
		},
		registerCommand() {},
		registerMessageRenderer() {},
		registerShortcut() {},
		sendMessage() {},
		setSessionName() {},
	};
	return { api, handlers };
}

function makeSessionCtx() {
	const theme = { bg: (_t: string, s: string) => s, bold: (s: string) => s, fg: (_t: string, s: string) => s, italic: (s: string) => s };
	return {
		cwd: workdir,
		getContextUsage: () => undefined,
		hasPendingMessages: () => false,
		hasUI: true,
		isIdle: () => true,
		model: undefined,
		sessionManager: { getBranch: () => [], getSessionFile: () => undefined, getSessionId: () => "pending-queue-test" },
		ui: {
			addAutocompleteProvider() {},
			notify() {},
			setEditorComponent() {},
			setFooter() {},
			setHeader() {},
			setHiddenThinkingLabel() {},
			setStatus() {},
			setWidget() {},
			setWorkingIndicator() {},
			setWorkingVisible() {},
			theme,
		},
	};
}

test("the session installs the patch at start and removes it at shutdown", () => {
	expect.hasAssertions();
	writeFileSync(
		join(workdir, "settings.json"),
		`${JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-qol": { "sessionSearch.enabled": false, "sessionAutoRename.enabled": false, "statusline.enabled": false, "enableScheduleCommand": false } } } } })}\n`,
		"utf8",
	);
	clearPackageConfigCache();
	const fake = makeFakeApi();
	const ctx = makeSessionCtx();
	qolDefault(fake.api as never);
	const atLoad = proto.render === hostRender;
	fake.handlers.session_start!({ reason: "startup" }, ctx);
	const inSession = proto.render !== hostRender;
	fake.handlers.session_shutdown!({ reason: "quit" }, ctx);
	expect({ atLoad, inSession, afterShutdown: proto.render === hostRender }).toEqual({ atLoad: true, inSession: true, afterShutdown: true });
});
