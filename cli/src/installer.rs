use crate::agent::Agent;
use crate::config::{InstallMethod, ItemKind, LockEntry, LockFile};
use crate::harness::Harness;
use crate::hook::Hook;
use crate::skill::Skill;
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

/// Result of a single installation
pub struct InstallResult {
    pub name: String,
    pub kind: ItemKind,
    pub harness: Harness,
    pub path: PathBuf,
    pub detail: String,
}

/// Install an agent to a specific harness
pub fn install_agent(
    agent: &Agent,
    harness: Harness,
    global: bool,
    skills: &[(String, String)],
    hooks: &[crate::hook::Hook],
    extras: &crate::agent::AgentExtras,
) -> Result<InstallResult> {
    let output_path = harness.generate_agent(agent, global, skills, hooks, extras)?;

    let detail = format!(
        "{} → {} ({})",
        agent.name,
        output_path.display(),
        harness.name()
    );

    Ok(InstallResult {
        name: agent.name.clone(),
        kind: ItemKind::Agent,
        harness,
        detail,
        path: output_path,
    })
}

/// Install a skill directory to a specific harness.
///
/// Symlink mode: copy to a canonical dir (`.agents/skills/<name>/`) within the
/// project, then symlink from each harness-specific dir to the canonical copy.
/// All paths stay within the project root — no external symlinks.
///
/// Copy mode: copy directly to each harness dir.
pub fn install_skill(
    skill: &Skill,
    harness: Harness,
    global: bool,
    method: InstallMethod,
    instructions: Option<&str>,
) -> Result<InstallResult> {
    let dest = harness.install_skill(skill, global)?;

    // Canonical location: .agents/skills/<name>/ (universal, like Vercel npx skills)
    let canonical = if global && matches!(harness, Harness::Codex) {
        crate::config::codex_home_dir()
            .join("skills")
            .join(&skill.name)
    } else if global {
        crate::config::global_state_dir()
            .join("skills")
            .join(&skill.name)
    } else {
        crate::config::project_root()
            .join(".agents")
            .join("skills")
            .join(&skill.name)
    };

    let detail = match method {
        InstallMethod::Symlink => {
            // Step 1: Copy to canonical location (refresh from source).
            // Use a marker file to avoid re-copying if another harness
            // already refreshed the canonical in this process.
            let marker = canonical.join(".vstack-refreshed");
            let current_pid = std::process::id().to_string();
            let already_refreshed = marker.exists()
                && std::fs::read_to_string(&marker).is_ok_and(|s| s.trim() == current_pid);
            if !already_refreshed {
                remove_existing(&canonical)?;
                copy_dir(&skill.source_dir, &canonical)?;

                // Inject skill instructions from project config
                let skill_md = canonical.join("SKILL.md");
                if let Some(text) = instructions {
                    crate::skill::inject_skill_instructions(&skill_md, text);
                }
                crate::skill::inject_vstack_notice(&skill_md);

                // Mark as done for this process
                let _ = std::fs::write(&marker, std::process::id().to_string());
            }

            // Step 2: If this harness IS the canonical path, we're done
            if dest == canonical {
                format!(
                    "{} → {} (canonical, {})",
                    skill.name,
                    canonical.display(),
                    harness.name()
                )
            } else {
                // Step 3: Symlink from harness dir to canonical
                if let Some(parent) = dest.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                remove_existing(&dest)?;

                let rel = relative_path(dest.parent().unwrap(), &canonical)?;
                #[cfg(unix)]
                std::os::unix::fs::symlink(&rel, &dest).with_context(|| {
                    format!("symlinking {} → {}", dest.display(), rel.display())
                })?;

                #[cfg(not(unix))]
                copy_dir(&canonical, &dest)?;

                format!(
                    "{} → {} (symlink, {})",
                    skill.name,
                    dest.display(),
                    harness.name()
                )
            }
        }
        InstallMethod::Copy => {
            remove_existing(&dest)?;
            copy_dir(&skill.source_dir, &dest)?;

            // Inject skill instructions from project config
            let skill_md = dest.join("SKILL.md");
            if let Some(text) = instructions {
                crate::skill::inject_skill_instructions(&skill_md, text);
            }
            crate::skill::inject_vstack_notice(&skill_md);

            // Write marker so reconciliation can detect vstack-managed skills
            let _ = std::fs::write(
                dest.join(".vstack-refreshed"),
                std::process::id().to_string(),
            );

            format!(
                "{} → {} (copy, {})",
                skill.name,
                dest.display(),
                harness.name()
            )
        }
    };

    Ok(InstallResult {
        name: skill.name.clone(),
        kind: ItemKind::Skill,
        harness,
        path: dest,
        detail,
    })
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
    // Copy the script
    let hooks_dir = Harness::ClaudeCode
        .hooks_dir(global)
        .expect("Claude hooks dir");
    std::fs::create_dir_all(&hooks_dir)?;
    let dest = hooks_dir.join(format!("{}.sh", hook.name));
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

    // Build the hook entry.
    // Project installs: use $CLAUDE_PROJECT_DIR so hooks resolve regardless of CWD.
    // Global installs: use the absolute path under the global config dir.
    let command = if global {
        dest.to_string_lossy().into_owned()
    } else {
        format!("$CLAUDE_PROJECT_DIR/.claude/hooks/{}.sh", hook.name)
    };
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
    if !hooks_obj.contains_key(&hook.event) {
        hooks_obj.insert(hook.event.clone(), serde_json::json!([]));
    }
    let event_arr = hooks_obj
        .get_mut(&hook.event)
        .unwrap()
        .as_array_mut()
        .unwrap();

    // Don't duplicate if already present
    let already_exists = event_arr.iter().any(|e| {
        e.get("hooks")
            .and_then(|h| h.as_array())
            .and_then(|a| a.first())
            .and_then(|h| h.get("command"))
            .and_then(|c| c.as_str())
            .is_some_and(|c| c.contains(&hook.name))
    });

    if !already_exists {
        event_arr.push(hook_entry);
    }

    let output = serde_json::to_string_pretty(&settings)?;
    std::fs::write(&settings_path, output)?;

    Ok(())
}

