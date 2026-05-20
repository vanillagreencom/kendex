import type { ExtensionAPI, KeybindingsManager, Theme } from "@earendil-works/pi-coding-agent";
import { Input, matchesKey, truncateToWidth, visibleWidth, type Focusable } from "@earendil-works/pi-tui";
import { acquireVstackModalLock, clearLegacySessionStatus, deleteSessionFile, loadSessionsForScope, renameSession } from "./actions.js";
import { currentModelInfo, modelLabel, sameModel, sessionModelInfo } from "./model.js";
import { canonicalPath, samePath } from "./paths.js";
import { buildSnippet, matchSession, parseQuery, styleSearchMatches } from "./search.js";
import { isNamed, sessionResumeTitle, sessionUserMessagesCache } from "./session-data.js";
import { settingNumber, settingScope, settingSort } from "./settings.js";
import { ansiGreen, ansiRed, ansiYellow, centerAnsi, formatAge, oneLine, padAnsi, shortenPath } from "./text.js";
import { buildSessionTree, flattenSessionTree, rowTreePrefix } from "./tree.js";
import { frameGlyphs, glyphs } from "./glyphs.js";
import {
	DEFAULT_ROWS,
	DEFAULT_WIDTH,
	POPUP_HEIGHT_RATIO,
	POPUP_MARGIN_ROWS,
	POPUP_PADDING_X,
	POPUP_PADDING_Y,
	ROW_META_MAX_WIDTH,
	type FlatSessionNode,
	type Mode,
	type NameFilter,
	type Scope,
	type SessionAction,
	type SessionInfo,
	type SessionManagerContext,
	type SortMode,
} from "./types.js";

class SessionManagerOverlay implements Focusable {
	private _focused = false;
	get focused(): boolean {
		return this._focused;
	}
	set focused(value: boolean) {
		this._focused = value;
		this.searchInput.focused = value;
		this.renameInput.focused = value;
	}

	private mode: Mode = "loading";
	private sessions: SessionInfo[] = [];
	private filtered: FlatSessionNode[] = [];
	private selectedIndex = 0;
	private scrollOffset = 0;
	private searchInput = new Input();
	private renameInput = new Input();
	private renameTarget: SessionInfo | undefined;
	private deleteTarget: SessionInfo | undefined;
	private deleteAllTargets: SessionInfo[] = [];
	private deleteConfirmSelection: 0 | 1 = 0;
	private modelConfirmTarget: SessionInfo | undefined;
	private modelConfirmSelection: 0 | 1 = 0;
	private notice: { kind: "info" | "error"; text: string } | undefined;
	private queryError: string | undefined;
	private loadingProgress: { loaded: number; total: number } | undefined;
	private loadSeq = 0;
	private scope: Scope;
	private sortMode: SortMode;
	private nameFilter: NameFilter = "all";
	private currentSessionPath: string | undefined;

	constructor(
		private readonly ctx: SessionManagerContext,
		private readonly pi: ExtensionAPI,
		private readonly theme: Theme,
		private readonly keybindings: KeybindingsManager,
		private readonly done: (action: SessionAction) => void,
		private readonly tui: { requestRender(): void; terminal?: { rows?: number } },
		initialScope?: Scope,
	) {
		this.scope = initialScope ?? settingScope(ctx.cwd);
		this.sortMode = settingSort(ctx.cwd);
		this.currentSessionPath = ctx.sessionManager.getSessionFile();
		this.searchInput.focused = true;
		this.renameInput.onSubmit = (value) => void this.commitRename(value);
		void this.reload();
	}

	private get visibleRows(): number {
		const configured = Math.max(1, Math.min(30, Math.floor(settingNumber("visibleRows", DEFAULT_ROWS, this.ctx.cwd))));
		return Math.min(configured, this.responsiveVisibleRows());
	}

	private maxPopupRows(): number {
		const terminalRows = Number(this.tui.terminal?.rows ?? process.stdout.rows ?? 30);
		const safeRows = Number.isFinite(terminalRows) && terminalRows > 0 ? terminalRows : 30;
		return Math.max(1, Math.floor(safeRows * POPUP_HEIGHT_RATIO) - POPUP_MARGIN_ROWS * 2);
	}

	private footerRowCount(): number {
		return this.mode === "confirm-delete" || this.mode === "confirm-delete-all" || this.mode === "confirm-model" || this.mode === "rename" ? 1 : 2;
	}

	private detailRowCount(): number {
		const selectedNode = this.filtered[this.selectedIndex];
		if (!selectedNode?.session) return 1;
		const hasMatchSnippet = Boolean(oneLine(this.searchInput.getValue()) && selectedNode.snippet);
		return hasMatchSnippet ? 3 : 2;
	}

	private responsiveVisibleRows(): number {
		// Fixed chrome around the scrollable session list:
		// top/bottom borders, padding, tabs, search/subheader, dividers, detail pane,
		// blank footer spacer, and footer help. The list is the only section that
		// should shrink on shorter terminals; allow it to collapse all the way to 1 row.
		const chromeRows = 11 + this.detailRowCount() + this.footerRowCount();
		return Math.max(1, this.maxPopupRows() - chromeRows);
	}

