use crate::agent::{AgentExtras, AgentRole};
use crate::harness::Harness;
use crate::project_config::ProjectConfig;
use crate::skill::Skill;
use std::path::Path;

/// Map skill names to (name, description) pairs using the available skill list.
/// Falls back to the skill name itself when no matching Skill is found.
pub fn resolve_skill_pairs(names: &[String], available: &[Skill]) -> Vec<(String, String)> {
    names
        .iter()
        .map(|name| {
            let desc = available
                .iter()
                .find(|s| s.name == *name)
                .map(|s| s.description.clone())
                .unwrap_or_else(|| name.clone());
            (name.clone(), desc)
        })
        .collect()
}

/// Return source hooks that are actually installed for a specific harness.
///
/// Source `vstack.toml` hook mappings describe where hooks should attach once
/// installed; they must not cause agent frontmatter to reference hooks absent
/// from the scope lock or from the harness-specific hook install set.
pub fn hooks_installed_for_harness(
    lock: &crate::config::LockFile,
    hooks: &[crate::hook::Hook],
    harness_id: &str,
) -> Vec<crate::hook::Hook> {
    lock.entries
        .iter()
        .filter(|(_, entry)| {
            entry.kind == crate::config::ItemKind::Hook
                && entry.harnesses.iter().any(|h| h == harness_id)
        })
        .filter_map(|(_, entry)| source_hook_for_lock_entry(hooks, entry))
        .filter(|hook| hook.applies_to(harness_id))
        .cloned()
        .collect()
}

/// Return installed Codex fallback hooks from the lock using lock-entry source
/// ownership, harness allowlists, and Codex native-event mapping.
pub(crate) fn installed_codex_fallback_hooks(
    lock: &crate::config::LockFile,
    source_hooks: &[crate::hook::Hook],
) -> Vec<crate::hook::Hook> {
    lock.entries
        .values()
        .filter(|entry| entry.kind == crate::config::ItemKind::Hook)
        .filter(|entry| entry.harnesses.iter().any(|h| h == Harness::Codex.id()))
        .filter_map(|entry| source_hook_for_lock_entry(source_hooks, entry))
        .filter(|hook| hook.applies_to(Harness::Codex.id()))
        .filter(|hook| crate::installer::codex_event_for(&hook.event).is_none())
        .cloned()
        .collect()
}

/// Return the source hook matching a hook lock entry's recorded source.
///
/// Aggregated source discovery can contain same-named hooks from multiple
/// sources. The lock entry source decides which one is authoritative for
/// refresh/prune/reinstall/agent-frontmatter matching.
pub fn source_hook_for_lock_entry<'a>(
    source_hooks: &'a [crate::hook::Hook],
    entry: &crate::config::LockEntry,
) -> Option<&'a crate::hook::Hook> {
    if should_match_entry_source(&entry.source) {
        if let Some(root) = crate::config::resolve_source_path(&entry.source) {
            for hook in source_hooks.iter().filter(|hook| hook.name == entry.name) {
                if hook_path_is_from_source(hook, &root) {
                    return Some(hook);
                }
            }
            return None;
        }
        // A source that exists but did not resolve — a remote whose clone is
        // absent or refused — must not fall through to a same-named hook from
        // a different source: prune judged the entry against that hook's
        // `harnesses:` list and uninstalled the difference, and generated agent
        // frontmatter took its event and matcher.
        if crate::refresh_sources::recorded_source_exists(&entry.source) {
            return None;
        }
    }

    for hook in source_hooks.iter().filter(|hook| hook.name == entry.name) {
        if hook.source_path.as_os_str().is_empty() {
            return Some(hook);
        }
    }

    source_hooks.iter().find(|hook| hook.name == entry.name)
}

fn should_match_entry_source(source: &str) -> bool {
    let path = Path::new(source);
    source == "." || path.is_absolute() || (source.contains('/') && !source.starts_with('.'))
}

fn hook_path_is_from_source(hook: &crate::hook::Hook, source_root: &Path) -> bool {
    let root = source_root
        .canonicalize()
        .unwrap_or_else(|_| source_root.to_path_buf());
    let hook_path = hook
        .source_path
        .canonicalize()
        .unwrap_or_else(|_| hook.source_path.clone());
    hook_path.starts_with(root.join("hooks")) || hook_path.starts_with(root)
}

