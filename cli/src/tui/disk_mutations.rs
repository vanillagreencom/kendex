use crate::agent::Agent;
use crate::config::{self, ItemKind};
use crate::harness::Harness;

use super::DiscoveredItems;
use super::multiselect::{MovePlan, RemovePlan};

#[derive(Clone, Debug, Default)]
pub(super) struct DiskMutationReport {
    pub attempted: usize,
    pub completed: usize,
    pub failed: Vec<String>,
    /// Non-failure information the user must still see (e.g. anchored
    /// canonicals left in another checkout). Collected here — never printed
    /// from the worker thread, which runs while the TUI owns the terminal
    /// in raw mode — and rendered by the main thread's flash line.
    pub notices: Vec<String>,
}

impl DiskMutationReport {
    fn new(attempted: usize) -> Self {
        Self {
            attempted,
            completed: 0,
            failed: Vec::new(),
            notices: Vec::new(),
        }
    }

    fn fail(&mut self, item: &str, err: impl std::fmt::Display) {
        self.failed.push(format!("{item}: {err}"));
    }

    /// Record an item that was deliberately not attempted. A skip is a
    /// notice, never a failure: it must not veto follow-up work gated on
    /// `failed` (the CLI update behind an "Update All"), and it leaves
    /// `attempted` so the completed/attempted ratio counts only real tries.
    fn skip(&mut self, item: &str, why: impl std::fmt::Display) {
        self.attempted = self.attempted.saturating_sub(1);
        self.notices.push(format!("skipped {item}: {why}"));
    }
}

/// Resolve a lock entry's harness id list to the set that actually supports
/// the move's destination scope. When moving to global, harnesses without
/// global support (currently just Cursor) are dropped — installing them at
/// global would either fail outright or silently skip, leaving the lock
/// entry claiming an install that never landed.
fn filter_harnesses_for_target(harness_ids: &[String], to_global: bool) -> Vec<Harness> {
    harness_ids
        .iter()
        .filter_map(|h| Harness::from_id(h))
        .filter(|h| !to_global || h.supports_global_scope())
        .collect()
}

fn filter_harnesses_for_hook_target(
    hook: &crate::hook::Hook,
    harnesses: &[Harness],
) -> Vec<Harness> {
    harnesses
        .iter()
        .copied()
        .filter(|harness| hook.applies_to(harness.id()))
        .collect()
}

fn rollback_destination_install(
    name: &str,
    kind: ItemKind,
    harnesses: &[Harness],
    scope_global: bool,
) -> String {
    if harnesses.is_empty() {
        return String::new();
    }
    match crate::installer::remove_item(name, Some(kind), harnesses, scope_global) {
        Ok(outcome) if outcome.anchored_left.is_empty() => String::new(),
        Ok(outcome) => format!(
            "; rollback left anchored canonical(s) in place (another checkout's): {}",
            outcome
                .anchored_left
                .iter()
                .map(|path| path.display().to_string())
                .collect::<Vec<_>>()
                .join(", ")
        ),
        Err(err) => format!("; rollback failed: {err:#}"),
    }
}

pub(super) fn perform_remove_plans(plans: &[RemovePlan]) -> DiskMutationReport {
    let mut report = DiskMutationReport::new(plans.len());
    for plan in plans {
        let mut removed_any = false;
        let mut failures = Vec::new();
        if plan.from_project {
            match remove_one(&plan.name, false, &mut report.notices) {
                Ok(removed) => removed_any |= removed,
                Err(err) => failures.push(format!("project scope: {err:#}")),
            }
        }
        if plan.from_global {
            match remove_one(&plan.name, true, &mut report.notices) {
                Ok(removed) => removed_any |= removed,
                Err(err) => failures.push(format!("global scope: {err:#}")),
            }
        }
        if failures.is_empty() {
            if removed_any {
                report.completed += 1;
            }
        } else {
            report.fail(&plan.name, failures.join("; "));
        }
    }
    report
}

