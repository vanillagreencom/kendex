import type { ExtensionAPI, KeybindingsManager, Theme } from "@earendil-works/pi-coding-agent";
import { Input, matchesKey, truncateToWidth, visibleWidth, type Focusable } from "@earendil-works/pi-tui";
import { acquirekendexModalLock, deleteSessionFile, loadSessionsForScope, renameSession } from "./actions.js";
import { currentModelInfo, modelLabel, sameModel, sessionModelInfo } from "./model.js";
import { canonicalPath } from "./paths.js";
import { buildSnippet, matchSessions, parseQuery, RegexTimeoutError, styleSearchMatches } from "./search.js";
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
	type ModelInfo,
	type NameFilter,
	type ParsedQuery,
	type Scope,
	type SessionAction,
	type SessionInfo,
	type SessionManagerContext,
	type SortMode,
} from "./types.js";

/** Typing pause after which a search runs; a keystroke inside it repaints the input alone. */
const SEARCH_DEBOUNCE_MS = 120;
/** Time a search runs before it yields to keystrokes and paint; a slice overruns it by at most one batch. */
const SCAN_SLICE_MS = 12;
/** Sessions matched per call: a regex query pays one deadline watchdog per batch, plus one per session when the batch runs past the deadline. */
const SCAN_BATCH = 8;
/** The notice a session action gets while the list still shows an earlier query's results. */
const SEARCH_PENDING_NOTICE = "Search still running";

function flatNode(session: SessionInfo, score: number): FlatSessionNode {
	return { session, depth: 0, isLast: true, ancestorContinues: [], score };
}

class SessionManagerOverlay implements Focusable {
	private readonly ctx: SessionManagerContext;
	private readonly pi: ExtensionAPI;
	private readonly theme: Theme;
	private readonly keybindings: KeybindingsManager;
	private readonly done: (action: SessionAction) => void;
	private readonly tui: { requestRender(): void; terminal?: { rows?: number } };
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
	private modelConfirm: { session: SessionInfo; previousModel: ModelInfo } | undefined;
	private modelConfirmSelection: 0 | 1 = 0;
	private notice: { kind: "info" | "error"; text: string } | undefined;
	private queryError: string | undefined;
	private loadingProgress: { loaded: number; total: number } | undefined;
	private readonly modelLabelCache = new Map<string, string | undefined>();
	private readonly canonicalPaths = new Map<string, string>();
	private loadSeq = 0;
	private filterSeq = 0;
	private filterTimer: ReturnType<typeof setTimeout> | undefined;
	/** A filter is armed or scanning: `filtered` does not yet match the search input. */
	private searching = false;
	private disposed = false;
	private filterQuery: { text: string; parsed: ParsedQuery } = { text: "", parsed: parseQuery("") };
	private readonly snippets = new Map<FlatSessionNode, string | undefined>();
	private scope: Scope;
	private sortMode: SortMode;
	private nameFilter: NameFilter = "all";
	private currentSessionPath: string | undefined;

