import type { AgentBeforeSettleEvent, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { isAbsolute, resolve } from "node:path";

/**
 * Pi's tool vocabulary said in Claude Code's.
 *
 * A hook is authored in Claude's words — a matcher reads `Bash`, a body reads
 * `.tool_input.file_path` — and kendex hands Pi that matcher exactly as
 * written (`crates/core/src/render/vocab/mod.rs::hook_matcher` translates for
 * Gemini and Copilot and leaves every other harness alone). So the carrier is
 * where Pi's own words are turned into the hook's, and this module is the only
 * place that translation lives: a second copy of it is a matcher that matches
 * on one side and not the other.
 */

/** Public built-in tool vocabulary for extension consumers. */
export const PI_BUILTIN_TOOLS = ["bash", "edit", "find", "grep", "ls", "powershell", "read", "write"];

/**
 * Tool names follow `render::vocab::claude_tool_name`.
 * tests/vocab.test.ts checks each supported tool through the public function.
 *
 * `powershell` maps to itself because the Rust table has no name for it either
 * — Claude Code has no such tool — and an unmapped tool keeps its own id,
 * which is what a matcher naming an extension's tool needs too. So a matcher
 * for it is spelled `powershell`; `PowerShell` names nothing.
 */
const CLAUDE_TOOL_NAMES = new Map<string, string>([
	["bash", "Bash"],
	["edit", "Edit"],
	["find", "Glob"],
	["grep", "Grep"],
	["ls", "LS"],
	["powershell", "powershell"],
	["read", "Read"],
	["write", "Write"],
]);

/**
 * The tool as a hook matcher spells it. An unmapped name — an extension's own
 * tool — keeps its id, the way the Rust table's fallthrough does: a matcher
 * naming it still matches, and one naming nothing matches nothing.
 */
export function claudeToolName(toolName: string): string {
	return CLAUDE_TOOL_NAMES.get(toolName.trim().toLowerCase()) ?? toolName.trim();
}

/**
 * The tools whose one path argument Pi spells `path` and Claude Code spells
 * `file_path`. A hook body reads the payload it was authored against, so a
 * guard on `Write` that reads `.tool_input.file_path` would find nothing and
 * exit 0 — allowing the very call it was installed to judge.
 */
const PATH_KEY_TOOLS = new Set(["Read", "Write", "Edit"]);

/**
 * The tool's input with the keys this table knows renamed. Everything else
 * rides through in Pi's own shape: an `edit` call carries Pi's `edits` array,
 * which is not Claude Code's `old_string`/`new_string` pair and is not mapped
 * onto it — different shapes, and any mapping loses something.
 *
 * Claude Code sends `file_path` absolute and hooks match on it, while Pi sends
 * the path as the model spelled it, so a relative one is resolved against the
 * session's working directory, the one Pi's own tool resolves it against.
 */
export function claudeToolInput(claudeName: string, input: unknown, cwd: string): Record<string, unknown> {
	if (input === null || typeof input !== "object" || Array.isArray(input)) return {};
	const source = input as Record<string, unknown>;
	if (!PATH_KEY_TOOLS.has(claudeName) || !Object.hasOwn(source, "path")) return { ...source };
	const { path, ...rest } = source;
	return { file_path: typeof path === "string" && !isAbsolute(path) ? resolve(cwd, path) : path, ...rest };
}

/**
 * Pi's reasons for a session start said the way Claude Code's `SessionStart`
 * payload says them, for the matcher a hook was written against and the
 * `source` its body reads (`hooks/session-drift-check.sh` reads exactly that
 * key). Claude Code sends `startup|resume|clear|compact`.
 *
 * The split is the one this carrier already takes for its own drift report: a
 * session that starts fresh against one that carries a transcript forward.
 * `startup` is both tools' word for the process opening one. `new` and `fork`
 * are a session beginning inside a running process, which is Claude Code's
 * `clear`. `resume` is both tools' word, and `reload` is the same session's
 * extensions re-bound in place — a continuation, so it is said as `resume`
 * and a hook that skips a resumed session skips it too.
 *
 * Nothing maps onto `compact`: `pi_listener` gives `PostCompact` no listener,
 * so a hook declared for it never reaches Pi at all.
 */
const CLAUDE_SESSION_SOURCES = new Map<string, string>([
	["startup", "startup"],
	["new", "clear"],
	["fork", "clear"],
	["resume", "resume"],
	["reload", "resume"],
]);

/** The session's start reason as a `SessionStart` hook spells it. A reason Pi
 * adds and this table has not learned keeps its own word: a matcher naming it
 * still matches, and one naming nothing matches nothing. */
export function claudeSessionSource(reason: string): string {
	return CLAUDE_SESSION_SOURCES.get(reason.trim().toLowerCase()) ?? reason.trim();
}

/**
 * Pi's `session_shutdown` reasons said the way Claude Code's `SessionEnd`
 * payload says them, for the matcher and the `reason` a hook body reads.
 * Claude Code sends `clear|resume|logout|prompt_input_exit|other`.
 *
 * `new` and `fork` end a session for another inside the same process, Claude
 * Code's `clear`; `resume` and `reload` end it for a resumed one, its
 * `resume`; and `quit` is the person leaving Pi, its `prompt_input_exit`.
 * Pi has no `logout` ending.
 */
const CLAUDE_SESSION_END_REASONS = new Map<string, string>([
	["new", "clear"],
	["fork", "clear"],
	["resume", "resume"],
	["reload", "resume"],
	["quit", "prompt_input_exit"],
]);

/** The session's end reason as a `SessionEnd` hook spells it. A reason Pi adds
 * and this table has not learned keeps its own word, as a start reason does. */
export function claudeSessionEndReason(reason: string): string {
	return CLAUDE_SESSION_END_REASONS.get(reason.trim().toLowerCase()) ?? reason.trim();
}

/** Public session-start vocabulary for extension consumers. */
export const PI_SESSION_REASONS = ["startup", "reload", "new", "resume", "fork"];

/**
 * The fields Claude Code puts on every hook payload to name whose call a hook
 * judges: `session_id`, the `transcript_path` recording the calling agent's
 * tool calls, and the calling agent's `agent_type`. Pi puts none of them on an
 * event, so they are read off the session and the process. A Pi subagent is
 * its own process with its own session file, so that file is already the
 * calling agent's transcript and no `agent_id` is sent; its name is the one
 * pi-agents-tmux starts the process with. A session with no file
 * (`--no-session`) sends no `transcript_path`.
 */
export function claudeSessionFields(ctx: ExtensionContext): Record<string, string> {
	const fields: Record<string, string> = { session_id: ctx.sessionManager.getSessionId() };
	const transcript = ctx.sessionManager.getSessionFile();
	if (transcript !== undefined) fields.transcript_path = transcript;
	const agent = piSubagentName();
	if (agent !== undefined) fields.agent_type = agent;
	return fields;
}

/**
 * The context window of the session's model, as `context_window` on every
 * payload that can judge the session's context: the `Stop` payload and the
 * `PostToolUse` payload. The lane mail wake's run carries none, since no tool
 * ran (extensions/lane-mail-wake.ts). Claude
 * Code's payload carries no such field; Pi keeps the window in its model
 * registry and never in the session file, so a hook that judges a session
 * against its own window, as orch's `lane-mail-check` does at a turn end and
 * after a tool call, reads it here. Absent where Pi reports no usage, or a
 * window that is not a positive whole number.
 */
export function piContextFields(ctx: ExtensionContext): Record<string, number> {
	const window = ctx.getContextUsage?.()?.contextWindow;
	return typeof window === "number" && Number.isInteger(window) && window > 0 ? { context_window: window } : {};
}

/**
 * Claude Code's `last_assistant_message` on a `StopFailure` payload, the
 * harness's own text of the failure: for a usage limit, the limit and its
 * reset, which orch's session rows keep as `message`. Pi keeps a failed
 * response's text as the `errorMessage` of its assistant message
 * (`AssistantMessage`, @earendil-works/pi-ai), so the field is that of the
 * last assistant message in the context the settle hands over, and absent
 * where that message carries none.
 */
export function claudeFailureFields(messages: AgentBeforeSettleEvent["context"]["contextMessages"]): Record<string, string> {
	const last = messages.findLast((message) => message.role === "assistant");
	return last !== undefined && "errorMessage" in last && typeof last.errorMessage === "string" ? { last_assistant_message: last.errorMessage } : {};
}

/** The agent name a pi-agents-tmux subagent process is started with, or
 * `undefined` in a process no subagent runner started. */
export function piSubagentName(): string | undefined {
	const agent = process.env.PI_SUBAGENT_CHILD_AGENT;
	return agent === undefined || agent === "" ? undefined : agent;
}
