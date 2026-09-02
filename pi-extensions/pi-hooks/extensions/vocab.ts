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
 * Pi's built-in tools, as its own extension reference lists them (`docs/
 * extensions.md`, "Extensions can override built-in tools"), each said the way
 * `render::vocab::claude_tool_name` says it. tests/registry.test.ts holds this
 * table to that function.
 *
 * `powershell` is here with no Claude name of its own because the Rust table
 * has none either: an unmapped tool keeps its own id, which is what a hook
 * matcher naming an extension's tool needs too.
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

/** The names Pi ships, for the coupling test and nothing else. */
export const PI_BUILTIN_TOOLS = [...CLAUDE_TOOL_NAMES.keys()];

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
 * The tool's input as Claude Code sends it. Only the keys this knows are
 * renamed; everything else rides through, since a hook reading a key Pi alone
 * has is better served by the value than by its absence.
 */
export function claudeToolInput(claudeName: string, input: unknown): Record<string, unknown> {
	if (input === null || typeof input !== "object" || Array.isArray(input)) return {};
	const source = input as Record<string, unknown>;
	if (!PATH_KEY_TOOLS.has(claudeName) || !Object.hasOwn(source, "path")) return { ...source };
	const { path, ...rest } = source;
	return { file_path: path, ...rest };
}