	private notify(kind: "info" | "error", text: string): void {
		this.notice = { kind, text: oneLine(text) };
	}

	private requestRender(): void {
		this.tui.requestRender();
	}

	private async reload(): Promise<void> {
		const seq = ++this.loadSeq;
		this.mode = "loading";
		this.loadingProgress = undefined;
		this.requestRender();
		try {
			const sessions = await loadSessionsForScope(this.ctx.cwd, this.scope, (loaded, total) => {
				if (seq !== this.loadSeq) return;
				this.loadingProgress = { loaded, total };
				this.requestRender();
			});
			if (seq !== this.loadSeq) return;
			sessionUserMessagesCache.clear();
			this.sessions = sessions.sort((a, b) => b.modified.getTime() - a.modified.getTime());
			this.mode = "browse";
			this.applyFilter(false);
		} catch (error) {
			if (seq !== this.loadSeq) return;
			this.sessions = [];
			this.mode = "browse";
			this.notify("error", `Failed to load sessions: ${error instanceof Error ? error.message : String(error)}`);
			this.applyFilter(false);
		}
		this.requestRender();
	}

	private selected(): SessionInfo | undefined {
		return this.filtered[this.selectedIndex]?.session;
	}

	private isCurrent(session: SessionInfo): boolean {
		return samePath(session.path, this.currentSessionPath);
	}

	private applyFilter(resetSelection = true): void {
		const query = this.searchInput.getValue().trim();
		const parsed = parseQuery(query);
		this.queryError = parsed.error;
		const base = this.nameFilter === "named" ? this.sessions.filter(isNamed) : [...this.sessions];

		if (parsed.error) {
			this.filtered = [];
		} else if (!query && this.sortMode === "threaded") {
			this.filtered = flattenSessionTree(buildSessionTree(base));
		} else {
			const nodes: FlatSessionNode[] = [];
			for (const session of base) {
				const match = matchSession(session, parsed);
				if (!match.matches) continue;
				nodes.push({ session, depth: 0, isLast: true, ancestorContinues: [], score: match.score, snippet: buildSnippet(session, parsed) });
			}
			nodes.sort((a, b) => {
				if (this.sortMode === "recent" || !query) return b.session.modified.getTime() - a.session.modified.getTime();
				return a.score - b.score || b.session.modified.getTime() - a.session.modified.getTime();
			});
			this.filtered = nodes;
		}
		if (this.nameFilter === "named") this.filtered = this.filtered.filter((node) => isNamed(node.session));

		if (resetSelection) {
			this.selectedIndex = 0;
			this.scrollOffset = 0;
		}
		this.syncSelection();
	}

	private syncSelection(): void {
		if (this.filtered.length === 0) {
			this.selectedIndex = 0;
			this.scrollOffset = 0;
			return;
		}
		this.selectedIndex = Math.max(0, Math.min(this.selectedIndex, this.filtered.length - 1));
		const rows = this.visibleRows;
		const maxScroll = Math.max(0, this.filtered.length - rows);
		if (this.selectedIndex < this.scrollOffset) this.scrollOffset = this.selectedIndex;
		else if (this.selectedIndex >= this.scrollOffset + rows) this.scrollOffset = this.selectedIndex - rows + 1;
		this.scrollOffset = Math.max(0, Math.min(this.scrollOffset, maxScroll));
	}

	private moveSelection(delta: number): void {
		if (this.filtered.length === 0) return;
		this.selectedIndex = Math.max(0, Math.min(this.selectedIndex + delta, this.filtered.length - 1));
		this.syncSelection();
	}

	private setSelection(index: number): void {
		this.selectedIndex = Math.max(0, Math.min(index, Math.max(0, this.filtered.length - 1)));
		this.syncSelection();
	}

	private startRename(session: SessionInfo): void {
		this.renameTarget = session;
		this.renameInput = new Input();
		this.renameInput.focused = this.focused;
		this.renameInput.setValue(oneLine(session.name) || sessionResumeTitle(session));
		this.renameInput.onSubmit = (value) => void this.commitRename(value);
		this.mode = "rename";
		this.notice = undefined;
	}

	private async commitRename(value: string): Promise<void> {
		const target = this.renameTarget;
		if (!target) return;
		const next = oneLine(value);
		try {
			if (this.isCurrent(target)) {
				this.pi.setSessionName(next);
				clearLegacySessionStatus(this.ctx);
			} else {
				renameSession(target.path, next);
			}
			this.notify("info", next ? `Renamed to “${next}”` : "Cleared session name");
			this.mode = "browse";
			this.renameTarget = undefined;
			await this.reload();
		} catch (error) {
			this.mode = "browse";
			this.renameTarget = undefined;
			this.notify("error", `Rename failed: ${error instanceof Error ? error.message : String(error)}`);
			this.requestRender();
		}
	}

	private cancelModalMode(): void {
		this.mode = "browse";
		this.renameTarget = undefined;
		this.deleteTarget = undefined;
		this.deleteAllTargets = [];
		this.deleteConfirmSelection = 0;
		this.modelConfirmTarget = undefined;
		this.modelConfirmSelection = 0;
	}

