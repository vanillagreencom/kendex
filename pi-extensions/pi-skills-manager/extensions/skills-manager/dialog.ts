import { writeFileSync } from "node:fs";
import {
	Container,
	type Focusable,
	Editor,
	Input,
	Key,
	matchesKey,
	Spacer,
	Text,
	type TUI,
	wrapTextWithAnsi,
} from "@earendil-works/pi-tui";
import type { ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import {
	ListLineText,
	PrefixedEditor,
	ScrollableSkillPreview,
	SearchInputLine,
	SingleLineText,
	SkillEditorView,
} from "./components.js";
import { DEFAULT_LIST_ROWS, DEFAULT_POPUP_MAX_HEIGHT, DEFAULT_POPUP_WIDTH } from "./constants.js";
import { renameSkillEntry } from "./creation.js";
import {
	buildEditableSkillDocument,
	normalizeSkillName,
	parseEditableSkillDocument,
	readSkillDocument,
	toUpdatedSkill,
} from "./format.js";
import { normalizeListRows, responsiveBrowsePageSelection, responsiveBrowseWindow, sanitizePopupMaxHeight } from "./layout.js";
import { isDeletableSkill, skillStorageTarget } from "./registry.js";
import { settingNumber, settingOverlaySize, settingString } from "./settings.js";
import {
	acquireVstackModalLock,
	getEditorTheme,
	packageLabel,
	renderCenteredDialog,
	renderFrame,
	scopeLabel,
	skillEntityTitle,
	skillKeyHints,
	skillSectionTitle,
	toneText,
} from "./ui.js";
import {
	CREATE_STEPS,
	type CreateStep,
	type CreateTextStepId,
	type Mode,
	type OverlaySize,
	type SkillEntry,
	type SkillLocation,
	type SkillRegistry,
	type SkillsManagerOptions,
} from "./types.js";

class SkillsManagerDialog implements Focusable {
	private mode: Mode = "browse";
	private _focused = false;
	private registry: SkillRegistry;
	private filteredSkills: SkillEntry[] = [];
	private selectedIndex: number;
	private browseQuery: string;
	private readonly browseInput = new Input();
	private readonly descriptionEditor: Editor;
	private readonly renameInput = new Input();
	private createStepIndex = 0;
	private createValues: Record<CreateTextStepId, string> = { name: "", description: "" };
	private createLocation: SkillLocation;
	private submittedDescriptionValue: string | undefined;
	private createError: string | undefined;
	private previewSkillPath: string | undefined;
	private preview: ScrollableSkillPreview | undefined;
	private editorView: SkillEditorView | undefined;
	private renameError: string | undefined;
	private deleteSkillPath: string | undefined;
	private deleteReturnMode: "browse" | "preview" = "browse";
	private generationAbortController: AbortController | undefined;
	private generationRunId = 0;
	private readonly configuredListRows: number;
	private readonly popupMaxHeight: OverlaySize;

	constructor(
		private readonly ctx: ExtensionContext,
		registry: SkillRegistry,
		private readonly theme: Theme,
		private readonly tui: TUI,
		private readonly done: (skill: SkillEntry | null) => void,
		private readonly options: SkillsManagerOptions,
		private readonly requestRender: () => void,
		initialSelectedIndex = 0,
		initialQuery = "",
	) {
		this.registry = registry;
		this.selectedIndex = Math.max(0, initialSelectedIndex);
		this.browseQuery = initialQuery;
		this.browseInput.setValue(initialQuery);
		this.createLocation = settingString("defaultCreateLocation", "project", ctx.cwd) === "global" ? "global" : "project";
		this.configuredListRows = normalizeListRows(settingNumber("listRows", DEFAULT_LIST_ROWS, ctx.cwd));
		this.popupMaxHeight = sanitizePopupMaxHeight(settingOverlaySize("popupMaxHeight", DEFAULT_POPUP_MAX_HEIGHT, ctx.cwd));
		this.descriptionEditor = new Editor(tui, { borderColor: (text: string) => " ".repeat(text.length), selectList: getEditorTheme(theme).selectList });
		this.descriptionEditor.onSubmit = (text: string) => { this.submittedDescriptionValue = text; void this.advanceCreate(); };
		this.renameInput.onSubmit = (value) => { void this.submitRename(value); };
		this.refreshBrowseList();
	}

	get focused(): boolean { return this._focused; }
	set focused(value: boolean) { this._focused = value; this.syncFocus(); }
	invalidate(): void { this.browseInput.invalidate(); this.descriptionEditor.invalidate(); this.renameInput.invalidate(); this.preview?.invalidate(); this.editorView?.invalidate(); }

	private syncFocus(): void {
		this.browseInput.focused = this._focused && (this.mode === "browse" || (this.mode === "create" && this.currentCreateStep.id === "name"));
		this.descriptionEditor.focused = this._focused && this.mode === "create" && this.currentCreateStep.id === "description";
		this.renameInput.focused = this._focused && this.mode === "rename";
		if (this.editorView) this.editorView.focused = this._focused && this.mode === "edit";
	}

	private searchableText(skill: SkillEntry): string {
		return [skill.name, skill.description, scopeLabel(skill), skill.origin, skill.source, skill.path, skill.baseDir ?? ""].join(" ").toLowerCase();
	}

	private filterSkills(query: string): SkillEntry[] {
		const trimmed = query.trim().toLowerCase();
		if (!trimmed) return this.registry.allSkills;
		const tokens = trimmed.split(/\s+/).filter(Boolean);
		return this.registry.allSkills.filter((skill) => tokens.every((token) => this.searchableText(skill).includes(token)));
	}

	private orderBrowseSkills(skills: SkillEntry[]): SkillEntry[] {
		const own = skills.filter((skill) => isDeletableSkill(skill));
		const library = skills.filter((skill) => !isDeletableSkill(skill));
		return [...own, ...library];
	}

	private refreshBrowseList(preferredPath?: string): void {
		const currentPath = preferredPath ?? this.getSelectedSkill()?.path;
		this.filteredSkills = this.orderBrowseSkills(this.filterSkills(this.browseQuery));
		if (currentPath) {
			const nextIndex = this.filteredSkills.findIndex((skill) => skill.path === currentPath);
			if (nextIndex >= 0) { this.selectedIndex = nextIndex + 1; return; }
		}
		this.selectedIndex = Math.min(this.selectedIndex, Math.max(0, this.filteredSkills.length));
	}

	private getSelectedSkill(): SkillEntry | undefined { return this.selectedIndex === 0 ? undefined : this.filteredSkills[this.selectedIndex - 1]; }
	private getCurrentSkill(): SkillEntry | undefined { return this.previewSkillPath ? this.registry.allSkills.find((skill) => skill.path === this.previewSkillPath) : undefined; }
	private get currentCreateStep(): CreateStep { return CREATE_STEPS[this.createStepIndex]!; }

	private enterCreateMode(): void { this.mode = "create"; this.createStepIndex = 0; this.createError = undefined; this.syncCreateInput(); this.syncFocus(); this.requestRender(); }
	private exitToBrowse(preferredPath?: string): void {
		this.mode = "browse"; this.createError = undefined; this.renameError = undefined; this.previewSkillPath = undefined; this.preview = undefined; this.editorView = undefined; this.deleteSkillPath = undefined;
		this.browseInput.setValue(this.browseQuery); this.refreshBrowseList(preferredPath); this.syncFocus(); this.requestRender();
	}
	private openPreview(skill: SkillEntry): void { this.previewSkillPath = skill.path; this.preview = new ScrollableSkillPreview(skill, this.theme, () => this.tui.terminal.rows); this.mode = "preview"; this.syncFocus(); this.requestRender(); }
	private openDeleteConfirm(skill: SkillEntry, returnMode: "browse" | "preview"): void { this.deleteSkillPath = skill.path; this.deleteReturnMode = returnMode; this.mode = "delete-confirm"; this.syncFocus(); this.requestRender(); }
	private openEditor(): void {
		const skill = this.getCurrentSkill();
		if (!skill || !isDeletableSkill(skill)) return;
		this.editorView = new SkillEditorView(skill, this.theme, this.tui, buildEditableSkillDocument(skill, readSkillDocument(skill)), (value) => { void this.saveEditedSkill(value); }, () => this.closeEditor());
		this.mode = "edit"; this.syncFocus(); this.requestRender();
	}
	private closeEditor(): void { this.editorView = undefined; this.mode = "preview"; this.syncFocus(); this.requestRender(); }
	private openRenameDialog(): void {
		const skill = this.getCurrentSkill();
		if (!skill || !isDeletableSkill(skill)) return;
		this.renameError = undefined; this.renameInput.setValue(skill.name); this.mode = "rename"; this.syncFocus(); this.requestRender();
	}
	private closeRenameDialog(): void { this.renameError = undefined; this.mode = "preview"; this.syncFocus(); this.requestRender(); }

	private syncCreateInput(): void {
		const step = this.currentCreateStep;
		if (step.id === "name") this.browseInput.setValue(this.createValues.name);
		if (step.id === "description") { this.submittedDescriptionValue = undefined; this.descriptionEditor.setText(this.createValues.description); }
	}

	private persistCreateInput(): void {
		const step = this.currentCreateStep;
		if (step.id === "name") this.createValues.name = this.browseInput.getValue();
		else if (step.id === "description") {
			this.createValues.description = this.submittedDescriptionValue !== undefined ? this.submittedDescriptionValue : this.descriptionEditor.getText();
			this.submittedDescriptionValue = undefined;
		}
	}
	private validateCreateStep(): boolean {
		this.persistCreateInput();
		const step = this.currentCreateStep;
		if (step.kind === "text" && !step.optional) {
			const value = this.createValues[step.id].trim();
			if (!value) { this.createError = `${step.title} is required.`; return false; }
			if (step.id === "name" && !normalizeSkillName(value)) { this.createError = "Name must contain letters, numbers, or hyphens."; return false; }
		}
		this.createError = undefined;
		return true;
	}
	private goToPreviousCreateStep(): void { this.persistCreateInput(); if (this.createStepIndex > 0) { this.createError = undefined; this.createStepIndex -= 1; this.syncCreateInput(); this.syncFocus(); } }
	private async advanceCreate(): Promise<void> { if (!this.validateCreateStep()) return; if (this.createStepIndex >= CREATE_STEPS.length - 1) await this.submitCreate(); else { this.createStepIndex += 1; this.syncCreateInput(); this.syncFocus(); } this.requestRender(); }
	private async submitCreate(): Promise<void> {
		const name = normalizeSkillName(this.createValues.name);
		if (!name) { this.createStepIndex = 0; this.syncCreateInput(); this.createError = "Name is required."; return; }
		if (!this.createValues.description.trim()) { this.createStepIndex = 1; this.syncCreateInput(); this.createError = "Description is required."; return; }
		this.mode = "generating";
		const runId = ++this.generationRunId;
		const abortController = new AbortController();
		this.generationAbortController = abortController;
		this.syncFocus(); this.requestRender();
		const created = await this.options.onCreate({ name, description: this.createValues.description.trim(), allowedTools: [], location: this.createLocation }, abortController.signal);
		if (this.generationRunId !== runId) return;
		this.generationAbortController = undefined;
		if (abortController.signal.aborted || !created) { this.mode = "create"; this.syncFocus(); this.requestRender(); return; }
		await this.refreshRegistry(created.path);
		this.openPreview(this.registry.allSkills.find((skill) => skill.path === created.path) ?? created);
	}
	private async refreshRegistry(preferredPath?: string): Promise<void> {
		this.registry = await this.options.onRefresh();
		this.refreshBrowseList(preferredPath);
		if (this.previewSkillPath) {
			const current = this.registry.allSkills.find((skill) => skill.path === this.previewSkillPath);
			if (!current) { this.exitToBrowse(preferredPath); return; }
			this.preview?.setSkill(current); this.editorView?.setSkill(current);
		}
	}
	private async toggleSkill(skill: SkillEntry): Promise<void> {
		const nextEnabled = !skill.enabled;
		try {
			await this.options.onToggle(skill, nextEnabled);
			await this.refreshRegistry(skill.path);
			this.ctx.ui.notify(`${nextEnabled ? "Enabled" : "Disabled"} ${skill.name}. Run /reload to fully apply the change.`, "info");
		} catch (error) {
			this.ctx.ui.notify(error instanceof Error ? error.message : "Failed to update skill visibility", "error");
		}
		this.requestRender();
	}
	private async confirmDelete(): Promise<void> {
		const skill = this.deleteSkillPath ? this.registry.allSkills.find((entry) => entry.path === this.deleteSkillPath) : undefined;
		if (!skill) { this.exitToBrowse(); return; }
		const deleted = await this.options.onDelete(skill);
		if (!deleted) { this.mode = this.deleteReturnMode === "preview" ? "preview" : "browse"; this.syncFocus(); this.requestRender(); return; }
		this.deleteSkillPath = undefined; this.previewSkillPath = undefined; this.preview = undefined;
		await this.refreshRegistry();
		this.exitToBrowse();
	}
	private async submitRename(value: string): Promise<void> {
		const skill = this.getCurrentSkill();
		if (!skill) { this.exitToBrowse(); return; }
		try {
			const renamed = await renameSkillEntry(this.ctx, skill, value);
			if (!renamed) { this.closeRenameDialog(); return; }
			this.previewSkillPath = renamed.path;
			await this.refreshRegistry(renamed.path);
			this.closeRenameDialog();
		} catch (error) {
			this.renameError = error instanceof Error ? error.message : "Failed to rename skill";
			this.requestRender();
		}
	}
	private async saveEditedSkill(raw: string): Promise<void> {
		const skill = this.getCurrentSkill();
		if (!skill) { this.exitToBrowse(); return; }
		try {
			const parsed = parseEditableSkillDocument(raw, skill.name);
			writeFileSync(skill.path, parsed.raw, "utf8");
			await this.refreshRegistry(skill.path);
			this.preview?.setSkill(this.registry.allSkills.find((entry) => entry.path === skill.path) ?? toUpdatedSkill(skill, parsed));
			this.ctx.ui.notify(`Updated skill: ${skill.name}`, "info");
			this.closeEditor();
		} catch (error) {
			this.editorView?.setMessage(error instanceof Error ? error.message : "Failed to save skill", "error");
			this.requestRender();
		}
	}

	render(width: number): string[] {
		if (this.mode === "preview") return this.preview?.render(width) ?? [];
		if (this.mode === "edit") return this.editorView?.render(width) ?? [];
		if (this.mode === "rename") return this.renderRenameDialog(width);
		if (this.mode === "delete-confirm") return this.renderDeleteDialog(width);
		if (this.mode === "generating") return this.renderGeneratingDialog(width);
		return this.mode === "create" ? this.renderCreate(width) : this.renderBrowse(width);
	}

	private renderBrowse(width: number): string[] {
		const innerWidth = Math.max(1, width - 4);
		const root = new Container();
		const enabledCount = this.registry.allSkills.filter((skill) => skill.enabled).length;
		const totalCount = this.registry.allSkills.length;
		root.addChild(new SearchInputLine(this.browseInput, this.theme));
		root.addChild(new Spacer(1));
		const list = new Container();
		const entries: Array<{ kind: "create" } | { kind: "header"; label: string } | { kind: "skill"; skill: SkillEntry }> = [{ kind: "create" }];
		const own = this.filteredSkills.filter((skill) => isDeletableSkill(skill));
		const library = this.filteredSkills.filter((skill) => !isDeletableSkill(skill));
		if (own.length > 0) entries.push({ kind: "header", label: "Your Skills" }, ...own.map((skill) => ({ kind: "skill" as const, skill })));
		if (library.length > 0) entries.push({ kind: "header", label: "Library Skills" }, ...library.map((skill) => ({ kind: "skill" as const, skill })));
		let selectedDisplayIndex = 0;
		let selectableIndex = 0;
		for (let i = 0; i < entries.length; i++) {
			const entry = entries[i]!;
			if (entry.kind === "create" || entry.kind === "skill") {
				if (selectableIndex === this.selectedIndex) { selectedDisplayIndex = i; break; }
				selectableIndex += 1;
			}
		}
		const { startIndex, endIndex } = responsiveBrowseWindow(this.configuredListRows, this.tui.terminal.rows, entries.length, selectedDisplayIndex, this.popupMaxHeight);
		selectableIndex = 0;
		const ellipsis = this.theme.fg("dim", "...");
		for (let i = 0; i < endIndex; i++) {
			const entry = entries[i]!;
			const isSelectable = entry.kind === "create" || entry.kind === "skill";
			const isSelected = isSelectable && selectableIndex === this.selectedIndex;
			if (i >= startIndex) {
				if (entry.kind === "header") {
					list.addChild(new Spacer(1));
					list.addChild(new SingleLineText(skillSectionTitle(this.theme, entry.label), ellipsis));
				} else if (entry.kind === "create") {
					const prefix = " ";
					const label = "Create new skill";
					list.addChild(new ListLineText(`${prefix}${label}${this.theme.fg("dim", " — generate and save a new skill")}`, isSelected, this.theme, ellipsis));
				} else {
					const skill = entry.skill;
					const prefix = " ";
					const name = skill.enabled ? skill.name : this.theme.fg("muted", skill.name);
					const status = skill.enabled ? "" : this.theme.fg("warning", " [disabled]");
					const scope = this.theme.fg("muted", ` [${scopeLabel(skill)}]`);
					const source = packageLabel(skill) ? this.theme.fg("muted", ` [${packageLabel(skill)}]`) : "";
					const description = this.theme.fg("dim", ` — ${skill.description}`);
					list.addChild(new ListLineText(`${prefix}${name}${status}${scope}${source}${description}`, isSelected, this.theme, ellipsis));
				}
			}
			if (isSelectable) selectableIndex += 1;
		}
		if (entries.length === 1 && this.filteredSkills.length === 0) list.addChild(new Text(this.theme.fg("dim", "No skills match your search."), 1, 0));
		root.addChild(list);
		root.addChild(new Spacer(1));
		const selected = this.getSelectedSkill();
		const actions: Array<[string, string]> = [["-/=", "page"]];
		if (selected) { actions.push(["tab", "preview"], ["alt+x", "enable/disable"]); if (!this.browseQuery && isDeletableSkill(selected)) actions.push(["backspace", "delete"]); }
		root.addChild(new Text(skillKeyHints(this.theme, actions), 1, 0));
		return renderFrame(this.theme, width, root.render(innerWidth), undefined, "Skills Manager", `${enabledCount}/${totalCount} enabled`);
	}

	private renderCreate(width: number): string[] {
		const innerWidth = Math.max(1, width - 4);
		const step = this.currentCreateStep;
		const root = new Container();
		root.addChild(new Text(skillEntityTitle(this.theme, `${step.title} (${this.createStepIndex + 1}/${CREATE_STEPS.length})`), 1, 0));
		root.addChild(new Spacer(1));
		if (step.id === "name") { root.addChild(this.browseInput); root.addChild(new Spacer(1)); root.addChild(new Text(this.theme.fg("dim", step.hint), 1, 0)); }
		else if (step.id === "description") { root.addChild(new PrefixedEditor(this.descriptionEditor)); root.addChild(new Spacer(1)); root.addChild(new Text(this.theme.fg("dim", step.hint), 1, 0)); }
		else {
			for (const option of step.options) {
				const selected = option.value === this.createLocation;
				root.addChild(new ListLineText(` ${option.label}${this.theme.fg(selected ? "text" : "dim", ` — ${option.description}`)}`, selected, this.theme));
			}
			root.addChild(new Spacer(1)); root.addChild(new Text(this.theme.fg("dim", step.hint), 1, 0));
		}
		if (this.createError) { root.addChild(new Spacer(1)); root.addChild(new Text(this.theme.fg("error", this.createError), 1, 0)); }
		root.addChild(new Spacer(1));
		const footer = step.id === "description"
			? skillKeyHints(this.theme, [["alt+←", "back"], ["alt+→", "next"]])
			: step.id === "location"
				? skillKeyHints(this.theme, [["alt+←", "back"]])
				: skillKeyHints(this.theme, [["alt+←", "back"], ["alt+→", "next"]]);
		root.addChild(new Text(footer, 1, 0));
		return renderFrame(this.theme, width, root.render(innerWidth));
	}
	private renderRenameDialog(width: number): string[] {
		const lines = [skillEntityTitle(this.theme, "Rename skill"), "", this.theme.fg("dim", "enter new skill name (lowercase letters, numbers, hyphens)"), "", ...this.renameInput.render(Math.max(1, Math.min(width - 4, 64)))];
		if (this.renameError) lines.push("", toneText(this.theme, "error", this.renameError));
		return renderCenteredDialog(this.theme, width, lines);
	}
	private renderDeleteDialog(width: number): string[] {
		const skill = this.deleteSkillPath ? this.registry.allSkills.find((entry) => entry.path === this.deleteSkillPath) : undefined;
		const innerWidth = Math.max(1, Math.min(width - 4, 64));
		const message = skill ? `Delete ${skill.name}? This removes ${skillStorageTarget(skill)} and cannot be undone.` : "Delete this skill?";
		return renderCenteredDialog(this.theme, width, [skillEntityTitle(this.theme, "Delete skill"), "", ...wrapTextWithAnsi(message, innerWidth), ""]);
	}
	private renderGeneratingDialog(width: number): string[] {
		const modelLabel = this.ctx.model?.id ?? "fallback template";
		return renderCenteredDialog(this.theme, width, [skillEntityTitle(this.theme, "Generating skill"), "", this.theme.fg("dim", `Using ${modelLabel} to draft SKILL.md.`), this.theme.fg("dim", "The preview opens when generation finishes.")]);
	}

	handleInput(data: string): void {
		if (this.mode === "generating") { if (matchesKey(data, Key.escape)) { this.generationAbortController?.abort(); this.generationAbortController = undefined; this.generationRunId += 1; this.mode = "create"; this.syncFocus(); this.requestRender(); } return; }
		if (this.mode === "rename") { if (matchesKey(data, Key.escape)) { this.closeRenameDialog(); return; } if (this.renameError) this.renameError = undefined; this.renameInput.handleInput(data); return; }
		if (this.mode === "delete-confirm") { if (matchesKey(data, Key.escape)) { this.mode = this.deleteReturnMode === "preview" ? "preview" : "browse"; this.syncFocus(); return; } if (matchesKey(data, Key.enter)) void this.confirmDelete(); return; }
		if (this.mode === "edit") { this.editorView?.handleInput(data); return; }
		if (this.mode === "preview") {
			const skill = this.getCurrentSkill();
			if (!skill) { this.exitToBrowse(); return; }
			if (matchesKey(data, Key.escape) || matchesKey(data, Key.tab)) { this.exitToBrowse(skill.path); return; }
			if (matchesKey(data, Key.enter)) { if (!skill.enabled) this.ctx.ui.notify("Enable this skill first with alt+x", "info"); else this.done(skill); return; }
			if (matchesKey(data, Key.alt("x")) || matchesKey(data, Key.ctrl("x"))) { void this.toggleSkill(skill); return; }
			if (isDeletableSkill(skill) && (matchesKey(data, Key.alt("e")) || matchesKey(data, Key.ctrl("e")))) { this.openEditor(); return; }
			if (isDeletableSkill(skill) && (matchesKey(data, Key.alt("r")) || matchesKey(data, Key.ctrl("r")))) { this.openRenameDialog(); return; }
			if (isDeletableSkill(skill) && (matchesKey(data, Key.backspace) || matchesKey(data, "delete"))) { this.openDeleteConfirm(skill, "preview"); return; }
			this.preview?.handleInput(data); return;
		}
		if (this.mode === "create") { this.handleCreateInput(data); return; }
		this.handleBrowseInput(data);
	}
	private handleBrowseInput(data: string): void {
		if (matchesKey(data, Key.up)) { this.selectedIndex = this.selectedIndex === 0 ? this.filteredSkills.length : this.selectedIndex - 1; return; }
		if (matchesKey(data, Key.down)) { this.selectedIndex = this.selectedIndex === this.filteredSkills.length ? 0 : this.selectedIndex + 1; return; }
		if (matchesKey(data, "-") || matchesKey(data, Key.pageUp)) { this.selectedIndex = responsiveBrowsePageSelection(this.configuredListRows, this.tui.terminal.rows, this.selectedIndex, this.filteredSkills.length, -1, this.popupMaxHeight); return; }
		if (matchesKey(data, "=") || matchesKey(data, Key.pageDown)) { this.selectedIndex = responsiveBrowsePageSelection(this.configuredListRows, this.tui.terminal.rows, this.selectedIndex, this.filteredSkills.length, 1, this.popupMaxHeight); return; }
		if (matchesKey(data, Key.enter)) { if (this.selectedIndex === 0) { this.enterCreateMode(); return; } const skill = this.getSelectedSkill(); if (!skill) return; if (!skill.enabled) this.ctx.ui.notify("Enable this skill first with alt+x", "info"); else this.done(skill); return; }
		if (matchesKey(data, Key.tab)) { const skill = this.getSelectedSkill(); if (skill) this.openPreview(skill); return; }
		if (matchesKey(data, Key.alt("x")) || matchesKey(data, Key.ctrl("x"))) { const skill = this.getSelectedSkill(); if (skill) void this.toggleSkill(skill); return; }
		if (matchesKey(data, Key.backspace) && !this.browseInput.getValue()) { const skill = this.getSelectedSkill(); if (skill && isDeletableSkill(skill)) this.openDeleteConfirm(skill, "browse"); return; }
		if (matchesKey(data, Key.escape)) { if (this.browseInput.getValue()) { this.browseQuery = ""; this.browseInput.setValue(""); this.refreshBrowseList(); } else this.done(null); return; }
		this.browseInput.handleInput(data); this.browseQuery = this.browseInput.getValue(); this.refreshBrowseList();
	}
	private handleCreateInput(data: string): void {
		if (matchesKey(data, Key.escape)) { this.exitToBrowse(); return; }
		if (matchesKey(data, Key.alt("left"))) { this.goToPreviousCreateStep(); return; }
		if (matchesKey(data, Key.alt("right"))) { void this.advanceCreate(); return; }
		if (matchesKey(data, Key.enter) && this.currentCreateStep.id !== "description") { void this.advanceCreate(); return; }
		this.createError = undefined;
		const step = this.currentCreateStep;
		if (step.id === "name") { this.browseInput.handleInput(data); this.createValues.name = this.browseInput.getValue(); return; }
		if (step.id === "location") { if (matchesKey(data, Key.up)) this.createLocation = this.createLocation === "project" ? "global" : "project"; else if (matchesKey(data, Key.down)) this.createLocation = this.createLocation === "project" ? "global" : "project"; return; }
		this.descriptionEditor.handleInput(data); if (!matchesKey(data, Key.enter)) this.createValues.description = this.descriptionEditor.getText();
	}
}

export async function showSkillsManager(ctx: ExtensionContext, registry: SkillRegistry, options: SkillsManagerOptions): Promise<SkillEntry | null> {
	const releaseModalLock = acquireVstackModalLock();
	try {
		return await ctx.ui.custom<SkillEntry | null>((tui, theme, _kb, done) => {
			const dialog = new SkillsManagerDialog(ctx, registry, theme, tui, done, options, () => tui.requestRender());
			return {
				get focused() { return dialog.focused; },
				set focused(value: boolean) { dialog.focused = value; },
				render(width: number) { return dialog.render(width); },
				invalidate() { dialog.invalidate(); },
				handleInput(data: string) { dialog.handleInput(data); tui.requestRender(); },
			};
		}, {
			overlay: true,
			overlayOptions: {
				anchor: "center",
				width: settingOverlaySize("popupWidth", DEFAULT_POPUP_WIDTH, ctx.cwd),
				maxHeight: sanitizePopupMaxHeight(settingOverlaySize("popupMaxHeight", DEFAULT_POPUP_MAX_HEIGHT, ctx.cwd)),
			},
		});
	} finally {
		releaseModalLock();
	}
}