fn remove_one(name: &str, scope_global: bool, notices: &mut Vec<String>) -> anyhow::Result<bool> {
    let lock_path = config::lock_file_path(scope_global);
    let mut lock = config::LockFile::load(&lock_path)
        .map_err(|err| anyhow::anyhow!("failed to load lock {}: {err:#}", lock_path.display()))?;
    let Some(entry) = lock.entries.get(name).cloned() else {
        return Ok(false);
    };
    let removed_hook_harnesses = (entry.kind == ItemKind::Hook).then(|| entry.harnesses.clone());
    let project_root = config::project_root();
    let mut project_config = if entry.kind == ItemKind::Hook {
        if scope_global {
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
    if entry.kind == ItemKind::PiExtension {
        crate::pi_extension::remove_pi_extension(name, scope_global)?;
    } else {
        let harnesses: Vec<Harness> = entry
            .harnesses
            .iter()
            .filter_map(|h| Harness::from_id(h))
            .collect();
        let outcome =
            crate::installer::remove_item(name, Some(entry.kind), &harnesses, scope_global)?;
        for anchored in &outcome.anchored_left {
            notices.push(format!(
                "{name}: anchored canonical left in place (another checkout's): {}",
                anchored.display()
            ));
        }
    }
    lock.remove(name);
    lock.save(&lock_path)?;
    if let Some(harnesses) = removed_hook_harnesses.as_deref() {
        crate::commands::refresh::regenerate_agents_after_hook_removal(
            scope_global,
            &lock,
            harnesses,
            project_config
                .as_mut()
                .expect("hook-removal config preloaded"),
            &project_root,
        )?;
    }
    Ok(true)
}

fn matched_hooks_for_move_destination(
    dst_lock: &config::LockFile,
    items: &DiscoveredItems,
    mapping: &crate::mapping::MappingConfig,
    agent: &Agent,
    harness: Harness,
) -> Vec<crate::hook::Hook> {
    crate::resolve::matched_installed_hooks_for_agent_harness(
        dst_lock,
        &items.hooks,
        mapping,
        &agent.role,
        harness.id(),
    )
}

#[derive(Clone)]
struct AgentMoveIntent {
    name: String,
    entry: config::LockEntry,
    target_harnesses: Vec<Harness>,
}

/// Move plans = install at the destination scope, then remove from the
/// source scope. Uses each item's existing source-scope lock entry to
/// preserve harness list and install method.
///
/// Safety: a plan's source scope is removed ONLY after at least one
/// destination harness install succeeded for that plan. If every install
/// fails (or every harness was filtered out as scope-incompatible), the
/// plan is skipped — the user keeps their working copy at the source scope
/// rather than losing it to a half-completed move. The destination lock
/// entry tracks the harnesses that actually succeeded, not the source's
/// original list.
pub(super) fn perform_move_plans(
    items: &DiscoveredItems,
    plans: &[MovePlan],
    to_global: bool,
) -> DiskMutationReport {
    let mut report = DiskMutationReport::new(plans.len());
    let from_global = !to_global;

    let src_lock_path = config::lock_file_path(from_global);
    let Ok(src_lock) = config::LockFile::load(&src_lock_path) else {
        for plan in plans {
            report.fail(&plan.name, "failed to load source lock");
        }
        return report;
    };
    let dst_lock_path = config::lock_file_path(to_global);
    let mut dst_lock = if dst_lock_path.exists() {
        match config::LockFile::load(&dst_lock_path) {
            Ok(lock) => lock,
            Err(err) => {
                for plan in plans {
                    report.fail(
                        &plan.name,
                        format!("failed to load destination lock: {err:#}"),
                    );
                }
                return report;
            }
        }
    } else {
        config::LockFile::default()
    };
    dst_lock.version = 1;

    let project_root = config::project_root();
    let mut project_config = crate::project_config::ProjectConfig::load(&project_root);

    let source_dir = source_dir_for_items(items);
    let mapping = source_dir
        .as_deref()
        .map(crate::mapping::MappingConfig::load)
        .unwrap_or_default();
    project_config.overlay_source_frontmatter(&mapping);

    // Plans that succeeded at the destination — only these are eligible
    // for source removal at the end.
    let mut moved_names: Vec<String> = Vec::new();
    let mut agent_intents: Vec<AgentMoveIntent> = Vec::new();

    for plan in plans {
        let Some(entry) = src_lock.entries.get(&plan.name).cloned() else {
            report.fail(&plan.name, "source lock entry not found");
            continue;
        };
        // Cursor (project-only) silently dropped from a move-to-global
        // would leave a lock entry claiming it was installed there.
        let target_harnesses = filter_harnesses_for_target(&entry.harnesses, to_global);
        if target_harnesses.is_empty() {
            // Nothing can be moved for this item — keep the source in place.
            report.fail(&plan.name, "no destination harness supports target scope");
            continue;
        }

        let mut succeeded: Vec<Harness> = Vec::new();
        let mut install_failures = Vec::new();
        match entry.kind {
            ItemKind::Agent => {
                if items.agents.iter().any(|a| a.name == plan.name) {
                    agent_intents.push(AgentMoveIntent {
                        name: plan.name.clone(),
                        entry,
                        target_harnesses,
                    });
                } else {
                    report.fail(&plan.name, "source agent not found");
                }
                continue;
            }
            ItemKind::Skill => {
                let Some(skill) = items.skills.iter().find(|s| s.name == plan.name) else {
                    report.fail(&plan.name, "source skill not found");
                    continue;
                };
                let instr = project_config.skill_instructions_for(&skill.name);
                for harness in &target_harnesses {
                    match crate::installer::install_skill(
                        skill,
                        *harness,
                        to_global,
                        entry.method,
                        instr.as_deref(),
                    ) {
                        Ok(_) => succeeded.push(*harness),
                        Err(err) => install_failures.push(format!("{}: {err:#}", harness.name())),
                    }
                }
            }
            ItemKind::Hook => {
                let Some(hook) = crate::resolve::source_hook_for_lock_entry(&items.hooks, &entry)
                else {
                    report.fail(&plan.name, "source hook not found");
                    continue;
                };
                let target_harnesses = filter_harnesses_for_hook_target(hook, &target_harnesses);
                if target_harnesses.is_empty() {
                    // Source hook allowlist no longer includes any destination
                    // harness. Treat as no move so source stays tracked until
                    // refresh/prune removes it intentionally.
                    report.fail(&plan.name, "hook allowlist excludes destination harnesses");
                    continue;
                }
                let agents_for_hook: Vec<Agent> = items
                    .agents
                    .iter()
                    .filter(|a| {
                        dst_lock
                            .entries
                            .get(&a.name)
                            .is_some_and(|e| e.kind == ItemKind::Agent)
                    })
                    .cloned()
                    .collect();
                for harness in &target_harnesses {
                    match crate::installer::install_hook(
                        hook,
                        *harness,
                        to_global,
                        &agents_for_hook,
                    ) {
                        Ok(_) => succeeded.push(*harness),
                        Err(err) => install_failures.push(format!("{}: {err:#}", harness.name())),
                    }
                }
            }
            ItemKind::PiExtension => {
                let Some(ext) = items.pi_extensions.iter().find(|e| e.name == plan.name) else {
                    report.fail(&plan.name, "source Pi package not found");
                    continue;
                };
                match crate::pi_extension::install_pi_extension_for_move(ext, to_global) {
                    Ok(Some(_)) => {
                        // Pi packages aren't per-harness; mirror src list so the
                        // entry round-trips cleanly.
                        succeeded = target_harnesses.clone();
                    }
                    Ok(None) => install_failures.push(
                        "Pi: destination install skipped (package already installed)".to_string(),
                    ),
                    Err(err) => install_failures.push(format!("Pi: {err:#}")),
                }
            }
            ItemKind::Extra => {}
        }

        if succeeded.is_empty() {
            // Every destination install failed. Don't remove the source.
            let reason = if install_failures.is_empty() {
                "no destination install succeeded".to_string()
            } else {
                install_failures.join("; ")
            };
            report.fail(&plan.name, reason);
            continue;
        }
        if !install_failures.is_empty() {
            let rollback =
                rollback_destination_install(&plan.name, entry.kind, &succeeded, to_global);
            report.fail(
                &plan.name,
                format!(
                    "partial destination failure: {}{}",
                    install_failures.join("; "),
                    rollback
                ),
            );
            continue;
        }

        let mut new_entry = entry.clone();
        new_entry.harnesses = succeeded.iter().map(|h| h.id().to_string()).collect();
        new_entry.installed_at = config::now_iso();
        new_entry.source_hash = config::compute_source_hash(&new_entry);
        dst_lock.add(new_entry);
        moved_names.push(plan.name.clone());
    }

    let moved_agent_names = generate_moved_agents(
        items,
        &agent_intents,
        to_global,
        &mut dst_lock,
        &mapping,
        &project_config,
        &mut report,
    );
    if let Err(err) =
        reinstall_codex_hooks_for_moved_agents(items, &moved_agent_names, to_global, &dst_lock)
    {
        for name in moved_agent_names {
            report.fail(
                &name,
                format!("failed to install Codex hook prose: {err:#}"),
            );
        }
        return report;
    }
    moved_names.extend(moved_agent_names);

    if let Err(err) = dst_lock.save(&dst_lock_path) {
        // Couldn't persist the destination lock. Don't remove anything at
        // the source — the install succeeded on disk but we couldn't
        // record it, so leaving the source intact lets a retry recover.
        for name in moved_names {
            report.fail(&name, format!("failed to save destination lock: {err:#}"));
        }
        return report;
    }

    // Remove files + lock entries at the source scope only for items that
    // actually made it to the destination.
    for name in &moved_names {
        match remove_one(name, from_global, &mut report.notices) {
            Ok(true) => report.completed += 1,
            Ok(false) => report.fail(name, "source lock entry missing after destination install"),
            Err(err) => report.fail(name, format!("failed to remove source install: {err:#}")),
        }
    }
    report
}

fn generate_moved_agents(
    items: &DiscoveredItems,
    intents: &[AgentMoveIntent],
    to_global: bool,
    dst_lock: &mut config::LockFile,
    mapping: &crate::mapping::MappingConfig,
    project_config: &crate::project_config::ProjectConfig,
    report: &mut DiskMutationReport,
) -> Vec<String> {
    let installed_skills_final: Vec<String> = dst_lock
        .entries
        .iter()
        .filter(|(_, e)| e.kind == ItemKind::Skill)
        .map(|(n, _)| n.clone())
        .collect();
    let mut moved_names = Vec::new();

    for intent in intents {
        if let Err(err) = crate::path_safety::validate_new_item_name(&intent.name) {
            report.fail(&intent.name, format!("invalid agent name: {err:#}"));
            continue;
        }
        let Some(agent) = items.agents.iter().find(|a| a.name == intent.name) else {
            report.fail(&intent.name, "source agent missing");
            continue;
        };
        let source_skills =
            mapping.skills_for_agent(&agent.name, &agent.role, &installed_skills_final);
        let skill_pairs = crate::resolve::resolve_skill_pairs(&source_skills, &items.skills);
        let extras =
            crate::resolve::build_agent_extras(project_config, &agent.name, &agent.role, None);
        let mut succeeded = Vec::new();
        let mut failures = Vec::new();
        for harness in &intent.target_harnesses {
            let matched_hooks =
                matched_hooks_for_move_destination(dst_lock, items, mapping, agent, *harness);
            match harness.generate_agent(agent, to_global, &skill_pairs, &matched_hooks, &extras) {
                Ok(_) => succeeded.push(*harness),
                Err(err) => failures.push(format!("{}: {err:#}", harness.name())),
            }
        }
        if succeeded.is_empty() {
            if failures.is_empty() {
                report.fail(&intent.name, "no destination harnesses available");
            } else {
                report.fail(
                    &intent.name,
                    format!(
                        "failed to generate destination agent: {}",
                        failures.join("; ")
                    ),
                );
            }
            continue;
        }
        if !failures.is_empty() {
            let rollback =
                rollback_destination_install(&intent.name, ItemKind::Agent, &succeeded, to_global);
            report.fail(
                &intent.name,
                format!(
                    "partial destination failure: {}{}",
                    failures.join("; "),
                    rollback
                ),
            );
            continue;
        }

        let mut new_entry = intent.entry.clone();
        new_entry.harnesses = succeeded.iter().map(|h| h.id().to_string()).collect();
        new_entry.installed_at = config::now_iso();
        new_entry.source_hash = config::compute_source_hash(&new_entry);
        dst_lock.add(new_entry);
        moved_names.push(intent.name.clone());
    }

    moved_names
}

fn reinstall_codex_hooks_for_moved_agents(
    items: &DiscoveredItems,
    moved_agent_names: &[String],
    to_global: bool,
    dst_lock: &config::LockFile,
) -> anyhow::Result<()> {
    if moved_agent_names.is_empty() {
        return Ok(());
    }
    let moved_agents: Vec<Agent> = items
        .agents
        .iter()
        .filter(|agent| moved_agent_names.iter().any(|name| name == &agent.name))
        .cloned()
        .collect();
    if moved_agents.is_empty() {
        return Ok(());
    }

    let fallback_hooks = crate::resolve::installed_codex_fallback_hooks(dst_lock, &items.hooks);
    crate::installer::install_codex_fallback_hooks_for_agents(
        &fallback_hooks,
        to_global,
        &moved_agents,
    )?;

    Ok(())
}

/// Refresh the named installs in place, each from its own recorded source.
///
/// Sources are resolved per scope from that scope's lock, exactly as
/// `vstack refresh` does — never from whichever source the picker has
/// selected — so an entry recorded from any source refreshes.
pub(super) fn perform_inline_update(names: &[String]) -> DiskMutationReport {
    let mut report = DiskMutationReport::new(names.len());
    let mut completed_names = std::collections::HashSet::new();
    let mut extras_reported = std::collections::HashSet::new();
    let project_root = config::project_root();

    for scope_global in [false, true] {
        let lock_path = config::lock_file_path(scope_global);
        let Ok(mut lock) = config::LockFile::load(&lock_path) else {
            continue;
        };
        // Extras are applied, not installed: the refresh pass has no branch
        // for them, so a requested extra would count as neither done nor
        // failed. Skip it with a notice — not a failure: a failure would
        // veto the CLI update queued behind the same "Update All", and a
        // stale extra stays stale until re-applied, so it would veto every
        // one after it too.
        let is_extra = |name: &String| {
            lock.entries
                .get(name)
                .is_some_and(|entry| entry.kind == ItemKind::Extra)
        };
        for name in names.iter().filter(|name| is_extra(name)) {
            if extras_reported.insert(name.clone()) {
                report.skip(
                    name,
                    format!("extras are reapplied with `vstack apply {name}`"),
                );
            }
        }
        let names: Vec<String> = names
            .iter()
            .filter(|name| !is_extra(name))
            .cloned()
            .collect();
        let names = names.as_slice();
        if !names.iter().any(|n| lock.entries.contains_key(n)) {
            continue;
        }
        let mut project_config = if scope_global {
            crate::project_config::ProjectConfig::load(&project_root)
        } else {
            match crate::project_config::ProjectConfig::load_strict(&project_root) {
                Ok(config) => config,
                Err(err) => {
                    for name in names {
                        if lock.entries.contains_key(name) {
                            report.fail(name, format!("failed to load project config: {err:#}"));
                        }
                    }
                    continue;
                }
            }
        };
        if !scope_global
            && let Err(err) = crate::commands::refresh::preflight_project_refresh(&project_root)
        {
            for name in names {
                if lock.entries.contains_key(name) {
                    report.fail(name, format!("failed project refresh preflight: {err:#}"));
                }
            }
            continue;
        }
        let updates_hooks = names.iter().any(|name| {
            lock.entries
                .get(name)
                .is_some_and(|entry| entry.kind == ItemKind::Hook)
        });

        let source_records = crate::refresh_sources::resolve_source_records(&lock);
        let sources = crate::refresh_sources::load_refresh_sources(&source_records.sources);
        let source_hooks = crate::refresh_sources::all_source_hooks(&sources);

        let pruned = crate::commands::refresh::prune_hook_harnesses(
            scope_global,
            &mut lock,
            &source_hooks,
            Some(names),
        );
        if pruned && let Err(err) = lock.save(&lock_path) {
            for name in names {
                if lock.entries.contains_key(name) {
                    report.fail(name, format!("failed to save pruned lock: {err:#}"));
                }
            }
            continue;
        }
        let refresh_names: Vec<String> = if updates_hooks {
            let mut expanded = names.to_vec();
            for (name, entry) in &lock.entries {
                if entry.kind == ItemKind::Agent && !expanded.contains(name) {
                    expanded.push(name.clone());
                }
            }
            expanded
        } else {
            names.to_vec()
        };

        let stats = crate::commands::refresh::refresh_items_in_scope(
            scope_global,
            &lock,
            &sources,
            &mut project_config,
            &project_root,
            Some(&refresh_names),
            &source_records.refused,
        );

        if !scope_global {
            stats.persist_upstream(&project_root);
        }
        for failure in &stats.failures {
            let harness = failure
                .harness
                .as_ref()
                .map(|harness| format!(" ({harness})"))
                .unwrap_or_default();
            report.fail(
                &failure.item,
                format!("refresh failed{harness}: {}", failure.error),
            );
        }
        // An entry whose source is gone (or no longer carries it) is not
        // refreshed; without this it would count as neither done nor failed
        // and the flash would read "Updated 0 item(s)". Agents the hook
        // update pulled in on its own are named as such — the user never
        // asked for them, but their stale payload is a real outcome.
        for (item, reason) in &stats.missing {
            if names.contains(item) {
                report.fail(item, format!("not refreshed: {reason}"));
            } else {
                report.fail(
                    item,
                    format!("agent not regenerated after hook update: {reason}"),
                );
            }
        }

        let now = config::now_iso();
        for (name, entry) in lock.entries.iter_mut() {
            if stats.successful_items.contains(name) {
                crate::commands::refresh::sync_lock_entry_source_repo(
                    &source_records.sources,
                    entry,
                );
                entry.installed_at = now.clone();
                entry.source_hash = config::compute_source_hash(entry);
            }
        }
        match lock.save(&lock_path) {
            Ok(()) => {
                for name in names {
                    if lock.entries.contains_key(name) && stats.successful_items.contains(name) {
                        completed_names.insert(name.clone());
                    }
                }
            }
            Err(err) => {
                for name in names {
                    if lock.entries.contains_key(name) {
                        report.fail(name, format!("failed to save refreshed lock: {err:#}"));
                    }
                }
            }
        }
    }
    report.completed = completed_names.len();
    report
}

fn source_dir_for_items(items: &DiscoveredItems) -> Option<std::path::PathBuf> {
    fn item_path(items: &DiscoveredItems) -> Option<&std::path::Path> {
        items
            .agents
            .first()
            .map(|agent| agent.source_path.as_path())
            .or_else(|| items.skills.first().map(|skill| skill.source_dir.as_path()))
            .or_else(|| items.hooks.first().map(|hook| hook.source_path.as_path()))
            .or_else(|| {
                items
                    .pi_extensions
                    .first()
                    .map(|extension| extension.source_dir.as_path())
            })
            .or_else(|| items.extras.first().map(|extra| extra.source_dir.as_path()))
    }

    if let Some(path) = item_path(items)
        && let Some(root) = crate::catalog::find_source_root_for_item_path(path)
    {
        return Some(root);
    }

    if let Some(path) = items
        .agents
        .first()
        .and_then(|a| a.source_path.parent().and_then(|p| p.parent()))
    {
        return Some(path.to_path_buf());
    }
    if let Some(path) = items.skills.first().and_then(|s| s.source_dir.parent()) {
        return Some(path.to_path_buf());
    }
    if let Some(path) = items
        .hooks
        .first()
        .and_then(|h| h.source_path.parent().and_then(|p| p.parent()))
    {
        return Some(path.to_path_buf());
    }
    if let Some(path) = items
        .pi_extensions
        .first()
        .and_then(|e| e.source_dir.parent())
    {
        return Some(path.to_path_buf());
    }
    None
}

#[cfg(test)]
mod tests;
