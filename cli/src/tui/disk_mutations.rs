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
}

impl DiskMutationReport {
    fn new(attempted: usize) -> Self {
        Self {
            attempted,
            completed: 0,
            failed: Vec::new(),
        }
    }

    fn fail(&mut self, item: &str, err: impl std::fmt::Display) {
        self.failed.push(format!("{item}: {err}"));
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

pub(super) fn perform_remove_plans(plans: &[RemovePlan]) -> DiskMutationReport {
    let mut report = DiskMutationReport::new(plans.len());
    for plan in plans {
        let mut removed_any = false;
        let mut failures = Vec::new();
        if plan.from_project {
            match remove_one(&plan.name, false) {
                Ok(removed) => removed_any |= removed,
                Err(err) => failures.push(format!("project scope: {err:#}")),
            }
        }
        if plan.from_global {
            match remove_one(&plan.name, true) {
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

fn remove_one(name: &str, scope_global: bool) -> anyhow::Result<bool> {
    let lock_path = config::lock_file_path(scope_global);
    let Ok(mut lock) = config::LockFile::load(&lock_path) else {
        return Ok(false);
    };
    let Some(entry) = lock.entries.get(name).cloned() else {
        return Ok(false);
    };
    if entry.kind == ItemKind::PiExtension {
        crate::pi_extension::remove_pi_extension(name, scope_global)?;
    } else {
        let harnesses: Vec<Harness> = entry
            .harnesses
            .iter()
            .filter_map(|h| Harness::from_id(h))
            .collect();
        crate::installer::remove_item(name, Some(entry.kind), &harnesses, scope_global)?;
    }
    lock.remove(name);
    lock.save(&lock_path)?;
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
    let mut dst_lock = config::LockFile::load(&dst_lock_path).unwrap_or_default();
    dst_lock.version = 1;

    let project_root = config::project_root();
    let mut project_config = crate::project_config::ProjectConfig::load(&project_root);

    let source_dir = source_dir_for_items(items);
    let mapping = source_dir
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
                        instr,
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
                match crate::pi_extension::install_pi_extension(ext, to_global) {
                    Ok(_) => {
                        // Pi packages aren't per-harness; mirror src list so the
                        // entry round-trips cleanly.
                        succeeded = target_harnesses.clone();
                    }
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
        match remove_one(name, from_global) {
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

pub(super) fn perform_inline_update(
    names: &[String],
    items: &DiscoveredItems,
) -> DiskMutationReport {
    let mut report = DiskMutationReport::new(names.len());
    let mut completed_names = std::collections::HashSet::new();
    let project_root = config::project_root();
    let source_dir = source_dir_for_items(items);
    let mapping = source_dir
        .map(crate::mapping::MappingConfig::load)
        .unwrap_or_default();

    for scope_global in [false, true] {
        let lock_path = config::lock_file_path(scope_global);
        let Ok(mut lock) = config::LockFile::load(&lock_path) else {
            continue;
        };
        if !names.iter().any(|n| lock.entries.contains_key(n)) {
            continue;
        }
        let updates_hooks = names.iter().any(|name| {
            lock.entries
                .get(name)
                .is_some_and(|entry| entry.kind == ItemKind::Hook)
        });

        let pruned = crate::commands::refresh::prune_hook_harnesses(
            scope_global,
            &mut lock,
            &items.hooks,
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

        let mut project_config = crate::project_config::ProjectConfig::load(&project_root);
        project_config.overlay_source_frontmatter(&mapping);

        let stats = crate::commands::refresh::refresh_items_in_scope(
            scope_global,
            &lock,
            &items.agents,
            &items.skills,
            &items.hooks,
            &items.pi_extensions,
            &mapping,
            &mut project_config,
            &project_root,
            Some(&refresh_names),
        );

        if !scope_global {
            stats.persist_upstream(&project_root);
        }

        let now = config::now_iso();
        for name in names {
            if let Some(entry) = lock.entries.get_mut(name) {
                entry.installed_at = now.clone();
                entry.source_hash = config::compute_source_hash(entry);
            }
        }
        match lock.save(&lock_path) {
            Ok(()) => {
                for name in names {
                    if lock.entries.contains_key(name) {
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

fn source_dir_for_items(items: &DiscoveredItems) -> Option<&std::path::Path> {
    items
        .agents
        .first()
        .and_then(|a| a.source_path.parent().and_then(|p| p.parent()))
        .or_else(|| items.skills.first().and_then(|s| s.source_dir.parent()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::{Agent, AgentRole};
    use crate::config::{InstallMethod, LockEntry, LockFile};
    use crate::mapping::{HookTarget, MappingConfig};
    use std::path::PathBuf;

    fn agent_fixture(name: &str) -> Agent {
        Agent {
            name: name.to_string(),
            description: format!("{name} agent"),
            model: "sonnet".into(),
            role: AgentRole::Engineer,
            color: None,
            effort: None,
            body: String::new(),
            source_path: PathBuf::new(),
        }
    }

    fn hook_fixture(name: &str, harnesses: Option<Vec<&str>>) -> crate::hook::Hook {
        crate::hook::Hook {
            name: name.into(),
            event: "PreToolUse".into(),
            matcher: Some("Bash".into()),
            description: String::new(),
            safety: None,
            timeout: None,
            harnesses: harnesses.map(|items| items.into_iter().map(String::from).collect()),
            script: String::new(),
            source_path: PathBuf::new(),
        }
    }

    fn codex_fallback_hook(name: &str) -> crate::hook::Hook {
        crate::hook::Hook {
            name: name.into(),
            event: "TaskCompleted".into(),
            matcher: None,
            description: "Complete task safely".into(),
            safety: Some("Check completion state.".into()),
            timeout: None,
            harnesses: Some(vec!["codex".into()]),
            script: String::new(),
            source_path: PathBuf::new(),
        }
    }

    fn agent_frontmatter(content: &str) -> &str {
        content
            .strip_prefix("---\n")
            .and_then(|rest| rest.split_once("\n---\n"))
            .map(|(frontmatter, _)| frontmatter)
            .expect("frontmatter present")
    }

    fn tmpdir(label: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock before epoch")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "vstack-disk-mutations-{label}-{}-{nanos}",
            std::process::id()
        ))
    }

    #[test]
    fn filter_harnesses_drops_cursor_when_moving_to_global() {
        // Regression: Cursor is project-only. A move-to-global plan must
        // not pretend it can land at global, otherwise the destination
        // lock entry would claim Cursor was installed there and the source
        // copy would be deleted with no working replacement on disk.
        let ids = vec!["cursor".to_string(), "claude-code".to_string()];

        let to_global = filter_harnesses_for_target(&ids, true);
        assert_eq!(to_global, vec![Harness::ClaudeCode]);

        let to_project = filter_harnesses_for_target(&ids, false);
        assert!(to_project.contains(&Harness::Cursor));
        assert!(to_project.contains(&Harness::ClaudeCode));
    }

    #[test]
    fn filter_harnesses_returns_empty_for_global_only_cursor_entry() {
        // If the only harness on a plan is project-only, the move target
        // has no eligible harness — perform_move_plans skips the plan and
        // leaves the source intact.
        let ids = vec!["cursor".to_string()];
        assert!(filter_harnesses_for_target(&ids, true).is_empty());
        assert_eq!(
            filter_harnesses_for_target(&ids, false),
            vec![Harness::Cursor]
        );
    }

    #[test]
    fn filter_harnesses_skips_unknown_ids() {
        let ids = vec!["claude-code".to_string(), "made-up-harness".to_string()];
        let result = filter_harnesses_for_target(&ids, true);
        assert_eq!(result, vec![Harness::ClaudeCode]);
    }

    #[test]
    fn hook_move_target_filter_respects_current_hook_allowlist() {
        let hook = hook_fixture("guard", Some(vec!["codex"]));
        let target_harnesses = vec![Harness::ClaudeCode, Harness::Codex];

        assert_eq!(
            filter_harnesses_for_hook_target(&hook, &target_harnesses),
            vec![Harness::Codex]
        );
        assert!(filter_harnesses_for_hook_target(&hook, &[Harness::ClaudeCode]).is_empty());
    }

    #[test]
    fn move_destination_hook_matching_uses_destination_harness_lock() {
        let mut dst_lock = LockFile::default();
        dst_lock.add(LockEntry {
            name: "guard".into(),
            kind: ItemKind::Hook,
            source: "source".into(),
            harnesses: vec!["claude-code".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        });
        let items = DiscoveredItems {
            agents: Vec::new(),
            skills: Vec::new(),
            hooks: vec![hook_fixture("guard", None)],
            pi_extensions: Vec::new(),
            extras: Vec::new(),
        };
        let mut mapping = MappingConfig::default();
        mapping
            .hook_events
            .insert("PreToolUse:Bash".into(), HookTarget::All("all".into()));
        let agent = agent_fixture("rust");

        assert_eq!(
            matched_hooks_for_move_destination(
                &dst_lock,
                &items,
                &mapping,
                &agent,
                Harness::ClaudeCode,
            )
            .len(),
            1
        );
        assert!(
            matched_hooks_for_move_destination(
                &dst_lock,
                &items,
                &mapping,
                &agent,
                Harness::Codex,
            )
            .is_empty()
        );
    }

    #[test]
    fn codex_hooks_are_reinstalled_for_newly_moved_agents() {
        let root = tmpdir("codex-moved-agent-hooks");
        let codex_home = root.join("codex");
        let agents_dir = codex_home.join("agents");
        std::fs::create_dir_all(&agents_dir).unwrap();
        std::fs::write(
            agents_dir.join("rust.toml"),
            "name = \"rust\"\ndeveloper_instructions = '''\nBody\n'''\n",
        )
        .unwrap();

        let mut dst_lock = LockFile::default();
        dst_lock.add(LockEntry {
            name: "finish-check".into(),
            kind: ItemKind::Hook,
            source: "source".into(),
            harnesses: vec!["codex".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        });
        let items = DiscoveredItems {
            agents: vec![agent_fixture("rust")],
            skills: Vec::new(),
            hooks: vec![codex_fallback_hook("finish-check")],
            pi_extensions: Vec::new(),
            extras: Vec::new(),
        };

        crate::test_util::with_codex_home(&codex_home, || {
            reinstall_codex_hooks_for_moved_agents(&items, &["rust".to_string()], true, &dst_lock)
                .unwrap();
        });

        let content = std::fs::read_to_string(agents_dir.join("rust.toml")).unwrap();
        assert!(content.contains("## Safety: finish-check"));
        assert!(content.contains("Check completion state."));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn generate_moved_agents_reports_when_no_harness_succeeds() {
        let mut dst_lock = LockFile::default();
        let entry = LockEntry {
            name: "rust".into(),
            kind: ItemKind::Agent,
            source: "source".into(),
            harnesses: vec!["cursor".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        };
        let intent = AgentMoveIntent {
            name: "rust".into(),
            entry,
            target_harnesses: vec![Harness::Cursor],
        };
        let items = DiscoveredItems {
            agents: vec![agent_fixture("rust")],
            skills: Vec::new(),
            hooks: Vec::new(),
            pi_extensions: Vec::new(),
            extras: Vec::new(),
        };
        let mut report = DiskMutationReport::new(1);

        let moved = generate_moved_agents(
            &items,
            &[intent],
            true,
            &mut dst_lock,
            &MappingConfig::default(),
            &crate::project_config::ProjectConfig::default(),
            &mut report,
        );

        assert!(moved.is_empty());
        assert!(!dst_lock.entries.contains_key("rust"));
        assert_eq!(report.failed.len(), 1);
        assert!(report.failed[0].contains("rust"));
        assert!(report.failed[0].contains("Cursor"));
    }

    #[test]
    fn inline_update_refreshes_hook_config_and_agents() {
        let root = tmpdir("inline-update-hook");
        let project = root.join("project");
        let source = root.join("source");
        std::fs::create_dir_all(source.join("agents")).unwrap();
        std::fs::create_dir_all(source.join("hooks")).unwrap();
        std::fs::create_dir_all(&project).unwrap();
        std::fs::write(
            source.join("vstack.toml"),
            "[hook-events]\n\"PostCompact:\" = \"all\"\n",
        )
        .unwrap();

        let mut agent = agent_fixture("rust");
        agent.source_path = source.join("agents/rust.md");
        let mut old_hook = hook_fixture("guard", None);
        old_hook.source_path = source.join("hooks/guard.sh");
        old_hook.script = "#!/usr/bin/env bash\nexit 0\n".into();
        let mut new_hook = old_hook.clone();
        new_hook.event = "PostCompact".into();
        new_hook.matcher = None;

        let mut lock = LockFile::default();
        lock.add(LockEntry {
            name: "rust".into(),
            kind: ItemKind::Agent,
            source: source.to_string_lossy().into_owned(),
            harnesses: vec!["claude-code".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        });
        lock.add(LockEntry {
            name: "guard".into(),
            kind: ItemKind::Hook,
            source: source.to_string_lossy().into_owned(),
            harnesses: vec!["claude-code".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        });
        lock.save(&project.join(".vstack-lock.json")).unwrap();

        let items = DiscoveredItems {
            agents: vec![agent.clone()],
            skills: Vec::new(),
            hooks: vec![new_hook],
            pi_extensions: Vec::new(),
            extras: Vec::new(),
        };

        crate::test_util::with_project_root(&project, || {
            crate::installer::install_hook(&old_hook, Harness::ClaudeCode, false, &[]).unwrap();
            Harness::ClaudeCode
                .generate_agent(
                    &agent,
                    false,
                    &[],
                    &[old_hook.clone()],
                    &crate::agent::AgentExtras::default(),
                )
                .unwrap();

            let report = perform_inline_update(&["guard".to_string()], &items);
            assert_eq!(report.completed, 1, "report: {report:?}");
            assert!(report.failed.is_empty(), "report: {report:?}");
        });

        let settings = std::fs::read_to_string(project.join(".claude/settings.json")).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&settings).unwrap();
        assert!(
            parsed.pointer("/hooks/PreToolUse").is_none(),
            "stale PreToolUse settings: {settings}"
        );
        assert!(
            parsed.pointer("/hooks/PostCompact").is_some(),
            "missing PostCompact settings: {settings}"
        );

        let agent_body = std::fs::read_to_string(project.join(".claude/agents/rust.md")).unwrap();
        let frontmatter: serde_json::Value = serde_yaml::from_str(agent_frontmatter(&agent_body))
            .expect("valid Claude frontmatter after inline update");
        assert!(frontmatter.pointer("/hooks/PreToolUse").is_none());
        assert!(frontmatter.pointer("/hooks/PostCompact").is_some());

        let _ = std::fs::remove_dir_all(root);
    }
}
