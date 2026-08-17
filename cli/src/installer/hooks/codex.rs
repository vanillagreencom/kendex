//! Codex hooks: native registration under `<scope>/.codex/`, the
//! `config.toml` feature toggle that enables it, and the
//! `developer_instructions` prose fallback for events Codex has no
//! equivalent for.

use super::{
    checked_child_path, is_toml_table_header, remove_hook_entries_from_hooks_object, shell_quote,
};
use crate::agent::Agent;
use crate::harness::Harness;
use crate::hook::Hook;
use crate::path_safety::validate_item_name;
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

pub(crate) fn codex_hook_safety_block(hook: &Hook) -> String {
    format!(
        "{}\n\n{}",
        codex_hook_safety_marker(&hook.name),
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
/// place a presence read looks. Anchored at a line start, because that is
/// where a TOML assignment begins; the whole-file reading it replaces treated
/// marker text in a comment or an unrelated field as the block itself.
fn developer_instructions_span(content: &str) -> Option<std::ops::Range<usize>> {
    const KEY: &str = "developer_instructions";
    const DELIMITER: &str = "'''";
    let mut line_start = 0;
    for line in content.split_inclusive('\n') {
        let offset = line_start;
        line_start += line.len();
        let Some(rest) = line.trim_start().strip_prefix(KEY) else {
            continue;
        };
        let Some(rest) = rest.trim_start().strip_prefix('=') else {
            continue;
        };
        let rest = rest.trim_start();
        if !rest.starts_with(DELIMITER) {
            // A single-line or basic string: nothing this writer produced,
            // and nowhere a multi-line prose block can be spliced.
            return None;
        }
        // TOML drops the newline that immediately follows the opening
        // delimiter, so the value starts after it.
        let opened = offset + (line.len() - rest.len()) + DELIMITER.len();
        let start = match content[opened..].strip_prefix('\n') {
            Some(_) => opened + 1,
            None => opened,
        };
        let end = start + content[start..].find(DELIMITER)?;
        return Some(start..end);
    }
    None
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
fn codex_agent_prose_range(content: &str, hook_name: &str) -> Option<std::ops::Range<usize>> {
    let span = developer_instructions_span(content)?;
    let inner = hook_prose_section_range(&content[span.clone()], hook_name)?;
    Some(span.start + inner.start..span.start + inner.end)
}

/// The one predicate install and every presence read share: does this Codex
/// agent TOML already carry `hook_name`'s safety prose, in the block the prose
/// has to live in? `None` when it does not — including when the file has no
/// `developer_instructions` block at all.
///
/// Finding the section is necessary, never sufficient: what the hook DOES is
/// its action line, and a heading whose body was deleted carries none of it.
/// [`codex_agent_carries_hook_prose`] is the predicate every caller that has
/// the hook itself asks.
pub(crate) fn codex_agent_prose_section<'a>(content: &'a str, hook_name: &str) -> Option<&'a str> {
    codex_agent_prose_range(content, hook_name).map(|range| &content[range])
}

/// Does any Codex agent under `codex_root` carry THIS hook's prose fallback?
///
/// The block is found by [`codex_agent_prose_section`] — the predicate the
/// install writes against — and must carry the CURRENT hook's action line, so
/// a same-named block installed for a different event is not adopted as this
/// one. It lives here, beside the install, for exactly that reason.
pub(crate) fn codex_agent_carries_hook_prose(codex_root: &Path, hook: &Hook) -> bool {
    let Some(action_line) = crate::config::generated_safety_action_line(hook) else {
        return false;
    };
    let Ok(entries) = std::fs::read_dir(codex_root.join("agents")) else {
        return false;
    };
    entries.flatten().any(|entry| {
        let path = entry.path();
        path.extension().is_some_and(|ex| ex == "toml")
            && std::fs::read_to_string(&path)
                .is_ok_and(|content| content_carries_hook_prose(&content, &hook.name, &action_line))
    })
}

/// Does ONE agent TOML carry the hook's prose, body and all? A section is the
/// place the prose lives; the action line is the prose itself, and a heading
/// whose body was deleted leaves codex carrying no behavior at all. Install
/// repairs exactly what this rejects, so neither can drift from the other.
fn content_carries_hook_prose(content: &str, hook_name: &str, action_line: &str) -> bool {
    codex_agent_prose_section(content, hook_name)
        .is_some_and(|section| section.lines().any(|line| line == action_line))
}

/// Map a canonical (Claude-style) hook event to its codex equivalent.
///
/// Codex supports these events natively (per
/// <https://developers.openai.com/codex/hooks>):
///   SessionStart, UserPromptSubmit, PreToolUse, PostToolUse,
///   PreCompact, PostCompact, PermissionRequest, Stop.
///
/// Claude's `TaskCompleted` has no clean equivalent — Stop fires when a turn
/// ends and treats `exit 2 + stderr` as "continue with this reason as the next
/// prompt" rather than "block the done state". Returning None routes such
/// hooks to the prose-only fallback; authors who want codex coverage should
/// scope the hook with `harnesses: [claude-code]` or rewrite for Stop.
pub(crate) fn codex_event_for(event: &str) -> Option<&'static str> {
    match event {
        "SessionStart" => Some("SessionStart"),
        "UserPromptSubmit" => Some("UserPromptSubmit"),
        "PreToolUse" => Some("PreToolUse"),
        "PostToolUse" => Some("PostToolUse"),
        "PreCompact" => Some("PreCompact"),
        "PostCompact" => Some("PostCompact"),
        "PermissionRequest" => Some("PermissionRequest"),
        "Stop" => Some("Stop"),
        _ => None,
    }
}

