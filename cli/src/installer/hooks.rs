use crate::agent::Agent;
use crate::harness::Harness;
use crate::hook::Hook;
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

pub(crate) fn validate_item_name(name: &str) -> Result<()> {
    if name.is_empty() {
        anyhow::bail!("item name must not be empty");
    }
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        anyhow::bail!("item name must not be empty");
    };
    if !first.is_ascii_alphanumeric() {
        anyhow::bail!("item name {name:?} must start with an ASCII letter or digit");
    }
    if !chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')) {
        anyhow::bail!(
            "item name {name:?} must contain only ASCII letters, digits, '.', '_', or '-'"
        );
    }
    Ok(())
}

fn validate_file_name(file_name: &str) -> Result<()> {
    if file_name.is_empty()
        || file_name == "."
        || file_name == ".."
        || file_name.contains('/')
        || file_name.contains('\\')
        || Path::new(file_name).is_absolute()
    {
        anyhow::bail!("unsafe file name {file_name:?}");
    }
    Ok(())
}

fn checked_child_path(parent: &Path, file_name: &str) -> Result<PathBuf> {
    validate_file_name(file_name)?;
    let path = parent.join(file_name);
    if !path.starts_with(parent) {
        anyhow::bail!(
            "refusing path outside expected directory: {}",
            path.display()
        );
    }
    if parent.exists() {
        let parent_canon = parent
            .canonicalize()
            .with_context(|| format!("canonicalizing {}", parent.display()))?;
        if path.exists() {
            let target_canon = path
                .canonicalize()
                .with_context(|| format!("canonicalizing {}", path.display()))?;
            if !target_canon.starts_with(&parent_canon) {
                anyhow::bail!(
                    "refusing target outside expected directory: {}",
                    path.display()
                );
            }
        } else if let Some(path_parent) = path.parent() {
            let path_parent_canon = path_parent
                .canonicalize()
                .with_context(|| format!("canonicalizing {}", path_parent.display()))?;
            if path_parent_canon != parent_canon {
                anyhow::bail!(
                    "refusing path outside expected directory: {}",
                    path.display()
                );
            }
        }
    }
    Ok(path)
}

fn command_matches_owned_hook_command(command: &str, owned_commands: &[String]) -> bool {
    owned_commands.iter().any(|owned| command == owned)
}

fn hook_entry_mentions_owned_command(entry: &serde_json::Value, owned_commands: &[String]) -> bool {
    entry
        .get("hooks")
        .and_then(|h| h.as_array())
        .is_some_and(|handlers| {
            handlers.iter().any(|handler| {
                handler
                    .get("command")
                    .and_then(|c| c.as_str())
                    .is_some_and(|command| {
                        command_matches_owned_hook_command(command, owned_commands)
                    })
            })
        })
}

fn remove_hook_entries_from_hooks_object(
    hooks_obj: &mut serde_json::Map<String, serde_json::Value>,
    owned_commands: &[String],
) -> bool {
    let mut changed = false;
    let event_keys: Vec<String> = hooks_obj.keys().cloned().collect();
    for event in event_keys {
        if let Some(arr) = hooks_obj.get_mut(&event).and_then(|v| v.as_array_mut()) {
            let before = arr.len();
            arr.retain(|entry| !hook_entry_mentions_owned_command(entry, owned_commands));
            if arr.len() != before {
                changed = true;
            }
            if arr.is_empty() {
                hooks_obj.remove(&event);
                changed = true;
            }
        }
    }
    changed
}

fn claude_hook_command(global: bool, hook_name: &str, script_path: &Path) -> String {
    if global {
        format!("bash {}", shell_quote(&script_path.to_string_lossy()))
    } else {
        format!("bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/{hook_name}.sh\"")
    }
}

fn claude_owned_hook_commands(global: bool, hook_name: &str, script_path: &Path) -> Vec<String> {
    let mut commands = vec![claude_hook_command(global, hook_name, script_path)];
    if global {
        commands.push(script_path.to_string_lossy().into_owned());
    } else {
        commands.push(format!("$CLAUDE_PROJECT_DIR/.claude/hooks/{hook_name}.sh"));
    }
    commands
}

/// Install a hook to a specific harness.
///
/// - Claude Code: copy script + add to settings.json hooks
/// - OpenCode: add permission rules to opencode.json
/// - Codex: native hooks.json entry + script when codex supports the event;
///   safety prose appended to agent TOML developer_instructions otherwise
/// - Cursor: append safety advisory to all .mdc rule files
/// - Pi: no-op (safety prose lives in agent bodies via the Pi generator)
///
/// Honors the optional `harnesses:` allowlist in the hook frontmatter.
pub fn install_hook(
    hook: &Hook,
    harness: Harness,
    global: bool,
    agents: &[Agent],
) -> Result<String> {
    validate_item_name(&hook.name)?;
    if !hook.applies_to(harness.id()) {
        return Ok(format!(
            "[hook] {} → {} (skipped: harness not in `harnesses:`)",
            hook.name,
            harness.name()
        ));
    }
    match harness {
        Harness::ClaudeCode => install_hook_claude(hook, global)?,
        Harness::OpenCode => install_hook_opencode(hook, global)?,
        Harness::Codex => install_hook_codex(hook, global, agents)?,
        Harness::Cursor => install_hook_cursor(hook, global)?,
        Harness::Pi => {}
    }

    Ok(format!(
        "[hook] {} → {} ({})",
        hook.name,
        harness.name(),
        hook.event
    ))
}