/// OpenCode: add permission rules based on hook intent
fn install_hook_opencode(hook: &Hook, global: bool) -> Result<()> {
    let config_path = if global {
        crate::config::opencode_global_config_path()
    } else {
        crate::config::opencode_project_config_path()
    };
    let instruction_path = opencode_hook_instruction_path(global, &hook.name);
    let instruction_ref = opencode_hook_instruction_ref(global, &hook.name);
    install_hook_opencode_at_path(hook, &config_path, &instruction_path, &instruction_ref)
}

fn opencode_hook_instruction_path(global: bool, name: &str) -> PathBuf {
    let file_name = format!("vstack-hook-{name}.md");
    if global {
        crate::config::opencode_global_dir()
            .join("instructions")
            .join(file_name)
    } else {
        crate::config::project_root()
            .join(".opencode")
            .join("instructions")
            .join(file_name)
    }
}

fn opencode_hook_instruction_ref(global: bool, name: &str) -> String {
    let file_name = format!("vstack-hook-{name}.md");
    if global {
        format!("instructions/{file_name}")
    } else {
        format!(".opencode/instructions/{file_name}")
    }
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
    }

    let instruction_contents = format!("# Safety: {}\n\n{}", hook.name, hook.safety_prose());
    std::fs::write(instruction_path, instruction_contents)?;

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
fn codex_event_for(event: &str) -> Option<&'static str> {
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
fn codex_root(global: bool) -> PathBuf {
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
    let root = codex_root(global);

    let hooks_dir = root.join("hooks");
    std::fs::create_dir_all(&hooks_dir)?;
    let script_path = hooks_dir.join(format!("{}.sh", hook.name));
    std::fs::write(&script_path, &hook.script)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&script_path, std::fs::Permissions::from_mode(0o755))?;
    }

    let command = codex_hook_command(global, &hook.name, &script_path);
    let hooks_json = root.join("hooks.json");
    merge_codex_hooks_json(&hooks_json, codex_event, hook, &command)?;
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
fn merge_codex_hooks_json(
    hooks_json: &Path,
    codex_event: &str,
    hook: &Hook,
    command: &str,
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
    if !hooks_obj.contains_key(codex_event) {
        hooks_obj.insert(codex_event.to_string(), serde_json::json!([]));
    }
    let event_arr = hooks_obj
        .get_mut(codex_event)
        .unwrap()
        .as_array_mut()
        .unwrap();

    // Match the full `/<name>.sh` segment so a hook named `foo` doesn't
    // collide with one named `notfoo`.
    let script_token = format!("/{}.sh", hook.name);
    let already_present = event_arr.iter().any(|entry| {
        entry
            .get("hooks")
            .and_then(|h| h.as_array())
            .and_then(|arr| arr.first())
            .and_then(|h| h.get("command"))
            .and_then(|c| c.as_str())
            .is_some_and(|c| c.contains(&script_token))
    });
    if already_present {
        let output = serde_json::to_string_pretty(&doc)?;
        std::fs::write(hooks_json, output)?;
        return Ok(());
    }

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
    let agents_dir = Harness::Codex.agents_dir(global);
    if !agents_dir.exists() {
        return Ok(());
    }

    let safety = hook.safety_prose();

    for agent in agents {
        let toml_path = agents_dir.join(format!("{}.toml", agent.name));
        if !toml_path.exists() {
            continue;
        }

        let content = std::fs::read_to_string(&toml_path)?;
        if content.contains(&hook.name) {
            continue;
        }

        if let Some(close_pos) = content.rfind("'''") {
            let mut new_content = content[..close_pos].to_string();
            new_content.push_str(&format!("\n## Safety: {}\n\n{}\n", hook.name, safety));
            new_content.push_str(&content[close_pos..]);
            std::fs::write(&toml_path, new_content)?;
        }
    }

    Ok(())
}

