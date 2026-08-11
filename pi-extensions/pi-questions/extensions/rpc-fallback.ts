import type { QuestionRequest, QuestionTab } from "./question-model.js";

// RPC hosts (Paseo, pi-web, VS Code bridges) cannot render ctx.ui.custom()
// components; they bridge Pi's standard dialog methods instead. This module
// walks a question request sequentially through native select()/input()
// dialogs and reproduces the QuestionResult answers shape of the custom TUI.
// Trade-offs versus the TUI: no tabbed review step, and multi-select is a
// free-text numbers input instead of checkbox rows.

const TITLE_MAX_CHARS = 600;
const ROW_MAX_CHARS = 200;
// Bounds re-prompt loops (blank custom text, out-of-range numbers) so a host
// that mechanically replays the same bad answer cancels instead of spinning.
const MAX_PROMPT_ATTEMPTS = 5;

export interface RpcDialogUI {
	select(title: string, options: string[]): Promise<string | undefined>;
	input(title: string, placeholder?: string): Promise<string | undefined>;
}

export type PresentOutcome =
	| { kind: "answered"; answers: string[][] }
	| { kind: "cancelled" }
	| { kind: "unavailable"; error: string }
	| { kind: "external" };

export type WalkOutcome = Extract<PresentOutcome, { kind: "answered" | "cancelled" | "external" }>;

// Per-question step results. Discriminated objects, never bare strings: a
// custom answer whose text happens to be "cancelled" or "abandoned" must stay
// a valid answer, not a control state. "cancelled" is a user dismissal;
// "abandoned" means the request settled elsewhere (bridge reply, rejection,
// shutdown) and the walker must stop silently.
type StepResult =
	| { kind: "answers"; values: string[] }
	| { kind: "cancelled" }
	| { kind: "abandoned" };

// Custom-text dialog results; "blank" sends the caller back to re-show the
// question rather than submitting an empty answer.
type CustomTextResult =
	| { kind: "text"; value: string }
	| { kind: "blank" }
	| { kind: "cancelled" }
	| { kind: "abandoned" };

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
 * the pending request with them — except "external", which means the request
 * was already completed elsewhere and must not be completed again.
 */
export async function presentQuestion(request: QuestionRequest, host: QuestionHost): Promise<PresentOutcome | undefined> {
	if (host.rpcMode) {
		if (!host.dialogs) return { error: noDialogRouteError(true), kind: "unavailable" };
		return runRpcQuestionnaire(host.dialogs, request, host.isSettled);
	}
	if (host.hasUI && host.openCustom) {
		const uiResult = await host.openCustom();
		if (host.isSettled()) return { kind: "external" };
		if (uiResult !== undefined) return { kind: "external" };
		// custom() resolved undefined without completing the request: the host
		// accepted the call but cannot render the component. Fall back.
		if (!host.dialogs) return { error: noDialogRouteError(false), kind: "unavailable" };
		return runRpcQuestionnaire(host.dialogs, request, host.isSettled);
	}
	return undefined;
}

export async function runRpcQuestionnaire(
	ui: RpcDialogUI,
	request: QuestionRequest,
	isSettled: () => boolean = () => false,
): Promise<WalkOutcome> {
	const answers: string[][] = [];
	for (const [index, tab] of request.questions.entries()) {
		const step = tab.multiple
			? await askMultiSelect(ui, request, tab, index, isSettled)
			: await askSingleSelect(ui, request, tab, index, isSettled);
		if (step.kind === "abandoned") return { kind: "external" };
		if (step.kind === "cancelled") return { kind: "cancelled" };
		answers.push(step.values);
	}
	return isSettled() ? { kind: "external" } : { answers, kind: "answered" };
}

function truncateChars(text: string, max: number): string {
	return text.length > max ? `${text.slice(0, Math.max(0, max - 1))}…` : text;
}

