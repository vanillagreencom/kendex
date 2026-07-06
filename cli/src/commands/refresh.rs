use crate::agent::Agent;
use crate::commands::refresh_sources::{
    RefreshSource, all_source_hooks, all_source_pi_extensions, load_refresh_sources,
    refresh_source_for_entry, resolve_skill_pairs_from_sources, resolve_source_records,
    source_pi_extension_for_lock_name,
};
use crate::config::{self, ItemKind};
use crate::harness::Harness;
use crate::hook::Hook;
use crate::installer;
use crate::project_config::ProjectConfig;
use crate::skill::Skill;
use anyhow::Result;
use std::collections::{HashMap, HashSet};
use std::path::Path;

/// Result counts from one invocation of [`refresh_items_in_scope`].
#[derive(Default)]
pub struct RefreshStats {
    pub agents_refreshed: usize,
    pub skills_refreshed: usize,
    pub hooks_refreshed: usize,
    pub pi_refreshed: usize,
    pub successful_items: HashSet<String>,
    pub failures: Vec<RefreshFailure>,
    /// Map of agent_name → (full merged required-skills list, newly added skill names).
    pub upstream_skill_updates: HashMap<String, (Vec<String>, Vec<String>)>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RefreshFailure {
    pub item: String,
    pub harness: Option<String>,
    pub error: String,
}

impl RefreshStats {
    /// Persist any required-skill upstream additions back to the project's
    /// `vstack.toml`. No-op for global scope (no project config).
    pub fn persist_upstream(&self, project_root: &Path) {
        if !self.upstream_skill_updates.is_empty() {
            let merged: HashMap<String, Vec<String>> = self
                .upstream_skill_updates
                .iter()
                .map(|(k, (list, _))| (k.clone(), list.clone()))
                .collect();
            crate::project_config::merge_upstream_agent_skills(project_root, &merged);
        }
    }

    fn mark_success(&mut self, name: &str) {
        self.successful_items.insert(name.to_string());
    }

    fn fail(&mut self, item: &str, harness: Option<Harness>, err: impl std::fmt::Display) {
        self.failures.push(RefreshFailure {
            item: item.to_string(),
            harness: harness.map(|harness| harness.name().to_string()),
            error: err.to_string(),
        });
    }

