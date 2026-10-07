import type { ExtensionAPI, ExtensionContext, ToolResultEventResult } from "@earendil-works/pi-coding-agent";
import { randomUUID } from "node:crypto";
import { type FileHandle, open, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

import { openLaneDir, pruneLanes } from "../scripts/lane-retention.js";
import { installSettingsCacheRefresh, piUserDir, readPackageConfig, recordProjectTrust } from "./package-config.js";

const INSTALL_SYMBOL = Symbol.for("kendex.pi-output-policy.installed");
const CONFIG_ID = "@vanillagreen/pi-output-policy";
const DEFAULT_MINIMIZER_MAX_CAPTURE_BYTES = 1024 * 1024;
const DEFAULT_SHELL_MINIMIZER_ENABLED = true;
const DEFAULT_MODEL_OUTPUT_MAX_CHARS = 96_000;
const DEFAULT_MODEL_OUTPUT_MAX_CONSECUTIVE_REPEATS = 24;
const DEFAULT_MODEL_OUTPUT_MIN_REPEAT_BLOCK_CHARS = 32;
const DEFAULT_MODEL_OUTPUT_MIN_REPEATED_CHARS = 1_536;
const MAX_PENDING_MODEL_OUTPUT_CHARS = 16_384;

// Tools whose `details` carry state-bearing data (task lists, background-task
// snapshots, subagent run records). Sanitization would corrupt restore
// semantics, so balanced/compact modes skip these by default. Sidecars/state
// files are the canonical store; the inline details just point at them.
const DEFAULT_SANITIZE_EXCEPT_TOOLS = [
	"tasks_write",
	"tasks_read",
	"bg_task",
	"bg_status",
	"subagent",
	"subagent_run",
	"stop_subagent",
	"steer_subagent",
	"get_subagent_result",
];

export type PolicyMode = "compat" | "balanced" | "compact";

interface ModeDefaults {
	spillThresholdKb: number;
	inlineTailKb: number;
	inlineTailLines: number;
	maxTextBlockKb: number;
	maxLineCount: number;
	maxLineWidth: number;
	sanitizeDetails: boolean;
}

// `compat` is the pre-1.1 behavior — UI-safety sized only. `balanced` (default)
// is sized so a single non-read/non-mutation tool result cannot push more than
// ~24 KB into the model transcript / session JSONL. `compact` is for very long
// runs that need to stretch the request buffer further.
const MODE_DEFAULTS: Record<PolicyMode, ModeDefaults> = {
	compat: {
		spillThresholdKb: 200,
		inlineTailKb: 100,
		inlineTailLines: 2_000,
		maxTextBlockKb: 200,
		maxLineCount: 8_000,
		maxLineWidth: 20_000,
		sanitizeDetails: false,
	},
	balanced: {
		spillThresholdKb: 48,
		inlineTailKb: 16,
		inlineTailLines: 400,
		maxTextBlockKb: 24,
		maxLineCount: 400,
		maxLineWidth: 3_000,
		sanitizeDetails: true,
	},
	compact: {
		spillThresholdKb: 16,
		inlineTailKb: 6,
		inlineTailLines: 200,
		maxTextBlockKb: 8,
		maxLineCount: 200,
		maxLineWidth: 2_000,
		sanitizeDetails: true,
	},
};

const DEFAULT_POLICY_MODE: PolicyMode = "balanced";

type kendexConfig = Record<string, unknown>;
type Direction = "head" | "tail";

export interface TruncationMeta {
	direction: Direction;
	truncated: boolean;
	reason: string;
	totalBytes: number;
	totalLines: number;
	shownBytes: number;
	shownLines: number;
	shownRange: string;
	artifactPath?: string;
	artifactError?: string;
	minimized?: boolean;
	minimizedDroppedLines?: number;
	policyMode?: PolicyMode;
	savedBytes?: number;
	turnSavedBytes?: number;
	sessionSavedBytes?: number;
}

interface SessionCounters {
	turnSavedBytes: number;
	sessionSavedBytes: number;
}

export interface ModelOutputGuardState {
	aborted: boolean;
	consecutiveRepeats: number;
	lastBlock?: string;
	pending: string;
	repeatedChars: number;
	totalChars: number;
}

export interface ModelOutputGuardOptions {
	maxChars: number;
	maxConsecutiveRepeats: number;
	minRepeatBlockChars: number;
	minRepeatedChars: number;
	repetitionEnabled?: boolean;
}

export interface ModelOutputGuardDetection {
	block?: string;
	consecutiveRepeats?: number;
	reason: "max-chars" | "repetition";
	totalChars: number;
}

interface ModelOutputGuardConfigSnapshot {
	enabled: boolean;
	options: ModelOutputGuardOptions;
}

const SESSION_COUNTERS = new Map<string, SessionCounters>();

function counters(sessionId: string): SessionCounters {
	let entry = SESSION_COUNTERS.get(sessionId);
	if (!entry) {
		entry = { sessionSavedBytes: 0, turnSavedBytes: 0 };
		SESSION_COUNTERS.set(sessionId, entry);
	}
	return entry;
}

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

const SESSION_FOLDER = "pi-output-policy";

function artifactDir(ctx: ExtensionContext): string {
	return join(piUserDir(), "kendex", "sessions", safeFileName(sessionIdForContext(ctx)), SESSION_FOLDER, "artifacts");
}

function readkendexConfig(cwd?: string): kendexConfig {
	return readPackageConfig(CONFIG_ID, cwd) as kendexConfig;
}

function configNumber(config: kendexConfig, key: string, fallback: number): number {
	const value = config[key];
	const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN;
	return Number.isFinite(parsed) ? parsed : fallback;
}

function configBoolean(config: kendexConfig, key: string, fallback: boolean): boolean {
	const value = config[key];
	return typeof value === "boolean" ? value : fallback;
}

function configString(config: kendexConfig, key: string, fallback: string): string {
	const value = config[key];
	return typeof value === "string" ? value : fallback;
}

function configList(config: kendexConfig, key: string): string[] {
	return configString(config, key, "")
		.split(",")
		.map((part) => part.trim().toLowerCase())
		.filter(Boolean);
}

function policyModeFrom(config: kendexConfig): PolicyMode {
	const raw = configString(config, "policyMode", DEFAULT_POLICY_MODE).toLowerCase().trim();
	if (raw === "compat" || raw === "balanced" || raw === "compact") return raw;
	return DEFAULT_POLICY_MODE;
}

export function resolvePolicyMode(cwd?: string): PolicyMode {
	return policyModeFrom(readkendexConfig(cwd));
}

/** `config` is the settings snapshot a tool-result handler already read, so
 * one result reads the settings files once. */
export function isSanitizeExceptTool(toolName: string, cwd?: string, config: kendexConfig = readkendexConfig(cwd)): boolean {
	const name = toolName.toLowerCase();
	const configured = configList(config, "sanitizeDetails.exceptTools");
	const allowlist = configured.length > 0 ? configured : DEFAULT_SANITIZE_EXCEPT_TOOLS;
	return allowlist.includes(name) || allowlist.some((entry) => entry && name.endsWith(`.${entry}`));
}

export function __resetSessionCountersForTests(): void {
	SESSION_COUNTERS.clear();
}

export function createModelOutputGuardState(): ModelOutputGuardState {
	return {
		aborted: false,
		consecutiveRepeats: 0,
		pending: "",
		repeatedChars: 0,
		totalChars: 0,
	};
}

function normalizedRepeatBlock(line: string): string {
	return line.trim().replace(/\s+/g, " ");
}

function isCommonMarkFenceLine(line: string): boolean {
	// CommonMark permits up to three leading spaces and an optional info string.
	// Backtick-fence info strings cannot contain backticks; tilde-fence info
	// strings have no equivalent character restriction.
	const match = /^(?: {0,3})(`{3,}|~{3,})(.*)$/.exec(line);
	if (!match) return false;
	return match[1].startsWith("~") || !match[2].includes("`");
}

function isIgnorableRepeatSyntaxBlock(line: string): boolean {
	// Preserve a substantial repetition streak only across syntax-only lines
	// produced by common model/tool protocols. Short prose, labels, values, and
	// headings are semantic content and must break the streak.
	const block = normalizedRepeatBlock(line);
	return /^<\/?[A-Za-z][A-Za-z0-9:._-]*(?:\s+[^<>]*)?\/?>$/.test(block)
		|| isCommonMarkFenceLine(line)
		|| /^(?:(?:-\s*){3,}|(?:\*\s*){3,}|(?:_\s*){3,})$/.test(block);
}

function resetModelOutputRepeatStreak(state: ModelOutputGuardState): void {
	state.lastBlock = undefined;
	state.consecutiveRepeats = 0;
	state.repeatedChars = 0;
}

export function inspectModelOutputDelta(
	state: ModelOutputGuardState,
	delta: string,
	options: ModelOutputGuardOptions,
): ModelOutputGuardDetection | undefined {
	if (state.aborted || delta.length === 0) return undefined;
	state.totalChars += delta.length;
	if (options.maxChars > 0 && state.totalChars >= options.maxChars) {
		return { reason: "max-chars", totalChars: state.totalChars };
	}

	if (options.repetitionEnabled === false) return undefined;
	state.pending = `${state.pending}${delta.replace(/\r\n?/g, "\n")}`;
	let newline = state.pending.indexOf("\n");
	while (newline >= 0) {
		const line = state.pending.slice(0, newline);
		const block = normalizedRepeatBlock(line);
		state.pending = state.pending.slice(newline + 1);
		newline = state.pending.indexOf("\n");
		if (!block) continue;
		if (isIgnorableRepeatSyntaxBlock(line)) continue;
		if (block.length < options.minRepeatBlockChars) {
			resetModelOutputRepeatStreak(state);
			continue;
		}
		if (block === state.lastBlock) {
			state.consecutiveRepeats += 1;
			state.repeatedChars += block.length;
		} else {
			state.lastBlock = block;
			state.consecutiveRepeats = 1;
			state.repeatedChars = block.length;
		}
		if (
			state.consecutiveRepeats >= options.maxConsecutiveRepeats
			&& state.repeatedChars >= options.minRepeatedChars
		) {
			return {
				block,
				consecutiveRepeats: state.consecutiveRepeats,
				reason: "repetition",
				totalChars: state.totalChars,
			};
		}
	}

	if (state.pending.length > MAX_PENDING_MODEL_OUTPUT_CHARS) {
		state.pending = state.pending.slice(-MAX_PENDING_MODEL_OUTPUT_CHARS);
	}
	return undefined;
}

function modelOutputGuardConfigSnapshot(cwd?: string): ModelOutputGuardConfigSnapshot {
	const config = readkendexConfig(cwd);
	return {
		enabled: configBoolean(config, "enabled", true) && configBoolean(config, "modelOutputGuard.enabled", true),
		options: {
			maxChars: Math.max(0, Math.floor(configNumber(config, "modelOutputGuard.maxChars", DEFAULT_MODEL_OUTPUT_MAX_CHARS))),
			maxConsecutiveRepeats: Math.max(2, Math.floor(configNumber(config, "modelOutputGuard.maxConsecutiveRepeats", DEFAULT_MODEL_OUTPUT_MAX_CONSECUTIVE_REPEATS))),
			repetitionEnabled: configBoolean(config, "modelOutputGuard.repetition.enabled", true),
			minRepeatBlockChars: Math.max(8, Math.floor(configNumber(config, "modelOutputGuard.minRepeatBlockChars", DEFAULT_MODEL_OUTPUT_MIN_REPEAT_BLOCK_CHARS))),
			minRepeatedChars: Math.max(64, Math.floor(configNumber(config, "modelOutputGuard.minRepeatedChars", DEFAULT_MODEL_OUTPUT_MIN_REPEATED_CHARS))),
		},
	};
}

function assistantStreamDelta(event: any): string | undefined {
	const update = event?.assistantMessageEvent ?? event;
	if (!update || typeof update.delta !== "string") return undefined;
	if (!["text", "text_delta", "thinking", "thinking_delta", "toolcall_delta"].includes(String(update.type ?? ""))) return undefined;
	return update.delta;
}

function byteLength(text: string): number {
	return Buffer.byteLength(text, "utf8");
}

function formatSize(bytes: number): string {
	if (bytes < 1024) return `${bytes}B`;
	if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(bytes >= 10 * 1024 ? 0 : 1)}KB`;
	return `${(bytes / (1024 * 1024)).toFixed(bytes >= 10 * 1024 * 1024 ? 0 : 1)}MB`;
}

function isReadTool(toolName: string): boolean {
	const name = toolName.toLowerCase();
	return name === "read" || name.endsWith(".read");
}

function isMutationTool(toolName: string): boolean {
	const name = toolName.toLowerCase();
	return name === "edit" || name === "write" || name.endsWith(".edit") || name.endsWith(".write");
}

function shouldBypassTool(toolName: string, config: kendexConfig): boolean {
	if (isReadTool(toolName) && !configBoolean(config, "truncateReadOutputs", false)) return true;
	if (isMutationTool(toolName) && !configBoolean(config, "truncateMutationOutputs", false)) return true;
	return false;
}

function directionForTool(toolName: string): Direction {
	const name = toolName.toLowerCase();
	if (["bash", "python", "bg_task", "bg_status"].some((prefix) => name.includes(prefix))) return "tail";
	return "head";
}

function commandFamily(command: string): string {
	const trimmed = command.trim();
	const first = trimmed.split(/\s+/)[0] ?? "";
	return basename(first).toLowerCase();
}

function shouldMinimize(command: string, config: kendexConfig): boolean {
	if (!configBoolean(config, "shellMinimizer.enabled", DEFAULT_SHELL_MINIMIZER_ENABLED)) return false;
	const family = commandFamily(command);
	const defaults = ["git", "npm", "pnpm", "yarn", "bun", "cargo", "pytest", "go", "mvn", "gradle"];
	const only = configList(config, "shellMinimizer.only");
	const except = configList(config, "shellMinimizer.except");
	if (except.includes(family)) return false;
	return only.length > 0 ? only.includes(family) : defaults.includes(family);
}

const IMPORTANT_SHELL_LINE = /(error|failed|failure|panic|warning|warn|exception|traceback|summary|finished|test result|\bpass(ed)?\b|\bfail(ed)?\b|\bok\b|exit code|aborted|denied)/i;

/** `config` is the settings snapshot a tool-result handler already read. */
export function minimizeShellOutput(text: string, command: string, cwd?: string, config: kendexConfig = readkendexConfig(cwd)): { text: string; dropped: number } {
	if (!shouldMinimize(command, config)) return { dropped: 0, text };
	if (byteLength(text) > configNumber(config, "shellMinimizer.maxCaptureBytes", DEFAULT_MINIMIZER_MAX_CAPTURE_BYTES)) {
		return { dropped: 0, text };
	}
	const total = countLines(text);
	const compact: string[] = [];
	let dropped = 0;
	let gap = 0;
	let i = 0;
	eachLine(text, (start, end) => {
		const line = text.slice(start, end);
		if (i < 20 || i >= total - 80 || IMPORTANT_SHELL_LINE.test(line)) {
			if (gap > 0) compact.push(minimizedNotice(gap));
			gap = 0;
			compact.push(line);
		} else {
			dropped += 1;
			gap += 1;
		}
		i += 1;
	});
	if (gap > 0) compact.push(minimizedNotice(gap));
	return dropped > 0 ? { dropped, text: compact.join("\n") } : { dropped: 0, text };
}

// Lines are what `/\r?\n/` splits: a `\r` before a `\n` belongs to the
// terminator, and a trailing `\r` with no `\n` after it belongs to the line.
// `eachLine` walks those boundaries forward and the tail selection walks them
// backward, both by newline position, so a large result is never split into a
// whole-output array. The truncation preview slices only the lines it keeps;
// the shell minimizer slices each line of its input, which
// `shellMinimizer.maxCaptureBytes` bounds.

function contentEnd(text: string, start: number, newline: number): number {
	return newline > start && text.charCodeAt(newline - 1) === 13 ? newline - 1 : newline;
}

/** Visits each line's content span, first to last, and stops early when
 * `visit` returns false. */
function eachLine(text: string, visit: (start: number, end: number) => boolean | void): void {
	for (let start = 0; ;) {
		const nl = text.indexOf("\n", start);
		if (visit(start, nl < 0 ? text.length : contentEnd(text, start, nl)) === false || nl < 0) return;
		start = nl + 1;
	}
}

function countLines(text: string): number {
	let lines = 1;
	for (let nl = text.indexOf("\n"); nl >= 0; nl = text.indexOf("\n", nl + 1)) lines += 1;
	return lines;
}

interface TextStats {
	bytes: number;
	lines: number;
	overWidth: boolean;
}

/** `widthLimit` is undefined when the text is already over a byte limit: the
 * result is cut either way, so only its line count is still needed. */
function textStats(text: string, bytes: number, widthLimit: number | undefined): TextStats {
	if (widthLimit === undefined) return { bytes, lines: countLines(text), overWidth: false };
	let lines = 0;
	let overWidth = false;
	eachLine(text, (start, end) => {
		lines += 1;
		overWidth ||= end - start > widthLimit;
	});
	return { bytes, lines, overWidth };
}

function widthSafeLine(text: string, start: number, end: number, maxWidth: number): string {
	return end - start <= maxWidth ? text.slice(start, end) : `${text.slice(start, start + Math.max(0, maxWidth - 1))}…`;
}

const UTF8 = new TextEncoder();

/** The longest prefix of `text` whose UTF-8 encoding fits `maxBytes`, never
 * splitting a character. */
function prefixWithinBytes(text: string, maxBytes: number): string {
	return text.slice(0, UTF8.encodeInto(text, new Uint8Array(Math.max(0, maxBytes))).read);
}

/** What is left of one result's inline allowance. `started` is whether any line
 * of the result has been kept, so only the result's first line is ever cut to
 * fit rather than dropped. */
interface InlineBudget {
	bytes: number;
	lines: number;
	started: boolean;
}

/** Keeps `line` if the budget holds it plus its newline. The first line that
 * does not fit ends the selection for the whole result, so what is shown stays
 * one contiguous run of lines. */
function takeLine(picked: string[], line: string, budget: InlineBudget): boolean {
	const cost = byteLength(line) + 1;
	if (cost <= budget.bytes) {
		picked.push(line);
		budget.bytes -= cost;
		budget.lines -= 1;
		budget.started = true;
		return true;
	}
	if (!budget.started && budget.bytes > 1) picked.push(prefixWithinBytes(line, budget.bytes - 1));
	budget.started = true;
	budget.lines = 0;
	return false;
}

/** The head or tail lines of `text` the budget holds, in text order. Only the
 * kept lines are sliced; the rest of the text is never copied. */
function selectLines(text: string, direction: Direction, budget: InlineBudget, maxLineWidth: number): string[] {
	const picked: string[] = [];
	if (direction === "head") {
		eachLine(text, (start, end) => budget.lines > 0 && takeLine(picked, widthSafeLine(text, start, end, maxLineWidth), budget));
		return picked;
	}
	// `stop` is the index of the newline that ends the current line, or the text's end.
	let stop = text.length;
	while (budget.lines > 0) {
		const nl = stop === 0 ? -1 : text.lastIndexOf("\n", stop - 1);
		const start = nl + 1;
		const end = stop === text.length ? stop : contentEnd(text, start, stop);
		if (!takeLine(picked, widthSafeLine(text, start, end, maxLineWidth), budget) || nl < 0) break;
		stop = nl;
	}
	return picked.reverse();
}

interface TextPolicy {
	mode: PolicyMode;
	maxLineWidth: number;
	maxLineCount: number;
	spillThresholdBytes: number;
	maxTextBytes: number;
	inlineTailBytes: number;
	inlineTailLines: number;
	preserveFullOutput: boolean;
}

type NumericModeKey = Exclude<keyof ModeDefaults, "sanitizeDetails">;

function textPolicy(config: kendexConfig): TextPolicy {
	const mode = policyModeFrom(config);
	const defaults = MODE_DEFAULTS[mode];
	const count = (key: NumericModeKey, floor: number) => Math.max(floor, Math.floor(configNumber(config, key, defaults[key])));
	const kilobytes = (key: NumericModeKey) => Math.max(1, Math.floor(configNumber(config, key, defaults[key]) * 1024));
	return {
		inlineTailBytes: kilobytes("inlineTailKb"),
		inlineTailLines: count("inlineTailLines", MIN_LINE_LIMIT),
		maxLineCount: count("maxLineCount", MIN_LINE_LIMIT),
		maxLineWidth: count("maxLineWidth", 80),
		maxTextBytes: kilobytes("maxTextBlockKb"),
		mode,
		preserveFullOutput: configBoolean(config, "preserveFullOutput", true),
		spillThresholdBytes: kilobytes("spillThresholdKb"),
	};
}

// Artifact writes run off Pi's thread. The slot count bounds how many full
// outputs are being written at once when tool results overlap. Each write
// encodes into one fixed buffer and writes it out before encoding more, so a
// write holds one buffer beside the text Pi already holds, never an encoded
// copy of the whole output.
const ARTIFACT_WRITE_SLOTS = 2;
const ARTIFACT_BUFFER_BYTES = 64 * 1024;
let artifactWritesActive = 0;
const artifactWriteQueue: Array<() => void> = [];

async function acquireArtifactWriteSlot(): Promise<void> {
	if (artifactWritesActive < ARTIFACT_WRITE_SLOTS) {
		artifactWritesActive += 1;
		return;
	}
	// A released slot passes straight to the next waiter, so the count holds.
	await new Promise<void>((grant) => artifactWriteQueue.push(grant));
}

function releaseArtifactWriteSlot(): void {
	const next = artifactWriteQueue.shift();
	if (next) next();
	else artifactWritesActive -= 1;
}

async function writeBytes(file: FileHandle, bytes: Uint8Array): Promise<void> {
	for (let offset = 0; offset < bytes.length;) {
		const { bytesWritten } = await file.write(bytes, offset, bytes.length - offset);
		if (bytesWritten <= 0) throw new Error(`artifact-write=no-progress offset=${offset}`);
		offset += bytesWritten;
	}
}

/** Writes the texts joined by newlines, as the preview's line numbers count them. */
async function writeTexts(path: string, texts: readonly string[]): Promise<void> {
	const file = await open(path, "wx", 0o600);
	const buffer = new Uint8Array(ARTIFACT_BUFFER_BYTES);
	try {
		for (const [index, text] of texts.entries()) {
			if (index > 0) await writeBytes(file, UTF8.encode("\n"));
			// encodeInto stops before a character that does not fit, so no
			// character is ever split across two writes.
			for (let read = 0; read < text.length;) {
				const step = UTF8.encodeInto(read === 0 ? text : text.slice(read), buffer);
				if (step.read <= 0) throw new Error(`artifact-encode=no-progress offset=${read}`);
				await writeBytes(file, buffer.subarray(0, step.written));
				read += step.read;
			}
		}
	} catch (error) {
		// A partial artifact would pass for the full output, so it goes too.
		try {
			await file.close();
			await rm(path, { force: true });
		} catch (cleanup) {
			throw new Error(`${stringifyError(error)}; cleanup ${stringifyError(cleanup)}`);
		}
		throw error;
	}
	await file.close();
}

async function writeArtifact(ctx: ExtensionContext, toolName: string, toolCallId: string | undefined, texts: readonly string[]): Promise<{ path?: string; error?: string }> {
	const safeTool = toolName.replaceAll(/[^a-z0-9_.-]+/gi, "-").slice(0, 40) || "tool";
	const safeId = (toolCallId ?? Date.now().toString(36)).replaceAll(/[^a-z0-9_.-]+/gi, "-").slice(0, 80);
	const candidates = [artifactDir(ctx), join(tmpdir(), "pi-output-policy", safeFileName(sessionIdForContext(ctx)))];
	const errors: string[] = [];
	await acquireArtifactWriteSlot();
	try {
		for (const dir of candidates) {
			const unique = randomUUID().replaceAll("-", "").slice(0, 12);
			const artifactPath = join(dir, `${Date.now()}-${unique}-${safeTool}-${safeId}.txt`);
			try {
				openLaneDir(dir, ctx.cwd);
				await writeTexts(artifactPath, texts);
				return { path: artifactPath };
			} catch (error) {
				errors.push(stringifyError(error));
			}
		}
	} finally {
		releaseArtifactWriteSlot();
	}
	return { error: errors.join("; ") };
}

function minimizedNotice(lines: number): string {
	return policyNotice("minimized-lines", lines, "Repetitive or noisy lines were minimized.");
}

function policyNotice(key: string, value: string | number, explanation: string): string {
	return `[output-policy:${key}=${JSON.stringify(value)}]\n${explanation}`;
}

// A notice appended to text follows a blank line. `appendNotice` is the one
// place that joins them and `noticeLines` the one place that counts what the
// join adds: the notice's own lines plus the blank line.
const NOTICE_SEPARATOR = "\n\n";

function appendNotice(text: string, noticeText: string): string {
	return `${text}${NOTICE_SEPARATOR}${noticeText}`;
}

function noticeLines(noticeText: string): number {
	return countLines(noticeText) + 1;
}

/** The truncation notice, followed by the write-error notice when the full
 * output could not be saved. */
function notice(meta: TruncationMeta): string {
	const target = meta.direction === "tail" ? `Showing last ${meta.shownLines} lines / ${formatSize(meta.shownBytes)}` : `Showing ${meta.shownRange} of ${meta.totalLines} / ${formatSize(meta.shownBytes)}`;
	const artifact = meta.artifactPath ? ` Full output: ${meta.artifactPath}` : "";
	const minimized = meta.minimized ? ` Minimized ${meta.minimizedDroppedLines} noisy line(s) before truncation.` : "";
	const saved = typeof meta.savedBytes === "number" && meta.savedBytes > 0 ? ` Saved ${formatSize(meta.savedBytes)} from transcript (turn total: ${formatSize(meta.turnSavedBytes ?? 0)}, session: ${formatSize(meta.sessionSavedBytes ?? 0)}).` : "";
	const continuation = meta.direction === "head" && meta.totalLines > meta.shownLines ? ` Continue with the same tool using an offset past line ${meta.shownLines} to read more.` : "";
	const truncation = policyNotice("truncated-bytes", meta.totalBytes, `Output truncated (${meta.direction}). ${target}. Total: ${meta.totalLines} lines / ${formatSize(meta.totalBytes)}.${minimized}${saved}${artifact}${continuation}`);
	return meta.artifactError === undefined ? truncation : appendNotice(truncation, policyNotice("artifact-error", meta.artifactError, "Full output was not saved. Only the preview above remains."));
}

// The floor of both line caps: the tallest notice, the truncation notice with
// the write-error notice after it, plus one preview line. Every notice value
// is JSON-escaped, so the notice's line count does not vary with its figures.
const MIN_LINE_LIMIT = noticeLines(notice({ artifactError: "", direction: "head", reason: "", shownBytes: 0, shownLines: 0, shownRange: "", totalBytes: 0, totalLines: 0, truncated: true })) + 1;

// The notice is sized before the preview is cut from worst-case figures; this
// covers the few characters by which the final figures can print wider.
const NOTICE_SLACK_BYTES = 64;

type ContentPart = NonNullable<ToolResultEventResult["content"]>[number];

function isTextPart(part: ContentPart): part is Extract<ContentPart, { type: "text" }> {
	return part?.type === "text" && typeof part.text === "string";
}

interface PolicedText {
	index: number;
	original: string;
	working: string;
	stats: TextStats;
}

export interface ProcessedContent {
	changed: boolean;
	content: ContentPart[];
	meta?: TruncationMeta;
}

/**
 * Applies the policy to one tool result's content. The text parts share one
 * inline budget, notices included: read as one text joined by newlines, the
 * result keeps its head or tail lines, a part left with no line is dropped, and
 * the whole original text goes to one artifact. Non-text parts pass through.
 * `config` is the settings snapshot a tool-result handler already read.
 */
export async function processContent(event: any, ctx: ExtensionContext, content: ContentPart[], config: kendexConfig = readkendexConfig(ctx.cwd)): Promise<ProcessedContent> {
	const unchanged: ProcessedContent = { changed: false, content };
	const toolName = String(event.toolName ?? "tool");
	const policy = textPolicy(config);
	const direction = directionForTool(toolName);
	const command = toolName.toLowerCase() === "bash" && typeof event.input?.command === "string" ? event.input.command as string : undefined;
	const texts: PolicedText[] = [];
	let minimizedDroppedLines = 0;
	for (const [index, part] of content.entries()) {
		if (!isTextPart(part)) continue;
		let working = part.text;
		if (command !== undefined) {
			const result = minimizeShellOutput(working, command, ctx.cwd, config);
			working = result.text;
			minimizedDroppedLines += result.dropped;
		}
		const bytes = byteLength(working);
		const overBytes = bytes > Math.min(policy.maxTextBytes, policy.spillThresholdBytes);
		texts.push({ index, original: part.text, stats: textStats(working, bytes, overBytes ? undefined : policy.maxLineWidth), working });
	}
	if (texts.length === 0) return unchanged;
	const minimized = minimizedDroppedLines > 0;
	const minimizedText = minimized ? minimizedNotice(minimizedDroppedLines) : undefined;
	const joinedBytes = (sizes: number[]) => sizes.reduce((sum, size) => sum + size, sizes.length - 1);
	const totalBytes = joinedBytes(texts.map((text) => text.stats.bytes));
	const totalLines = texts.reduce((sum, text) => sum + text.stats.lines, 0);
	const inlineBytes = totalBytes + (minimizedText === undefined ? 0 : byteLength(appendNotice("", minimizedText)));
	const inlineLines = totalLines + (minimizedText === undefined ? 0 : noticeLines(minimizedText));
	const overSpill = inlineBytes > policy.spillThresholdBytes;
	const overTextBlock = inlineBytes > policy.maxTextBytes;
	const tooLarge = overSpill || overTextBlock || inlineLines > policy.maxLineCount || texts.some((text) => text.stats.overWidth);
	if (!tooLarge) {
		if (minimizedText === undefined) return unchanged;
		const last = texts[texts.length - 1];
		const next = [...content];
		for (const text of texts) next[text.index] = { ...(content[text.index] as Extract<ContentPart, { type: "text" }>), text: text === last ? appendNotice(text.working, minimizedText) : text.working };
		return { changed: true, content: next };
	}

	const artifact = policy.preserveFullOutput ? await writeArtifact(ctx, toolName, event.toolCallId, texts.map((text) => text.original)) : {};
	const tail = direction === "tail";
	const byteLimit = Math.min(policy.maxTextBytes, tail ? policy.inlineTailBytes : policy.maxTextBytes);
	const lineLimit = Math.min(policy.maxLineCount, tail ? policy.inlineTailLines : policy.maxLineCount);
	const originalBytes = joinedBytes(texts.map((text) => text.original === text.working ? text.stats.bytes : byteLength(text.original)));
	const session = counters(sessionIdForContext(ctx));
	const base = {
		artifactError: artifact.error,
		artifactPath: artifact.path,
		direction,
		minimized,
		minimizedDroppedLines,
		policyMode: policy.mode,
		reason: overSpill ? "spill-threshold" : overTextBlock ? "max-text-block" : "ui-safety",
		totalBytes,
		totalLines,
		truncated: true,
	};
	// Every figure at its widest, and one line short of the total so the
	// head notice's continuation clause is counted.
	const worstNotice = notice({
		...base,
		savedBytes: originalBytes,
		sessionSavedBytes: session.sessionSavedBytes + originalBytes,
		shownBytes: totalBytes,
		shownLines: totalLines - 1,
		shownRange: `lines ${totalLines}-${totalLines}`,
		turnSavedBytes: session.turnSavedBytes + originalBytes,
	});
	const budget: InlineBudget = {
		bytes: Math.max(0, byteLimit - byteLength(appendNotice("", worstNotice)) - NOTICE_SLACK_BYTES),
		lines: Math.max(0, lineLimit - noticeLines(worstNotice)),
		started: false,
	};
	const shown = new Map<number, { lines: number; text: string }>();
	for (const text of tail ? [...texts].reverse() : texts) {
		if (budget.lines <= 0) break;
		const lines = selectLines(text.working, direction, budget, policy.maxLineWidth);
		if (lines.length > 0) shown.set(text.index, { lines: lines.length, text: lines.join("\n") });
	}
	let shownBytes = 0;
	let shownLines = 0;
	for (const part of shown.values()) {
		shownBytes += byteLength(part.text);
		shownLines += part.lines;
	}
	const savedBytes = Math.max(0, originalBytes - shownBytes);
	session.turnSavedBytes += savedBytes;
	session.sessionSavedBytes += savedBytes;
	const meta: TruncationMeta = {
		...base,
		savedBytes,
		sessionSavedBytes: session.sessionSavedBytes,
		shownBytes,
		shownLines,
		shownRange: shownLines === 0 ? "none" : tail ? `lines ${totalLines - shownLines + 1}-${totalLines}` : `lines 1-${shownLines}`,
		turnSavedBytes: session.turnSavedBytes,
	};
	const next: ContentPart[] = [];
	let lastText = -1;
	for (const [index, part] of content.entries()) {
		if (!isTextPart(part)) {
			next.push(part);
			continue;
		}
		const kept = shown.get(index);
		if (!kept) continue;
		lastText = next.length;
		next.push({ ...part, text: kept.text });
	}
	const policyText = notice(meta);
	if (lastText < 0) next.push({ text: policyText, type: "text" });
	else {
		const part = next[lastText] as Extract<ContentPart, { type: "text" }>;
		next[lastText] = { ...part, text: appendNotice(part.text, policyText) };
	}
	return { changed: true, content: next, meta };
}

const SANITIZE_ARRAY_CAP = 50;
const SANITIZE_OBJECT_CAP = 80;
const SANITIZE_MAX_DEPTH = 4;
const SANITIZE_STRING_CHARS = 8 * 1024;
// One traversal shares these across the whole details tree: every visited
// value spends a node, every kept string its UTF-8 bytes.
const SANITIZE_NODE_BUDGET = 2_000;
const SANITIZE_BYTE_BUDGET = 64 * 1024;

interface DetailBudget {
	bytes: number;
	nodes: number;
}

/** Caps a details tree. A branch the caps leave alone is returned by
 * reference, so an in-budget tree is traversed but never copied. */
export function sanitizeDetails(value: unknown): { value: unknown; changed: boolean } {
	const sanitized = sanitizeNode(value, 0, { bytes: SANITIZE_BYTE_BUDGET, nodes: SANITIZE_NODE_BUDGET });
	return { changed: !Object.is(sanitized, value), value: sanitized };
}

function byteBudgetNotice(): string {
	return policyNotice("detail-byte-budget", SANITIZE_BYTE_BUDGET, "Detail byte budget reached.");
}

function budgetNotice(budget: DetailBudget): string | undefined {
	if (budget.nodes <= 0) return policyNotice("detail-node-budget", SANITIZE_NODE_BUDGET, "Detail traversal budget reached.");
	if (budget.bytes <= 0) return byteBudgetNotice();
	return undefined;
}

function sanitizeNode(value: unknown, depth: number, budget: DetailBudget): unknown {
	budget.nodes -= 1;
	if (depth > SANITIZE_MAX_DEPTH) return policyNotice("detail-depth", depth, "Maximum detail depth reached.");
	if (value == null || typeof value === "number" || typeof value === "boolean") return value;
	if (typeof value === "string") return sanitizeString(value, budget);
	if (Array.isArray(value)) return sanitizeArray(value, depth, budget);
	if (typeof value === "object") return sanitizeObject(value as Record<string, unknown>, depth, budget);
	return String(value);
}

/** A string over the character cap ends with a `detail-chars` notice. One the
 * byte budget cuts ends with the `detail-byte-budget` notice and spends the
 * rest of the budget, since a multi-byte cut can leave a few bytes no whole
 * character fits. */
function sanitizeString(value: string, budget: DetailBudget): string {
	const overChars = value.length > SANITIZE_STRING_CHARS;
	const head = overChars ? value.slice(0, SANITIZE_STRING_CHARS) : value;
	const bytes = byteLength(head);
	if (bytes <= budget.bytes) {
		budget.bytes -= bytes;
		return overChars ? `${head}…\n${policyNotice("detail-chars", value.length, "Detail string truncated.")}` : value;
	}
	const kept = prefixWithinBytes(head, budget.bytes);
	budget.bytes = 0;
	return `${kept}…\n${byteBudgetNotice()}`;
}

function sanitizeArray(value: unknown[], depth: number, budget: DetailBudget): unknown[] {
	const overflow = value.length > SANITIZE_ARRAY_CAP;
	const limit = overflow ? SANITIZE_ARRAY_CAP - 1 : value.length;
	let out: unknown[] | undefined;
	for (let i = 0; i < limit; i += 1) {
		const stop = budgetNotice(budget);
		if (stop !== undefined) {
			out ??= value.slice(0, i);
			out.push(stop);
			return out;
		}
		const item = sanitizeNode(value[i], depth + 1, budget);
		if (out) out.push(item);
		else if (!Object.is(item, value[i])) {
			out = value.slice(0, i);
			out.push(item);
		}
	}
	if (!overflow) return out ?? value;
	out ??= value.slice(0, limit);
	out.push(policyNotice("detail-array-dropped", value.length - limit, "Detail array truncated."));
	return out;
}

/** The first `count` own keys of `source`, values by reference. */
function copyOwnKeys(source: Record<string, unknown>, count: number): Record<string, unknown> {
	const out: Record<string, unknown> = {};
	let copied = 0;
	for (const key in source) {
		if (copied >= count) break;
		if (!Object.hasOwn(source, key)) continue;
		out[key] = source[key];
		copied += 1;
	}
	return out;
}

function sanitizeObject(source: Record<string, unknown>, depth: number, budget: DetailBudget): Record<string, unknown> {
	// Iterate own keys with an early break instead of materializing the full
	// Object.entries(...) array, so a wide untrusted `details` object cannot
	// exhaust memory or CPU before the cap engages.
	let out: Record<string, unknown> | undefined;
	let kept = 0;
	for (const key in source) {
		if (!Object.hasOwn(source, key)) continue;
		const stop = kept >= SANITIZE_OBJECT_CAP
			? policyNotice("detail-object-cap", SANITIZE_OBJECT_CAP, "Detail object truncated.")
			: budgetNotice(budget);
		if (stop !== undefined) {
			out ??= copyOwnKeys(source, kept);
			out["[output-policy:truncated]"] = stop;
			break;
		}
		const item = sanitizeNode(source[key], depth + 1, budget);
		if (out) out[key] = item;
		else if (!Object.is(item, source[key])) {
			out = copyOwnKeys(source, kept);
			out[key] = item;
		}
		kept += 1;
	}
	return out ?? source;
}

function stringifyError(error: unknown): string {
	if (error instanceof Error) return `${error.name}: ${error.message}`;
	return String(error);
}

export default function outputPolicy(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;
	// Pi 0.84.1 invokes the extension factory once per loaded session runtime.
	// Session replacement emits shutdown, invalidates the old runner, and loads a
	// replacement ExtensionAPI/factory closure, so this state cannot cross session runtimes.
	let modelOutputState = createModelOutputGuardState();
	let modelOutputConfig: ModelOutputGuardConfigSnapshot | undefined;

	const resetModelOutputState = () => {
		modelOutputState = createModelOutputGuardState();
		modelOutputConfig = undefined;
	};

	const snapshotModelOutputConfig = (ctx: ExtensionContext) => {
		recordProjectTrust(ctx);
		modelOutputConfig = modelOutputGuardConfigSnapshot(ctx.cwd);
		return modelOutputConfig;
	};

	installSettingsCacheRefresh(pi);
	pi.on("session_start", async (_event, ctx: ExtensionContext) => {
		resetModelOutputState();
		recordProjectTrust(ctx);
		SESSION_COUNTERS.delete(sessionIdForContext(ctx));
		for (const [root, below] of [
			[join(piUserDir(), "kendex", "sessions"), [SESSION_FOLDER, "artifacts"]],
			[join(tmpdir(), SESSION_FOLDER), []],
		] as const) {
			const pruned = pruneLanes(root, [...below]);
			for (const failure of pruned.failed) {
				console.warn(policyNotice("artifact-prune-error", failure.path, failure.error));
			}
		}
	});

	pi.on("turn_start", async (_event, ctx: ExtensionContext) => {
		resetModelOutputState();
		counters(sessionIdForContext(ctx)).turnSavedBytes = 0;
	});

	pi.on("session_shutdown", async (_event, ctx: ExtensionContext) => {
		resetModelOutputState();
		SESSION_COUNTERS.delete(sessionIdForContext(ctx));
	});

	pi.on("message_start", (event: any, ctx: ExtensionContext) => {
		if (event?.message?.role !== "assistant") return;
		resetModelOutputState();
		snapshotModelOutputConfig(ctx);
	});

	pi.on("message_update", (event: any, ctx: ExtensionContext) => {
		const delta = assistantStreamDelta(event);
		if (delta === undefined) return;
		// Pi 0.84.1 agent-core guarantees one assistant message_start before any
		// message_update. This lazy snapshot only supports isolated direct/mock
		// event injection; delta events expose no safe boundary to infer if start is
		// absent, so do not reset via timing, contentIndex, or delta-shape heuristics.
		const config = modelOutputConfig ?? snapshotModelOutputConfig(ctx);
		if (!config.enabled) return;
		const detection = inspectModelOutputDelta(modelOutputState, delta, config.options);
		if (!detection || modelOutputState.aborted) return;
		modelOutputState.aborted = true;
		const detail = detection.reason === "repetition"
			? `${detection.consecutiveRepeats} consecutive repeated blocks`
			: `${detection.totalChars.toLocaleString()} streamed characters`;
		ctx.abort();
		try {
			ctx.ui.notify(policyNotice(detection.reason, detection.reason === "repetition" ? detection.consecutiveRepeats! : detection.totalChars, `Model output stopped: ${detail}. Retry or switch model.`), "warning");
		} catch (error) {
			console.warn(policyNotice("warning-error", stringifyError(error), "Model output warning failed."));
		}
	});

	pi.on("tool_result", async (event: any, ctx: ExtensionContext) => {
		recordProjectTrust(ctx);
		const config = readkendexConfig(ctx.cwd);
		if (!configBoolean(config, "enabled", true)) return undefined;
		const toolName = String(event.toolName ?? "tool");
		if (shouldBypassTool(toolName, config)) return undefined;
		const processed = await processContent(event, ctx, event.content ?? [], config);
		const mode = policyModeFrom(config);
		const sanitizeOn = configBoolean(config, "sanitizeDetails", MODE_DEFAULTS[mode].sanitizeDetails);
		const sanitizedDetails = sanitizeOn && !isSanitizeExceptTool(toolName, ctx.cwd, config) ? sanitizeDetails(event.details) : { changed: false, value: event.details };
		if (!processed.changed && !sanitizedDetails.changed) return undefined;
		let details = sanitizedDetails.value;
		if (processed.meta || sanitizedDetails.changed) {
			details = details && typeof details === "object" && !Array.isArray(details) ? { ...(details as Record<string, unknown>) } : {};
		}
		if (processed.meta) {
			(details as Record<string, unknown>).kendexOutputPolicy = [processed.meta];
		}
		if (sanitizedDetails.changed) {
			(details as Record<string, unknown>).kendexOutputPolicySanitized = {
				policyMode: mode,
				reason: "details payload exceeded inline budget; capped per policyMode (set policyMode=compat or sanitizeDetails=false to disable)",
			};
		}
		if (!processed.changed) return { details };
		// Text budgets change the model's display, not the tool's output for
		// programmatic callers. Pi's bash already gives these different budgets.
		return { content: processed.content, details, structuredContent: event.structuredContent };
	});
}