	private resumeAction(session: SessionInfo, keepCurrentModel = false): SessionAction {
		return { type: "resume", path: session.path, title: sessionResumeTitle(session), keepCurrentModel };
	}

	private startResume(session: SessionInfo): void {
		const previousModel = sessionModelInfo(session.path);
		const activeModel = currentModelInfo(this.ctx);
		if (previousModel && activeModel && !sameModel(previousModel, activeModel)) {
			this.modelConfirmTarget = session;
			this.modelConfirmSelection = 0;
			this.mode = "confirm-model";
			this.notice = undefined;
			this.requestRender();
			return;
		}
		this.done(this.resumeAction(session, false));
	}

	private confirmModelResume(): void {
		const target = this.modelConfirmTarget;
		if (!target) return;
		this.done(this.resumeAction(target, this.modelConfirmSelection === 1));
	}

	private startDelete(session: SessionInfo): void {
		if (this.isCurrent(session)) {
			this.notify("error", "Cannot delete the current active session");
			return;
		}
		this.deleteTarget = session;
		this.deleteConfirmSelection = 0;
		this.mode = "confirm-delete";
		this.notice = undefined;
	}

	private async confirmDelete(): Promise<void> {
		const target = this.deleteTarget;
		if (!target) return;
		this.mode = "deleting";
		this.requestRender();
		const result = await deleteSessionFile(target.path, this.ctx.cwd, target.id);
		if (result.ok) {
			this.sessions = this.sessions.filter((session) => !samePath(session.path, target.path));
			this.mode = "browse";
			this.deleteTarget = undefined;
			this.notify("info", result.method === "trash" ? "Session moved to trash" : "Session deleted");
			this.applyFilter(false);
		} else {
			this.mode = "browse";
			this.deleteTarget = undefined;
			this.notify("error", `Delete failed: ${result.error ?? "unknown error"}`);
		}
		this.requestRender();
	}

	private startDeleteAll(): void {
		const seen = new Set<string>();
		const targets: SessionInfo[] = [];
		for (const node of this.filtered) {
			const session = node.session;
			if (this.isCurrent(session)) continue;
			const key = canonicalPath(session.path) ?? session.path;
			if (seen.has(key)) continue;
			seen.add(key);
			targets.push(session);
		}
		if (targets.length === 0) {
			this.notify("error", "No deletable sessions in the current view");
			return;
		}
		this.deleteAllTargets = targets;
		this.deleteTarget = undefined;
		this.deleteConfirmSelection = 0;
		this.mode = "confirm-delete-all";
		this.notice = undefined;
	}

	private async confirmDeleteAll(): Promise<void> {
		const targets = this.deleteAllTargets;
		if (targets.length === 0) return;
		this.mode = "deleting";
		this.requestRender();
		let deleted = 0;
		let trashed = 0;
		const failures: string[] = [];
		for (const target of targets) {
			if (this.isCurrent(target)) continue;
			const result = await deleteSessionFile(target.path, this.ctx.cwd, target.id);
			if (result.ok) {
				deleted += 1;
				if (result.method === "trash") trashed += 1;
				this.sessions = this.sessions.filter((session) => !samePath(session.path, target.path));
			} else {
				failures.push(`${sessionResumeTitle(target)}: ${result.error ?? "unknown error"}`);
			}
		}
		this.mode = "browse";
		this.deleteAllTargets = [];
		if (failures.length > 0) {
			this.notify("error", `Deleted ${deleted}; failed ${failures.length}: ${failures[0]}`);
		} else {
			this.notify("info", trashed > 0 ? `${deleted} sessions moved to trash` : `${deleted} sessions deleted`);
		}
		this.applyFilter(false);
		this.requestRender();
	}

