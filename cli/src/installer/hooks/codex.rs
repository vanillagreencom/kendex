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

/// Why a codex-native hook that HAS its script still never runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CodexNativeGap {
    /// Nothing in `<root>/hooks.json` points codex at the script.
    NotRegistered,
    /// `[features] hooks` is not on, so codex ignores `hooks.json` entirely.
    FeatureDisabled,
}

impl CodexNativeGap {
    pub(crate) fn describe(self) -> &'static str {
        match self {
            Self::NotRegistered => "script present but not registered",
            Self::FeatureDisabled => "hooks feature disabled",
        }
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
    if !super::hooks_config_registers_script(
        &root.join("hooks.json"),
        Some(codex_event),
        &script_path,
        git_root.map(|root| (CODEX_GIT_TOPLEVEL, root)),
        &owned,
    ) {
        gaps.push(CodexNativeGap::NotRegistered);
    }
    if !codex_hooks_feature_enabled(&root.join("config.toml")) {
        gaps.push(CodexNativeGap::FeatureDisabled);
    }
    gaps
}

/// The repo-root substitution the project-scope command defers to run time.
/// A user who reshapes that command keeps it, so registration checking has to
/// read the command the same way the shell codex hands it to will.
const CODEX_GIT_TOPLEVEL: &str = "$(git rev-parse --show-toplevel)";

/// Is `[features] hooks` the boolean `true`? Read with a real TOML parser,
/// because that is what codex reads it with: a line scanner answers `true`
/// for the literal text `[features]` / `hooks = true` inside an unrelated
/// multiline string, and for the string `"true"` codex would reject. A
/// missing file, an unparseable file, a missing table, a missing key, a
/// non-boolean value, and an explicit `false` all mean codex runs no hooks.
/// The writer stays line-based so it keeps the user's comments and ordering.
pub(super) fn codex_hooks_feature_enabled(config_path: &Path) -> bool {
    let Ok(content) = std::fs::read_to_string(config_path) else {
        return false;
    };
    let Ok(doc) = content.parse::<toml::Value>() else {
        return false;
    };
    doc.get("features")
        .and_then(|features| features.get("hooks"))
        .and_then(|hooks| hooks.as_bool())
        .unwrap_or(false)
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
    let mut doc: serde_json::Value = if hooks_json.exists() {
        let content = std::fs::read_to_string(hooks_json)?;
        serde_json::from_str(&content).unwrap_or(serde_json::json!({}))
    } else {
        serde_json::json!({})
    };

    let root_map = doc.as_object_mut().unwrap();
    if !root_map.contains_key("hooks") {
        root_map.insert("hooks".into(), serde_json::json!({}));
    }
    let hooks_obj = root_map.get_mut("hooks").unwrap().as_object_mut().unwrap();
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

    let marker = codex_hook_safety_marker(&hook.name);
    let mut wrote = false;
    for agent in agents {
        validate_item_name(&agent.name)?;
        let toml_path = checked_child_path(&agents_dir, &format!("{}.toml", agent.name))?;
        if !toml_path.exists() {
            continue;
        }

        let content = std::fs::read_to_string(&toml_path)?;
        if content.contains(&marker) {
            wrote = true;
            continue;
        }

        let Some(close_pos) = content.rfind("'''") else {
            anyhow::bail!(
                "Codex agent `{}` has no developer_instructions block to carry the `{}` hook's safety prose: {}",
                agent.name,
                hook.name,
                toml_path.display()
            );
        };
        let mut new_content = content[..close_pos].to_string();
        new_content.push('\n');
        new_content.push_str(&codex_hook_safety_block(hook));
        new_content.push('\n');
        new_content.push_str(&content[close_pos..]);
        // Only claim the install when the marker presence checking looks for
        // is actually in the bytes about to be written.
        if !new_content.contains(&marker) {
            anyhow::bail!(
                "the `{}` hook's safety block carries no `{marker}` marker for Codex agent `{}`: {}",
                hook.name,
                agent.name,
                toml_path.display()
            );
        }
        std::fs::write(&toml_path, new_content)?;
        wrote = true;
    }

    Ok(wrote)
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
    if !hooks_json.exists() {
        return Ok(());
    }
    let content = std::fs::read_to_string(&hooks_json)
        .with_context(|| format!("reading Codex hooks config {}", hooks_json.display()))?;
    let mut doc: serde_json::Value = serde_json::from_str(&content)
        .with_context(|| format!("parsing Codex hooks config {}", hooks_json.display()))?;

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