/// Return hooks from a selected/pre-lock set that apply to an agent on a
/// specific harness.
pub fn matched_selected_hooks_for_agent_harness(
    mapping: &crate::mapping::MappingConfig,
    agent_role: &AgentRole,
    hooks: &[crate::hook::Hook],
    harness_id: &str,
) -> Vec<crate::hook::Hook> {
    let applicable_hooks: Vec<crate::hook::Hook> = hooks
        .iter()
        .filter(|hook| hook.applies_to(harness_id))
        .cloned()
        .collect();
    mapping
        .hooks_for_agent(agent_role, &applicable_hooks)
        .into_iter()
        .cloned()
        .collect()
}

/// Return hooks from the scope lock that apply to an agent on a specific
/// harness.
pub fn matched_installed_hooks_for_agent_harness(
    lock: &crate::config::LockFile,
    hooks: &[crate::hook::Hook],
    mapping: &crate::mapping::MappingConfig,
    agent_role: &AgentRole,
    harness_id: &str,
) -> Vec<crate::hook::Hook> {
    let installed_hooks = hooks_installed_for_harness(lock, hooks, harness_id);
    mapping
        .hooks_for_agent(agent_role, &installed_hooks)
        .into_iter()
        .cloned()
        .collect()
}

/// Read guidance/instructions from an existing agent file on disk.
/// Returns empty extras if the file doesn't exist.
pub fn read_existing_extras(path: &Path, harness: Harness) -> AgentExtras {
    let Ok(content) = std::fs::read_to_string(path) else {
        return Default::default();
    };
    let body = if matches!(harness, Harness::Codex) {
        crate::agent::extract_body_from_codex_toml(&content).unwrap_or(content)
    } else {
        content
    };
    crate::agent::extract_user_sections(&body)
}

/// Build AgentExtras by merging project config values with file-extracted fallbacks.
pub fn build_agent_extras(
    project_config: &ProjectConfig,
    agent_name: &str,
    agent_role: &AgentRole,
    file_extras: Option<&AgentExtras>,
) -> AgentExtras {
    // File-extracted sections come from a previously generated (merged)
    // render; drop the marked shared region (or, for pre-marker files, the
    // configured shared prefix) so it is never merged in twice.
    let file_guidance = file_extras
        .and_then(|e| e.guidance.as_deref())
        .and_then(|text| ProjectConfig::strip_shared_block(project_config.shared_guidance(), text));
    let file_instructions = file_extras
        .and_then(|e| e.instructions.as_deref())
        .and_then(|text| {
            ProjectConfig::strip_shared_block(project_config.shared_instructions(), text)
        });
    let file_color = file_extras.and_then(|e| e.color.as_deref());
    AgentExtras {
        color: project_config
            .color_for(agent_name)
            .or(file_color)
            .map(String::from),
        guidance: ProjectConfig::merge_marked_shared_and_specific(
            project_config.shared_guidance(),
            project_config
                .guidance_for(agent_name)
                .or(file_guidance.as_deref()),
        ),
        instructions: ProjectConfig::merge_marked_shared_and_specific(
            project_config.shared_instructions(),
            project_config
                .instructions_for(agent_name)
                .or(file_instructions.as_deref()),
        ),
        frontmatter: Default::default(),
        frontmatter_by_harness: project_config
            .agent_frontmatter_by_harness
            .iter()
            .filter_map(|(harness, entries)| {
                entries
                    .get(agent_name)
                    .cloned()
                    .map(|overrides| (harness.clone(), overrides))
            })
            .collect(),
        custom_hooks: project_config.custom_hooks_for(agent_name, agent_role),
    }
}

/// Check if a directory looks like a vstack source repo (has 2+ source item dirs).
/// The dot-prefix rejection keeps hidden dirs (.vstack, .agents mirrors) out of
/// CWD walk-up DISCOVERY; callers that already hold an explicit project root
/// should use [`has_vstack_source_content`] instead — a checkout is a source
/// because of what it contains, not what its directory is named.
pub fn is_vstack_source(dir: &Path) -> bool {
    if dir
        .file_name()
        .and_then(|n| n.to_str())
        .is_some_and(|n| n.starts_with('.'))
    {
        return false;
    }
    has_vstack_source_content(dir)
}