	handleInput(data: string): void {
		if (this.mode === "rename") {
			if (this.keybindings.matches(data, "tui.select.cancel")) {
				this.cancelModalMode();
				this.requestRender();
				return;
			}
			this.renameInput.handleInput(data);
			this.requestRender();
			return;
		}

		if (this.mode === "confirm-delete" || this.mode === "confirm-delete-all") {
			if (this.keybindings.matches(data, "tui.select.up") || this.keybindings.matches(data, "tui.select.down") || matchesKey(data, "up") || matchesKey(data, "down")) {
				this.deleteConfirmSelection = this.deleteConfirmSelection === 0 ? 1 : 0;
				this.requestRender();
				return;
			}
			if (this.keybindings.matches(data, "tui.select.confirm") || matchesKey(data, "enter") || matchesKey(data, "return")) {
				if (this.deleteConfirmSelection === 1) {
					this.cancelModalMode();
					this.requestRender();
					return;
				}
				if (this.mode === "confirm-delete-all") void this.confirmDeleteAll();
				else void this.confirmDelete();
				return;
			}
			if (this.keybindings.matches(data, "tui.select.cancel") || matchesKey(data, "backspace") || matchesKey(data, "escape")) {
				this.cancelModalMode();
				this.requestRender();
				return;
			}
			return;
		}

		if (this.mode === "confirm-model") {
			if (this.keybindings.matches(data, "tui.select.up") || this.keybindings.matches(data, "tui.select.down") || matchesKey(data, "up") || matchesKey(data, "down")) {
				this.modelConfirmSelection = this.modelConfirmSelection === 0 ? 1 : 0;
				this.requestRender();
				return;
			}
			if (this.keybindings.matches(data, "tui.select.confirm") || matchesKey(data, "enter") || matchesKey(data, "return")) {
				this.confirmModelResume();
				return;
			}
			if (this.keybindings.matches(data, "tui.select.cancel") || matchesKey(data, "backspace") || matchesKey(data, "escape")) {
				this.cancelModalMode();
				this.requestRender();
				return;
			}
			return;
		}

		if (this.mode === "deleting" || this.mode === "loading") {
			if (this.keybindings.matches(data, "tui.select.cancel")) this.done({ type: "cancel" });
			return;
		}

		if (this.keybindings.matches(data, "tui.select.cancel")) {
			if (this.searchInput.getValue()) {
				this.searchInput.setValue("");
				this.applyFilter();
				this.requestRender();
				return;
			}
			this.done({ type: "cancel" });
			return;
		}

		if (this.keybindings.matches(data, "tui.input.tab")) {
			this.scope = this.scope === "current" ? "all" : "current";
			this.searchInput.setValue("");
			void this.reload();
			return;
		}

		if (matchesKey(data, "alt+s") || this.keybindings.matches(data, "app.session.toggleSort")) {
			this.sortMode = this.sortMode === "threaded" ? "recent" : this.sortMode === "recent" ? "relevance" : "threaded";
			this.applyFilter();
			this.requestRender();
			return;
		}

		if (matchesKey(data, "alt+n") || this.keybindings.matches(data, "app.session.toggleNamedFilter")) {
			this.nameFilter = this.nameFilter === "all" ? "named" : "all";
			this.applyFilter();
			this.requestRender();
			return;
		}

		if (matchesKey(data, "alt+r") || this.keybindings.matches(data, "app.session.rename")) {
			const selected = this.selected();
			if (selected) this.startRename(selected);
			this.requestRender();
			return;
		}

		if (matchesKey(data, "alt+d")) {
			this.startDeleteAll();
			this.requestRender();
			return;
		}

		if (matchesKey(data, "delete")) {
			const selected = this.selected();
			if (selected) this.startDelete(selected);
			this.requestRender();
			return;
		}

		if (this.keybindings.matches(data, "tui.select.confirm")) {
			const selected = this.selected();
			if (selected) this.startResume(selected);
			return;
		}

		if (this.keybindings.matches(data, "tui.select.up")) {
			this.moveSelection(-1);
			this.requestRender();
			return;
		}
		if (this.keybindings.matches(data, "tui.select.down")) {
			this.moveSelection(1);
			this.requestRender();
			return;
		}
		if (matchesKey(data, "-") || this.keybindings.matches(data, "tui.select.pageUp")) {
			this.setSelection(this.selectedIndex - this.visibleRows);
			this.requestRender();
			return;
		}
		if (matchesKey(data, "=") || this.keybindings.matches(data, "tui.select.pageDown")) {
			this.setSelection(this.selectedIndex + this.visibleRows);
			this.requestRender();
			return;
		}
		if (matchesKey(data, "home")) {
			this.setSelection(0);
			this.requestRender();
			return;
		}
		if (matchesKey(data, "end")) {
			this.setSelection(this.filtered.length - 1);
			this.requestRender();
			return;
		}

		this.searchInput.handleInput(data);
		this.applyFilter();
		this.requestRender();
	}

