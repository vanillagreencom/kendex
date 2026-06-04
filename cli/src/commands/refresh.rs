use crate::agent::Agent;
use crate::config::{self, ItemKind};
use crate::harness::Harness;
use crate::hook::Hook;
use crate::installer;
use crate::mapping::MappingConfig;
use crate::pi_extension::PiExtension;
use crate::project_config::ProjectConfig;
use crate::skill::Skill;
use anyhow::Result;

fn source_pi_extension_for_lock_name<'a>(
    pi_extensions: &'a [PiExtension],
    name: &str,
) -> Option<&'a PiExtension> {
    pi_extensions.iter().find(|e| e.name == name).or_else(|| {
        pi_extensions
            .iter()
            .find(|e| crate::pi_extension::legacy_names_for(&e.name).contains(&name))
    })
}
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Result counts from one invocation of [`refresh_items_in_scope`].
#[derive(Default)]
pub struct RefreshStats {
    pub agents_refreshed: usize,
    pub skills_refreshed: usize,
    pub hooks_refreshed: usize,
    pub pi_refreshed: usize,
    /// Map of agent_name → (full merged required-skills list, newly added skill names).
    pub upstream_skill_updates: HashMap<String, (Vec<String>, Vec<String>)>,
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
/// helper. Caller is responsible for: source discovery (filling in
/// `agents`/`skills`/`hooks`/`pi_extensions` and `mapping`), project-config
/// loading, lock loading, lock-disk reconciliation, and writing the
/// upstream-additions back to disk via
/// [`crate::project_config::merge_upstream_agent_skills`].
#[allow(clippy::too_many_arguments)]
pub fn refresh_items_in_scope(
    global: bool,
    lock: &config::LockFile,
    agents: &[Agent],
    skills: &[Skill],
    hooks: &[Hook],
    pi_extensions: &[PiExtension],
    mapping: &MappingConfig,
    project_config: &mut ProjectConfig,
    project_root: &Path,
    name_filter: Option<&[String]>,
) -> RefreshStats {
    let mut stats = RefreshStats::default();
    let pass = |name: &str| name_filter.is_none_or(|f| f.iter().any(|n| n == name));

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

    let installed_hook_names: std::collections::HashSet<String> = lock
        .entries
        .iter()
        .filter(|(_, e)| e.kind == ItemKind::Hook)
        .map(|(name, _)| name.clone())
        .collect();

    let installed_hooks: Vec<Hook> = hooks
        .iter()
        .filter(|h| installed_hook_names.contains(&h.name))
        .cloned()
        .collect();

    // ── Agents ───────────────────────────────────────────────
    for (name, entry) in lock
        .entries
        .iter()
        .filter(|(_, e)| e.kind == ItemKind::Agent)
        .filter(|(n, _)| pass(n))
    {
        let Some(agent) = agents.iter().find(|a| &a.name == name) else {
            if name_filter.is_none() {
                eprintln!("  ! {} — source not found, skipped", name);
            }
            continue;
        };

        // Required skills: project list (if present) merged with source additions.
        let source_skills = mapping.skills_for_agent(&agent.name, &agent.role, &installed_skills);
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

        let skill_pairs = crate::resolve::resolve_skill_pairs(&skill_names, skills);

        let matched_hooks: Vec<Hook> = mapping
            .hooks_for_agent(&agent.role, &installed_hooks)
            .into_iter()
            .cloned()
            .collect();

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

        let extras =
            crate::resolve::build_agent_extras(project_config, &agent.name, &agent.role, None);

        for harness_id in &entry.harnesses {
            if let Some(harness) = Harness::from_id(harness_id) {
                let _ =
                    harness.generate_agent(agent, global, &skill_pairs, &matched_hooks, &extras);
            }
        }
        stats.agents_refreshed += 1;
    }

    // ── Skills ───────────────────────────────────────────────
    for (name, entry) in lock
        .entries
        .iter()
        .filter(|(_, e)| e.kind == ItemKind::Skill)
        .filter(|(n, _)| pass(n))
    {
        let Some(skill) = skills.iter().find(|s| &s.name == name) else {
            continue;
        };

        for harness_id in &entry.harnesses {
            if let Some(harness) = Harness::from_id(harness_id) {
                let skill_instr = project_config.skill_instructions_for(&skill.name);
                let _ = installer::install_skill(skill, harness, global, entry.method, skill_instr);
            }
        }
        stats.skills_refreshed += 1;
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
        .filter_map(|(name, _)| agents.iter().find(|a| &a.name == name).cloned())
        .collect();

    for (name, entry) in lock
        .entries
        .iter()
        .filter(|(_, e)| e.kind == ItemKind::Hook)
        .filter(|(n, _)| pass(n))
    {
        let Some(hook) = hooks.iter().find(|h| &h.name == name) else {
            continue;
        };
        for harness_id in &entry.harnesses {
            if !hook.applies_to(harness_id) {
                continue;
            }
            if let Some(harness) = Harness::from_id(harness_id) {
                let _ = installer::install_hook(hook, harness, global, &agent_entries);
            }
        }
        stats.hooks_refreshed += 1;
    }

    // ── Pi packages ──────────────────────────────────────
    for (name, _) in lock
        .entries
        .iter()
        .filter(|(_, e)| e.kind == ItemKind::PiExtension)
        .filter(|(n, _)| pass(n))
    {
        let Some(ext) = source_pi_extension_for_lock_name(pi_extensions, name) else {
            continue;
        };
        let _ = crate::pi_extension::install_pi_extension(ext, global);
        stats.pi_refreshed += 1;
    }

    stats
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

    // Self-heal hook lock entries: drop harness ids the hook no longer
    // applies to (the `harnesses:` allowlist in source may have changed
    // since install). Done up-front so all downstream passes see the
    // pruned state.
    {
        let source_hooks_for_prune: Vec<crate::hook::Hook> = resolve_sources(&lock)
            .iter()
            .flat_map(|dir| crate::hook::discover_hooks(&dir.join("hooks")).unwrap_or_default())
            .collect();
        let mut pruned_any = false;
        for entry in lock
            .entries
            .values_mut()
            .filter(|e| e.kind == ItemKind::Hook)
        {
            let Some(hook) = source_hooks_for_prune.iter().find(|h| h.name == entry.name) else {
                continue;
            };
            let new_harnesses: Vec<String> = entry
                .harnesses
                .iter()
                .filter(|h| hook.applies_to(h))
                .cloned()
                .collect();
            if new_harnesses != entry.harnesses {
                entry.harnesses = new_harnesses;
                pruned_any = true;
            }
        }
        if pruned_any {
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

    // After mapping is loaded below we overlay its frontmatter defaults so
    // source-level `[agent-frontmatter.<harness>]` entries feed regeneration.

    // Resolve source directories from lock file entries
    let source_dirs = resolve_sources(&lock);
    if source_dirs.is_empty() {
        eprintln!("Could not locate any package sources. Run `vstack add` to reinstall.");
        return Ok(());
    }

    // Aggregate source data from all resolved sources
    let mut all_source_agents = Vec::new();
    let mut all_source_skills = Vec::new();
    let mut all_source_hooks = Vec::new();
    let mut mapping = crate::mapping::MappingConfig::default();

    for dir in &source_dirs {
        mapping = crate::mapping::MappingConfig::load(dir);
        all_source_agents
            .extend(crate::agent::discover_agents(&dir.join("agents")).unwrap_or_default());
        all_source_skills
            .extend(crate::skill::discover_skills(&dir.join("skills")).unwrap_or_default());
        all_source_hooks
            .extend(crate::hook::discover_hooks(&dir.join("hooks")).unwrap_or_default());
    }

    let mut all_pi_extensions = Vec::new();
    for dir in &source_dirs {
        all_pi_extensions.extend(
            crate::pi_extension::discover_pi_extensions(&dir.join("pi-extensions"))
                .unwrap_or_default(),
        );
    }

    if !global {
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
        let installed_agents: Vec<Agent> = all_source_agents
            .iter()
            .filter(|agent| lock.entries.contains_key(&agent.name))
            .cloned()
            .collect();
        crate::project_config::write_agent_frontmatter_defaults(
            &project_root,
            &installed_agents,
            &harnesses_by_agent,
            &mapping,
        );
        project_config = crate::project_config::ProjectConfig::load(&project_root);
    }
    project_config.overlay_source_frontmatter(&mapping);

    let stats = refresh_items_in_scope(
        global,
        &lock,
        &all_source_agents,
        &all_source_skills,
        &all_source_hooks,
        &all_pi_extensions,
        &mapping,
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
        if resolve_single_source(&entry.source).is_none()
            && let Some(replacement) = &fallback_source
            && &entry.source != replacement
        {
            entry.source = replacement.clone();
            repaired_sources += 1;
        }
        let old_hash = entry.source_hash.clone();
        entry.installed_at = now.clone();
        entry.source_hash = config::compute_source_hash(entry);
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
    Ok(())
}

/// Resolve source directories from lock file entries.
/// Handles local paths, "." (walks up from CWD), and remote shorthand (cached clones).
fn resolve_sources(lock: &config::LockFile) -> Vec<PathBuf> {
    let mut sources: Vec<PathBuf> = Vec::new();
    let mut seen = std::collections::HashSet::new();

    for entry in lock.entries.values() {
        if seen.contains(&entry.source) {
            continue;
        }
        seen.insert(entry.source.clone());

        if let Some(dir) = resolve_single_source(&entry.source)
            && !sources.contains(&dir)
        {
            sources.push(dir);
        }
    }

    // Fallback: walk up from CWD to find a vstack source repo
    if sources.is_empty()
        && let Ok(mut dir) = std::env::current_dir()
    {
        loop {
            if crate::resolve::is_vstack_source(&dir) {
                sources.push(dir);
                break;
            }
            if !dir.pop() {
                break;
            }
        }
    }

    // Fallback: try the source registry (cached remote repos)
    if sources.is_empty() {
        let reg_path = config::source_registry_path();
        if let Ok(registry) = config::SourceRegistry::load(&reg_path) {
            for entry in registry.current.iter().chain(registry.entries.iter()) {
                if let Some(dir) = resolve_single_source(entry)
                    && !sources.contains(&dir)
                {
                    sources.push(dir);
                }
            }
        }
    }

    sources
}

fn resolve_single_source(source: &str) -> Option<PathBuf> {
    // Absolute or relative path that exists
    let p = std::path::Path::new(source);
    if p.is_absolute() && p.is_dir() && crate::resolve::is_vstack_source(p) {
        return Some(p.to_path_buf());
    }

    // "." — walk up from CWD
    if source == "." {
        let mut dir = std::env::current_dir().ok()?;
        loop {
            if crate::resolve::is_vstack_source(&dir) {
                return Some(dir);
            }
            if !dir.pop() {
                break;
            }
        }
        return None;
    }

    // Remote shorthand (owner/repo) — update and use cached clone
    let cache_dir = config::global_base_dir().join(".vstack").join("cache");
    let key = source.replace('/', "_");
    let cached = cache_dir.join(&key);
    if cached.join(".git").exists() {
        update_cached_repo(&cached);
        return Some(cached);
    }

    None
}

/// Pull latest changes for a cached remote repo.
fn update_cached_repo(repo_dir: &std::path::Path) {
    eprintln!("Updating cached repo...");
    let fetch = std::process::Command::new("git")
        .args(["fetch", "origin", "--quiet"])
        .current_dir(repo_dir)
        .status();
    match fetch {
        Ok(s) if s.success() => {
            let reset = std::process::Command::new("git")
                .args(["reset", "--hard", "origin/HEAD"])
                .current_dir(repo_dir)
                .stderr(std::process::Stdio::null())
                .status();
            if !reset.is_ok_and(|s| s.success()) {
                eprintln!("  Warning: git reset failed — cached repo may be stale");
            }
        }
        Ok(_) => eprintln!("  Warning: git fetch failed — using cached version"),
        Err(_) => eprintln!("  Warning: git not available — using cached version"),
    }
}
