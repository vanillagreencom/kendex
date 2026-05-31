import { calculateCost, getModels, type AssistantMessage, type AssistantMessageEventStream, type Context, type Model, type SimpleStreamOptions, type Tool } from "@earendil-works/pi-ai";
import * as piAi from "@earendil-works/pi-ai";
import { type ExtensionAPI, type ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { createSdkMcpServer, query, type EffortLevel, type SDKMessage, type SDKUserMessage, type SettingSource, type SpawnOptions, type SpawnedProcess } from "@anthropic-ai/claude-agent-sdk";
import type { Base64ImageSource, ContentBlockParam, MessageParam } from "@anthropic-ai/sdk/resources";
import { createSession, deleteSession, openSession, repairToolPairing } from "cc-session-io";
import { spawn as spawnProcess } from "child_process";
import { createHash } from "crypto";
import { accessSync, appendFileSync, chmodSync, constants as fsConstants, mkdirSync, readFileSync, realpathSync, statSync } from "fs";
import { resolve as pathResolve } from "path";
import { homedir } from "os";
import { delimiter, dirname, join } from "path";
import { PROVIDER_ID, messageContentToText, convertPiMessages } from "./convert.js";
import { buildModels } from "./models.js";
import { MCP_SERVER_NAME, MCP_TOOL_PREFIX, extractSkillsBlock } from "./skills.js";
import { verifyWrittenSession as _verifyWrittenSession } from "./session-verify.js";
import { extractAllToolResults as _extractAllToolResults, type McpResult } from "./extract-tool-results.js";
import { QueryContext, ctx, stackDepth, pushContext, popContext } from "./query-state.js";
import { findUnpairedToolUses, summarizeMissingToolNames, type MissingToolResult } from "./tool-pairing-audit.js";
import { loadConfig, normalizeEffortLevel, type Config } from "./config.js";
import { extractAgentsAppend } from "./agents-md.js";
import { buildPromptContextAppend } from "./prompt-context.js";
import { jsonSchemaToZodShape } from "./typebox-to-zod.js";

// Compat (#2): use factory if available (pi-ai ≥0.66), else fall back to constructor (gsd-pi etc.)
const _piAi = piAi as any;
const newAssistantMessageEventStream: () => AssistantMessageEventStream =
	typeof _piAi.createAssistantMessageEventStream === "function"
		? _piAi.createAssistantMessageEventStream
		: () => new _piAi.AssistantMessageEventStream();

// --- Debug logging ---
// CLAUDE_BRIDGE_DEBUG=1 enables debug logging to ~/.pi/agent/claude-bridge.log

const DEBUG = process.env.CLAUDE_BRIDGE_DEBUG === "1";
const DEBUG_LOG_PATH = process.env.CLAUDE_BRIDGE_DEBUG_PATH || join(homedir(), ".pi", "agent", "claude-bridge.log");
const DEFAULT_DIAG_LOG_PATH = join(homedir(), ".pi", "agent", "claude-bridge-diag.log");

function diagLogPath(): string {
	return process.env.CLAUDE_BRIDGE_DIAG_PATH || DEFAULT_DIAG_LOG_PATH;
}

// Ensure log directories exist when debug is enabled
if (DEBUG) {
	try {
		mkdirSync(dirname(DEBUG_LOG_PATH), { recursive: true });
		mkdirSync(dirname(diagLogPath()), { recursive: true, mode: 0o700 });
	} catch {
		// If directory creation fails, debug functions will throw on first use
	}
}

// Unique per module evaluation — confirms whether subagents share module state
const moduleInstanceId = Math.random().toString(36).slice(2, 8);

function debug(...args: unknown[]) {
	if (!DEBUG) return;
	const ts = new Date().toISOString();
	const fmt = (a: unknown): string => {
		if (typeof a === "string") return a;
		if (a instanceof Error) return `${a.name}: ${a.message}${a.stack ? "\n" + a.stack : ""}`;
		return JSON.stringify(a);
	};
	const msg = args.map(fmt).join(" ");
	try { appendFileSync(DEBUG_LOG_PATH, `[${ts}] [${moduleInstanceId}] ${msg}\n`); } catch { /* debug is best effort */ }
}

function executableFromPath(name: string): string | undefined {
	const paths = (process.env.PATH ?? "").split(delimiter).filter(Boolean);
	for (const dir of paths) {
		const candidate = join(dir, name);
		try {
			accessSync(candidate, fsConstants.X_OK);
			return candidate;
		} catch {
			// keep searching
		}
	}
	return undefined;
}

function resolveClaudeExecutable(configured?: string): string | undefined {
	const trimmed = configured?.trim();
	if (trimmed) return trimmed;
	return executableFromPath("claude") ?? executableFromPath("claude-code");
}

export type ClaudeExecutableFileType = "elf" | "mach-o" | "pe" | "shebang-script" | "empty" | "unknown";

export interface ClaudeExecutablePreflightResult {
	path: string;
	realPath: string;
	cwd: string;
	realCwd: string;
	fileType: ClaudeExecutableFileType;
}

function errnoValue(err: unknown): string | number | undefined {
	return typeof (err as NodeJS.ErrnoException)?.errno === "number" ? (err as NodeJS.ErrnoException).errno : undefined;
}

function syscallValue(err: unknown): string | undefined {
	return typeof (err as NodeJS.ErrnoException)?.syscall === "string" ? (err as NodeJS.ErrnoException).syscall : undefined;
}

function pathValue(err: unknown): string | undefined {
	const value = (err as NodeJS.ErrnoException)?.path;
	return typeof value === "string" ? value : undefined;
}

function codeValue(err: unknown, fallback: string): string {
	const value = (err as NodeJS.ErrnoException)?.code;
	return typeof value === "string" ? value : fallback;
}

function displayValue(value: unknown): string {
	return value === undefined || value === null || value === "" ? "<none>" : String(value);
}

function makeClaudePreflightError(
	summary: string,
	details: { code: string; errno?: string | number; syscall?: string; path: string; cwd: string; fileType?: ClaudeExecutableFileType; realPath?: string; cause?: unknown },
): Error & NodeJS.ErrnoException & { cwd: string; fileType?: ClaudeExecutableFileType; realPath?: string } {
	const detail = [
		`code=${details.code}`,
		`errno=${displayValue(details.errno)}`,
		`syscall=${displayValue(details.syscall)}`,
		`path=${details.path}`,
		`cwd=${details.cwd}`,
		...(details.fileType ? [`fileType=${details.fileType}`] : []),
		...(details.realPath ? [`realPath=${details.realPath}`] : []),
	].join(" ");
	const error = new Error(`${summary} (${detail})`) as Error & NodeJS.ErrnoException & { cwd: string; fileType?: ClaudeExecutableFileType; realPath?: string };
	error.name = "ClaudeExecutablePreflightError";
	error.code = details.code;
	if (details.errno !== undefined) error.errno = typeof details.errno === "number" ? details.errno : Number(details.errno);
	if (details.syscall) error.syscall = details.syscall;
	error.path = details.path;
	error.cwd = details.cwd;
	if (details.fileType) error.fileType = details.fileType;
	if (details.realPath) error.realPath = details.realPath;
	if (details.cause !== undefined) (error as Error & { cause?: unknown }).cause = details.cause;
	return error;
}

export function classifyClaudeExecutableBytes(bytes: Uint8Array): ClaudeExecutableFileType {
	if (bytes.length === 0) return "empty";
	if (bytes.length >= 2 && bytes[0] === 0x23 && bytes[1] === 0x21) return "shebang-script";
	if (bytes.length >= 4 && bytes[0] === 0x7f && bytes[1] === 0x45 && bytes[2] === 0x4c && bytes[3] === 0x46) return "elf";
	if (bytes.length >= 2 && bytes[0] === 0x4d && bytes[1] === 0x5a) return "pe";
	if (bytes.length >= 4) {
		const magic = bytes[0] * 0x1000000 + bytes[1] * 0x10000 + bytes[2] * 0x100 + bytes[3];
		if (
			magic === 0xfeedface ||
			magic === 0xfeedfacf ||
			magic === 0xcefaedfe ||
			magic === 0xcffaedfe ||
			magic === 0xcafebabe ||
			magic === 0xbebafeca
		) return "mach-o";
	}
	return "unknown";
}

export function preflightClaudeExecutable(path: string, cwd: string): ClaudeExecutablePreflightResult {
	let realCwd = cwd;
	try {
		const cwdStat = statSync(cwd);
		if (!cwdStat.isDirectory()) {
			throw makeClaudePreflightError("Claude Code spawn cwd preflight failed: cwd is not a directory.", {
				code: "ENOTDIR",
				syscall: "chdir",
				path: cwd,
				cwd,
			});
		}
		accessSync(cwd, fsConstants.X_OK);
		realCwd = realpathSync(cwd);
	} catch (err) {
		if ((err as Error).name === "ClaudeExecutablePreflightError") throw err;
		throw makeClaudePreflightError("Claude Code spawn cwd preflight failed: cwd is not reachable before spawning Claude Code.", {
			code: codeValue(err, "EACCES"),
			errno: errnoValue(err),
			syscall: syscallValue(err),
			path: pathValue(err) ?? cwd,
			cwd,
			cause: err,
		});
	}

	let realPath = path;
	try {
		const stat = statSync(path);
		if (!stat.isFile()) {
			throw makeClaudePreflightError("Claude Code executable preflight failed: resolved path is not a file.", {
				code: "EACCES",
				syscall: "exec",
				path,
				cwd,
			});
		}
		accessSync(path, fsConstants.X_OK);
		realPath = realpathSync(path);
	} catch (err) {
		if ((err as Error).name === "ClaudeExecutablePreflightError") throw err;
		throw makeClaudePreflightError("Claude Code executable preflight failed: cannot access resolved executable before spawning Claude Code.", {
			code: codeValue(err, "ENOENT"),
			errno: errnoValue(err),
			syscall: syscallValue(err),
			path: pathValue(err) ?? path,
			cwd,
			cause: err,
		});
	}

	let fileType: ClaudeExecutableFileType;
	try {
		fileType = classifyClaudeExecutableBytes(readFileSync(realPath).subarray(0, 16));
	} catch (err) {
		throw makeClaudePreflightError("Claude Code executable preflight failed: cannot read executable header before spawning Claude Code.", {
			code: codeValue(err, "EACCES"),
			errno: errnoValue(err),
			syscall: syscallValue(err),
			path: pathValue(err) ?? realPath,
			cwd,
			realPath,
			cause: err,
		});
	}

	if (!["elf", "mach-o", "pe", "shebang-script"].includes(fileType)) {
		throw makeClaudePreflightError("Claude Code executable preflight failed: executable header is not an ELF, Mach-O, PE, or shebang script.", {
			code: "ENOEXEC",
			syscall: "exec",
			path,
			cwd,
			fileType,
			realPath,
		});
	}

	return { path, realPath, cwd, realCwd, fileType };
}

function envFlagEnabled(value: string | undefined): boolean {
	return value === "1" || value?.toLowerCase() === "true";
}

export function wrapClaudeSpawnErrorForSdk(err: Error, options: SpawnOptions): Error & NodeJS.ErrnoException & { cwd: string; originalCode?: string; originalMessage?: string } {
	const originalCode = codeValue(err, "SPAWN_ERROR");
	const originalMessage = err.message;
	const spawnPath = pathValue(err) ?? options.command;
	const cwd = options.cwd ?? process.cwd();
	const detail = [
		`code=${originalCode}`,
		`errno=${displayValue(errnoValue(err))}`,
		`syscall=${displayValue(syscallValue(err))}`,
		`path=${spawnPath}`,
		`cwd=${cwd}`,
		`command=${options.command}`,
	].join(" ");
	const wrapped = new Error(`Claude Code spawn failed: ${originalMessage} (${detail})`) as Error & NodeJS.ErrnoException & { cwd: string; originalCode?: string; originalMessage?: string };
	wrapped.name = "ClaudeSpawnDiagnosticError";
	// The SDK special-cases code === ENOENT and replaces the message with its
	// generic "native binary not found" text. Preserve the original code in the
	// message/originalCode while using a bridge code so the SDK surfaces context.
	wrapped.code = originalCode === "ENOENT" ? "CLAUDE_BRIDGE_SPAWN_FAILED" : originalCode;
	wrapped.originalCode = originalCode;
	wrapped.originalMessage = originalMessage;
	const errno = errnoValue(err);
	if (errno !== undefined) wrapped.errno = typeof errno === "number" ? errno : Number(errno);
	const syscall = syscallValue(err);
	if (syscall) wrapped.syscall = syscall;
	wrapped.path = spawnPath;
	wrapped.cwd = cwd;
	// Do not set `cause` here: the listener copies these structured fields back
	// onto the original Error. A cause reference to that same object would become
	// `err.cause === err`, making JSON.stringify throw on a circular structure.
	// originalMessage plus code/errno/syscall/path/cwd preserve the useful data.
	return wrapped;
}

export function spawnClaudeCodeWithDiagnostics(options: SpawnOptions): SpawnedProcess {
	const pipeStderr = DEBUG || envFlagEnabled(options.env.DEBUG_CLAUDE_AGENT_SDK);
	const child = spawnProcess(options.command, options.args, {
		cwd: options.cwd,
		env: options.env,
		signal: options.signal,
		stdio: ["pipe", "pipe", pipeStderr ? "pipe" : "ignore"],
		windowsHide: true,
	});
	if (pipeStderr) {
		child.stderr?.on("data", (data) => {
			for (const line of data.toString().split(/\r?\n/)) {
				if (line) debug(`[cli-stderr spawn] ${line}`);
			}
		});
	}
	child.prependListener("error", (err) => {
		const originalStack = err.stack;
		const wrapped = wrapClaudeSpawnErrorForSdk(err, options);
		Object.assign(err, wrapped);
		err.name = wrapped.name;
		err.message = wrapped.message;
		// Keep V8's stack from the actual Node spawn failure, not the wrapper
		// construction site. Diagnostic fields above remain enumerable and
		// JSON-serializable; stack stays the spawn-time breadcrumb for operators.
		if (originalStack) err.stack = originalStack;
	});
	return {
		stdin: child.stdin,
		stdout: child.stdout,
		get killed() { return child.killed; },
		get exitCode() { return child.exitCode; },
		kill: child.kill.bind(child),
		on: child.on.bind(child),
		once: child.once.bind(child),
		off: child.off.bind(child),
	};
}

// Per-query CLI debug capture. When CLAUDE_BRIDGE_DEBUG=1, ask the Claude Code
// CLI subprocess to write its own debug log to a file we choose, and also
// forward its stderr into our debug stream. Drops straight into the real SDK's
// Options — see @anthropic-ai/claude-agent-sdk sdk.d.ts:1245 (debug, debugFile,
// stderr). Without this, CC's internal view of the world is invisible to us
// and "No conversation found" / empty-error reports are unactionable.
let nextCliDebugSeq = 1;
function makeCliDebugOptions(tag: string): { debug?: boolean; debugFile?: string; stderr?: (data: string) => void } {
	if (!DEBUG) return {};
	const seq = nextCliDebugSeq++;
	const ts = new Date().toISOString().replace(/[:.]/g, "-");
	const logDir = join(dirname(DEBUG_LOG_PATH), "cc-cli-logs");
	try { mkdirSync(logDir, { recursive: true }); } catch { /* ignore */ }
	const debugFile = join(logDir, `${ts}-${tag}-${seq}.log`);
	debug(`cli-debug: ${tag} #${seq} → ${debugFile}`);
	return {
		debug: true,
		debugFile,
		stderr: (data: string) => {
			for (const line of data.split(/\r?\n/)) {
				if (line) debug(`[cli-stderr ${tag}#${seq}] ${line}`);
			}
		},
	};
}

/** Unconditional diagnostic dump — for "should never happen" paths */
function diagDump(label: string, data: Record<string, unknown>) {
	try {
		const ts = new Date().toISOString();
		const entry = { ts, moduleInstanceId, label, ...data };
		const path = diagLogPath();
		try { mkdirSync(dirname(path), { recursive: true, mode: 0o700 }); } catch { /* best effort */ }
		appendFileSync(path, JSON.stringify(entry) + "\n", { mode: 0o600 });
		try { chmodSync(path, 0o600); } catch { /* best effort */ }
		debug(`DIAG: ${label} (see ${path})`);
	} catch (error) {
		debug(`DIAG FAILED: ${label}`, error);
	}
}

function safeNotify(message: string, level: "info" | "warning" | "error" = "warning"): void {
	try { piUI?.notify(message, level); }
	catch (error) { debug("notify failed:", error); }
}

function argKeys(args: Record<string, unknown> | undefined): string[] {
	return Object.keys(args ?? {}).sort();
}

function safeToolCallSummary(calls: Array<{ id: string; toolName: string; arguments?: Record<string, unknown> }>): Array<{ id: string; toolName: string; argKeys: string[] }> {
	return calls.map((call) => ({ id: call.id, toolName: call.toolName, argKeys: argKeys(call.arguments) }));
}

function compactToolNameSummary(names: Array<{ name: string; count: number }>, limit = 12): string[] {
	const shown = names.slice(0, limit).map(({ name, count }) => count > 1 ? `${name}×${count}` : name);
	if (names.length > limit) shown.push(`+${names.length - limit} more`);
	return shown;
}

function reportSyntheticToolResultRepair(missing: MissingToolResult[], context: Record<string, unknown>): void {
	try {
		if (missing.length === 0) return;
		const toolNames = summarizeMissingToolNames(missing);
		const toolNameSummary = compactToolNameSummary(toolNames);
		const sampledToolCallIds = missing.slice(0, 50).map((item) => item.id);
		diagDump("repair_tool_pairing_synthetic_results", {
			count: missing.length,
			toolNames,
			sampledToolCallIds,
			missing: missing.slice(0, 50),
			...context,
		});
		safeNotify(
			`Claude bridge: ${missing.length} missing tool result(s) repaired with "[no tool result recorded]"` +
			`${toolNameSummary.length ? ` for ${toolNameSummary.join(", ")}` : ""}. ` +
			`Real tool output was lost before Claude session import; see ${diagLogPath()}.`,
			"error",
		);
	} catch (error) {
		debug("reportSyntheticToolResultRepair failed:", error);
	}
}

export function reportToolResultMismatch(queryCtx: QueryContext, reason: string, cwd: string | undefined, opts: { forceRotate?: boolean } = {}): boolean {
	try {
		if (queryCtx.reportedToolResultMismatch) return false;
		const progress = queryCtx.toolResultProgress();
		const hasMismatch = progress.expectedCount > 0
			? progress.unresolvedIds.length > 0 || progress.waitingCount > 0 || progress.queuedCount > 0
			: progress.waitingCount > 0 || progress.queuedCount > 0;
		if (!hasMismatch) return false;
		queryCtx.reportedToolResultMismatch = true;
		if (sharedSession) {
			sharedSession = { ...sharedSession, needsRebuild: true, ...(opts.forceRotate ? { forceRotate: true } : {}) };
		}
		const toolNameSummary = compactToolNameSummary(progress.toolNames);
		diagDump("tool_result_delivery_mismatch", {
			reason,
			cwd,
			progress,
			activeQueryExists: queryCtx.activeQuery !== null,
			sharedSession: sharedSession ? {
				sessionId: sharedSession.sessionId.slice(0, 8),
				cursor: sharedSession.cursor,
				needsRebuild: sharedSession.needsRebuild === true,
				forceRotate: sharedSession.forceRotate === true,
			} : null,
		});
		safeNotify(
			`Claude bridge: tool result delivery interrupted during ${reason}; ` +
			`delivered ${progress.deliveredCount}/${progress.expectedCount}, resolved ${progress.resolvedCount}/${progress.expectedCount}, ` +
			`waiting=${progress.waitingCount}, queued=${progress.queuedCount}` +
			`${toolNameSummary.length ? `, tools=${toolNameSummary.join(", ")}` : ""}. ` +
			`Claude session will rebuild before the next turn; see ${diagLogPath()}.`,
			"error",
		);
		return true;
	} catch (error) {
		debug("reportToolResultMismatch failed:", error);
		return false;
	}
}

export function __testSetBridgeIntegrityState(state: { ui?: Pick<ExtensionUIContext, "notify"> | null; sharedSession?: SessionState | null }): void {
	if ("ui" in state) piUI = state.ui as ExtensionUIContext | undefined;
	if ("sharedSession" in state) sharedSession = state.sharedSession ?? null;
}

export function __testGetBridgeIntegrityState(): { sharedSession: SessionState | null } {
	return { sharedSession };
}

// --- Constants ---

// Global key to prevent re-registration of the provider across module reloads.
//
// Extensions like pi-subagents spawn a subagent and it loads this module
// again. Without this guard, the subagent's call to registerProvider() would
// overwrite the parent's `streamSimple` function reference in the shared
// ModelRegistry. When the parent later delivers a tool result, it would call
// the subagent's `streamSimple` (which has empty state) instead of its own.
//
// By storing the active streamSimple in a Symbol.for() global (shared across all
// module instances), we ensure only the FIRST instance to register takes effect.
// Subsequent instances wrap the stored function instead of overwriting it.
//
// On session_shutdown (including /reload), clearSession() resets this so a fresh
// registration can occur for the next session.
const ACTIVE_STREAM_SIMPLE_KEY = Symbol.for("claude-bridge:activeStreamSimple");
const COMMANDS_REGISTERED_KEY = Symbol.for("claude-bridge:commandsRegistered");

const SDK_TO_PI_TOOL_NAME: Record<string, string> = {
	read: "read", write: "write", edit: "edit", bash: "bash",
};

// MODELS is buildModels(getModels("anthropic")) — projection kept in models.js.
const MODELS = buildModels(getModels("anthropic"));

// Disable Claude Code built-ins in the provider path. Pi owns tool execution;
// Claude reaches Pi tools through the bridged MCP server instead.
//
// `allowedTools` is a permission auto-allow list in the Claude Agent SDK, not a
// visibility allowlist. Use `tools: []` to remove the built-in tool set, and keep
// this disallow list as a belt-and-suspenders guard for SDK/CLI built-ins that may
// otherwise leak into the model context (e.g. TodoWrite, CronList, SendMessage).
export const DISALLOWED_BUILTIN_TOOLS = [
	"Read", "Write", "Edit", "MultiEdit", "Glob", "Grep", "Bash", "Agent", "Task",
	"NotebookEdit", "EnterWorktree", "ExitWorktree",
	"CronList", "CronCreate", "CronDelete", "TeamCreate", "TeamDelete",
	"TaskOutput", "TaskStop", "SendMessage", "Skill",
	"TodoRead", "TodoWrite",
	"ListMcpResources", "ReadMcpResource",
	"WebFetch", "WebSearch",
	"AskUserQuestion", "EnterPlanMode", "ExitPlanMode",
	"ToolSearch", "ScheduleWakeup",
];

export const CLAUDE_BRIDGE_TOOL_ISOLATION = {
	tools: [] as string[],
	disallowedTools: DISALLOWED_BUILTIN_TOOLS,
	allowedTools: [`mcp__${MCP_SERVER_NAME}__*`],
} satisfies Pick<NonNullable<Parameters<typeof query>[0]["options"]>, "tools" | "allowedTools" | "disallowedTools">;

// --- Session persistence ---

interface SessionState {
	sessionId: string;
	cursor: number;
	cwd: string;
	// Force the next syncSharedSession call down the REBUILD path. Set when
	// pi has mutated its messages array out from under us (compact, tree
	// navigation) or after an abort left the JSONL in an indeterminate state.
	// REBUILD wipes and rewrites the file to match pi's current history.
	needsRebuild?: boolean;
	// Set ONLY after an abort. The killed CC subprocess may still be flushing
	// a late "[Request interrupted by user]" record to the session JSONL.
	// Reusing the same sessionId/path would race that orphan write into our
	// fresh file and break CC's parent-uuid chain on the next resume. When
	// this flag is set, REBUILD takes a fresh UUID and skips deleteSession
	// so the orphan writes land on a dead inode. Compact/tree do NOT set
	// this — there's no concurrent CC writer during those events, so
	// in-place rebuild (preserve UUID, deleteSession + createSession) is safe.
	forceRotate?: boolean;
}

let sharedSession: SessionState | null = null;
let extensionApi: ExtensionAPI | undefined;
let piUI: ExtensionUIContext | undefined;
let extraUsageHelperInFlight: Promise<string> | null = null;

const RATE_LIMIT_AUTO_RESUME_EVENT = "vstack:rate-limit";
const RATE_LIMIT_TOKEN = "\x1b[31m[rate-limit]\x1b[39m";

export function isExtraUsageRequiredMessage(value: unknown): boolean {
	let text: string;
	if (typeof value === "string") text = value;
	else if (value instanceof Error) text = value.message;
	else {
		try { text = JSON.stringify(value ?? ""); }
		catch { text = String(value); }
	}
	return /extra[-\s]?usage|overage|extra usage billing|extra usage credits|1M context/i.test(text);
}

export function uniqueNonEmptyLines(values: unknown[]): string[] {
	const seen = new Set<string>();
	const out: string[] = [];
	for (const value of values) {
		const text = typeof value === "string" ? value.trim() : value == null ? "" : String(value).trim();
		if (!text || seen.has(text)) continue;
		seen.add(text);
		out.push(text);
	}
	return out;
}

export function formatResetTimestamp(value: unknown): string {
	const parsed = typeof value === "number" ? value : typeof value === "string" ? Date.parse(value) : Number.NaN;
	if (!Number.isFinite(parsed)) return "unknown";
	return new Date(parsed).toLocaleString(undefined, {
		day: "numeric",
		hour: "numeric",
		minute: "2-digit",
		month: "short",
		second: "2-digit",
		timeZoneName: "short",
		year: "numeric",
	});
}

function emitRateLimitEvent(payload: Record<string, unknown>): void {
	try {
		extensionApi?.events?.emit?.(RATE_LIMIT_AUTO_RESUME_EVENT, payload);
	} catch {
		// Cross-extension broker is best-effort only.
	}
}

function extraUsageAllowed(config: Config): boolean {
	return config.provider?.allowExtraUsage === true;
}

function sdkTextFromMessage(message: SDKMessage): string | undefined {
	if (message.type === "result") return (message as any).result;
	if (message.type === "assistant") {
		const content = (message as any).message?.content;
		if (!Array.isArray(content)) return undefined;
		return content
			.map((block) => block?.type === "text" && typeof block.text === "string" ? block.text : "")
			.filter(Boolean)
			.join("\n");
	}
	return undefined;
}

async function runExtraUsageHelper(cwd: string, config = loadConfig(cwd)): Promise<string> {
	const providerSettings = config.provider ?? {};
	const claudeExecutable = resolveClaudeExecutable(providerSettings.pathToClaudeCodeExecutable);
	if (claudeExecutable) preflightClaudeExecutable(claudeExecutable, cwd);

	const helperQuery = query({
		prompt: "/extra-usage",
		options: {
			cwd,
			env: { ...process.env, ENABLE_CLAUDEAI_MCP_SERVERS: "0", DISABLE_AUTO_COMPACT: "1" },
			maxTurns: 1,
			...(claudeExecutable ? { pathToClaudeCodeExecutable: claudeExecutable } : {}),
			spawnClaudeCodeProcess: spawnClaudeCodeWithDiagnostics,
			...makeCliDebugOptions("extra-usage"),
		},
	});
	const outputs: string[] = [];
	try {
		for await (const message of helperQuery) {
			const text = sdkTextFromMessage(message)?.trim();
			if (text && outputs[outputs.length - 1] !== text) outputs.push(text);
		}
	} finally {
		helperQuery.close();
	}
	return outputs.join("\n").trim() || "Claude Code /extra-usage completed.";
}

function launchExtraUsageHelperIfAllowed(cwd: string, config: Config, reason: string): boolean {
	if (!extraUsageAllowed(config)) return false;
	if (extraUsageHelperInFlight) return true;
	extraUsageHelperInFlight = runExtraUsageHelper(cwd, config)
		.then((message) => {
			piUI?.notify(`Claude extra usage helper: ${message}`, "info");
			return message;
		})
		.catch((error) => {
			const message = error instanceof Error ? error.message : String(error);
			piUI?.notify(`Claude extra usage helper failed after ${reason}: ${message}`, "error");
			throw error;
		})
		.finally(() => { extraUsageHelperInFlight = null; });
	void extraUsageHelperInFlight.catch(() => {});
	return true;
}

const BRIDGE_SESSION_CUSTOM_TYPE = "claude-bridge-session";

interface PersistedBridgeSessionState extends SessionState {
	fingerprint: string;
	piSessionId?: string;
	updatedAt: string;
}

function fingerprintMessages(messages: Context["messages"]): string {
	const normalized = messages.map((message) => {
		if (message.role === "assistant") {
			return {
				role: message.role,
				provider: (message as AssistantMessage).provider,
				model: (message as AssistantMessage).model,
				content: (message as AssistantMessage).content,
			};
		}
		return message;
	});
	return createHash("sha256").update(JSON.stringify(normalized)).digest("hex");
}

function readBuiltSessionContext(sessionManager: unknown): { messages: Context["messages"] } | undefined {
	const built = typeof (sessionManager as any)?.buildSessionContext === "function" ? (sessionManager as any).buildSessionContext() : undefined;
	return Array.isArray(built?.messages) ? built as { messages: Context["messages"] } : undefined;
}

function latestPersistedBridgeSession(sessionManager: unknown): PersistedBridgeSessionState | undefined {
	const entries = typeof (sessionManager as any)?.getEntries === "function" ? (sessionManager as any).getEntries() : [];
	if (!Array.isArray(entries)) return undefined;
	for (let i = entries.length - 1; i >= 0; i--) {
		const entry = entries[i];
		if (entry?.type !== "custom" || entry.customType !== BRIDGE_SESSION_CUSTOM_TYPE) continue;
		const data = entry.data as Partial<PersistedBridgeSessionState> | undefined;
		if (!data || typeof data.sessionId !== "string" || typeof data.cursor !== "number" || typeof data.cwd !== "string" || typeof data.fingerprint !== "string") continue;
		return data as PersistedBridgeSessionState;
	}
	return undefined;
}

function claudeSessionExists(sessionId: string, cwd: string): boolean {
	try {
		const session = openSession({ sessionId, projectPath: cwd, claudeDir: process.env.CLAUDE_CONFIG_DIR });
		statSync(session.jsonlPath);
		return true;
	} catch {
		return false;
	}
}

function canonicalize(p: string | undefined): string | undefined {
	if (!p) return undefined;
	try { return realpathSync.native(p); } catch { return pathResolve(p); }
}

// Decides whether a persisted bridge-session marker is safe to restore.
//
// The fork case is the load-bearing one: pi/core's createBranchedSession copies
// every non-label entry from root→leaf into the new session file. That includes
// our claude-bridge-session markers from the parent. Restoring from them would
// --resume parent's Claude jsonl on the fork's first turn, leaking conversation
// past the fork point.
//
// Returns undefined when the entry is safe to use, or a short rejection reason
// for diagnostic logging. Old entries without piSessionId always reject, which
// degrades safely to the rebuild path.
export function shouldRestorePersistedBridgeEntry(
	persisted: { piSessionId?: string; cwd: string },
	currentPiSessionId: string | undefined,
	currentCwd: string | undefined,
): string | undefined {
	if (!persisted.piSessionId) return "missing piSessionId";
	if (currentPiSessionId && persisted.piSessionId !== currentPiSessionId) {
		return `piSessionId mismatch (persisted=${persisted.piSessionId} current=${currentPiSessionId})`;
	}
	if (currentCwd && canonicalize(persisted.cwd) !== canonicalize(currentCwd)) {
		return `cwd mismatch (persisted=${persisted.cwd} current=${currentCwd})`;
	}
	return undefined;
}

export function restoreSharedSessionFromPi(ctx: { sessionManager?: unknown; cwd?: string }): void {
	const persisted = latestPersistedBridgeSession(ctx.sessionManager);
	if (!persisted) return;
	const currentPiSessionId = typeof (ctx.sessionManager as any)?.getSessionId === "function" ? (ctx.sessionManager as any).getSessionId() : undefined;
	const currentCwd = typeof (ctx.sessionManager as any)?.getCwd === "function" ? (ctx.sessionManager as any).getCwd() : ctx.cwd;
	const rejection = shouldRestorePersistedBridgeEntry(persisted, currentPiSessionId, currentCwd);
	if (rejection) {
		debug(`restoreSharedSession: ${rejection} — forcing rebuild`);
		return;
	}
	const built = readBuiltSessionContext(ctx.sessionManager);
	if (!built) return;
	const cursor = Math.max(0, Math.min(persisted.cursor, built.messages.length));
	const fingerprint = fingerprintMessages(built.messages.slice(0, cursor));
	if (fingerprint !== persisted.fingerprint) {
		debug(`restoreSharedSession: fingerprint mismatch for ${persisted.sessionId.slice(0, 8)}`);
		return;
	}
	if (!claudeSessionExists(persisted.sessionId, persisted.cwd)) {
		debug(`restoreSharedSession: Claude session missing for ${persisted.sessionId.slice(0, 8)}`);
		return;
	}
	sharedSession = { sessionId: persisted.sessionId, cursor, cwd: persisted.cwd };
	debug(`restoreSharedSession: restored ${persisted.sessionId.slice(0, 8)}, cursor=${cursor}`);
}

function schedulePersistSharedSession(ctxLike?: { sessionManager?: unknown }): void {
	if (!extensionApi || !sharedSession || !ctxLike?.sessionManager) return;
	const snapshot = { ...sharedSession };
	const timer = setTimeout(() => {
		try {
			const built = readBuiltSessionContext(ctxLike.sessionManager);
			if (!built) return;
			const cursor = Math.max(0, Math.min(snapshot.cursor, built.messages.length));
			const data: PersistedBridgeSessionState = {
				...snapshot,
				cursor,
				fingerprint: fingerprintMessages(built.messages.slice(0, cursor)),
				piSessionId: typeof (ctxLike.sessionManager as any)?.getSessionId === "function" ? (ctxLike.sessionManager as any).getSessionId() : undefined,
				updatedAt: new Date().toISOString(),
			};
			extensionApi?.appendEntry(BRIDGE_SESSION_CUSTOM_TYPE, data);
			debug(`persistSharedSession: saved ${data.sessionId.slice(0, 8)}, cursor=${data.cursor}`);
		} catch (error) {
			debug("persistSharedSession failed:", error);
		}
	}, 0);
	timer.unref?.();
}

// Convert pi messages to Anthropic API format for session import.
// Lossy: non-Anthropic thinking blocks are dropped (no valid signature). User and
// tool-result image blocks are preserved when possible. If assistant blocks are
// otherwise incompatible, convertPiMessages emits a text placeholder so the record
// sequence stays valid before repairToolPairing runs.
function convertAndImportMessages(
	session: ReturnType<typeof createSession>,
	messages: Context["messages"],
	customToolNameToSdk?: Map<string, string>,
	cwd?: string,
): void {
	const { anthropicMessages, sanitizedIds } = convertPiMessages(messages, customToolNameToSdk);

	debug(`convertAndImportMessages: ${messages.length} pi msgs → ${anthropicMessages.length} anthropic msgs`);
	debug(`convertAndImportMessages: imported roles:`, anthropicMessages.map((m, i) => {
		const c = m.content;
		if (typeof c === "string") return `[${i}]${m.role}:text`;
		if (Array.isArray(c)) return `[${i}]${m.role}:${(c).map((b) => b.type).join("+")}`;
		return `[${i}]${m.role}:?`;
	}).join(" "));
	if (sanitizedIds.size > 0) {
		debug(`convertAndImportMessages: sanitized ${sanitizedIds.size} tool IDs:`,
			[...sanitizedIds.entries()].map(([orig, clean]) => orig === clean ? orig : `${orig}→${clean}`).join(", "));
	}
	// Pre-repair for debug logging; importMessages also repairs internally (idempotent).
	const missingToolResults = findUnpairedToolUses(anthropicMessages);
	const repaired = repairToolPairing(anthropicMessages);
	if (missingToolResults.length > 0) {
		reportSyntheticToolResultRepair(missingToolResults, {
			cwd,
			messageCount: messages.length,
			anthropicMessageCount: anthropicMessages.length,
			sessionId: session.sessionId,
			jsonlPath: session.jsonlPath,
		});
	}
	if (repaired.length !== anthropicMessages.length) {
		debug(`convertAndImportMessages: repairToolPairing ${anthropicMessages.length} → ${repaired.length} msgs`);
	}
	if (repaired.length) session.importMessages(repaired);
}

// Pi doesn't pass tool results directly — it appends them to the context and calls
// the provider again. Thin wrapper over extract-tool-results.js that adds per-turn
// debug logging at the extraction boundary.
function extractAllToolResults(context: Context): McpResult[] {
	const { results, stopIdx } = _extractAllToolResults(context.messages as unknown as Array<{ role: string; [key: string]: unknown }>);
	debug(`extractAllToolResults: ${results.length} results from ${context.messages.length} msgs, stopped at index ${stopIdx}`);
	debug(`extractAllToolResults: all msg roles:`, context.messages.map((m, i) => `[${i}]${m.role}`).join(" "));
	for (let r = 0; r < results.length; r++) {
		debug(`extractAllToolResults: result[${r}] id=${results[r].toolCallId}${results[r].isError ? " ERROR" : ""} preview:`, JSON.stringify(results[r].content).slice(0, 150));
	}
	return results;
}

/** Extract the last user message from context as a prompt string. Returns null if last message is not a user message. */
function extractUserPrompt(messages: Context["messages"]): string | null {
	const last = messages[messages.length - 1];
	if (!last || last.role !== "user") return null;
	if (typeof last.content === "string") return last.content;
	return messageContentToText(last.content) || "";
}

/** Extract the last user message as ContentBlockParam[] (preserving images).
 *  Returns null if no images — caller should fall back to string prompt. */
function extractUserPromptBlocks(messages: Context["messages"]): ContentBlockParam[] | null {
	const last = messages[messages.length - 1];
	if (!last || last.role !== "user") return null;
	if (typeof last.content === "string") {
		debug(`extractUserPromptBlocks: content is string (length=${last.content.length})`);
		return null;
	}
	if (!Array.isArray(last.content)) {
		debug(`extractUserPromptBlocks: content is ${typeof last.content}`);
		return null;
	}
	debug(`extractUserPromptBlocks: ${last.content.length} blocks, types=${last.content.map((b: any) => b.type).join(",")}`);
	let hasImage = false;
	const blocks: ContentBlockParam[] = [];
	for (const block of last.content) {
		if (block.type === "text" && block.text) {
			blocks.push({ type: "text", text: block.text });
		} else if (block.type === "image") {
			debug(`image block: mimeType=${(block as any).mimeType}, data length=${((block as any).data ?? "").length}, keys=${Object.keys(block).join(",")}`);
			if (!(block as any).data || !(block as any).mimeType) {
				debug(`image block missing data or mimeType, skipping`);
				continue;
			}
			hasImage = true;
			blocks.push({
				type: "image",
				source: { type: "base64", media_type: block.mimeType as Base64ImageSource["media_type"], data: block.data },
			});
		}
	}
	return hasImage ? blocks : null;
}

async function* wrapPromptStream(blocks: ContentBlockParam[]): AsyncIterable<SDKUserMessage> {
	yield {
		type: "user",
		message: { role: "user", content: blocks } as MessageParam,
		parent_tool_use_id: null,
	};
}


interface SyncResult {
	sessionId: string | null;
}

/**
 * Ensure the shared session has all messages up to (but not including) the last user message.
 * Returns session ID to resume from, or null if no resume needed.
 */
// Read the session file we just wrote and sanity-check it. Warns instead of
// throwing — CC may be more tolerant than our checks, so a false positive
// shouldn't block the user. Pure logic is in session-verify.js; this wrapper
// fans each warning out to debug log + piUI notify + diagDump.
function verifyWrittenSession(
	jsonlPath: string,
	expectedSessionId: string,
	expectedRecordCount: number,
	cwd: string,
): void {
	const warnings = _verifyWrittenSession(jsonlPath, expectedSessionId, expectedRecordCount);
	for (const msg of warnings) {
		debug(`WARNING session verify: ${msg}`);
		piUI?.notify(
			`Session file issue: ${msg}\n` +
			`cwd=${cwd} realpath=${safeRealpath(cwd)} CLAUDE_CONFIG_DIR=${process.env.CLAUDE_CONFIG_DIR ?? "(unset)"}\n` +
			`Please copy and paste this message into a new issue at https://github.com/elidickinson/pi-claude-bridge/issues/new` +
			(DEBUG ? ` and attach ${DEBUG_LOG_PATH}` : ` (rerun with CLAUDE_BRIDGE_DEBUG=1 to capture a debug log)`),
			"warning",
		);
		diagDump("session_verify_fail", { msg, jsonlPath, cwd, realpath: safeRealpath(cwd), claudeConfigDir: process.env.CLAUDE_CONFIG_DIR ?? null });
	}
}

function safeRealpath(p: string): string {
	try { return realpathSync(p); } catch (e) { return `<failed: ${(e as Error).message}>`; }
}

// Diagnostic snapshot of where a session file was just written. Catches the
// class of bugs where pi writes to ~/.claude/projects/<X> but CC SDK reads
// from ~/.claude/projects/<Y> (symlinks, CLAUDE_CONFIG_DIR, hash mismatch).
function debugSessionPaths(label: string, cwd: string, jsonlPath: string): void {
	const realCwd = safeRealpath(cwd);
	let fileSize: number | null = null;
	let fileExists = false;
	try {
		const st = statSync(jsonlPath);
		fileExists = true;
		fileSize = st.size;
	} catch { /* file may not exist yet */ }
	debug(`${label}: cwd=${cwd}`);
	if (realCwd !== cwd) debug(`${label}: realpath(cwd)=${realCwd} (DIFFERS — symlink-resolved path is what CC SDK uses)`);
	debug(`${label}: jsonlPath=${jsonlPath}`);
	debug(`${label}: fileExists=${fileExists}${fileSize != null ? ` size=${fileSize}` : ""}`);
	debug(`${label}: env.CLAUDE_CONFIG_DIR=${process.env.CLAUDE_CONFIG_DIR ?? "(unset)"} HOME=${process.env.HOME ?? "(unset)"}`);
}

// Two semantic paths:
//   REUSE — pi's history is in sync with the existing sharedSession (or drifted
//     only by the trailing final-assistant message that pi appends after
//     streamSimple returns, which CC's own persisted session already has).
//     Returns the existing sessionId. Keeps CC's prompt cache warm.
//   REBUILD — no session yet, or pi's history has diverged (non-trailing
//     missed messages, e.g. another provider took a turn). Wipes the existing
//     session file (if any) and writes a fresh one containing all prior
//     messages, reusing the same sessionId across rebuilds so UUIDs stay
//     stable for the lifetime of pi's session.
//
// Why a full rebuild rather than patching:
//   Injecting deltas into an existing session creates a branch that CC's
//   --resume doesn't follow (documented attempt prior to this). A complete
//   overwrite at the same path is simpler and correct.
//
// Why reuse the sessionId across rebuilds:
//   CC re-reads the JSONL on every --resume call — no in-process UUID
//   caching. Validated in tests/exp-session-clear.mjs, including the case
//   where CC had appended its own tool_use/tool_result records between
//   rebuilds. Preserving the UUID means stable log correlation across
//   provider switches and no orphaned session files.
//
// Log strings still say "Case 1/2/3/4" so existing diagnostics (int-cache.sh,
// int-session-resume.mjs) keep grepping the same anchors.
function syncSharedSession(
	messages: Context["messages"],
	cwd: string,
	customToolNameToSdk?: Map<string, string>,
	modelId?: string,
): SyncResult {
	const priorMessages = messages.slice(0, -1); // everything before the new user prompt

	// REUSE path
	if (sharedSession && !sharedSession.needsRebuild) {
		const missed = priorMessages.slice(sharedSession.cursor);
		const trailingAssistantOnly =
			missed.length === 1 && (missed[0] as { role?: string }).role === "assistant";
		if (missed.length === 0 || trailingAssistantOnly) {
			if (trailingAssistantOnly) {
				sharedSession = { ...sharedSession, cursor: priorMessages.length, cwd };
			}
			debug(`Case 3: ${trailingAssistantOnly ? "advanced cursor past trailing assistant, " : ""}resuming session ${sharedSession.sessionId.slice(0, 8)}, cursor=${sharedSession.cursor}`);
			debug(`syncResult: path=reuse sessionId=${sharedSession.sessionId} cursor=${sharedSession.cursor}`);
			return { sessionId: sharedSession.sessionId };
		}
	}

	// REBUILD path
	if (priorMessages.length === 0) {
		debug(`Case 1: clean start, ${messages.length} total messages`);
		debug(`syncResult: path=clean-start`);
		return { sessionId: null };
	}
	const previousSessionId = sharedSession?.sessionId;
	const previousCursor = sharedSession?.cursor ?? 0;
	// preserveId: rebuild in place (deleteSession + createSession with the
	// existing UUID), so prompt-cache UUIDs stay stable for log correlation
	// and for any tools that key off them. Skipped only when there's a
	// concurrent writer we shouldn't race — see forceRotate docs above.
	const preserveId = previousSessionId !== undefined && !sharedSession?.forceRotate;
	if (preserveId) {
		// Wipe prior jsonl + companion dir (no-op if nothing to wipe).
		deleteSession(previousSessionId!, cwd, process.env.CLAUDE_CONFIG_DIR);
	}
	const session = createSession({
		projectPath: cwd,
		claudeDir: process.env.CLAUDE_CONFIG_DIR,
		...(preserveId ? { sessionId: previousSessionId } : {}),
		...(modelId ? { model: modelId } : {}),
	});
	convertAndImportMessages(session, priorMessages, customToolNameToSdk, cwd);
	session.save();
	verifyWrittenSession(session.jsonlPath, session.sessionId, session.messages.length, cwd);
	sharedSession = { sessionId: session.sessionId, cursor: priorMessages.length, cwd };
	if (previousSessionId === undefined) {
		debug(`Case 2: first turn with ${priorMessages.length} prior messages → session ${session.sessionId.slice(0, 8)}, ${session.messages.length} records`);
	} else if (preserveId) {
		const missedCount = priorMessages.length - previousCursor;
		debug(`Case 4: ${missedCount} missed messages, ${priorMessages.length} total → rewrote session ${session.sessionId.slice(0, 8)} (same id), ${session.messages.length} records`);
	} else {
		debug(`Case 4 post-abort: ${priorMessages.length} total → new session ${session.sessionId.slice(0, 8)} (was ${previousSessionId.slice(0, 8)}, rotated to avoid race with orphan writer), ${session.messages.length} records`);
	}
	debugSessionPaths(`${session.sessionId.slice(0, 8)}`, cwd, session.jsonlPath);
	debug(`syncResult: path=rebuild sessionId=${session.sessionId} priors=${priorMessages.length} ${previousSessionId === undefined ? "first" : preserveId ? "preserved" : "rotated-post-abort"}`);
	return { sessionId: session.sessionId };
}

// --- Provider helpers: tool name mapping ---

export function mapToolName(name: string, customToolNameToPi?: Map<string, string>): string {
	const normalized = name.toLowerCase();
	const builtin = SDK_TO_PI_TOOL_NAME[normalized];
	if (builtin) return builtin;
	if (customToolNameToPi) {
		const mapped = customToolNameToPi.get(name) ?? customToolNameToPi.get(normalized);
		if (mapped) return mapped;
	}
	for (const prefix of [
		MCP_TOOL_PREFIX,
		`mcp__${MCP_SERVER_NAME.replace(/-/g, "_")}__`,
		`mcp/${MCP_SERVER_NAME}/`,
		`mcp/${MCP_SERVER_NAME.replace(/-/g, "_")}/`,
	]) {
		if (normalized.startsWith(prefix)) return normalized.slice(prefix.length);
	}
	return name;
}

// Renames for Claude Code SDK param names that differ from pi's native names.
// Keys not listed here pass through unchanged, so new pi params work automatically.
const SDK_KEY_RENAMES: Record<string, Record<string, string>> = {
	read:  { file_path: "path" },
	write: { file_path: "path" },
	edit:  { file_path: "path", old_string: "oldText", new_string: "newText", old_text: "oldText", new_text: "newText" },
};

// Maps SDK tool args to pi tool args via key renaming + pass-through.
// Pi's own prepareArguments hooks handle any structural transforms (e.g. edit oldText/newText → edits[]).
function mapToolArgs(
	toolName: string, args: Record<string, unknown> | undefined,
): Record<string, unknown> {
	const input = args ?? {};
	const renames = SDK_KEY_RENAMES[toolName.toLowerCase()];
	const result: Record<string, unknown> = {};
	for (const [key, value] of Object.entries(input)) {
		const piKey = renames?.[key] ?? key;
		if (!(piKey in result)) result[piKey] = value; // first alias wins
	}
	// Pi bash has no default timeout; add a safety default
	if (toolName.toLowerCase() === "bash" && result.timeout == null) {
		result.timeout = 120;
	}
	return result;
}

// --- Provider helpers: tool resolution ---

// --- Provider helpers: tool bridge ---

// --- Query state ---
// QueryContext + context stack live in query-state.js so tests can import
// them without activating the extension. `ctx()`, `pushContext()`, `popContext()`
// are imported at the top of this file.

function resolveMcpTools(context: Context, excludeToolName?: string): {
	mcpTools: Tool[];
	customToolNameToSdk: Map<string, string>;
	customToolNameToPi: Map<string, string>;
} {
	const mcpTools: Tool[] = [];
	const customToolNameToSdk = new Map<string, string>();
	const customToolNameToPi = new Map<string, string>();

	if (!context.tools) return { mcpTools, customToolNameToSdk, customToolNameToPi };

	for (const tool of context.tools) {
		if (tool.name === excludeToolName) continue;
		const sdkName = `${MCP_TOOL_PREFIX}${tool.name}`;
		mcpTools.push(tool);
		customToolNameToSdk.set(tool.name, sdkName);
		customToolNameToSdk.set(tool.name.toLowerCase(), sdkName);
		customToolNameToPi.set(sdkName, tool.name);
		customToolNameToPi.set(sdkName.toLowerCase(), tool.name);
	}

	return { mcpTools, customToolNameToSdk, customToolNameToPi };
}

// Creates an MCP server that bridges pi tools to the SDK. Each tool handler
// blocks on a Promise until pi delivers the tool result via streamSimple.
// Handlers claim their tool_call id by matching the actual MCP call
// (tool name + arguments) against the recorded tool_use blocks, then results
// are matched by ID. Handlers close over the captured `queryCtx`, ensuring they
// operate on the correct query's state even across pushContext/popContext calls.
function buildMcpServers(tools: Tool[], queryCtx: QueryContext): Record<string, ReturnType<typeof createSdkMcpServer>> | undefined {
	if (!tools.length) return undefined;
	const mcpTools = tools.map((tool) => ({
		name: tool.name,
		description: tool.description,
		inputSchema: jsonSchemaToZodShape(tool.parameters),
		handler: async (args?: Record<string, unknown>) => {
			const mappedArgs = mapToolArgs(tool.name, args);
			const claim = queryCtx.claimToolCall(tool.name, mappedArgs);
			const toolCallId = claim.toolCallId;
			if (!toolCallId) {
				debug(`WARNING: mcp handler ${tool.name} has no toolCallId (available=${claim.available})`);
				diagDump("tool_handler_unmatched", {
					toolName: tool.name,
					argKeys: argKeys(mappedArgs),
					available: claim.available,
					turnToolCallIds: queryCtx.turnToolCallIds,
					turnToolCalls: safeToolCallSummary(queryCtx.turnToolCalls),
				});
				return { content: [{ type: "text", text: `Claude bridge internal error: no matching tool_call id for ${tool.name}` }], isError: true } satisfies McpResult;
			}
			if (claim.match !== "tool-args" || claim.ambiguous) {
				debug(`mcp handler: ${tool.name} [${toolCallId}] claimed by ${claim.match}${claim.ambiguous ? " (ambiguous)" : ""}`);
			}
			if (toolCallId && queryCtx.pendingResults.has(toolCallId)) {
				const result = queryCtx.pendingResults.get(toolCallId)!;
				queryCtx.pendingResults.delete(toolCallId);
				queryCtx.markToolResultResolved(toolCallId);
				debug(`mcp handler: ${tool.name} [${toolCallId}] → resolved from queue (${queryCtx.pendingResults.size} remaining)`);
				return result;
			}
			debug(`mcp handler: ${tool.name} [${toolCallId}] → waiting`);
			return new Promise<McpResult>((resolve) => {
				queryCtx.pendingToolCalls.set(toolCallId, {
					toolName: tool.name,
					resolve: (result) => {
						queryCtx.markToolResultResolved(toolCallId);
						resolve(result);
					},
				});
			});
		},
	}));
	const server = createSdkMcpServer({ name: MCP_SERVER_NAME, version: "1.0.0", tools: mcpTools });
	return { [MCP_SERVER_NAME]: server };
}

// --- Usage helpers ---

function updateUsage(output: AssistantMessage, usage: Record<string, number | undefined>, model: Model<any>): void {
	if (usage.input_tokens != null) output.usage.input = usage.input_tokens;
	if (usage.output_tokens != null) output.usage.output = usage.output_tokens;
	if (usage.cache_read_input_tokens != null) output.usage.cacheRead = usage.cache_read_input_tokens;
	if (usage.cache_creation_input_tokens != null) output.usage.cacheWrite = usage.cache_creation_input_tokens;
	output.usage.totalTokens = output.usage.input + output.usage.output + output.usage.cacheRead + output.usage.cacheWrite;
	calculateCost(model, output.usage);
	const promptTokens = output.usage.input + output.usage.cacheRead + output.usage.cacheWrite;
	const cachePct = promptTokens > 0 ? Math.round(output.usage.cacheRead / promptTokens * 100) : 0;
	debug(`usage: in=${output.usage.input} out=${output.usage.output} cacheRead=${output.usage.cacheRead} cacheWrite=${output.usage.cacheWrite} total=${output.usage.totalTokens} cachePct=${cachePct}% model=${model.id}`);
}

// --- Effort level mapping ---
// Pi reasoning levels → CC SDK effort levels

const REASONING_TO_EFFORT: Record<string, EffortLevel> = {
	minimal: "low", low: "low", medium: "medium", high: "high", xhigh: "max",
};

function normalizeEffortOverrideModelKey(value: string): string {
	const key = value.trim().toLowerCase();
	return key.startsWith(`${PROVIDER_ID}/`) ? key.slice(PROVIDER_ID.length + 1) : key;
}

export function resolveConfiguredEffort(
	modelId: string,
	reasoningEffort: EffortLevel | undefined,
	providerConfig?: Config["provider"],
): EffortLevel | undefined {
	const target = normalizeEffortOverrideModelKey(modelId);
	for (const [key, rawEffort] of Object.entries(providerConfig?.modelEffortOverrides ?? {})) {
		const normalizedKey = normalizeEffortOverrideModelKey(key);
		if (normalizedKey !== "*" && normalizedKey !== target) continue;
		const effort = normalizeEffortLevel(rawEffort) as EffortLevel | undefined;
		if (effort) return effort;
	}
	return (normalizeEffortLevel(providerConfig?.forceEffort) as EffortLevel | undefined) ?? reasoningEffort;
}

// --- Provider helpers: misc ---

function mapStopReason(reason: string | undefined): "stop" | "length" | "toolUse" {
	switch (reason) {
		case "tool_use": return "toolUse";
		case "max_tokens": return "length";
		case "end_turn": default: return "stop";
	}
}

function parsePartialJson(input: string, fallback: Record<string, unknown>): Record<string, unknown> {
	if (!input) return fallback;
	try { return JSON.parse(input); } catch { return fallback; }
}


// --- Provider: streaming function ---
//
// Push-based streaming with MCP tool bridge:
// 1. streamSimple starts a query() and kicks off consumeQuery() in background
// 2. consumeQuery() iterates the SDK generator, pushing events to currentPiStream
// 3. On tool_use: ends the current pi stream, nulls it out. The MCP handler
//    blocks the generator naturally — no events arrive until resolved.
// 4. Pi executes the tool, calls streamSimple again. We swap in the new stream,
//    resolve the MCP handler, and the generator unblocks — events flow to new stream.
//
// Note: resetTurnState clears turnSawStreamEvent while the generator may still
// have queued messages from the previous turn. This is safe because step 3 nulls
// currentPiStream, so any leftover messages hit the `!ctx().currentPiStream` guard
// in consumeQuery and are skipped before resetTurnState runs.

function ensureTurnStarted(): void {
	if (!ctx().turnStarted && ctx().currentPiStream && ctx().turnOutput) {
		ctx().currentPiStream!.push({ type: "start", partial: ctx().turnOutput });
		ctx().turnStarted = true;
	}
}

function finalizeCurrentStream(stopReason?: string): void {
	if (!ctx().currentPiStream || !ctx().turnOutput) return;
	debug(`provider: finalizeCurrentStream called, stopReason=${stopReason}, turnOutput=${JSON.stringify({stopReason: ctx().turnOutput!.stopReason, error: ctx().turnOutput!.errorMessage})}`);
	if (!ctx().turnStarted) ensureTurnStarted();
	const reason = stopReason === "length" ? "length" : "stop";
	ctx().currentPiStream!.push({ type: "done", reason, message: ctx().turnOutput });
	ctx().currentPiStream!.end();
	ctx().currentPiStream = null;
}

/** Maps Anthropic stream events to pi stream events (text, thinking, toolcall).
 *  On message_stop with tool_use: ends currentPiStream so pi can execute the tool. */
export function processStreamEvent(
	message: SDKMessage,
	customToolNameToPi: Map<string, string>,
	model: Model<any>,
): void {
	const c = ctx();
	if (!c.currentPiStream || !c.turnOutput) return;
	const event = (message as SDKMessage & { event: any }).event;
	if (event?.type === "ping") return;
	if (event?.type === "message_stop" && !c.turnSawToolCall) {
		debug("processStreamEvent: ignoring bare message_stop with no streamed content/tool call");
		return;
	}

	if (event?.type === "message_start") {
		c.resetToolTracking();
		if (event.message?.usage) updateUsage(c.turnOutput, event.message.usage, model);
		return;
	}

	if (event?.type === "content_block_start") {
		c.turnSawStreamEvent = true;
		ensureTurnStarted();
		if (event.content_block?.type === "text") {
			c.turnBlocks.push({ type: "text", text: "", index: event.index });
			c.currentPiStream!.push({ type: "text_start", contentIndex: c.turnBlocks.length - 1, partial: c.turnOutput });
		} else if (event.content_block?.type === "thinking") {
			c.turnBlocks.push({ type: "thinking", thinking: "", thinkingSignature: "", index: event.index });
			c.currentPiStream!.push({ type: "thinking_start", contentIndex: c.turnBlocks.length - 1, partial: c.turnOutput });
		} else if (event.content_block?.type === "tool_use") {
			c.turnSawToolCall = true;
			const mappedName = mapToolName(event.content_block.name, customToolNameToPi);
			c.recordToolCall(event.content_block.id, mappedName, {});
			c.turnBlocks.push({
				type: "toolCall", id: event.content_block.id,
				name: mappedName,
				arguments: (event.content_block.input as Record<string, unknown>) ?? {},
				partialJson: "", index: event.index,
			});
			c.currentPiStream!.push({ type: "toolcall_start", contentIndex: c.turnBlocks.length - 1, partial: c.turnOutput });
		} else {
			debug("processStreamEvent: unhandled content_block_start type", event.content_block?.type);
		}
		return;
	}

	if (event?.type === "content_block_delta") {
		const index = c.turnBlocks.findIndex((b: any) => b.index === event.index);
		const block = c.turnBlocks[index];
		if (!block) {
			debug("processStreamEvent: ignoring unmatched content_block_delta", event.index);
			return;
		}
		c.turnSawStreamEvent = true;
		if (event.delta?.type === "text_delta" && block.type === "text") {
			block.text += event.delta.text;
			c.currentPiStream!.push({ type: "text_delta", contentIndex: index, delta: event.delta.text, partial: c.turnOutput });
		} else if (event.delta?.type === "thinking_delta" && block.type === "thinking") {
			block.thinking += event.delta.thinking;
			c.currentPiStream!.push({ type: "thinking_delta", contentIndex: index, delta: event.delta.thinking, partial: c.turnOutput });
		} else if (event.delta?.type === "input_json_delta" && block.type === "toolCall") {
			block.partialJson += event.delta.partial_json;
			block.arguments = parsePartialJson(block.partialJson, block.arguments);
			c.currentPiStream!.push({ type: "toolcall_delta", contentIndex: index, delta: event.delta.partial_json, partial: c.turnOutput });
		} else if (event.delta?.type === "signature_delta" && block.type === "thinking") {
			block.thinkingSignature = (block.thinkingSignature ?? "") + event.delta.signature;
		} else {
			debug("processStreamEvent: unhandled content_block_delta type", event.delta?.type);
		}
		return;
	}

	if (event?.type === "content_block_stop") {
		const index = c.turnBlocks.findIndex((b: any) => b.index === event.index);
		const block = c.turnBlocks[index];
		if (!block) {
			debug("processStreamEvent: ignoring unmatched content_block_stop", event.index);
			return;
		}
		c.turnSawStreamEvent = true;
		delete block.index;
		if (block.type === "text") {
			c.currentPiStream!.push({ type: "text_end", contentIndex: index, content: block.text, partial: c.turnOutput });
		} else if (block.type === "thinking") {
			c.currentPiStream!.push({ type: "thinking_end", contentIndex: index, content: block.thinking, partial: c.turnOutput });
		} else if (block.type === "toolCall") {
			c.turnSawToolCall = true;
			block.arguments = mapToolArgs(
				block.name, parsePartialJson(block.partialJson, block.arguments),
			);
			c.updateToolCallArgs(block.id, block.arguments);
			delete block.partialJson;
			c.currentPiStream!.push({ type: "toolcall_end", contentIndex: index, toolCall: block, partial: c.turnOutput });
		}
		return;
	}

	if (event?.type === "message_delta") {
		c.turnOutput.stopReason = mapStopReason(event.delta?.stop_reason);
		if (event.usage) updateUsage(c.turnOutput, event.usage, model);
		return;
	}

	if (event?.type === "message_stop" && c.turnSawToolCall) {
		// Tool call complete — end this pi stream. The SDK will still yield an
		// assistant message for this turn, but currentPiStream=null causes
		// consumeQuery to skip it. The MCP handler blocks the generator until
		// pi delivers the tool result via the next streamSimple call.
		c.turnOutput.stopReason = "toolUse";
		c.currentPiStream!.push({ type: "done", reason: "toolUse", message: c.turnOutput });
		c.currentPiStream!.end();
		c.currentPiStream = null;

		// Cursor is updated by the next streamSimple call (tool result delivery path)
		// which sets cursor = context.messages.length with the post-tool-result context.
		return;
	}

	if (event?.type !== "message_stop" && event?.type !== "ping") {
		debug("processStreamEvent: unhandled event type", event?.type);
	}
}

// The SDK always yields `assistant` messages (completed content blocks) after streaming.
// When stream_events already delivered the content, this is a no-op. But after
// resetTurnState (e.g. tool result delivery), if the next turn's assistant message
// arrives before any stream_events, this is the primary content path. Must maintain
// the same stream lifecycle as processStreamEvent — including ending the stream on
// tool_use to prevent deadlock with the MCP handler.
function appendMissingToolUsesFromAssistant(
	assistantMsg: { content?: Array<any>; usage?: Record<string, number | undefined> },
	model: Model<any>,
	customToolNameToPi: Map<string, string>,
): boolean {
	const c = ctx();
	if (!assistantMsg?.content) return false;
	let sawToolUse = false;
	for (const block of assistantMsg.content) {
		if (block.type !== "tool_use") continue;
		sawToolUse = true;
		const existingIdx = c.turnBlocks.findIndex((b: any) => b.type === "toolCall" && b.id === block.id);
		const name = mapToolName(block.name, customToolNameToPi);
		const mappedArgs = mapToolArgs(name, block.input);
		c.recordToolCall(block.id, name, mappedArgs);
		if (existingIdx >= 0) {
			const existing = c.turnBlocks[existingIdx] as any;
			existing.name = name;
			existing.arguments = mappedArgs;
			c.updateToolCallArgs(block.id, mappedArgs);
			if ("partialJson" in existing) {
				delete existing.partialJson;
				delete existing.index;
				c.currentPiStream?.push({ type: "toolcall_end", contentIndex: existingIdx, toolCall: existing, partial: c.turnOutput });
			}
			continue;
		}

		ensureTurnStarted();
		c.turnBlocks.push({
			type: "toolCall", id: block.id,
			name,
			arguments: mappedArgs,
		});
		const idx = c.turnBlocks.length - 1;
		const toolBlock = c.turnBlocks[idx];
		c.currentPiStream?.push({ type: "toolcall_start", contentIndex: idx, partial: c.turnOutput });
		c.currentPiStream?.push({ type: "toolcall_end", contentIndex: idx, toolCall: toolBlock as any, partial: c.turnOutput });
	}
	if (assistantMsg.usage && c.turnOutput) updateUsage(c.turnOutput, assistantMsg.usage, model);
	return sawToolUse;
}

export function processAssistantMessage(message: SDKMessage, model: Model<any>, customToolNameToPi: Map<string, string>): void {
	const c = ctx();
	const assistantMsg = (message as any).message;
	if (!assistantMsg?.content) return;
	if (c.turnSawStreamEvent) {
		// Claude Agent SDK can yield the completed assistant message before (or
		// instead of) a stream_event message_stop for a tool-use turn. Treat that
		// assistant message as a hard turn boundary so Pi executes the tool calls
		// and the MCP handlers stay blocked until real tool results are delivered.
		// Without this fallback, Claude Code can continue internally with empty MCP
		// results and Pi only sees the real outputs one render cycle later.
		if (appendMissingToolUsesFromAssistant(assistantMsg, model, customToolNameToPi)) {
			c.turnSawToolCall = true;
			if (c.currentPiStream && c.turnOutput) {
				c.turnOutput.stopReason = "toolUse";
				c.currentPiStream.push({ type: "done", reason: "toolUse", message: c.turnOutput });
				c.currentPiStream.end();
				c.currentPiStream = null;
				debug("processAssistantMessage boundary: ended streamed tool_use turn from assistant message");
			}
		}
		return;
	}
	c.resetToolTracking();
	debug(`processAssistantMessage fallback: ${assistantMsg.content.length} blocks, types=${assistantMsg.content.map((b: any) => b.type).join(",")}`);
	for (const block of assistantMsg.content) {
		if (block.type === "text" && block.text) {
			ensureTurnStarted();
			c.turnBlocks.push({ type: "text", text: block.text });
			const idx = c.turnBlocks.length - 1;
			c.currentPiStream?.push({ type: "text_start", contentIndex: idx, partial: c.turnOutput });
			c.currentPiStream?.push({ type: "text_delta", contentIndex: idx, delta: block.text, partial: c.turnOutput });
			c.currentPiStream?.push({ type: "text_end", contentIndex: idx, content: block.text, partial: c.turnOutput });
		} else if (block.type === "thinking") {
			ensureTurnStarted();
			c.turnBlocks.push({ type: "thinking", thinking: block.thinking ?? "", thinkingSignature: block.signature ?? "" });
			const idx = c.turnBlocks.length - 1;
			c.currentPiStream?.push({ type: "thinking_start", contentIndex: idx, partial: c.turnOutput });
			if (block.thinking) c.currentPiStream?.push({ type: "thinking_delta", contentIndex: idx, delta: block.thinking, partial: c.turnOutput });
			c.currentPiStream?.push({ type: "thinking_end", contentIndex: idx, content: block.thinking ?? "", partial: c.turnOutput });
		} else if (block.type === "tool_use") {
			ensureTurnStarted();
			c.turnSawToolCall = true;
			const mappedName = mapToolName(block.name, customToolNameToPi);
			const mappedArgs = mapToolArgs(mappedName, block.input);
			c.recordToolCall(block.id, mappedName, mappedArgs);
			c.turnBlocks.push({
				type: "toolCall", id: block.id,
				name: mappedName,
				arguments: mappedArgs,
			});
			const idx = c.turnBlocks.length - 1;
			const toolBlock = c.turnBlocks[idx];
			c.currentPiStream?.push({ type: "toolcall_start", contentIndex: idx, partial: c.turnOutput });
			c.currentPiStream?.push({ type: "toolcall_end", contentIndex: idx, toolCall: toolBlock as any, partial: c.turnOutput });
		} else {
			debug("processAssistantMessage: unhandled block type", block.type);
		}
	}
	if (assistantMsg.usage && c.turnOutput) updateUsage(c.turnOutput, assistantMsg.usage, model);

	// End the stream on tool_use, same as processStreamEvent's message_stop handler.
	if (c.turnSawToolCall && c.currentPiStream && c.turnOutput) {
		c.turnOutput.stopReason = "toolUse";
		c.currentPiStream.push({ type: "done", reason: "toolUse", message: c.turnOutput });
		c.currentPiStream.end();
		c.currentPiStream = null;
	}
}

/** Background consumer: iterates the SDK generator, pushing events to currentPiStream.
 *  Runs until the query ends. Per turn, the SDK yields stream_events (deltas), then
 *  an assistant message (completed blocks). On tool_use, the stream is ended by
 *  whichever path handles it first (processStreamEvent or processAssistantMessage),
 *  and the MCP handler blocks the generator until pi delivers the tool result. */
async function consumeQuery(
	sdkQuery: ReturnType<typeof query>,
	customToolNameToPi: Map<string, string>,
	model: Model<any>,
	cwd: string,
	bridgeConfig: Config,
	wasAborted: () => boolean,
): Promise<{ capturedSessionId?: string }> {
	let capturedSessionId: string | undefined;

	for await (const message of sdkQuery) {
		if (wasAborted()) break;
		if (!ctx().currentPiStream || !ctx().turnOutput) continue;

		switch (message.type) {
			case "stream_event":
				processStreamEvent(message, customToolNameToPi, model);
				break;
			case "assistant":
				processAssistantMessage(message, model, customToolNameToPi);
				break;
			case "result":
				if (!ctx().turnSawStreamEvent && message.subtype === "success") {
					ensureTurnStarted();
					const text = message.result || "";
					ctx().turnBlocks.push({ type: "text", text });
					const idx = ctx().turnBlocks.length - 1;
					ctx().currentPiStream?.push({ type: "text_start", contentIndex: idx, partial: ctx().turnOutput });
					ctx().currentPiStream?.push({ type: "text_delta", contentIndex: idx, delta: text, partial: ctx().turnOutput });
					ctx().currentPiStream?.push({ type: "text_end", contentIndex: idx, content: text, partial: ctx().turnOutput });
				} else if (message.subtype !== "success" && isExtraUsageRequiredMessage(message)) {
					const errorLines = Array.isArray((message as any).errors) ? uniqueNonEmptyLines((message as any).errors) : [];
					const errors = errorLines.length > 0 ? errorLines.join("\n") : String(message.subtype ?? "Claude Code rate limit");
					const openedExtraUsage = launchExtraUsageHelperIfAllowed(cwd, bridgeConfig, "result error");
					ctx().handledTerminalError = true;
					ctx().turnOutput.stopReason = "error";
					ctx().turnOutput.errorMessage = `${errors}${openedExtraUsage ? "\n\nOpened Claude Code /extra-usage helper. Complete billing/admin flow in the browser, then retry the prompt." : "\n\nRun /claude-bridge:extra, or enable Allow extra usage helper in settings."}`;
					ctx().currentPiStream?.push({ type: "error", reason: "error", error: ctx().turnOutput });
					ctx().currentPiStream?.end();
					ctx().currentPiStream = null;
				}
				break;
			case "system":
				if ((message as any).subtype === "init" && (message as any).session_id) {
					capturedSessionId = (message as any).session_id;
				}
				break;
			case "user":
				break; // SDK echo of user prompt — not needed
			case "rate_limit_event": {
				const info = (message as any).rate_limit_info;
				debug("consumeQuery: rate_limit_event", JSON.stringify(info).slice(0, 300));
				if (info?.status === "rejected") {
					const resetsAt = formatResetTimestamp(info.resetsAt);
					const resetAtMs = typeof info.resetsAt === "string" ? Date.parse(info.resetsAt) : undefined;
					const reason = `${info.rateLimitType ?? "unknown"} rate limit`;
					const launchedExtraUsage = isExtraUsageRequiredMessage(info) && launchExtraUsageHelperIfAllowed(cwd, bridgeConfig, reason);
					emitRateLimitEvent({
						model: model.id,
						provider: PROVIDER_ID,
						rateLimitType: info.rateLimitType,
						reason,
						resetAt: info.resetsAt,
						...(Number.isFinite(resetAtMs) ? { resetAtMs } : {}),
						source: "claude-bridge",
						status: "rejected",
					});
					piUI?.notify(`${RATE_LIMIT_TOKEN} Claude ${reason} hit — resets ${resetsAt}${launchedExtraUsage ? "; opened /extra-usage helper" : ""}`, "warning");
				} else if (info?.status === "allowed_warning") {
					piUI?.notify(`Claude rate limit warning: ${Math.round(info.utilization ?? 0)}% used (${info.rateLimitType ?? ""})`, "warning");
				}
				break;
			}
			default:
				debug("consumeQuery: unhandled SDK message type", message.type);
				break;
		}
	}

	// DEBUG: trace when consumeQuery exits
	debug(`consumeQuery: for-await loop exited, wasAborted=${wasAborted()}, capturedSessionId=${capturedSessionId?.slice(0, 8) ?? "none"}`);

	return { capturedSessionId };
}

/** Provider entry point. Pi calls this for each new prompt and each tool result.
 *  Two cases: tool result delivery (active query) or fresh query. */
function streamClaudeAgentSdk(model: Model<any>, context: Context, options?: SimpleStreamOptions): AssistantMessageEventStream {
	const stream = newAssistantMessageEventStream();

	// DEBUG: trace followUp message triggering
	const lastMsgRole = context.messages[context.messages.length - 1]?.role;
	debug(`provider: streamClaudeAgentSdk called, activeQuery=${!!ctx().activeQuery}, lastMsgRole=${lastMsgRole}, isReentrant=${ctx().activeQuery !== null}`);

	// --- Tool result delivery ---
	// Pi appends tool results to context and calls back. Extract this turn's results
	// (everything after the last assistant message) and match against waiting MCP
	// handlers. Results that arrive before their handler get queued in pendingResults.
	if (ctx().activeQuery) {
		const queryCtx = ctx();
		queryCtx.currentPiStream = stream;
		queryCtx.resetTurnState(model);
		const allResults = extractAllToolResults(context);
		debug(`provider: tool results, ${allResults.length} results, ${queryCtx.pendingToolCalls.size} waiting handlers, ctx.msgs=${context.messages.length}`);
		for (const result of allResults) {
			const id = result.toolCallId;
			queryCtx.markToolResultDelivered(id);
			if (id && queryCtx.pendingToolCalls.has(id)) {
				const pending = queryCtx.pendingToolCalls.get(id)!;
				queryCtx.pendingToolCalls.delete(id);
				debug(`provider: resolving ${pending.toolName} [${id}]${result.isError ? " (error)" : ""}`, JSON.stringify(result.content).slice(0, 200));
				pending.resolve(result);
			} else if (id) {
				queryCtx.pendingResults.set(id, result);
				debug(`provider: queued result [${id}] (${queryCtx.pendingResults.size} pending)`);
			} else {
				debug(`WARNING: tool result without toolCallId, cannot match`);
			}
			if (queryCtx.pendingToolCalls.size > 0 && queryCtx.pendingResults.size > 0) {
				debug(`BUG: both maps non-empty! handlers=${queryCtx.pendingToolCalls.size} results=${queryCtx.pendingResults.size}`);
			}
		}
		if (queryCtx.pendingToolCalls.size > 0) {
			debug(`WARNING: ${queryCtx.pendingToolCalls.size} MCP handlers still waiting after delivering ${allResults.length} results`);
			piUI?.notify(`Claude bridge: ${queryCtx.pendingToolCalls.size} tool handler(s) still waiting — provider may be stuck`, "warning");
		}

		// Detect user messages (steer/followUp) that pi injected into context
		// during the active query. This happens when:
		//   - User sends a steer while a tool is executing; pi drains the steer
		//     queue at the turn boundary and appends it to context alongside the
		//     tool result, then calls the provider again.
		//   - A followUp is delivered between tool-result turns.
		// The bridge can't forward these mid-query (the SDK query is in progress),
		// so we save them for replay as continuation queries after consumeQuery ends.
		if (lastMsgRole === "user") {
			const userPrompt = extractUserPrompt(context.messages);
			if (userPrompt) {
				ctx().deferredUserMessages.push(userPrompt);
				debug(`provider: deferred user message for replay after query: ${userPrompt.slice(0, 60)}`);
			}
		}

		if (sharedSession) sharedSession.cursor = context.messages.length;
		queryCtx.latestCursor = Math.max(queryCtx.latestCursor, context.messages.length);
		return stream;
	}

	// --- Orphaned tool result (e.g. user aborted a tool call) ---
	// The query is gone but pi still delivered the result. Nothing to do — just
	// emit end_turn so pi waits for the next real user message.
	const lastMsg = context.messages[context.messages.length - 1];
	if (lastMsg?.role === "toolResult") {
		debug(`provider: orphaned tool result after abort, emitting end_turn`);
		if (sharedSession) sharedSession.cursor = context.messages.length;
		const c = ctx();  // capture current context for the microtask
		queueMicrotask(() => {
			c.resetTurnState(model);
			stream.push({ type: "done", reason: "stop", message: c.turnOutput });
			stream.end();
		});
		return stream;
	}

	// --- Fresh query ---

	// 1. Determine reentrancy and push parent context if needed.
	const isReentrant = ctx().activeQuery !== null;
	if (isReentrant) pushContext();
	debug(`provider: fresh query setup, isReentrant=${isReentrant}, stackDepth=${stackDepth()}`);

	// 2. Fresh child context — constructor already gave us clean Maps and empty
	//    arrays. For a reused top-level context, clear explicitly.
	ctx().currentPiStream = stream;
	ctx().pendingToolCalls.clear();
	ctx().pendingResults.clear();
	ctx().deferredUserMessages = [];
	ctx().resetTurnState(model);
	ctx().resetToolTracking();
	ctx().latestCursor = 0;

	const { mcpTools, customToolNameToSdk, customToolNameToPi } = resolveMcpTools(context);
	const cwd = (options as { cwd?: string } | undefined)?.cwd ?? process.cwd();
	const promptBlocks = extractUserPromptBlocks(context.messages);
	let promptText = extractUserPrompt(context.messages) ?? "";

	// Guard: empty prompt means the last context message isn't a user message.
	// This should never happen with the state stack fix — dump diagnostics if it does.
	if (!promptText && !promptBlocks) {
		diagDump("empty_prompt", {
			contextLength: context.messages.length,
			lastMsgRole: lastMsg?.role,
			isReentrant,
			stackDepth: stackDepth(),
			activeQueryExists: ctx().activeQuery !== null,
			sharedSession: sharedSession ? { sessionId: sharedSession.sessionId.slice(0, 8), cursor: sharedSession.cursor } : null,
			messageRoles: context.messages.map((m, i) => `[${i}]${m.role}`).join(" "),
		});
		// Recover: use a continuation prompt so the SDK doesn't send an empty text block
		promptText = "[continue]";
	}

	const prompt: string | AsyncIterable<SDKUserMessage> = promptBlocks
		? wrapPromptStream(promptBlocks)
		: promptText;
	const mcpServers = buildMcpServers(mcpTools, ctx());
	const bridgeConfig = loadConfig(cwd);
	const providerSettings = bridgeConfig.provider ?? {};
	const appendSystemPrompt = providerSettings.appendSystemPrompt !== false;
	const agentsAppend = appendSystemPrompt ? extractAgentsAppend() : undefined;
	const skillsAppend = appendSystemPrompt ? extractSkillsBlock(context.systemPrompt) : undefined;
	const promptContextAppend = buildPromptContextAppend(context.systemPrompt, cwd, bridgeConfig.promptContext ?? {});
	const appendParts = [agentsAppend, skillsAppend, promptContextAppend.text].filter((part): part is string => Boolean(part));
	const systemPromptAppend = appendParts.length > 0 ? appendParts.join("\n\n") : undefined;

	// MCP auto-loading suppression: with appendSystemPrompt=true (default), the
	// SDK uses isolation mode and avoids filesystem settings. If users turn that
	// off, load user/project settings but pass --strict-mcp-config so Claude Code
	// ignores auto-discovered filesystem MCP servers while Pi owns tool execution.
	const settingSources: SettingSource[] | undefined = appendSystemPrompt
		? undefined
		: providerSettings.settingSources ?? ["user", "project"];
	const strictMcpConfigEnabled = !appendSystemPrompt && providerSettings.strictMcpConfig !== false;
	const claudeExecutable = resolveClaudeExecutable(providerSettings.pathToClaudeCodeExecutable);
	const claudeExecutablePreflight = claudeExecutable ? preflightClaudeExecutable(claudeExecutable, cwd) : undefined;
	const { sessionId: resumeSessionId } = syncSharedSession(context.messages, cwd, customToolNameToSdk, model.id);

	// Prefer the model's own thinkingLevelMap when present (pi-ai 0.72+ ships
	// per-model overrides — e.g. opus-4-7 wants xhigh→xhigh, not xhigh→max).
	// Fall back to our generic table for older pi-ai or unmapped levels.
	const requestedEffort = options?.reasoning
		? ((model as any).thinkingLevelMap?.[options.reasoning] as EffortLevel | undefined)
			?? REASONING_TO_EFFORT[options.reasoning]
		: undefined;
	const effort = resolveConfiguredEffort(model.id, requestedEffort, providerSettings);

	const extraArgs: Record<string, string | null> = { model: model.id };
	if (strictMcpConfigEnabled) extraArgs["strict-mcp-config"] = null;
	// Opus 4.7 defaults thinking.display to "omitted" (empty thinking text in stream).
	// Force summarized so thinking_delta events arrive. See anthropics/claude-agent-sdk-python#830.
	if (effort) extraArgs["thinking-display"] = "summarized";

	// Suppress claude.ai cloud MCP servers (Figma/Canva/etc. auto-discovered via OAuth
	// when the user is logged into Anthropic). These are a separate code path from
	// filesystem MCP and are NOT blocked by --strict-mcp-config or settingSources=undefined.
	// The native CC binary gates them on env var ENABLE_CLAUDEAI_MCP_SERVERS: setting it
	// to "0"/"false"/"no"/"off" makes the loader return early before any cloud fetch.
	// DISABLE_AUTO_COMPACT=1: pi owns context-management and propagates its own
	// /compact via session_compact (see handler in default export). Letting CC
	// also autocompact would double-flush the prompt cache and races pi's
	// threshold with CC's, including CC's anti-thrashing guard (issue #8).
	// Manual /compact in CC still works (we never invoke it).
	const childEnv = { ...process.env, ENABLE_CLAUDEAI_MCP_SERVERS: "0", DISABLE_AUTO_COMPACT: "1" };
	const queryOptions: NonNullable<Parameters<typeof query>[0]["options"]> = {
		cwd,
		env: childEnv,
		...CLAUDE_BRIDGE_TOOL_ISOLATION,
		permissionMode: "bypassPermissions",
		includePartialMessages: true,
		...(providerSettings.fastMode ? { settings: { fastMode: true } } : {}),
		systemPrompt: {
			type: "preset", preset: "claude_code",
			append: systemPromptAppend ? systemPromptAppend : undefined,
		},
		extraArgs,
		...(effort ? { effort } : {}),
		...(settingSources ? { settingSources } : {}),
		...(mcpServers ? { mcpServers } : {}),
		...(resumeSessionId ? { resume: resumeSessionId } : {}),
		...(claudeExecutable ? { pathToClaudeCodeExecutable: claudeExecutable } : {}),
		spawnClaudeCodeProcess: spawnClaudeCodeWithDiagnostics,
		...makeCliDebugOptions("provider"),
	};

	debug("provider: fresh query",
		`model=${model.id} msgs=${context.messages.length} tools=${mcpTools.length}`,
		`resume=${resumeSessionId?.slice(0, 8) ?? "none"} effort=${effort ?? "default"}`,
		`appendSys=${appendSystemPrompt} promptCtx=${promptContextAppend.labels.join(",") || "none"} strictMcp=${strictMcpConfigEnabled} fastMode=${providerSettings.fastMode === true}`,
		`claudeExec=${claudeExecutablePreflight ? `${claudeExecutablePreflight.fileType}:${claudeExecutablePreflight.path}` : "sdk-default"}`,
		`prompt=${promptText.slice(0, 60)}${promptBlocks ? " [+images]" : ""}`);

	// 3. Start SDK query and claim it for this context
	let wasAborted = false;
	const sdkQuery = query({ prompt, options: queryOptions });
	ctx().activeQuery = sdkQuery;

	// 4. Capture context for abort handling (must be AFTER pushContext)
	const abortCtx = ctx();

	const requestAbort = () => {
		// interrupt() asks the CLI to stop gracefully; close() kills it immediately.
		// Both are needed — interrupt alone lets the current API call finish.
		void sdkQuery.interrupt().catch(() => {});
		try { sdkQuery.close(); } catch {}
	};
	const onAbort = () => {
		wasAborted = true;
		// Prevent stale deferred messages from being replayed by parent on pop
		abortCtx.deferredUserMessages = [];
		reportToolResultMismatch(abortCtx, "abort", cwd, { forceRotate: true });
		for (const pending of abortCtx.pendingToolCalls.values()) { pending.resolve({ content: [{ type: "text", text: "Operation aborted" }] }); }
		abortCtx.pendingToolCalls.clear();
		abortCtx.pendingResults.clear();
		requestAbort();
	};
	if (options?.signal) {
		if (options.signal.aborted) onAbort();
		else options.signal.addEventListener("abort", onAbort, { once: true });
	}

	// Background consumer — runs until query ends
	consumeQuery(sdkQuery, customToolNameToPi, model, cwd, bridgeConfig, () => wasAborted)
		.then(async ({ capturedSessionId }) => {
			debug(`provider: consumeQuery completed, stopReason=${ctx().turnOutput?.stopReason}, error=${ctx().turnOutput?.errorMessage}, aborted=${wasAborted}`);

			// --- Abort detection in normal completion path ---
			if (wasAborted || options?.signal?.aborted) {
				if (sharedSession) sharedSession = { ...sharedSession, needsRebuild: true, forceRotate: true };
				ctx().deferredUserMessages = [];
				debug(`provider: abort detected, marked sharedSession needsRebuild + forceRotate`);
				if (ctx().turnOutput) {
					ctx().turnOutput.stopReason = "aborted";
					ctx().turnOutput.errorMessage = "Operation aborted";
				}
				ctx().currentPiStream?.push({ type: "error", reason: "aborted", error: ctx().turnOutput! });
				ctx().currentPiStream?.end();
				ctx().currentPiStream = null;
				return;
			}

			// --- Capture session ID ---
			const sessionId = capturedSessionId ?? sharedSession?.sessionId;
			if (sessionId) {
				const cursor = Math.max(context.messages.length, ctx().latestCursor, sharedSession?.cursor ?? 0);
				debug(`provider: query done, session=${sessionId.slice(0, 8)}, cursor=${cursor}`);
				sharedSession = { sessionId, cursor, cwd };
			}

			// --- Replay deferred user messages as continuation queries ---
			// Only for outermost queries — reentrant (subagent) queries leave
			// deferred messages for the parent to handle after it finishes.
			try {
				while (ctx().deferredUserMessages.length > 0 && !isReentrant && !wasAborted) {
					const steerPrompt = ctx().deferredUserMessages.shift()!;
					debug(`provider: replaying deferred user message: ${steerPrompt.slice(0, 60)}`);
					ctx().resetTurnState(model);
					ctx().resetToolTracking();

					const resumeId = sharedSession?.sessionId;
					if (!resumeId) {
						debug(`WARNING: no session to resume for deferred message, dropping`);
						break;
					}

					const contOptions = { ...queryOptions, resume: resumeId, ...makeCliDebugOptions("continuation") };
					const contQuery = query({ prompt: steerPrompt, options: contOptions });
					ctx().activeQuery = contQuery;

					debug(`provider: continuation query, model=${model.id}, resume=${resumeId.slice(0, 8)}, prompt=${steerPrompt.slice(0, 60)}`);

					try {
						const { capturedSessionId: contSid } = await consumeQuery(contQuery, customToolNameToPi, model, cwd, bridgeConfig, () => wasAborted);
						const sid = contSid ?? sharedSession?.sessionId;
						if (sid) {
							sharedSession = { sessionId: sid, cursor: sharedSession?.cursor ?? 0, cwd };
						}
					} catch (contError) {
						debug(`provider: continuation query error:`, contError);
						break;
					} finally {
						contQuery.close();
					}
				}
			} finally {
				// Guarantees restoration even if contQuery() throws synchronously
				ctx().activeQuery = sdkQuery;
			}

			finalizeCurrentStream(ctx().turnOutput?.stopReason);
		})
		.catch((error) => {
			debug(`provider: query error, model=${model.id}, aborted=${Boolean(options?.signal?.aborted)}, error=`, error);
			const suppressDuplicateError = ctx().handledTerminalError;
			const openedExtraUsage = !suppressDuplicateError && isExtraUsageRequiredMessage(error) && launchExtraUsageHelperIfAllowed(cwd, bridgeConfig, "query error");
			if ((wasAborted || options?.signal?.aborted) && sharedSession) {
				sharedSession = { ...sharedSession, needsRebuild: true, forceRotate: true };
			} else {
				sharedSession = null;
			}
			ctx().deferredUserMessages = [];
			if (suppressDuplicateError) {
				debug("provider: suppressing duplicate query error after terminal error was already emitted");
				return;
			}
			if (ctx().turnOutput) {
				ctx().turnOutput.stopReason = options?.signal?.aborted ? "aborted" : "error";
				ctx().turnOutput.errorMessage = `${error instanceof Error ? error.message : String(error)}${openedExtraUsage ? "\n\nOpened Claude Code /extra-usage helper. Complete billing/admin flow in the browser, then retry the prompt." : ""}`;
			}
			ctx().currentPiStream?.push({ type: "error", reason: (ctx().turnOutput?.stopReason ?? "error") as "aborted" | "error", error: ctx().turnOutput! });
			ctx().currentPiStream?.end();
			ctx().currentPiStream = null;
		})
		.finally(() => {
			if (options?.signal) options.signal.removeEventListener("abort", onAbort);
			if (ctx().activeQuery === sdkQuery) {
				reportToolResultMismatch(ctx(), "query teardown", cwd, { forceRotate: wasAborted || options?.signal?.aborted });
				// Drain pending handlers for this query
				for (const pending of ctx().pendingToolCalls.values()) { pending.resolve({ content: [{ type: "text", text: "Query ended" }] }); }
				ctx().pendingToolCalls.clear();
				ctx().pendingResults.clear();

				if (isReentrant) {
					popContext();  // merges deferred messages and restores parent
				} else {
					ctx().activeQuery = null;
				}
			}
			sdkQuery.close();
		});

	return stream;
}

function commandCwd(ctx: unknown): string {
	const value = (ctx as { cwd?: unknown })?.cwd;
	return typeof value === "string" && value.length > 0 ? value : process.cwd();
}

async function tryOpenExtensionManagerSettings(ctx: { ui: ExtensionUIContext }): Promise<boolean> {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const openQuickSettings = host[Symbol.for("vstack.pi.extension-manager.open-quick-settings")];
	if (typeof openQuickSettings !== "function") return false;
	try {
		await (openQuickSettings as (ctx: unknown, hint?: string) => Promise<void>)(ctx, "@vanillagreen/pi-claude-bridge");
		return true;
	} catch {
		return false;
	}
}

function showBridgeStatus(ctx: { ui: ExtensionUIContext; cwd?: string }): void {
	const config = loadConfig(commandCwd(ctx));
	ctx.ui.notify([
		`Claude bridge: ${config.enabled === false ? "disabled" : "enabled"}`,
		`Extra usage auto-helper: ${extraUsageAllowed(config) ? "on" : "off"} (settings)`,
		`Use /claude-bridge:extra to run Claude Code /extra-usage now.`,
	].join("\n"), "info");
}

function registerBridgeCommands(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[COMMANDS_REGISTERED_KEY]) return;
	guard[COMMANDS_REGISTERED_KEY] = true;

	const runExtraUsage = async (ctx: { ui: ExtensionUIContext; cwd?: string }) => {
		const cwd = commandCwd(ctx);
		if (extraUsageHelperInFlight) {
			ctx.ui.notify("Claude extra usage helper already running.", "info");
			await extraUsageHelperInFlight.catch(() => undefined);
			return;
		}
		try {
			ctx.ui.notify("Claude extra usage helper starting…", "info");
			extraUsageHelperInFlight = runExtraUsageHelper(cwd)
				.finally(() => { extraUsageHelperInFlight = null; });
			const message = await extraUsageHelperInFlight;
			ctx.ui.notify(`Claude extra usage helper: ${message}`, "info");
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			ctx.ui.notify(`Claude extra usage helper failed: ${message}`, "error");
		}
	};

	pi.registerCommand("claude-bridge", {
		description: "Open Claude bridge settings/status",
		handler: async (args: string, ctx) => {
			if (args.trim()) ctx.ui.notify("Unknown /claude-bridge argument. Use /claude-bridge:extra to run Claude Code /extra-usage.", "warning");
			if (await tryOpenExtensionManagerSettings(ctx)) return;
			showBridgeStatus(ctx);
		},
	});
	pi.registerCommand("claude-bridge:extra", {
		description: "Run Claude Code /extra-usage through claude-bridge",
		handler: async (_args: string, ctx) => runExtraUsage(ctx),
	});
}