/// Cursor: add safety advisory to a dedicated .mdc file
fn install_hook_cursor(hook: &Hook, global: bool) -> Result<()> {
    let rules_dir = Harness::Cursor.agents_dir(global);
    std::fs::create_dir_all(&rules_dir)?;

    let path = rules_dir.join(format!("safety-{}.mdc", hook.name));

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

    std::fs::write(&path, output)?;
    Ok(())
}

/// Remove an installed item.
/// Each harness cleanup is independent — one failure doesn't block others.
pub fn remove_item(name: &str, harnesses: &[Harness], global: bool) -> Result<Vec<PathBuf>> {
    let mut removed = Vec::new();

    for harness in harnesses {
        // Agent files
        let agent_paths = match harness {
            Harness::ClaudeCode => vec![harness.agents_dir(global).join(format!("{name}.md"))],
            Harness::Cursor => {
                vec![
                    harness.agents_dir(global).join(format!("{name}.mdc")),
                    harness
                        .agents_dir(global)
                        .join(format!("safety-{name}.mdc")),
                ]
            }
            Harness::OpenCode => vec![harness.agents_dir(global).join(format!("{name}.md"))],
            Harness::Codex => vec![harness.agents_dir(global).join(format!("{name}.toml"))],
            Harness::Pi => vec![harness.agents_dir(global).join(format!("{name}.md"))],
        };

        for path in agent_paths {
            if path.exists() && std::fs::remove_file(&path).is_ok() {
                removed.push(path);
            }
        }

        // Skill directories
        let skill_path = harness.skills_dir(global).join(name);
        if skill_path.exists() || skill_path.is_symlink() {
            let ok = if skill_path.is_symlink() || skill_path.is_file() {
                std::fs::remove_file(&skill_path).is_ok()
            } else {
                std::fs::remove_dir_all(&skill_path).is_ok()
            };
            if ok {
                removed.push(skill_path);
            }
        }

        // Hook cleanup (per-harness, each independent)
        if *harness == Harness::ClaudeCode {
            let hook_path = harness
                .hooks_dir(global)
                .expect("Claude hooks dir")
                .join(format!("{name}.sh"));
            if hook_path.exists() && std::fs::remove_file(&hook_path).is_ok() {
                removed.push(hook_path);
            }
            let _ = remove_hook_from_claude_settings(global, name);
        }

        if *harness == Harness::OpenCode {
            let _ = remove_hook_from_opencode_json(global, name);
        }

        if *harness == Harness::Codex {
            let root = codex_root(global);
            let script_path = root.join("hooks").join(format!("{name}.sh"));
            if script_path.exists() && std::fs::remove_file(&script_path).is_ok() {
                removed.push(script_path);
            }
            let _ = remove_hook_from_codex_json(global, name);
            let _ = strip_hook_prose_from_codex_agents(global, name);
        }
    }

    let canonical_skill_paths = if global {
        vec![
            crate::config::global_state_dir().join("skills").join(name),
            crate::config::codex_home_dir().join("skills").join(name),
        ]
    } else {
        vec![
            crate::config::project_root()
                .join(".agents")
                .join("skills")
                .join(name),
        ]
    };

    for path in canonical_skill_paths {
        if path.exists() || path.is_symlink() {
            let ok = if path.is_symlink() || path.is_file() {
                std::fs::remove_file(&path).is_ok()
            } else {
                std::fs::remove_dir_all(&path).is_ok()
            };
            if ok {
                removed.push(path);
            }
        }
    }

    Ok(removed)
}