/// Compare two paths with symlinks resolved; a path that cannot be
/// canonicalized (e.g. it does not exist) falls back to raw comparison.
pub fn same_path(a: &Path, b: &Path) -> bool {
    let a = a.canonicalize().unwrap_or_else(|_| a.to_path_buf());
    let b = b.canonicalize().unwrap_or_else(|_| b.to_path_buf());
    a == b
}

/// Majority-vote a default source from the project's lock file. Project-local
/// items record the project itself as their source; those self entries must
/// not outvote the canonical source (vstack#1024) unless the project genuinely
/// carries vstack source content. Shared by `add` and `apply` so default
/// source resolution is identical across commands (vstack#1038).
pub fn source_from_project_lock(project_root: &Path) -> Option<String> {
    let lock = crate::config::LockFile::load(&project_root.join(".vstack-lock.json")).ok()?;
    let allow_project_self = has_vstack_source_content(project_root);
    let mut counts = std::collections::BTreeMap::<String, usize>::new();
    for entry in lock.entries.values() {
        if !allow_project_self && same_path(Path::new(&entry.source), project_root) {
            continue;
        }
        *counts.entry(entry.source.clone()).or_default() += 1;
    }
    counts
        .into_iter()
        .max_by(|(a_source, a_count), (b_source, b_count)| {
            a_count.cmp(b_count).then_with(|| b_source.cmp(a_source))
        })
        .map(|(source, _)| source)
}

