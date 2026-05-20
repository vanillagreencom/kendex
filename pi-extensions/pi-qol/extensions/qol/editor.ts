import { CustomEditor, Theme, type ExtensionContext, type KeybindingsManager } from "@earendil-works/pi-coding-agent";
import { matchesKey, truncateToWidth, visibleWidth, type AutocompleteItem, type AutocompleteSuggestions, type EditorTheme, type TUI } from "@earendil-works/pi-tui";
import { stripAnsi } from "./ansi.js";
import { readCavemanBridge } from "./bridges.js";
import { STATUS_KEY } from "./constants.js";
import { glyphs } from "./glyphs.js";
import { statusText, styleImageChips } from "./images.js";
import { newlineFallbackKey, settingBoolean } from "./settings.js";

function styleAutocompleteHintItem(item: AutocompleteItem, theme: Theme): AutocompleteItem {
	const label = stripAnsi(item.label || item.value);
	const styled: AutocompleteItem = { ...item, label: theme.fg("accent", label) };
	if (typeof item.description === "string" && item.description.length > 0) {
		styled.description = theme.fg("text", stripAnsi(item.description));
	}
	return styled;
}

function styleSlashAutocompleteHints(suggestions: AutocompleteSuggestions | null, theme: Theme): AutocompleteSuggestions | null {
	if (!suggestions || !suggestions.prefix.startsWith("/")) return suggestions;
	return { ...suggestions, items: suggestions.items.map((item) => styleAutocompleteHintItem(item, theme)) };
}

export function installAutocompleteHintStyling(ctx: ExtensionContext): void {
	if (!ctx.hasUI) return;
	ctx.ui.addAutocompleteProvider((current) => ({
		async getSuggestions(lines, cursorLine, cursorCol, options) {
			return styleSlashAutocompleteHints(await current.getSuggestions(lines, cursorLine, cursorCol, options), ctx.ui.theme);
		},
		applyCompletion(lines, cursorLine, cursorCol, item, prefix) {
			return current.applyCompletion(lines, cursorLine, cursorCol, item, prefix);
		},
		shouldTriggerFileCompletion(lines, cursorLine, cursorCol) {
			return current.shouldTriggerFileCompletion?.(lines, cursorLine, cursorCol) ?? true;
		},
	}));
}

const QOL_ARGUMENT_COMPLETIONS: AutocompleteItem[] = [
	{ value: "status", label: "status", description: "Show QOL status and current settings" },
	{ value: "rename", label: "rename", description: "Generate a session name from the first user message" },
	{ value: "notify-test", label: "notify-test", description: "Send a test QOL notification" },
];

const QOL_RENAME_ARGUMENT_COMPLETIONS: AutocompleteItem[] = [
	{ value: "rename full", label: "rename full", description: "Generate a session name from the full conversation" },
];

export function getQolArgumentCompletions(prefix: string): AutocompleteItem[] | null {
	const query = prefix.trimStart().toLowerCase();
	const items = query.startsWith("rename ") ? QOL_RENAME_ARGUMENT_COMPLETIONS : QOL_ARGUMENT_COMPLETIONS;
	const filtered = items.filter((item) => item.value.toLowerCase().startsWith(query));
	return filtered.length > 0 ? filtered : null;
}

const SESSION_SEARCH_ARGUMENT_COMPLETIONS: AutocompleteItem[] = [
	{ value: "refresh", label: "refresh", description: "Refresh the session search index" },
];

export function getSessionSearchArgumentCompletions(prefix: string): AutocompleteItem[] | null {
	const query = prefix.trimStart().toLowerCase();
	const filtered = SESSION_SEARCH_ARGUMENT_COMPLETIONS.filter((item) => item.value.toLowerCase().startsWith(query) || (item.label ?? item.value).toLowerCase().startsWith(query));
	return filtered.length > 0 ? filtered : null;
}