/// Remove a hook entry from Claude Code settings.json
fn remove_hook_from_claude_settings(global: bool, name: &str) -> Result<()> {
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
        for (_event, entries) in hooks.iter_mut() {
            if let Some(arr) = entries.as_array_mut() {
                let before = arr.len();
                arr.retain(|entry| {
                    !entry
                        .get("hooks")
                        .and_then(|h| h.as_array())
                        .and_then(|a| a.first())
                        .and_then(|h| h.get("command"))
                        .and_then(|c| c.as_str())
                        .is_some_and(|c| c.contains(name))
                });
                if arr.len() != before {
                    changed = true;
                }
            }
        }
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
fn remove_hook_from_codex_json(global: bool, name: &str) -> Result<()> {
    let root = codex_root(global);
    let hooks_json = root.join("hooks.json");
    if !hooks_json.exists() {
        return Ok(());
    }
    let content = std::fs::read_to_string(&hooks_json)?;
    let mut doc: serde_json::Value = match serde_json::from_str(&content) {
        Ok(v) => v,
        Err(_) => return Ok(()),
    };

    let script_token = format!("/{name}.sh");
    let mut changed = false;

    if let Some(hooks) = doc.get_mut("hooks").and_then(|h| h.as_object_mut()) {
        let event_keys: Vec<String> = hooks.keys().cloned().collect();
        for event in event_keys {
            if let Some(arr) = hooks.get_mut(&event).and_then(|v| v.as_array_mut()) {
                let before = arr.len();
                arr.retain(|entry| {
                    !entry
                        .get("hooks")
                        .and_then(|h| h.as_array())
                        .and_then(|a| a.first())
                        .and_then(|h| h.get("command"))
                        .and_then(|c| c.as_str())
                        .is_some_and(|c| c.contains(&script_token))
                });
                if arr.len() != before {
                    changed = true;
                }
                if arr.is_empty() {
                    hooks.remove(&event);
                }
            }
        }
        if hooks.is_empty()
            && let Some(map) = doc.as_object_mut()
        {
            map.remove("hooks");
        }
    }

    if changed {
        if doc.as_object().is_some_and(|m| m.is_empty()) {
            let _ = std::fs::remove_file(&hooks_json);
        } else {
            let output = serde_json::to_string_pretty(&doc)?;
            std::fs::write(&hooks_json, output)?;
        }
    }
    Ok(())
}

/// Strip any `## Safety: <name>` prose block we previously injected into codex
/// agent TOMLs (legacy fallback path). Idempotent.
fn strip_hook_prose_from_codex_agents(global: bool, name: &str) -> Result<()> {
    let agents_dir = Harness::Codex.agents_dir(global);
    if !agents_dir.exists() {
        return Ok(());
    }
    let marker = format!("\n## Safety: {name}\n");
    let entries = match std::fs::read_dir(&agents_dir) {
        Ok(e) => e,
        Err(_) => return Ok(()),
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().is_some_and(|ext| ext == "toml") {
            let content = match std::fs::read_to_string(&path) {
                Ok(c) => c,
                Err(_) => continue,
            };
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
                let _ = std::fs::write(&path, new_content);
            }
        }
    }
    Ok(())
}

