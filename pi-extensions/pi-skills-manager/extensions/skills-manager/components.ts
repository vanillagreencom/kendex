import {
	Container,
	type Component,
	Editor,
	type Focusable,
	Input,
	Key,
	Markdown,
	matchesKey,
	Spacer,
	Text,
	truncateToWidth,
	type TUI,
	visibleWidth,
} from "@earendil-works/pi-tui";
import { getMarkdownTheme, type Theme } from "@earendil-works/pi-coding-agent";
import { buildFrontmatterBlock } from "./format.js";
import { glyphs } from "./glyphs.js";
import { isDeletableSkill } from "./registry.js";
import {
	getEditorTheme,
	inlineLine,
	packageLabel,
	padAnsi,
	scopeLabel,
	skillEntityTitle,
	skillKeyHints,
	skillLocation,
	skillSelectedLine,
	toneText,
	renderFrame,
} from "./ui.js";
import type { MessageTone, SkillEntry } from "./types.js";

export class SingleLineText implements Component {
	constructor(private readonly text: string, private readonly ellipsis = "...") {}
	render(width: number): string[] { return [truncateToWidth(inlineLine(this.text), width, this.ellipsis)]; }
	invalidate(): void {}
}

export class ListLineText implements Component {
	constructor(private readonly text: string, private readonly selected: boolean, private readonly theme: Theme, private readonly ellipsis = "...") {}
	render(width: number): string[] {
		const line = truncateToWidth(inlineLine(this.text), width, this.ellipsis);
		return [this.selected ? skillSelectedLine(this.theme, line, width) : line];
	}
	invalidate(): void {}
}

export class PrefixedEditor implements Component {
	constructor(private readonly editor: Editor, private readonly prefix = "> ") {}
	render(width: number): string[] {
		const rendered = this.editor.render(Math.max(1, width - this.prefix.length));
		const lines = rendered.length >= 2 ? rendered.slice(1, -1) : rendered;
		return lines.length === 0 ? [this.prefix] : lines.map((line, index) => `${index === 0 ? this.prefix : "  "}${line}`);
	}
	invalidate(): void { this.editor.invalidate(); }
}

export class SearchInputLine implements Component {
	constructor(private readonly input: Input, private readonly theme: Theme, private readonly prefix = " ") {}
	render(width: number): string[] {
		const inputWidth = Math.max(1, width - visibleWidth(this.prefix));
		const line = truncateToWidth(`${this.prefix}${this.input.render(inputWidth)[0] ?? ""}`, width, "");
		return [this.theme.bg("toolPendingBg", padAnsi(line, width))];
	}
	invalidate(): void { this.input.invalidate(); }
}

export class ScrollableSkillPreview implements Component {
	private scrollOffset = 0;
	private lastInnerWidth = 1;
	private lastContentLines: string[] = [];
	constructor(private skill: SkillEntry, private readonly theme: Theme, private readonly getTerminalRows: () => number) {}
	setSkill(skill: SkillEntry): void { this.skill = skill; this.scrollOffset = 0; this.lastContentLines = []; }
	invalidate(): void { this.lastContentLines = []; }
	private maxHeight(): number { return Math.max(10, Math.floor(this.getTerminalRows() * 0.78)); }
	private buildContentLines(innerWidth: number): string[] {
		const content = new Container();
		const status = this.skill.enabled ? this.theme.fg("success", "enabled") : this.theme.fg("warning", "disabled");
		const source = packageLabel(this.skill) ? `${packageLabel(this.skill)}` : this.skill.path;
		content.addChild(new Text(skillEntityTitle(this.theme, this.skill.name), 0, 0));
		content.addChild(new Text(`${this.theme.fg("muted", scopeLabel(this.skill))}${this.theme.fg("dim", ` ${glyphs().bullet.trim()} `)}${this.theme.fg("muted", source)}${this.theme.fg("dim", ` ${glyphs().bullet.trim()} `)}${status}`, 0, 0));
		content.addChild(new Spacer(1));
		content.addChild(new Text(this.theme.fg("muted", this.theme.bold("Description")), 0, 0));
		content.addChild(new Text(this.skill.description, 0, 0));
		content.addChild(new Spacer(1));
		content.addChild(new Text(this.theme.fg("muted", this.theme.bold("Metadata")), 0, 0));
		content.addChild(new Text(this.theme.fg("dim", buildFrontmatterBlock(this.skill)), 0, 0));
		content.addChild(new Spacer(1));
		content.addChild(new Text(this.theme.fg("muted", this.theme.bold("Content")), 0, 0));
		content.addChild(new Spacer(1));
		content.addChild(new Markdown(this.skill.content || this.theme.fg("dim", "(empty skill body)"), 0, 0, getMarkdownTheme()));
		const lines = content.render(innerWidth);
		this.lastInnerWidth = innerWidth;
		this.lastContentLines = lines;
		return lines;
	}
	private footer(innerWidth: number, visibleHeight: number, totalLines: number): string {
		const maxScroll = Math.max(0, totalLines - visibleHeight);
		const scroll = maxScroll > 0 ? this.theme.fg("dim", ` ${glyphs().bullet.trim()} ${this.scrollOffset + 1}-${Math.min(totalLines, this.scrollOffset + visibleHeight)}/${totalLines}`) : "";
		const hints: Array<[string, string]> = [["-/=", "page"]];
		hints.push(["alt+x", "enable/disable"]);
		if (isDeletableSkill(this.skill)) hints.push(["alt+e", "edit"], ["alt+r", "rename"], ["backspace", "delete"]);
		return truncateToWidth(`${skillKeyHints(this.theme, hints)}${scroll}`, innerWidth, this.theme.fg("dim", "..."));
	}
	render(width: number): string[] {
		if (width < 8) return [];
		const innerWidth = Math.max(1, width - 4);
		const visibleHeight = Math.max(1, this.maxHeight() - 3);
		const contentLines = this.buildContentLines(innerWidth);
		const maxScroll = Math.max(0, contentLines.length - visibleHeight);
		this.scrollOffset = Math.max(0, Math.min(this.scrollOffset, maxScroll));
		const visible = contentLines.slice(this.scrollOffset, this.scrollOffset + visibleHeight);
		return renderFrame(this.theme, width, [...visible, this.footer(innerWidth, visibleHeight, contentLines.length)]);
	}
	handleInput(data: string): void {
		const visibleHeight = Math.max(1, this.maxHeight() - 3);
		const total = this.lastContentLines.length || this.buildContentLines(this.lastInnerWidth).length;
		const maxScroll = Math.max(0, total - visibleHeight);
		if (matchesKey(data, Key.up)) this.scrollOffset = Math.max(0, this.scrollOffset - 1);
		else if (matchesKey(data, Key.down)) this.scrollOffset = Math.min(maxScroll, this.scrollOffset + 1);
		else if (matchesKey(data, "-") || matchesKey(data, Key.pageUp)) this.scrollOffset = Math.max(0, this.scrollOffset - visibleHeight);
		else if (matchesKey(data, "=") || matchesKey(data, Key.pageDown)) this.scrollOffset = Math.min(maxScroll, this.scrollOffset + visibleHeight);
		else if (matchesKey(data, Key.home)) this.scrollOffset = 0;
		else if (matchesKey(data, Key.end)) this.scrollOffset = maxScroll;
	}
}

