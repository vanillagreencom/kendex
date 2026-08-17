//! The Codex prose fallback: the `## Safety: <name>` block that carries a
//! hook Codex has no native event for, inside the `developer_instructions`
//! Codex hands the agent.
//!
//! Finding that block is a TOML question and then a prose one: the parser
//! says which value is the agent's instructions, and only inside that value
//! does a heading mean a section. Install, presence and removal all ask it
//! here, so none of them can answer differently.

use super::toml_error_summary;
use crate::agent::Agent;
use crate::harness::Harness;
use crate::hook::Hook;
use crate::installer::hooks::checked_child_path;
use crate::path_safety::validate_item_name;
use anyhow::{Context, Result};
use std::path::Path;

pub(crate) fn codex_hook_safety_block(hook: &Hook) -> String {
    format!(
        "{}\n\n{}\n\n{}",
        codex_hook_safety_marker(&hook.name),
        crate::installer::hooks::contract::ADVISORY_BANNER,
        hook.safety_prose()
    )
}

/// The anchored heading that marks a hook's safety prose in an agent TOML.
/// Installation and presence checking must agree on EXACTLY this string: a
/// bare substring search for the hook's name matches ordinary words in the
/// generated header ("check", "add", "run"), so a hook named after one of
/// them was skipped as already-installed and then reported missing forever.
pub(crate) fn codex_hook_safety_marker(hook_name: &str) -> String {
    format!("## Safety: {hook_name}")
}

/// The byte range of a Codex agent TOML's `developer_instructions` value.
///
/// This is the only place the prose fallback can live — it is what Codex
/// hands the agent — so it is the only place install writes and the only
/// place a presence read looks. The document is PARSED and the range is the
/// parser's own span for that value: which key, which table it belongs to,
/// and where the value starts and ends are answers only a TOML parser has.
/// The line scan this replaces took the first line in the file that read like
/// the assignment, so a `developer_instructions = '''` quoted inside another
/// field's multi-line string was spliced into as if it were the agent's — and
/// the splice landed in the middle of the user's own text.
///
/// - `Err(reason)` — the file is not valid TOML. Never collapsed into "no
///   block": every caller then rewrites nothing and names the file.
/// - `Ok(None)` — it parsed, and there is no root `developer_instructions`
///   written as the multi-line LITERAL string the generator emits. That
///   encoding is the one whose bytes on disk ARE its value, so prose spliced
///   into the range reads back as exactly what was written; any other
///   spelling is not this writer's and offers nowhere to splice.
fn developer_instructions_span(content: &str) -> Result<Option<std::ops::Range<usize>>, String> {
    const DELIMITER: &str = "'''";
    let doc = toml_edit::ImDocument::parse(content)
        .map_err(|err| format!("not valid TOML: {}", toml_error_summary(&err)))?;
    let Some(value) = doc
        .get("developer_instructions")
        .and_then(toml_edit::Item::as_value)
    else {
        return Ok(None);
    };
    let (Some(span), Some(decoded)) = (value.span(), value.as_str()) else {
        return Ok(None);
    };
    let Some(inner) = content
        .get(span.clone())
        .and_then(|raw| raw.strip_prefix(DELIMITER))
        .and_then(|raw| raw.strip_suffix(DELIMITER))
    else {
        return Ok(None);
    };
    // TOML drops a newline that immediately follows the opening delimiter, so
    // the value starts after it.
    let opened = span.start + DELIMITER.len();
    let start = opened + leading_newline_len(inner);
    let end = span.end - DELIMITER.len();
    // The parser's own decoding must be exactly the bytes of the range, or a
    // splice into them would not read back as what it wrote.
    match content.get(start..end) {
        Some(bytes) if bytes == decoded => Ok(Some(start..end)),
        _ => Ok(None),
    }
}

fn leading_newline_len(text: &str) -> usize {
    match text {
        _ if text.starts_with("\r\n") => 2,
        _ if text.starts_with('\n') => 1,
        _ => 0,
    }
}