	render(width: number): string[] {
		const configured = Math.max(72, Math.floor(settingNumber("overlayWidth", DEFAULT_WIDTH, this.ctx.cwd)));
		const renderWidth = Math.min(Math.max(48, width), configured);
		const frameInner = Math.max(10, renderWidth - 2);
		const bodyWidth = Math.max(10, frameInner - POPUP_PADDING_X * 2);
		const th = this.theme;
		const border = (s: string) => th.fg("borderAccent", s);
		const dim = (s: string) => th.fg("dim", s);
		const muted = (s: string) => th.fg("muted", s);
		const accent = (s: string) => th.fg("accent", s);
		const warning = (s: string) => th.fg("warning", s);
		const error = (s: string) => th.fg("error", s);
		const success = (s: string) => th.fg("success", s);
		const frame = frameGlyphs();

		const fixed = (content = "", rowWidth = bodyWidth): string => {
			const safe = content.replace(/[\r\n\t]+/g, " ");
			const clipped = truncateToWidth(safe, rowWidth, "");
			return clipped + " ".repeat(Math.max(0, rowWidth - visibleWidth(clipped)));
		};
		const top = (title: string, right = "") => {
			const rightPlain = right ? ` ${right} ` : "";
			const titleBudget = Math.max(1, frameInner - visibleWidth(rightPlain) - 1);
			const titlePlain = ` ${truncateToWidth(title, Math.max(1, titleBudget - 2), glyphs().ellipsis)} `;
			const fill = Math.max(1, frameInner - visibleWidth(titlePlain) - visibleWidth(rightPlain));
			return `${border(frame.tl)}${ansiGreen(titlePlain)}${border(frame.h.repeat(fill))}${right ? dim(rightPlain) : ""}${border(frame.tr)}`;
		};
		const blank = () => border(frame.v) + " ".repeat(frameInner) + border(frame.v);
		const row = (content = "") => border(frame.v) + " ".repeat(POPUP_PADDING_X) + fixed(content) + " ".repeat(POPUP_PADDING_X) + border(frame.v);
		const filledRow = (content = "") => border(frame.v) + " ".repeat(POPUP_PADDING_X) + th.bg("toolPendingBg", fixed(content)) + " ".repeat(POPUP_PADDING_X) + border(frame.v);
		const divider = () => row(muted(frame.h.repeat(bodyWidth)));
		const lines: string[] = [];

		lines.push(top("Session Manager", `${this.filtered.length}/${this.sessions.length} shown`));
		for (let i = 0; i < POPUP_PADDING_Y; i++) lines.push(blank());
		lines.push(row(this.renderScopeTabs(bodyWidth)));
		lines.push(row(""));

		if (this.mode === "confirm-delete" || this.mode === "confirm-delete-all") {
			const rowsBeforeConfirmBody = 1 + POPUP_PADDING_Y + 2;
			const rowsAfterConfirmBody = POPUP_PADDING_Y + 1;
			const targetRows = Math.max(10, this.maxPopupRows() - rowsBeforeConfirmBody - rowsAfterConfirmBody);
			lines.push(...this.renderDeleteConfirmationRows(bodyWidth, targetRows, { row, dim, muted, accent, warning, error, border }));
			for (let i = 0; i < POPUP_PADDING_Y; i++) lines.push(blank());
			lines.push(border(`${frame.bl}${frame.h.repeat(frameInner)}${frame.br}`));
			return lines.map((line) => truncateToWidth(line, renderWidth, ""));
		}

		if (this.mode === "confirm-model") {
			const rowsBeforeConfirmBody = 1 + POPUP_PADDING_Y + 2;
			const rowsAfterConfirmBody = POPUP_PADDING_Y + 1;
			const targetRows = Math.max(12, this.maxPopupRows() - rowsBeforeConfirmBody - rowsAfterConfirmBody);
			lines.push(...this.renderModelConfirmationRows(bodyWidth, targetRows, { row, dim, muted, accent, warning }));
			for (let i = 0; i < POPUP_PADDING_Y; i++) lines.push(blank());
			lines.push(border(`${frame.bl}${frame.h.repeat(frameInner)}${frame.br}`));
			return lines.map((line) => truncateToWidth(line, renderWidth, ""));
		}

		lines.push(row(this.renderSubheader(bodyWidth, accent, muted, dim, warning, error)));
		lines.push(filledRow(this.renderSearch(bodyWidth, dim)));
		lines.push(divider());

		if (this.mode === "loading") {
			const progress = this.loadingProgress ? ` ${this.loadingProgress.loaded}/${this.loadingProgress.total}` : "";
			lines.push(row(dim(`Loading sessions${progress}${glyphs().ellipsis}`)));
			for (let i = 1; i < this.visibleRows; i++) lines.push(row(""));
		} else {
			lines.push(...this.renderListRows(bodyWidth, { row, fixed, dim, muted, accent, warning, error }));
		}

		lines.push(divider());
		lines.push(...this.renderDetailRows(bodyWidth, { row, fixed, dim, muted, accent, warning, error, success }));
		lines.push(row(""));
		for (const footerLine of this.renderFooter(bodyWidth, dim, warning, error)) lines.push(row(footerLine));
		for (let i = 0; i < POPUP_PADDING_Y; i++) lines.push(blank());
		lines.push(border(`${frame.bl}${frame.h.repeat(frameInner)}${frame.br}`));
		return lines.map((line) => truncateToWidth(line, renderWidth, ""));
	}

