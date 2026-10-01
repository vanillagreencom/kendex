import type { Theme } from "@earendil-works/pi-coding-agent";
import { matchesKey, truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";
import { ansiGreen, ansiRed, ansiYellow } from "../ansi.js";
import { SESSION_SEARCH_OVERLAY_HEIGHT_RATIO } from "../constants.js";
import { settingNumber } from "../settings.js";
import {
	defaultSessionSearchScope,
	canonicalPathForSessionSearch,
	prepareQolSessionSearchSessions,
	modelLabel,
	sameModel,
	sessionModelInfo,
	sessionResumeTitle,
	shortPathForUi,
	userMessagesForResult,
	sessionUserMessageForAction,
	type QolModelInfo,
} from "./cache.js";
import {
	formatSessionSearchDate,
	parseSessionSearchQuery,
	promptRecencyTime,
	searchQolSessionHits,
} from "./search.js";
import type {
	QolSessionActionState,
	QolSessionConfirmModelState,
	QolSessionContextConfirmState,
	QolSessionForkConfirmState,
	QolSessionMessagesState,
	QolSessionPaletteAction,
	QolSessionSearchHit,
	QolSessionSearchLoad,
	QolSessionSearchResult,
	QolSessionSearchScope,
	QolSessionSearchSession,
	QolSessionSearchState,
	QolSessionUserMessage,
} from "./types.js";

import { escapeRegex } from "../util.js";

export function wrapVisible(text: string, width: number, maxLines: number): string[] {
	const wrapped = wrapTextWithAnsi(text, width);
	if (wrapped.length <= maxLines) return wrapped;
	const head = wrapped.slice(0, Math.max(0, maxLines - 1));
	const tail = wrapped.slice(Math.max(0, maxLines - 1)).join(" ");
	return [...head, truncateToWidth(tail, width, "…")];
}

export function styleSessionSnippet(snippet: string, query: string, _theme: Theme): string {
	let styled = snippet;
	const parsed = parseSessionSearchQuery(query);
	if (parsed.mode === "tokens") {
		for (const token of parsed.tokens) {
			const value = token.value.trim();
			if (!value || value.length > 80) continue;
			try {
				styled = styled.replace(new RegExp(escapeRegex(value), "gi"), (match) => ansiRed(match));
			} catch {
				// Ignore highlighting failures; search result remains readable.
			}
		}
	}
	return styled;
}

export function boxParts(width: number, theme: Theme) {
	const safeWidth = Math.max(24, width);
	const paddingX = 2;
	const frameInner = Math.max(10, safeWidth - 2);
	const inner = Math.max(1, frameInner - paddingX * 2);
	const border = (s: string) => theme.fg("borderAccent", s);
	const fixed = (content = "", rowWidth = inner) => {
		// A single accidental newline in a session name/prompt can tear the box apart.
		// Preserve ANSI styling, but collapse hard line breaks before measuring.
		const safeContent = content.replace(/[\r\n\t]+/g, " ");
		const clipped = truncateToWidth(safeContent, rowWidth, "");
		return clipped + " ".repeat(Math.max(0, rowWidth - visibleWidth(clipped)));
	};
	const row = (content = "", selected = false) => {
		const body = fixed(content);
		return `${border("┃")}${" ".repeat(paddingX)}${selected ? theme.bg("selectedBg", body) : body}${" ".repeat(paddingX)}${border("┃")}`;
	};
	const filledRow = (content = "", bg: "selectedBg" | "toolPendingBg" = "toolPendingBg") => {
		const body = fixed(content);
		return `${border("┃")}${" ".repeat(paddingX)}${theme.bg(bg, body)}${" ".repeat(paddingX)}${border("┃")}`;
	};
	const selectedRow = (content = "") => row(content, true);
	const empty = () => `${border("┃")}${" ".repeat(frameInner)}${border("┃")}`;
	const divider = () => row(theme.fg("borderMuted", "━".repeat(inner)));
	const top = (label = "", right = "") => {
		if (!label) return border(`┏${"━".repeat(frameInner)}┓`);
		const rightPlain = right ? ` ${right} ` : "";
		const titleBudget = Math.max(1, frameInner - visibleWidth(rightPlain) - 1);
		const titlePlain = ` ${truncateToWidth(label, Math.max(1, titleBudget - 2), "…")} `;
		const fill = Math.max(1, frameInner - visibleWidth(titlePlain) - visibleWidth(rightPlain));
		const rightText = right ? theme.fg("dim", rightPlain) : "";
		return `${border("┏")}${ansiGreen(titlePlain)}${border("━".repeat(fill))}${rightText}${border("┓")}`;
	};
	const bottom = () => border(`┗${"━".repeat(frameInner)}┛`);
	return { bottom, divider, empty, filledRow, inner, row, selectedRow, top };
}

function isPrintableInput(data: string): boolean {
	return data.length >= 1 && data.charCodeAt(0) >= 32 && !data.startsWith("\x1b") && data !== "\x7f";
}

export class QolSessionSearchComponent {
	private readonly done: (action: QolSessionPaletteAction) => void;
	private readonly tui: { requestRender(): void; terminal?: { rows?: number } };
	private readonly theme: Theme;
	/** The index, while it loads, once loaded, or the load's failure. */
	private sessions: QolSessionSearchLoad;
	private readonly cwd: string;
	private readonly currentModel: QolModelInfo | undefined;
	private screen: "search" | "messages" | "actions" | "confirmContext" | "confirmFork" | "confirmModel" = "search";
	private searchState: QolSessionSearchState;
	private messagesState: QolSessionMessagesState | undefined;
	private actionState: QolSessionActionState | undefined;
	private actionReturnScreen: "search" | "messages" = "messages";
	private contextConfirmState: QolSessionContextConfirmState | undefined;
	private forkConfirmState: QolSessionForkConfirmState | undefined;
	private confirmModelState: QolSessionConfirmModelState | undefined;
	private readonly indexController = new AbortController();
	private queryController: AbortController | undefined;
	private debounceTimer: ReturnType<typeof setTimeout> | undefined;
	private currentSessions: QolSessionSearchSession[] = [];
	private searchStatus: { status: "searching" | "action" } | { status: "ready" } | { status: "failed"; error: string } = { status: "ready" };


	constructor(
		done: (action: QolSessionPaletteAction) => void,
		tui: { requestRender(): void; terminal?: { rows?: number } },
		theme: Theme,
		sessions: QolSessionSearchLoad,
		cwd: string,
		initialQuery = "",
		currentModel: QolModelInfo | undefined = undefined,
	) {
		this.done = async (action) => {
			try {
				if (action.type === "copy" || action.type === "fork") {
					this.screen = "search";
					this.searchStatus = { status: "action" };
					this.tui.requestRender();
					action = { ...action, message: await sessionUserMessageForAction(action.result!, action.message, this.indexController.signal) };
				}
				if (this.indexController.signal.aborted) return;
				this.dispose(); done(action);
			} catch (error) {
				if (this.indexController.signal.aborted) return;
				this.searchStatus = { status: "failed", error: `${action.type === "copy" ? "Copy" : "Fork"} failed: ${String(error)}` };
				this.tui.requestRender();
			}
		};
		this.tui = tui;
		this.theme = theme;
		this.sessions = sessions;
		this.cwd = cwd;
		this.currentModel = currentModel;
		const query = initialQuery.trim();
		const scope = defaultSessionSearchScope(cwd);
		this.searchState = {
			cursor: query.length,
			query,
			results: [],
			selected: 0,
			scope,
			total: 0,
		};
		if (sessions.status === "ready") this.setSessions(sessions);
	}

	invalidate(): void {}

	/** Pi disposes a completed custom overlay. Late loads cannot redraw it. */
	dispose(): void {
		this.indexController.abort();
		this.queryController?.abort();
		if (this.debounceTimer) clearTimeout(this.debounceTimer);
		this.debounceTimer = undefined;
		this.currentSessions = [];
		this.sessions = { status: "loading" };
		this.searchState.results = [];
	}

	/** Show the index once its load settles; the overlay opens before that. */
	setSessions(sessions: QolSessionSearchLoad): void {
		const signal = this.indexController.signal;
		if (signal.aborted) return;
		if (sessions.status !== "ready") {
			this.sessions = sessions;
			this.tui.requestRender();
			return;
		}
		this.sessions = { status: "loading" };
		void Promise.all([
			prepareQolSessionSearchSessions(sessions.sessions, signal),
			canonicalPathForSessionSearch(this.cwd),
		]).then(([prepared, cwd]) => {
			if (signal.aborted) return;
			this.sessions = { status: "ready", sessions: prepared };
			this.currentSessions = prepared.filter((session) => session.canonicalCwd === cwd);
			this.updateResults(false);
		}, (error: unknown) => {
			if (signal.aborted) return;
			this.sessions = { status: "failed", error: String(error) };
			this.tui.requestRender();
		});
	}

	private maxOverlayRows(): number {
		const terminalRows = Number(this.tui.terminal?.rows ?? process.stdout.rows ?? 30);
		const safeRows = Number.isFinite(terminalRows) && terminalRows > 0 ? terminalRows : 30;
		return Math.max(9, Math.floor(safeRows * SESSION_SEARCH_OVERLAY_HEIGHT_RATIO));
	}

	private compactSearchLayout(): boolean {
		return this.maxOverlayRows() < 18;
	}

	private searchMaxVisibleRows(): number {
		const configured = Math.max(1, Math.floor(settingNumber("sessionSearch.maxVisible", 8, this.cwd)));
		// Each hit is two rows plus a separator between hits. Chrome is aggressively
		// reduced on short terminals so the popup can shrink to one visible hit.
		const chromeRows = this.compactSearchLayout() ? 7 : 11;
		const responsive = Math.max(1, Math.floor((this.maxOverlayRows() - chromeRows) / 3));
		return Math.max(1, Math.min(configured, responsive));
	}

	private messageMaxVisibleRows(): number {
		const configured = Math.max(1, Math.floor(settingNumber("sessionSearch.messageMaxVisible", 12, this.cwd)));
		// Message rows are one line each; reserve space for session metadata,
		// optional scroll status, footer, and frame.
		const responsive = Math.max(1, this.maxOverlayRows() - 14);
		return Math.max(1, Math.min(configured, responsive));
	}

	private forkConfirmMaxVisibleRows(): number {
		const configured = Math.max(1, Math.floor(settingNumber("sessionSearch.messageMaxVisible", 12, this.cwd)));
		const responsive = Math.max(1, this.maxOverlayRows() - 13);
		return Math.max(1, Math.min(configured, responsive));
	}

	render(width: number): string[] {
		const configured = Math.max(70, Math.floor(settingNumber("sessionSearch.overlayWidth", 104, this.cwd)));
		const renderWidth = Math.min(Math.max(48, width), configured);
		if (this.screen === "messages" && this.messagesState) return this.renderMessages(renderWidth, this.messagesState);
		if (this.screen === "actions" && this.actionState) return this.renderActions(renderWidth, this.actionState);
		if (this.screen === "confirmContext" && this.contextConfirmState) return this.renderContextConfirm(renderWidth, this.contextConfirmState);
		if (this.screen === "confirmFork" && this.forkConfirmState) return this.renderForkConfirm(renderWidth, this.forkConfirmState);
		if (this.screen === "confirmModel" && this.confirmModelState) return this.renderConfirmModel(renderWidth, this.confirmModelState);
		return this.renderSearch(renderWidth);
	}

	handleInput(data: string): void {
		if (this.searchStatus.status === "action") return matchesKey(data, "escape") ? this.done({ type: "cancel" }) : undefined;
		if (this.screen === "messages" && this.messagesState) this.handleMessagesInput(data);
		else if (this.screen === "actions" && this.actionState) this.handleActionInput(data);
		else if (this.screen === "confirmContext" && this.contextConfirmState) this.handleContextConfirmInput(data);
		else if (this.screen === "confirmFork" && this.forkConfirmState) this.handleForkConfirmInput(data);
		else if (this.screen === "confirmModel" && this.confirmModelState) this.handleConfirmModelInput(data);
		else {
			this.screen = "search";
			this.handleSearchInput(data);
		}
		this.tui.requestRender();
	}

	private clampSelection(): void {
		this.searchState.selected = Math.max(0, Math.min(this.searchState.selected, Math.max(0, this.searchState.results.length - 1)));
	}

	private sessionsForScope(scope = this.searchState.scope): QolSessionSearchSession[] {
		if (this.sessions.status !== "ready") return [];
		if (scope === "all") return this.sessions.sessions;
		return this.currentSessions;
	}

	private updateResults(resetSelection = true): void {
		if (this.debounceTimer) clearTimeout(this.debounceTimer);
		this.debounceTimer = undefined;
		this.queryController?.abort();
		if (this.indexController.signal.aborted || this.sessions.status !== "ready") return;
		const controller = new AbortController();
		this.queryController = controller;
		const state = this.searchState;
		const scopedSessions = this.sessionsForScope(state.scope);
		state.results = [];
		this.searchStatus = { status: "searching" };
		state.total = scopedSessions.length;
		if (resetSelection) state.selected = 0;
		void searchQolSessionHits(scopedSessions, state.query, this.cwd, controller.signal).then((results) => {
			if (controller.signal.aborted || this.indexController.signal.aborted) return;
			state.results = results;
			this.searchStatus = { status: "ready" };
			this.clampSelection();
			this.tui.requestRender();
		}, (error: unknown) => {
			if (controller.signal.aborted || this.indexController.signal.aborted) return;
			this.searchStatus = { status: "failed", error: String(error) };
			this.tui.requestRender();
		});
	}

	private toggleScope(): void {
		this.searchState.scope = this.searchState.scope === "current" ? "all" : "current";
		this.updateResults(true);
	}

	private updateQuery(query: string, cursor: number): void {
		this.searchState.query = query;
		this.searchState.cursor = Math.max(0, Math.min(cursor, query.length));
		this.queryController?.abort();
		this.searchState.results = [];
		this.searchStatus = { status: "searching" };
		if (this.debounceTimer) clearTimeout(this.debounceTimer);
		this.debounceTimer = setTimeout(() => this.updateResults(true), 20);
	}

	private selectedMessageIndex(messages: QolSessionUserMessage[], query: string): number {
		const trimmed = query.trim().toLowerCase();
		if (trimmed) {
			const firstToken = trimmed.replace(/^re:/, "").replace(/["']/g, "").split(/\s+/).find(Boolean);
			if (firstToken) {
				const found = messages.findIndex((message) => message.text.toLowerCase().includes(firstToken));
				if (found >= 0) return found;
			}
		}
		return Math.max(0, messages.length - 1);
	}

	private openMessages(result: QolSessionSearchResult, preferredMessage?: QolSessionUserMessage): void {
		const messages = userMessagesForResult(result);
		const preferredIndex = preferredMessage
			? messages.findIndex((message) => message.index === preferredMessage.index || (message.entryId && message.entryId === preferredMessage.entryId))
			: -1;
		this.messagesState = {
			messages,
			result,
			selected: preferredIndex >= 0 ? preferredIndex : this.selectedMessageIndex(messages, this.searchState.query),
		};
		this.screen = "messages";
	}

	private selectedFocusText(message: QolSessionUserMessage): string {
		return `Focus on prompt #${message.index}: ${message.text}`;
	}

	private openContextConfirm(type: "summarize" | "newSession", result: QolSessionSearchResult, message: QolSessionUserMessage, returnScreen: "search" | "messages" | "actions"): void {
		this.contextConfirmState = { message, result, returnScreen, type };
		this.screen = "confirmContext";
	}

	private returnFromContextConfirm(state: QolSessionContextConfirmState): void {
		this.contextConfirmState = undefined;
		if (state.returnScreen === "actions" && this.actionState) this.screen = "actions";
		else if (state.returnScreen === "messages" && this.messagesState) this.screen = "messages";
		else this.screen = "search";
	}

	private confirmContextAction(state: QolSessionContextConfirmState): void {
		this.done({ customPrompt: this.selectedFocusText(state.message), message: state.message, result: state.result, type: state.type });
	}

	private openForkConfirm(result: QolSessionSearchResult, message: QolSessionUserMessage, returnScreen: "search" | "messages" | "actions"): void {
		const messages = userMessagesForResult(result);
		const preferredIndex = messages.findIndex((candidate) => candidate.index === message.index || (message.entryId && candidate.entryId === message.entryId));
		this.forkConfirmState = {
			messages,
			result,
			returnScreen,
			selected: preferredIndex >= 0 ? preferredIndex : 0,
		};
		this.screen = "confirmFork";
	}

	private returnFromForkConfirm(state: QolSessionForkConfirmState): void {
		this.forkConfirmState = undefined;
		if (state.returnScreen === "actions" && this.actionState) this.screen = "actions";
		else if (state.returnScreen === "messages" && this.messagesState) this.screen = "messages";
		else this.screen = "search";
	}

	private confirmForkAction(state: QolSessionForkConfirmState): void {
		const message = state.messages[state.selected];
		if (!message) return;
		this.done({ message, result: state.result, type: "fork" });
	}

	private startResume(result: QolSessionSearchResult, returnScreen: "search" | "messages" | "actions"): void {
		const previousModel = sessionModelInfo(result.path);
		const current = this.currentModel;
		if (previousModel && current && !sameModel(previousModel, current)) {
			this.confirmModelState = { result, returnScreen, selected: 0, previousModel, currentModel: current };
			this.screen = "confirmModel";
			return;
		}
		this.done({ result, type: "resume" });
	}

	private returnFromConfirmModel(state: QolSessionConfirmModelState): void {
		this.confirmModelState = undefined;
		if (state.returnScreen === "actions" && this.actionState) this.screen = "actions";
		else if (state.returnScreen === "messages" && this.messagesState) this.screen = "messages";
		else this.screen = "search";
	}

	private confirmModelAction(state: QolSessionConfirmModelState): void {
		this.done({ keepCurrentModel: state.selected === 1, result: state.result, type: "resume" });
	}

	private returnFromActions(): void {
		this.actionState = undefined;
		if (this.actionReturnScreen === "messages" && this.messagesState) this.screen = "messages";
		else this.screen = "search";
	}

	private handleSearchInput(data: string): void {
		const state = this.searchState;
		if (matchesKey(data, "escape")) {
			this.done({ type: "cancel" });
			return;
		}
		if (matchesKey(data, "tab")) {
			this.toggleScope();
			return;
		}
		if (matchesKey(data, "return") || matchesKey(data, "enter")) {
			const hit = state.results[state.selected];
			if (!hit) return;
			this.openMessages(hit.result, hit.message);
			return;
		}
		if (matchesKey(data, "alt+c")) {
			const hit = state.results[state.selected];
			if (hit) this.done({ message: hit.message, result: hit.result, type: "copy" });
			return;
		}
		if (matchesKey(data, "alt+f")) {
			const hit = state.results[state.selected];
			if (hit) this.openForkConfirm(hit.result, hit.message, "search");
			return;
		}
		if (matchesKey(data, "alt+r")) {
			const hit = state.results[state.selected];
			if (hit) this.startResume(hit.result, "search");
			return;
		}
		if (matchesKey(data, "alt+i")) {
			const hit = state.results[state.selected];
			if (hit) this.openContextConfirm("summarize", hit.result, hit.message, "search");
			return;
		}
		if (matchesKey(data, "alt+n")) {
			const hit = state.results[state.selected];
			if (hit) this.openContextConfirm("newSession", hit.result, hit.message, "search");
			return;
		}
		if (matchesKey(data, "alt+a")) {
			const hit = state.results[state.selected];
			if (hit) {
				this.actionState = { message: hit.message, result: hit.result };
				this.actionReturnScreen = "search";
				this.screen = "actions";
			}
			return;
		}
		if (matchesKey(data, "up")) {
			state.selected = Math.max(0, state.selected - 1);
			return;
		}
		if (matchesKey(data, "down")) {
			state.selected = Math.min(Math.max(0, state.results.length - 1), state.selected + 1);
			return;
		}
		if (matchesKey(data, "-") || matchesKey(data, "pageup")) {
			state.selected = Math.max(0, state.selected - this.searchMaxVisibleRows());
			return;
		}
		if (matchesKey(data, "=") || matchesKey(data, "pagedown")) {
			state.selected = Math.min(Math.max(0, state.results.length - 1), state.selected + this.searchMaxVisibleRows());
			return;
		}
		if (matchesKey(data, "left")) {
			state.cursor = Math.max(0, state.cursor - 1);
			return;
		}
		if (matchesKey(data, "right")) {
			state.cursor = Math.min(state.query.length, state.cursor + 1);
			return;
		}
		if (matchesKey(data, "home") || matchesKey(data, "ctrl+a")) {
			state.cursor = 0;
			return;
		}
		if (matchesKey(data, "end") || matchesKey(data, "ctrl+e")) {
			state.cursor = state.query.length;
			return;
		}
		if (matchesKey(data, "ctrl+u")) {
			this.updateQuery("", 0);
			return;
		}
		if (matchesKey(data, "ctrl+w") || matchesKey(data, "alt+backspace")) {
			const before = state.query.slice(0, state.cursor);
			const after = state.query.slice(state.cursor);
			let i = before.length;
			while (i > 0 && /\s/.test(before[i - 1]!)) i -= 1;
			while (i > 0 && !/\s/.test(before[i - 1]!)) i -= 1;
			this.updateQuery(`${before.slice(0, i)}${after}`, i);
			return;
		}
		if (matchesKey(data, "backspace")) {
			if (state.cursor > 0) this.updateQuery(`${state.query.slice(0, state.cursor - 1)}${state.query.slice(state.cursor)}`, state.cursor - 1);
			return;
		}
		if (matchesKey(data, "delete")) {
			if (state.cursor < state.query.length) this.updateQuery(`${state.query.slice(0, state.cursor)}${state.query.slice(state.cursor + 1)}`, state.cursor);
			return;
		}
		if (isPrintableInput(data)) this.updateQuery(`${state.query.slice(0, state.cursor)}${data}${state.query.slice(state.cursor)}`, state.cursor + data.length);
	}

	private handleMessagesInput(data: string): void {
		const state = this.messagesState;
		if (!state) return;
		if (matchesKey(data, "escape") || matchesKey(data, "backspace")) {
			this.screen = "search";
			return;
		}
		if (matchesKey(data, "return") || matchesKey(data, "enter")) {
			const message = state.messages[state.selected];
			if (!message) return;
			this.actionState = { message, result: state.result };
			this.actionReturnScreen = "messages";
			this.screen = "actions";
			return;
		}
		if (matchesKey(data, "alt+r")) {
			this.startResume(state.result, "messages");
			return;
		}
		if (matchesKey(data, "alt+c")) {
			const message = state.messages[state.selected];
			if (message) this.done({ message, result: state.result, type: "copy" });
			return;
		}
		if (matchesKey(data, "alt+f")) {
			const message = state.messages[state.selected];
			if (message) this.openForkConfirm(state.result, message, "messages");
			return;
		}
		if (matchesKey(data, "alt+i")) {
			const message = state.messages[state.selected];
			if (message) this.openContextConfirm("summarize", state.result, message, "messages");
			return;
		}
		if (matchesKey(data, "alt+n")) {
			const message = state.messages[state.selected];
			if (message) this.openContextConfirm("newSession", state.result, message, "messages");
			return;
		}
		if (matchesKey(data, "up")) {
			state.selected = Math.max(0, state.selected - 1);
			return;
		}
		if (matchesKey(data, "down")) {
			state.selected = Math.min(state.messages.length - 1, state.selected + 1);
			return;
		}
		if (matchesKey(data, "-") || matchesKey(data, "pageup")) {
			state.selected = Math.max(0, state.selected - this.messageMaxVisibleRows());
			return;
		}
		if (matchesKey(data, "=") || matchesKey(data, "pagedown")) {
			state.selected = Math.min(state.messages.length - 1, state.selected + this.messageMaxVisibleRows());
			return;
		}
		if (matchesKey(data, "home") || matchesKey(data, "ctrl+a")) {
			state.selected = 0;
			return;
		}
		if (matchesKey(data, "end") || matchesKey(data, "ctrl+e")) {
			state.selected = Math.max(0, state.messages.length - 1);
		}
	}

	private handleActionInput(data: string): void {
		const state = this.actionState;
		if (!state) return;
		if (matchesKey(data, "escape") || matchesKey(data, "backspace")) {
			this.returnFromActions();
			return;
		}
		if (matchesKey(data, "alt+c")) {
			this.done({ message: state.message, result: state.result, type: "copy" });
			return;
		}
		if (matchesKey(data, "alt+f")) {
			this.openForkConfirm(state.result, state.message, "actions");
			return;
		}
		if (matchesKey(data, "alt+r")) {
			this.startResume(state.result, "actions");
			return;
		}
		if (matchesKey(data, "alt+i")) {
			this.openContextConfirm("summarize", state.result, state.message, "actions");
			return;
		}
		if (matchesKey(data, "alt+n")) {
			this.openContextConfirm("newSession", state.result, state.message, "actions");
			return;
		}
	}

	private handleContextConfirmInput(data: string): void {
		const state = this.contextConfirmState;
		if (!state) return;
		if (matchesKey(data, "escape") || matchesKey(data, "backspace")) {
			this.returnFromContextConfirm(state);
			return;
		}
		if (matchesKey(data, "return") || matchesKey(data, "enter")) {
			this.confirmContextAction(state);
		}
	}

	private handleConfirmModelInput(data: string): void {
		const state = this.confirmModelState;
		if (!state) return;
		if (matchesKey(data, "escape") || matchesKey(data, "backspace")) {
			this.returnFromConfirmModel(state);
			return;
		}
		if (matchesKey(data, "up") || matchesKey(data, "down")) {
			state.selected = state.selected === 0 ? 1 : 0;
			return;
		}
		if (matchesKey(data, "return") || matchesKey(data, "enter")) {
			this.confirmModelAction(state);
		}
	}

	private handleForkConfirmInput(data: string): void {
		const state = this.forkConfirmState;
		if (!state) return;
		if (matchesKey(data, "escape") || matchesKey(data, "backspace")) {
			this.returnFromForkConfirm(state);
			return;
		}
		if (matchesKey(data, "return") || matchesKey(data, "enter")) {
			this.confirmForkAction(state);
			return;
		}
		if (matchesKey(data, "up")) {
			state.selected = Math.max(0, state.selected - 1);
			return;
		}
		if (matchesKey(data, "down")) {
			state.selected = Math.min(Math.max(0, state.messages.length - 1), state.selected + 1);
			return;
		}
		if (matchesKey(data, "-") || matchesKey(data, "pageup")) {
			state.selected = Math.max(0, state.selected - this.forkConfirmMaxVisibleRows());
			return;
		}
		if (matchesKey(data, "=") || matchesKey(data, "pagedown")) {
			state.selected = Math.min(Math.max(0, state.messages.length - 1), state.selected + this.forkConfirmMaxVisibleRows());
			return;
		}
		if (matchesKey(data, "home") || matchesKey(data, "ctrl+a")) {
			state.selected = 0;
			return;
		}
		if (matchesKey(data, "end") || matchesKey(data, "ctrl+e")) {
			state.selected = Math.max(0, state.messages.length - 1);
		}
	}

	private renderSearch(width: number): string[] {
		const { bottom, divider, empty, filledRow, inner, row, top } = boxParts(width, this.theme);
		const state = this.searchState;
		const compact = this.compactSearchLayout();
		const lines: string[] = [top("Session Search", `${state.results.length} hits`), empty()];
		const accent = (s: string) => this.theme.fg("accent", s);
		const dim = (s: string) => this.theme.fg("dim", s);
		const muted = (s: string) => this.theme.fg("muted", s);
		const cursorChar = state.query[state.cursor] ?? " ";
		const queryDisplay = `${state.query.slice(0, state.cursor)}${this.theme.inverse(cursorChar)}${state.query.slice(state.cursor + (state.cursor < state.query.length ? 1 : 0))}`;
		lines.push(row(this.renderScopeTabs(inner)));
		if (!compact) lines.push(empty());
		lines.push(filledRow(` > ${queryDisplay}`));
		if (!compact) lines.push(row(dim(`tokens · re:<pattern> regex · "phrase" exact`)));
		lines.push(divider());

		if (this.sessions.status === "loading") {
			lines.push(row(muted("Loading sessions…")));
		} else if (this.sessions.status === "failed") {
			lines.push(row(muted(`Could not load sessions: ${this.sessions.error.split("\n")[0]}`)));
		} else if (this.searchStatus.status === "failed") {
			lines.push(row(muted(`Search failed: ${this.searchStatus.error.split("\n")[0]}`)));
		} else if (this.searchStatus.status === "searching" || this.searchStatus.status === "action") {
			lines.push(row(muted(this.searchStatus.status === "action" ? "Loading prompt…  Esc cancel" : "Searching…")));
		} else if (state.results.length === 0) {
			lines.push(row(muted(state.query.trim() ? "No prompts match your search" : "No prompts found")));
		} else {
			lines.push(...this.renderSearchHitPane(inner, row, dim, muted, accent));
		}

		lines.push(divider());
		if (compact) {
			lines.push(row(`${ansiYellow("alt+c/f/r/i/n/a")} ${dim("actions")}  ${ansiYellow("tab")} ${dim("scope")}`));
		} else {
			lines.push(row(`${ansiYellow("-/=")} ${dim("page")}  ${ansiYellow("alt+c")} ${dim("copy")}  ${ansiYellow("alt+f")} ${dim("fork")}  ${ansiYellow("alt+r")} ${dim("resume")}`));
			lines.push(row(`${ansiYellow("alt+i")} ${dim("inject+ctx")}  ${ansiYellow("alt+n")} ${dim("new+ctx")}  ${ansiYellow("alt+a")} ${dim("actions")}  ${ansiYellow("tab")} ${dim("scope")}`));
		}
		lines.push(bottom());
		return lines;
	}

	private renderSearchHitPane(
		inner: number,
		row: (content?: string) => string,
		dim: (s: string) => string,
		muted: (s: string) => string,
		accent: (s: string) => string,
	): string[] {
		const state = this.searchState;
		const compact = this.compactSearchLayout();
		const maxVisible = this.searchMaxVisibleRows();
		const start = Math.max(0, Math.min(state.selected - Math.floor(maxVisible / 2), state.results.length - maxVisible));
		const end = Math.min(start + maxVisible, state.results.length);
		const gap = ` ${dim("│")} `;
		const twoPane = inner >= 72;
		const rightWidth = twoPane ? Math.max(24, Math.floor(inner * 0.43)) : 0;
		const leftWidth = twoPane ? Math.max(24, inner - rightWidth - visibleWidth(gap)) : inner;
		const paneRows = Math.max(1, (end - start) * 3 - 1);
		const selectedHit = state.results[state.selected];
		const rightLines = twoPane ? this.renderPromptPreviewLines(selectedHit, rightWidth, paneRows, dim, muted, accent) : [];
		const fixed = (content: string, colWidth: number, selected = false): string => {
			const safe = content.replace(/[\r\n\t]+/g, " ");
			const clipped = truncateToWidth(safe, colWidth, "");
			const padded = clipped + " ".repeat(Math.max(0, colWidth - visibleWidth(clipped)));
			return selected ? this.theme.bg("selectedBg", padded) : padded;
		};
		const leftLines: string[] = [];
		for (let i = start; i < end; i++) {
			const hit = state.results[i]!;
			const selected = i === state.selected;
			const promptDate = new Date(promptRecencyTime(hit));
			const metadata = dim(`#${hit.message.index} · ${formatSessionSearchDate(promptDate)}`);
			const titleText = truncateToWidth(sessionResumeTitle(hit.result), Math.max(8, leftWidth - visibleWidth(metadata) - 1), "…");
			const title = accent(titleText);
			const snippet = styleSessionSnippet(hit.snippet || hit.message.text, state.query, this.theme);
			leftLines.push(fixed(selected ? this.theme.bold(snippet) : snippet, leftWidth, selected));
			leftLines.push(fixed(`${title} ${metadata}`, leftWidth, selected));
			if (i < end - 1) leftLines.push(fixed(dim("─".repeat(Math.max(8, leftWidth))), leftWidth));
		}
		const output: string[] = [];
		for (let i = 0; i < leftLines.length; i++) {
			if (twoPane) output.push(row(`${leftLines[i] ?? ""}${gap}${rightLines[i] ?? " ".repeat(rightWidth)}`));
			else output.push(row(leftLines[i] ?? ""));
		}
		if (!twoPane && selectedHit) {
			output.push(row(dim("─".repeat(Math.max(8, inner)))));
			for (const line of this.renderPromptPreviewLines(selectedHit, inner, Math.min(5, paneRows), dim, muted, accent)) output.push(row(line));
		}
		if (!compact && state.results.length > maxVisible) output.push(row(dim(`${state.selected + 1}/${state.results.length} ${state.query.trim() ? "matches" : "recent prompts"}`)));
		return output;
	}

	private renderPromptPreviewLines(
		hit: QolSessionSearchHit | undefined,
		width: number,
		maxLines: number,
		dim: (s: string) => string,
		muted: (s: string) => string,
		accent: (s: string) => string,
	): string[] {
		const fixed = (content: string): string => {
			const clipped = truncateToWidth(content.replace(/[\r\n\t]+/g, " "), width, "…");
			return clipped + " ".repeat(Math.max(0, width - visibleWidth(clipped)));
		};
		if (!hit) return Array.from({ length: maxLines }, () => fixed(""));
		const title = accent("Prompt preview");
		const cwd = muted(truncateToWidth(shortPathForUi(hit.result.cwd || hit.result.path), width, "…"));
		const bodyBudget = Math.max(1, maxLines - 3);
		const body = wrapVisible(styleSessionSnippet(hit.message.text, this.searchState.query, this.theme), width, bodyBudget);
		const lines = [fixed(title), fixed(cwd), fixed(dim("─".repeat(Math.max(8, width)))), ...body.map(fixed)];
		while (lines.length < maxLines) lines.push(fixed(""));
		return lines.slice(0, maxLines);
	}

	private renderScopeTabs(inner: number): string {
		const tabs: { id: QolSessionSearchScope; label: string }[] = [
			{ id: "current", label: "Project" },
			{ id: "all", label: "All" },
		];
		const parts = tabs.map((tab) => {
			const label = ` ${truncateToWidth(tab.label, 18, "…")} `;
			if (tab.id === this.searchState.scope) return this.theme.fg("accent", this.theme.inverse(this.theme.bold(label)));
			return this.theme.bg("selectedBg", this.theme.fg("accent", label));
		});
		return truncateToWidth(parts.join(" "), inner, "");
	}

	private renderMessages(width: number, state: QolSessionMessagesState): string[] {
		const { bottom, divider, empty, inner, row, selectedRow, top } = boxParts(width, this.theme);
		const accent = (s: string) => this.theme.fg("accent", s);
		const dim = (s: string) => this.theme.fg("dim", s);
		const muted = (s: string) => this.theme.fg("muted", s);
		const result = state.result;
		const lines: string[] = [top("Session Prompts", `${state.selected + 1}/${state.messages.length}`), empty()];
		const pair = (left: string, right: string) => {
			const leftWidth = Math.max(1, inner - visibleWidth(right) - 1);
			const clippedLeft = truncateToWidth(left, leftWidth, "…");
			const gap = Math.max(1, inner - visibleWidth(clippedLeft) - visibleWidth(right));
			return `${clippedLeft}${" ".repeat(gap)}${right}`;
		};
		const right = dim(formatSessionSearchDate(result.modified));
		const title = truncateToWidth(sessionResumeTitle(result), Math.max(12, inner - visibleWidth(right) - 1), "…");
		lines.push(row(pair(this.theme.bold(accent(title)), right)));
		lines.push(row(muted(truncateToWidth(shortPathForUi(result.cwd || result.path), inner, "…"))));
		lines.push(empty(), divider(), empty());

		const maxVisible = this.messageMaxVisibleRows();
		const start = Math.max(0, Math.min(state.selected - Math.floor(maxVisible / 2), state.messages.length - maxVisible));
		const end = Math.min(start + maxVisible, state.messages.length);
		for (let i = start; i < end; i++) {
			const message = state.messages[i]!;
			const selected = i === state.selected;
			const numberPlain = `#${message.index}`;
			const number = selected ? this.theme.fg("text", numberPlain) : dim(numberPlain);
			const textWidth = Math.max(12, inner - visibleWidth(number) - 1);
			const text = truncateToWidth(message.text, textWidth, "…");
			const messageRow = `${number} ${selected ? this.theme.bold(accent(text)) : text}`;
			lines.push(selected ? selectedRow(messageRow) : row(messageRow));
		}
		lines.push(divider(), empty());
		lines.push(row(`${ansiYellow("-/=")} ${dim("page")}  ${ansiYellow("alt+c")} ${dim("copy")}  ${ansiYellow("alt+f")} ${dim("fork")}  ${ansiYellow("alt+r")} ${dim("resume")}`));
		lines.push(row(`${ansiYellow("alt+i")} ${dim("inject+ctx")}  ${ansiYellow("alt+n")} ${dim("new+ctx")}`));
		lines.push(bottom());
		return lines;
	}

	private renderActions(width: number, state: QolSessionActionState): string[] {
		const { bottom, divider, empty, inner, row, top } = boxParts(width, this.theme);
		const accent = (s: string) => this.theme.fg("accent", s);
		const dim = (s: string) => this.theme.fg("dim", s);
		const muted = (s: string) => this.theme.fg("muted", s);
		const lines: string[] = [top("Prompt Actions"), empty()];
		const title = truncateToWidth(sessionResumeTitle(state.result), Math.max(12, inner - visibleWidth(`#${state.message.index}`) - 2), "…");
		lines.push(row(`${this.theme.bold(accent(title))}  ${dim(`#${state.message.index}`)}`));
		lines.push(row(muted(truncateToWidth(shortPathForUi(state.result.cwd || state.result.path), inner, "…"))));
		lines.push(empty(), divider(), empty());
		lines.push(row(dim("Selected prompt")));
		const wrapped = wrapVisible(state.message.text, inner, 4);
		for (const line of wrapped) lines.push(row(line));
		lines.push(empty(), divider(), empty());
		const helpLines = [
			"Fork session from here opens the source session at the point before this prompt and places the prompt in the editor; submit to branch from there.",
			"Copy Prompt copies this prompt into your current editor.",
			"Inject + Context summarizes the source session into the current session, focused on this prompt.",
			"New + Context creates a fresh session and imports that focused summary there.",
		];
		for (const help of helpLines) {
			for (const line of wrapVisible(dim(help), inner, 2)) lines.push(row(line));
		}
		lines.push(empty(), divider(), empty());
		lines.push(row(`${ansiYellow("alt+c")} ${dim("copy")}  ${ansiYellow("alt+f")} ${dim("fork")}  ${ansiYellow("alt+r")} ${dim("resume")}`));
		lines.push(row(`${ansiYellow("alt+i")} ${dim("inject+ctx")}  ${ansiYellow("alt+n")} ${dim("new+ctx")}`));
		lines.push(bottom());
		return lines;
	}

	private renderConfirmModel(width: number, state: QolSessionConfirmModelState): string[] {
		const { bottom, divider, empty, inner, row, top } = boxParts(width, this.theme);
		const accent = (s: string) => this.theme.fg("accent", s);
		const dim = (s: string) => this.theme.fg("dim", s);
		const muted = (s: string) => this.theme.fg("muted", s);
		const warning = (s: string) => this.theme.fg("warning", s);
		const previousLabel = modelLabel(state.previousModel);
		const currentLabel = modelLabel(state.currentModel);
		const lines: string[] = [top("Choose model"), empty()];
		const title = truncateToWidth(sessionResumeTitle(state.result), inner, "…");
		lines.push(row(this.theme.bold(warning("Model differs from current session"))));
		lines.push(row(accent(`“${title}”`)));
		lines.push(row(muted(truncateToWidth(shortPathForUi(state.result.cwd || state.result.path), inner, "…"))));
		lines.push(empty());
		lines.push(row(`${dim("Session model: ")}${warning(previousLabel)}`));
		lines.push(row(`${dim("Current model: ")}${warning(currentLabel)}`));
		lines.push(empty());
		for (const help of [
			"Previous model resumes exactly as saved.",
			"Current model writes a model-change event before resume, so full context transfers and future turns use it.",
		]) {
			for (const line of wrapVisible(dim(help), inner, 2)) lines.push(row(line));
		}
		lines.push(empty(), divider(), empty());
		const optionRow = (index: 0 | 1, label: string, model: string): string => {
			const selected = state.selected === index;
			const prefix = selected ? "› " : "  ";
			const content = `${warning(prefix)}${selected ? this.theme.fg("text", label) : dim(label)}${dim(" — ")}${selected ? warning(model) : muted(model)}`;
			const body = truncateToWidth(content, inner, "…") + " ".repeat(Math.max(0, inner - visibleWidth(truncateToWidth(content, inner, "…"))));
			return selected ? this.theme.bg("selectedBg", body) : body;
		};
		lines.push(row(optionRow(0, "Continue with previous model", previousLabel)));
		lines.push(row(optionRow(1, "Continue with current model", currentLabel)));
		lines.push(empty(), divider(), empty());
		lines.push(row(`${ansiYellow("↑/↓")} ${dim("choose")}  ${ansiYellow("enter")} ${dim("resume")}  ${ansiYellow("backspace")} ${dim("back")}`));
		lines.push(bottom());
		return lines;
	}

	private renderForkConfirm(width: number, state: QolSessionForkConfirmState): string[] {
		const { bottom, divider, empty, inner, row, selectedRow, top } = boxParts(width, this.theme);
		const accent = (s: string) => this.theme.fg("accent", s);
		const dim = (s: string) => this.theme.fg("dim", s);
		const muted = (s: string) => this.theme.fg("muted", s);
		const lines: string[] = [top("Fork Session", `${state.selected + 1}/${state.messages.length}`), empty()];
		const title = truncateToWidth(sessionResumeTitle(state.result), inner, "…");
		lines.push(row(this.theme.bold(accent(title))));
		lines.push(row(muted(truncateToWidth(shortPathForUi(state.result.cwd || state.result.path), inner, "…"))));
		lines.push(empty(), divider(), empty());
		for (const line of wrapVisible(dim("Choose the prompt to fork from. Pi will open the source session before that prompt and place the prompt in the editor."), inner, 2)) {
			lines.push(row(line));
		}
		lines.push(empty());

		const maxVisible = this.forkConfirmMaxVisibleRows();
		const start = Math.max(0, Math.min(state.selected - Math.floor(maxVisible / 2), state.messages.length - maxVisible));
		const end = Math.min(start + maxVisible, state.messages.length);
		for (let i = start; i < end; i++) {
			const message = state.messages[i]!;
			const selected = i === state.selected;
			const numberPlain = `#${message.index}`;
			const number = selected ? this.theme.fg("text", numberPlain) : dim(numberPlain);
			const textWidth = Math.max(12, inner - visibleWidth(number) - 1);
			const text = truncateToWidth(message.text, textWidth, "…");
			const messageRow = `${number} ${selected ? this.theme.bold(accent(text)) : text}`;
			lines.push(selected ? selectedRow(messageRow) : row(messageRow));
		}
		if (state.messages.length > maxVisible) lines.push(row(dim(`${state.selected + 1}/${state.messages.length} prompts`)));
		lines.push(divider(), empty());
		lines.push(row(`${ansiYellow("backspace")} ${dim("back")}`));
		lines.push(bottom());
		return lines;
	}

	private renderContextConfirm(width: number, state: QolSessionContextConfirmState): string[] {
		const { bottom, divider, empty, inner, row, top } = boxParts(width, this.theme);
		const accent = (s: string) => this.theme.fg("accent", s);
		const dim = (s: string) => this.theme.fg("dim", s);
		const muted = (s: string) => this.theme.fg("muted", s);
		const action = state.type === "newSession" ? "New + Context" : "Inject + Context";
		const verb = state.type === "newSession" ? "create new session with context" : "inject context";
		const lines: string[] = [top(action), empty()];
		lines.push(row(`${accent(sessionResumeTitle(state.result))}  ${dim(`#${state.message.index}`)}`));
		lines.push(row(muted(truncateToWidth(shortPathForUi(state.result.cwd || state.result.path), inner, "…"))));
		lines.push(empty(), divider(), empty());
		const details = [
			"This summarizes the entire source session, including messages after this prompt.",
			"The selected prompt is used as the focus for the summary, not as a cutoff point.",
			state.type === "newSession"
				? "New + Context creates a fresh session and imports that focused summary there."
				: "Inject + Context adds that focused summary to your current session.",
		];
		for (const detail of details) {
			for (const line of wrapVisible(dim(detail), inner, 2)) lines.push(row(line));
		}
		lines.push(empty(), divider(), empty());
		lines.push(row(`${ansiYellow("backspace")} ${dim("back")}`));
		lines.push(bottom());
		return lines;
	}

}

export class QolSessionSearchLoadingComponent {
	private readonly tui: { requestRender(): void };
	private readonly theme: Theme;
	private readonly title: string;
	private readonly message: string;
	private readonly done: (value: null) => void;
	private readonly controller = new AbortController();
	private readonly startedAt = Date.now();
	private frame = 0;
	private timer: ReturnType<typeof setInterval> | undefined;

	constructor(
		tui: { requestRender(): void },
		theme: Theme,
		title: string,
		message: string,
		done: (value: null) => void,
	) {
		this.tui = tui;
		this.theme = theme;
		this.title = title;
		this.message = message;
		this.done = done;
		this.timer = setInterval(() => {
			this.frame += 1;
			this.tui.requestRender();
		}, 180);
		this.timer.unref?.();
	}

	get signal(): AbortSignal {
		return this.controller.signal;
	}

	dispose(): void {
		if (this.timer) clearInterval(this.timer);
		this.timer = undefined;
	}

	invalidate(): void {}

	handleInput(data: string): void {
		if (!matchesKey(data, "escape") && !matchesKey(data, "ctrl+c")) return;
		if (!this.controller.signal.aborted) this.controller.abort();
		this.dispose();
		this.done(null);
	}

	render(width: number): string[] {
		const { bottom, divider, empty, row, top } = boxParts(width, this.theme);
		const dim = (s: string) => this.theme.fg("dim", s);
		const muted = (s: string) => this.theme.fg("muted", s);
		const accent = (s: string) => this.theme.fg("accent", s);
		const frames = ["|", "/", "-", "\\"];
		const elapsed = `${Math.max(0, Math.floor((Date.now() - this.startedAt) / 1000))}s`;
		const indicator = accent(frames[this.frame % frames.length]!);
		return [
			top(this.title, elapsed),
			empty(),
			row(`${indicator} ${muted(this.message)}`),
			row(dim("Long sessions may take a few seconds to summarize.")),
			empty(),
			divider(),
			empty(),
			bottom(),
		];
	}
}
