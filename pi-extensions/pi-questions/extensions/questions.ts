import {
	DEFAULT_MAX_BYTES,
	DEFAULT_MAX_LINES,
	formatSize,
	type AgentToolResult,
	type ExtensionAPI,
	type ExtensionContext,
	type Theme,
	truncateHead,
	type TruncationResult,
	withFileMutationQueue,
} from "@earendil-works/pi-coding-agent";
import { Input, matchesKey, truncateToWidth, visibleWidth, type Focusable } from "@earendil-works/pi-tui";
import { existsSync, readFileSync } from "node:fs";
import { mkdtemp, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

import { publishQuestionActivity } from "./activity.js";
import { frameGlyphs, glyphs, treeGlyph } from "./glyphs.js";

const INSTALL_SYMBOL = Symbol.for("vstack.pi-questions.installed");
const CONFIG_ID = "@vanillagreen/pi-questions";
const SERVICE_SYMBOL = Symbol.for("vstack.pi-questions.service");
const QOL_NOTIFICATION_SERVICE_SYMBOL = Symbol.for("vstack.pi-qol.notification-service");
const VSTACK_MODAL_LOCK_SYMBOL = Symbol.for("vstack.pi.modal-lock");
const QUESTION_OPENED_EVENT = "vstack:pi-questions:opened";
const POPUP_WIDTH = 96;
const POPUP_MAX_HEIGHT = "80%";
const DEFAULT_RENDER_MODE = "editor";
const PADDING_X = 2;
const PADDING_Y = 0;
const OPTION_ROWS = 10;
const ANSI_GREEN_FG = "\x1b[32m";
const ANSI_YELLOW_FG = "\x1b[33m";

// Nerd Font glyphs (Font Awesome subset) used in place of unicode dingbats so
// chat output renders consistently regardless of emoji-presentation fallback.
const ICONS = {
	check: "",          // nf-fa-check
	checkSquare: "",    // nf-fa-check_square_o
	square: "",         // nf-fa-square_o
	circleFilled: "",   // nf-fa-circle
	circleOpen: "",     // nf-fa-circle_o
} as const;
const ANSI_FG_RESET = "\x1b[39m";

function ansiGreen(text: string): string { return `${ANSI_GREEN_FG}${text}${ANSI_FG_RESET}`; }
function ansiYellow(text: string): string { return `${ANSI_YELLOW_FG}${text}${ANSI_FG_RESET}`; }

type VstackConfig = Record<string, unknown>;
type QuestionRenderMode = "editor" | "overlay";

type QuestionResult = QuestionAnswerResult | QuestionCancelResult;
type QuestionToolDetails = QuestionResult & { fullOutputError?: string; fullOutputPath?: string; truncation?: TruncationResult };
type QuestionSource = "ui" | "bridge" | "tool" | "api" | "shutdown" | "ui_error";

interface QuestionAnswerResult {
	requestId: string;
	answers: string[][];
}

interface QuestionCancelResult {
	requestId: string;
	cancelled: true;
	error?: string;
}

interface QuestionOption {
	label: string;
	description: string;
}

interface QuestionTab {
	header: string;
	question: string;
	options: QuestionOption[];
	multiple: boolean;
	allowCustom: boolean;
	customLabel: string;
	customPlaceholder: string;
}

interface QuestionRequest {
	id: string;
	header: string;
	questions: QuestionTab[];
}

interface PendingQuestionView {
	requestId: string;
	openedAt: string;
	request: QuestionRequest;
}

interface QuestionEvent {
	action: "opened" | "answered" | "rejected";
	requestId: string;
	openedAt: string;
	closedAt?: string;
	source?: QuestionSource;
	request?: QuestionRequest;
	result?: QuestionResult;
}

interface QolNotificationService {
	notifyQuestionOpened(ctx: ExtensionContext | undefined, event: { requestId?: string; request?: QuestionRequest; source?: string }): boolean;
}

interface VstackModalLock {
	depth: number;
}

interface QuestionService {
	ask(ctx: ExtensionContext, payload: unknown, source?: QuestionSource): Promise<QuestionResult>;
	listPending(): PendingQuestionView[];
	reply(requestId: string, answers: unknown, source?: QuestionSource): boolean;
	reject(requestId: string, source?: QuestionSource): boolean;
	subscribe(listener: (event: QuestionEvent) => void): () => void;
	shutdown(): void;
}

interface PendingQuestion extends PendingQuestionView {
	complete(result: QuestionResult, source: QuestionSource): void;
	promise: Promise<QuestionResult>;
	requestRender?: () => void;
	uiDone?: (result: QuestionResult) => void;
}

function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
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
	const userDir = resolve(expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "~/.pi/agent"));
	return [join(userDir, "settings.json"), projectSettingsPath(cwd)];
}

