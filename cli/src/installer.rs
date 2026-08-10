use crate::agent::Agent;
use crate::config::{InstallMethod, ItemKind, LockEntry, LockFile};
use crate::harness::Harness;
use crate::hook::Hook;
use crate::skill::Skill;
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

mod hooks;

pub(crate) use crate::path_safety::{validate_item_name, validate_new_item_name};
pub(crate) use hooks::{
    codex_event_for, codex_root, cursor_hook_rule_contents, cursor_hook_rule_path,
    install_codex_fallback_hooks_for_agents, install_hook, migrate_codex_config,
    opencode_hook_instruction_contents, opencode_hook_instruction_path, remove_hook_install,
};

pub(crate) fn codex_hook_safety_block(hook: &Hook) -> String {
    hooks::codex_hook_safety_block(hook)
}

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
    validate_new_item_name(&agent.name)?;
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
    validate_new_item_name(&skill.name)?;
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

/// Remove an installed item.
///
/// Agent/skill deletion and hook cleanup are attempted for every requested
/// harness. Any deletion failure includes path/harness/scope context so callers
/// can keep the lock entry until a later retry succeeds.
pub fn remove_item(
    name: &str,
    kind: Option<ItemKind>,
    harnesses: &[Harness],
    global: bool,
) -> Result<Vec<PathBuf>> {
    validate_item_name(name)?;
    let mut removed = Vec::new();
    let mut cleanup_errors = Vec::new();
    let remove_agents = kind.is_none_or(|kind| kind == ItemKind::Agent);
    let remove_skills = kind.is_none_or(|kind| kind == ItemKind::Skill);
    let remove_hooks = kind.is_none_or(|kind| kind == ItemKind::Hook);

    for harness in harnesses {
        // Agent files
        if remove_agents {
            let agent_paths = match harness {
                Harness::ClaudeCode => vec![harness.agents_dir(global).join(format!("{name}.md"))],
                Harness::Cursor => vec![harness.agents_dir(global).join(format!("{name}.mdc"))],
                Harness::OpenCode => vec![harness.agents_dir(global).join(format!("{name}.md"))],
                Harness::Codex => vec![harness.agents_dir(global).join(format!("{name}.toml"))],
                Harness::Pi => vec![harness.agents_dir(global).join(format!("{name}.md"))],
            };

            for path in agent_paths {
                match remove_expected_path(&path, ExpectedArtifact::File) {
                    Ok(true) => removed.push(path),
                    Ok(false) => {}
                    Err(err) => cleanup_errors.push(format!(
                        "agent {name} removal failed for {} {} scope at {}: {err:#}",
                        harness.name(),
                        if global { "global" } else { "project" },
                        path.display()
                    )),
                }
            }
        }

        // Skill directories
        if remove_skills {
            let skill_path = harness.skills_dir(global).join(name);
            match remove_expected_path(&skill_path, ExpectedArtifact::Any) {
                Ok(true) => removed.push(skill_path),
                Ok(false) => {}
                Err(err) => cleanup_errors.push(format!(
                    "skill {name} removal failed for {} {} scope at {}: {err:#}",
                    harness.name(),
                    if global { "global" } else { "project" },
                    skill_path.display()
                )),
            }
        }

        if remove_hooks {
            match remove_hook_install(name, *harness, global) {
                Ok(hook_removed) => removed.extend(hook_removed),
                Err(err) => cleanup_errors.push(format!(
                    "hook {name} cleanup failed for {} {} scope: {err:#}",
                    harness.name(),
                    if global { "global" } else { "project" }
                )),
            }
        }
    }

    if remove_skills {
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
            match remove_expected_path(&path, ExpectedArtifact::Any) {
                Ok(true) => removed.push(path),
                Ok(false) => {}
                Err(err) => cleanup_errors.push(format!(
                    "canonical skill {name} removal failed for {} scope at {}: {err:#}",
                    if global { "global" } else { "project" },
                    path.display()
                )),
            }
        }
    }

    if !cleanup_errors.is_empty() {
        anyhow::bail!(cleanup_errors.join("; "));
    }

    Ok(removed)
}

#[derive(Clone, Copy)]
enum ExpectedArtifact {
    File,
    Any,
}

fn remove_expected_path(path: &Path, expected: ExpectedArtifact) -> Result<bool> {
    let meta = match std::fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(err) => return Err(err).with_context(|| format!("checking {}", path.display())),
    };
    if meta.file_type().is_symlink() || meta.is_file() {
        std::fs::remove_file(path).with_context(|| format!("removing file {}", path.display()))?;
        return Ok(true);
    }
    if meta.is_dir() {
        if matches!(expected, ExpectedArtifact::File) {
            anyhow::bail!("expected file but found directory");
        }
        std::fs::remove_dir_all(path)
            .with_context(|| format!("removing directory {}", path.display()))?;
        return Ok(true);
    }
    anyhow::bail!("unsupported file type")
}

