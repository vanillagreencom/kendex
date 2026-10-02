import { mock } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { clearPackageConfigCache } from "../package-config.js";

// Every suite in this package imports the extension through this module, so
// the one pi-tui stand-in below is the one the extension binds to.
mock.module("@earendil-works/pi-tui", () => ({
	Input: class {
		focused = false;
		value = "";
		getValue() { return this.value; }
		setValue(value: string) { this.value = value; }
		handleInput(data: string) { this.value += data; }
		render() { return [this.value]; }
		invalidate() {}
	},
	matchesKey: (data: string, key: string) => data === key,
	truncateToWidth: (text: string) => text,
	visibleWidth: (text: string) => text.length,
}));

const { default: promptStash } = await import("../prompt-stash.js");

export interface Popup {
	render(width: number): string[];
	handleInput(data: string): void;
}

export interface StashWorld {
	storeFile: string;
	notices: Array<{ message: string; level: string }>;
	editorText: string;
	terminalRows: number;
	popup?: Popup;
	overlayOptions?: { maxHeight?: string };
	popupOpened: Promise<void>;
	/** Resolves at the extension's next requestRender or notify call. */
	nextHostCall(): Promise<void>;
	shortcut(): Promise<void>;
	command(): Promise<void>;
	storedItems(): Array<{ text: string }>;
	writeStore(items: Array<{ text: string }>): void;
	writeSettings(config: Record<string, unknown>): void;
	dispose(): void;
}

/** Prefix the fake theme puts on the popup's selected row. */
export const SELECTED = "[selected]";

const theme = {
	bg: (name: string, text: string) => (name === "selectedBg" ? `${SELECTED}${text}` : text),
	bold: (text: string) => text,
	fg: (_name: string, text: string) => text,
};

/** A fresh Pi user directory and session with the extension registered against a fake host. */
export function stashWorld(): StashWorld {
	const root = mkdtempSync(join(tmpdir(), "pi-prompt-stash-test-"));
	mkdirSync(join(root, "project", ".pi"), { recursive: true });
	mkdirSync(join(root, "agent"));
	const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(root, "agent");
	clearPackageConfigCache();

	let command: { handler: (args: string, ctx: unknown) => Promise<void> } | undefined;
	let shortcut: { handler: (ctx: unknown) => Promise<void> } | undefined;
	promptStash({
		on() {},
		registerCommand(_name: string, definition: typeof command) { command = definition; },
		registerShortcut(_key: string, definition: typeof shortcut) { shortcut = definition; },
	} as never);

	let opened = () => {};
	let hostCalled: Array<() => void> = [];
	const hostCall = () => {
		const waiters = hostCalled;
		hostCalled = [];
		for (const resolve of waiters) resolve();
	};
	const world: StashWorld = {
		storeFile: join(root, "agent", "kendex", "sessions", "session-1", "prompt-stash", "prompt-stash.json"),
		notices: [],
		editorText: "",
		terminalRows: 40,
		popupOpened: new Promise<void>((resolve) => { opened = resolve; }),
		nextHostCall: () => new Promise<void>((resolve) => { hostCalled.push(resolve); }),
		shortcut: () => shortcut!.handler(ctx),
		command: () => command!.handler("", ctx),
		storedItems: () => JSON.parse(readFileSync(world.storeFile, "utf8")).items,
		writeStore(items) {
			mkdirSync(dirname(world.storeFile), { recursive: true });
			const stamped = items.map((item, index) => ({ id: `id-${index}`, createdAt: new Date(Date.UTC(2026, 0, 1, 0, 0, index)).toISOString(), ...item }));
			writeFileSync(world.storeFile, JSON.stringify({ version: 1, items: stamped }));
		},
		writeSettings(config) {
			writeFileSync(join(root, "agent", "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-prompt-stash": config } } } }));
			clearPackageConfigCache();
		},
		dispose() {
			if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
			clearPackageConfigCache();
			rmSync(root, { recursive: true, force: true });
		},
	};
	const ctx = {
		cwd: join(root, "project"),
		hasUI: true,
		sessionManager: {
			getSessionFile: () => undefined,
			getSessionId: () => "session-1",
		},
		ui: {
			getEditorText: () => world.editorText,
			notify: (message: string, level: string) => {
				world.notices.push({ message, level });
				hostCall();
			},
			setEditorText: (value: string) => { world.editorText = value; },
			custom: (factory: (tui: unknown, theme: unknown, keybindings: unknown, done: (value: string | null) => void) => Popup, options: { overlayOptions?: { maxHeight?: string } }) =>
				new Promise<string | null>((resolve) => {
					world.overlayOptions = options.overlayOptions;
					const tui = { requestRender: hostCall, terminal: { get rows() { return world.terminalRows; } } };
					world.popup = factory(tui, theme, {}, resolve);
					opened();
				}),
		},
	};
	return world;
}