function readVstackConfig(cwd?: string): VstackConfig {
	const merged: VstackConfig = {};
	for (const path of piSettingsPaths(cwd)) {
		if (!existsSync(path)) continue;
		try {
			const parsed = JSON.parse(readFileSync(path, "utf8"));
			const config = parsed?.vstack?.extensionManager?.config?.[CONFIG_ID];
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

function questionRenderMode(cwd?: string): QuestionRenderMode {
	const mode = settingString("renderMode", DEFAULT_RENDER_MODE, cwd);
	return mode === "overlay" ? "overlay" : "editor";
}

function safeFileName(value: string): string {
	return value.replace(/[^a-z0-9_.-]+/gi, "-").replace(/^-+|-+$/g, "").slice(0, 80) || "question";
}

function formatQuestionTruncationNotice(truncation: TruncationResult, fullOutputPath?: string, fullOutputError?: string): string {
	const omittedLines = Math.max(0, truncation.totalLines - truncation.outputLines);
	const omittedBytes = Math.max(0, truncation.totalBytes - truncation.outputBytes);
	const artifact = fullOutputPath
		? ` Full output saved to: ${fullOutputPath}`
		: fullOutputError
			? ` Full output preservation failed: ${fullOutputError}`
			: "";
	return `[Output truncated: showing ${truncation.outputLines} of ${truncation.totalLines} lines (${formatSize(
		truncation.outputBytes,
	)} of ${formatSize(truncation.totalBytes)}). ${omittedLines} lines (${formatSize(omittedBytes)}) omitted.${artifact}]`;
}

function sanitizeDetailValue(value: unknown, depth = 0): unknown {
	if (depth > 4) return "[Max detail depth reached]";
	if (value == null || typeof value === "number" || typeof value === "boolean") return value;
	if (typeof value === "string") return value.length > 8 * 1024 ? `${value.slice(0, 8 * 1024)}${glyphs().ellipsis} [detail string truncated]` : value;
	if (Array.isArray(value)) return value.slice(0, 50).map((item) => sanitizeDetailValue(item, depth + 1));
	if (typeof value === "object") {
		const out: Record<string, unknown> = {};
		for (const [index, [key, nested]] of Object.entries(value as Record<string, unknown>).entries()) {
			if (index >= 80) {
				out["[truncated]"] = "detail object field cap reached";
				break;
			}
			out[key] = sanitizeDetailValue(nested, depth + 1);
		}
		return out;
	}
	return String(value);
}

async function writeFullQuestionResult(result: QuestionResult, toolCallId: string, text: string): Promise<{ error?: string; path?: string }> {
	try {
		const dir = await mkdtemp(join(tmpdir(), "pi-question-"));
		const filePath = join(dir, `${safeFileName(result.requestId || toolCallId || "result")}.json`);
		await withFileMutationQueue(filePath, async () => {
			await writeFile(filePath, text, { encoding: "utf-8", mode: 0o600 });
		});
		return { path: filePath };
	} catch (error) {
		return { error: stringifyError(error) };
	}
}

async function makeQuestionToolResult(toolCallId: string, result: QuestionResult): Promise<AgentToolResult<QuestionResult>> {
	const text = JSON.stringify(result, null, 2);
	const truncation = truncateHead(text, { maxBytes: DEFAULT_MAX_BYTES, maxLines: DEFAULT_MAX_LINES });
	if (!truncation.truncated) return { content: [{ type: "text", text }], details: result };
	const artifact = await writeFullQuestionResult(result, toolCallId, text);
	const details = sanitizeDetailValue(result) as QuestionToolDetails;
	details.fullOutputError = artifact.error;
	details.fullOutputPath = artifact.path;
	details.truncation = truncation;
	return {
		content: [{ type: "text", text: `${truncation.content}\n\n${formatQuestionTruncationNotice(truncation, artifact.path, artifact.error)}` }],
		details,
	};
}

const QUESTION_TOOL_PARAMETERS = {
	type: "object",
	additionalProperties: false,
	properties: {
		id: { type: "string", description: "Stable request id. Defaults to que_<random>." },
		header: { type: "string", description: "Question title text." },
		questions: {
			type: "array",
			minItems: 1,
			items: {
				type: "object",
				additionalProperties: false,
				properties: {
					header: { type: "string", description: "Tab/category title." },
					question: { type: "string", description: "Question text for this tab." },
					options: {
						type: "array",
						minItems: 1,
						items: {
							type: "object",
							additionalProperties: false,
							properties: {
								label: { type: "string" },
								description: { type: "string" },
							},
							required: ["label"],
						},
					},
					multiple: { type: "boolean", default: false },
					allowCustom: { type: "boolean", default: false, description: "Allow the user to type a custom free-form answer for this tab." },
					customLabel: { type: "string", description: "Label for the free-form answer row. Defaults to 'Type custom answer'." },
					customPlaceholder: { type: "string", description: "Placeholder/help text shown for the free-form answer editor." },
				},
				required: ["header", "question", "options"],
			},
		},
	},
	required: ["questions"],
};

function padAnsi(text: string, width: number): string {
	const truncated = truncateToWidth(text, width, "");
	return `${truncated}${" ".repeat(Math.max(0, width - visibleWidth(truncated)))}`;
}

function vstackModalLock(): VstackModalLock {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const existing = host[VSTACK_MODAL_LOCK_SYMBOL] as VstackModalLock | undefined;
	if (existing && typeof existing.depth === "number") return existing;
	const lock = { depth: 0 };
	host[VSTACK_MODAL_LOCK_SYMBOL] = lock;
	return lock;
}

function isVstackModalActive(): boolean {
	return vstackModalLock().depth > 0;
}

function acquireVstackModalLock(): () => void {
	const lock = vstackModalLock();
	lock.depth += 1;
	let released = false;
	return () => {
		if (released) return;
		released = true;
		lock.depth = Math.max(0, lock.depth - 1);
	};
}

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

function popupContentWidth(width: number): number {
	return Math.max(1, width - 2 - PADDING_X * 2);
}

function framePopup(lines: string[], width: number, theme: Theme, title = "", right = ""): string[] {
	if (width < 8) return lines.map((line) => truncateToWidth(line, width, ""));

	const border = (text: string) => theme.fg("borderAccent", text);
	const frame = frameGlyphs();
	const contentWidth = popupContentWidth(width);
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

function selectedLine(theme: Theme, content: string, width: number): string {
	return theme.bg("selectedBg", padAnsi(content, width));
}

function panelLine(content: string, width: number): string {
	return padAnsi(content, width);
}

function footerHint(theme: Theme, entries: Array<[string, string]>): string {
	return entries.map(([key, label]) => `${ansiYellow(key)} ${theme.fg("dim", label)}`).join("  ");
}

function syntheticConfirmLabel(request: QuestionRequest): string {
	const labels = new Set(request.questions.map((question) => question.header.trim().toLowerCase()));
	for (const candidate of ["Confirm", "Submit", "Review"] as const) {
		if (!labels.has(candidate.toLowerCase())) return candidate;
	}
	return "Submit answers";
}

class CompactLines {
	constructor(private readonly getLines: (width: number) => string[]) {}
	invalidate(): void {}
	render(width: number): string[] {
		return this.getLines(Math.max(1, width)).map((line) => truncateToWidth(line, Math.max(1, width), ""));
	}
}

function compactLines(getLines: (width: number) => string[]): CompactLines {
	return new CompactLines(getLines);
}

function wrapPlain(text: string, width: number, maxLines = 3): string[] {
	const words = text.trim().split(/\s+/).filter(Boolean);
	if (words.length === 0) return [""];
	const lines: string[] = [];
	let current = "";
	for (const word of words) {
		if (visibleWidth(word) > width) {
			if (current) lines.push(current);
			lines.push(truncateToWidth(word, width, ""));
			current = "";
		} else if (!current) {
			current = word;
		} else if (visibleWidth(current) + 1 + visibleWidth(word) <= width) {
			current = `${current} ${word}`;
		} else {
			lines.push(current);
			current = word;
		}
		if (lines.length >= maxLines) break;
	}
	if (current && lines.length < maxLines) lines.push(current);
	if (lines.length === maxLines && words.join(" ").length > lines.join(" ").length) {
		lines[maxLines - 1] = truncateToWidth(`${lines[maxLines - 1]}${glyphs().ellipsis}`, width, "");
	}
	return lines.length > 0 ? lines : [""];
}

function wrapStyled(label: string, text: string, width: number, maxLines = 4): string[] {
	const labelWidth = visibleWidth(label);
	const contentWidth = Math.max(12, width - labelWidth);
	const chunks = wrapPlain(text || "—", contentWidth, maxLines);
	return chunks.map((chunk, index) => `${index === 0 ? label : " ".repeat(labelWidth)}${chunk}`);
}

function formatAnswers(answers: string[] | undefined): string {
	return answers && answers.length > 0 ? answers.join(", ") : "—";
}

function renderCompactAnswerLines(request: QuestionRequest | undefined, answers: string[][], width: number, theme: Theme): string[] {
	const count = Math.max(answers.length, request?.questions.length ?? 0);
	const lines: string[] = [];
	for (let index = 0; index < count; index += 1) {
		const tab = request?.questions[index];
		const labelText = tab?.header ?? `Q${index + 1}`;
		const answerText = formatAnswers(answers[index]);
		const label = `  ${theme.fg("muted", glyphs().bullet.trim())} ${theme.fg("accent", `${labelText}: `)}`;
		lines.push(...wrapStyled(label, theme.fg("text", answerText), width));
	}
	return lines;
}

function answerBranch(theme: Theme, last: boolean): string {
	return theme.fg("muted", `  ${treeGlyph(last ? "└" : "├")}`);
}

function answerStem(theme: Theme, last: boolean): string {
	return theme.fg("muted", last ? "     " : `  ${treeGlyph("│")}`);
}

function optionIcon(selected: boolean, theme: Theme): string {
	return selected ? theme.fg("success", ICONS.checkSquare) : theme.fg("muted", ICONS.square);
}

function renderExpandedOptionLines(tab: QuestionTab | undefined, selectedAnswers: string[] | undefined, stem: string, width: number, theme: Theme): string[] {
	if (!tab) return [];
	const selected = new Set(selectedAnswers ?? []);
	const optionLabels = new Set(tab.options.map((option) => option.label));
	const customAnswers = (selectedAnswers ?? []).filter((answer) => !optionLabels.has(answer));
	const lines = [`${stem}${theme.fg("muted", "Answer:")}`];

	for (const option of tab.options) {
		const isSelected = selected.has(option.label);
		const prefix = `${stem}  ${optionIcon(isSelected, theme)} `;
		const label = isSelected ? theme.fg("success", option.label) : theme.fg("text", option.label);
		const description = option.description ? theme.fg("dim", ` — ${option.description}`) : "";
		lines.push(...wrapStyled(prefix, `${label}${description}`, width, 6));
	}

	if (tab.allowCustom) {
		if (customAnswers.length === 0) {
			const label = theme.fg("text", tab.customLabel);
			lines.push(...wrapStyled(`${stem}  ${optionIcon(false, theme)} `, `${label}${theme.fg("dim", " — custom answer")}`, width, 6));
		} else {
			for (const answer of customAnswers) {
				const label = `${theme.fg("success", `${tab.customLabel}:`)} ${theme.fg("success", answer)}`;
				lines.push(...wrapStyled(`${stem}  ${optionIcon(true, theme)} `, label, width, 6));
			}
		}
	}

	return lines;
}

function renderExpandedAnswerLines(request: QuestionRequest | undefined, answers: string[][], width: number, theme: Theme): string[] {
	const count = Math.max(answers.length, request?.questions.length ?? 0);
	const lines: string[] = [];
	for (let index = 0; index < count; index += 1) {
		const tab = request?.questions[index];
		const last = index === count - 1;
		const category = tab?.header ?? `Question ${index + 1}`;
		const stem = answerStem(theme, last);
		lines.push(`${answerBranch(theme, last)}${theme.fg("accent", theme.bold(category))}`);
		if (tab?.question) {
			lines.push(...wrapStyled(`${stem}${theme.fg("muted", "Question: ")}`, theme.fg("text", tab.question), width, 10));
		}
		lines.push(...renderExpandedOptionLines(tab, answers[index], stem, width, theme));
	}
	return lines;
}

function makeRequestId(): string {
	return `que_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;
}

function asRecord(value: unknown, name: string): Record<string, unknown> {
	if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${name} must be an object`);
	return value as Record<string, unknown>;
}

function readString(value: unknown, fallback: string): string {
	return typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback;
}

function normalizeRequest(payload: unknown): QuestionRequest {
	const input = asRecord(payload, "question request");
	const rawQuestions = input.questions;
	if (!Array.isArray(rawQuestions) || rawQuestions.length === 0) throw new Error("questions must be a non-empty array");

	const questions = rawQuestions.map((rawQuestion, index) => {
		const question = asRecord(rawQuestion, `questions[${index}]`);
		const rawOptions = question.options;
		if (!Array.isArray(rawOptions) || rawOptions.length === 0) {
			throw new Error(`questions[${index}].options must be a non-empty array`);
		}

		const seen = new Set<string>();
		const options = rawOptions.map((rawOption, optionIndex) => {
			const option = asRecord(rawOption, `questions[${index}].options[${optionIndex}]`);
			const label = readString(option.label, "");
			if (!label) throw new Error(`questions[${index}].options[${optionIndex}].label is required`);
			if (seen.has(label)) throw new Error(`Duplicate option label in questions[${index}]: ${label}`);
			seen.add(label);
			return {
				description: typeof option.description === "string" ? option.description : "",
				label,
			};
		});

		return {
			allowCustom: question.allowCustom === true,
			customLabel: readString(question.customLabel, "Type custom answer"),
			customPlaceholder: readString(question.customPlaceholder, "Type your answer, then press enter."),
			header: readString(question.header, `Question ${index + 1}`),
			multiple: question.multiple === true,
			options,
			question: readString(question.question, "Choose an option."),
		};
	});

	const id = readString(input.id, makeRequestId());
	const firstHeader = questions[0]?.header ?? settingString("defaultHeader", "Question");
	return {
		header: readString(input.header ?? input.title, firstHeader),
		id,
		questions,
	};
}

function normalizeAnswers(request: QuestionRequest, rawAnswers: unknown): string[][] {
	if (!Array.isArray(rawAnswers)) throw new Error("answers must be an array of per-tab label arrays");
	if (rawAnswers.length !== request.questions.length) {
		throw new Error(`answers length (${rawAnswers.length}) must match questions length (${request.questions.length})`);
	}

	return request.questions.map((question, index) => {
		const rawTabAnswers = rawAnswers[index];
		if (!Array.isArray(rawTabAnswers)) throw new Error(`answers[${index}] must be an array`);
		const valid = new Set(question.options.map((option) => option.label));
		const unique: string[] = [];
		for (const rawLabel of rawTabAnswers) {
			if (typeof rawLabel !== "string") throw new Error(`answers[${index}] entries must be strings`);
			const label = rawLabel.trim();
			if (!label) continue;
			if (!valid.has(label) && !question.allowCustom) throw new Error(`answers[${index}] contains invalid label: ${label}`);
			if (!unique.includes(label)) unique.push(label);
		}
		if (!question.multiple && unique.length > 1) {
			throw new Error(`answers[${index}] accepts only one label because multiple=false`);
		}
		return unique;
	});
}

function toPendingView(pending: PendingQuestion): PendingQuestionView {
	return {
		openedAt: pending.openedAt,
		request: pending.request,
		requestId: pending.requestId,
	};
}

let emitQuestionOpenedEvent: ((event: QuestionEvent) => void) | undefined;

function notifyQuestionOpened(ctx: ExtensionContext, event: QuestionEvent): void {
	const service = (globalThis as unknown as Record<PropertyKey, unknown>)[QOL_NOTIFICATION_SERVICE_SYMBOL] as QolNotificationService | undefined;
	if (service && typeof service.notifyQuestionOpened === "function") {
		try {
			service.notifyQuestionOpened(ctx, { requestId: event.requestId, request: event.request, source: event.source });
		} catch {
			// Notifications are best-effort; still emit the shared event below.
		}
	}
	emitQuestionOpenedEvent?.(event);
}

class QuestionServiceImpl implements QuestionService {
	private readonly listeners = new Set<(event: QuestionEvent) => void>();
	private readonly pending = new Map<string, PendingQuestion>();

	ask(ctx: ExtensionContext, payload: unknown, source: QuestionSource = "api"): Promise<QuestionResult> {
		attachContext(ctx, this);
		const request = normalizeRequest(payload);
		if (this.pending.has(request.id)) throw new Error(`Question request already pending: ${request.id}`);

		const openedAt = new Date().toISOString();
		let resolvePromise: (result: QuestionResult) => void = () => undefined;
		const promise = new Promise<QuestionResult>((resolve) => {
			resolvePromise = resolve;
		});

		const pending: PendingQuestion = {
			complete: (result, completeSource) => {
				if (!this.pending.has(request.id)) return;
				this.pending.delete(request.id);
				const finalResult = "answers" in result ? { requestId: request.id, answers: result.answers } : { ...result, requestId: request.id };
				resolvePromise(finalResult);
				pending.uiDone?.(finalResult);
				this.publish({
					action: "answers" in finalResult ? "answered" : "rejected",
					closedAt: new Date().toISOString(),
					openedAt,
					requestId: request.id,
					result: finalResult,
					source: completeSource,
				});
			},
			openedAt,
			promise,
			request,
			requestId: request.id,
		};

		this.pending.set(request.id, pending);
		const openedEvent: QuestionEvent = { action: "opened", openedAt, request, requestId: request.id, source };
		notifyQuestionOpened(ctx, openedEvent);
		this.publish(openedEvent);

		if (ctx.hasUI) {
			void openQuestionUi(ctx, pending).catch((error) => {
				pending.complete({ cancelled: true, error: stringifyError(error), requestId: request.id }, "ui_error");
			});
		}

		return promise;
	}

	listPending(): PendingQuestionView[] {
		return [...this.pending.values()].map(toPendingView);
	}

	reply(requestId: string, answers: unknown, source: QuestionSource = "bridge"): boolean {
		if (source === "bridge" && !settingBoolean("bridgeRepliesEnabled", true)) {
			throw new Error("Bridge replies are disabled by pi-questions settings");
		}
		const pending = this.pending.get(requestId);
		if (!pending) throw new Error(`No pending question request: ${requestId}`);
		pending.complete({ answers: normalizeAnswers(pending.request, answers), requestId }, source);
		return true;
	}

	reject(requestId: string, source: QuestionSource = "bridge"): boolean {
		if (source === "bridge" && !settingBoolean("bridgeRepliesEnabled", true)) {
			throw new Error("Bridge replies are disabled by pi-questions settings");
		}
		const pending = this.pending.get(requestId);
		if (!pending) throw new Error(`No pending question request: ${requestId}`);
		pending.complete({ cancelled: true, requestId }, source);
		return true;
	}

	subscribe(listener: (event: QuestionEvent) => void): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}

	shutdown(): void {
		for (const requestId of [...this.pending.keys()]) {
			this.reject(requestId, "shutdown");
		}
	}

	private publish(event: QuestionEvent): void {
		publishQuestionActivity(event);
		for (const listener of this.listeners) {
			try {
				listener(event);
			} catch {
				// Listener failures must not break the question lifecycle.
			}
		}
	}
}

function getService(): QuestionServiceImpl {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const existing = host[SERVICE_SYMBOL];
	if (existing instanceof QuestionServiceImpl) return existing;
	const service = new QuestionServiceImpl();
	host[SERVICE_SYMBOL] = service;
	return service;
}

function attachContext(ctx: ExtensionContext | undefined, service: QuestionService): void {
	if (!ctx) return;
	Object.defineProperty(ctx, "askQuestions", {
		configurable: true,
		value: (payload: unknown) => service.ask(ctx, payload, "api"),
	});
}

async function openQuestionUi(ctx: ExtensionContext, pending: PendingQuestion): Promise<void> {
	if (isVstackModalActive()) {
		ctx.ui.notify("Question queued until the current popup closes.", "info");
		while (isVstackModalActive()) {
			const completed = await Promise.race([pending.promise.then(() => true), sleep(100).then(() => false)]);
			if (completed) return;
		}
	}
	const releaseModalLock = acquireVstackModalLock();
	let restoreHardwareCursor: (() => void) | undefined;
	try {
	const request = pending.request;
	const optionRows = Math.max(1, Math.floor(settingNumber("optionRows", OPTION_ROWS, ctx.cwd)));
	const selections = request.questions.map(() => new Set<string>());
	const customAnswers = request.questions.map(() => "");
	const selectedRows = request.questions.map(() => 0);
	const scrollOffsets = request.questions.map(() => 0);
	const useOverlay = questionRenderMode(ctx.cwd) === "overlay";
	const hasConfirmTab = request.questions.length > 1 || request.questions.some((question) => question.multiple);
	const confirmTabLabel = syntheticConfirmLabel(request);
	const tabCount = request.questions.length + (hasConfirmTab ? 1 : 0);
	let activeTab = 0;
	let startCustomInput: (() => void) | undefined;

	const rowCount = (question: QuestionTab): number => question.options.length + (question.allowCustom ? 1 : 0);
	const visibleRowsFor = (index: number): number => {
		const count = rowCount(request.questions[index]);
		return useOverlay ? optionRows : Math.max(1, Math.min(optionRows, count));
	};
	const isCustomRow = (question: QuestionTab, index: number): boolean => question.allowCustom && index === question.options.length;

	const clamp = () => {
		activeTab = Math.max(0, Math.min(activeTab, tabCount - 1));
		if (activeTab >= request.questions.length) return;
		const optionCount = rowCount(request.questions[activeTab]);
		const visibleRows = visibleRowsFor(activeTab);
		selectedRows[activeTab] = Math.max(0, Math.min(selectedRows[activeTab] ?? 0, Math.max(0, optionCount - 1)));
		if (selectedRows[activeTab] < scrollOffsets[activeTab]) scrollOffsets[activeTab] = selectedRows[activeTab];
		if (selectedRows[activeTab] >= scrollOffsets[activeTab] + visibleRows) {
			scrollOffsets[activeTab] = selectedRows[activeTab] - visibleRows + 1;
		}
		scrollOffsets[activeTab] = Math.max(0, Math.min(scrollOffsets[activeTab], Math.max(0, optionCount - visibleRows)));
	};

	const answers = () => request.questions.map((question, index) => {
		const labels = [...selections[index]];
		const custom = customAnswers[index].trim();
		if (question.multiple) return custom ? [...labels, custom] : labels;
		return custom ? [custom] : labels.slice(0, 1);
	});
	const submit = () => pending.complete({ answers: answers(), requestId: request.id }, "ui");
	const advanceOrSubmit = () => {
		if (!hasConfirmTab && activeTab >= request.questions.length - 1) {
			submit();
			return;
		}
		activeTab = Math.min(activeTab + 1, tabCount - 1);
		clamp();
		pending.requestRender?.();
	};
	const chooseSingle = () => {
		const question = request.questions[activeTab];
		if (isCustomRow(question, selectedRows[activeTab])) {
			startCustomInput?.();
			return;
		}
		const option = question.options[selectedRows[activeTab]];
		if (!option) return;
		customAnswers[activeTab] = "";
		selections[activeTab].clear();
		selections[activeTab].add(option.label);
		advanceOrSubmit();
	};
	const toggleMulti = () => {
		const question = request.questions[activeTab];
		if (isCustomRow(question, selectedRows[activeTab])) {
			startCustomInput?.();
			return;
		}
		const option = question.options[selectedRows[activeTab]];
		if (!option) return;
		const selected = selections[activeTab];
		if (selected.has(option.label)) selected.delete(option.label);
		else selected.add(option.label);
		pending.requestRender?.();
	};

	await ctx.ui.custom<QuestionResult>(
		(tui, theme, _keybindings, done) => {
			pending.uiDone = done;
			pending.requestRender = () => tui.requestRender();
			let inputMode = false;
			const previousHardwareCursor = tui.getShowHardwareCursor();
			tui.setShowHardwareCursor(true);
			restoreHardwareCursor = () => tui.setShowHardwareCursor(previousHardwareCursor);

			const input = new Input();
			const refresh = () => tui.requestRender();
			const isConfirmTab = () => hasConfirmTab && activeTab === request.questions.length;

			startCustomInput = () => {
				inputMode = true;
				input.setValue(customAnswers[activeTab]);
				refresh();
			};

			input.onSubmit = (value) => {
				const trimmed = value.trim();
				if (!trimmed) {
					customAnswers[activeTab] = "";
					inputMode = false;
					input.setValue("");
					refresh();
					return;
				}
				customAnswers[activeTab] = trimmed;
				inputMode = false;
				input.setValue("");
				if (request.questions[activeTab].multiple) {
					refresh();
					return;
				}
				selections[activeTab].clear();
				advanceOrSubmit();
			};

			input.onEscape = () => {
				inputMode = false;
				input.setValue("");
				refresh();
			};

			const renderTabs = (width: number): string => {
				const labels = request.questions.map((question) => question.header);
				if (hasConfirmTab) labels.push(confirmTabLabel);
				const parts = labels.map((labelText, index) => {
					const label = ` ${labelText} `;
					if (index === activeTab) return theme.fg("accent", theme.inverse(theme.bold(label)));
					return theme.fg("muted", label);
				});
				return truncateToWidth(parts.join("  "), width, "");
			};

			const renderOption = (question: QuestionTab, index: number, width: number): string[] => {
				const custom = isCustomRow(question, index);
				const option = custom ? undefined : question.options[index];
				if (!custom && !option) return [panelLine("", width)];
				const isCursor = index === selectedRows[activeTab];
				const customValue = customAnswers[activeTab].trim();
				const isChecked = custom ? customValue.length > 0 : selections[activeTab].has(option!.label);
				const prefixText = question.multiple
					? `${index + 1}. ${isChecked ? "[x]" : "[ ]"} `
					: `${index + 1}. `;
				const prefix = theme.fg(isCursor ? "accent" : isChecked ? "success" : "muted", prefixText);
				const prefixWidth = visibleWidth(prefixText);
				const rawLabel = custom && customValue ? `${question.customLabel}: ${customValue}` : custom ? question.customLabel : option!.label;
				const rawDesc = custom
					? inputMode && isCursor ? "" : customValue ? "edit custom response" : question.customPlaceholder
					: option!.description;
				const styleLabel = (text: string) => theme.fg(isCursor ? "accent" : isChecked ? "success" : "text", text);
				const labelWidth = Math.max(1, width - prefixWidth);
				const labelLines = wrapPlain(rawLabel, labelWidth, 4);
				const descIndent = " ".repeat(prefixWidth);
				const descWidth = Math.max(1, width - prefixWidth);
				const descLines = rawDesc ? wrapPlain(rawDesc, descWidth, 8) : [];
				const out: string[] = [];

				labelLines.forEach((line, i) => {
					const content = i === 0 ? `${prefix}${styleLabel(line)}` : `${descIndent}${styleLabel(line)}`;
					out.push(i === 0 && isCursor ? selectedLine(theme, content, width) : panelLine(content, width));
				});
				for (const line of descLines) {
					out.push(panelLine(`${descIndent}${theme.fg("dim", line)}`, width));
				}
				if (custom && inputMode && isCursor) {
					for (const line of input.render(Math.max(1, width - prefixWidth))) {
						out.push(panelLine(`${descIndent}${line}`, width));
					}
				}
				return out;
			};

			const renderConfirm = (width: number): string[] => {
				const currentAnswers = answers();
				const lines = [panelLine(theme.fg("text", "Review answers, then press enter to submit."), width), panelLine("", width)];
				for (const [index, question] of request.questions.entries()) {
					const answerText = formatAnswers(currentAnswers[index]);
					const label = `  ${theme.fg("muted", glyphs().bullet.trim())} ${theme.fg("accent", `${question.header}: `)}`;
					lines.push(...wrapStyled(label, theme.fg("text", answerText), width, 4).map((line) => panelLine(line, width)));
				}
				return lines;
			};

			const renderFooter = (question: QuestionTab | undefined): string => {
				if (!question) return footerHint(theme, [["⇆", "tab"], ["enter", "submit"], ["esc", "dismiss"]]);
				return footerHint(theme, [["⇆", "tab"], ["↑↓", "select"], ["enter", question.multiple ? "toggle" : "confirm"], ["esc", "dismiss"]]);
			};

			const render = (width: number): string[] => {
				clamp();
				const innerWidth = popupContentWidth(width);
				const question = isConfirmTab() ? undefined : request.questions[activeTab];
				const lines: string[] = [];

				if (tabCount > 1) {
					lines.push(panelLine("", innerWidth));
				}
				lines.push(panelLine(renderTabs(innerWidth), innerWidth));
				lines.push(panelLine("", innerWidth));

				if (!question) {
					lines.push(...renderConfirm(innerWidth));
				} else {
					for (const line of wrapPlain(question.question, innerWidth, 4)) {
						lines.push(panelLine(theme.fg("text", line), innerWidth));
					}
					lines.push(panelLine("", innerWidth));

					const start = scrollOffsets[activeTab];
					const visibleRows = visibleRowsFor(activeTab);
					const totalRows = rowCount(question);
					const end = Math.min(totalRows, start + visibleRows);
					let renderedRowLines = 0;
					for (let index = start; index < end; index += 1) {
						const rowLines = renderOption(question, index, innerWidth);
						for (const line of rowLines) lines.push(line);
						renderedRowLines += rowLines.length;
					}
					if (useOverlay) {
						for (let i = renderedRowLines; i < visibleRows; i += 1) lines.push(panelLine("", innerWidth));
					}
				}

				lines.push(panelLine("", innerWidth));
				lines.push(panelLine(renderFooter(question), innerWidth));

				return framePopup(lines, width, theme, request.header, "");
			};

			const component: Focusable & { handleInput(data: string): void; invalidate(): void; render(width: number): string[] } = {
				get focused() {
					return input.focused;
				},
				set focused(value: boolean) {
					input.focused = value;
				},
				handleInput(data: string) {
					if (inputMode) {
						if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
							inputMode = false;
							input.setValue("");
							refresh();
							return;
						}
						input.handleInput(data);
						refresh();
						return;
					}
					if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
						pending.complete({ cancelled: true, requestId: request.id }, "ui");
						return;
					}
					if (matchesKey(data, "left") || matchesKey(data, "shift+tab")) {
						activeTab = (activeTab - 1 + tabCount) % tabCount;
						clamp();
						refresh();
						return;
					}
					if (matchesKey(data, "right") || matchesKey(data, "tab")) {
						activeTab = (activeTab + 1) % tabCount;
						clamp();
						refresh();
						return;
					}
					if (isConfirmTab()) {
						if (matchesKey(data, "return") || matchesKey(data, "enter")) submit();
						return;
					}

					const question = request.questions[activeTab];
					if (matchesKey(data, "up")) {
						selectedRows[activeTab] -= 1;
						clamp();
						refresh();
						return;
					}
					if (matchesKey(data, "down")) {
						selectedRows[activeTab] += 1;
						clamp();
						refresh();
						return;
					}
					if (matchesKey(data, "-") || matchesKey(data, "pageup")) {
						selectedRows[activeTab] -= visibleRowsFor(activeTab);
						clamp();
						refresh();
						return;
					}
					if (matchesKey(data, "=") || matchesKey(data, "pagedown")) {
						selectedRows[activeTab] += visibleRowsFor(activeTab);
						clamp();
						refresh();
						return;
					}
					if (matchesKey(data, "return") || matchesKey(data, "enter")) {
						if (question.multiple) toggleMulti();
						else chooseSingle();
						return;
					}
					if (data === " " && (question.multiple || isCustomRow(question, selectedRows[activeTab]))) {
						toggleMulti();
					}
				},
				invalidate() {},
				render,
			};

			return component;
		},
		useOverlay
			? {
				overlay: true,
				overlayOptions: {
					anchor: "center",
					maxHeight: settingString("popupMaxHeight", POPUP_MAX_HEIGHT, ctx.cwd),
					width: Math.max(40, Math.floor(settingNumber("popupWidth", POPUP_WIDTH, ctx.cwd))),
				},
			}
			: undefined,
	);
	} finally {
		restoreHardwareCursor?.();
		releaseModalLock();
	}
}