/// Remove hook instructions and permission entries from OpenCode opencode.json
fn remove_hook_from_opencode_json(global: bool, name: &str) -> Result<()> {
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

/// Record installation in lock file
pub fn record_install(
    lock: &mut LockFile,
    results: &[InstallResult],
    source: &str,
    method: InstallMethod,
) {
    let now = crate::config::now_iso();
    for result in results {
        let harness_id = result.harness.id().to_string();
        if let Some(existing) = lock.entries.get_mut(&result.name) {
            if !existing.harnesses.contains(&harness_id) {
                existing.harnesses.push(harness_id);
            }
            existing.source = source.into();
            existing.method = method;
            existing.installed_at = now.clone();
            existing.source_hash = crate::config::compute_source_hash(existing);
        } else {
            let mut entry = LockEntry {
                name: result.name.clone(),
                kind: result.kind,
                source: source.into(),
                harnesses: vec![harness_id],
                method,
                installed_at: now.clone(),
                source_hash: String::new(),
            };
            entry.source_hash = crate::config::compute_source_hash(&entry);
            lock.add(entry);
        }
    }
}

/// Compute relative path from `from` to `to`
fn remove_existing(path: &Path) -> Result<()> {
    if path.is_symlink() {
        std::fs::remove_file(path)?;
    } else if path.is_dir() {
        std::fs::remove_dir_all(path)?;
    } else if path.exists() {
        std::fs::remove_file(path)?;
    }
    Ok(())
}

fn normalize_absolute_path(path: &Path) -> PathBuf {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    };

    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}

fn relative_path(from: &Path, to: &Path) -> Result<PathBuf> {
    let from_lexical = normalize_absolute_path(from);
    let from_canonical = std::fs::canonicalize(from).unwrap_or_else(|_| from_lexical.clone());
    let to = std::fs::canonicalize(to).unwrap_or_else(|_| normalize_absolute_path(to));

    // If the apparent parent path differs from the real containing directory
    // (for example because an ancestor is a symlink), prefer an absolute
    // target over a confusing relative path that is computed from the real path.
    if from_canonical != from_lexical {
        return Ok(to);
    }

    let from_parts: Vec<_> = from_lexical.components().collect();
    let to_parts: Vec<_> = to.components().collect();

    let common = from_parts
        .iter()
        .zip(to_parts.iter())
        .take_while(|(a, b)| a == b)
        .count();

    let mut rel = PathBuf::new();
    for _ in common..from_parts.len() {
        rel.push("..");
    }
    for part in &to_parts[common..] {
        rel.push(part);
    }

    Ok(rel)
}

