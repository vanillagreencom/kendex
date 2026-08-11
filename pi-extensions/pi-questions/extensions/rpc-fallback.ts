import type { QuestionRequest, QuestionTab } from "./question-model.js";

// RPC hosts (Paseo, pi-web, VS Code bridges) cannot render ctx.ui.custom()
// components; they bridge Pi's standard dialog methods instead. This module
// walks a question request sequentially through native select()/input()
// dialogs and reproduces the QuestionResult answers shape of the custom TUI.
// Trade-offs versus the TUI: no tabbed review step, and multi-select is a
// free-text numbers input instead of checkbox rows.

const TITLE_MAX_CHARS = 600;
const ROW_MAX_CHARS = 200;

export interface RpcDialogUI {
	select(title: string, options: string[]): Promise<string | undefined>;
	input(title: string, placeholder?: string): Promise<string | undefined>;
}

export type PresentOutcome =
	| { kind: "answered"; answers: string[][] }
	| { kind: "cancelled" }
	| { kind: "unavailable"; error: string }
	| { kind: "external" };

export interface QuestionHost {
	rpcMode: boolean;
	hasUI: boolean;
	dialogs: RpcDialogUI | undefined;
	/** Opens the custom TUI questionnaire; resolves with ctx.ui.custom()'s result. */
	openCustom?: () => Promise<unknown>;
	/** Whether the pending question was already completed elsewhere (bridge/API reply). */
	isSettled: () => boolean;
}

export function isRpcMode(ctx: unknown): boolean {
	return typeof ctx === "object" && ctx !== null && (ctx as { mode?: unknown }).mode === "rpc";
}

export function rpcDialogUI(ui: unknown): RpcDialogUI | undefined {
	if (!ui || typeof ui !== "object") return undefined;
	const candidate = ui as { select?: unknown; input?: unknown };
	if (typeof candidate.select !== "function" || typeof candidate.input !== "function") return undefined;
	return ui as RpcDialogUI;
}

export function noDialogRouteError(rpcMode: boolean): string {
	return rpcMode
		? "No question UI available: this RPC host renders neither custom TUI components nor native select/input dialogs"
		: "No question UI available: custom TUI resolved without a result and the host provides no native select/input dialogs";
}

/**
 * Route a question request to the best available UI.
 *
 * Returns undefined when no UI route applies and the request should stay
 * pending for bridge/API replies (the pre-fallback behavior for headless
 * contexts). All other outcomes are terminal and the caller must complete
 * the pending request with them.
 */
export async function presentQuestion(request: QuestionRequest, host: QuestionHost): Promise<PresentOutcome | undefined> {
	if (host.rpcMode) {
		if (!host.dialogs) return { error: noDialogRouteError(true), kind: "unavailable" };
		return runRpcQuestionnaire(host.dialogs, request);
	}
	if (host.hasUI && host.openCustom) {
		const uiResult = await host.openCustom();
		if (host.isSettled()) return { kind: "external" };
		if (uiResult !== undefined) return { kind: "external" };
		// custom() resolved undefined without completing the request: the host
		// accepted the call but cannot render the component. Fall back.
		if (!host.dialogs) return { error: noDialogRouteError(false), kind: "unavailable" };
		return runRpcQuestionnaire(host.dialogs, request);
	}
	return undefined;
}

export async function runRpcQuestionnaire(
	ui: RpcDialogUI,
	request: QuestionRequest,
): Promise<{ kind: "answered"; answers: string[][] } | { kind: "cancelled" }> {
	const answers: string[][] = [];
	for (const [index, tab] of request.questions.entries()) {
		const tabAnswers = tab.multiple
			? await askMultiSelect(ui, request, tab, index)
			: await askSingleSelect(ui, request, tab, index);
		if (tabAnswers === undefined) return { kind: "cancelled" };
		answers.push(tabAnswers);
	}
	return { answers, kind: "answered" };
}

function truncateChars(text: string, max: number): string {
	return text.length > max ? `${text.slice(0, Math.max(0, max - 1))}…` : text;
}

function tabTitle(request: QuestionRequest, tab: QuestionTab, index: number): string {
	const position = request.questions.length > 1 ? ` (${index + 1}/${request.questions.length})` : "";
	return truncateChars(`${tab.header}${position}: ${tab.question}`, TITLE_MAX_CHARS);
}

function customRowNumber(tab: QuestionTab): number {
	return tab.options.length + 1;
}

export function formatOptionRows(tab: QuestionTab): string[] {
	const rows = tab.options.map((option, index) => {
		const description = option.description ? ` — ${option.description}` : "";
		return truncateChars(`${index + 1}. ${option.label}${description}`, ROW_MAX_CHARS);
	});
	rows.push(truncateChars(`${customRowNumber(tab)}. ${tab.customLabel} (type your own answer)`, ROW_MAX_CHARS));
	return rows;
}

async function askCustomText(ui: RpcDialogUI, tab: QuestionTab): Promise<string[] | undefined> {
	const text = await ui.input(truncateChars(`${tab.header}: ${tab.customLabel}`, TITLE_MAX_CHARS), tab.customPlaceholder);
	if (text === undefined) return undefined;
	const trimmed = text.trim();
	return trimmed ? [trimmed] : [];
}

async function askSingleSelect(ui: RpcDialogUI, request: QuestionRequest, tab: QuestionTab, index: number): Promise<string[] | undefined> {
	const rows = formatOptionRows(tab);
	const choice = await ui.select(tabTitle(request, tab, index), rows);
	if (choice === undefined) return undefined;
	const rowIndex = rows.indexOf(choice);
	if (rowIndex === -1) {
		// Host returned something other than a listed row: treat non-empty text
		// as a custom answer, matching the always-available free-text fallback.
		const trimmed = choice.trim();
		return trimmed ? [trimmed] : [];
	}
	if (rowIndex >= tab.options.length) return askCustomText(ui, tab);
	return [tab.options[rowIndex].label];
}

export function parseMultiSelection(raw: string, tab: QuestionTab): { labels: string[]; wantsCustom: boolean } {
	const trimmed = raw.trim();
	if (!trimmed) return { labels: [], wantsCustom: false };
	const tokens = trimmed.split(/[\s,]+/).filter(Boolean);
	if (!tokens.every((token) => /^\d+$/.test(token))) {
		// Any non-numeric input is a whole free-text custom answer.
		return { labels: [trimmed], wantsCustom: false };
	}
	const labels: string[] = [];
	let wantsCustom = false;
	for (const token of tokens) {
		const row = Number(token);
		if (row >= 1 && row <= tab.options.length) {
			const label = tab.options[row - 1].label;
			if (!labels.includes(label)) labels.push(label);
		} else if (row === customRowNumber(tab)) {
			wantsCustom = true;
		}
	}
	return { labels, wantsCustom };
}

async function askMultiSelect(ui: RpcDialogUI, request: QuestionRequest, tab: QuestionTab, index: number): Promise<string[] | undefined> {
	const title = truncateChars(`${tabTitle(request, tab, index)}\n${formatOptionRows(tab).join("\n")}`, TITLE_MAX_CHARS);
	const placeholder = `Comma-separated numbers (e.g. 1,3); ${customRowNumber(tab)} or free text for a custom answer`;
	const raw = await ui.input(title, placeholder);
	if (raw === undefined) return undefined;
	const { labels, wantsCustom } = parseMultiSelection(raw, tab);
	if (!wantsCustom) return labels;
	const custom = await askCustomText(ui, tab);
	if (custom === undefined) return undefined;
	return [...labels, ...custom.filter((answer) => !labels.includes(answer))];
}