	private renderDeleteConfirmationRows(
		inner: number,
		targetRows: number,
		ui: {
			row: (content?: string) => string;
			dim: (s: string) => string;
			muted: (s: string) => string;
			accent: (s: string) => string;
			warning: (s: string) => string;
			error: (s: string) => string;
			border: (s: string) => string;
		},
	): string[] {
		const deleteAll = this.mode === "confirm-delete-all";
		const target = deleteAll ? undefined : this.deleteTarget;
		const deleteCount = this.deleteAllTargets.length;
		const deleteCountLabel = `${deleteCount} shown ${deleteCount === 1 ? "session" : "sessions"}`;
		const boxWidth = Math.max(1, Math.min(inner, Math.max(32, Math.min(74, inner - 18))));
		const boxInner = Math.max(1, boxWidth - 4);
		const centeredBoxLine = (line: string) => `${" ".repeat(Math.max(0, Math.floor((inner - boxWidth) / 2)))}${line}`;
		const top = () => {
			const label = " Confirm delete ";
			const fill = Math.max(1, boxWidth - 2 - visibleWidth(label));
			return `${ui.error("┏")}${ansiRed(label)}${ui.error("━".repeat(fill))}${ui.error("┓")}`;
		};
		const bottom = () => ui.error(`┗${"━".repeat(Math.max(0, boxWidth - 2))}┛`);
		const boxRow = (content = "") => `${ui.error("┃ ")}${padAnsi(content, boxInner)}${ui.error(" ┃")}`;
		const boxDivider = () => `${ui.error("┃ ")}${ui.muted("─".repeat(boxInner))}${ui.error(" ┃")}`;

		const subject = deleteAll
			? this.scope === "current"
				? shortenPath(this.ctx.cwd)
				: "All paths, all projects"
			: target
				? `“${truncateToWidth(sessionResumeTitle(target), Math.max(8, boxInner - 2), "…")}”`
				: "selected session";
		const removeMessage = deleteAll
			? this.scope === "current"
				? `This removes ${deleteCountLabel} in this project.`
				: `This removes ${deleteCountLabel} across all paths and projects.`
			: "This removes the session file.";
		const extensionDataMessage = deleteAll
			? "Also removes all vstack extension data for these sessions (sub-agent panes, inboxes/outboxes, transcripts, prompt stash, captured outputs)."
			: "Also removes all vstack extension data for this session (sub-agent panes, inboxes/outboxes, transcripts, prompt stash, captured outputs).";
		const optionRow = (index: 0 | 1, label: string) => {
			const selected = this.deleteConfirmSelection === index;
			const prefix = selected ? "› " : "  ";
			const labelText = index === 0 ? ui.error(label) : selected ? this.theme.fg("text", label) : ui.dim(label);
			const content = `${ui.warning(prefix)}${labelText}`;
			const padded = padAnsi(content, boxInner);
			return selected ? this.theme.bg(index === 0 ? "toolErrorBg" : "selectedBg", padded) : padded;
		};

		const wrapPlain = (text: string, width: number): string[] => {
			if (width <= 0) return [text];
			const words = text.split(/\s+/);
			const lines: string[] = [];
			let current = "";
			for (const word of words) {
				const candidate = current ? `${current} ${word}` : word;
				if (visibleWidth(candidate) <= width) {
					current = candidate;
				} else {
					if (current) lines.push(current);
					current = word;
				}
			}
			if (current) lines.push(current);
			return lines.length > 0 ? lines : [""];
		};
		const extensionDataLines = wrapPlain(extensionDataMessage, boxInner).map((line) => boxRow(ui.warning(line)));
		const boxLines = [
			top(),
			boxRow(centerAnsi(ui.error(this.theme.bold(deleteAll ? "Delete all sessions?" : "Delete session?")), boxInner)),
			boxRow(centerAnsi(ui.accent(subject), boxInner)),
			boxRow(""),
			boxRow(ui.warning(removeMessage)),
			...extensionDataLines,
			boxRow(ui.dim("If trash is unavailable, deletion is permanent.")),
			boxDivider(),
			boxRow(optionRow(0, deleteAll ? `Delete ${deleteCountLabel}` : "Delete this session")),
			boxRow(optionRow(1, "Go back to previous screen")),
			bottom(),
		];

		const bodyRows = Math.max(boxLines.length, targetRows);
		const topPad = Math.max(0, Math.floor((bodyRows - boxLines.length) / 2));
		const lines: string[] = [];
		for (let i = 0; i < topPad; i++) lines.push(ui.row(""));
		for (const line of boxLines) lines.push(ui.row(centeredBoxLine(line)));
		while (lines.length < bodyRows) lines.push(ui.row(""));
		return lines;
	}

	private renderModelConfirmationRows(
		inner: number,
		targetRows: number,
		ui: {
			row: (content?: string) => string;
			dim: (s: string) => string;
			muted: (s: string) => string;
			accent: (s: string) => string;
			warning: (s: string) => string;
		},
	): string[] {
		const target = this.modelConfirmTarget;
		const previousModel = target ? sessionModelInfo(target.path) : undefined;
		const activeModel = currentModelInfo(this.ctx);
		const previousLabel = modelLabel(previousModel);
		const activeLabel = modelLabel(activeModel);
		const boxWidth = Math.max(1, Math.min(inner, Math.max(44, Math.min(86, inner - 12))));
		const boxInner = Math.max(1, boxWidth - 4);
		const centeredBoxLine = (line: string) => `${" ".repeat(Math.max(0, Math.floor((inner - boxWidth) / 2)))}${line}`;
		const top = () => {
			const label = " Choose model ";
			const fill = Math.max(1, boxWidth - 2 - visibleWidth(label));
			return `${ui.warning("┏")}${ansiYellow(label)}${ui.warning("━".repeat(fill))}${ui.warning("┓")}`;
		};
		const bottom = () => ui.warning(`┗${"━".repeat(Math.max(0, boxWidth - 2))}┛`);
		const boxRow = (content = "") => `${ui.warning("┃ ")}${padAnsi(content, boxInner)}${ui.warning(" ┃")}`;
		const boxDivider = () => `${ui.warning("┃ ")}${ui.muted("─".repeat(boxInner))}${ui.warning(" ┃")}`;
		const optionRow = (index: 0 | 1, label: string, model: string) => {
			const selected = this.modelConfirmSelection === index;
			const prefix = selected ? "› " : "  ";
			const labelText = selected ? this.theme.fg("text", label) : ui.dim(label);
			const modelText = selected ? ui.warning(model) : ui.muted(model);
			const content = `${ui.warning(prefix)}${labelText}${ui.dim(" — ")}${modelText}`;
			const padded = padAnsi(content, boxInner);
			return selected ? this.theme.bg("selectedBg", padded) : padded;
		};

		const title = target ? truncateToWidth(sessionResumeTitle(target), Math.max(8, boxInner - 2), "…") : "selected session";
		const boxLines = [
			top(),
			boxRow(centerAnsi(ui.warning(this.theme.bold("Model differs from current session")), boxInner)),
			boxRow(centerAnsi(ui.accent(`“${title}”`), boxInner)),
			boxRow(""),
			boxRow(`${ui.dim("Session model: ")}${ui.warning(previousLabel)}`),
			boxRow(`${ui.dim("Current model: ")}${ui.warning(activeLabel)}`),
			boxRow(""),
			boxRow(ui.dim("Previous model resumes exactly as saved.")),
			boxRow(ui.dim("Current model writes a model-change event before resume,")),
			boxRow(ui.dim("so full context transfers and future turns use it.")),
			boxDivider(),
			boxRow(optionRow(0, "Continue with previous model", previousLabel)),
			boxRow(optionRow(1, "Continue with current model", activeLabel)),
			bottom(),
		];

		const bodyRows = Math.max(boxLines.length, targetRows);
		const topPad = Math.max(0, Math.floor((bodyRows - boxLines.length) / 2));
		const lines: string[] = [];
		for (let i = 0; i < topPad; i++) lines.push(ui.row(""));
		for (const line of boxLines) lines.push(ui.row(centeredBoxLine(line)));
		while (lines.length < bodyRows) lines.push(ui.row(""));
		return lines;
	}