/// Root of the codex config layer for the given scope.
pub(crate) fn codex_root(global: bool) -> PathBuf {
    if global {
        crate::config::codex_home_dir()
    } else {
        crate::config::project_root().join(".codex")
    }
}

/// Codex hook install. Native install (script + hooks.json + features flag)
/// when codex understands the event; safety-prose appendix to agent TOML
/// otherwise.
/// Returns whether an artifact (native script or prose block) was produced.
pub(super) fn install_hook_codex(hook: &Hook, global: bool, agents: &[Agent]) -> Result<bool> {
    match codex_event_for(&hook.event) {
        Some(codex_event) => install_hook_codex_native(hook, codex_event, global).map(|()| true),
        None => install_hook_codex_prose(hook, global, agents),
    }
}

/// Install a codex-native hook: copy the script under `<root>/hooks/<name>.sh`,
/// merge the entry into `<root>/hooks.json`, and ensure
/// `[features] hooks = true` is set in `<root>/config.toml`.
fn install_hook_codex_native(hook: &Hook, codex_event: &str, global: bool) -> Result<()> {
    validate_item_name(&hook.name)?;
    let root = codex_root(global);

    let hooks_dir = root.join("hooks");
    std::fs::create_dir_all(&hooks_dir)?;
    let script_path = checked_child_path(&hooks_dir, &format!("{}.sh", hook.name))?;
    std::fs::write(&script_path, &hook.script)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&script_path, std::fs::Permissions::from_mode(0o755))?;
    }

    let command = codex_hook_command(global, &hook.name, &script_path);
    let owned_commands = codex_owned_hook_commands(global, &hook.name, &script_path);
    let hooks_json = root.join("hooks.json");
    merge_codex_hooks_json_owned(&hooks_json, codex_event, hook, &command, &owned_commands)?;
    enable_codex_hooks_feature(&root.join("config.toml"))?;
    Ok(())
}

/// Why a codex-native hook that HAS its script still never runs — or why
/// nothing here can say whether it does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CodexNativeGap {
    /// Nothing in `<root>/hooks.json` points codex at the script.
    NotRegistered,
    /// `[features] hooks` is not on, so codex ignores `hooks.json` entirely.
    FeatureDisabled,
    /// A file this answer depends on exists and could not be parsed. Not a
    /// missing registration: reinstalling repairs nothing, and the note names
    /// the file whose repair does.
    Unreadable(String),
}

impl CodexNativeGap {
    pub(crate) fn describe(&self) -> String {
        match self {
            Self::NotRegistered => "script present but not registered".to_string(),
            Self::FeatureDisabled => "hooks feature disabled".to_string(),
            Self::Unreadable(reason) => format!("registration unverifiable — {reason}"),
        }
    }

    /// Is this a gap no reinstall can close?
    pub(crate) fn is_unreadable(&self) -> bool {
        matches!(self, Self::Unreadable(_))
    }
}