function stringifyError(error: unknown): string {
	if (error instanceof Error) return `${error.name}: ${error.message}`;
	return String(error);
}

export default function questions(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;
	if (!settingBoolean("enabled", true)) return;

	const service = getService();
	emitQuestionOpenedEvent = (event) => pi.events.emit(QUESTION_OPENED_EVENT, { requestId: event.requestId, request: event.request, source: event.source });
	let activeCtx: ExtensionContext | undefined;

	pi.on("session_start", (_event, ctx) => {
		activeCtx = ctx;
		attachContext(ctx, service);
	});

	pi.on("session_shutdown", () => {
		service.shutdown();
		emitQuestionOpenedEvent = undefined;
	});

	pi.registerTool({
		renderShell: "self",
		name: "question",
		label: "Question",
		description: `Ask the user one or more structured multiple-choice questions, optionally with free-form custom answers. Returns selected labels/text per tab. Output is truncated to ${DEFAULT_MAX_LINES} lines or ${formatSize(DEFAULT_MAX_BYTES)} if a free-form answer is very large, with the full JSON saved to a temp file.`,
		promptSnippet: "Ask the user structured multiple-choice questions and return selected labels or allowed custom text.",
		promptGuidelines: [
			"Use question when you need explicit user clarification before proceeding; keep options concise and mutually exclusive unless multiple=true.",
			"When using question, provide a clear header, question text, and descriptive option labels.",
			"Set question allowCustom=true only when an option list may not cover the user's answer; custom text is returned in that tab's answers array.",
			"Do not add a final Confirm, Submit, Review, or Done tab; pi-questions adds its own submit tab when needed.",
		],
		parameters: QUESTION_TOOL_PARAMETERS as never,
		async execute(toolCallId, params, _signal, _onUpdate, ctx): Promise<AgentToolResult<QuestionResult>> {
			const runCtx = ctx ?? activeCtx;
			if (!runCtx) {
				const result: QuestionCancelResult = { cancelled: true, error: "No active Pi context", requestId: "que_unavailable" };
				return makeQuestionToolResult(toolCallId, result);
			}
			if (!runCtx.hasUI) {
				const result: QuestionCancelResult = { cancelled: true, error: "No interactive UI available for question prompt", requestId: typeof params.id === "string" ? params.id : "que_unavailable" };
				return makeQuestionToolResult(toolCallId, result);
			}
			activeCtx = runCtx;
			attachContext(runCtx, service);
			const result = await service.ask(runCtx, params, "tool");
			return makeQuestionToolResult(toolCallId, result);
		},
		renderCall() {
			return compactLines(() => []);
		},
		renderResult(result, options, theme, context) {
			const details = result.details as QuestionResult | undefined;
			return compactLines((width: number) => {
				const request = (() => {
					try { return normalizeRequest(context?.args); }
					catch { return undefined; }
				})();
				const title = request?.header ?? "Question";
				const prefix = details && "answers" in details ? theme.fg("success", glyphs().bullet) : theme.fg("warning", glyphs().bullet);
				const state = details && "answers" in details ? theme.fg("success", "answered") : theme.fg("warning", "cancelled");
				const expandHint = details && "answers" in details && !options?.expanded ? theme.fg("dim", `${glyphs().dot}ctrl+o to expand`) : "";
				const head = `${prefix}${theme.fg("toolTitle", theme.bold("Question"))} ${state}${title ? ` ${theme.fg("muted", "—")} ${theme.fg("text", title)}` : ""}${expandHint}`;
				if (!details || !("answers" in details)) return [head];

				const lines = [head];
				lines.push(...(options?.expanded
					? renderExpandedAnswerLines(request, details.answers, width, theme)
					: renderCompactAnswerLines(request, details.answers, width, theme)));
				const fullOutputPath = (details as QuestionToolDetails).fullOutputPath;
				if (fullOutputPath) lines.push(theme.fg("dim", `  Full output: ${fullOutputPath}`));
				return lines;
			});
		},
	});
}