	private renderScopeTabs(inner: number): string {
		const tabs: { id: Scope; label: string }[] = [
			{ id: "current", label: "Current" },
			{ id: "all", label: "All" },
		];
		const parts = tabs.map((tab) => {
			const label = ` ${truncateToWidth(tab.label, 18, "…")} `;
			if (tab.id === this.scope) return this.theme.fg("accent", this.theme.inverse(this.theme.bold(label)));
			return this.theme.bg("selectedBg", this.theme.fg("accent", label));
		});
		return truncateToWidth(parts.join(" "), inner, "");
	}

	private renderSubheader(inner: number, accent: (s: string) => string, muted: (s: string) => string, dim: (s: string) => string, warning: (s: string) => string, error: (s: string) => string): string {
		if (this.mode === "confirm-delete" && this.deleteTarget) {
			return error(`Delete “${truncateToWidth(sessionResumeTitle(this.deleteTarget), Math.max(12, inner - 10), "…")}”?`);
		}
		if (this.mode === "confirm-delete-all") {
			return error(`Delete all ${this.deleteAllTargets.length} shown deletable sessions?`);
		}
		if (this.mode === "deleting") return warning("Deleting session…");
		if (this.mode === "rename" && this.renameTarget) return accent(`Rename “${truncateToWidth(sessionResumeTitle(this.renameTarget), Math.max(12, inner - 10), "…")}”`);
		if (this.notice) {
			return this.notice.kind === "error" ? error(this.notice.text) : accent(this.notice.text);
		}
		if (this.queryError) return error(`Search error: ${this.queryError}`);
		return dim("Search supports re:<pattern> regex and \"phrase\" exact matching.");
	}

	private renderSearch(inner: number, dim: (s: string) => string): string {
		if (this.mode === "rename") {
			const prefix = " ";
			const input = this.renameInput.render(Math.max(1, inner - visibleWidth(prefix)))[0] ?? "";
			return prefix + input;
		}
		const prefix = " ";
		const input = this.searchInput.render(Math.max(1, inner - visibleWidth(prefix)))[0] ?? "";
		return prefix + input;
	}

	private renderListRows(
		inner: number,
		ui: {
			row: (content?: string) => string;
			fixed: (content?: string, width?: number) => string;
			dim: (s: string) => string;
			muted: (s: string) => string;
			accent: (s: string) => string;
			warning: (s: string) => string;
			error: (s: string) => string;
		},
	): string[] {
		const lines: string[] = [];
		if (this.filtered.length === 0) {
			const message = this.queryError
				? "  No sessions match because the search query is invalid"
				: this.searchInput.getValue().trim()
					? "  No matching sessions"
					: this.nameFilter === "named"
						? "  No named sessions found"
						: "  No sessions found";
			lines.push(ui.row(ui.dim(message)));
			for (let i = 1; i < this.visibleRows; i++) lines.push(ui.row(""));
			return lines;
		}

		const end = Math.min(this.scrollOffset + this.visibleRows, this.filtered.length);
		for (let i = this.scrollOffset; i < end; i++) {
			const node = this.filtered[i]!;
			lines.push(ui.row(this.renderSessionRow(node, i, inner, ui)));
		}
		for (let i = end - this.scrollOffset; i < this.visibleRows; i++) lines.push(ui.row(""));
		return lines;
	}

