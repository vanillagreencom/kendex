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
                            global, &lock, harnesses,
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
                        global, &lock, harnesses,
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