// --- Extension registration ---

export default function (pi: ExtensionAPI) {
	extensionApi = pi;
	// Disable non-essential Claude Code traffic (update checks, MCP registry, telemetry)
	process.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";

	const config = loadConfig(process.cwd());
	debug("loadConfig:", JSON.stringify(config));
	registerBridgeCommands(pi);
	if (config.enabled === false) {
		debug("provider: disabled by configuration");
		return;
	}

	// Reset shared session on pi session lifecycle events
	const clearSession = (event: string) => {
		debug(`${event}: clearing session ${sharedSession?.sessionId?.slice(0, 8) ?? "none"}`);
		sharedSession = null;

		// Clear the global streamSimple if this instance registered it.
		// This allows /reload to work — the old instance clears the flag so
		// the new instance can register fresh without wrapping stale state.
		const g = globalThis as Record<symbol, any>;
		if (g[ACTIVE_STREAM_SIMPLE_KEY] === streamClaudeAgentSdk) {
			debug(`${event}: clearing ACTIVE_STREAM_SIMPLE_KEY`);
			g[ACTIVE_STREAM_SIMPLE_KEY] = undefined;
		}
	};
	pi.on("session_start", (event, ctx) => {
		piUI = ctx.ui;
		if (event.reason === "new" || event.reason === "resume" || event.reason === "fork") {
			clearSession(`session_start:${event.reason}`);
		}
		// Note: "fork" intentionally omitted from restoration. createBranchedSession
		// copies the parent's persisted bridge entries into the fork; restoring from
		// them would --resume the parent's Claude jsonl and leak conversation past the
		// fork point. Letting the first fork turn rebuild is the correct path.
		if (event.reason === "startup" || event.reason === "resume") restoreSharedSessionFromPi(ctx);
	});
	pi.on("session_shutdown", () => clearSession("session_shutdown"));
	pi.on("message_end", (event, ctx) => {
		const message = (event as { message?: AssistantMessage }).message;
		if (message?.role === "assistant" && message.provider === PROVIDER_ID) schedulePersistSharedSession(ctx);
	});

	// pi /compact and session-tree navigation (rewind / fork-at-point /
	// branch switch) both mutate pi's messages array out from under the
	// bridge. syncSharedSession's REUSE check would otherwise see
	// slice(cursor) === [] (or skip entries) and keep --resume'ing a CC
	// session that no longer matches pi's history. /compact in particular
	// triggers CC's autocompact-thrashing guard (issue #8). Force the next
	// call down the REBUILD path so CC sees the current history.
	const markRebuild = (event: string) => {
		if (ctx().activeQuery) {
			reportToolResultMismatch(ctx(), event, sharedSession?.cwd ?? process.cwd());
		}
		if (sharedSession) {
			debug(`${event}: marking needsRebuild on session ${sharedSession.sessionId.slice(0, 8)}`);
			sharedSession = { ...sharedSession, needsRebuild: true };
		}
	};
	pi.on("session_compact", () => markRebuild("session_compact"));
	pi.on("session_tree", () => markRebuild("session_tree"));

	// --- Provider ---
	//
	// Guard against re-registration when the module is loaded multiple times
	// (e.g., when spawning subagents). The shared ModelRegistry would otherwise
	// overwrite the parent's streamSimple, breaking tool result delivery.
	// See ACTIVE_STREAM_SIMPLE_KEY for the full mechanism.

	const g = globalThis as Record<symbol, any>;
	if (!g[ACTIVE_STREAM_SIMPLE_KEY]) {
		// First instance: store our streamSimple and register.
		g[ACTIVE_STREAM_SIMPLE_KEY] = streamClaudeAgentSdk;
		pi.registerProvider(PROVIDER_ID, {
			baseUrl: "claude-bridge",
			apiKey: "not-used",
			api: "claude-bridge",
			models: MODELS,
			// Cast: pi-ai AssistantMessageEventStream diamond dep between pi-coding-agent and pi-agent-core
			streamSimple: streamClaudeAgentSdk as any,
		});
	} else {
		// Subsequent instance (subagent session): skip registration entirely.
		// The subagent already has access to claude-bridge models via the shared
		// ModelRegistry from the parent's registration. Calls to those models
		// will route through the parent's streamSimple via the reentrant
		// QueryContext stack mechanism.
		debug(`provider: skipping re-registration, parent instance active (module=${moduleInstanceId})`);
	}

}
