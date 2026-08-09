use crate::agent::Agent;
use crate::config::{self, ItemKind};
use crate::harness::Harness;
use crate::hook::Hook;
use crate::installer;
use crate::project_config::ProjectConfig;
use crate::refresh_sources::{
    RefreshSource, ResolvedSource, all_source_hooks, all_source_pi_extensions,
    load_refresh_sources, refresh_source_for_entry, resolve_skill_pairs_from_sources,
    resolve_source_records, source_pi_extension_for_lock_name,
};
use crate::skill::Skill;
use anyhow::Result;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

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
    /// Names of items whose generated/installed on-disk content actually
    /// changed during this refresh. Distinct from source-hash equality: an
    /// agent re-renders when the installed skill set (or injected project
    /// instructions) changes even though the agent's own source hash is
    /// unchanged, and a rendered skill can differ from its source via injected
    /// instructions/notice. Tracked for agents and skills (the artifacts that
    /// derive from external state); hooks and Pi packages rely on source-hash
    /// equality alone.
    pub content_changed: HashSet<String>,
    /// Canonical project-owned skills managed through `[skill-instructions]`
    /// despite having no vstack lock entry or upstream package source.
    pub project_owned_skills: HashSet<String>,
    /// Locked items that could not be refreshed because their source is gone
    /// or no longer carries the asset, mapped to the reason. Tracked
    /// separately from [`Self::failures`] (a failed install attempt) so the
    /// report can never fall through to "unchanged" with the stored hash —
    /// that silently masked an entry whose source had stopped providing it.
    pub missing: BTreeMap<String, String>,
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

    fn mark_content_changed(&mut self, name: &str) {
        self.content_changed.insert(name.to_string());
    }

    fn fail(&mut self, item: &str, harness: Option<Harness>, err: impl std::fmt::Display) {
        self.failures.push(RefreshFailure {
            item: item.to_string(),
            harness: harness.map(|harness| harness.name().to_string()),
            error: err.to_string(),
        });
    }

    /// Record that `item` has no asset to refresh from. `source` is the source
    /// root it resolved to, or `None` when no source resolved at all.
    fn mark_missing(&mut self, item: &str, source: Option<&Path>) {
        let reason = match source {
            Some(root) => format!("not found in source {}", root.display()),
            None => "source not found".to_string(),
        };
        self.missing.insert(item.to_string(), reason);
    }

    pub fn has_failures(&self) -> bool {
        !self.failures.is_empty()
    }

    pub fn has_missing(&self) -> bool {
        !self.missing.is_empty()
    }

    /// Record an entry whose harness list produced no install attempt at all
    /// (empty list, or ids this binary does not recognize / the hook does not
    /// apply to). Without this the entry fell through its refresh pass with no
    /// success, no failure, and no missing state, and the summary echoed the
    /// recorded source hash as both old and new — "(unchanged)" for an entry
    /// that was never re-copied from its source (VST-134).
    fn fail_no_installable_harness(&mut self, item: &str, harnesses: &[String]) {
        self.fail(
            item,
            None,
            format!(
                "no installable harness (recorded harnesses: [{}]); \
                 re-add the item or run `vstack remove` to drop the stale entry",
                harnesses.join(", ")
            ),
        );
    }
}

/// Content hash of an installed skill directory, resolving a symlinked install
/// dir to its canonical target and skipping the volatile `.vstack-refreshed`
/// marker (its per-process PID payload changes every run). Returned value is
/// only ever compared before-vs-after within a single refresh, so the absolute
/// value is irrelevant.
fn hash_installed_skill_dir(path: &Path) -> u64 {
    let resolved = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    config::hash_dir_bytes_excluding(&resolved, &[".vstack-refreshed"])
}

fn same_path(a: &Path, b: &Path) -> bool {
    a.canonicalize().unwrap_or_else(|_| a.to_path_buf())
        == b.canonicalize().unwrap_or_else(|_| b.to_path_buf())
}