/// The hook's own `## Safety: <name>` section inside `instructions` — its
/// heading line through to the next `## ` heading or the end of the block.
fn hook_prose_section_range(instructions: &str, hook_name: &str) -> Option<std::ops::Range<usize>> {
    let marker = codex_hook_safety_marker(hook_name);
    let mut start = None;
    let mut offset = 0;
    for line in instructions.split_inclusive('\n') {
        let at = offset;
        offset += line.len();
        let text = line.strip_suffix('\n').unwrap_or(line);
        match start {
            // Whole-line equality, never `contains`: `## Safety: foo` is a
            // prefix of `## Safety: foo-bar`, and a substring reading let one
            // hook's block stand in for another's.
            None if text == marker => start = Some(at),
            Some(from) if text.starts_with("## ") => return Some(from..at),
            _ => {}
        }
    }
    start.map(|from| from..instructions.len())
}

/// The byte range of `hook_name`'s section within the WHOLE agent TOML, so a
/// writer can replace exactly what a presence read found.
fn codex_agent_prose_range(
    content: &str,
    hook_name: &str,
) -> Result<Option<std::ops::Range<usize>>, String> {
    let Some(span) = developer_instructions_span(content)? else {
        return Ok(None);
    };
    let Some(inner) = hook_prose_section_range(&content[span.clone()], hook_name) else {
        return Ok(None);
    };
    Ok(Some(span.start + inner.start..span.start + inner.end))
}

/// The one predicate install and every presence read share: does this Codex
/// agent TOML already carry `hook_name`'s safety prose, in the block the prose
/// has to live in? `Ok(None)` when it does not — including when the file has
/// no `developer_instructions` block at all — and `Err` when the file is not
/// TOML vstack can read, which is never the same answer.
///
/// Finding the section is necessary, never sufficient: what the hook DOES is
/// its action line, and a heading whose body was deleted carries none of it.
/// [`codex_hook_prose`] is the question every caller that has the hook itself
/// asks.
pub(crate) fn codex_agent_prose_section<'a>(
    content: &'a str,
    hook_name: &str,
) -> Result<Option<&'a str>, String> {
    Ok(codex_agent_prose_range(content, hook_name)?.map(|range| &content[range]))
}

/// What this scope's Codex agents say about a hook's prose fallback.
///
/// Four answers, because their remedies differ. `NoAgents` demands nothing —
/// the block lives inside agent instructions, so until an agent exists there
/// is no artifact to write and none to miss. `Unreadable` is not `Absent`:
/// reinstalling repairs no unreadable file, and the note names the one that
/// has to be.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CodexProse {
    /// Some agent carries the block, action line and all.
    Carried,
    /// Every agent in the scope was read; none carries it.
    Absent,
    /// There is no Codex agent for the block to live in.
    NoAgents,
    /// The agents directory, or one of its TOMLs, could not be read.
    Unreadable(String),
}

impl CodexProse {
    /// The bool collapse, for a caller deciding only whether to WRITE the
    /// block — where the conservative answer to "nothing could be read" is to
    /// go ahead and install, which reads the file again and refuses by name.
    /// Anything REPORTING on an install must match on the variants instead.
    pub(crate) fn carried(&self) -> bool {
        matches!(self, Self::Carried)
    }
}

/// Does any Codex agent under `codex_root` carry THIS hook's prose fallback?
///
/// The block is found by [`codex_agent_prose_section`] — the predicate the
/// install writes against — and must carry the CURRENT hook's action line, so
/// a same-named block installed for a different event is not adopted as this
/// one. It lives here, beside the install, for exactly that reason.
///
/// One agent that carries the block answers for the whole scope; only when
/// NONE does, and one of them could not be read, is the answer unknowable.
pub(crate) fn codex_hook_prose(codex_root: &Path, hook: &Hook) -> CodexProse {
    let Some(action_line) = crate::config::generated_safety_action_line(hook) else {
        // The hook has no prose to install, so no agent can be missing it.
        return CodexProse::NoAgents;
    };
    let agents_dir = codex_root.join("agents");
    let entries = match std::fs::read_dir(&agents_dir) {
        Ok(entries) => entries,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return CodexProse::NoAgents,
        Err(err) => {
            return CodexProse::Unreadable(format!("reading {}: {err}", agents_dir.display()));
        }
    };
    let mut unreadable = None;
    let mut agents = 0;
    for entry in entries {
        let path = match entry {
            Ok(entry) => entry.path(),
            Err(err) => {
                unreadable.get_or_insert(format!("reading {}: {err}", agents_dir.display()));
                continue;
            }
        };
        if path.extension().is_none_or(|ex| ex != "toml") {
            continue;
        }
        agents += 1;
        match std::fs::read_to_string(&path) {
            Ok(content) => match content_carries_hook_prose(&content, &hook.name, &action_line) {
                Ok(true) => return CodexProse::Carried,
                Ok(false) => {}
                // A TOML vstack cannot read is not an agent missing the block:
                // no reinstall repairs it, and the installer refuses to touch
                // it, so the note names the file that has to be fixed by hand.
                Err(reason) => {
                    unreadable.get_or_insert(format!("{}: {reason}", path.display()));
                }
            },
            Err(err) => {
                unreadable.get_or_insert(format!("reading {}: {err}", path.display()));
            }
        }
    }
    match (unreadable, agents) {
        (Some(reason), _) => CodexProse::Unreadable(reason),
        (None, 0) => CodexProse::NoAgents,
        (None, _) => CodexProse::Absent,
    }
}

