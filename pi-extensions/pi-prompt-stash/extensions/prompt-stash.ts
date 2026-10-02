import {
	type ExtensionAPI,
	type ExtensionContext,
	type Theme,
} from "@earendil-works/pi-coding-agent";
import { Input, matchesKey, truncateToWidth, visibleWidth, type Focusable } from "@earendil-works/pi-tui";
import { mkdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { frameGlyphs, glyphs } from "./glyphs.js";
import { installSettingsCacheRefresh, piUserDir, readPackageConfig, recordProjectTrust } from "./package-config.js";

const PACKAGE_ID = "@vanillagreen/pi-prompt-stash";
const DEFAULT_STORE_FILE = "prompt-stash.json";
const STORE_VERSION = 1;
const POPUP_WIDTH = 92;
const POPUP_MAX_HEIGHT = "80%";
const LIST_ROWS = 10;
const PADDING_X = 2;
const PADDING_Y = 1;
// Border, search line, spacer and status around the list, plus vertical padding.
const POPUP_CHROME_ROWS = 6 + PADDING_Y * 2;
const MAX_ITEMS = 500;
const MAX_STORE_BYTES = 8 * 1024 * 1024;
// Keep the legacy symbol so stale prompt-stash installs and the renamed
// pi-prompt-stash package do not double-register the same command/shortcut.
const INSTALL_SYMBOL = Symbol.for("kendex.prompt-stash.installed");
const KENDEX_MODAL_LOCK_SYMBOL = Symbol.for("kendex.pi.modal-lock");
const DEFAULT_SHORTCUT = "alt+s";
const ANSI_GREEN_FG = "\x1b[32m";
const ANSI_YELLOW_FG = "\x1b[33m";
const ANSI_FG_RESET = "\x1b[39m";

const stashMessages = {
	empty: "prompt_stash_items=0\nPrompt stash is empty",
	saved: (count: number) => `prompt_stash_items=${count}\nStashed prompt (${count} total)`,
	saveFailed: (error: unknown) => `prompt_stash_save_failed\n${error instanceof Error ? error.message : String(error)}`,
	refused: {
		"item-limit": `Prompt stash holds at most ${MAX_ITEMS} prompts; delete some in the popup first`,
		"byte-limit": `Prompt stash store holds at most ${MAX_STORE_BYTES} bytes; delete some prompts in the popup first`,
		"store-too-large": `Prompt stash store file is over ${MAX_STORE_BYTES} bytes; trim it by hand`,
	},
};

type Refusal = keyof typeof stashMessages.refused;

class StashRefused extends Error {
	constructor(reason: Refusal, value: string | number) {
		super(`prompt_stash_refused=${reason} value=${value}\n${stashMessages.refused[reason]}`);
	}
}

function notifyRefusal(ctx: ExtensionContext, error: unknown): void {
	if (!(error instanceof StashRefused)) throw error;
	ctx.ui.notify(error.message, "error");
}

function ansiGreen(text: string): string { return `${ANSI_GREEN_FG}${text}${ANSI_FG_RESET}`; }
function ansiYellow(text: string): string { return `${ANSI_YELLOW_FG}${text}${ANSI_FG_RESET}`; }

interface StashItem {
	id: string;
	text: string;
	createdAt: string;
}

interface kendexModalLock {
	depth: number;
}

interface StashStore {
	version: number;
	items: StashItem[];
}

type kendexConfig = Record<string, unknown>;

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
	return join(piUserDir(), "kendex", "sessions", safeFileName(sessionIdForContext(ctx)), SESSION_FOLDER);
}


function readkendexConfig(cwd?: string): kendexConfig {
	return readPackageConfig(PACKAGE_ID, cwd) as kendexConfig;
}

function settingNumber(key: string, fallback: number, cwd?: string): number {
	const value = readkendexConfig(cwd)[key];
	const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN;
	return Number.isFinite(parsed) ? parsed : fallback;
}

function settingBoolean(key: string, fallback: boolean, cwd?: string): boolean {
	const value = readkendexConfig(cwd)[key];
	return typeof value === "boolean" ? value : fallback;
}

function settingString(key: string, fallback: string, cwd?: string): string {
	const value = readkendexConfig(cwd)[key];
	return typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback;
}

function configuredStoreFile(ctx: ExtensionContext): string {
	// Historical config accepted a project-local path. Treat it as a file name
	// only so prompt text never lands back in the repository's .pi directory.
	const file = basename(settingString("storeFile", DEFAULT_STORE_FILE, ctx.cwd));
	return !file || file === "." || file === ".." ? DEFAULT_STORE_FILE : file;
}

