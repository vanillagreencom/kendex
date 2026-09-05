//! What each harness calls the tools an agent talks about. Agent bodies are
//! authored in Claude's vocabulary — "the Read tool" — and every other
//! harness reads that as a name for something it does not have. This module
//! owns all three translations: the manifest-name tables the renderers use
//! for their permission fields, and the conservative prose rewrite that lets
//! a body say the same thing in the reader's own words.

use crate::model::HarnessId;

/// v1's alias table: manifests write generic lowercase tool names, Claude
/// matches exact PascalCase — an unmapped name silently fails to deny.
pub fn claude_tool_name(tool: &str) -> String {
    match normalize(tool).as_str() {
        "read" => "Read".into(),
        "grep" => "Grep".into(),
        "glob" | "find" => "Glob".into(),
        "ls" | "list" => "LS".into(),
        "bash" => "Bash".into(),
        "edit" => "Edit".into(),
        "multiedit" => "MultiEdit".into(),
        "write" => "Write".into(),
        "webfetch" => "WebFetch".into(),
        "websearch" => "WebSearch".into(),
        "todowrite" => "TodoWrite".into(),
        "todoread" => "TodoRead".into(),
        "task" | "agent" | "subagent" | "spawnagent" | "spawnagentsoncsv" => "Agent".into(),
        "question" | "askuserquestion" => "AskUserQuestion".into(),
        "notebookread" => "NotebookRead".into(),
        "notebookedit" => "NotebookEdit".into(),
        _ => tool.trim().to_owned(),
    }
}

/// Gemini's built-in tool identifiers (matrix §1 "Built-in tool
/// identifiers", §D3 — six of the eight names in circulation are wrong, and
/// a wrong one drops the tool in silence).
fn gemini_tool(tool: &str) -> Option<&'static str> {
    Some(match normalize(tool).as_str() {
        "read" => "read_file",
        "grep" => "grep_search",
        "glob" | "find" => "glob",
        "ls" | "list" => "list_directory",
        "bash" | "shell" => "run_shell_command",
        "edit" | "multiedit" => "replace",
        "write" => "write_file",
        "webfetch" => "web_fetch",
        "websearch" => "google_web_search",
        "todowrite" => "write_todos",
        "question" | "askuserquestion" => "ask_user",
        _ => return None,
    })
}

/// What an agent's `tools:` allowlist has to name on Gemini. An unmapped
/// name passes through so an MCP tool keeps its own id; Gemini then simply
/// does not offer it, which is narrower, never wider.
pub fn gemini_tool_name(tool: &str) -> String {
    gemini_tool(tool)
        .map(str::to_owned)
        .unwrap_or_else(|| tool.trim().to_owned())
}

/// Copilot's own tool names, as its custom-agent reference lists them
/// ([custom agents configuration](https://docs.github.com/en/copilot/reference/custom-agents-configuration),
/// Names it does not document are left alone rather
/// than guessed at: an allowlist entry Copilot does not recognize grants
/// nothing, which is narrower than the author asked for, never wider.
fn copilot_tool(tool: &str) -> Option<&'static str> {
    Some(match normalize(tool).as_str() {
        "read" => "read",
        "grep" => "grep",
        "glob" | "find" => "glob",
        "bash" | "shell" => "bash",
        "edit" => "edit",
        "multiedit" => "multiedit",
        "write" => "write",
        "webfetch" => "webfetch",
        "websearch" => "websearch",
        "todowrite" => "todowrite",
        "task" | "agent" | "subagent" | "spawnagent" => "agent",
        "notebookread" => "notebookread",
        "notebookedit" => "notebookedit",
        _ => return None,
    })
}

/// What an agent's `tools:` allowlist has to name on Copilot.
pub fn copilot_tool_name(tool: &str) -> String {
    copilot_tool(tool)
        .map(str::to_owned)
        .unwrap_or_else(|| tool.trim().to_owned())
}

/// Antigravity's own tool names, the step types its loader lowercases
/// (<https://antigravity.google/docs/subagents>, the CLI's embedded
/// customization guide). A name of its own passes through unchanged, so an
/// author may write either vocabulary.
fn antigravity_tool(tool: &str) -> Option<&'static str> {
    Some(match normalize(tool).as_str() {
        "read" | "viewfile" => "view_file",
        "grep" | "grepsearch" => "grep_search",
        "glob" | "find" | "findbyname" => "find_by_name",
        "ls" | "list" | "listdir" => "list_dir",
        "bash" | "shell" | "runcommand" => "run_command",
        "edit" | "replacefilecontent" => "replace_file_content",
        "multiedit" | "multireplacefilecontent" => "multi_replace_file_content",
        "write" | "writetofile" => "write_to_file",
        "webfetch" | "readurlcontent" => "read_url_content",
        "websearch" | "searchweb" => "search_web",
        "task" | "agent" | "subagent" | "spawnagent" | "invokesubagent" => "invoke_subagent",
        "question" | "askuserquestion" | "askquestion" => "ask_question",
        "notebookread" | "readnotebook" => "read_notebook",
        "notebookedit" | "editnotebook" => "edit_notebook",
        _ => return None,
    })
}