/// What stands between an installed codex-native hook script and codex
/// actually running it. The script alone proves nothing: codex only executes
/// what `hooks.json` registers, and only while `[features] hooks = true`.
/// Reads exactly the two artifacts [`install_hook_codex_native`] writes, so
/// install and presence answer from the same evidence.
pub(crate) fn codex_native_hook_gaps(
    global: bool,
    hook_name: &str,
    codex_event: &str,
) -> Vec<CodexNativeGap> {
    let root = codex_root(global);
    let script_path = root.join("hooks").join(format!("{hook_name}.sh"));
    let owned = codex_owned_hook_commands(global, hook_name, &script_path);
    // Only the project-scope command defers the repo root to run time.
    let git_root = (!global).then(|| root.parent()).flatten();
    let mut gaps = Vec::new();
    match super::hooks_config_registration(
        &root.join("hooks.json"),
        Some(codex_event),
        &script_path,
        git_root.map(|root| (CODEX_GIT_TOPLEVEL, root)),
        &owned,
    ) {
        super::HookRegistration::Registered => {}
        super::HookRegistration::Absent => gaps.push(CodexNativeGap::NotRegistered),
        super::HookRegistration::Unreadable(reason) => {
            gaps.push(CodexNativeGap::Unreadable(reason));
        }
    }
    match codex_hooks_feature_state(&root.join("config.toml")) {
        CodexHooksFeature::Enabled => {}
        CodexHooksFeature::Disabled => gaps.push(CodexNativeGap::FeatureDisabled),
        CodexHooksFeature::Unreadable(reason) => gaps.push(CodexNativeGap::Unreadable(reason)),
    }
    gaps
}

/// The repo-root substitution the project-scope command defers to run time.
/// A user who reshapes that command keeps it, so registration checking has to
/// read the command the same way the shell codex hands it to will.
const CODEX_GIT_TOPLEVEL: &str = "$(git rev-parse --show-toplevel)";

/// Whether codex will act on `hooks.json` at all.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum CodexHooksFeature {
    Enabled,
    Disabled,
    /// `config.toml` exists and does not parse as TOML. Codex reads no
    /// features out of it either, but nothing here can say what the user
    /// meant, and a writer that assumed would rewrite their config.
    Unreadable(String),
}

/// Is `[features] hooks` the boolean `true`? Read with a real TOML parser,
/// because that is what codex reads it with: a line scanner answers `true`
/// for the literal text `[features]` / `hooks = true` inside an unrelated
/// multiline string, and for the string `"true"` codex would reject. A
/// missing file, a missing table, a missing key, a non-boolean value, and an
/// explicit `false` all mean codex runs no hooks. The writer stays line-based
/// so it keeps the user's comments and ordering.
pub(super) fn codex_hooks_feature_state(config_path: &Path) -> CodexHooksFeature {
    let content = match std::fs::read_to_string(config_path) {
        Ok(content) => content,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            return CodexHooksFeature::Disabled;
        }
        Err(err) => {
            return CodexHooksFeature::Unreadable(format!(
                "reading {}: {err}",
                config_path.display()
            ));
        }
    };
    codex_hooks_feature_in(&content, config_path)
}

/// [`codex_hooks_feature_state`] for content already in hand — the writer's
/// own refusal reads the same bytes it is about to merge into.
fn codex_hooks_feature_in(content: &str, config_path: &Path) -> CodexHooksFeature {
    let doc = match content.parse::<toml::Value>() {
        Ok(doc) => doc,
        Err(err) => {
            return CodexHooksFeature::Unreadable(format!(
                "{} is not valid TOML: {}",
                config_path.display(),
                toml_error_summary(&err)
            ));
        }
    };
    if doc
        .get("features")
        .and_then(|features| features.get("hooks"))
        .and_then(|hooks| hooks.as_bool())
        .unwrap_or(false)
    {
        CodexHooksFeature::Enabled
    } else {
        CodexHooksFeature::Disabled
    }
}

/// The first line of a TOML parse failure — the one carrying the location.
/// The rest is a multi-line source excerpt, and every consumer here puts the
/// message on ONE report line.
fn toml_error_summary(err: &toml::de::Error) -> String {
    let rendered = err.to_string();
    rendered
        .lines()
        .next()
        .unwrap_or("parse failed")
        .to_string()
}

/// Migrate deprecated Codex config keys for the selected scope without
/// creating a config file or enabling hooks when no native hook is installed.
pub fn migrate_codex_config(global: bool) -> Result<()> {
    migrate_codex_hooks_feature(&codex_root(global).join("config.toml"))
}