/// Record installation in lock file
pub fn record_install(
    lock: &mut LockFile,
    results: &[InstallResult],
    source: &str,
    source_repo: Option<&str>,
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
            existing.source_repo = source_repo.map(str::to_string);
            existing.method = method;
            existing.installed_at = now.clone();
            existing.source_hash = crate::config::compute_source_hash(existing);
        } else {
            let mut entry = LockEntry {
                name: result.name.clone(),
                kind: result.kind,
                source: source.into(),
                source_repo: source_repo.map(str::to_string),
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

    #[test]
    fn record_install_updates_method_for_existing_entry() {
        let mut lock = LockFile::default();
        lock.add(LockEntry {
            name: "rust".into(),
            kind: ItemKind::Agent,
            source: "old-source".into(),
            source_repo: None,
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

        record_install(
            &mut lock,
            &results,
            "new-source",
            Some("vanillagreencom/vstack"),
            InstallMethod::Copy,
        );

        let entry = lock.entries.get("rust").expect("entry should exist");
        assert_eq!(entry.method, InstallMethod::Copy);
        assert_eq!(entry.source, "new-source");
        assert_eq!(entry.source_repo.as_deref(), Some("vanillagreencom/vstack"));
        assert!(entry.harnesses.contains(&Harness::Pi.id().to_string()));
        assert!(
            entry
                .harnesses
                .contains(&Harness::ClaudeCode.id().to_string())
        );
    }

    #[test]
    fn install_skill_applies_shared_skill_instructions_to_every_skill() {
        let root = std::env::temp_dir().join(format!(
            "vstack_shared_skill_instr_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let project = root.join("project");
        let source = root.join("source").join("github");
        std::fs::create_dir_all(&project).unwrap();
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(
            source.join("SKILL.md"),
            "---\nname: github\ndescription: GitHub ops\n---\n\n# GitHub\n\nBody.\n",
        )
        .unwrap();

        // The skill has NO entry of its own — only the shared key applies.
        let config: crate::project_config::ProjectConfig =
            toml::from_str("[skill-instructions]\nall = \"Shared skill rule.\"\n").unwrap();
        let instructions = config.skill_instructions_for("github");
        assert_eq!(instructions.as_deref(), Some("Shared skill rule."));

        let skill = Skill {
            name: "github".into(),
            description: "GitHub ops".into(),
            license: None,
            user_invocable: None,
            dependencies: None,
            body: String::new(),
            source_dir: source.clone(),
            resolved_deps: Vec::new(),
        };

        let result = crate::test_util::with_project_root(&project, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Copy,
                instructions.as_deref(),
            )
            .unwrap()
        });

        let installed = std::fs::read_to_string(result.path.join("SKILL.md")).unwrap();
        assert!(
            installed.contains("## Project Instructions"),
            "installed SKILL.md: {installed}"
        );
        assert!(
            installed.contains("Shared skill rule."),
            "installed SKILL.md: {installed}"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn remove_item_accepts_reserved_name_for_legacy_installs() {
        // `all` is reserved for NEW installs only; a project that installed an
        // item named `all` under a previous release must still be able to
        // remove it.
        let root = std::env::temp_dir().join(format!(
            "vstack_remove_reserved_name_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let project = root.join("project");
        let legacy_agent = project.join(".claude").join("agents").join("all.md");
        std::fs::create_dir_all(legacy_agent.parent().unwrap()).unwrap();
        std::fs::write(&legacy_agent, "# all\n").unwrap();

        let removed = crate::test_util::with_project_root(&project, || {
            remove_item("all", Some(ItemKind::Agent), &[Harness::ClaudeCode], false).unwrap()
        });
        assert!(removed.contains(&legacy_agent), "removed: {removed:?}");
        assert!(!legacy_agent.exists());

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn install_rejects_reserved_name() {
        let agent = Agent {
            name: "all".into(),
            description: "reserved".into(),
            model: "sonnet".into(),
            role: Default::default(),
            color: None,
            effort: None,
            body: String::new(),
            source_path: PathBuf::new(),
        };
        let err = install_agent(
            &agent,
            Harness::ClaudeCode,
            false,
            &[],
            &[],
            &crate::agent::AgentExtras::default(),
        )
        .err()
        .expect("install_agent must reject the reserved name");
        assert!(err.to_string().contains("reserved"), "got: {err}");

        let skill = Skill {
            name: "all".into(),
            description: "reserved".into(),
            license: None,
            user_invocable: None,
            dependencies: None,
            body: String::new(),
            source_dir: PathBuf::new(),
            resolved_deps: Vec::new(),
        };
        let err = install_skill(
            &skill,
            Harness::ClaudeCode,
            false,
            InstallMethod::Copy,
            None,
        )
        .err()
        .expect("install_skill must reject the reserved name");
        assert!(err.to_string().contains("reserved"), "got: {err}");
    }

    #[test]
    fn remove_item_reports_agent_delete_failure() {
        let root = std::env::temp_dir().join(format!(
            "vstack_remove_agent_failure_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let project = root.join("project");
        let bad_agent_path = project.join(".claude").join("agents").join("rust.md");
        std::fs::create_dir_all(&bad_agent_path).unwrap();

        let err = crate::test_util::with_project_root(&project, || {
            remove_item("rust", Some(ItemKind::Agent), &[Harness::ClaudeCode], false).unwrap_err()
        });
        let message = err.to_string();
        assert!(message.contains("agent rust removal failed"));
        assert!(message.contains("Claude Code project scope"));
        assert!(message.contains("rust.md"));
        assert!(bad_agent_path.is_dir());

        let _ = std::fs::remove_dir_all(&root);
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
