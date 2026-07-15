use crate::config::{self, ItemKind, LockFile};
use crate::harness::Harness;
use crate::installer;
use crate::scope::ScopeFilter;
use anyhow::Result;

pub fn run(names: &[String], scope: ScopeFilter) -> Result<()> {
    if names.is_empty() {
        eprintln!("Usage: vstack remove <name> [<name>...] [--scope project|global|all]");
        return Ok(());
    }

    let mut total_removed = 0usize;
    let mut total_missing = 0usize;
    let mut printed_scope_header = false;

    for &global in scope.globals() {
        let lock_path = config::lock_file_path(global);
        if !lock_path.exists() {
            continue;
        }
        let mut lock = LockFile::load(&lock_path).unwrap_or_default();
        let scope_label = if global { "GLOBAL" } else { "PROJECT" };
        let project_root = config::project_root();
        let removes_hook = names.iter().any(|name| {
            lock.entries
                .get(name)
                .is_some_and(|entry| entry.kind == ItemKind::Hook)
        });
        let mut project_config = if removes_hook {
            if global {
                Some(crate::project_config::ProjectConfig::load(&project_root))
            } else {
                crate::commands::refresh::preflight_project_refresh(&project_root)?;
                Some(crate::project_config::ProjectConfig::load_strict(
                    &project_root,
                )?)
            }
        } else {
            None
        };

        let mut scope_removed: Vec<String> = Vec::new();
        let mut scope_missing: Vec<String> = Vec::new();
        let mut scope_failed: Vec<String> = Vec::new();

        for name in names {
            let lock_entry = lock.entries.get(name.as_str()).cloned();
            let kind = lock_entry.as_ref().map(|entry| entry.kind);
            let removed_hook_harnesses = lock_entry
                .as_ref()
                .filter(|entry| entry.kind == ItemKind::Hook)
                .map(|entry| entry.harnesses.clone());
            let harnesses: Vec<Harness> = if let Some(ref entry) = lock_entry {
                entry
                    .harnesses
                    .iter()
                    .filter_map(|h| Harness::from_id(h))
                    .collect()
            } else {
                Harness::ALL.to_vec()
            };

            // Pi packages live in a separate location; route to the dedicated
            // helper. Also catches stale/manual installs missing from the lock.
            let mut removed = Vec::new();
            let remove_as_pi_extension = matches!(
                lock_entry.as_ref().map(|e| e.kind),
                Some(crate::config::ItemKind::PiExtension)
            ) || (lock_entry.is_none()
                && crate::pi_extension::is_pi_extension_installed(name, global));
            let remove_result = if remove_as_pi_extension {
                crate::pi_extension::remove_pi_extension(name, global)
            } else {
                installer::remove_item(name, kind, &harnesses, global)
            };
            match remove_result {
                Ok(paths) => removed.extend(paths),
                Err(err) => {
                    if !printed_scope_header {
                        eprintln!("\n{scope_label}:");
                        printed_scope_header = true;
                    }
                    eprintln!("  failed to remove {name}: {err:#}");
                    scope_failed.push(name.clone());
                    continue;
                }
            }

            if removed.is_empty() {
                if lock_entry.is_some() {
                    if !printed_scope_header {
                        eprintln!("\n{scope_label}:");
                        printed_scope_header = true;
                    }
                    eprintln!("  removed stale lock entry for {name}");
                    lock.remove(name);
                    if let Some(harnesses) = removed_hook_harnesses.as_deref() {
                        lock.save(&lock_path)?;
                        crate::commands::refresh::regenerate_agents_after_hook_removal(
                            global,
                            &lock,
                            harnesses,
                            project_config
                                .as_mut()
                                .expect("hook-removal config preloaded"),
                            &project_root,
                        )?;
                    }
                    scope_removed.push(name.clone());
                } else {
                    scope_missing.push(name.clone());
                }
            } else {
                if !printed_scope_header {
                    eprintln!("\n{scope_label}:");
                    printed_scope_header = true;
                }
                let pi_settings_path = config::pi_settings_path(global);
                for path in &removed {
                    if path == &pi_settings_path {
                        eprintln!("  updated {}", path.display());
                    } else {
                        eprintln!("  removed {}", path.display());
                    }
                }
                lock.remove(name);
                if let Some(harnesses) = removed_hook_harnesses.as_deref() {
                    lock.save(&lock_path)?;
                    crate::commands::refresh::regenerate_agents_after_hook_removal(
                        global,
                        &lock,
                        harnesses,
                        project_config
                            .as_mut()
                            .expect("hook-removal config preloaded"),
                        &project_root,
                    )?;
                }
                scope_removed.push(name.clone());
            }
        }

        lock.save(&lock_path)?;
        total_removed += scope_removed.len();
        total_missing += scope_missing.len();
        if !scope_failed.is_empty() {
            anyhow::bail!(
                "failed to remove {} item(s) in {scope_label} scope: {}",
                scope_failed.len(),
                scope_failed.join(", ")
            );
        }
        // Reset header state per scope so each scope prints its own header
        // when it has output.
        printed_scope_header = false;
    }

    eprintln!();
    if total_removed == 0 && total_missing > 0 {
        eprintln!("Nothing removed: {total_missing} not found in selected scope(s).");
    } else {
        eprintln!("Removed {total_removed} item(s) across {}", scope.label());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{InstallMethod, LockEntry};
    use std::path::{Path, PathBuf};

    #[derive(Clone, Copy)]
    enum BrokenConfig {
        Malformed,
        Unreadable,
    }

    fn tmpdir(label: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock before epoch")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "vstack-remove-{label}-{}-{nanos}",
            std::process::id()
        ))
    }

    fn lock_entry(name: &str, kind: ItemKind, source: &Path) -> LockEntry {
        LockEntry {
            name: name.into(),
            kind,
            source: source.to_string_lossy().into_owned(),
            harnesses: vec!["claude-code".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-15T00:00:00Z".into(),
            source_hash: String::new(),
        }
    }

    fn assert_project_hook_removal_rejects_broken_config(kind: BrokenConfig) {
        let root = tmpdir(match kind {
            BrokenConfig::Malformed => "malformed-config",
            BrokenConfig::Unreadable => "unreadable-config",
        });
        let project = root.join("project");
        let source = root.join("source");
        std::fs::create_dir_all(project.join(".claude/hooks")).unwrap();
        std::fs::create_dir_all(project.join(".claude/agents")).unwrap();
        std::fs::create_dir_all(source.join("agents")).unwrap();
        std::fs::create_dir_all(source.join("hooks")).unwrap();
        std::fs::write(
            source.join("vstack.toml"),
            "[hook-events]\n\"PreToolUse:Bash\" = \"all\"\n",
        )
        .unwrap();
        std::fs::write(
            source.join("agents/rust.md"),
            "---\nname: rust\ndescription: Rust\nmodel: sonnet\nrole: engineer\n---\n# Rust\n",
        )
        .unwrap();
        std::fs::write(
            source.join("hooks/guard.sh"),
            "# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: Guard\n# ---\n#!/usr/bin/env bash\nexit 0\n",
        )
        .unwrap();

        let hook_path = project.join(".claude/hooks/guard.sh");
        let settings_path = project.join(".claude/settings.json");
        let agent_path = project.join(".claude/agents/rust.md");
        let hook_bytes = b"#!/usr/bin/env bash\n# installed guard\n";
        let settings_bytes = b"{\n  \"hooks\": {\n    \"PreToolUse\": [\n      {\n        \"matcher\": \"Bash\",\n        \"hooks\": [{\"type\": \"command\", \"command\": \"bash \\\"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\\\"\"}]\n      }\n    ]\n  }\n}\n";
        let agent_bytes = b"---\nhooks:\n  PreToolUse:\n    - guard\n---\n# Installed Rust agent\n";
        std::fs::write(&hook_path, hook_bytes).unwrap();
        std::fs::write(&settings_path, settings_bytes).unwrap();
        std::fs::write(&agent_path, agent_bytes).unwrap();

        let mut lock = LockFile::default();
        lock.add(lock_entry("rust", ItemKind::Agent, &source));
        lock.add(lock_entry("guard", ItemKind::Hook, &source));
        let lock_path = project.join(".vstack-lock.json");
        lock.save(&lock_path).unwrap();
        let lock_bytes = std::fs::read(&lock_path).unwrap();

        match kind {
            BrokenConfig::Malformed => {
                std::fs::write(project.join("vstack.toml"), "[agent-skills\n").unwrap();
            }
            BrokenConfig::Unreadable => {
                std::fs::create_dir(project.join("vstack.toml")).unwrap();
            }
        }

        let err = crate::test_util::with_project_root(&project, || {
            run(&["guard".to_string()], crate::scope::ScopeFilter::Project).unwrap_err()
        });
        let expected = match kind {
            BrokenConfig::Malformed => "parsing",
            BrokenConfig::Unreadable => "reading",
        };
        assert!(err.to_string().contains(expected), "{err:#}");
        assert_eq!(std::fs::read(&hook_path).unwrap(), hook_bytes);
        assert_eq!(std::fs::read(&settings_path).unwrap(), settings_bytes);
        assert_eq!(std::fs::read(&agent_path).unwrap(), agent_bytes);
        assert_eq!(std::fs::read(&lock_path).unwrap(), lock_bytes);

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn cli_hook_removal_keeps_state_on_malformed_project_config() {
        assert_project_hook_removal_rejects_broken_config(BrokenConfig::Malformed);
    }

    #[test]
    fn cli_hook_removal_keeps_state_on_unreadable_project_config() {
        assert_project_hook_removal_rejects_broken_config(BrokenConfig::Unreadable);
    }
}