	private renderSessionRow(
		node: FlatSessionNode,
		index: number,
		inner: number,
		ui: {
			fixed: (content?: string, width?: number) => string;
			dim: (s: string) => string;
			muted: (s: string) => string;
			accent: (s: string) => string;
			warning: (s: string) => string;
			error: (s: string) => string;
		},
	): string {
		const session = node.session;
		const selected = index === this.selectedIndex;
		const current = this.isCurrent(session);
		const titleRaw = sessionResumeTitle(session);
		const prefix = rowTreePrefix(node);
		const cursor = " ";
		const marker = "";
		const rightParts = [
			`${session.messageCount} msg`,
			formatAge(session.modified),
		].filter(Boolean);
		const rightRaw = rightParts.join(" · ");
		const rightMax = Math.min(ROW_META_MAX_WIDTH, Math.max(14, Math.floor(inner * 0.38)));
		const right = selected ? this.theme.fg("text", truncateToWidth(rightRaw, rightMax, "…")) : ui.dim(truncateToWidth(rightRaw, rightMax, "…"));
		const leftFixed = cursor + ui.dim(prefix) + marker;
		const availableTitle = Math.max(8, inner - visibleWidth(leftFixed) - visibleWidth(right) - 2);
		let title = truncateToWidth(titleRaw, availableTitle, "…");
		if (current) title = this.theme.fg("success", title);
		else if (isNamed(session)) title = ui.accent(title);
		if (selected) title = this.theme.bold(title);
		const left = leftFixed + title;
		const spacing = " ".repeat(Math.max(1, inner - visibleWidth(left) - visibleWidth(right)));
		let line = ui.fixed(left + spacing + right, inner);
		if (selected) line = this.theme.bg("selectedBg", line);
		return line;
	}

	private renderDetailRows(
		inner: number,
		ui: {
			row: (content?: string) => string;
			fixed: (content?: string, width?: number) => string;
			dim: (s: string) => string;
			muted: (s: string) => string;
			accent: (s: string) => string;
			warning: (s: string) => string;
			error: (s: string) => string;
			success: (s: string) => string;
		},
	): string[] {
		const lines: string[] = [];
		const selectedNode = this.filtered[this.selectedIndex];
		const selected = selectedNode?.session;
		const scope = this.scope === "current" ? "current project" : "all sessions";
		const shown = `${this.filtered.length}/${this.sessions.length}`;
		const search = oneLine(this.searchInput.getValue());
		if (!selected) {
			const state = `${shown} shown · ${scope} · ${this.sortMode} sort · ${this.nameFilter === "named" ? "named only" : "all names"}${search ? ` · query “${truncateToWidth(search, 28, "…")}”` : ""}`;
			lines.push(ui.row(ui.dim(state)));
			return lines;
		}

		const locationPrefix = ui.dim("Session CWD: ");
		const location = selected.cwd || selected.path;
		lines.push(ui.row(locationPrefix + ui.muted(truncateToWidth(shortenPath(location), Math.max(10, inner - visibleWidth(locationPrefix)), "…"))));

		const state = `${shown} shown · ${scope} · ${this.sortMode} sort · ${this.nameFilter === "named" ? "named only" : "all names"}${search ? ` · query “${truncateToWidth(search, 28, "…")}”` : ""}`;
		lines.push(ui.row(ui.dim(state)));

		const snippet = oneLine(this.searchInput.getValue()) ? selectedNode?.snippet : undefined;
		if (snippet) {
			const previewPrefix = ui.dim("match   ");
			const preview = truncateToWidth(styleSearchMatches(snippet, this.searchInput.getValue()), Math.max(10, inner - visibleWidth(previewPrefix) - 1), "…");
			lines.push(ui.row(previewPrefix + ui.muted(`“${preview}`)));
		}
		return lines;
	}

	private renderFooter(inner: number, dim: (s: string) => string, warning: (s: string) => string, error: (s: string) => string): string[] {
		if (this.mode === "confirm-delete" || this.mode === "confirm-delete-all" || this.mode === "confirm-model") return [];
		if (this.mode === "rename") return [warning("empty name clears title")];
		return [
			`${ansiYellow("-/=")} ${dim("page · ")}${ansiYellow("enter")} ${dim("resume · ")}${ansiYellow("alt+r")} ${dim("rename")}`,
			`${ansiYellow("tab")} ${dim("scope · ")}${ansiYellow("alt+s")} ${dim("sort · ")}${ansiYellow("alt+n")} ${dim("names · ")}${ansiYellow("del")} ${dim("delete · ")}${ansiYellow("alt+d")} ${dim("delete all")}`,
		];
	}

	invalidate(): void {
		this.searchInput.invalidate();
		this.renameInput.invalidate();
	}
}

export async function openManager(ctx: SessionManagerContext, pi: ExtensionAPI): Promise<SessionAction> {
	const releaseModalLock = acquireVstackModalLock();
	try {
		const result = await ctx.ui.custom<SessionAction | undefined>(
			(tui, theme, keybindings, done) => new SessionManagerOverlay(ctx, pi, theme, keybindings, (action) => done(action), tui),
			{
				overlay: true,
				overlayOptions: {
					anchor: "center",
					width: Math.max(72, Math.floor(settingNumber("overlayWidth", DEFAULT_WIDTH, ctx.cwd))),
					maxHeight: "90%",
					margin: 1,
				},
			},
		);
		return result ?? { type: "cancel" };
	} finally {
		releaseModalLock();
	}
}