/// Claude Code: copy hook script + merge into settings.json
fn install_hook_claude(hook: &Hook, global: bool) -> Result<()> {
    validate_item_name(&hook.name)?;
    // Copy the script
    let hooks_dir = Harness::ClaudeCode
        .hooks_dir(global)
        .expect("Claude hooks dir");
    std::fs::create_dir_all(&hooks_dir)?;
    let dest = checked_child_path(&hooks_dir, &format!("{}.sh", hook.name))?;
    std::fs::write(&dest, &hook.script)?;

    // Make executable
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(0o755))?;
    }

    // Merge into settings.json
    let settings_path = if global {
        crate::config::claude_global_dir().join("settings.json")
    } else {
        crate::config::project_root()
            .join(".claude")
            .join("settings.json")
    };
    let mut settings: serde_json::Value = if settings_path.exists() {
        let content = std::fs::read_to_string(&settings_path)?;
        serde_json::from_str(&content).unwrap_or(serde_json::json!({}))
    } else {
        serde_json::json!({})
    };

    let map = settings.as_object_mut().unwrap();
    if !map.contains_key("hooks") {
        map.insert("hooks".into(), serde_json::json!({}));
    }
    let hooks_obj = map.get_mut("hooks").unwrap().as_object_mut().unwrap();
    let owned_commands = claude_owned_hook_commands(global, &hook.name, &dest);
    remove_hook_entries_from_hooks_object(hooks_obj, &owned_commands);

    // Build the hook entry.
    // Project installs: use $CLAUDE_PROJECT_DIR so hooks resolve regardless of CWD.
    // Global installs: use the absolute path under the global config dir.
    let command = claude_hook_command(global, &hook.name, &dest);
    let hook_entry = {
        let mut entry = serde_json::json!({
            "hooks": [{
                "type": "command",
                "command": command,
            }]
        });
        if let Some(ref matcher) = hook.matcher {
            entry
                .as_object_mut()
                .unwrap()
                .insert("matcher".into(), serde_json::Value::String(matcher.clone()));
        }
        if let Some(timeout) = hook.timeout {
            entry
                .as_object_mut()
                .unwrap()
                .insert("timeout".into(), serde_json::Value::Number(timeout.into()));
        }
        entry
    };

    // Add to the appropriate event array
    if !hooks_obj.get(&hook.event).is_some_and(|v| v.is_array()) {
        hooks_obj.insert(hook.event.clone(), serde_json::json!([]));
    }
    let event_arr = hooks_obj
        .get_mut(&hook.event)
        .unwrap()
        .as_array_mut()
        .unwrap();

    event_arr.push(hook_entry);

    let output = serde_json::to_string_pretty(&settings)?;
    std::fs::write(&settings_path, output)?;

    Ok(())
}

/// OpenCode: add permission rules based on hook intent
fn install_hook_opencode(hook: &Hook, global: bool) -> Result<()> {
    validate_item_name(&hook.name)?;
    let config_path = if global {
        crate::config::opencode_global_config_path()
    } else {
        crate::config::opencode_project_config_path()
    };
    let instruction_dir = opencode_hook_instruction_dir(global);
    if instruction_dir.exists() {
        checked_child_path(&instruction_dir, &format!("vstack-hook-{}.md", hook.name))?;
    }
    let instruction_path = opencode_hook_instruction_path(global, &hook.name);
    let instruction_ref = opencode_hook_instruction_ref(global, &hook.name);
    install_hook_opencode_at_path(hook, &config_path, &instruction_path, &instruction_ref)
}

fn opencode_hook_instruction_dir(global: bool) -> PathBuf {
    if global {
        crate::config::opencode_global_dir().join("instructions")
    } else {
        crate::config::project_root()
            .join(".opencode")
            .join("instructions")
    }
}

pub(crate) fn opencode_hook_instruction_path(global: bool, name: &str) -> PathBuf {
    let file_name = format!("vstack-hook-{name}.md");
    opencode_hook_instruction_dir(global).join(file_name)
}

fn opencode_hook_instruction_ref(global: bool, name: &str) -> String {
    let file_name = format!("vstack-hook-{name}.md");
    if global {
        format!("instructions/{file_name}")
    } else {
        format!(".opencode/instructions/{file_name}")
    }
}

pub(crate) fn opencode_hook_instruction_contents(hook: &Hook) -> String {
    format!("# Safety: {}\n\n{}", hook.name, hook.safety_prose())
}

pub(crate) fn cursor_hook_rule_contents(hook: &Hook) -> String {
    let mut output = String::new();
    output.push_str("---\n");
    output.push_str(&format!(
        "description: \"Safety: {} — {}\"\n",
        hook.name, hook.description
    ));
    output.push_str("alwaysApply: true\n");
    output.push_str("---\n\n");
    output.push_str(&format!("# Safety: {}\n\n", hook.name));
    output.push_str(&hook.safety_prose());
    output
}

pub(crate) fn codex_hook_safety_block(hook: &Hook) -> String {
    format!("## Safety: {}\n\n{}", hook.name, hook.safety_prose())
}