/// Build the command codex runs. For global scope we resolve to the absolute
/// path under `~/.codex/hooks/`. For project scope we resolve from the git root
/// (the codex docs recommend this so the hook works regardless of session cwd).
fn codex_hook_command(global: bool, hook_name: &str, script_path: &Path) -> String {
    if global {
        format!("bash {}", shell_quote(&script_path.to_string_lossy()))
    } else {
        format!(
            "bash \"$(git rev-parse --show-toplevel)/.codex/hooks/{}.sh\"",
            hook_name
        )
    }
}

fn codex_owned_hook_commands(global: bool, hook_name: &str, script_path: &Path) -> Vec<String> {
    vec![codex_hook_command(global, hook_name, script_path)]
}

/// Merge one hook handler into `<root>/hooks.json`. Existing entries for other
/// hooks are preserved. The handler is keyed by the script file name so reruns
/// don't duplicate.
#[cfg(test)]
pub(super) fn merge_codex_hooks_json(
    hooks_json: &Path,
    codex_event: &str,
    hook: &Hook,
    command: &str,
) -> Result<()> {
    let owned_commands = [command.to_string()];
    merge_codex_hooks_json_owned(hooks_json, codex_event, hook, command, &owned_commands)
}

fn merge_codex_hooks_json_owned(
    hooks_json: &Path,
    codex_event: &str,
    hook: &Hook,
    command: &str,
    owned_commands: &[String],
) -> Result<()> {
    let mut doc = super::read_hooks_config(hooks_json)
        .context(super::REFUSE_UNPARSEABLE_CONFIG)?
        .unwrap_or_else(|| serde_json::json!({}));

    let root_map = doc.as_object_mut().expect("read_hooks_config: object");
    if !root_map.contains_key("hooks") {
        root_map.insert("hooks".into(), serde_json::json!({}));
    }
    let hooks_obj = root_map
        .get_mut("hooks")
        .and_then(|hooks| hooks.as_object_mut())
        .expect("read_hooks_config: `hooks` is an object");
    remove_hook_entries_from_hooks_object(hooks_obj, owned_commands);
    if !hooks_obj.get(codex_event).is_some_and(|v| v.is_array()) {
        hooks_obj.insert(codex_event.to_string(), serde_json::json!([]));
    }
    let event_arr = hooks_obj
        .get_mut(codex_event)
        .unwrap()
        .as_array_mut()
        .unwrap();

    let mut handler = serde_json::json!({
        "type": "command",
        "command": command,
    });
    if let Some(timeout) = hook.timeout {
        handler
            .as_object_mut()
            .unwrap()
            .insert("timeout".into(), serde_json::Value::Number(timeout.into()));
    }

    let mut entry = serde_json::json!({ "hooks": [handler] });
    if let Some(ref matcher) = hook.matcher {
        entry
            .as_object_mut()
            .unwrap()
            .insert("matcher".into(), serde_json::Value::String(matcher.clone()));
    }
    event_arr.push(entry);

    let output = crate::config::to_json_pretty(&doc)?;
    std::fs::write(hooks_json, output)?;
    Ok(())
}

/// Ensure `[features] hooks = true` is set in `<root>/config.toml`,
/// preserving any user content. Uses a text-level merge so we don't clobber
/// comments or key ordering. Removes the deprecated `codex_hooks` feature flag
/// from the `[features]` table so Codex doesn't warn about custom config.
pub(super) fn enable_codex_hooks_feature(config_path: &Path) -> Result<()> {
    merge_codex_hooks_feature(config_path, true)
}

/// Migrate `[features] codex_hooks = ...` to `hooks = ...` when the file
/// already exists. Unlike [`enable_codex_hooks_feature`], this is intentionally
/// a no-op for missing files and does not force hooks on when users have
/// `hooks = false`.
pub(super) fn migrate_codex_hooks_feature(config_path: &Path) -> Result<()> {
    merge_codex_hooks_feature(config_path, false)
}

