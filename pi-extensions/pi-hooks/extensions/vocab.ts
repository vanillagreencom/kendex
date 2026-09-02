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

/**
 * Pi's built-in tools, as its extension reference lists them (`docs/
 * extensions.md`, "Extensions can override built-in tools"). Written out
 * rather than read off the table below, which is the thing it checks: a list
 * derived from that map cannot see a row go missing from it.
 */
export const PI_BUILTIN_TOOLS = ["bash", "edit", "find", "grep", "ls", "powershell", "read", "write"];

/**
 * Each of those said the way `render::vocab::claude_tool_name` says it.
 * tests/registry.test.ts holds this table to that function and its key set to
 * the list above.
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
 */
export function claudeToolInput(claudeName: string, input: unknown): Record<string, unknown> {
	if (input === null || typeof input !== "object" || Array.isArray(input)) return {};
	const source = input as Record<string, unknown>;
	if (!PATH_KEY_TOOLS.has(claudeName) || !Object.hasOwn(source, "path")) return { ...source };
	const { path, ...rest } = source;
	return { file_path: path, ...rest };
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

/** The reasons Pi's `session_start` event carries, as its `SessionStartEvent`
 * type lists them. Written out rather than read off the table above, which is
 * the thing tests/registry.test.ts checks: a list derived from that map cannot
 * see a row go missing from it. */
export const PI_SESSION_REASONS = ["startup", "reload", "new", "resume", "fork"];
