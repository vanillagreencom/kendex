//! Codex hooks: native registration under `<scope>/.codex/`, the
//! `config.toml` feature toggle that enables it, and the
//! `developer_instructions` prose fallback for events Codex has no
//! equivalent for.

use super::{checked_child_path, remove_hook_entries_from_hooks_object, shell_quote};
use crate::agent::Agent;
use crate::hook::Hook;
use crate::path_safety::validate_item_name;
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

mod prose;

pub(crate) use prose::{
    CodexProse, codex_hook_prose, install_codex_fallback_hooks_for_agents,
    strip_hook_prose_from_codex_agents,
};
/// The block and the marker inside it are written by [`prose`] and read back
/// only by tests, which reach them through this module's path.
#[cfg(test)]
pub(crate) use prose::{
    codex_agent_prose_section, codex_hook_safety_block, codex_hook_safety_marker,
};

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
        None => prose::install_hook_codex_prose(hook, global, agents),
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
    /// The path is the `config.toml` that has to say otherwise.
    FeatureDisabled(PathBuf),
    /// A file this answer depends on exists and could not be parsed. Not a
    /// missing registration: reinstalling repairs nothing, and the note names
    /// the file whose repair does.
    Unreadable(String),
}

impl CodexNativeGap {
    /// The note, in the shape every harness's switch report shares: what is
    /// off, and the file that turns it back on.
    pub(crate) fn describe(&self) -> String {
        match self {
            Self::NotRegistered => "script present but not registered".to_string(),
            Self::FeatureDisabled(config) => format!(
                "switched off — [features] hooks is not true in {}",
                config.display()
            ),
            Self::Unreadable(reason) => format!("registration unverifiable — {reason}"),
        }
    }

    /// Is this a gap no reinstall can close?
    pub(crate) fn is_unreadable(&self) -> bool {
        matches!(self, Self::Unreadable(_))
    }

    /// Is every artifact present and the harness simply switched off? Its own
    /// answer because its own remedy: the setting, named in [`Self::describe`].
    pub(crate) fn is_disabled(&self) -> bool {
        matches!(self, Self::FeatureDisabled(_))
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
        &crate::json_config::HOOKS_CONFIG,
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
    let config_path = root.join("config.toml");
    match codex_hooks_feature_state(&config_path) {
        CodexHooksFeature::Enabled => {}
        CodexHooksFeature::Disabled => gaps.push(CodexNativeGap::FeatureDisabled(config_path)),
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
/// explicit `false` all mean codex runs no hooks. The writer parses the same
/// document with the same parser and edits it in place, so it keeps the user's
/// comments and ordering without ever reading string content as structure.
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
    let doc = match parse_codex_config(content, config_path) {
        Ok(doc) => doc,
        Err(reason) => return CodexHooksFeature::Unreadable(reason),
    };
    if doc
        .get("features")
        .and_then(toml_edit::Item::as_table_like)
        .and_then(|features| features.get("hooks"))
        .and_then(toml_edit::Item::as_bool)
        .unwrap_or(false)
    {
        CodexHooksFeature::Enabled
    } else {
        CodexHooksFeature::Disabled
    }
}

/// The one parse of a Codex `config.toml`, for the reader and the writer
/// alike: whether the file is readable and what it says are one answer, and a
/// writer that parsed differently from the presence check would rewrite a file
/// the check had already called unreadable.
fn parse_codex_config(content: &str, config_path: &Path) -> Result<toml_edit::DocumentMut, String> {
    content.parse::<toml_edit::DocumentMut>().map_err(|err| {
        format!(
            "{} is not valid TOML: {}",
            config_path.display(),
            toml_error_summary(&err)
        )
    })
}

/// The first line of a TOML parse failure — the one carrying the location.
/// The rest is a multi-line source excerpt, and every consumer here puts the
/// message on ONE report line.
fn toml_error_summary(err: &toml_edit::TomlError) -> String {
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
    let mut doc = super::read_hooks_config(hooks_json, &crate::json_config::HOOKS_CONFIG)
        .context(crate::json_config::REFUSE_UNPARSEABLE_CONFIG)?
        .unwrap_or_else(|| serde_json::json!({}));

    let root_map = doc
        .as_object_mut()
        .expect("validated by json_config: the document is an object");
    let hooks_obj = root_map
        .entry("hooks")
        .or_insert_with(|| serde_json::json!({}))
        .as_object_mut()
        .expect("validated by json_config: `hooks` is an object");
    remove_hook_entries_from_hooks_object(hooks_obj, owned_commands);
    // Created only when the key is absent; a value that is not an array made
    // the read unreadable, so none reaches this point to be replaced.
    let event_arr = hooks_obj
        .entry(codex_event)
        .or_insert_with(|| serde_json::json!([]))
        .as_array_mut()
        .expect("validated by json_config: an event value is an array");

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
/// preserving any user content: the edit is made through `toml_edit`, so
/// comments, spacing and key order survive it. Removes the deprecated
/// `codex_hooks` feature flag from the `[features]` table so Codex doesn't
/// warn about custom config.
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

/// Both feature-flag writers, over one parsed document.
///
/// Every mutation goes through `toml_edit`: it is syntax-aware, so a
/// `[features]` header or a `codex_hooks = …` line that appears inside a
/// multiline STRING is content and is never touched, and it is
/// format-preserving, so the comments, spacing and key order the user wrote
/// come back out unchanged. The line scanner this replaced answered both
/// questions from trimmed text: a string containing `[features]` made it write
/// `hooks = true` at the document root — codex reads no feature there, and the
/// install reported success — and a string containing `codex_hooks = …` had
/// that line deleted out from under the user during migration.
///
/// An edit that cannot be expressed against the parsed document — a `features`
/// or `features.hooks` that is not the shape this owns — is refused by name
/// rather than forced through text, because forcing it destroys content vstack
/// does not own.
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
    // A file codex itself cannot read is not one to splice a flag into — the
    // install would report success and never run. What the user has to fix is
    // the parse failure, so that is what this says, and the file is left
    // exactly as it is.
    let mut doc = parse_codex_config(&original, config_path).map_err(|reason| {
        anyhow::anyhow!("{reason}").context(crate::json_config::REFUSE_UNPARSEABLE_CONFIG)
    })?;

    let features = match doc.get("features") {
        None => None,
        Some(item) => Some(item.as_table_like().ok_or_else(|| {
            anyhow::anyhow!(
                "refusing to rewrite `features` in {}: it is not a table, so vstack cannot record the Codex hooks flag in it; fix the file by hand, then rerun",
                config_path.display()
            )
        })?),
    };
    let deprecated = features
        .and_then(|features| features.get("codex_hooks"))
        .and_then(toml_edit::Item::as_value)
        .cloned();
    let hooks_present = features.is_some_and(|features| features.contains_key("hooks"));

    // What `hooks` becomes. Enabling always says `true`; the migration only
    // carries the deprecated key's own value over, and never past an explicit
    // `hooks` the user already set.
    let target = if enable_hooks {
        Some(toml_edit::Value::from(true))
    } else if hooks_present {
        None
    } else {
        deprecated.clone()
    };
    if target.is_none() && deprecated.is_none() {
        return Ok(());
    }

    let features = codex_features_table(&mut doc, config_path)?;
    if deprecated.is_some() {
        features.remove("codex_hooks");
    }
    if let Some(target) = target {
        set_codex_hooks_flag(features, target, config_path)?;
    }

    let mut output = doc.to_string();
    if !output.ends_with('\n') {
        output.push('\n');
    }
    if output != original {
        std::fs::write(config_path, output)?;
    }
    Ok(())
}

/// The `[features]` table to edit, created empty when the document has none.
/// Callers decide there is an edit to make BEFORE calling, so a migration with
/// nothing to migrate never creates the table.
fn codex_features_table<'a>(
    doc: &'a mut toml_edit::DocumentMut,
    config_path: &Path,
) -> Result<&'a mut dyn toml_edit::TableLike> {
    if doc.get("features").is_none() {
        let mut table = toml_edit::Table::new();
        // A blank line before an appended table, so a config that had content
        // reads as it did when the line writer appended one.
        if !doc.as_table().is_empty() {
            table.decor_mut().set_prefix("\n");
        }
        doc.insert("features", toml_edit::Item::Table(table));
    }
    doc.get_mut("features")
        .and_then(toml_edit::Item::as_table_like_mut)
        .ok_or_else(|| {
            anyhow::anyhow!(
                "refusing to rewrite `features` in {}: it is not a table, so vstack cannot record the Codex hooks flag in it; fix the file by hand, then rerun",
                config_path.display()
            )
        })
}