fn merge_codex_hooks_feature(config_path: &Path, enable_hooks: bool) -> Result<()> {
    if !enable_hooks && !config_path.exists() {
        return Ok(());
    }

    if let Some(parent) = config_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let original = if config_path.exists() {
        std::fs::read_to_string(config_path)?
    } else {
        String::new()
    };
    // The merge below is line-based, so it would happily splice `hooks = true`
    // into a file codex itself cannot read — an install that reports success
    // and never runs. What the user has to fix is the parse failure, so that
    // is what this says, and the file is left exactly as it is.
    if let CodexHooksFeature::Unreadable(reason) = codex_hooks_feature_in(&original, config_path) {
        return Err(anyhow::anyhow!("{reason}").context(super::REFUSE_UNPARSEABLE_CONFIG));
    }

    let mut lines: Vec<String> = original.lines().map(|s| s.to_string()).collect();
    let state = codex_features_state(&lines);
    let target_hooks_value = if enable_hooks {
        Some("true".to_string())
    } else {
        state
            .deprecated
            .as_ref()
            .map(|deprecated| deprecated.value.clone())
    };

    if target_hooks_value.is_none() && state.deprecated.is_none() {
        return Ok(());
    }

    let mut in_features = false;
    let mut hooks_written = false;
    let mut merged = Vec::with_capacity(lines.len() + 2);

    for line in lines.drain(..) {
        let trimmed = line.trim();

        if trimmed == "[features]" {
            in_features = true;
            merged.push(line);
            continue;
        }

        if in_features && is_toml_table_header(trimmed) {
            if !state.hooks_seen
                && let Some(value) = &target_hooks_value
            {
                let indent = state
                    .deprecated
                    .as_ref()
                    .map(|deprecated| deprecated.indent.as_str())
                    .unwrap_or("");
                merged.push(format!("{indent}hooks = {value}"));
            }
            in_features = false;
            merged.push(line);
            continue;
        }

        if in_features {
            match toml_assignment_key(&line) {
                Some("codex_hooks") => continue,
                Some("hooks") => {
                    if hooks_written {
                        continue;
                    }
                    if enable_hooks {
                        let indent: String =
                            line.chars().take_while(|c| c.is_whitespace()).collect();
                        merged.push(format!("{indent}hooks = true"));
                    } else {
                        merged.push(line);
                    }
                    hooks_written = true;
                    continue;
                }
                _ => {}
            }
        }

        merged.push(line);
    }

    if state.features_seen && in_features && !state.hooks_seen {
        if let Some(value) = &target_hooks_value {
            let indent = state
                .deprecated
                .as_ref()
                .map(|deprecated| deprecated.indent.as_str())
                .unwrap_or("");
            merged.push(format!("{indent}hooks = {value}"));
        }
    } else if !state.features_seen && enable_hooks {
        if !merged.is_empty() && !merged.last().is_some_and(|s| s.is_empty()) {
            merged.push(String::new());
        }
        merged.push("[features]".into());
        merged.push("hooks = true".into());
    }

    let mut output = merged.join("\n");
    if !output.ends_with('\n') {
        output.push('\n');
    }
    if output != original {
        std::fs::write(config_path, output)?;
    }
    Ok(())
}

#[derive(Default)]
struct CodexFeaturesState {
    features_seen: bool,
    hooks_seen: bool,
    deprecated: Option<DeprecatedCodexHooksFeature>,
}

struct DeprecatedCodexHooksFeature {
    indent: String,
    value: String,
}

fn codex_features_state(lines: &[String]) -> CodexFeaturesState {
    let mut state = CodexFeaturesState::default();
    let mut in_features = false;

    for line in lines {
        let trimmed = line.trim();
        if trimmed == "[features]" {
            state.features_seen = true;
            in_features = true;
            continue;
        }

        if in_features && is_toml_table_header(trimmed) {
            in_features = false;
        }

        if !in_features {
            continue;
        }

        match toml_assignment_key(line) {
            Some("hooks") => state.hooks_seen = true,
            Some("codex_hooks") if state.deprecated.is_none() => {
                let indent: String = line.chars().take_while(|c| c.is_whitespace()).collect();
                let value = toml_assignment_value(line).unwrap_or("true").to_string();
                state.deprecated = Some(DeprecatedCodexHooksFeature { indent, value });
            }
            _ => {}
        }
    }

    state
}

fn toml_assignment_key(line: &str) -> Option<&str> {
    let trimmed = line.trim_start();
    if trimmed.starts_with('#') || trimmed.starts_with(';') {
        return None;
    }

    trimmed
        .split_once('=')
        .map(|(key, _)| key.trim().trim_matches('"'))
}