function storePath(ctx: ExtensionContext): string {
	return join(sessionStoreDir(ctx), configuredStoreFile(ctx));
}

async function loadItems(path: string): Promise<StashItem[]> {
	const size = await stat(path).then((info) => info.size, () => 0);
	if (size > MAX_STORE_BYTES) throw new StashRefused("store-too-large", path);
	try {
		const parsed = JSON.parse(await readFile(path, "utf8")) as Partial<StashStore>;
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

async function saveItems(path: string, items: StashItem[]): Promise<void> {
	const store: StashStore = { version: STORE_VERSION, items };
	const json = `${JSON.stringify(store, null, 2)}\n`;
	const bytes = Buffer.byteLength(json);
	if (bytes > MAX_STORE_BYTES) throw new StashRefused("byte-limit", bytes);
	await mkdir(dirname(path), { recursive: true, mode: 0o700 });
	const tempPath = `${path}.tmp-${process.pid}`;
	await writeFile(tempPath, json, { encoding: "utf8", mode: 0o600 });
	await rename(tempPath, path);
}

let storeQueue: Promise<unknown> = Promise.resolve();

// Every store read and write runs in this one queue, so an async write never
// interleaves with another stash's read-modify-write or a popup load.
function serialized<T>(op: () => Promise<T>): Promise<T> {
	const run = storeQueue.then(op);
	storeQueue = run.catch(() => undefined);
	return run;
}

function makeId(): string {
	return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

function stashPrompt(ctx: ExtensionContext, text: string): Promise<number> {
	return serialized(async () => {
		const path = storePath(ctx);
		const now = new Date().toISOString();
		const loaded = await loadItems(path);
		const existing = settingBoolean("deduplicate", true, ctx.cwd) ? loaded.filter((item) => item.text !== text) : loaded;
		const items = [{ id: makeId(), text, createdAt: now }, ...existing];
		if (items.length > MAX_ITEMS) throw new StashRefused("item-limit", items.length);
		await saveItems(path, items);
		return items.length;
	});
}

interface ItemView {
	search: string;
	preview: string;
	lines: number;
}

// Items are never mutated, so a view computed once holds for the item's life.
const itemViews = new WeakMap<StashItem, ItemView>();

function itemView(item: StashItem): ItemView {
	const cached = itemViews.get(item);
	if (cached) return cached;
	const lines = item.text.split(/\r\n|\r|\n/);
	const preview = lines.map((line) => line.trim()).find((line) => line.length > 0) ?? "(empty prompt)";
	const view = { search: item.text.toLowerCase(), preview, lines: lines.length };
	itemViews.set(item, view);
	return view;
}

// pi-tui slices an overlay to its resolved maxHeight but does not export the
// resolver, so this repeats its rule: only an "N%" string resolves, as that
// share of the terminal; any other value leaves the terminal height.
function overlayHeight(maxHeight: string, terminalRows: number): number {
	const percent = /^(\d+(?:\.\d+)?)%$/.exec(maxHeight);
	const height = percent ? Math.floor((terminalRows * Number(percent[1])) / 100) : terminalRows;
	return Math.max(1, Math.min(height, terminalRows));
}

function padAnsi(text: string, width: number): string {
	const truncated = truncateToWidth(text, width, "");
	return `${truncated}${" ".repeat(Math.max(0, width - visibleWidth(truncated)))}`;
}

function acquirekendexModalLock(): () => void {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const existing = host[KENDEX_MODAL_LOCK_SYMBOL] as kendexModalLock | undefined;
	const lock = existing && typeof existing.depth === "number" ? existing : { depth: 0 };
	host[KENDEX_MODAL_LOCK_SYMBOL] = lock;
	lock.depth += 1;
	let released = false;
	return () => {
		if (released) return;
		released = true;
		lock.depth = Math.max(0, lock.depth - 1);
	};
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
	return items.filter((item) => itemView(item).search.includes(trimmed));
}

async function openStashPopup(ctx: ExtensionContext): Promise<void> {
	if (!ctx.hasUI) return;

	const configuredRows = Math.max(1, Math.floor(settingNumber("listRows", LIST_ROWS, ctx.cwd)));
	const maxHeight = settingString("popupMaxHeight", POPUP_MAX_HEIGHT, ctx.cwd);
	const path = storePath(ctx);
	let items: StashItem[];
	try {
		items = await serialized(() => loadItems(path));
	} catch (error) {
		notifyRefusal(ctx, error);
		return;
	}
	if (items.length === 0) {
		ctx.ui.notify(stashMessages.empty, "info");
		return;
	}

	const releaseModalLock = acquirekendexModalLock();
	let restored: string | null = null;
	try {
		restored = await ctx.ui.custom<string | null>(
		(tui, theme, _keybindings, done) => {
			const searchInput = new Input();
			searchInput.focused = true;
			let selected = 0;
			let scroll = 0;
			let confirmDeleteAll = false;

			let filterCache: { items: StashItem[]; query: string; matches: StashItem[] } | undefined;
			const filtered = () => {
				const query = searchInput.getValue();
				if (filterCache?.items !== items || filterCache.query !== query) filterCache = { items, query, matches: filterItems(items, query) };
				return filterCache.matches;
			};
			const visibleRows = () => Math.max(1, Math.min(configuredRows, overlayHeight(maxHeight, tui.terminal.rows) - POPUP_CHROME_ROWS));
			// A draft stashed after the popup loaded is only in the store, so a
			// delete applies to the store as it is when the queue reaches it, and
			// the list takes that result once no other delete is still queued.
			let pendingDeletes = 0;
			const persistDelete = (drop: (item: StashItem) => boolean) => {
				pendingDeletes += 1;
				serialized(async () => {
					const kept = (await loadItems(path)).filter((item) => !drop(item));
					await saveItems(path, kept);
					return kept;
				}).then(
					(kept) => {
						pendingDeletes -= 1;
						if (pendingDeletes > 0) return;
						items = kept;
						clampSelection();
						tui.requestRender();
					},
					(error) => {
						pendingDeletes -= 1;
						ctx.ui.notify(stashMessages.saveFailed(error), "error");
					},
				);
			};
			const clampSelection = () => {
				const listRows = visibleRows();
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
				persistDelete((candidate) => candidate.id === item.id);
				clampSelection();
				tui.requestRender();
			};

			const clearAll = () => {
				const shown = new Set(items.map((candidate) => candidate.id));
				items = [];
				persistDelete((candidate) => shown.has(candidate.id));
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
				const listRows = visibleRows();
				clampSelection();

				const lines: string[] = [];
				lines.push(panelLine(renderSearchLine(searchInput, innerWidth, theme), innerWidth));
				lines.push(panelLine("", innerWidth));

				if (results.length === 0) {
					lines.push(panelLine(theme.fg("dim", "No matching stashed prompts"), innerWidth));
				} else {
					for (const [visibleIndex, item] of results.slice(scroll, scroll + listRows).entries()) {
						const index = scroll + visibleIndex;
						const view = itemView(item);
						const count = view.lines;
						const countText = `~${count} ${count === 1 ? "line" : "lines"}`;
						const countWidth = visibleWidth(countText);
						const rowWidth = innerWidth;
						const itemPad = " ";
						const previewWidth = Math.max(1, rowWidth - visibleWidth(itemPad) - countWidth - 1);
						const preview = truncateToWidth(view.preview, previewWidth, "");
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
						selected -= visibleRows();
						clampSelection();
						tui.requestRender();
						return;
					}
					if (matchesKey(data, "=") || matchesKey(data, "pagedown")) {
						selected += visibleRows();
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
				maxHeight,
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

function enabledForContext(ctx: ExtensionContext): boolean {
	return settingBoolean("enabled", true, ctx.cwd);
}

async function toggleStash(ctx: ExtensionContext): Promise<void> {
	if (!enabledForContext(ctx)) return;
	if (stashShortcutOpen) return;
	const text = ctx.ui.getEditorText?.() ?? "";
	if (text.trim().length > 0) {
		let count: number;
		try {
			count = await stashPrompt(ctx, text);
		} catch (error) {
			notifyRefusal(ctx, error);
			return;
		}
		// The write is async; keep anything typed while it ran.
		if ((ctx.ui.getEditorText?.() ?? "") === text) ctx.ui.setEditorText("");
		ctx.ui.notify(stashMessages.saved(count), "info");
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

	installSettingsCacheRefresh(pi);
	pi.on("session_start", async (_event, ctx) => {
		recordProjectTrust(ctx);
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
		handler: async (_args, ctx) => {
			if (!enabledForContext(ctx)) return;
			await openStashPopup(ctx);
		},
	});
}