fn install_hook_opencode_at_path(
    hook: &Hook,
    config_path: &Path,
    instruction_path: &Path,
    instruction_ref: &str,
) -> Result<()> {
    if let Some(parent) = config_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if let Some(parent) = instruction_path.parent() {
        std::fs::create_dir_all(parent)?;
        let file_name = instruction_path
            .file_name()
            .and_then(|name| name.to_str())
            .context("OpenCode hook instruction path missing file name")?;
        checked_child_path(parent, file_name)?;
    }

    std::fs::write(instruction_path, opencode_hook_instruction_contents(hook))?;

    let mut config: serde_json::Value = if config_path.exists() {
        let content = std::fs::read_to_string(config_path)?;
        serde_json::from_str(&content)?
    } else {
        serde_json::json!({ "$schema": "https://opencode.ai/config.json" })
    };

    let map = config.as_object_mut().unwrap();

    // OpenCode doesn't have hooks — convert to permission rules and instructions
    if !map.contains_key("permission") {
        map.insert("permission".into(), serde_json::json!({}));
    }

    // Add safety-relevant permission restrictions based on hook type
    if hook.event == "PreToolUse" {
        let perms = map.get_mut("permission").unwrap().as_object_mut().unwrap();

        if hook.matcher.as_deref() == Some("Bash") {
            // For bash hooks: set bash permission to "ask" (require confirmation)
            if !perms.contains_key("bash") {
                perms.insert("bash".into(), serde_json::json!({ "*": "ask" }));
            }
        }
    }

    // OpenCode instructions are file paths, so write a dedicated file and reference it.
    if !map.contains_key("instructions") {
        map.insert("instructions".into(), serde_json::json!([]));
    }
    let instructions = map.get_mut("instructions").unwrap().as_array_mut().unwrap();

    let already_has = instructions
        .iter()
        .any(|i| i.as_str() == Some(instruction_ref));

    if !already_has {
        instructions.push(serde_json::Value::String(instruction_ref.to_string()));
    }

    let output = serde_json::to_string_pretty(&config)?;
    std::fs::write(config_path, output)?;

    Ok(())
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
fn install_hook_codex(hook: &Hook, global: bool, agents: &[Agent]) -> Result<()> {
    match codex_event_for(&hook.event) {
        Some(codex_event) => install_hook_codex_native(hook, codex_event, global),
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

fn shell_quote(s: &str) -> String {
    if s.chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '.' | '_' | '-'))
    {
        s.to_string()
    } else {
        let escaped = s.replace('\'', "'\\''");
        format!("'{escaped}'")
    }
}

/// Merge one hook handler into `<root>/hooks.json`. Existing entries for other
/// hooks are preserved. The handler is keyed by the script file name so reruns
/// don't duplicate.
#[cfg(test)]
fn merge_codex_hooks_json(
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

    let output = serde_json::to_string_pretty(&doc)?;
    std::fs::write(hooks_json, output)?;
    Ok(())
}

/// Ensure `[features] hooks = true` is set in `<root>/config.toml`,
/// preserving any user content. Uses a text-level merge so we don't clobber
/// comments or key ordering. Removes the deprecated `codex_hooks` feature flag
/// from the `[features]` table so Codex doesn't warn about custom config.
fn enable_codex_hooks_feature(config_path: &Path) -> Result<()> {
    merge_codex_hooks_feature(config_path, true)
}

/// Migrate `[features] codex_hooks = ...` to `hooks = ...` when the file
/// already exists. Unlike [`enable_codex_hooks_feature`], this is intentionally
/// a no-op for missing files and does not force hooks on when users have
/// `hooks = false`.
fn migrate_codex_hooks_feature(config_path: &Path) -> Result<()> {
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

fn is_toml_table_header(trimmed_line: &str) -> bool {
    trimmed_line.starts_with('[') && trimmed_line.ends_with(']')
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
fn install_hook_codex_prose(hook: &Hook, global: bool, agents: &[Agent]) -> Result<()> {
    validate_item_name(&hook.name)?;
    let agents_dir = Harness::Codex.agents_dir(global);
    if !agents_dir.exists() {
        return Ok(());
    }

    for agent in agents {
        validate_item_name(&agent.name)?;
        let toml_path = checked_child_path(&agents_dir, &format!("{}.toml", agent.name))?;
        if !toml_path.exists() {
            continue;
        }

        let content = std::fs::read_to_string(&toml_path)?;
        if content.contains(&hook.name) {
            continue;
        }

        if let Some(close_pos) = content.rfind("'''") {
            let mut new_content = content[..close_pos].to_string();
            new_content.push('\n');
            new_content.push_str(&codex_hook_safety_block(hook));
            new_content.push('\n');
            new_content.push_str(&content[close_pos..]);
            std::fs::write(&toml_path, new_content)?;
        }
    }

    Ok(())
}

pub fn install_codex_fallback_hooks_for_agents(
    hooks: &[Hook],
    global: bool,
    agents: &[Agent],
) -> Result<()> {
    for hook in hooks {
        if hook.applies_to(Harness::Codex.id()) && codex_event_for(&hook.event).is_none() {
            install_hook_codex_prose(hook, global, agents)?;
        }
    }
    Ok(())
}

pub(crate) fn cursor_hook_rule_path(global: bool, name: &str) -> PathBuf {
    Harness::Cursor
        .agents_dir(global)
        .join(format!("safety-{name}.mdc"))
}

/// Cursor: add safety advisory to a dedicated .mdc file
fn install_hook_cursor(hook: &Hook, global: bool) -> Result<()> {
    validate_item_name(&hook.name)?;
    let rules_dir = Harness::Cursor.agents_dir(global);
    std::fs::create_dir_all(&rules_dir)?;

    let path = checked_child_path(&rules_dir, &format!("safety-{}.mdc", hook.name))?;
    std::fs::write(&path, cursor_hook_rule_contents(hook))?;
    Ok(())
}

/// Remove a hook's harness-specific artifacts/config. Codex cleanup also
/// strips legacy `## Safety: <name>` prose from generated Codex agent TOMLs,
/// because older installs stored unmapped hook guidance there.
pub fn remove_hook_install(name: &str, harness: Harness, global: bool) -> Result<Vec<PathBuf>> {
    validate_item_name(name)?;
    let mut removed = Vec::new();

    match harness {
        Harness::ClaudeCode => {
            let hooks_dir = harness.hooks_dir(global).expect("Claude hooks dir");
            let hook_path = checked_child_path(&hooks_dir, &format!("{name}.sh"))?;
            if hook_path.exists() {
                std::fs::remove_file(&hook_path)?;
                removed.push(hook_path);
            }
            remove_hook_from_claude_settings(global, name, &hooks_dir.join(format!("{name}.sh")))?;
        }
        Harness::OpenCode => {
            remove_hook_from_opencode_json(global, name)?;
        }
        Harness::Codex => {
            let root = codex_root(global);
            let hooks_dir = root.join("hooks");
            let script_path = checked_child_path(&hooks_dir, &format!("{name}.sh"))?;
            if script_path.exists() {
                std::fs::remove_file(&script_path)?;
                removed.push(script_path.clone());
            }
            remove_hook_from_codex_json(global, name, &script_path)?;
            strip_hook_prose_from_codex_agents(global, name)?;
        }
        Harness::Cursor => {
            let rules_dir = Harness::Cursor.agents_dir(global);
            let rule_path = checked_child_path(&rules_dir, &format!("safety-{name}.mdc"))?;
            if rule_path.exists() {
                std::fs::remove_file(&rule_path)?;
                removed.push(rule_path);
            }
        }
        Harness::Pi => {}
    }

    Ok(removed)
}

/// Remove a hook entry from Claude Code settings.json
fn remove_hook_from_claude_settings(global: bool, name: &str, script_path: &Path) -> Result<()> {
    validate_item_name(name)?;
    let settings_path = if global {
        crate::config::claude_global_dir().join("settings.json")
    } else {
        crate::config::project_root()
            .join(".claude")
            .join("settings.json")
    };
    if !settings_path.exists() {
        return Ok(());
    }
    let content = std::fs::read_to_string(&settings_path)?;
    let mut settings: serde_json::Value = serde_json::from_str(&content)?;

    let mut changed = false;
    if let Some(hooks) = settings.get_mut("hooks").and_then(|h| h.as_object_mut()) {
        let owned_commands = claude_owned_hook_commands(global, name, script_path);
        changed |= remove_hook_entries_from_hooks_object(hooks, &owned_commands);
    }

    if changed {
        let output = serde_json::to_string_pretty(&settings)?;
        std::fs::write(&settings_path, output)?;
    }
    Ok(())
}

/// Remove a hook entry from `<scope>/.codex/hooks.json`. Prunes empty matcher
/// groups and the event key when the last entry goes. Leaves
/// `[features] hooks = true` in `config.toml` because other hooks may
/// rely on it.
fn remove_hook_from_codex_json(global: bool, name: &str, script_path: &Path) -> Result<()> {
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
            let output = serde_json::to_string_pretty(&doc)?;
            std::fs::write(&hooks_json, output)
                .with_context(|| format!("writing Codex hooks config {}", hooks_json.display()))?;
        }
    }
    Ok(())
}

/// Strip any `## Safety: <name>` prose block we previously injected into codex
/// agent TOMLs (legacy fallback path). Idempotent.
fn strip_hook_prose_from_codex_agents(global: bool, name: &str) -> Result<()> {
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

/// Remove hook instructions and permission entries from OpenCode opencode.json
fn remove_hook_from_opencode_json(global: bool, name: &str) -> Result<()> {
    validate_item_name(name)?;
    let config_path = if global {
        crate::config::opencode_global_config_path()
    } else {
        crate::config::opencode_project_config_path()
    };
    let instruction_path = opencode_hook_instruction_path(global, name);
    let instruction_ref = opencode_hook_instruction_ref(global, name);
    remove_hook_from_opencode_json_at_path(&config_path, &instruction_path, &instruction_ref, name)
}

fn remove_hook_from_opencode_json_at_path(
    config_path: &Path,
    instruction_path: &Path,
    instruction_ref: &str,
    name: &str,
) -> Result<()> {
    validate_item_name(name)?;
    if let Some(parent) = instruction_path.parent()
        && parent.exists()
    {
        let file_name = instruction_path
            .file_name()
            .and_then(|name| name.to_str())
            .context("OpenCode hook instruction path missing file name")?;
        checked_child_path(parent, file_name)?;
    }
    if !config_path.exists() {
        let _ = std::fs::remove_file(instruction_path);
        return Ok(());
    }
    let content = std::fs::read_to_string(config_path)?;
    let mut config: serde_json::Value = serde_json::from_str(&content)?;

    let mut changed = false;

    // Remove the current file-path based format plus the legacy inline prose format.
    let keywords: Vec<&str> = name.split('-').collect();
    if let Some(instructions) = config
        .get_mut("instructions")
        .and_then(|i| i.as_array_mut())
    {
        let before = instructions.len();
        instructions.retain(|i| {
            let Some(s) = i.as_str() else { return true };
            if s == instruction_ref {
                return false;
            }
            let s_lower = s.to_lowercase();
            !keywords.iter().all(|kw| s_lower.contains(kw))
        });
        if instructions.len() != before {
            changed = true;
        }
    }

    let _ = std::fs::remove_file(instruction_path);

    // If no vstack hook instructions remain, remove the temporary bash restriction we added.
    if let Some(map) = config.as_object_mut() {
        let no_vstack_hook_instructions = map
            .get("instructions")
            .and_then(|i| i.as_array())
            .is_none_or(|entries| {
                !entries.iter().any(|entry| {
                    entry
                        .as_str()
                        .is_some_and(|value| value.contains("vstack-hook-"))
                })
            });

        if let Some(instructions) = map.get("instructions").and_then(|i| i.as_array())
            && instructions.is_empty()
        {
            map.remove("instructions");
            changed = true;
        }

        if no_vstack_hook_instructions
            && let Some(permission) = map.get_mut("permission").and_then(|p| p.as_object_mut())
        {
            let remove_bash = permission
                .get("bash")
                .and_then(|bash| bash.as_object())
                .is_some_and(|bash| {
                    bash.len() == 1
                        && bash
                            .get("*")
                            .and_then(|value| value.as_str())
                            .is_some_and(|value| value == "ask")
                });
            if remove_bash {
                permission.remove("bash");
                changed = true;
            }
            if permission.is_empty() {
                map.remove("permission");
                changed = true;
            }
        }
    }

    if changed {
        let output = serde_json::to_string_pretty(&config)?;
        std::fs::write(config_path, output)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hook_fixture(name: &str, event: &str, matcher: Option<&str>) -> Hook {
        Hook {
            name: name.into(),
            event: event.into(),
            matcher: matcher.map(|m| m.into()),
            description: format!("{name} test hook"),
            safety: None,
            timeout: Some(30),
            harnesses: None,
            script: format!("#!/usr/bin/env bash\n# {name}\nexit 0\n"),
            source_path: PathBuf::new(),
        }
    }

    fn tmpdir(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "vstack_{label}_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn codex_event_for_known_events() {
        assert_eq!(codex_event_for("PreToolUse"), Some("PreToolUse"));
        assert_eq!(codex_event_for("PostToolUse"), Some("PostToolUse"));
        assert_eq!(codex_event_for("Stop"), Some("Stop"));
        assert_eq!(codex_event_for("SessionStart"), Some("SessionStart"));
    }

    #[test]
    fn codex_event_for_taskcompleted_is_unmapped() {
        // TaskCompleted has no clean codex equivalent — routes to prose fallback.
        assert_eq!(codex_event_for("TaskCompleted"), None);
    }

    #[test]
    fn merge_codex_hooks_json_creates_new_file() {
        let dir = tmpdir("codex_merge_new");
        let hooks_json = dir.join("hooks.json");
        let hook = hook_fixture("block-bare-cd", "PreToolUse", Some("Bash"));
        let command = "bash /tmp/block-bare-cd.sh";
        merge_codex_hooks_json(&hooks_json, "PreToolUse", &hook, command).unwrap();

        let doc: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&hooks_json).unwrap()).unwrap();
        let arr = doc
            .pointer("/hooks/PreToolUse")
            .and_then(|v| v.as_array())
            .expect("PreToolUse array present");
        assert_eq!(arr.len(), 1);
        assert_eq!(
            arr[0].pointer("/matcher").and_then(|v| v.as_str()),
            Some("Bash")
        );
        assert_eq!(
            arr[0].pointer("/hooks/0/command").and_then(|v| v.as_str()),
            Some(command)
        );
        assert_eq!(
            arr[0].pointer("/hooks/0/timeout").and_then(|v| v.as_u64()),
            Some(30)
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn merge_codex_hooks_json_is_idempotent() {
        let dir = tmpdir("codex_merge_idempotent");
        let hooks_json = dir.join("hooks.json");
        let hook = hook_fixture("block-bare-cd", "PreToolUse", Some("Bash"));
        let command = "bash /tmp/block-bare-cd.sh";
        merge_codex_hooks_json(&hooks_json, "PreToolUse", &hook, command).unwrap();
        merge_codex_hooks_json(&hooks_json, "PreToolUse", &hook, command).unwrap();
        let doc: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&hooks_json).unwrap()).unwrap();
        assert_eq!(
            doc.pointer("/hooks/PreToolUse")
                .and_then(|v| v.as_array())
                .map(|a| a.len()),
            Some(1)
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn merge_codex_hooks_json_replaces_existing_hook_registration() {
        let dir = tmpdir("codex_merge_replace");
        let hooks_json = dir.join("hooks.json");
        std::fs::write(
            &hooks_json,
            r#"{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash /home/.codex/hooks/guard.sh", "timeout": 30}]
      }
    ]
  }
}"#,
        )
        .unwrap();
        let mut hook = hook_fixture("guard", "PostCompact", None);
        hook.timeout = Some(5);
        merge_codex_hooks_json(
            &hooks_json,
            "PostCompact",
            &hook,
            "bash /home/.codex/hooks/guard.sh",
        )
        .unwrap();

        let doc: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&hooks_json).unwrap()).unwrap();
        assert!(doc.pointer("/hooks/PreToolUse").is_none());
        let arr = doc
            .pointer("/hooks/PostCompact")
            .and_then(|v| v.as_array())
            .expect("PostCompact array present");
        assert_eq!(arr.len(), 1);
        assert!(arr[0].pointer("/matcher").is_none());
        assert_eq!(
            arr[0].pointer("/hooks/0/timeout").and_then(|v| v.as_u64()),
            Some(5)
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn validate_item_name_rejects_path_like_names() {
        for name in [
            "",
            ".",
            "..",
            "../victim",
            "a/b",
            "a\\b",
            "/abs",
            "-leading-dash",
            "bad\";touch pwn;#",
            "bad$(touch pwn)",
            "has spaces",
            "has\nnewline",
            "bad`touch pwn`",
        ] {
            assert!(validate_item_name(name).is_err(), "accepted {name:?}");
        }
        assert!(validate_item_name("guard-hook").is_ok());
        assert!(validate_item_name("guard.hook_1").is_ok());
    }

    #[test]
    fn hook_prune_preserves_user_handlers_with_same_basename() {
        let mut hooks_obj = serde_json::json!({
            "PreToolUse": [
                {
                    "matcher": "Bash",
                    "hooks": [{"type": "command", "command": "bash ./scripts/guard.sh"}]
                },
                {
                    "matcher": "Bash",
                    "hooks": [{"type": "command", "command": "bash /usr/local/bin/guard.sh"}]
                },
                {
                    "matcher": "Bash",
                    "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\""}]
                }
            ]
        })
        .as_object()
        .unwrap()
        .clone();
        let owned = vec!["bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\"".to_string()];

        assert!(remove_hook_entries_from_hooks_object(
            &mut hooks_obj,
            &owned
        ));
        let arr = hooks_obj
            .get("PreToolUse")
            .and_then(|v| v.as_array())
            .unwrap();
        assert_eq!(arr.len(), 2, "only vstack-owned command should be pruned");
        let body = serde_json::to_string(&hooks_obj).unwrap();
        assert!(body.contains("./scripts/guard.sh"));
        assert!(body.contains("/usr/local/bin/guard.sh"));
        assert!(!body.contains(".claude/hooks/guard.sh"));
    }

    #[test]
    fn merge_codex_hooks_json_does_not_dedupe_substring_collisions() {
        // A hook named `foo` must not be considered already-present when the
        // event already has `notfoo.sh`; only exact vstack-owned commands are
        // pruned.
        let dir = tmpdir("codex_merge_substring");
        let hooks_json = dir.join("hooks.json");
        std::fs::write(
            &hooks_json,
            r#"{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash /home/.codex/hooks/notfoo.sh"}]
      }
    ]
  }
}"#,
        )
        .unwrap();
        let hook = hook_fixture("foo", "PreToolUse", Some("Bash"));
        merge_codex_hooks_json(
            &hooks_json,
            "PreToolUse",
            &hook,
            "bash /home/.codex/hooks/foo.sh",
        )
        .unwrap();

        let doc: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&hooks_json).unwrap()).unwrap();
        let arr = doc
            .pointer("/hooks/PreToolUse")
            .and_then(|v| v.as_array())
            .unwrap();
        assert_eq!(
            arr.len(),
            2,
            "`foo.sh` must not collide with existing `notfoo.sh`"
        );
    }

    #[test]
    fn merge_codex_hooks_json_preserves_existing_entries() {
        let dir = tmpdir("codex_merge_preserve");
        let hooks_json = dir.join("hooks.json");
        std::fs::write(
            &hooks_json,
            r#"{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash /user/own.sh"}]
      }
    ]
  }
}"#,
        )
        .unwrap();

        let hook = hook_fixture("new-one", "PreToolUse", Some("Bash"));
        merge_codex_hooks_json(&hooks_json, "PreToolUse", &hook, "bash /tmp/new-one.sh").unwrap();

        let doc: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&hooks_json).unwrap()).unwrap();
        let arr = doc
            .pointer("/hooks/PreToolUse")
            .and_then(|v| v.as_array())
            .unwrap();
        assert_eq!(arr.len(), 2, "user entry should be preserved");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn merge_codex_hooks_json_preserves_user_handler_with_same_basename() {
        let dir = tmpdir("codex_merge_preserve_same_basename");
        let hooks_json = dir.join("hooks.json");
        std::fs::write(
            &hooks_json,
            r#"{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash /usr/local/bin/guard.sh"}]
      }
    ]
  }
}"#,
        )
        .unwrap();

        let hook = hook_fixture("guard", "PreToolUse", Some("Bash"));
        merge_codex_hooks_json(&hooks_json, "PreToolUse", &hook, "bash /tmp/guard.sh").unwrap();

        let doc: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&hooks_json).unwrap()).unwrap();
        let arr = doc
            .pointer("/hooks/PreToolUse")
            .and_then(|v| v.as_array())
            .unwrap();
        assert_eq!(arr.len(), 2, "user entry with same basename should remain");
        let body = serde_json::to_string(&doc).unwrap();
        assert!(body.contains("/usr/local/bin/guard.sh"));
        assert!(body.contains("/tmp/guard.sh"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn remove_hook_install_codex_strips_script_json_and_legacy_prose() {
        let dir = tmpdir("codex_remove_strip");
        let hooks_dir = dir.join("hooks");
        let agents_dir = dir.join("agents");
        std::fs::create_dir_all(&hooks_dir).unwrap();
        std::fs::create_dir_all(&agents_dir).unwrap();
        std::fs::write(hooks_dir.join("post-edit-lint.sh"), "#!/usr/bin/env bash\n").unwrap();
        std::fs::write(hooks_dir.join("block-bare-cd.sh"), "#!/usr/bin/env bash\n").unwrap();
        let post_edit_command = format!("bash {}", hooks_dir.join("post-edit-lint.sh").display());
        let block_bare_command = format!("bash {}", hooks_dir.join("block-bare-cd.sh").display());

        let hooks_json = dir.join("hooks.json");
        let hooks_doc = serde_json::json!({
            "hooks": {
                "PreToolUse": [
                    {
                        "matcher": "Bash",
                        "hooks": [{"type": "command", "command": block_bare_command}]
                    },
                    {
                        "matcher": "Bash",
                        "hooks": [{"type": "command", "command": "bash /home/.codex/hooks/user-own.sh"}]
                    }
                ],
                "PostToolUse": [
                    {
                        "matcher": "Edit|Write",
                        "hooks": [{"type": "command", "command": post_edit_command}]
                    }
                ]
            }
        });
        std::fs::write(
            &hooks_json,
            serde_json::to_string_pretty(&hooks_doc).unwrap(),
        )
        .unwrap();
        let agent_toml = agents_dir.join("rust.toml");
        std::fs::write(
            &agent_toml,
            r#"name = "rust"
developer_instructions = '''
Body

## Safety: post-edit-lint

Remove me.

## Keep

Keep me.
'''
"#,
        )
        .unwrap();

        crate::test_util::with_codex_home(&dir, || {
            remove_hook_install("post-edit-lint", Harness::Codex, true).unwrap();
        });

        let result: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&hooks_json).unwrap()).unwrap();
        assert!(!hooks_dir.join("post-edit-lint.sh").exists());
        assert!(hooks_dir.join("block-bare-cd.sh").exists());
        assert!(
            result.pointer("/hooks/PostToolUse").is_none(),
            "empty PostToolUse should be pruned"
        );
        let pre = result
            .pointer("/hooks/PreToolUse")
            .unwrap()
            .as_array()
            .unwrap();
        assert_eq!(pre.len(), 2, "unrelated PreToolUse entries preserved");
        let agent = std::fs::read_to_string(agent_toml).unwrap();
        assert!(!agent.contains("Safety: post-edit-lint"));
        assert!(agent.contains("## Keep"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn enable_codex_hooks_feature_creates_section() {
        let dir = tmpdir("codex_features_new");
        let config = dir.join("config.toml");
        enable_codex_hooks_feature(&config).unwrap();
        let body = std::fs::read_to_string(&config).unwrap();
        assert!(body.contains("[features]"));
        assert!(body.contains("hooks = true"));
        assert!(!body.contains("codex_hooks"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn enable_codex_hooks_feature_is_idempotent() {
        let dir = tmpdir("codex_features_idempotent");
        let config = dir.join("config.toml");
        enable_codex_hooks_feature(&config).unwrap();
        let body1 = std::fs::read_to_string(&config).unwrap();
        enable_codex_hooks_feature(&config).unwrap();
        let body2 = std::fs::read_to_string(&config).unwrap();
        assert_eq!(body1, body2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn enable_codex_hooks_feature_preserves_user_content() {
        let dir = tmpdir("codex_features_preserve");
        let config = dir.join("config.toml");
        std::fs::write(
            &config,
            "# user comment\nmodel = \"gpt-5.5\"\n\n[other]\nfoo = 1\n",
        )
        .unwrap();
        enable_codex_hooks_feature(&config).unwrap();
        let body = std::fs::read_to_string(&config).unwrap();
        assert!(body.contains("# user comment"));
        assert!(body.contains("model = \"gpt-5.5\""));
        assert!(body.contains("[other]"));
        assert!(body.contains("hooks = true"));
        assert!(!body.contains("codex_hooks"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn enable_codex_hooks_feature_inserts_under_existing_features() {
        let dir = tmpdir("codex_features_existing");
        let config = dir.join("config.toml");
        std::fs::write(
            &config,
            "[features]\nother_flag = true\n\n[unrelated]\nx = 1\n",
        )
        .unwrap();
        enable_codex_hooks_feature(&config).unwrap();
        let body = std::fs::read_to_string(&config).unwrap();
        let features_pos = body.find("[features]").unwrap();
        let unrelated_pos = body.find("[unrelated]").unwrap();
        let hooks_pos = body.find("hooks = true").unwrap();
        assert!(features_pos < hooks_pos && hooks_pos < unrelated_pos);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn enable_codex_hooks_feature_migrates_deprecated_flag() {
        let dir = tmpdir("codex_features_migrate");
        let config = dir.join("config.toml");
        std::fs::write(
            &config,
            "[features]\ncodex_hooks = true\nother_flag = true\n\n[unrelated]\nx = 1\n",
        )
        .unwrap();
        enable_codex_hooks_feature(&config).unwrap();
        let body = std::fs::read_to_string(&config).unwrap();
        assert!(body.contains("hooks = true"));
        assert!(body.contains("other_flag = true"));
        assert!(!body.contains("codex_hooks"));
        let hooks_pos = body.find("hooks = true").unwrap();
        let unrelated_pos = body.find("[unrelated]").unwrap();
        assert!(hooks_pos < unrelated_pos);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn migrate_codex_hooks_feature_does_not_create_config() {
        let dir = tmpdir("codex_features_migrate_no_config");
        let config = dir.join("config.toml");
        migrate_codex_hooks_feature(&config).unwrap();
        assert!(!config.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn migrate_codex_hooks_feature_preserves_deprecated_value() {
        let dir = tmpdir("codex_features_migrate_only");
        let config = dir.join("config.toml");
        std::fs::write(
            &config,
            "[features]\ncodex_hooks = false\nother_flag = true\n\n[unrelated]\nx = 1\n",
        )
        .unwrap();
        migrate_codex_hooks_feature(&config).unwrap();
        let body = std::fs::read_to_string(&config).unwrap();
        assert!(body.contains("hooks = false"));
        assert!(body.contains("other_flag = true"));
        assert!(!body.contains("codex_hooks"));
        let hooks_pos = body.find("hooks = false").unwrap();
        let unrelated_pos = body.find("[unrelated]").unwrap();
        assert!(hooks_pos < unrelated_pos);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn migrate_codex_hooks_feature_prefers_existing_hooks_value() {
        let dir = tmpdir("codex_features_migrate_existing_hooks");
        let config = dir.join("config.toml");
        std::fs::write(
            &config,
            "[features]\nhooks = false\ncodex_hooks = true\nother_flag = true\n",
        )
        .unwrap();
        migrate_codex_hooks_feature(&config).unwrap();
        let body = std::fs::read_to_string(&config).unwrap();
        assert!(body.contains("hooks = false"));
        assert!(!body.contains("hooks = true"));
        assert!(!body.contains("codex_hooks"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn enable_codex_hooks_feature_replaces_disabled_hooks_flag() {
        let dir = tmpdir("codex_features_disabled");
        let config = dir.join("config.toml");
        std::fs::write(&config, "[features]\nhooks = false\ncodex_hooks = true\n").unwrap();
        enable_codex_hooks_feature(&config).unwrap();
        let body = std::fs::read_to_string(&config).unwrap();
        assert!(body.contains("hooks = true"));
        assert!(!body.contains("hooks = false"));
        assert!(!body.contains("codex_hooks"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn remove_hook_from_opencode_removes_instruction() {
        let base = std::env::temp_dir().join("vstack_test_opencode");
        let _ = std::fs::create_dir_all(&base);
        let config_path = base.join("opencode.json");
        let instruction_path = base
            .join(".opencode")
            .join("instructions")
            .join("vstack-hook-block-bare-cd.md");
        std::fs::create_dir_all(instruction_path.parent().unwrap()).unwrap();
        std::fs::write(&instruction_path, "# Safety").unwrap();

        let content = r#"{
  "$schema": "https://opencode.ai/config.json",
  "instructions": [
    ".opencode/instructions/vstack-hook-block-bare-cd.md"
  ],
  "permission": {
    "bash": {
      "*": "ask"
    }
  }
}"#;
        std::fs::write(&config_path, content).unwrap();

        remove_hook_from_opencode_json_at_path(
            &config_path,
            &instruction_path,
            ".opencode/instructions/vstack-hook-block-bare-cd.md",
            "block-bare-cd",
        )
        .unwrap();

        let result = std::fs::read_to_string(&config_path).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();

        // instructions and permission should be gone
        assert!(
            parsed.get("instructions").is_none(),
            "instructions should be removed, got: {result}"
        );
        assert!(
            parsed.get("permission").is_none(),
            "permission should be removed, got: {result}"
        );
        assert!(
            !instruction_path.exists(),
            "instruction file should be removed"
        );

        // Cleanup
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn remove_hook_from_opencode_preserves_unrelated_permissions() {
        let base = std::env::temp_dir().join("vstack_test_opencode_permissions");
        let _ = std::fs::create_dir_all(&base);
        let config_path = base.join("opencode.json");
        let instruction_path = base.join("instructions").join("vstack-hook-review-bash.md");
        std::fs::create_dir_all(instruction_path.parent().unwrap()).unwrap();
        std::fs::write(&instruction_path, "# Safety").unwrap();

        let content = r#"{
  "$schema": "https://opencode.ai/config.json",
  "instructions": [
    "instructions/vstack-hook-review-bash.md"
  ],
  "permission": {
    "edit": "deny",
    "bash": {
      "*": "ask"
    }
  }
}"#;
        std::fs::write(&config_path, content).unwrap();

        remove_hook_from_opencode_json_at_path(
            &config_path,
            &instruction_path,
            "instructions/vstack-hook-review-bash.md",
            "review-bash",
        )
        .unwrap();

        let result = std::fs::read_to_string(&config_path).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();

        assert_eq!(
            parsed.get("permission").and_then(|p| p.get("edit")),
            Some(&serde_json::Value::String("deny".into()))
        );
        assert!(
            parsed
                .get("permission")
                .and_then(|p| p.get("bash"))
                .is_none(),
            "vstack-added bash permission should be removed, got: {result}"
        );

        let _ = std::fs::remove_dir_all(&base);
    }
}
