import {
	type ExtensionAPI,
	type ExtensionContext,
	type Theme,
} from "@earendil-works/pi-coding-agent";
import { Input, matchesKey, truncateToWidth, visibleWidth, type Focusable } from "@earendil-works/pi-tui";
import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { frameGlyphs, glyphs } from "./glyphs.js";

const PACKAGE_ID = "@vanillagreen/pi-prompt-stash";
const DEFAULT_STORE_FILE = "prompt-stash.json";
const STORE_VERSION = 1;
const POPUP_WIDTH = 92;
const POPUP_MAX_HEIGHT = "80%";
const LIST_ROWS = 10;
const PADDING_X = 2;
const PADDING_Y = 1;
// Keep the legacy symbol so stale prompt-stash installs and the renamed
// pi-prompt-stash package do not double-register the same command/shortcut.
const INSTALL_SYMBOL = Symbol.for("vstack.prompt-stash.installed");
const VSTACK_MODAL_LOCK_SYMBOL = Symbol.for("vstack.pi.modal-lock");
const DEFAULT_SHORTCUT = "alt+s";
const ANSI_GREEN_FG = "\x1b[32m";
const ANSI_YELLOW_FG = "\x1b[33m";
const ANSI_FG_RESET = "\x1b[39m";

function ansiGreen(text: string): string { return `${ANSI_GREEN_FG}${text}${ANSI_FG_RESET}`; }
function ansiYellow(text: string): string { return `${ANSI_YELLOW_FG}${text}${ANSI_FG_RESET}`; }

interface StashItem {
	id: string;
	text: string;
	createdAt: string;
}

interface VstackModalLock {
	depth: number;
}

interface StashStore {
	version: number;
	items: StashItem[];
}

type VstackConfig = Record<string, unknown>;

function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

function piUserDir(): string {
	return resolve(expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "~/.pi/agent"));
}

function safeFileName(value: string): string {
	return value.replace(/[^\w.-]+/g, "_");
}

function sessionIdForContext(ctx: ExtensionContext): string {
	const id = ctx.sessionManager.getSessionId();
	if (id && id.trim()) return id;
	const file = ctx.sessionManager.getSessionFile();
	if (file) return basename(file, ".jsonl");
	return `ephemeral-${process.pid}`;
}

const SESSION_FOLDER = "prompt-stash";

function sessionStoreDir(ctx: ExtensionContext): string {
	return join(piUserDir(), "vstack", "sessions", safeFileName(sessionIdForContext(ctx)), SESSION_FOLDER);
}

function legacyPackageSessionStoreDir(ctx: ExtensionContext): string {
	return join(piUserDir(), "vstack", SESSION_FOLDER, "sessions", safeFileName(sessionIdForContext(ctx)));
}

function migrateLegacyPackageStore(ctx: ExtensionContext): void {
	const legacyDir = legacyPackageSessionStoreDir(ctx);
	const targetDir = sessionStoreDir(ctx);
	if (resolve(legacyDir) === resolve(targetDir) || !existsSync(legacyDir)) return;
	if (existsSync(targetDir)) return;
	try {
		mkdirSync(dirname(targetDir), { recursive: true, mode: 0o700 });
		renameSync(legacyDir, targetDir);
	} catch {
		// Leave legacy tree in place if filesystem refuses migration; new state
		// still lands at targetDir on first stash.
	}
}

function projectSettingsPath(cwd: string): string {
	let current = resolve(cwd);
	while (true) {
		const candidate = join(current, ".pi", "settings.json");
		if (existsSync(candidate)) return candidate;
		if (existsSync(join(current, ".pi")) || existsSync(join(current, ".git")) || existsSync(join(current, ".vstack-lock.json"))) return candidate;
		const parent = dirname(current);
		if (parent === current) return join(resolve(cwd), ".pi", "settings.json");
		current = parent;
	}
}

function piSettingsPaths(cwd = process.cwd()): string[] {
	return [join(piUserDir(), "settings.json"), projectSettingsPath(cwd)];
}