/// Does ONE agent TOML carry the hook's prose, body and all? A section is the
/// place the prose lives; the action line is the prose itself, and a heading
/// whose body was deleted leaves codex carrying no behavior at all. Install
/// repairs exactly what this rejects, so neither can drift from the other.
fn content_carries_hook_prose(
    content: &str,
    hook_name: &str,
    action_line: &str,
) -> Result<bool, String> {
    // The section is the harness's own free text once the parser has handed it
    // over, so matching a line inside it is reading prose, not deciding
    // structure from characters.
    Ok(codex_agent_prose_section(content, hook_name)?
        .is_some_and(|section| section.lines().any(|line| line == action_line)))
}

/// Fallback path for codex hooks whose event has no codex equivalent — append a
/// safety advisory to every agent's developer_instructions block. Matches the
/// original (pre-native) behavior.
///
/// `Ok(true)` means EVERY eligible agent carries this hook's safety block. An
/// agent whose TOML exists but offers no `developer_instructions` string to
/// append to is an `Err` naming the agent and its file, never a skipped entry:
/// accumulating success across agents let one agent that already carried the
/// marker report the install done while a newly added agent silently received
/// no safety prose at all. A malformed agent TOML is a real condition a user
/// must fix, and every caller propagates the error.
///
/// A scope with no Codex agent TOMLs produces nothing at all, and `Ok(false)`
/// says so — there is no artifact to make, and none for `check` to demand
/// until an agent exists.
pub(crate) fn install_hook_codex_prose(
    hook: &Hook,
    global: bool,
    agents: &[Agent],
) -> Result<bool> {
    validate_item_name(&hook.name)?;
    let agents_dir = Harness::Codex.agents_dir(global);
    if !agents_dir.exists() {
        return Ok(false);
    }
    let action_line = crate::config::generated_safety_action_line(hook).with_context(|| {
        format!(
            "the `{}` hook has no safety prose to install for Codex",
            hook.name
        )
    })?;

    let mut wrote = false;
    for agent in agents {
        validate_item_name(&agent.name)?;
        let toml_path = checked_child_path(&agents_dir, &format!("{}.toml", agent.name))?;
        if !toml_path.exists() {
            continue;
        }

        let content = std::fs::read_to_string(&toml_path)?;
        // The same question every presence read asks, from the same bytes. A
        // file that does not parse is refused by name — never rewritten, and
        // never counted as an agent this install covered.
        let unparseable = |reason: String| {
            anyhow::anyhow!(
                "Codex agent `{}` is not TOML vstack can rewrite ({reason}); fix the file by hand, then rerun: {}",
                agent.name,
                toml_path.display()
            )
        };
        if content_carries_hook_prose(&content, &hook.name, &action_line).map_err(unparseable)? {
            wrote = true;
            continue;
        }

        // A section that is present but no longer carries the hook's action
        // line — a heading whose body was edited away, or a block left by a
        // different event — is REPLACED, not skipped: skipping it left the
        // agent with a marker and no behavior, and every presence read then
        // had nothing to report.
        let content = strip_stale_prose_section(&content, &hook.name).map_err(unparseable)?;

        // Append INSIDE `developer_instructions`, so what is written is what
        // the predicate above will find on the next run.
        let Some(instructions) = developer_instructions_span(&content).map_err(unparseable)? else {
            anyhow::bail!(
                "Codex agent `{}` has no developer_instructions block to carry the `{}` hook's safety prose: {}",
                agent.name,
                hook.name,
                toml_path.display()
            );
        };
        let close_pos = instructions.end;
        let mut new_content = content[..close_pos].to_string();
        new_content.push('\n');
        new_content.push_str(&codex_hook_safety_block(hook));
        new_content.push('\n');
        new_content.push_str(&content[close_pos..]);
        // Only claim the install when the block presence checking looks for
        // is actually in the bytes about to be written.
        if !content_carries_hook_prose(&new_content, &hook.name, &action_line)
            .map_err(unparseable)?
        {
            anyhow::bail!(
                "the `{}` hook's safety block carries no `{}` marker for Codex agent `{}`: {}",
                hook.name,
                codex_hook_safety_marker(&hook.name),
                agent.name,
                toml_path.display()
            );
        }
        std::fs::write(&toml_path, new_content)?;
        wrote = true;
    }

    Ok(wrote)
}