function handleQolEditorInput(editor: CustomEditor, ctx: ExtensionContext, data: string): void {
	if (matchesKey(data, "alt+c")) {
		const caveman = readCavemanBridge();
		if (caveman?.cycleMode) {
			const next = caveman.cycleMode(ctx.cwd);
			if (typeof next === "string") {
				try { ctx.ui.notify(next === "off" ? "Caveman off." : `Caveman ${next} active.`, "info"); } catch { /* notify is best-effort */ }
			}
			return;
		}
	}
	const fallback = newlineFallbackKey(ctx.cwd);
	const newlineEnabled = settingBoolean("newlineOnShiftEnter", true, ctx.cwd);
	const isShiftEnter = matchesKey(data, "shift+enter") || matchesKey(data, "shift+return");
	const isFallback = fallback !== "none" && matchesKey(data, fallback);
	CustomEditor.prototype.handleInput.call(editor, newlineEnabled && (isShiftEnter || isFallback) ? "\n" : data);
}

/// Push the latest attachment-count status only when it actually changes.
/// Called from render() so we follow the rainbow-editor pattern (pull from
/// render, don't push from every keystroke) and avoid the per-keystroke
/// setStatus side effect that previously contributed to resize/input races.
function syncQolEditorStatus(
	ctx: ExtensionContext,
	text: string,
	cache: { last?: string },
): void {
	const next = statusText(ctx, text);
	if (next === cache.last) return;
	cache.last = next;
	try {
		ctx.ui.setStatus(STATUS_KEY, next);
	} catch {
		// best-effort visual; don't let a status push break render
	}
}

export class QolEditor extends CustomEditor {
	private readonly statusCache: { last?: string } = {};

	constructor(
		tui: TUI,
		editorTheme: EditorTheme,
		keybindings: KeybindingsManager,
		private readonly ctx: ExtensionContext,
	) {
		super(tui, editorTheme, keybindings);
	}

	handleInput(data: string): void {
		handleQolEditorInput(this, this.ctx, data);
	}

	render(width: number): string[] {
		syncQolEditorStatus(this.ctx, this.getText(), this.statusCache);
		return super.render(width).map((line) => truncateToWidth(styleImageChips(line, this.ctx.cwd, this.ctx.ui.theme), width, ""));
	}
}

function isEditorBorderLine(line: string): boolean {
	const visible = stripAnsi(line).trim();
	return visible.length > 0 && /^[─━╭╮╰╯┌┐└┘]+$/.test(visible);
}

export class QolCompactPromptEditor extends CustomEditor {
	private readonly statusCache: { last?: string } = {};

	constructor(
		tui: TUI,
		editorTheme: EditorTheme,
		keybindings: KeybindingsManager,
		private readonly inputBottomPaddingLines: number,
		private readonly ctx: ExtensionContext,
	) {
		super(tui, editorTheme, keybindings, { paddingX: 0 });
	}

	handleInput(data: string): void {
		handleQolEditorInput(this, this.ctx, data);
	}

	render(width: number): string[] {
		syncQolEditorStatus(this.ctx, this.getText(), this.statusCache);
		const promptGlyph = glyphs(this.ctx.cwd).prompt;
		const prompt = this.borderColor(promptGlyph);
		const prefix = `${prompt} `;
		const prefixWidth = visibleWidth(`${promptGlyph} `);
		const continuationPrefix = " ".repeat(prefixWidth);
		const innerWidth = Math.max(1, width - prefixWidth);
		const rendered = super.render(innerWidth);

		const inputLines: string[] = [];
		let completionLines: string[] = [];
		for (let index = 1; index < rendered.length; index++) {
			const line = rendered[index] ?? "";
			if (isEditorBorderLine(line)) {
				completionLines = rendered.slice(index + 1);
				break;
			}
			inputLines.push(line);
		}

		const lines = (inputLines.length > 0 ? inputLines : [""]).map((line, index) => {
			const linePrefix = index === 0 ? prefix : continuationPrefix;
			const content = styleImageChips(line, this.ctx.cwd, this.ctx.ui.theme);
			return truncateToWidth(linePrefix + content, width, "");
		});
		for (let index = 0; index < this.inputBottomPaddingLines; index++) lines.push("");
		for (const line of completionLines) lines.push(truncateToWidth(`${this.ctx.ui.theme.fg("dim", continuationPrefix)}${line}`, width, ""));
		return lines;
	}
}

export function currentEditorText(ctx: ExtensionContext): string {
	try {
		return ctx.ui.getEditorText?.() ?? "";
	} catch {
		return "";
	}
}