fn observed_source_repo_for_lock_entry(
    source_records: &[ResolvedSource],
    entry: &config::LockEntry,
) -> Option<Option<String>> {
    if let Some(record) = source_records.iter().find(|source| {
        source.aliases.iter().any(|alias| alias == &entry.source)
            || (Path::new(&entry.source).is_absolute()
                && same_path(&source.root, Path::new(&entry.source)))
    }) {
        return Some(record.source_repo.clone());
    }
    if let Some(source_root) = config::resolve_source_path(&entry.source) {
        return Some(config::source_repo_for_source(
            Some(&source_root),
            &entry.source,
        ));
    }
    config::parse_github_slug(&entry.source).map(Some)
}

fn sync_lock_entry_source_repo(source_records: &[ResolvedSource], entry: &mut config::LockEntry) {
    if let Some(source_repo) = observed_source_repo_for_lock_entry(source_records, entry) {
        entry.source_repo = source_repo;
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

    let project_owned_skills_root = if global {
        None
    } else {
        match resolve_project_owned_skills_root(project_root) {
            Ok(root) => root,
            Err(err) => {
                stats.fail(".agents/skills", None, err);
                return stats;
            }
        }
    };

    let relocated_project_skills = if global {
        None
    } else {
        match resolve_relocated_project_skills(project_root, project_config) {
            Ok(relocated) => relocated,
            Err(err) => {
                stats.fail("project-skills-dir", None, err);
                return stats;
            }
        }
    };

    if let Some(skills_root) = project_owned_skills_root.as_ref() {
        // Link first, so the instruction pass below sees the links it manages.
        if let Some(relocated) = relocated_project_skills.as_ref() {
            link_relocated_project_skills(skills_root, relocated, &pass, &mut stats);
        }
        refresh_project_owned_skill_instructions(
            lock,
            project_config,
            skills_root,
            relocated_project_skills.as_ref(),
            &pass,
            &mut stats,
        );
    }

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
        if let Err(err) = crate::path_safety::validate_item_name(name) {
            stats.fail(name, None, format!("invalid agent name: {err:#}"));
            continue;
        }
        let Some(source) = refresh_source_for_entry(sources, entry) else {
            stats.mark_missing(name, None);
            continue;
        };
        let Some(agent) = source.agents.iter().find(|a| &a.name == name) else {
            stats.mark_missing(name, Some(&source.root));
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
        let mut content_changed = false;
        for harness_id in &entry.harnesses {
            if let Some(harness) = Harness::from_id(harness_id) {
                let matched_hooks = crate::resolve::matched_installed_hooks_for_agent_harness(
                    lock,
                    &all_hooks,
                    &source.mapping,
                    &agent.role,
                    harness.id(),
                );
                // Compare the bytes actually written to the destination against
                // what was there before: agent files re-render when the
                // installed skill set / injected instructions change even
                // though the agent's own source hash is unchanged.
                let out_path = harness
                    .agents_dir(global)
                    .join(harness.agent_filename(&agent.name));
                let before = config::hash_file_bytes(&out_path);
                match harness.generate_agent(agent, global, &skill_pairs, &matched_hooks, &extras) {
                    Ok(_) => {
                        succeeded += 1;
                        if config::hash_file_bytes(&out_path) != before {
                            content_changed = true;
                        }
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
            if content_changed {
                stats.mark_content_changed(name);
            }
        } else if succeeded == 0 && !failed {
            stats.fail_no_installable_harness(name, &entry.harnesses);
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
                stats.content_changed.remove(&agent.name);
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
            stats.mark_missing(name, None);
            continue;
        };
        let Some(skill) = source.skills.iter().find(|s| &s.name == name) else {
            stats.mark_missing(name, Some(&source.root));
            continue;
        };

        let mut succeeded = 0usize;
        let mut failed = false;
        let mut content_changed = false;
        for harness_id in &entry.harnesses {
            if let Some(harness) = Harness::from_id(harness_id) {
                let skill_instr = project_config.skill_instructions_for(&skill.name);
                // Snapshot the installed skill content before/after: a rendered
                // skill can differ from its source (injected instructions/notice)
                // while the lock's source hash is unchanged.
                let before = harness
                    .install_skill(skill, global)
                    .ok()
                    .map(|dest| hash_installed_skill_dir(&dest))
                    .unwrap_or(0);
                match installer::install_skill(skill, harness, global, entry.method, skill_instr) {
                    Ok(result) => {
                        succeeded += 1;
                        if hash_installed_skill_dir(&result.path) != before {
                            content_changed = true;
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
            stats.skills_refreshed += 1;
            stats.mark_success(name);
            if content_changed {
                stats.mark_content_changed(name);
            }
        } else if succeeded == 0 && !failed {
            stats.fail_no_installable_harness(name, &entry.harnesses);
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
            stats.mark_missing(name, None);
            continue;
        };
        let Some(hook) = source.hooks.iter().find(|hook| hook.name == entry.name) else {
            stats.mark_missing(name, Some(&source.root));
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
        } else if succeeded == 0 && !failed {
            stats.fail_no_installable_harness(name, &entry.harnesses);
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
            stats.mark_missing(name, None);
            continue;
        };
        let Some(ext) = source_pi_extension_for_lock_name(&source.pi_extensions, name) else {
            stats.mark_missing(name, Some(&source.root));
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

#[derive(Debug)]
struct ProjectOwnedSkillsRoot {
    path: PathBuf,
    canonical: PathBuf,
}

/// The configured out-of-`.agents` home for project-owned skills.
struct RelocatedProjectSkills {
    /// Project-root-relative directory exactly as configured, used to build the
    /// `../../<dir>/<name>` link target.
    relative: String,
    canonical: PathBuf,
}

/// Resolve `project-skills-dir` from `vstack.toml`.
///
/// Returns `Ok(None)` when unset, or set but not yet created — an absent
/// directory is a project that has not adopted the convention, not an error.
/// Everything else fails closed: the directory must stay inside the project and
/// must not sit inside `.agents`, which is the tree the convention exists to
/// keep free of tracked content.
fn resolve_relocated_project_skills(
    project_root: &Path,
    project_config: &crate::project_config::ProjectConfig,
) -> Result<Option<RelocatedProjectSkills>> {
    let Some(configured) = project_config.project_skills_dir.as_deref() else {
        return Ok(None);
    };
    let relative = configured.trim().trim_end_matches('/');
    if relative.is_empty() {
        return Ok(None);
    }
    if Path::new(relative).is_absolute() || relative.split('/').any(|part| part == "..") {
        anyhow::bail!(
            "project-skills-dir must be a relative path inside the project, got: {relative}"
        );
    }

    let dir = project_root.join(relative);
    let canonical = match dir.canonicalize() {
        Ok(path) => path,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => {
            return Err(anyhow::anyhow!(
                "failed to resolve project-skills-dir {}: {err}",
                dir.display()
            ));
        }
    };
    let project_root_canon = project_root
        .canonicalize()
        .map_err(|err| anyhow::anyhow!("failed to resolve project root: {err}"))?;
    if !canonical.starts_with(&project_root_canon) {
        anyhow::bail!(
            "refusing project-skills-dir outside the project root: {}",
            dir.display()
        );
    }
    if !canonical.is_dir() {
        anyhow::bail!("project-skills-dir is not a directory: {}", dir.display());
    }
    if canonical.starts_with(project_root_canon.join(".agents")) {
        anyhow::bail!(
            "project-skills-dir must live outside .agents (that is the point of relocating it): {}",
            dir.display()
        );
    }
    Ok(Some(RelocatedProjectSkills {
        relative: relative.to_string(),
        canonical,
    }))
}

/// Link each `<project-skills-dir>/<name>` into `.agents/skills/<name>`.
///
/// Only ever replaces an existing SYMLINK. A real directory already sitting at
/// the destination is somebody's committed skill or a materialized harness dir,
/// and silently deleting either would be the bug this feature exists to avoid.
fn link_relocated_project_skills(
    skills_root: &ProjectOwnedSkillsRoot,
    relocated: &RelocatedProjectSkills,
    pass: &impl Fn(&str) -> bool,
    stats: &mut RefreshStats,
) {
    let entries = match std::fs::read_dir(&relocated.canonical) {
        Ok(entries) => entries,
        Err(err) => {
            stats.fail(
                &relocated.relative,
                None,
                format!("failed to enumerate project-skills-dir: {err}"),
            );
            return;
        }
    };

    let mut dirs: Vec<PathBuf> = Vec::new();
    for entry in entries {
        match entry {
            Ok(entry) => dirs.push(entry.path()),
            Err(err) => {
                stats.fail(
                    &relocated.relative,
                    None,
                    format!("failed to enumerate project-skills-dir: {err}"),
                );
                return;
            }
        }
    }
    dirs.sort();

    for source in dirs {
        let Some(name) = source.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if !pass(name) || crate::path_safety::validate_item_name(name).is_err() {
            continue;
        }
        if !source.join("SKILL.md").is_file() {
            continue;
        }

        let dest = skills_root.path.join(name);
        let target = format!("../../{}/{}", relocated.relative, name);
        match std::fs::symlink_metadata(&dest) {
            Ok(meta) if meta.file_type().is_symlink() => {
                if std::fs::read_link(&dest).is_ok_and(|current| current == Path::new(&target)) {
                    continue; // already correct
                }
                if let Err(err) = std::fs::remove_file(&dest) {
                    stats.fail(name, None, format!("failed to replace stale link: {err}"));
                    continue;
                }
            }
            Ok(_) => {
                stats.fail(
                    name,
                    None,
                    format!(
                        "refusing to replace existing non-symlink path with a project-skills link: {}",
                        dest.display()
                    ),
                );
                continue;
            }
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
            Err(err) => {
                stats.fail(name, None, format!("failed to inspect {}: {err}", dest.display()));
                continue;
            }
        }

        if let Some(parent) = dest.parent()
            && let Err(err) = std::fs::create_dir_all(parent)
        {
            stats.fail(name, None, format!("failed to create .agents/skills: {err}"));
            continue;
        }
        if let Err(err) = std::os::unix::fs::symlink(&target, &dest) {
            stats.fail(name, None, format!("failed to link project skill: {err}"));
            continue;
        }
        stats.mark_content_changed(name);
    }
}

/// Validate the ownership boundary used by all project refresh writes.
///
/// This must run before lock reconciliation, hook pruning, or installation.
/// Codex and Pi both write project skills through `.agents/skills`, so even a
/// refresh that is not applying local `[skill-instructions]` must reject an
/// existing `.agents` ancestor that resolves outside the selected project.
pub fn preflight_project_refresh(project_root: &Path) -> Result<()> {
    resolve_project_owned_skills_root(project_root).map(|_| ())
}

fn escaped_project_owned_skills_message(skills_dir: &Path) -> String {
    format!(
        "refusing project-owned skills path outside project root: {}. \
This project has a .agents skills path that resolves outside the selected project; \
run from the checkout that owns that path, or replace it with a project-local .agents directory before project-scope skill installs or refresh.",
        skills_dir.display()
    )
}

/// `git rev-parse --git-common-dir` for `dir`, canonicalized. `None` when `dir`
/// is not inside a Git repository, when git is unavailable, or when the answer
/// cannot be resolved — every one of which must fail closed at the call site.
fn git_common_dir(dir: &Path) -> Option<PathBuf> {
    let output = std::process::Command::new("git")
        .args(["-C", dir.to_str()?, "rev-parse", "--git-common-dir"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let raw = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if raw.is_empty() {
        return None;
    }
    // `--git-common-dir` is relative to the queried directory unless git is new
    // enough to have been asked for an absolute path, so resolve it against
    // `dir` rather than the process cwd.
    let reported = Path::new(&raw);
    let absolute = if reported.is_absolute() {
        reported.to_path_buf()
    } else {
        dir.join(reported)
    };
    absolute.canonicalize().ok()
}

/// Positive proof that `target` lives in a working tree of the SAME repository
/// as `project_root` — both resolve to one `--git-common-dir`.
///
/// This is not a relaxation of the containment boundary; it answers a different
/// and stronger question. Lexical containment asks "is this path under the
/// project directory", which cannot tell another checkout of the repository the
/// operator is already working in from an arbitrary directory elsewhere on
/// disk. vstack's own `worktree` skill provisions the first case: every issue
/// worktree gets a `.agents` symlink into the main checkout so a ~100 MB harness
/// library is shared rather than copied per branch (vstack#886). Refusing that
/// made refresh unusable from any worktree.
///
/// Everything else still fails closed. A target that is not a repository has no
/// common dir; a target in a DIFFERENT repository has a different one.
fn is_same_repository_worktree(project_root: &Path, target: &Path) -> bool {
    // `git -C` needs a directory. `target` is normally the canonical
    // `.agents`/`.agents/skills` directory, but probe its parent if it is not.
    let probe = if target.is_dir() {
        target
    } else {
        match target.parent() {
            Some(parent) => parent,
            None => return false,
        }
    };
    match (git_common_dir(project_root), git_common_dir(probe)) {
        (Some(project_common), Some(target_common)) => project_common == target_common,
        _ => false,
    }
}

fn resolve_project_owned_skills_root(
    project_root: &Path,
) -> Result<Option<ProjectOwnedSkillsRoot>> {
    let project_root_canon = project_root
        .canonicalize()
        .map_err(|err| anyhow::anyhow!("failed to resolve project root: {err}"))?;
    let agents_dir = project_root.join(".agents");
    let skills_dir = agents_dir.join("skills");

    match std::fs::symlink_metadata(&skills_dir) {
        Ok(_) => {
            let skills_dir_canon = skills_dir
                .canonicalize()
                .map_err(|err| anyhow::anyhow!("failed to resolve project-owned skills: {err}"))?;
            if !skills_dir_canon.starts_with(&project_root_canon)
                && !is_same_repository_worktree(&project_root_canon, &skills_dir_canon)
            {
                anyhow::bail!("{}", escaped_project_owned_skills_message(&skills_dir));
            }
            if !skills_dir_canon.is_dir() {
                anyhow::bail!(
                    "project-owned skills path is not a directory: {}",
                    skills_dir.display()
                );
            }
            return Ok(Some(ProjectOwnedSkillsRoot {
                path: skills_dir,
                canonical: skills_dir_canon,
            }));
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
        Err(err) => {
            return Err(anyhow::anyhow!(
                "failed to inspect project-owned skills: {err}"
            ));
        }
    }

    // `.agents/skills` may not exist yet, but installers can create it. Check
    // the nearest managed ancestor now so creation cannot follow an escaped or
    // dangling `.agents` symlink later in this refresh.
    match std::fs::symlink_metadata(&agents_dir) {
        Ok(_) => {
            let agents_dir_canon = agents_dir
                .canonicalize()
                .map_err(|err| anyhow::anyhow!("failed to resolve .agents directory: {err}"))?;
            if !agents_dir_canon.starts_with(&project_root_canon)
                && !is_same_repository_worktree(&project_root_canon, &agents_dir_canon)
            {
                anyhow::bail!("{}", escaped_project_owned_skills_message(&skills_dir));
            }
            if !agents_dir_canon.is_dir() {
                anyhow::bail!(
                    "project .agents path is not a directory: {}",
                    agents_dir.display()
                );
            }
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
        Err(err) => {
            return Err(anyhow::anyhow!(
                "failed to inspect project .agents directory: {err}"
            ));
        }
    }

    Ok(None)
}

fn refresh_project_owned_skill_instructions(
    lock: &config::LockFile,
    project_config: &ProjectConfig,
    skills_root: &ProjectOwnedSkillsRoot,
    relocated: Option<&RelocatedProjectSkills>,
    pass: &impl Fn(&str) -> bool,
    stats: &mut RefreshStats,
) {
    let entries = match std::fs::read_dir(&skills_root.path) {
        Ok(entries) => entries,
        Err(err) => {
            stats.fail(
                ".agents/skills",
                None,
                format!("failed to read project-owned skills: {err}"),
            );
            return;
        }
    };
    let mut skill_dirs = Vec::new();
    for entry in entries {
        match entry {
            Ok(entry) => skill_dirs.push(entry.path()),
            Err(err) => {
                stats.fail(
                    ".agents/skills",
                    None,
                    format!("failed to enumerate project-owned skills: {err}"),
                );
                return;
            }
        }
    }
    skill_dirs.sort();

    for skill_dir in skill_dirs {
        let Some(name) = skill_dir.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if !pass(name) || lock.entries.contains_key(name) {
            continue;
        }
        if crate::path_safety::validate_item_name(name).is_err() {
            continue;
        }
        let skill_dir_canon = match skill_dir.canonicalize() {
            Ok(path) => path,
            Err(err) => {
                stats.fail(
                    name,
                    None,
                    format!("failed to resolve project-owned skill directory: {err}"),
                );
                continue;
            }
        };
        // A skill dir normally has to resolve inside `.agents/skills`. The one
        // exception is a link into the configured `project-skills-dir`, which is
        // the whole point of the relocate-and-link convention — without this the
        // convention is not merely unsupported, it hard-fails the refresh.
        // Still fails closed for anything resolving anywhere else.
        let inside_skills_root = skill_dir_canon.starts_with(&skills_root.canonical);
        let inside_relocated = relocated
            .is_some_and(|reloc| skill_dir_canon.starts_with(&reloc.canonical));
        if !inside_skills_root && !inside_relocated {
            stats.fail(
                name,
                None,
                format!(
                    "refusing project-owned skill directory outside skills root: {}",
                    skill_dir.display()
                ),
            );
            continue;
        }
        if !skill_dir_canon.is_dir() {
            continue;
        }
        let skill_md = skill_dir.join("SKILL.md");
        let Ok(skill_md_metadata) = std::fs::symlink_metadata(&skill_md) else {
            continue;
        };
        if skill_md_metadata.file_type().is_symlink() {
            stats.fail(
                name,
                None,
                format!(
                    "refusing project-owned skill file symlink: {}",
                    skill_md.display()
                ),
            );
            continue;
        }
        if !skill_md_metadata.is_file() {
            continue;
        }

        match crate::skill::sync_project_owned_skill_instructions(
            &skill_md,
            project_config.skill_instructions_for(name),
        ) {
            Ok(None) => {}
            Ok(Some(changed)) => {
                stats.skills_refreshed += 1;
                stats.project_owned_skills.insert(name.to_string());
                stats.mark_success(name);
                if changed {
                    stats.mark_content_changed(name);
                }
            }
            Err(err) => stats.fail(name, None, err),
        }
    }
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

/// Re-render affected agents after a hook is removed.
///
/// Project callers must strict-load `project_config` and run
/// [`preflight_project_refresh`] before mutating hook artifacts or lock state.
pub fn regenerate_agents_after_hook_removal(
    global: bool,
    lock: &config::LockFile,
    removed_hook_harnesses: &[String],
    project_config: &mut ProjectConfig,
    project_root: &Path,
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

    let stats = refresh_items_in_scope(
        global,
        lock,
        &sources,
        project_config,
        project_root,
        Some(&agent_names),
    );
    if !global {
        stats.persist_upstream(project_root);
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
        let project_root = config::project_root();
        let project_owned_scope = !global
            && crate::project_config::project_config_path(&project_root).exists()
            && project_root.join(".agents/skills").is_dir();
        if !lock_path.exists() && !project_owned_scope {
            continue;
        }
        let lock = config::LockFile::load(&lock_path).unwrap_or_default();
        if lock.entries.is_empty() && !project_owned_scope {
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
    let lock_existed = lock_path.exists();
    let mut lock = config::LockFile::load(&lock_path)?;
    let project_root = config::project_root();
    let mut project_config = if global {
        crate::project_config::ProjectConfig::load(&project_root)
    } else {
        crate::project_config::ProjectConfig::load_strict(&project_root)?
    };
    if !global {
        preflight_project_refresh(&project_root)?;
    }

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

    if !global && !lock.entries.is_empty() {
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
        project_config = crate::project_config::ProjectConfig::load_strict(&project_root)?;
    }

    if !lock.entries.is_empty() && sources.is_empty() {
        eprintln!("Could not locate any package sources. Run `vstack add` to reinstall.");
    }
    let all_pi_extensions = all_source_pi_extensions(&sources);

    if !global && !lock.entries.is_empty() {
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
        project_config = crate::project_config::ProjectConfig::load_strict(&project_root)?;
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
        // Repair only a source that has genuinely gone away. An entry whose
        // recorded source still exists keeps it even when nothing else in the
        // lock references it: rewriting it here is what silently re-pointed
        // alternate-source entries at the majority source and undid every
        // hand-correction of the lock.
        if !source_resolved
            && !crate::refresh_sources::recorded_source_exists(&entry.source)
            && let Some(replacement) = &fallback_source
            && &entry.source != replacement
        {
            entry.source = replacement.clone();
            repaired_sources += 1;
        }
        let old_hash = entry.source_hash.clone();
        if stats.successful_items.contains(&entry.name) {
            sync_lock_entry_source_repo(&source_records, entry);
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
    for name in &stats.project_owned_skills {
        changes.push((
            ItemKind::Skill,
            ItemKind::Skill.label_short().to_string(),
            name.clone(),
            "project-owned".to_string(),
            "project-owned".to_string(),
        ));
    }
    if lock_existed || !lock.entries.is_empty() {
        lock.save(&lock_path)?;
    }

    // An item counts as "updated" when its source hash changed OR its
    // generated/installed on-disk content changed. The latter catches
    // artifacts that re-render from external state (agents embedding the
    // installed skill set; skills with injected instructions) whose own source
    // hash is unchanged — so the summary never reports "0 updated" while
    // refresh actually rewrote tracked output.
    let is_updated = |name: &str, old: &str, new: &str| -> bool {
        old != new || stats.content_changed.contains(name)
    };

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
        let failed_items: HashSet<&str> = stats
            .failures
            .iter()
            .map(|failure| failure.item.as_str())
            .collect();
        for (_, kind, name, old, new) in &changes {
            let missing = stats.missing.contains_key(name);
            let failed = !missing && failed_items.contains(name.as_str());
            let changed = !missing && !failed && is_updated(name, old, new);
            let mark = if missing || failed {
                "?"
            } else if changed {
                "!"
            } else {
                "✓"
            };
            let label = if missing {
                "missing"
            } else if failed {
                "failed"
            } else if changed {
                "changed"
            } else {
                "unchanged"
            };
            let old_short = if old.is_empty() {
                "—".to_string()
            } else {
                old.chars().take(8).collect()
            };
            // A missing or failed item's stored hash is deliberately not echoed
            // as the new value: printing "<hash> → <hash> (unchanged)" is
            // exactly the masking those states exist to prevent — an
            // unrefreshed entry's record says nothing about the live source.
            let new_short: String = if missing || failed {
                "—".to_string()
            } else {
                new.chars().take(8).collect()
            };
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
            if is_updated(name, old, new) {
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
            .filter(|(k, _, name, old, new)| *k == kind && is_updated(name, old, new))
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
    for (item, reason) in &stats.missing {
        eprintln!("  ? {item} — {reason}; not refreshed");
    }
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
    if stats.has_missing() {
        anyhow::bail!(
            "{} locked item(s) missing from their source; \
             re-add them or run `vstack remove` to drop the stale entries",
            stats.missing.len()
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests;