/// Cut `hook_name`'s section out of an agent TOML, taking with it the blank
/// line the block was appended after — so a repaired file is byte-identical to
/// one this hook's block was installed into for the first time. A section
/// followed by another keeps that separator, which belongs to the section
/// still there. Content with no such section is returned unchanged.
fn strip_stale_prose_section(content: &str, hook_name: &str) -> Result<String, String> {
    let Some(span) = developer_instructions_span(content)? else {
        return Ok(content.to_string());
    };
    let Some(inner) = hook_prose_section_range(&content[span.clone()], hook_name) else {
        return Ok(content.to_string());
    };
    let range = span.start + inner.start..span.start + inner.end;
    let start = if range.end == span.end && content[..range.start].ends_with("\n\n") {
        range.start - 1
    } else {
        range.start
    };
    Ok(format!("{}{}", &content[..start], &content[range.end..]))
}

pub(crate) fn install_codex_fallback_hooks_for_agents(
    hooks: &[Hook],
    global: bool,
    agents: &[Agent],
) -> Result<()> {
    for hook in hooks {
        if hook.applies_to(Harness::Codex.id())
            && crate::installer::hooks::contract::is_codex_prose(&hook.event)
        {
            let _ = install_hook_codex_prose(hook, global, agents)?;
        }
    }
    Ok(())
}

/// Strip the `## Safety: <name>` prose block this installer injected into
/// codex agent TOMLs. Idempotent.
///
/// Cut by [`strip_stale_prose_section`] — the same anchored span the install
/// writes into and every presence read looks in. The whole-file search it
/// replaces cut from the FIRST `\n## Safety: <name>\n` anywhere in the file to
/// the next heading or string delimiter, so a marker a user wrote in a comment
/// or in an unrelated field took the rest of that field with it, while the
/// real block stayed and the removal reported success.
pub(crate) fn strip_hook_prose_from_codex_agents(global: bool, name: &str) -> Result<()> {
    validate_item_name(name)?;
    let agents_dir = Harness::Codex.agents_dir(global);
    if !agents_dir.exists() {
        return Ok(());
    }
    let entries = std::fs::read_dir(&agents_dir)
        .with_context(|| format!("reading Codex agents dir {}", agents_dir.display()))?;
    for entry in entries {
        let entry = entry.with_context(|| {
            format!("reading Codex agents dir entry in {}", agents_dir.display())
        })?;
        let path = entry.path();
        if path.extension().is_some_and(|ext| ext == "toml") {
            let content = std::fs::read_to_string(&path)
                .with_context(|| format!("reading Codex agent {}", path.display()))?;
            // A file vstack cannot parse is a file vstack does not rewrite:
            // cutting a byte range out of a document whose structure was never
            // established is how the whole-file search destroyed user content.
            let stripped = strip_stale_prose_section(&content, name).map_err(|reason| {
                anyhow::anyhow!(
                    "refusing to rewrite Codex agent {} ({reason}); fix the file by hand, then rerun",
                    path.display()
                )
            })?;
            if stripped != content {
                std::fs::write(&path, stripped)
                    .with_context(|| format!("writing Codex agent {}", path.display()))?;
            }
        }
    }
    Ok(())
}
