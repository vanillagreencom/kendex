use crate::hook::Hook;
use crate::path_safety::validate_item_name;
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

use super::checked_child_path;

/// OpenCode: add permission rules based on hook intent
pub(super) fn install_hook_opencode(hook: &Hook, global: bool) -> Result<()> {
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

/// Whether opencode.json still references this hook's instruction file — an
/// unreferenced file loads nowhere, so nothing is advisory.
pub(crate) fn opencode_hook_instruction_registered(global: bool, name: &str) -> bool {
    let config_path = if global {
        crate::config::opencode_global_config_path()
    } else {
        crate::config::opencode_project_config_path()
    };
    let Ok(content) = std::fs::read_to_string(&config_path) else {
        return false;
    };
    let Ok(config) = serde_json::from_str::<serde_json::Value>(&content) else {
        return false;
    };
    let reference = opencode_hook_instruction_ref(global, name);
    config
        .get("instructions")
        .and_then(|value| value.as_array())
        .is_some_and(|instructions| {
            instructions
                .iter()
                .any(|entry| entry.as_str() == Some(reference.as_str()))
        })
}

pub(crate) fn opencode_hook_instruction_contents(hook: &Hook) -> String {
    format!(
        "{}\n\n# Safety: {}\n\n{}",
        super::contract::ADVISORY_BANNER,
        hook.name,
        hook.safety_prose()
    )
}

pub(super) fn install_hook_opencode_at_path(
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

    let output = serialize_opencode_config(&config)?;
    std::fs::write(config_path, output)?;

    Ok(())
}

/// Remove hook instructions and permission entries from OpenCode opencode.json
pub(super) fn remove_hook_from_opencode_json(global: bool, name: &str) -> Result<()> {
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

pub(super) fn remove_hook_from_opencode_json_at_path(
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

    let remove_instruction = instruction_path.exists();

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
        let output = serialize_opencode_config(&config)?;
        std::fs::write(config_path, output)?;
    }
    if remove_instruction {
        let _ = std::fs::remove_file(instruction_path);
    }
    Ok(())
}

fn serialize_opencode_config(config: &serde_json::Value) -> Result<String> {
    let mut output = serde_json::to_string_pretty(config)?;
    output.push('\n');
    Ok(output)
}