/// Write `features.hooks`, keeping whatever formatting the user gave the value
/// it replaces — the spacing around it and any trailing comment.
///
/// A `hooks` that is a table or an array is not the flag this owns: replacing
/// it would delete a structure the user wrote, so it is refused by name.
fn set_codex_hooks_flag(
    features: &mut dyn toml_edit::TableLike,
    target: toml_edit::Value,
    config_path: &Path,
) -> Result<()> {
    let Some(existing) = features.get_mut("hooks") else {
        features.insert("hooks", toml_edit::Item::Value(target));
        return Ok(());
    };
    let refuse = || {
        anyhow::anyhow!(
            "refusing to rewrite `features.hooks` in {}: it is not a plain value, and replacing it would discard what is there; fix the file by hand, then rerun",
            config_path.display()
        )
    };
    let existing = existing.as_value_mut().ok_or_else(refuse)?;
    if existing.is_inline_table() || existing.is_array() {
        return Err(refuse());
    }
    let decor = existing.decor().clone();
    *existing = target;
    *existing.decor_mut() = decor;
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
    let Some(mut doc) = super::read_hooks_config(&hooks_json, &crate::json_config::HOOKS_CONFIG)
        .context(crate::json_config::REFUSE_UNPARSEABLE_CONFIG)?
    else {
        return Ok(());
    };

    let mut changed = false;

    if let Some(hooks) = doc.get_mut("hooks") {
        let hooks = hooks
            .as_object_mut()
            .expect("validated by json_config: `hooks` is an object");
        let owned_commands = codex_owned_hook_commands(global, name, script_path);
        changed |= remove_hook_entries_from_hooks_object(hooks, &owned_commands);
        if hooks.is_empty() {
            doc.as_object_mut()
                .expect("validated by json_config: the document is an object")
                .remove("hooks");
        }
    }

    if changed {
        if doc
            .as_object()
            .expect("validated by json_config: the document is an object")
            .is_empty()
        {
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