fn toml_assignment_value(line: &str) -> Option<&str> {
    let trimmed = line.trim_start();
    if trimmed.starts_with('#') || trimmed.starts_with(';') {
        return None;
    }

    trimmed.split_once('=').map(|(_, value)| value.trim())
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
fn install_hook_codex_prose(hook: &Hook, global: bool, agents: &[Agent]) -> Result<bool> {
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
        // The same question every presence read asks, from the same bytes.
        if content_carries_hook_prose(&content, &hook.name, &action_line) {
            wrote = true;
            continue;
        }

        // A section that is present but no longer carries the hook's action
        // line — a heading whose body was edited away, or a block left by a
        // different event — is REPLACED, not skipped: skipping it left the
        // agent with a marker and no behavior, and every presence read then
        // had nothing to report.
        let content = strip_stale_prose_section(&content, &hook.name);

        // Append INSIDE `developer_instructions`, so what is written is what
        // the predicate above will find on the next run.
        let Some(instructions) = developer_instructions_span(&content) else {
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
        if !content_carries_hook_prose(&new_content, &hook.name, &action_line) {
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
fn strip_stale_prose_section(content: &str, hook_name: &str) -> String {
    let Some(span) = developer_instructions_span(content) else {
        return content.to_string();
    };
    let Some(inner) = hook_prose_section_range(&content[span.clone()], hook_name) else {
        return content.to_string();
    };
    let range = span.start + inner.start..span.start + inner.end;
    let start = if range.end == span.end && content[..range.start].ends_with("\n\n") {
        range.start - 1
    } else {
        range.start
    };
    format!("{}{}", &content[..start], &content[range.end..])
}

pub fn install_codex_fallback_hooks_for_agents(
    hooks: &[Hook],
    global: bool,
    agents: &[Agent],
) -> Result<()> {
    for hook in hooks {
        if hook.applies_to(Harness::Codex.id()) && codex_event_for(&hook.event).is_none() {
            let _ = install_hook_codex_prose(hook, global, agents)?;
        }
    }
    Ok(())
}

/// Remove a hook entry from `<scope>/.codex/hooks.json`. Prunes empty matcher
/// groups and the event key when the last entry goes. Leaves
/// `[features] hooks = true` in `config.toml` because other hooks may
/// rely on it.
pub(super) fn remove_hook_from_codex_json(
    global: bool,
    name: &str,
    script_path: &Path,
) -> Result<()> {
    validate_item_name(name)?;
    let root = codex_root(global);
    let hooks_json = root.join("hooks.json");
    let Some(mut doc) =
        super::read_hooks_config(&hooks_json).context(super::REFUSE_UNPARSEABLE_CONFIG)?
    else {
        return Ok(());
    };

    let mut changed = false;

    if let Some(hooks) = doc.get_mut("hooks").and_then(|h| h.as_object_mut()) {
        let owned_commands = codex_owned_hook_commands(global, name, script_path);
        changed |= remove_hook_entries_from_hooks_object(hooks, &owned_commands);
        if hooks.is_empty()
            && let Some(map) = doc.as_object_mut()
        {
            map.remove("hooks");
        }
    }

    if changed {
        if doc.as_object().is_some_and(|m| m.is_empty()) {
            match std::fs::remove_file(&hooks_json) {
                Ok(()) => {}
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
                Err(err) => {
                    return Err(err).with_context(|| {
                        format!("removing Codex hooks config {}", hooks_json.display())
                    });
                }
            }
        } else {
            let output = crate::config::to_json_pretty(&doc)?;
            std::fs::write(&hooks_json, output)
                .with_context(|| format!("writing Codex hooks config {}", hooks_json.display()))?;
        }
    }
    Ok(())
}

/// Strip any `## Safety: <name>` prose block we previously injected into codex
/// agent TOMLs (legacy fallback path). Idempotent.
pub(super) fn strip_hook_prose_from_codex_agents(global: bool, name: &str) -> Result<()> {
    validate_item_name(name)?;
    let agents_dir = Harness::Codex.agents_dir(global);
    if !agents_dir.exists() {
        return Ok(());
    }
    let marker = format!("\n## Safety: {name}\n");
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
            if let Some(start) = content.find(&marker) {
                // Find the end: next '## ' header or the closing ''' of
                // developer_instructions, whichever comes first.
                let tail = &content[start + 1..];
                let next_section = tail.find("\n## ").map(|p| start + 1 + p + 1);
                let close_pos = content[start..].find("\n'''").map(|p| start + p + 1);
                let end = [next_section, close_pos]
                    .into_iter()
                    .flatten()
                    .min()
                    .unwrap_or(content.len());
                let mut new_content = String::with_capacity(content.len());
                new_content.push_str(&content[..start]);
                new_content.push_str(&content[end..]);
                std::fs::write(&path, new_content)
                    .with_context(|| format!("writing Codex agent {}", path.display()))?;
            }
        }
    }
    Ok(())
}