/// Content-only source check (no directory-name heuristics): a catalog table
/// or 2+ source item dirs.
pub fn has_vstack_source_content(dir: &Path) -> bool {
    if crate::catalog::has_catalog_table(dir) {
        return true;
    }
    let count = [
        dir.join("agents").is_dir(),
        dir.join("skills").is_dir(),
        dir.join("hooks").is_dir(),
        dir.join("pi-extensions").is_dir(),
        dir.join("extras").is_dir(),
    ]
    .iter()
    .filter(|&&b| b)
    .count();
    count >= 2
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{InstallMethod, ItemKind, LockEntry, LockFile};
    use crate::mapping::{HookTarget, MappingConfig};
    use std::path::PathBuf;

    fn hook(name: &str, harnesses: Option<Vec<&str>>) -> crate::hook::Hook {
        hook_from_path(name, harnesses, PathBuf::new())
    }

    fn hook_from_path(
        name: &str,
        harnesses: Option<Vec<&str>>,
        source_path: PathBuf,
    ) -> crate::hook::Hook {
        crate::hook::Hook {
            name: name.into(),
            event: "PreToolUse".into(),
            matcher: Some("Bash".into()),
            description: String::new(),
            safety: None,
            timeout: None,
            harnesses: harnesses.map(|items| items.into_iter().map(String::from).collect()),
            script: String::new(),
            source_path,
        }
    }

    fn hook_with_event(name: &str, event: &str, harnesses: Option<Vec<&str>>) -> crate::hook::Hook {
        let mut hook = hook(name, harnesses);
        hook.event = event.into();
        hook
    }

    fn lock_hook(name: &str, source: &Path, harnesses: Vec<&str>) -> LockEntry {
        LockEntry {
            name: name.into(),
            kind: ItemKind::Hook,
            source: source.to_string_lossy().into_owned(),
            source_repo: None,
            harnesses: harnesses.into_iter().map(String::from).collect(),
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        }
    }

    fn tmpdir(label: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock before epoch")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "vstack-resolve-{label}-{}-{nanos}",
            std::process::id()
        ))
    }

    fn mapping_all_bash_hooks() -> MappingConfig {
        let mut mapping = MappingConfig::default();
        mapping
            .hook_events
            .insert("PreToolUse:Bash".into(), HookTarget::All("all".into()));
        mapping
    }

    #[test]
    fn build_agent_extras_merges_shared_instruction_key() {
        let toml = r#"
[agent-launch-instructions]
all = "Shared launch."
rust = "Rust launch."

[agent-additional-instructions]
all = "Shared extra."
"#;
        let config: ProjectConfig = toml::from_str(toml).unwrap();
        let role = AgentRole::Engineer;

        // Both present: marked shared renders first, blank-line separated.
        let extras = build_agent_extras(&config, "rust", &role, None);
        assert_eq!(
            extras.guidance.as_deref(),
            Some(
                format!(
                    "{}\n\nRust launch.",
                    ProjectConfig::mark_shared("Shared launch.")
                )
                .as_str()
            )
        );
        assert_eq!(
            extras.instructions.as_deref(),
            Some(ProjectConfig::mark_shared("Shared extra.").as_str())
        );

        // Shared-only agent still gets the (marked) shared value.
        let extras = build_agent_extras(&config, "iced", &role, None);
        assert_eq!(
            extras.guidance.as_deref(),
            Some(ProjectConfig::mark_shared("Shared launch.").as_str())
        );

        // Per-agent-only config renders unchanged — no markers.
        let config: ProjectConfig =
            toml::from_str("[agent-launch-instructions]\nrust = \"Rust launch.\"\n").unwrap();
        let extras = build_agent_extras(&config, "rust", &role, None);
        assert_eq!(extras.guidance.as_deref(), Some("Rust launch."));
    }

    #[test]
    fn build_agent_extras_strips_shared_text_from_pre_marker_file_extras() {
        let config: ProjectConfig =
            toml::from_str("[agent-launch-instructions]\nall = \"Shared launch.\"\n").unwrap();
        let role = AgentRole::Engineer;

        // File extras extracted from a render generated before markers existed
        // fall back to prefix-stripping the configured value, so the shared
        // text is still not doubled.
        let file_extras = AgentExtras {
            guidance: Some("Shared launch.\n\nMine.".into()),
            ..Default::default()
        };
        let extras = build_agent_extras(&config, "rust", &role, Some(&file_extras));
        assert_eq!(
            extras.guidance.as_deref(),
            Some(format!("{}\n\nMine.", ProjectConfig::mark_shared("Shared launch.")).as_str())
        );

        let file_extras = AgentExtras {
            guidance: Some("Shared launch.".into()),
            ..Default::default()
        };
        let extras = build_agent_extras(&config, "rust", &role, Some(&file_extras));
        assert_eq!(
            extras.guidance.as_deref(),
            Some(ProjectConfig::mark_shared("Shared launch.").as_str())
        );
    }

    #[test]
    fn build_agent_extras_drops_marked_shared_after_value_change() {
        // The file on disk was rendered when `all` was "Old shared."; the
        // config now says "New shared.". The marked region must be dropped
        // structurally — value comparison would fail to match and persist the
        // stale fleet-wide text as this agent's own entry.
        let config: ProjectConfig =
            toml::from_str("[agent-launch-instructions]\nall = \"New shared.\"\n").unwrap();
        let role = AgentRole::Engineer;
        let file_extras = AgentExtras {
            guidance: Some(format!(
                "{}\n\nMine.",
                ProjectConfig::mark_shared("Old shared.")
            )),
            ..Default::default()
        };

        let extras = build_agent_extras(&config, "rust", &role, Some(&file_extras));

        assert_eq!(
            extras.guidance.as_deref(),
            Some(format!("{}\n\nMine.", ProjectConfig::mark_shared("New shared.")).as_str())
        );
        assert!(
            !extras.guidance.as_deref().unwrap().contains("Old shared."),
            "stale shared text must not survive: {:?}",
            extras.guidance
        );
    }

    #[test]
    fn build_agent_extras_drops_marked_shared_after_value_removal() {
        // `all` was removed from the config entirely; the old render's marked
        // region must still be dropped, leaving only the agent's own text.
        let config: ProjectConfig = toml::from_str("").unwrap();
        let role = AgentRole::Engineer;
        let file_extras = AgentExtras {
            guidance: Some(format!(
                "{}\n\nMine.",
                ProjectConfig::mark_shared("Old shared.")
            )),
            instructions: Some(ProjectConfig::mark_shared("Old shared extra.")),
            ..Default::default()
        };

        let extras = build_agent_extras(&config, "rust", &role, Some(&file_extras));

        assert_eq!(extras.guidance.as_deref(), Some("Mine."));
        // A shared-only section leaves nothing behind once the value is gone.
        assert_eq!(extras.instructions, None);
    }

    #[test]
    fn matched_installed_hooks_are_scoped_to_harness_lock_entries() {
        let mut lock = LockFile::default();
        lock.add(LockEntry {
            name: "guard".into(),
            kind: ItemKind::Hook,
            source: "source".into(),
            source_repo: None,
            harnesses: vec!["codex".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        });
        let hooks = vec![hook("guard", None)];
        let mapping = mapping_all_bash_hooks();

        assert!(
            matched_installed_hooks_for_agent_harness(
                &lock,
                &hooks,
                &mapping,
                &AgentRole::Engineer,
                "claude-code",
            )
            .is_empty()
        );
        assert_eq!(
            matched_installed_hooks_for_agent_harness(
                &lock,
                &hooks,
                &mapping,
                &AgentRole::Engineer,
                "codex",
            )
            .len(),
            1
        );
    }

    #[test]
    fn matched_selected_hooks_respect_source_harness_allowlist_before_lock_exists() {
        let hooks = vec![hook("guard", Some(vec!["claude-code"]))];
        let mapping = mapping_all_bash_hooks();

        assert_eq!(
            matched_selected_hooks_for_agent_harness(
                &mapping,
                &AgentRole::Engineer,
                &hooks,
                "claude-code",
            )
            .len(),
            1
        );
        assert!(
            matched_selected_hooks_for_agent_harness(
                &mapping,
                &AgentRole::Engineer,
                &hooks,
                "codex",
            )
            .is_empty()
        );
    }

    #[test]
    fn matched_installed_hooks_use_lock_entry_source_when_names_collide() {
        let root = tmpdir("hook-source");
        let source_a = root.join("source-a");
        let source_b = root.join("source-b");
        std::fs::create_dir_all(source_a.join("agents")).unwrap();
        std::fs::create_dir_all(source_a.join("hooks")).unwrap();
        std::fs::create_dir_all(source_b.join("agents")).unwrap();
        std::fs::create_dir_all(source_b.join("hooks")).unwrap();
        let mut lock = LockFile::default();
        lock.add(lock_hook("guard", &source_b, vec!["claude-code"]));
        let hooks = vec![
            hook_from_path(
                "guard",
                Some(vec!["codex"]),
                source_a.join("hooks/guard.sh"),
            ),
            hook_from_path(
                "guard",
                Some(vec!["claude-code"]),
                source_b.join("hooks/guard.sh"),
            ),
        ];
        let mapping = mapping_all_bash_hooks();

        assert_eq!(
            matched_installed_hooks_for_agent_harness(
                &lock,
                &hooks,
                &mapping,
                &AgentRole::Engineer,
                "claude-code",
            )
            .len(),
            1
        );
        assert!(
            matched_installed_hooks_for_agent_harness(
                &lock,
                &hooks,
                &mapping,
                &AgentRole::Engineer,
                "codex",
            )
            .is_empty()
        );

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn installed_codex_fallback_hooks_filters_native_and_non_codex_entries() {
        let mut lock = LockFile::default();
        lock.add(LockEntry {
            name: "fallback".into(),
            kind: ItemKind::Hook,
            source: "source".into(),
            source_repo: None,
            harnesses: vec!["codex".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        });
        lock.add(LockEntry {
            name: "native".into(),
            kind: ItemKind::Hook,
            source: "source".into(),
            source_repo: None,
            harnesses: vec!["codex".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        });
        lock.add(LockEntry {
            name: "claude-only".into(),
            kind: ItemKind::Hook,
            source: "source".into(),
            source_repo: None,
            harnesses: vec!["claude-code".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        });
        let hooks = vec![
            hook_with_event("fallback", "TaskCompleted", Some(vec!["codex"])),
            hook_with_event("native", "PreToolUse", Some(vec!["codex"])),
            hook_with_event("claude-only", "TaskCompleted", Some(vec!["claude-code"])),
        ];

        let fallback = installed_codex_fallback_hooks(&lock, &hooks);

        assert_eq!(fallback.len(), 1);
        assert_eq!(fallback[0].name, "fallback");
    }

    #[test]
    fn is_vstack_source_accepts_catalog_table_without_default_dirs() {
        let root = tmpdir("catalog-source");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(
            root.join("vstack.toml"),
            "[catalog]\nskills = [\"pkgs/skills/*\"]\n",
        )
        .unwrap();

        assert!(is_vstack_source(&root));
        let _ = std::fs::remove_dir_all(root);
    }
}