/// What an agent's `tools:` allowlist may name on Antigravity, or `None`
/// for a name it has no word for. An unmapped name is not passed through:
/// the loader documents that an unknown name in the list can hang the
/// subagent, so the caller drops it and says so.
pub fn antigravity_tool_name(tool: &str) -> Option<&'static str> {
    antigravity_tool(tool)
}

/// A hook matcher said in `harness`'s own tool names, and whether all of it
/// could be. Matchers are regexes over tool names authored in Claude's
/// vocabulary, so `Bash` left as written matches nothing on a tool whose
/// shell is `run_shell_command`. Each alternative is translated on its own;
/// one carrying regex syntax around a name is left exactly as authored and
/// reported, because a matcher that never matches is a protection that
/// never runs.
pub fn hook_matcher(matcher: &str, harness: HarnessId) -> (String, bool) {
    let name = match harness {
        HarnessId::Gemini => gemini_tool_name,
        HarnessId::Copilot => copilot_tool_name,
        // Claude's own names are what a matcher is authored in; codex and
        // cursor read the same spelling, and the rest register no matcher.
        _ => return (matcher.to_owned(), true),
    };
    let mut said = true;
    let pattern: Vec<String> = matcher
        .split('|')
        .map(|token| {
            let alphanumeric = token.chars().any(|c| c.is_ascii_alphanumeric());
            let plain = token
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
            match (alphanumeric, plain) {
                (true, true) => name(token),
                // Pure syntax — `.*` names no tool and needs no translation.
                (false, _) => token.to_owned(),
                (true, false) => {
                    said = false;
                    token.to_owned()
                }
            }
        })
        .collect();
    (pattern.join("|"), said)
}

/// OpenCode gates tools by permission key, not tool name. `None` is the
/// empty name — nothing to gate; an unknown name passes through so an MCP
/// tool can still be denied by its own id.
pub fn opencode_permission(tool: &str) -> Option<String> {
    let permission = match normalize(tool).as_str() {
        "read" => "read",
        "edit" | "write" | "patch" | "applypatch" | "multiedit" | "notebookedit" => "edit",
        "glob" | "find" | "ls" | "list" => "glob",
        "grep" => "grep",
        "bash" | "shell" => "bash",
        "task" | "agent" | "subagent" | "spawnagent" | "spawnagentsoncsv" => "task",
        "skill" => "skill",
        "lsp" => "lsp",
        "question" => "question",
        "webfetch" | "websearch" | "web" | "webresearch" | "webanswer" | "codesearch" => "webfetch",
        "" => return None,
        _ => return Some(tool.trim().to_owned()),
    };
    Some(permission.to_owned())
}

/// Claude's own spelling for every tool a body can name. Recognition in
/// prose is exact against this list: `read` in a sentence is the verb,
/// `Read` is the tool.
const CLAUDE_TOOLS: [&str; 16] = [
    "Read",
    "Grep",
    "Glob",
    "LS",
    "Bash",
    "Edit",
    "MultiEdit",
    "Write",
    "WebFetch",
    "WebSearch",
    "TodoWrite",
    "TodoRead",
    "Agent",
    "AskUserQuestion",
    "NotebookRead",
    "NotebookEdit",
];

/// Skill pointers name generated files; a line that carries one is a path
/// reference, not prose, and stays byte-for-byte.
const SKILL_POINTER: &str = "SKILL.md";

/// How a harness says a tool: a name that slots into the same sentence, or
/// — for Codex, whose docs name actions rather than tools — a phrase that
/// stands in for the whole reference.
enum Word {
    Name(&'static str),
    Phrase(&'static str),
}

/// The vocabulary each harness has an official word for. A tool missing
/// from a harness's column is left as authored rather than guessed at.
fn word(tool: &str, harness: HarnessId) -> Option<Word> {
    let tool = normalize(tool);
    match harness {
        // Bodies are already written in Claude's words.
        HarnessId::Claude => None,
        // Both name a tool the same way in prose as in an allowlist.
        HarnessId::Copilot => Some(Word::Name(copilot_tool(&tool)?)),
        HarnessId::Gemini => Some(Word::Name(gemini_tool(&tool)?)),
        HarnessId::Antigravity => Some(Word::Name(antigravity_tool(&tool)?)),
        HarnessId::Codex => Some(Word::Phrase(match tool.as_str() {
            "read" => "open the file",
            "grep" => "search",
            "glob" | "ls" => "list files",
            "bash" => "run a shell command",
            "edit" | "multiedit" | "write" => "edit the file",
            "webfetch" | "websearch" => "fetch the page",
            _ => return None,
        })),
        HarnessId::Opencode | HarnessId::Cursor | HarnessId::Pi => {
            Some(Word::Name(match tool.as_str() {
                "read" => "read",
                "grep" => "grep",
                "glob" => "glob",
                "ls" => "list",
                "bash" => "bash",
                "edit" | "multiedit" => "edit",
                "write" => "write",
                "webfetch" | "websearch" => "webfetch",
                _ => return None,
            }))
        }
    }
}

fn normalize(tool: &str) -> String {
    tool.trim().to_lowercase().replace(['_', '-'], "")
}

mod rewrite;
pub use rewrite::rewrite_prose;

#[cfg(test)]
mod tests;