function tabTitle(request: QuestionRequest, tab: QuestionTab, index: number, note = ""): string {
	const position = request.questions.length > 1 ? ` (${index + 1}/${request.questions.length})` : "";
	const prefix = note ? `${note} — ` : "";
	return truncateChars(`${prefix}${tab.header}${position}: ${tab.question}`, TITLE_MAX_CHARS);
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

// The option list is never truncated as a block: every row (including the
// custom row, whose number must stay actionable) is individually capped and
// always present. Only the question text itself is length-limited.
function multiSelectTitle(request: QuestionRequest, tab: QuestionTab, index: number, note: string): string {
	return [tabTitle(request, tab, index, note), ...formatOptionRows(tab)].join("\n");
}

// Mirrors the TUI's empty-selection contract: the custom TUI can submit an
// empty single-select answer only through its synthetic confirm tab, which
// exists exactly when the request has multiple questions or any multi-select
// tab (hasConfirmTab in questions.ts). Single-question single-select requests
// cannot submit empty there, so the walker offers no skip row for them either.
function allowsEmptySelection(request: QuestionRequest): boolean {
	return request.questions.length > 1 || request.questions.some((question) => question.multiple);
}

async function askCustomText(ui: RpcDialogUI, tab: QuestionTab, isSettled: () => boolean): Promise<CustomTextResult> {
	if (isSettled()) return { kind: "abandoned" };
	const text = await ui.input(truncateChars(`${tab.header}: ${tab.customLabel}`, TITLE_MAX_CHARS), tab.customPlaceholder);
	if (isSettled()) return { kind: "abandoned" };
	if (text === undefined) return { kind: "cancelled" };
	const trimmed = text.trim();
	return trimmed ? { kind: "text", value: trimmed } : { kind: "blank" };
}

async function askSingleSelect(ui: RpcDialogUI, request: QuestionRequest, tab: QuestionTab, index: number, isSettled: () => boolean): Promise<StepResult> {
	const rows = formatOptionRows(tab);
	const skipRow = allowsEmptySelection(request) ? `${customRowNumber(tab) + 1}. Skip (no selection)` : undefined;
	if (skipRow) rows.push(skipRow);
	let note = "";
	for (let attempt = 0; attempt < MAX_PROMPT_ATTEMPTS; attempt += 1) {
		if (isSettled()) return { kind: "abandoned" };
		const choice = await ui.select(tabTitle(request, tab, index, note), rows);
		if (isSettled()) return { kind: "abandoned" };
		if (choice === undefined) return { kind: "cancelled" };
		if (skipRow && choice === skipRow) return { kind: "answers", values: [] };
		const rowIndex = rows.indexOf(choice);
		if (rowIndex === -1) {
			// Host returned something other than a listed row: treat non-empty
			// text as a custom answer, matching the free-text fallback row.
			const trimmed = choice.trim();
			if (trimmed) return { kind: "answers", values: [trimmed] };
			note = "Answer cannot be empty";
			continue;
		}
		if (rowIndex < tab.options.length) return { kind: "answers", values: [tab.options[rowIndex].label] };
		const custom = await askCustomText(ui, tab, isSettled);
		if (custom.kind === "abandoned" || custom.kind === "cancelled") return { kind: custom.kind };
		if (custom.kind === "blank") {
			note = "Custom answer cannot be empty";
			continue;
		}
		return { kind: "answers", values: [custom.value] };
	}
	return { kind: "cancelled" };
}

export function parseMultiSelection(raw: string, tab: QuestionTab): { labels: string[]; wantsCustom: boolean } | { error: string } {
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
		if (row < 1 || row > customRowNumber(tab)) {
			return { error: `Option numbers must be between 1 and ${customRowNumber(tab)}` };
		}
		if (row <= tab.options.length) {
			const label = tab.options[row - 1].label;
			if (!labels.includes(label)) labels.push(label);
		} else {
			wantsCustom = true;
		}
	}
	return { labels, wantsCustom };
}

async function askMultiSelect(ui: RpcDialogUI, request: QuestionRequest, tab: QuestionTab, index: number, isSettled: () => boolean): Promise<StepResult> {
	const placeholder = `Comma-separated numbers (e.g. 1,3); ${customRowNumber(tab)} or free text for a custom answer; empty for no selection`;
	let note = "";
	for (let attempt = 0; attempt < MAX_PROMPT_ATTEMPTS; attempt += 1) {
		if (isSettled()) return { kind: "abandoned" };
		const raw = await ui.input(multiSelectTitle(request, tab, index, note), placeholder);
		if (isSettled()) return { kind: "abandoned" };
		if (raw === undefined) return { kind: "cancelled" };
		const parsed = parseMultiSelection(raw, tab);
		if ("error" in parsed) {
			note = parsed.error;
			continue;
		}
		if (!parsed.wantsCustom) return { kind: "answers", values: parsed.labels };
		const custom = await askCustomText(ui, tab, isSettled);
		if (custom.kind === "abandoned" || custom.kind === "cancelled") return { kind: custom.kind };
		if (custom.kind === "blank") {
			note = "Custom answer cannot be empty";
			continue;
		}
		return { kind: "answers", values: parsed.labels.includes(custom.value) ? parsed.labels : [...parsed.labels, custom.value] };
	}
	return { kind: "cancelled" };
}