    pub fn has_failures(&self) -> bool {
        !self.failures.is_empty()
    }
}

/// Generic upstream-merge: starts with `project_list` if present, else
/// `source_list`; appends source items not already present, returning
/// (merged, names_added).
fn merge_upstream<T: Clone>(
    project_list: Option<&[T]>,
    source_list: &[T],
    key: impl Fn(&T) -> String,
) -> (Vec<T>, Vec<String>) {
    let Some(project_list) = project_list else {
        return (source_list.to_vec(), Vec::new());
    };
    let mut merged: Vec<T> = project_list.to_vec();
    let existing: std::collections::HashSet<String> = merged.iter().map(&key).collect();
    let prev_len = merged.len();
    for s in source_list {
        if !existing.contains(&key(s)) {
            merged.push(s.clone());
        }
    }
    let added: Vec<String> = merged[prev_len..].iter().map(&key).collect();
    (merged, added)
}

/// Re-install the items currently recorded in `lock` (or just those in
/// `name_filter`) using the supplied source data.
///
/// Both `vstack refresh` and the TUI's inline-update path go through this
/// helper. Caller is responsible for: source discovery (filling `sources`),
/// project-config loading, lock loading, lock-disk reconciliation, hook-harness pruning via
/// [`prune_hook_harnesses`], and writing the upstream-additions back to disk via
/// [`crate::project_config::merge_upstream_agent_skills`].
#[allow(clippy::too_many_arguments)]
pub fn refresh_items_in_scope(
    global: bool,
    lock: &config::LockFile,
    sources: &[RefreshSource],
    project_config: &mut ProjectConfig,
    project_root: &Path,
    name_filter: Option<&[String]>,
) -> RefreshStats {
    let mut stats = RefreshStats::default();
    let pass = |name: &str| name_filter.is_none_or(|f| f.iter().any(|n| n == name));
    let all_hooks = all_source_hooks(sources);

    if lock
        .entries
        .values()
        .any(|entry| entry.harnesses.iter().any(|h| h == Harness::Codex.id()))
        && let Err(err) = installer::migrate_codex_config(global)
    {
        eprintln!("Warning: failed to migrate Codex config feature flags: {err}");
    }

    let installed_skills: Vec<String> = lock
        .entries
        .iter()
        .filter(|(_, e)| e.kind == ItemKind::Skill)
        .map(|(name, _)| name.clone())
        .collect();
    let mut regenerated_codex_agents = Vec::new();

    // ── Agents ───────────────────────────────────────────────
    for (name, entry) in lock
        .entries
        .iter()
        .filter(|(_, e)| e.kind == ItemKind::Agent)
        .filter(|(n, _)| pass(n))
    {
        let Some(source) = refresh_source_for_entry(sources, entry) else {
            if name_filter.is_none() {
                eprintln!("  ! {} — source not found, skipped", name);
            }
            continue;
        };
        let Some(agent) = source.agents.iter().find(|a| &a.name == name) else {
            if name_filter.is_none() {
                eprintln!("  ! {} — source not found, skipped", name);
            }
            continue;
        };

        // Required skills: project list (if present) merged with source additions.
        let source_skills =
            source
                .mapping
                .skills_for_agent(&agent.name, &agent.role, &installed_skills);
        let project_required = project_config.agent_skills_for(&agent.name);
        let (skill_names, added) =
            merge_upstream(project_required.map(|v| &v[..]), &source_skills, |s| {
                s.clone()
            });
        if !added.is_empty() {
            project_config
                .agent_skills
                .insert(agent.name.clone(), skill_names.clone());
            stats
                .upstream_skill_updates
                .insert(agent.name.clone(), (skill_names.clone(), added));
        }

        let skill_pairs = resolve_skill_pairs_from_sources(&skill_names, lock, sources);

        for harness_id in &entry.harnesses {
            if let Some(harness) = Harness::from_id(harness_id) {
                let existing_path = harness
                    .agents_dir(global)
                    .join(harness.agent_filename(&agent.name));
                let file_extras = crate::resolve::read_existing_extras(&existing_path, harness);
                // Project-level vstack.toml is only meaningful in project scope.
                if !global {
                    project_config.save_extracted(project_root, &agent.name, &file_extras);
                }
            }
        }

        let mut effective_project_config = project_config.clone();
        effective_project_config.overlay_source_frontmatter(&source.mapping);
        let extras = crate::resolve::build_agent_extras(
            &effective_project_config,
            &agent.name,
            &agent.role,
            None,
        );

        let mut succeeded = 0usize;
        let mut failed = false;
        for harness_id in &entry.harnesses {
            if let Some(harness) = Harness::from_id(harness_id) {
                let matched_hooks = crate::resolve::matched_installed_hooks_for_agent_harness(
                    lock,
                    &all_hooks,
                    &source.mapping,
                    &agent.role,
                    harness.id(),
                );
                match harness.generate_agent(agent, global, &skill_pairs, &matched_hooks, &extras) {
                    Ok(_) => {
                        succeeded += 1;
                        if matches!(harness, Harness::Codex) {
                            regenerated_codex_agents.push(agent.clone());
                        }
                    }
                    Err(err) => {
                        failed = true;
                        stats.fail(name, Some(harness), err);
                    }
                }
            }
        }
        if succeeded > 0 && !failed {
            stats.agents_refreshed += 1;
            stats.mark_success(name);
        }
    }

    if !regenerated_codex_agents.is_empty() {
        let fallback_hooks = crate::resolve::installed_codex_fallback_hooks(lock, &all_hooks);
        if !fallback_hooks.is_empty()
            && let Err(err) = crate::installer::install_codex_fallback_hooks_for_agents(
                &fallback_hooks,
                global,
                &regenerated_codex_agents,
            )
        {
            let error = format!("failed to install Codex hook prose: {err:#}");
            for agent in &regenerated_codex_agents {
                stats.fail(&agent.name, Some(Harness::Codex), &error);
                if stats.successful_items.remove(&agent.name) && stats.agents_refreshed > 0 {
                    stats.agents_refreshed -= 1;
                }
            }
        }
    }

    // ── Skills ───────────────────────────────────────────────
    for (name, entry) in lock
        .entries
        .iter()
        .filter(|(_, e)| e.kind == ItemKind::Skill)
        .filter(|(n, _)| pass(n))
    {
        let Some(source) = refresh_source_for_entry(sources, entry) else {
            continue;
        };
        let Some(skill) = source.skills.iter().find(|s| &s.name == name) else {
            continue;
        };

        let mut succeeded = 0usize;
        let mut failed = false;
        for harness_id in &entry.harnesses {
            if let Some(harness) = Harness::from_id(harness_id) {
                let skill_instr = project_config.skill_instructions_for(&skill.name);
                match installer::install_skill(skill, harness, global, entry.method, skill_instr) {
                    Ok(_) => succeeded += 1,
                    Err(err) => {
                        failed = true;
                        stats.fail(name, Some(harness), err);
                    }
                }
            }
        }
        if succeeded > 0 && !failed {
            stats.skills_refreshed += 1;
            stats.mark_success(name);
        }
    }

    // ── Hooks ─────────────────────────────────────────────
    // Hooks must be re-installed per harness on refresh. Claude Code, OpenCode,
    // and Codex each maintain hook state outside the agent files (Claude
    // settings.json, OpenCode opencode.json, Codex hooks.json + config.toml).
    // Regenerating agents alone doesn't refresh those.
    let agent_entries: Vec<Agent> = lock
        .entries
        .iter()
        .filter(|(_, e)| e.kind == ItemKind::Agent)
        .filter_map(|(name, entry)| {
            refresh_source_for_entry(sources, entry)
                .and_then(|source| source.agents.iter().find(|agent| &agent.name == name))
                .cloned()
        })
        .collect();

    for (name, entry) in lock
        .entries
        .iter()
        .filter(|(_, e)| e.kind == ItemKind::Hook)
        .filter(|(n, _)| pass(n))
    {
        let Some(source) = refresh_source_for_entry(sources, entry) else {
            continue;
        };
        let Some(hook) = source.hooks.iter().find(|hook| hook.name == entry.name) else {
            continue;
        };
        let mut succeeded = 0usize;
        let mut failed = false;
        for harness_id in &entry.harnesses {
            if !hook.applies_to(harness_id) {
                continue;
            }
            if let Some(harness) = Harness::from_id(harness_id) {
                match installer::install_hook(hook, harness, global, &agent_entries) {
                    Ok(_) => succeeded += 1,
                    Err(err) => {
                        failed = true;
                        stats.fail(name, Some(harness), err);
                    }
                }
            }
        }
        if succeeded > 0 && !failed {
            stats.hooks_refreshed += 1;
            stats.mark_success(name);
        }
    }

    // ── Pi packages ──────────────────────────────────────
    for (name, entry) in lock
        .entries
        .iter()
        .filter(|(_, e)| e.kind == ItemKind::PiExtension)
        .filter(|(n, _)| pass(n))
    {
        let Some(source) = refresh_source_for_entry(sources, entry) else {
            continue;
        };
        let Some(ext) = source_pi_extension_for_lock_name(&source.pi_extensions, name) else {
            continue;
        };
        match crate::pi_extension::install_pi_extension(ext, global) {
            Ok(_) => {
                stats.pi_refreshed += 1;
                stats.mark_success(name);
            }
            Err(err) => stats.fail(name, Some(Harness::Pi), err),
        }
    }

    stats
}

/// Drop hook harness ids that no longer satisfy the source hook `harnesses:`
/// allowlist, removing the stale harness artifacts/settings before mutating the
/// lock. Returns true when the lock changed.
pub fn prune_hook_harnesses(
    global: bool,
    lock: &mut config::LockFile,
    source_hooks: &[Hook],
    name_filter: Option<&[String]>,
) -> bool {
    let pass = |name: &str| name_filter.is_none_or(|names| names.iter().any(|n| n == name));
    let mut pruned_any = false;
    let mut remove_hook_entries = Vec::new();

    for entry in lock
        .entries
        .values_mut()
        .filter(|entry| entry.kind == ItemKind::Hook && pass(&entry.name))
    {
        let Some(hook) = crate::resolve::source_hook_for_lock_entry(source_hooks, entry) else {
            continue;
        };
        let mut new_harnesses = Vec::new();
        for harness_id in &entry.harnesses {
            if hook.applies_to(harness_id) {
                new_harnesses.push(harness_id.clone());
                continue;
            }

            let Some(harness) = Harness::from_id(harness_id) else {
                pruned_any = true;
                continue;
            };
            match installer::remove_hook_install(&entry.name, harness, global) {
                Ok(_) => pruned_any = true,
                Err(err) => {
                    eprintln!(
                        "Warning: failed to remove hook {} from {} during refresh: {err}",
                        entry.name,
                        harness.name()
                    );
                    new_harnesses.push(harness_id.clone());
                }
            }
        }
        if new_harnesses != entry.harnesses {
            entry.harnesses = new_harnesses;
            pruned_any = true;
        }
        if entry.harnesses.is_empty() {
            remove_hook_entries.push(entry.name.clone());
        }
    }

    for name in remove_hook_entries {
        lock.remove(&name);
        pruned_any = true;
    }

    pruned_any
}

pub fn regenerate_agents_after_hook_removal(
    global: bool,
    lock: &config::LockFile,
    removed_hook_harnesses: &[String],
) -> Result<()> {
    if removed_hook_harnesses.is_empty() {
        return Ok(());
    }

    let agent_names: Vec<String> = lock
        .entries
        .iter()
        .filter(|(_, entry)| entry.kind == ItemKind::Agent)
        .filter(|(_, entry)| {
            entry.harnesses.iter().any(|harness| {
                removed_hook_harnesses
                    .iter()
                    .any(|removed| removed == harness)
            })
        })
        .map(|(name, _)| name.clone())
        .collect();
    if agent_names.is_empty() {
        return Ok(());
    }

    let source_records = resolve_source_records(lock);
    let sources = load_refresh_sources(&source_records);
    if sources.is_empty() {
        return Ok(());
    }

    let project_root = config::project_root();
    let mut project_config = ProjectConfig::load(&project_root);
    let stats = refresh_items_in_scope(
        global,
        lock,
        &sources,
        &mut project_config,
        &project_root,
        Some(&agent_names),
    );
    if !global {
        stats.persist_upstream(&project_root);
    }
    if stats.has_failures() {
        anyhow::bail!(
            "failed to regenerate agents after hook removal: {} failure(s)",
            stats.failures.len()
        );
    }

    Ok(())
}

/// Reinstall every item recorded in the selected scopes from current source:
/// regenerate agent files (re-applying `vstack.toml` customizations),
/// re-copy skills, hooks, and Pi packages. Use after editing source files
/// to push changes to the install scope without re-running `vstack add`.
pub fn run(scope: crate::scope::ScopeFilter, verbose: bool) -> Result<()> {
    let mut any_action = false;
    for &global in scope.globals() {
        let lock_path = config::lock_file_path(global);
        if !lock_path.exists() {
            continue;
        }
        let lock = config::LockFile::load(&lock_path).unwrap_or_default();
        if lock.entries.is_empty() {
            continue;
        }
        any_action = true;
        let scope_label = if global { "GLOBAL" } else { "PROJECT" };
        eprintln!("\n─ refresh ({scope_label}) ─");
        run_one(global, verbose)?;
    }
    if !any_action {
        eprintln!("Nothing installed in selected scope(s). Run `vstack add` first.");
    }
    Ok(())
}

fn run_one(global: bool, verbose: bool) -> Result<()> {
    let lock_path = config::lock_file_path(global);
    let mut lock = config::LockFile::load(&lock_path)?;

    // Reconcile lock with disk before refreshing (recovers orphaned entries)
    let source_hint = lock
        .entries
        .values()
        .next()
        .map(|e| e.source.clone())
        .unwrap_or_default();
    if config::reconcile_lock_with_disk(&mut lock, global, &source_hint) {
        lock.save(&lock_path)?;
    }

    // Resolve source directories once per refresh. Cached remote sources update
    // during resolution; reusing this list avoids duplicate git fetch/reset
    // cycles for pruning and aggregation.
    let source_records = resolve_source_records(&lock);
    let source_dirs: Vec<_> = source_records
        .iter()
        .map(|source| source.root.clone())
        .collect();
    let sources = load_refresh_sources(&source_records);

    // Self-heal hook lock entries: drop harness ids the hook no longer
    // applies to (the `harnesses:` allowlist in source may have changed
    // since install). Done up-front so all downstream passes see the
    // pruned state.
    {
        let source_hooks_for_prune = all_source_hooks(&sources);
        if prune_hook_harnesses(global, &mut lock, &source_hooks_for_prune, None) {
            lock.save(&lock_path)?;
        }
    }

    let project_root = config::project_root();

    if lock.entries.is_empty() {
        eprintln!("Nothing installed. Run `vstack add` first.");
        return Ok(());
    }

    if !global {
        let agent_names: Vec<String> = lock
            .entries
            .iter()
            .filter(|(_, e)| e.kind == ItemKind::Agent)
            .map(|(n, _)| n.clone())
            .collect();
        let skill_names: Vec<String> = lock
            .entries
            .iter()
            .filter(|(_, e)| e.kind == ItemKind::Skill)
            .map(|(n, _)| n.clone())
            .collect();
        crate::project_config::ensure_project_config(&project_root, &agent_names, &skill_names);
    }
    let mut project_config = crate::project_config::ProjectConfig::load(&project_root);

    if sources.is_empty() {
        eprintln!("Could not locate any package sources. Run `vstack add` to reinstall.");
        return Ok(());
    }
    let all_pi_extensions = all_source_pi_extensions(&sources);

    if !global {
        let project_canon = project_root
            .canonicalize()
            .unwrap_or_else(|_| project_root.clone());
        let project_is_source = source_dirs
            .iter()
            .any(|dir| dir.canonicalize().unwrap_or_else(|_| dir.clone()) == project_canon);
        if !project_is_source {
            let installed_settings_skills: Vec<Skill> = lock
                .entries
                .iter()
                .filter(|(_, entry)| entry.kind == ItemKind::Skill)
                .filter_map(|(name, entry)| {
                    refresh_source_for_entry(&sources, entry).and_then(|source| {
                        source
                            .skills
                            .iter()
                            .find(|skill| &skill.name == name)
                            .cloned()
                    })
                })
                .collect();
            if let Some(result) = crate::project_settings::ensure_skill_settings(
                &project_root,
                &installed_settings_skills,
            )? {
                eprintln!("  + {}", result.summary());
            }
        }

        let harnesses_by_agent: HashMap<String, Vec<Harness>> = lock
            .entries
            .iter()
            .filter(|(_, entry)| entry.kind == ItemKind::Agent)
            .map(|(name, entry)| {
                (
                    name.clone(),
                    entry
                        .harnesses
                        .iter()
                        .filter_map(|harness_id| Harness::from_id(harness_id))
                        .collect(),
                )
            })
            .collect();
        for source in &sources {
            let installed_agents: Vec<Agent> = lock
                .entries
                .iter()
                .filter(|(_, entry)| entry.kind == ItemKind::Agent)
                .filter(|(_, entry)| {
                    refresh_source_for_entry(&sources, entry)
                        .is_some_and(|owner| owner.root == source.root)
                })
                .filter_map(|(name, _)| {
                    source
                        .agents
                        .iter()
                        .find(|agent| &agent.name == name)
                        .cloned()
                })
                .collect();
            crate::project_config::write_agent_frontmatter_defaults(
                &project_root,
                &installed_agents,
                &harnesses_by_agent,
                &source.mapping,
            );
        }
        project_config = crate::project_config::ProjectConfig::load(&project_root);
    }

    let stats = refresh_items_in_scope(
        global,
        &lock,
        &sources,
        &mut project_config,
        &project_root,
        None,
    );

    if !global {
        stats.persist_upstream(&project_root);
        for (agent, (_, added)) in &stats.upstream_skill_updates {
            eprintln!(
                "  + {} — added upstream skills: {}",
                agent,
                added.join(", ")
            );
        }
    }

    // Update lock file timestamps and content hashes. Also repair stale source
    // paths: if an entry's recorded source no longer resolves but we found a
    // working source via CWD/registry fallback, rewrite the entry's source so
    // future refresh/staleness checks use the valid path.
    let mut lock = config::LockFile::load(&lock_path)?;
    let now = config::now_iso();
    let fallback_source = source_dirs.first().map(|p| p.display().to_string());
    let mut repaired_sources = 0usize;
    let mut renamed_pi_entries = 0usize;
    for ext in &all_pi_extensions {
        for legacy in crate::pi_extension::legacy_names_for(&ext.name) {
            if lock.entries.contains_key(&ext.name) {
                let _ = lock.remove(legacy);
                continue;
            }
            if let Some(mut entry) = lock.remove(legacy) {
                entry.name = ext.name.clone();
                lock.add(entry);
                renamed_pi_entries += 1;
            }
        }
    }
    let mut changes: Vec<(ItemKind, String, String, String, String)> = Vec::new();
    for entry in lock.entries.values_mut() {
        let source_resolved = source_records
            .iter()
            .any(|source| source.aliases.iter().any(|alias| alias == &entry.source));
        if !source_resolved
            && let Some(replacement) = &fallback_source
            && &entry.source != replacement
        {
            entry.source = replacement.clone();
            repaired_sources += 1;
        }
        let old_hash = entry.source_hash.clone();
        if stats.successful_items.contains(&entry.name) {
            entry.installed_at = now.clone();
            entry.source_hash = config::compute_source_hash(entry);
        }
        changes.push((
            entry.kind,
            entry.kind.label_short().to_string(),
            entry.name.clone(),
            old_hash,
            entry.source_hash.clone(),
        ));
    }
    lock.save(&lock_path)?;

    if verbose {
        let kind_w = changes
            .iter()
            .map(|(_, k, _, _, _)| k.len())
            .max()
            .unwrap_or(0);
        let name_w = changes
            .iter()
            .map(|(_, _, n, _, _)| n.len())
            .max()
            .unwrap_or(0);
        for (_, kind, name, old, new) in &changes {
            let mark = if old == new { "✓" } else { "!" };
            let label = if old == new { "unchanged" } else { "changed" };
            let old_short = if old.is_empty() {
                "—".to_string()
            } else {
                old.chars().take(8).collect()
            };
            let new_short: String = new.chars().take(8).collect();
            eprintln!(
                "  {mark} {:kw$}  {:nw$}  {} → {}  ({})",
                kind,
                name,
                old_short,
                new_short,
                label,
                kw = kind_w,
                nw = name_w,
            );
        }
    } else {
        let mut updated_by_kind: HashMap<ItemKind, Vec<String>> = HashMap::new();
        for (kind, _, name, old, new) in &changes {
            if old != new {
                updated_by_kind.entry(*kind).or_default().push(name.clone());
            }
        }
        for kind in [
            ItemKind::Agent,
            ItemKind::Skill,
            ItemKind::Hook,
            ItemKind::PiExtension,
        ] {
            if let Some(names) = updated_by_kind.get_mut(&kind) {
                names.sort();
                eprintln!("  ! {} updated: {}", kind.label_short(), names.join(", "));
            }
        }
    }

    if repaired_sources > 0 {
        eprintln!(
            "  Repaired {} lock entry source path(s) (previous source missing)",
            repaired_sources
        );
    }
    if renamed_pi_entries > 0 {
        eprintln!(
            "  Migrated {} Pi package lock entry name(s)",
            renamed_pi_entries
        );
    }

    let count_updated = |kind: ItemKind| -> usize {
        changes
            .iter()
            .filter(|(k, _, _, old, new)| *k == kind && old != new)
            .count()
    };
    eprintln!(
        "Processed {} agent(s) ({} updated), {} skill(s) ({} updated), {} hook(s) ({} updated), {} Pi package(s) ({} updated)",
        stats.agents_refreshed,
        count_updated(ItemKind::Agent),
        stats.skills_refreshed,
        count_updated(ItemKind::Skill),
        stats.hooks_refreshed,
        count_updated(ItemKind::Hook),
        stats.pi_refreshed,
        count_updated(ItemKind::PiExtension),
    );
    if stats.has_failures() {
        for failure in &stats.failures {
            let harness = failure
                .harness
                .as_ref()
                .map(|harness| format!(" ({harness})"))
                .unwrap_or_default();
            eprintln!("  ! {}{} — {}", failure.item, harness, failure.error);
        }
        anyhow::bail!(
            "failed to refresh {} item/harness install(s)",
            stats.failures.len()
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests;