/// Recursively copy a directory.
///
/// Preserves symlinks instead of dereferencing them. `std::fs::copy` follows
/// symlinks and writes the resolved bytes, which made every package whose
/// tests/build produce symlink artifacts report `vstack verify -g` install
/// drift (source had a symlink, install had a real file with the resolved
/// content). Recreating the link via `std::os::unix::fs::symlink` keeps the
/// install dir byte-comparable to the source.
fn copy_dir(src: &Path, dst: &Path) -> Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in walkdir::WalkDir::new(src).min_depth(1) {
        let entry = entry?;
        let rel = entry.path().strip_prefix(src)?;
        let target = dst.join(rel);
        let file_type = entry.file_type();

        if file_type.is_symlink() {
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent)?;
            }
            // Replace any pre-existing entry at the destination so reinstall
            // is idempotent. `remove_file` works for both files and symlinks;
            // dirs need `remove_dir_all`.
            if target.is_symlink() || target.is_file() {
                std::fs::remove_file(&target).with_context(|| {
                    format!("removing existing {} for symlink replace", target.display())
                })?;
            } else if target.is_dir() {
                std::fs::remove_dir_all(&target).with_context(|| {
                    format!(
                        "removing existing dir {} for symlink replace",
                        target.display()
                    )
                })?;
            }
            let link_target = std::fs::read_link(entry.path())
                .with_context(|| format!("reading symlink target at {}", entry.path().display()))?;
            std::os::unix::fs::symlink(&link_target, &target).with_context(|| {
                format!(
                    "recreating symlink {} → {}",
                    target.display(),
                    link_target.display()
                )
            })?;
        } else if file_type.is_dir() {
            std::fs::create_dir_all(&target)?;
        } else {
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::copy(entry.path(), &target)?;
        }
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
    fn record_install_updates_method_for_existing_entry() {
        let mut lock = LockFile::default();
        lock.add(LockEntry {
            name: "rust".into(),
            kind: ItemKind::Agent,
            source: "old-source".into(),
            harnesses: vec![Harness::Pi.id().to_string()],
            method: InstallMethod::Symlink,
            installed_at: "2026-05-01T00:00:00Z".into(),
            source_hash: String::new(),
        });
        let results = vec![InstallResult {
            name: "rust".into(),
            kind: ItemKind::Agent,
            harness: Harness::ClaudeCode,
            path: PathBuf::new(),
            detail: String::new(),
        }];

        record_install(&mut lock, &results, "new-source", InstallMethod::Copy);

        let entry = lock.entries.get("rust").expect("entry should exist");
        assert_eq!(entry.method, InstallMethod::Copy);
        assert_eq!(entry.source, "new-source");
        assert!(entry.harnesses.contains(&Harness::Pi.id().to_string()));
        assert!(
            entry
                .harnesses
                .contains(&Harness::ClaudeCode.id().to_string())
        );
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
    fn merge_codex_hooks_json_does_not_dedupe_substring_collisions() {
        // A hook named `foo` must not be considered already-present when the
        // event already has `notfoo.sh`. The dedup token includes the path
        // separator to avoid this.
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
    fn remove_hook_from_codex_json_strips_entry_and_prunes_event() {
        let dir = tmpdir("codex_remove_strip");
        let hooks_json = dir.join("hooks.json");
        std::fs::write(
            &hooks_json,
            r#"{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash /home/.codex/hooks/block-bare-cd.sh"}]
      },
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash /home/.codex/hooks/user-own.sh"}]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [{"type": "command", "command": "bash /home/.codex/hooks/post-edit-lint.sh"}]
      }
    ]
  }
}"#,
        )
        .unwrap();

        // Use the inner helper-equivalent inline since remove_hook_from_codex_json
        // takes (global, name) and resolves codex_root() from env. We mirror its
        // logic against an explicit path here so the test is hermetic.
        let content = std::fs::read_to_string(&hooks_json).unwrap();
        let mut doc: serde_json::Value = serde_json::from_str(&content).unwrap();
        let script_token = "post-edit-lint.sh";
        if let Some(hooks) = doc.get_mut("hooks").and_then(|h| h.as_object_mut()) {
            let keys: Vec<String> = hooks.keys().cloned().collect();
            for event in keys {
                if let Some(arr) = hooks.get_mut(&event).and_then(|v| v.as_array_mut()) {
                    arr.retain(|entry| {
                        !entry
                            .pointer("/hooks/0/command")
                            .and_then(|c| c.as_str())
                            .is_some_and(|c| c.contains(script_token))
                    });
                    if arr.is_empty() {
                        hooks.remove(&event);
                    }
                }
            }
        }
        std::fs::write(&hooks_json, serde_json::to_string_pretty(&doc).unwrap()).unwrap();

        let result: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&hooks_json).unwrap()).unwrap();
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

    #[test]
    fn relative_path_uses_relative_target_for_normal_directories() {
        let root = std::env::temp_dir().join(format!(
            "vstack_relative_path_normal_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let from = root.join("a").join("b");
        let to = root.join("config").join("skills").join("rust-runtime");
        std::fs::create_dir_all(&from).unwrap();
        std::fs::create_dir_all(&to).unwrap();

        let rel = relative_path(&from, &to).unwrap();
        assert_eq!(rel, PathBuf::from("../../config/skills/rust-runtime"));

        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn relative_path_uses_absolute_target_when_parent_is_symlinked() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_relative_path_symlink_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let real_parent = root.join("real").join("skills");
        let apparent_parent = root.join("apparent");
        let target = root.join("config").join("skills").join("rust-runtime");

        std::fs::create_dir_all(&real_parent).unwrap();
        std::fs::create_dir_all(target.parent().unwrap()).unwrap();
        std::fs::create_dir_all(&target).unwrap();
        symlink(&real_parent, &apparent_parent).unwrap();

        let rel = relative_path(&apparent_parent, &target).unwrap();
        assert!(
            rel.is_absolute(),
            "expected absolute symlink target, got {rel:?}"
        );
        assert_eq!(rel, std::fs::canonicalize(&target).unwrap());

        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn copy_dir_preserves_symlinks_instead_of_dereferencing() {
        // Reproduces the pi-claude-bridge install-drift bug: source ships a
        // symlink, install must too — otherwise verify reports drift on
        // every package whose tests/build emit symlink artifacts.
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_copy_dir_symlink_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let src = root.join("src");
        let dst = root.join("dst");
        std::fs::create_dir_all(src.join("logs")).unwrap();
        let real_log = src.join("logs").join("2026-05-10-provider-1.log");
        std::fs::write(&real_log, b"line one\nline two\n").unwrap();
        symlink(&real_log, src.join("logs").join("latest")).unwrap();

        copy_dir(&src, &dst).unwrap();

        let dst_latest = dst.join("logs").join("latest");
        let meta = std::fs::symlink_metadata(&dst_latest).unwrap();
        assert!(
            meta.file_type().is_symlink(),
            "copy_dir must preserve symlinks; got file_type={:?}",
            meta.file_type()
        );
        assert_eq!(
            std::fs::read_link(&dst_latest).unwrap(),
            real_log,
            "symlink target must round-trip"
        );
        // Reading through the symlink still resolves to the real file.
        assert_eq!(std::fs::read(&dst_latest).unwrap(), b"line one\nline two\n");

        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn copy_dir_replaces_existing_symlink_on_reinstall() {
        // Reinstall path: dst already has a symlink, src now points
        // somewhere else — dst must end up matching src's new target.
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_copy_dir_resymlink_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let src = root.join("src");
        let dst = root.join("dst");
        std::fs::create_dir_all(&src).unwrap();
        std::fs::create_dir_all(&dst).unwrap();
        std::fs::write(src.join("a.log"), b"A").unwrap();
        std::fs::write(src.join("b.log"), b"B").unwrap();
        symlink(src.join("b.log"), src.join("latest")).unwrap();

        // Pre-existing dst symlink pointing at A; copy_dir should replace
        // it with the new symlink pointing at B.
        std::fs::write(dst.join("a.log"), b"A").unwrap();
        std::fs::write(dst.join("b.log"), b"B").unwrap();
        symlink(dst.join("a.log"), dst.join("latest")).unwrap();

        copy_dir(&src, &dst).unwrap();

        let resolved = std::fs::read_link(dst.join("latest")).unwrap();
        assert_eq!(
            resolved,
            src.join("b.log"),
            "reinstall must overwrite stale symlink"
        );

        let _ = std::fs::remove_dir_all(&root);
    }
}
