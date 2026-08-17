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

pub(crate) fn opencode_hook_instruction_contents(hook: &Hook) -> String {
    format!(
        "{}\n\n# Safety: {}\n\n{}",
        super::contract::ADVISORY_BANNER,
        hook.name,
        hook.safety_prose()
    )
}

/// `opencode.json` read against the shape both writers here depend on — see
/// [`crate::json_config`]. The refusal is attached once, so an unreadable
/// config reads the same whether it was hit by an install or a removal.
fn read_opencode_config(path: &Path) -> Result<Option<serde_json::Value>> {
    crate::json_config::read(path, &crate::json_config::OPENCODE_CONFIG)
        .context(crate::json_config::REFUSE_UNPARSEABLE_CONFIG)
}

/// Does `opencode.json` still point OpenCode at this hook's instruction file?
///
/// The file on disk is half the install. OpenCode loads what the
/// `instructions` array names, so an entry a user (or an older vstack) removed
/// leaves the file sitting there and the hook inert — the same "artifact
/// present, harness never runs it" state the Claude and Codex registration
/// checks exist to catch, and the one this harness answered `Registered` for.
///
/// Read from the array the installer writes, through the reader both writers
/// go through, and compared by the file each entry RESOLVES to — so a
/// hand-spelled but still-correct path counts, and a path naming some other
/// file does not.
pub(crate) fn opencode_hook_registration(global: bool, name: &str) -> super::HookRegistration {
    let config_path = if global {
        crate::config::opencode_global_config_path()
    } else {
        crate::config::opencode_project_config_path()
    };
    let config = match read_opencode_config(&config_path) {
        Ok(Some(config)) => config,
        Ok(None) => return super::HookRegistration::Absent,
        Err(err) => return super::HookRegistration::Unreadable(format!("{err:#}")),
    };
    // Entries are relative to the config file's own directory.
    let base = config_path.parent().unwrap_or(Path::new("."));
    let instruction_path = opencode_hook_instruction_path(global, name);
    let target = crate::config::normalize_path_lexical(&instruction_path);
    let target_resolved = std::fs::canonicalize(&instruction_path).ok();
    let registered = config
        .get("instructions")
        .and_then(|instructions| instructions.as_array())
        .into_iter()
        .flatten()
        .filter_map(|entry| entry.as_str())
        .any(|entry| {
            let path = Path::new(entry);
            let absolute = if path.is_absolute() {
                path.to_path_buf()
            } else {
                base.join(path)
            };
            if crate::config::normalize_path_lexical(&absolute) == target {
                return true;
            }
            match (&target_resolved, std::fs::canonicalize(&absolute).ok()) {
                (Some(target), Some(entry)) => &entry == target,
                _ => false,
            }
        });
    if registered {
        super::HookRegistration::Registered
    } else {
        super::HookRegistration::Absent
    }
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

    let mut config = read_opencode_config(config_path)?
        .unwrap_or_else(|| serde_json::json!({ "$schema": "https://opencode.ai/config.json" }));

    let map = config
        .as_object_mut()
        .expect("validated by json_config: the document is an object");

    // OpenCode doesn't have hooks — convert to permission rules and instructions.
    // Both containers are CREATED only when their key is absent: a value of
    // the wrong shape made the read unreadable above, so nothing here
    // replaces a value the user put there.
    let perms = map
        .entry("permission")
        .or_insert_with(|| serde_json::json!({}))
        .as_object_mut()
        .expect("validated by json_config: `permission` is an object");

    // Add safety-relevant permission restrictions based on hook type
    if hook.event == "PreToolUse" && hook.matcher.as_deref() == Some("Bash") {
        // For bash hooks: set bash permission to "ask" (require confirmation)
        if !perms.contains_key("bash") {
            perms.insert("bash".into(), serde_json::json!({ "*": "ask" }));
        }
    }

    // OpenCode instructions are file paths, so write a dedicated file and reference it.
    let instructions = map
        .entry("instructions")
        .or_insert_with(|| serde_json::json!([]))
        .as_array_mut()
        .expect("validated by json_config: `instructions` is an array");

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
    let Some(mut config) = read_opencode_config(config_path)? else {
        let _ = std::fs::remove_file(instruction_path);
        return Ok(());
    };

    let mut changed = false;

    // Remove the current file-path based format plus the legacy inline prose
    // format. A non-string entry is somebody else's and is retained: it can
    // never be the reference vstack wrote.
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