function readVstackConfig(cwd?: string): VstackConfig {
	const merged: VstackConfig = {};
	for (const path of piSettingsPaths(cwd)) {
		if (!existsSync(path)) continue;
		try {
			const parsed = JSON.parse(readFileSync(path, "utf8"));
			const config = parsed?.vstack?.extensionManager?.config?.[PACKAGE_ID];
			if (config && typeof config === "object" && !Array.isArray(config)) Object.assign(merged, config);
		} catch {
			// Ignore malformed optional manager config.
		}
	}
	return merged;
}

function settingNumber(key: string, fallback: number, cwd?: string): number {
	const value = readVstackConfig(cwd)[key];
	const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN;
	return Number.isFinite(parsed) ? parsed : fallback;
}

function settingBoolean(key: string, fallback: boolean, cwd?: string): boolean {
	const value = readVstackConfig(cwd)[key];
	return typeof value === "boolean" ? value : fallback;
}

function settingString(key: string, fallback: string, cwd?: string): string {
	const value = readVstackConfig(cwd)[key];
	return typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback;
}

function projectRoot(cwd: string): string {
	let current = resolve(cwd);
	while (true) {
		if (
			existsSync(join(current, ".git")) ||
			existsSync(join(current, ".vstack-lock.json")) ||
			existsSync(join(current, ".pi")) ||
			existsSync(join(current, ".agents"))
		) {
			return current;
		}
		const parent = dirname(current);
		if (parent === current) return resolve(cwd);
		current = parent;
	}
}

function configuredStoreFile(ctx: ExtensionContext): string {
	// Historical config accepted a project-local path. Treat it as a file name
	// only so prompt text never lands back in the repository's .pi directory.
	const file = basename(settingString("storeFile", DEFAULT_STORE_FILE, ctx.cwd));
	return !file || file === "." || file === ".." ? DEFAULT_STORE_FILE : file;
}

function storePath(ctx: ExtensionContext): string {
	migrateLegacyPackageStore(ctx);
	return join(sessionStoreDir(ctx), configuredStoreFile(ctx));
}

function legacyProjectStorePath(ctx: ExtensionContext): string {
	return join(projectRoot(ctx.cwd), ".pi", configuredStoreFile(ctx));
}

function migrateLegacyProjectStore(ctx: ExtensionContext, nextPath: string): void {
	const legacyPath = legacyProjectStorePath(ctx);
	if (!existsSync(legacyPath)) return;
	const legacyItems = loadItems(legacyPath);
	if (legacyItems.length === 0) return;
	const existingItems = loadItems(nextPath);
	const seen = new Set(existingItems.map((item) => item.id));
	const merged = [...existingItems, ...legacyItems.filter((item) => !seen.has(item.id))].sort((a, b) => b.createdAt.localeCompare(a.createdAt));
	saveItems(nextPath, merged);
	try {
		unlinkSync(legacyPath);
	} catch {
		// Migration succeeded; leave an undeletable legacy file alone rather than
		// failing prompt stash startup.
	}
}

function loadItems(path: string): StashItem[] {
	if (!existsSync(path)) return [];
	try {
		const parsed = JSON.parse(readFileSync(path, "utf8")) as Partial<StashStore>;
		if (!Array.isArray(parsed.items)) return [];
		return parsed.items
			.filter((item): item is StashItem => {
				return Boolean(
					item &&
						typeof item === "object" &&
						typeof (item as StashItem).id === "string" &&
						typeof (item as StashItem).text === "string" &&
						typeof (item as StashItem).createdAt === "string",
				);
			})
			.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
	} catch {
		return [];
	}
}