	constructor(
		ctx: SessionManagerContext,
		pi: ExtensionAPI,
		theme: Theme,
		keybindings: KeybindingsManager,
		done: (action: SessionAction) => void,
		tui: { requestRender(): void; terminal?: { rows?: number } },
		initialScope?: Scope,
	) {
		this.ctx = ctx;
		this.pi = pi;
		this.theme = theme;
		this.keybindings = keybindings;
		this.done = done;
		this.tui = tui;
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
		const hasMatchSnippet = Boolean(this.snippetFor(selectedNode));
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

	/** A notice for the overlay, or for Pi once the browser has closed, so an outcome that lands after close stays visible. */
	private notify(kind: "info" | "error", text: string): void {
		if (this.disposed) this.ctx.ui.notify(oneLine(text), kind);
		else this.notice = { kind, text: oneLine(text) };
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
			this.modelLabelCache.clear();
			this.canonicalPaths.clear();
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

	/** A path resolved once per load: a row render or a delete filter reads the map, not the disk. */
	private canonical(path: string): string {
		let resolved = this.canonicalPaths.get(path);
		if (resolved === undefined) {
			resolved = canonicalPath(path) ?? path;
			this.canonicalPaths.set(path, resolved);
		}
		return resolved;
	}

	private isCurrent(session: SessionInfo): boolean {
		if (!session.path || !this.currentSessionPath) return false;
		return this.canonical(session.path) === this.canonical(this.currentSessionPath);
	}

	private cancelFilter(): void {
		clearTimeout(this.filterTimer);
		this.filterTimer = undefined;
		this.filterSeq += 1;
	}

	private debounceFilter(): void {
		this.cancelFilter();
		this.searching = true;
		this.filterTimer = setTimeout(() => {
			this.filterTimer = undefined;
			this.applyFilter();
			this.requestRender();
		}, SEARCH_DEBOUNCE_MS);
	}

	private applyFilter(resetSelection = true): void {
		this.cancelFilter();
		if (this.disposed) return;
		const query = this.searchInput.getValue().trim();
		const parsed = parseQuery(query);
		const base = this.nameFilter === "named" ? this.sessions.filter(isNamed) : [...this.sessions];

		if (parsed.error) {
			this.showFiltered([], query, parsed, parsed.error, resetSelection);
		} else if (!query) {
			const nodes = this.sortMode === "threaded"
				? flattenSessionTree(buildSessionTree(base, (path) => this.canonical(path)))
				: base.map((session) => flatNode(session, 0)).sort((a, b) => b.session.modified.getTime() - a.session.modified.getTime());
			this.showFiltered(nodes, query, parsed, undefined, resetSelection);
		} else {
			void this.scanSessions(this.filterSeq, base, query, parsed, resetSelection);
		}
	}

	/**
	 * Match sessions in batches, yielding once a slice has run SCAN_SLICE_MS; a
	 * newer filter or a closed browser bumps `filterSeq` and the scan stops at its
	 * next yield.
	 */
	private async scanSessions(seq: number, base: SessionInfo[], query: string, parsed: ParsedQuery, resetSelection: boolean): Promise<void> {
		this.searching = true;
		const nodes: FlatSessionNode[] = [];
		try {
			for (let index = 0; index < base.length; ) {
				const sliceStart = performance.now();
				do {
					const batch = base.slice(index, index + SCAN_BATCH);
					index += batch.length;
					matchSessions(batch, parsed).forEach((match, i) => {
						if (match.matches) nodes.push(flatNode(batch[i]!, match.score));
					});
				} while (index < base.length && performance.now() - sliceStart < SCAN_SLICE_MS);
				await new Promise<void>((resolve) => setImmediate(resolve));
				if (seq !== this.filterSeq) return;
			}
		} catch (error) {
			if (seq !== this.filterSeq) return;
			if (error instanceof RegexTimeoutError) {
				this.showFiltered([], query, parsed, error.message, resetSelection);
			} else {
				this.showFiltered([], query, parsed, undefined, resetSelection);
				this.notify("error", `Search failed: ${error instanceof Error ? error.message : String(error)}`);
			}
			this.requestRender();
			return;
		}
		nodes.sort((a, b) => {
			if (this.sortMode === "recent") return b.session.modified.getTime() - a.session.modified.getTime();
			return a.score - b.score || b.session.modified.getTime() - a.session.modified.getTime();
		});
		this.showFiltered(nodes, query, parsed, undefined, resetSelection);
		this.requestRender();
	}

	private showFiltered(nodes: FlatSessionNode[], query: string, parsed: ParsedQuery, queryError: string | undefined, resetSelection: boolean): void {
		this.filtered = this.nameFilter === "named" ? nodes.filter((node) => isNamed(node.session)) : nodes;
		this.filterQuery = { text: query, parsed };
		this.queryError = queryError;
		this.snippets.clear();
		this.searching = false;
		if (this.notice?.text === SEARCH_PENDING_NOTICE) this.notice = undefined;
		if (resetSelection) {
			this.selectedIndex = 0;
			this.scrollOffset = 0;
		}
		this.syncSelection();
	}

	/** The match preview, built only for a row the detail pane shows. */
	private snippetFor(node: FlatSessionNode | undefined): string | undefined {
		if (!node || !this.filterQuery.text) return undefined;
		if (this.snippets.has(node)) return this.snippets.get(node);
		let snippet: string | undefined;
		try {
			snippet = buildSnippet(node.session, this.filterQuery.parsed);
		} catch (error) {
			// The scan matched this session within the same deadline; a rerun
			// that runs past it costs the preview alone.
			if (!(error instanceof RegexTimeoutError)) throw error;
		}
		this.snippets.set(node, snippet);
		return snippet;
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

	/** True, with a notice, while `filtered` still holds an earlier query's results and a session action would read them. */
	private refuseWhileSearching(): boolean {
		if (!this.searching) return false;
		this.notify("info", SEARCH_PENDING_NOTICE);
		this.requestRender();
		return true;
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
		this.modelConfirm = undefined;
		this.modelConfirmSelection = 0;
	}

	private resumeAction(session: SessionInfo, keepCurrentModel = false): SessionAction {
		return { type: "resume", path: session.path, title: sessionResumeTitle(session), keepCurrentModel };
	}

	private startResume(session: SessionInfo): void {
		const previousModel = sessionModelInfo(session.path);
		const activeModel = currentModelInfo(this.ctx);
		if (previousModel && activeModel && !sameModel(previousModel, activeModel)) {
			this.modelConfirm = { session, previousModel };
			this.modelConfirmSelection = 0;
			this.mode = "confirm-model";
			this.notice = undefined;
			this.requestRender();
			return;
		}
		this.done(this.resumeAction(session, false));
	}

	private sessionModelLabel(session: SessionInfo): string | undefined {
		if (this.modelLabelCache.has(session.path)) return this.modelLabelCache.get(session.path);
		const model = sessionModelInfo(session.path);
		const label = model ? modelLabel(model) : undefined;
		this.modelLabelCache.set(session.path, label);
		return label;
	}

	private confirmModelResume(): void {
		const target = this.modelConfirm?.session;
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
			const deleted = this.canonical(target.path);
			this.sessions = this.sessions.filter((session) => this.canonical(session.path) !== deleted);
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
			const key = this.canonical(session.path);
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
		const deletedPaths = new Set<string>();
		const failures: string[] = [];
		let unattempted = 0;
		for (const [index, target] of targets.entries()) {
			// A closed browser stops the run; the deletes already made stand.
			if (this.disposed) {
				unattempted = targets.length - index;
				break;
			}
			if (this.isCurrent(target)) continue;
			const result = await deleteSessionFile(target.path, this.ctx.cwd, target.id);
			if (result.ok) {
				deleted += 1;
				if (result.method === "trash") trashed += 1;
				deletedPaths.add(this.canonical(target.path));
			} else {
				failures.push(`${sessionResumeTitle(target)}: ${result.error ?? "unknown error"}`);
			}
		}
		this.sessions = this.sessions.filter((session) => !deletedPaths.has(this.canonical(session.path)));
		this.mode = "browse";
		this.deleteAllTargets = [];
		const stopped = unattempted > 0 ? `; ${unattempted} not attempted after the browser closed` : "";
		if (failures.length > 0) {
			this.notify("error", `Deleted ${deleted}; failed ${failures.length}${stopped}: ${failures[0]}`);
		} else if (stopped) {
			this.notify("error", `Deleted ${deleted}${stopped}`);
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
			if (this.refuseWhileSearching()) return;
			const selected = this.selected();
			if (selected) this.startRename(selected);
			this.requestRender();
			return;
		}

		if (matchesKey(data, "alt+d")) {
			if (this.refuseWhileSearching()) return;
			this.startDeleteAll();
			this.requestRender();
			return;
		}

		if (matchesKey(data, "delete")) {
			if (this.refuseWhileSearching()) return;
			const selected = this.selected();
			if (selected) this.startDelete(selected);
			this.requestRender();
			return;
		}

		if (this.keybindings.matches(data, "tui.select.confirm")) {
			if (this.refuseWhileSearching()) return;
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
		this.debounceFilter();
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
			? "Also removes all kendex extension data for these sessions (sub-agent panes, inboxes/outboxes, transcripts, prompt stash, captured outputs)."
			: "Also removes all kendex extension data for this session (sub-agent panes, inboxes/outboxes, transcripts, prompt stash, captured outputs).";
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
		const target = this.modelConfirm?.session;
		const previousModel = this.modelConfirm?.previousModel;
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
		if (this.searching) return dim(`Searching${glyphs().ellipsis}`);
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
		const location = shortenPath(selected.cwd || selected.path);
		const model = this.sessionModelLabel(selected);
		if (model) {
			const separator = ui.dim(" · ");
			const modelBudget = Math.max(8, Math.min(44, Math.floor(inner * 0.4), inner - visibleWidth(locationPrefix) - visibleWidth(separator) - 10));
			const modelText = truncateToWidth(model, modelBudget, "…");
			const locationBudget = Math.max(10, inner - visibleWidth(locationPrefix) - visibleWidth(separator) - visibleWidth(modelText));
			lines.push(ui.row(locationPrefix + ui.muted(truncateToWidth(location, locationBudget, "…")) + separator + ui.muted(modelText)));
		} else {
			lines.push(ui.row(locationPrefix + ui.muted(truncateToWidth(location, Math.max(10, inner - visibleWidth(locationPrefix)), "…"))));
		}

		const state = `${shown} shown · ${scope} · ${this.sortMode} sort · ${this.nameFilter === "named" ? "named only" : "all names"}${search ? ` · query “${truncateToWidth(search, 28, "…")}”` : ""}`;
		lines.push(ui.row(ui.dim(state)));

		const snippet = this.snippetFor(selectedNode);
		if (snippet) {
			const previewPrefix = ui.dim("match   ");
			const preview = truncateToWidth(styleSearchMatches(snippet, this.filterQuery.text), Math.max(10, inner - visibleWidth(previewPrefix) - 1), "…");
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

	/**
	 * Pi calls this when the browser closes: stop pending work and release the
	 * prompt text the search read. A delete still in flight finishes its current
	 * file, starts no new scan, and reports through Pi.
	 */
	dispose(): void {
		this.disposed = true;
		this.loadSeq += 1;
		this.cancelFilter();
		sessionUserMessagesCache.clear();
	}
}

export async function openManager(ctx: SessionManagerContext, pi: ExtensionAPI): Promise<SessionAction> {
	const releaseModalLock = acquirekendexModalLock();
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