export class SkillEditorView implements Component, Focusable {
	private readonly editor: Editor;
	private readonly initialText: string;
	private readonly proxyTui: TUI;
	private virtualRows = 24;
	private _focused = false;
	private message: { text: string; tone: MessageTone } | undefined;
	get focused(): boolean { return this._focused; }
	set focused(value: boolean) { this._focused = value; this.editor.focused = value; }
	constructor(
		private skill: SkillEntry,
		private readonly theme: Theme,
		private readonly realTui: TUI,
		initialText: string,
		private readonly onSave: (value: string) => void,
		private readonly onCancel: () => void,
	) {
		this.initialText = initialText;
		const self = this;
		this.proxyTui = { requestRender: () => realTui.requestRender(), get terminal() { return { ...realTui.terminal, rows: Math.max(1, self.virtualRows) }; } } as TUI;
		this.editor = new Editor(this.proxyTui, getEditorTheme(theme), { autocompleteMaxVisible: 6 });
		this.editor.setText(initialText);
	}
	setSkill(skill: SkillEntry): void { this.skill = skill; }
	setMessage(text: string, tone: MessageTone): void { this.message = { text, tone }; }
	isDirty(): boolean { return this.editor.getText() !== this.initialText; }
	invalidate(): void { this.editor.invalidate(); }
	private targetHeight(): number { return Math.max(10, Math.floor(this.realTui.terminal.rows * 0.78)); }
	private rowsForVisibleEditorLines(targetVisibleLines: number): number {
		let rows = 5;
		while (Math.max(5, Math.floor(rows * 0.3)) < targetVisibleLines && rows < 1000) rows += 1;
		return rows;
	}
	render(width: number): string[] {
		const innerWidth = Math.max(1, width - 4);
		const lines: string[] = [
			skillEntityTitle(this.theme, `Edit ${this.skill.name}`),
			this.theme.fg("muted", skillLocation(this.skill)),
			this.theme.fg("dim", `Name is immutable here: ${this.skill.name}`),
		];
		if (this.message) lines.push("", toneText(this.theme, this.message.tone, this.message.text));
		const targetInnerLines = Math.max(1, this.targetHeight() - 2);
		const staticLineCount = lines.length + 3;
		const editorBlockLines = Math.max(7, targetInnerLines - staticLineCount);
		this.virtualRows = this.rowsForVisibleEditorLines(Math.max(5, editorBlockLines - 2));
		lines.push("", ...this.editor.render(innerWidth), "", truncateToWidth(skillKeyHints(this.theme, [["alt+s", "save"]]), innerWidth, this.theme.fg("dim", "...")));
		while (lines.length < targetInnerLines) lines.splice(Math.max(0, lines.length - 1), 0, "");
		return renderFrame(this.theme, width, lines.slice(0, targetInnerLines));
	}
	handleInput(data: string): void {
		if (matchesKey(data, Key.escape)) { this.onCancel(); return; }
		if (matchesKey(data, Key.alt("s")) || matchesKey(data, Key.ctrl("s"))) { this.onSave(this.editor.getText()); return; }
		if (this.message?.tone === "error") this.message = undefined;
		this.editor.handleInput(data);
	}
}