function saveItems(path: string, items: StashItem[]): void {
	mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
	const tempPath = `${path}.tmp-${process.pid}`;
	const store: StashStore = { version: STORE_VERSION, items };
	writeFileSync(tempPath, `${JSON.stringify(store, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
	renameSync(tempPath, path);
}

function makeId(): string {
	return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

function stashPrompt(ctx: ExtensionContext, text: string): number {
	const path = storePath(ctx);
	migrateLegacyProjectStore(ctx, path);
	const now = new Date().toISOString();
	const loaded = loadItems(path);
	const existing = settingBoolean("deduplicate", true, ctx.cwd) ? loaded.filter((item) => item.text !== text) : loaded;
	const items = [{ id: makeId(), text, createdAt: now }, ...existing];
	saveItems(path, items);
	return items.length;
}

function lineCount(text: string): number {
	return Math.max(1, text.split(/\r\n|\r|\n/).length);
}

function previewText(text: string): string {
	const first = text
		.split(/\r\n|\r|\n/)
		.map((line) => line.trim())
		.find((line) => line.length > 0);
	return first ?? "(empty prompt)";
}

function padAnsi(text: string, width: number): string {
	const truncated = truncateToWidth(text, width, "");
	return `${truncated}${" ".repeat(Math.max(0, width - visibleWidth(truncated)))}`;
}

function acquireVstackModalLock(): () => void {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const existing = host[VSTACK_MODAL_LOCK_SYMBOL] as VstackModalLock | undefined;
	const lock = existing && typeof existing.depth === "number" ? existing : { depth: 0 };
	host[VSTACK_MODAL_LOCK_SYMBOL] = lock;
	lock.depth += 1;
	let released = false;
	return () => {
		if (released) return;
		released = true;
		lock.depth = Math.max(0, lock.depth - 1);
	};
}

function searchable(text: string): string {
	return text.toLowerCase();
}

function panelLine(content: string, width: number): string {
	return padAnsi(content, width);
}

function selectedLine(theme: Theme, content: string, width: number): string {
	return theme.bg("selectedBg", padAnsi(theme.fg("text", content), width));
}

function popupContentWidth(width: number): number {
	return Math.max(1, width - 2 - PADDING_X * 2);
}

function framePopup(lines: string[], width: number, theme: Theme, title = "", right = ""): string[] {
	if (width < 8) return lines.map((line) => truncateToWidth(line, width, ""));

	const border = (text: string) => theme.fg("borderAccent", text);
	const contentWidth = popupContentWidth(width);
	const frame = frameGlyphs();
	const blank = `${border(frame.v)}${" ".repeat(width - 2)}${border(frame.v)}`;
	const top = () => {
		if (!title) return `${border(frame.tl)}${border(frame.h.repeat(width - 2))}${border(frame.tr)}`;
		const rightPlain = right ? ` ${right} ` : "";
		const titleBudget = Math.max(1, width - 2 - visibleWidth(rightPlain) - 1);
		const titlePlain = ` ${truncateToWidth(title, Math.max(1, titleBudget - 2), glyphs().ellipsis)} `;
		const fill = Math.max(1, width - 2 - visibleWidth(titlePlain) - visibleWidth(rightPlain));
		return `${border(frame.tl)}${ansiGreen(titlePlain)}${border(frame.h.repeat(fill))}${right ? theme.fg("dim", rightPlain) : ""}${border(frame.tr)}`;
	};
	const framed = [top()];

	for (let i = 0; i < PADDING_Y; i += 1) framed.push(blank);
	for (const line of lines) {
		framed.push(`${border(frame.v)}${" ".repeat(PADDING_X)}${padAnsi(line, contentWidth)}${" ".repeat(PADDING_X)}${border(frame.v)}`);
	}
	for (let i = 0; i < PADDING_Y; i += 1) framed.push(blank);
	framed.push(`${border(frame.bl)}${border(frame.h.repeat(width - 2))}${border(frame.br)}`);
	return framed.map((line) => truncateToWidth(line, width, ""));
}

function renderSearchLine(searchInput: Input, width: number, theme: Theme): string {
	const prefix = " ";
	const inputWidth = Math.max(1, width - visibleWidth(prefix));
	const input = searchInput.render(inputWidth)[0] ?? "";
	return theme.bg("toolPendingBg", padAnsi(truncateToWidth(`${prefix}${input}`, width, ""), width));
}

function filterItems(items: StashItem[], query: string): StashItem[] {
	const trimmed = query.trim().toLowerCase();
	if (!trimmed) return items;
	return items.filter((item) => searchable(item.text).includes(trimmed));
}

async function openStashPopup(ctx: ExtensionContext): Promise<void> {
	if (!ctx.hasUI) return;

	const listRows = Math.max(1, Math.floor(settingNumber("listRows", LIST_ROWS, ctx.cwd)));
	const path = storePath(ctx);
	migrateLegacyProjectStore(ctx, path);
	let items = loadItems(path);
	if (items.length === 0) {
		ctx.ui.notify("Prompt stash is empty", "info");
		return;
	}

	const releaseModalLock = acquireVstackModalLock();
	let restored: string | null = null;
	try {
		restored = await ctx.ui.custom<string | null>(
		(tui, theme, _keybindings, done) => {
			const searchInput = new Input();
			searchInput.focused = true;
			let selected = 0;
			let scroll = 0;
			let confirmDeleteAll = false;

			const filtered = () => filterItems(items, searchInput.getValue());
			const clampSelection = () => {
				const count = filtered().length;
				if (count === 0) {
					selected = 0;
					scroll = 0;
					return;
				}
				selected = Math.max(0, Math.min(selected, count - 1));
				if (selected < scroll) scroll = selected;
				if (selected >= scroll + listRows) scroll = selected - listRows + 1;
				scroll = Math.max(0, Math.min(scroll, Math.max(0, count - listRows)));
			};

			const deleteSelected = () => {
				const item = filtered()[selected];
				if (!item) return;
				items = items.filter((candidate) => candidate.id !== item.id);
				saveItems(path, items);
				clampSelection();
				tui.requestRender();
			};

			const clearAll = () => {
				items = [];
				saveItems(path, items);
				confirmDeleteAll = false;
				clampSelection();
				tui.requestRender();
			};

			const restoreSelected = () => {
				const item = filtered()[selected];
				if (!item) return;
				done(item.text);
			};

			const render = (width: number): string[] => {
				const innerWidth = popupContentWidth(width);
				const results = filtered();
				clampSelection();

				const lines: string[] = [];
				lines.push(panelLine(renderSearchLine(searchInput, innerWidth, theme), innerWidth));
				lines.push(panelLine("", innerWidth));

				if (results.length === 0) {
					lines.push(panelLine(theme.fg("dim", "No matching stashed prompts"), innerWidth));
				} else {
					for (const [visibleIndex, item] of results.slice(scroll, scroll + listRows).entries()) {
						const index = scroll + visibleIndex;
						const count = lineCount(item.text);
						const countText = `~${count} ${count === 1 ? "line" : "lines"}`;
						const countWidth = visibleWidth(countText);
						const rowWidth = innerWidth;
						const itemPad = " ";
						const previewWidth = Math.max(1, rowWidth - visibleWidth(itemPad) - countWidth - 1);
						const preview = truncateToWidth(previewText(item.text), previewWidth, "");
						const styledPreview = index === selected ? theme.bold(preview) : preview;
						const styledCount = index === selected ? theme.fg("text", countText) : theme.fg("dim", countText);
						const row = `${itemPad}${styledPreview}${" ".repeat(Math.max(1, rowWidth - visibleWidth(itemPad) - visibleWidth(preview) - countWidth))}${styledCount}`;
						lines.push(index === selected ? selectedLine(theme, row, innerWidth) : panelLine(row, innerWidth));
					}
				}

				const emptyRows = Math.max(0, listRows - Math.max(1, Math.min(results.length, listRows)));
				for (let i = 0; i < emptyRows; i += 1) lines.push(panelLine("", innerWidth));

				lines.push(panelLine("", innerWidth));
				const status = confirmDeleteAll
					? theme.fg("warning", "delete all stashed prompts?")
					: `${ansiYellow("-/=")} ${theme.fg("dim", "page · ")}${ansiYellow("alt+d")} ${theme.fg("dim", "delete · ")}${ansiYellow("alt+x")} ${theme.fg("dim", "delete all")}`;
				lines.push(panelLine(status, innerWidth));

				return framePopup(lines, width, theme, "Prompt Stash", `${items.length} saved`);
			};

			const component: Focusable & { handleInput(data: string): void; invalidate(): void; render(width: number): string[] } = {
				get focused(): boolean {
					return searchInput.focused;
				},
				set focused(value: boolean) {
					searchInput.focused = value;
				},
				handleInput(data: string) {
					if (confirmDeleteAll) {
						if (matchesKey(data, "return") || matchesKey(data, "enter")) {
							clearAll();
							return;
						}
						if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
							confirmDeleteAll = false;
							tui.requestRender();
							return;
						}
					}

					if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
						done(null);
						return;
					}
					if (matchesKey(data, "return") || matchesKey(data, "enter")) {
						restoreSelected();
						return;
					}
					if (matchesKey(data, "up")) {
						selected -= 1;
						clampSelection();
						tui.requestRender();
						return;
					}
					if (matchesKey(data, "down")) {
						selected += 1;
						clampSelection();
						tui.requestRender();
						return;
					}
					if (matchesKey(data, "-") || matchesKey(data, "pageup")) {
						selected -= listRows;
						clampSelection();
						tui.requestRender();
						return;
					}
					if (matchesKey(data, "=") || matchesKey(data, "pagedown")) {
						selected += listRows;
						clampSelection();
						tui.requestRender();
						return;
					}
					if (matchesKey(data, "alt+d") || matchesKey(data, "ctrl+d") || matchesKey(data, "delete")) {
						deleteSelected();
						return;
					}
					if (matchesKey(data, "alt+x") || matchesKey(data, "ctrl+x")) {
						confirmDeleteAll = items.length > 0;
						tui.requestRender();
						return;
					}
					if (matchesKey(data, "ctrl+u")) {
						searchInput.setValue("");
						selected = 0;
						clampSelection();
						tui.requestRender();
						return;
					}

					const before = searchInput.getValue();
					searchInput.handleInput(data);
					if (searchInput.getValue() !== before) {
						selected = 0;
						clampSelection();
					}
					tui.requestRender();
				},
				invalidate() {
					searchInput.invalidate();
				},
				render,
			};
			return component;
		},
		{
			overlay: true,
			overlayOptions: {
				anchor: "center",
				maxHeight: settingString("popupMaxHeight", POPUP_MAX_HEIGHT, ctx.cwd),
				width: Math.max(40, Math.floor(settingNumber("popupWidth", POPUP_WIDTH, ctx.cwd))),
			},
		},
		);
	} finally {
		releaseModalLock();
	}

	if (restored != null) {
		ctx.ui.setEditorText(restored);
	}
}

let stashShortcutOpen = false;

async function toggleStash(ctx: ExtensionContext): Promise<void> {
	if (stashShortcutOpen) return;
	const text = ctx.ui.getEditorText?.() ?? "";
	if (text.trim().length > 0) {
		const count = stashPrompt(ctx, text);
		ctx.ui.setEditorText("");
		ctx.ui.notify(`Stashed prompt (${count} total)`, "info");
		return;
	}

	stashShortcutOpen = true;
	try {
		await openStashPopup(ctx);
	} finally {
		stashShortcutOpen = false;
	}
}

export default function promptStash(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;
	if (!settingBoolean("enabled", true)) return;

	pi.on("session_start", async (_event, ctx) => {
		migrateLegacyProjectStore(ctx, storePath(ctx));
	});

	const shortcut = settingString("shortcut", DEFAULT_SHORTCUT);
	if (shortcut !== "none") {
		pi.registerShortcut(shortcut, {
			description: "Stash current prompt or restore from prompt stash",
			handler: async (ctx) => toggleStash(ctx as ExtensionContext),
		});
	}

	pi.registerCommand("prompt-stash", {
		description: "Open the per-session prompt stash popup",
		handler: async (_args, ctx) => openStashPopup(ctx),
	});
}
