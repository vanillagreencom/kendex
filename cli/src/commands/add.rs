mod source;

use crate::agent::Agent;
use crate::config::{self, InstallMethod, LockFile};
use crate::harness::Harness;
use crate::hook::Hook;
use crate::installer;
use crate::pi_extension::PiExtension;
use crate::resolve::{same_path, source_from_project_lock};
use crate::skill;
use crate::skill::Skill;
use crate::tui;
use anyhow::Context;
use anyhow::Result;
use source::{resolve_remembered_source, resolve_source, source_label};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// Merge a project-side skill list with the upstream/source-derived list.
/// Returns (merged, added_names). If the project list is None, the source
/// list is taken as-is. Mirrors the helper used by `vstack refresh` so
/// `vstack add --skill <new>` and refresh agree on agent skill regeneration.
fn merge_skill_lists<T: Clone>(
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

#[allow(clippy::too_many_arguments)]
fn print_install_summary(
    global: bool,
    scope: &str,
    method: InstallMethod,
    resolved_source: &ResolvedSource,
    harness_names: &[&str],
    harnesses: &[Harness],
    agents: &[Agent],
    skills: &[Skill],
    hooks: &[Hook],
    pi_extensions: &[PiExtension],
    previously_installed: &HashSet<String>,
    skipped_harnesses: &[String],
) {
    let bar = "─".repeat(60);
    eprintln!("\n{bar}");
    if global {
        eprintln!("⚠  GLOBAL install — affects every project on this machine");
        eprintln!("{bar}");
    } else {
        eprintln!("vstack add");
        eprintln!("{bar}");
    }
    eprintln!("Source:   {}", resolved_source.label);
    let scope_target = if global {
        config::display_path(&config::global_state_dir())
    } else {
        config::display_path(&config::project_root())
    };
    eprintln!("Scope:    {} ({})", scope.to_uppercase(), scope_target);
    eprintln!("Method:   {method}");
    eprintln!("Harness:  {}", harness_names.join(", "));
    if !skipped_harnesses.is_empty() {
        eprintln!("Skipped:  {}", skipped_harnesses.join(", "));
    }

    let total = agents.len() + skills.len() + hooks.len() + pi_extensions.len();
    let updated_count = agents
        .iter()
        .filter(|a| previously_installed.contains(&a.name))
        .count()
        + skills
            .iter()
            .filter(|s| previously_installed.contains(&s.name))
            .count()
        + hooks
            .iter()
            .filter(|h| previously_installed.contains(&h.name))
            .count()
        + pi_extensions
            .iter()
            .filter(|e| previously_installed.contains(&e.name))
            .count();
    let new_count = total.saturating_sub(updated_count);
    eprintln!("\nInstalled {total} item(s) — {new_count} new, {updated_count} updated:");

    let primary_harness = harnesses.first().copied();
    let item_status = |name: &str| -> &'static str {
        if previously_installed.contains(name) {
            "updated"
        } else {
            "new"
        }
    };

    if !agents.is_empty() {
        eprintln!("  Agents:");
        for a in agents {
            let path = primary_harness
                .map(|h| h.agents_dir(global).join(h.agent_filename(&a.name)))
                .map(|p| config::display_path(&p))
                .unwrap_or_default();
            eprintln!("    {:<20}  {path}  ({})", a.name, item_status(&a.name));
        }
    }
    if !skills.is_empty() {
        eprintln!("  Skills:");
        let canonical_dir = if global {
            config::global_state_dir().join("skills")
        } else {
            config::project_root().join(".agents").join("skills")
        };
        for s in skills {
            let path = config::display_path(&canonical_dir.join(&s.name));
            eprintln!("    {:<20}  {path}  ({})", s.name, item_status(&s.name));
        }
    }
    if !hooks.is_empty() {
        eprintln!("  Hooks:");
        for h in hooks {
            let matcher = h.matcher.as_deref().unwrap_or("*");
            eprintln!(
                "    {:<20}  {}:{}  ({})",
                h.name,
                h.event,
                matcher,
                item_status(&h.name)
            );
        }
    }
    if !pi_extensions.is_empty() {
        let pkg_dir = if global {
            crate::config::user_home_dir()
                .join(".pi")
                .join("agent")
                .join("packages")
        } else {
            config::project_root().join(".pi").join("packages")
        };
        eprintln!("  Pi extensions:");
        for e in pi_extensions {
            let path = config::display_path(&pkg_dir.join(&e.name));
            eprintln!("    {:<20}  {path}  ({})", e.name, item_status(&e.name));
        }
    }

    let revert_names: Vec<String> = agents
        .iter()
        .map(|a| a.name.clone())
        .chain(skills.iter().map(|s| s.name.clone()))
        .chain(hooks.iter().map(|h| h.name.clone()))
        .chain(pi_extensions.iter().map(|e| e.name.clone()))
        .filter(|n| !previously_installed.contains(n))
        .collect();
    if !revert_names.is_empty() {
        let scope_flag = if global { " --global" } else { "" };
        // A discovered name reaches this line as a shell WORD: it comes from a
        // source directory or a frontmatter field, and this command is printed
        // to be pasted.
        let args: Vec<String> = revert_names
            .iter()
            .map(|name| crate::display::command_arg(name))
            .collect();
        eprintln!(
            "\nRevert with:\n  vstack remove {}{}",
            args.join(" "),
            scope_flag,
        );
    }
    eprintln!("{bar}\n");
}

struct ResolvedSource {
    source: String,
    source_repo: Option<String>,
    label: String,
    dir: PathBuf,
    persist: bool,
    /// Held for as long as this value is — which is the whole install, since
    /// `run` keeps it from resolution through the last copy. `dir` is read
    /// that entire time (discovered, hashed, copied out of), and without the
    /// lease a second `vstack add` could fetch and `reset --hard` the same
    /// cache underneath, leaving a mixed install and lock hashes for a tree
    /// that never existed as a whole.
    #[allow(dead_code)]
    lease: config::CacheLease,
}

fn build_source_options(
    registry: &config::SourceRegistry,
    resolved: &ResolvedSource,
    project_root: &Path,
) -> Vec<tui::RepoOption> {
    let mut sources = Vec::new();
    if !registry.was_removed(crate::REPO) {
        sources.push(crate::REPO.to_string());
    }
    if let Some(current) = registry.current_for_project(project_root) {
        sources.push(current.to_string());
    }
    if let Some(current) = &registry.current {
        sources.push(current.clone());
    }
    sources.extend(registry.entries.iter().cloned());
    if !sources.iter().any(|source| source == &resolved.source) {
        sources.push(resolved.source.clone());
    }

    let mut options = Vec::new();
    for source in sources {
        if options
            .iter()
            .any(|option: &tui::RepoOption| option.source == source)
        {
            continue;
        }
        // vstack#1038: the current project recorded as its own source without
        // being one (vstack#1024) is noise in the picker. Only the project's
        // own self entry is judged — other local entries may be legitimate
        // minimal sources (#1047 review). The source resolved for THIS run
        // always stays listed — the user chose it.
        if source != resolved.source && config::is_project_self_non_source(&source, project_root) {
            continue;
        }
        options.push(tui::RepoOption {
            label: source_label(&source),
            source,
        });
    }
    options
}

/// Resolve the harness set for a non-interactive add (`-y` / `--harness`).
/// An empty result is a hard error: nothing would be installed, and scripted
/// adopters chain on the exit code (vstack#1038).
fn noninteractive_harnesses(filter: Option<&[String]>) -> Result<Vec<Harness>> {
    let harnesses: Vec<Harness> = match filter {
        Some(filter) => filter.iter().filter_map(|f| Harness::from_id(f)).collect(),
        None => Harness::ALL
            .iter()
            .copied()
            .filter(|h| h.is_detected())
            .collect(),
    };
    if harnesses.is_empty() {
        let ids: Vec<&str> = Harness::ALL.iter().map(Harness::id).collect();
        anyhow::bail!(
            "No harnesses selected or detected. Use --harness to specify ({}).",
            ids.join(",")
        );
    }
    Ok(harnesses)
}

fn add_writes_project_skill_root(
    global: bool,
    selected_skills: &[Skill],
    harnesses: &[Harness],
    method: InstallMethod,
    auto_included_skill_names: &std::collections::HashSet<String>,
    lock: &LockFile,
    linked_project_skill_root_has_managed_auto_skill: bool,
) -> bool {
    !global
        && !selected_skills.is_empty()
        && (method == InstallMethod::Symlink
            || auto_included_skill_names.iter().any(|name| {
                lock.entries.get(name).is_some_and(|entry| {
                    entry.kind == config::ItemKind::Skill && entry.method == InstallMethod::Symlink
                }) || linked_project_skill_root_has_managed_auto_skill
            })
            || harnesses
                .iter()
                .any(|harness| matches!(harness, Harness::Codex | Harness::Pi)))
}

fn linked_project_skill_root_has_managed_auto_skill(
    project_root: &Path,
    auto_included_skill_names: &std::collections::HashSet<String>,
) -> bool {
    let skill_root_has_symlink = [
        project_root.join(".agents"),
        project_root.join(".agents/skills"),
    ]
    .iter()
    .any(|path| {
        std::fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink())
    });
    skill_root_has_symlink
        && auto_included_skill_names.iter().any(|name| {
            project_root
                .join(".agents/skills")
                .join(name)
                .join(".vstack-refreshed")
                .is_file()
        })
}

#[cfg(test)]
mod auto_include_agent_skills_tests {
    use super::*;
    use crate::agent::{Agent, AgentRole};
    use crate::mapping::MappingConfig;
    use crate::skill::{Skill, SkillDep};
    use std::path::PathBuf;

    fn skill(name: &str, deps: &[&str]) -> Skill {
        Skill {
            name: name.to_string(),
            description: format!("skill {name}"),
            license: None,
            user_invocable: None,
            dependencies: None,
            body: String::new(),
            source_dir: PathBuf::from(format!("/skills/{name}")),
            resolved_deps: deps
                .iter()
                .map(|d| SkillDep {
                    name: (*d).into(),
                    optional: false,
                })
                .collect(),
        }
    }

    fn agent(name: &str, role: AgentRole) -> Agent {
        Agent {
            name: name.to_string(),
            description: format!("agent {name}"),
            model: "opus".into(),
            role,
            color: None,
            effort: None,
            body: String::new(),
            source_path: PathBuf::from(format!("/agents/{name}.md")),
        }
    }

    #[test]
    fn auto_includes_role_skills_referenced_by_agent_role() {
        // vstack#71 repro: reviewer-error declares engineer role and
        // [role-skills] engineer = ["dev", "github"]. Without
        // explicit --skill flags the agent's frontmatter still references
        // dev, but the skill never lands on disk.
        let mut mapping = MappingConfig::default();
        mapping
            .role_skills
            .insert("engineer".into(), vec!["dev".into(), "github".into()]);
        let all = vec![skill("dev", &[]), skill("github", &[])];
        let agents = vec![agent("reviewer-error", AgentRole::Engineer)];
        let mut selected = Vec::<Skill>::new();
        let added = auto_include_agent_skills(&agents, &mapping, &all, &mut selected);
        assert_eq!(added, vec!["dev".to_string(), "github".to_string()]);
        let names: Vec<&str> = selected.iter().map(|s| s.name.as_str()).collect();
        assert!(names.contains(&"dev"));
        assert!(names.contains(&"github"));
    }

    #[test]
    fn already_selected_skills_are_not_duplicated() {
        let mut mapping = MappingConfig::default();
        mapping
            .role_skills
            .insert("engineer".into(), vec!["dev".into()]);
        let all = vec![skill("dev", &[])];
        let agents = vec![agent("rust", AgentRole::Engineer)];
        let mut selected = vec![skill("dev", &[])];
        let added = auto_include_agent_skills(&agents, &mapping, &all, &mut selected);
        assert!(added.is_empty());
        assert_eq!(selected.len(), 1);
    }

    #[test]
    fn transitive_required_dependencies_are_pulled_in() {
        // orch -> dev (required dep). Agent only references
        // orch; auto-include must transitively pull in dev.
        let mut mapping = MappingConfig::default();
        mapping
            .role_skills
            .insert("engineer".into(), vec!["orch".into()]);
        let all = vec![skill("orch", &["dev"]), skill("dev", &[])];
        let agents = vec![agent("planner", AgentRole::Engineer)];
        let mut selected = Vec::<Skill>::new();
        let added = auto_include_agent_skills(&agents, &mapping, &all, &mut selected);
        assert!(added.contains(&"orch".into()));
        assert!(added.contains(&"dev".into()));
    }

    #[test]
    fn unknown_skill_in_role_mapping_is_silently_skipped() {
        // Mapping references a skill that does not exist in canonical source;
        // skills_for_agent already filters those out, so no panic / no add.
        let mut mapping = MappingConfig::default();
        mapping
            .role_skills
            .insert("engineer".into(), vec!["does-not-exist".into()]);
        let all = vec![skill("github", &[])];
        let agents = vec![agent("rust", AgentRole::Engineer)];
        let mut selected = Vec::<Skill>::new();
        let added = auto_include_agent_skills(&agents, &mapping, &all, &mut selected);
        assert!(added.is_empty());
        assert!(selected.is_empty());
    }

    #[test]
    fn no_agents_selected_is_a_no_op() {
        let mut mapping = MappingConfig::default();
        mapping
            .role_skills
            .insert("engineer".into(), vec!["dev".into()]);
        let all = vec![skill("dev", &[])];
        let mut selected = Vec::<Skill>::new();
        let added = auto_include_agent_skills(&[], &mapping, &all, &mut selected);
        assert!(added.is_empty());
        assert!(selected.is_empty());
    }

    #[test]
    fn preserves_existing_method_for_auto_included_skills() {
        let mut lock = LockFile::default();
        lock.add(config::LockEntry {
            name: "reviewer".into(),
            kind: config::ItemKind::Skill,
            source: "source".into(),
            source_repo: None,
            harnesses: vec!["claude-code".into()],
            method: InstallMethod::Symlink,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        });
        lock.add(config::LockEntry {
            name: "rust".into(),
            kind: config::ItemKind::Agent,
            source: "source".into(),
            source_repo: None,
            harnesses: vec!["claude-code".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        });

        let auto = ["reviewer".to_string(), "rust".to_string()]
            .into_iter()
            .collect();
        let preserved = preserved_auto_skill_methods(&auto, &lock);

        assert_eq!(preserved.get("reviewer"), Some(&InstallMethod::Symlink));
        assert!(
            !preserved.contains_key("rust"),
            "agent entries must not be treated as auto-installed skills"
        );
    }
}

#[cfg(test)]
mod source_option_tests;

/// vstack#71: walk each agent's [agent-skills] + [role-skills] + transitive
/// required dependencies; push any missing canonical skills into
/// `selected_skills` so they get installed alongside the agents. Returns the
/// sorted list of names that were added (empty if nothing changed).
pub fn auto_include_agent_skills(
    selected_agents: &[crate::agent::Agent],
    mapping: &crate::mapping::MappingConfig,
    all_skills: &[crate::skill::Skill],
    selected_skills: &mut Vec<crate::skill::Skill>,
) -> Vec<String> {
    let all_skill_names: Vec<String> = all_skills.iter().map(|s| s.name.clone()).collect();
    let dep_graph = skill::build_dependency_graph(all_skills);
    let mut required: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for agent in selected_agents {
        for skill_name in mapping.skills_for_agent(&agent.name, &agent.role, &all_skill_names) {
            required.insert(skill_name);
        }
    }
    let already_selected: std::collections::HashSet<String> =
        selected_skills.iter().map(|s| s.name.clone()).collect();
    let seeds: Vec<String> = required
        .iter()
        .filter(|name| !already_selected.contains(*name))
        .cloned()
        .collect();
    if seeds.is_empty() {
        return Vec::new();
    }
    let (expanded, _auto_deps) = skill::expand_dependencies(&seeds, &dep_graph);
    let mut added: Vec<String> = Vec::new();
    for skill_name in expanded {
        if already_selected.contains(&skill_name) {
            continue;
        }
        if selected_skills.iter().any(|s| s.name == skill_name) {
            continue;
        }
        if let Some(skill) = all_skills.iter().find(|s| s.name == skill_name) {
            selected_skills.push(skill.clone());
            added.push(skill_name);
        }
    }
    added.sort();
    added.dedup();
    added
}

fn preserved_auto_skill_methods(
    auto_included_skill_names: &std::collections::HashSet<String>,
    pre_lock: &LockFile,
) -> std::collections::HashMap<String, InstallMethod> {
    auto_included_skill_names
        .iter()
        .filter_map(|name| {
            let entry = pre_lock.entries.get(name)?;
            if entry.kind != config::ItemKind::Skill {
                return None;
            }
            Some((name.clone(), entry.method))
        })
        .collect()
}

/// Record the confirmed install source in the on-disk registry. Re-reads
/// sources.json rather than reusing the registry loaded at the start of the
/// run: the interactive repo dialog removes sources by writing the file
/// directly mid-run (install_flow::forget_source), and saving the pre-TUI
/// snapshot would resurrect them.
fn persist_confirmed_source(
    resolved: &ResolvedSource,
    global: bool,
    project_root: &Path,
) -> Result<()> {
    if !resolved.persist {
        return Ok(());
    }
    let registry_path = config::source_registry_path();
    // A missing registry loads as the default; anything else is a real read or
    // parse failure, and defaulting past it here would save an EMPTY registry
    // over the unreadable one — losing every remembered source and every
    // forget_source tombstone this write path exists to preserve.
    let mut registry = config::SourceRegistry::load(&registry_path)?;
    if global {
        registry.remember(&resolved.source);
    } else {
        registry.remember_for_project(project_root, &resolved.source);
    }
    // vstack#1038: opportunistic hygiene on the write path — drop a
    // stale self entry left by an earlier project-local install.
    registry.prune_project_self_non_source(project_root);
    registry.save(&registry_path)
}

fn resolve_source_for_app(
    source: Option<&str>,
    registry: &config::SourceRegistry,
    project_root: &Path,
    interactive: bool,
) -> Result<ResolvedSource> {
    match source {
        Some(path) if Path::new(path).exists() => {
            let dir = std::fs::canonicalize(path)?;
            Ok(ResolvedSource {
                source: dir.display().to_string(),
                source_repo: config::source_repo_for_source(Some(&dir), &dir.to_string_lossy()),
                label: source_label(path),
                dir,
                persist: true,
                lease: config::CacheLease::none(),
            })
        }
        Some(source) => {
            let resolved = resolve_source(Some(source), interactive)?;
            Ok(ResolvedSource {
                source: source.to_string(),
                source_repo: config::source_repo_for_source(Some(&resolved.dir), source),
                label: source_label(source),
                dir: resolved.dir,
                persist: true,
                lease: resolved.lease,
            })
        }
        None => {
            // vstack#1024: a project that is not itself a vstack source must
            // never become its own default source. Installing a project-local
            // item with an explicit self path records the project in the
            // registry and lock; the no-SOURCE path would then scan the
            // project and report "nothing found". Skip self-references and
            // keep walking the fallback chain so resolution is identical
            // across repo shapes.
            let allow_project_self = crate::resolve::has_vstack_source_content(project_root);
            let usable = |dir: &Path| allow_project_self || !same_path(dir, project_root);

            // Prefer the source selected for THIS project. Source selection is
            // intentionally project-scoped: choosing a repo while working in
            // one project must not silently change the source used by another.
            if let Some(current) = registry.current_for_project(project_root)
                && let Some(resolved) = resolve_remembered_source(current, interactive)?
                && usable(&resolved.dir)
            {
                return Ok(ResolvedSource {
                    source: current.to_string(),
                    source_repo: config::source_repo_for_source(Some(&resolved.dir), current),
                    label: source_label(current),
                    dir: resolved.dir,
                    persist: true,
                    lease: resolved.lease,
                });
            }

            // Existing projects already record installed item sources in the
            // lock file. Use that before any global/default source so a
            // project's repo choice remains stable across invocations.
            if let Some(current) = source_from_project_lock(project_root)
                && let Some(resolved) = resolve_remembered_source(&current, interactive)?
                && usable(&resolved.dir)
            {
                return Ok(ResolvedSource {
                    label: source_label(&current),
                    source_repo: config::source_repo_for_source(Some(&resolved.dir), &current),
                    source: current,
                    dir: resolved.dir,
                    persist: true,
                    lease: resolved.lease,
                });
            }

            // Fallback: walk up from CWD looking for a vstack source
            let mut dir = std::env::current_dir()?;
            loop {
                if crate::resolve::is_vstack_source(&dir) {
                    return Ok(ResolvedSource {
                        source: dir.display().to_string(),
                        source_repo: config::source_repo_for_source(
                            Some(&dir),
                            &dir.to_string_lossy(),
                        ),
                        label: source_label(dir.to_str().unwrap_or("local")),
                        dir,
                        persist: false,
                        lease: config::CacheLease::none(),
                    });
                }
                if !dir.pop() {
                    break;
                }
            }

            let source = crate::REPO.to_string();
            let resolved = resolve_source(Some(&source), interactive)?;
            Ok(ResolvedSource {
                label: source_label(&source),
                source_repo: config::source_repo_for_source(Some(&resolved.dir), &source),
                dir: resolved.dir,
                source,
                persist: true,
                lease: resolved.lease,
            })
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub fn run(
    source: Option<String>,
    global: bool,
    harness_filter: Option<Vec<String>>,
    agent_filter: Option<Vec<String>>,
    skill_filter: Option<Vec<String>>,
    hook_filter: Option<Vec<String>>,
    pi_extension_filter: Option<Vec<String>>,
    copy: bool,
    yes: bool,
    all: bool,
    clobber: bool,
    no_auto_skills: bool,
) -> Result<()> {
    // Non-interactive global guard: `--global -y` (or `--global --harness ...
    // -y`) without an item filter would install the entire source catalog
    // into ~/.config/vstack and every detected harness's user dir. That has
    // bitten us repeatedly when an agent runs `--global --harness pi -y` to
    // update one Pi package and accidentally installs every agent, skill,
    // and hook globally. Force the caller to be explicit.
    let non_interactive = yes || all || harness_filter.is_some();
    let has_item_filter = agent_filter.is_some()
        || skill_filter.is_some()
        || hook_filter.is_some()
        || pi_extension_filter.is_some();
    if global && non_interactive && !all && !has_item_filter {
        eprintln!(
            "
Refusing --global without an item filter or --all.

Unfiltered --global installs every agent, skill, hook, and Pi package
in the source globally. Pick one:

  vstack add --global --pi-extension <name> --harness pi -y
  vstack add --global --skill <name> -y
  vstack add --global --agent <name> -y
  vstack add --global --all -y           # whole catalog, on purpose

Drop --global to install at project scope (default).
"
        );
        anyhow::bail!("global install requires --all or an explicit item filter");
    }

    // Second-line guard: --global --all -y is allowed for fresh installs but
    // refused when there's already a populated global lock. The clobber-the-
    // entire-catalog incident on 2026-05-06 came from an agent reaching for
    // --all to recover from a Pi-extension rename that broke `vstack refresh`.
    // The right move in that case is `vstack refresh` (re-sync existing) or a
    // narrow filter (add one specific item). --clobber is the explicit
    // "yes, replace everything globally on purpose" override.
    if global && all && non_interactive && !clobber {
        let global_lock_path = config::lock_file_path(true);
        let global_lock = config::LockFile::load(&global_lock_path).unwrap_or_default();
        let existing = global_lock.entries.len();
        if existing > 0 {
            let breakdown = {
                let mut a = 0;
                let mut s = 0;
                let mut h = 0;
                let mut p = 0;
                let mut x = 0;
                for entry in global_lock.entries.values() {
                    match entry.kind {
                        config::ItemKind::Agent => a += 1,
                        config::ItemKind::Skill => s += 1,
                        config::ItemKind::Hook => h += 1,
                        config::ItemKind::PiExtension => p += 1,
                        config::ItemKind::Extra => x += 1,
                    }
                }
                format!("{a} agent(s), {s} skill(s), {h} hook(s), {p} Pi package(s), {x} extra(s)")
            };
            eprintln!(
                "
Refusing --global --all over an existing global install.

Global scope already has {existing} item(s): {breakdown}.

This pattern usually means an agent is trying to recover from a broken
state by force-reinstalling everything. The recovery commands are:

  vstack refresh -g                       # re-sync existing items from source
  vstack refresh                          # both scopes
  vstack add --global --pi-extension <name> --harness pi -y   # add one item
  vstack remove <name> --scope global     # drop one item

If you really do want to clobber the entire global catalog from this
source (e.g. switching vstack repos, or starting clean), pass --clobber:

  vstack add --global --all --clobber -y
"
            );
            anyhow::bail!(
                "--global --all refused on non-empty global lock; pass --clobber to override"
            );
        }
    }

    let registry =
        config::SourceRegistry::load(&config::source_registry_path()).unwrap_or_default();
    let mut current_source = source.clone();
    let project_root = config::project_root();
    let (
        resolved_source,
        selected_agents,
        mut selected_skills,
        selected_hooks,
        selected_pi_extensions,
        harnesses,
        global,
        method,
        update_cli,
    ) = loop {
        let resolved = resolve_source_for_app(
            current_source.as_deref(),
            &registry,
            &project_root,
            !non_interactive,
        )?;
        let source_dir = resolved.dir.clone();
        let all_agents = crate::catalog::discover_agents(&source_dir)?;
        let all_skills = crate::catalog::discover_skills(&source_dir)?;
        let all_hooks = crate::catalog::discover_hooks(&source_dir)?;
        let all_pi_extensions = crate::catalog::discover_pi_extensions(&source_dir)?;
        let extras = crate::catalog::discover_extras(&source_dir)?;
        let dep_graph = skill::build_dependency_graph(&all_skills);

        // Filter semantics: passing any item filter restricts the install to
        // only the kinds named; unfiltered kinds get nothing. Use `--all` for
        // "everything," or `--skill '*'` as the per-kind "all of this kind"
        // sentinel when combining with narrower filters.
        let any_item_filter = agent_filter.is_some()
            || skill_filter.is_some()
            || hook_filter.is_some()
            || pi_extension_filter.is_some();

        // vstack#1024: a requested-by-name item that is not in the source is a
        // hard error in non-interactive mode — scripted adopters chain on the
        // exit code, so "nothing found" + exit 0 reads as installed. Interactive
        // runs keep going so the user can switch sources in the picker.
        let mut missing: Vec<String> = Vec::new();
        let collect_missing = |missing: &mut Vec<String>,
                               kind: &str,
                               filter: Option<&[String]>,
                               exists: &dyn Fn(&str) -> bool| {
            for name in filter.unwrap_or_default() {
                if name != "*" && !exists(name) {
                    missing.push(format!("{kind} '{name}'"));
                }
            }
        };
        collect_missing(&mut missing, "agent", agent_filter.as_deref(), &|name| {
            all_agents.iter().any(|a| a.name == name)
        });
        collect_missing(&mut missing, "skill", skill_filter.as_deref(), &|name| {
            all_skills.iter().any(|s| s.name == name)
        });
        collect_missing(&mut missing, "hook", hook_filter.as_deref(), &|name| {
            all_hooks.iter().any(|h| h.name == name)
        });
        collect_missing(
            &mut missing,
            "pi-extension",
            pi_extension_filter.as_deref(),
            &|name| {
                all_pi_extensions.iter().any(|e| {
                    e.name == name || crate::pi_extension::legacy_names_for(&e.name).contains(&name)
                })
            },
        );
        if !missing.is_empty() && non_interactive {
            anyhow::bail!(
                "not found in {}: {}\nNothing was installed. Check the name with `vstack list`, or pass an explicit SOURCE.",
                source_dir.display(),
                missing.join(", ")
            );
        }
        let agents = match agent_filter.as_deref() {
            Some(filter) if filter.iter().any(|f| f == "*") => all_agents,
            Some(filter) => {
                let wanted: std::collections::HashSet<&str> =
                    filter.iter().map(String::as_str).collect();
                all_agents
                    .into_iter()
                    .filter(|a| wanted.contains(a.name.as_str()))
                    .collect()
            }
            None if any_item_filter => Vec::new(),
            None => all_agents,
        };
        let skills = match skill_filter.as_deref() {
            Some(filter) if filter.iter().any(|f| f == "*") => all_skills,
            Some(filter) => {
                let (expanded, auto_added) = skill::expand_dependencies(filter, &dep_graph);
                if !auto_added.is_empty() {
                    eprintln!("Auto-added dependencies: {}", auto_added.join(", "));
                }
                all_skills
                    .into_iter()
                    .filter(|s| expanded.contains(&s.name))
                    .collect()
            }
            None if any_item_filter => Vec::new(),
            None => all_skills,
        };
        let hooks = match hook_filter.as_deref() {
            Some(filter) if filter.iter().any(|f| f == "*") => all_hooks,
            Some(filter) => {
                let wanted: std::collections::HashSet<&str> =
                    filter.iter().map(String::as_str).collect();
                all_hooks
                    .into_iter()
                    .filter(|h| wanted.contains(h.name.as_str()))
                    .collect()
            }
            None if any_item_filter => Vec::new(),
            None => all_hooks,
        };
        let pi_extensions = match pi_extension_filter.as_deref() {
            Some(filter) if filter.iter().any(|f| f == "*") => all_pi_extensions,
            Some(filter) => {
                let wanted: std::collections::HashSet<&str> =
                    filter.iter().map(String::as_str).collect();
                all_pi_extensions
                    .into_iter()
                    .filter(|e| {
                        wanted.contains(e.name.as_str())
                            || crate::pi_extension::legacy_names_for(&e.name)
                                .iter()
                                .any(|legacy| wanted.contains(legacy))
                    })
                    .collect()
            }
            None if any_item_filter => Vec::new(),
            None => all_pi_extensions,
        };

        let installable_total = agents.len() + skills.len() + hooks.len() + pi_extensions.len();
        if installable_total == 0 && extras.is_empty() && (yes || all || harness_filter.is_some()) {
            // vstack#1038: nothing installed must exit nonzero — scripted
            // adopters chain on the exit code. Interactive runs never reach
            // this bail: without -y/--all/--harness they fall through to the
            // picker below, where the user can switch sources.
            anyhow::bail!(
                "No agents, skills, hooks, pi-packages, or extras found in {}",
                source_dir.display()
            );
        }

        // Validate the non-interactive harness selection while the run can
        // still fail cleanly. `--all` always uses every harness and the
        // interactive picker chooses harnesses in the TUI, so only the
        // -y/--harness path can come up empty.
        let noninteractive_harness_selection = if !all && (yes || harness_filter.is_some()) {
            Some(noninteractive_harnesses(harness_filter.as_deref())?)
        } else {
            None
        };

        eprintln!(
            "Found {} agent(s), {} skill(s), {} hook(s), {} pi-package(s), {} extra(s) in {}",
            agents.len(),
            skills.len(),
            hooks.len(),
            pi_extensions.len(),
            extras.len(),
            source_dir.display()
        );

        if all {
            break (
                resolved,
                agents,
                skills,
                hooks,
                pi_extensions,
                Harness::ALL.to_vec(),
                global,
                if copy {
                    InstallMethod::Copy
                } else {
                    InstallMethod::Symlink
                },
                false,
            );
        } else if let Some(harnesses) = noninteractive_harness_selection {
            // In non-interactive mode, only auto-install Pi packages when Pi
            // is one of the chosen harnesses. The agents/skills/hooks loops
            // run per-harness, but Pi packages are scope-only — they go to
            // ~/.pi/agent/packages/<name> regardless of which agent harness
            // selection was requested.
            let pi_selected = harnesses.iter().any(|h| matches!(h, Harness::Pi));
            let chosen_pi_extensions = if pi_selected {
                pi_extensions
            } else {
                Vec::new()
            };

            break (
                resolved,
                agents,
                skills,
                hooks,
                chosen_pi_extensions,
                harnesses,
                global,
                if copy {
                    InstallMethod::Copy
                } else {
                    InstallMethod::Symlink
                },
                false,
            );
        } else {
            let selector = tui::SourceSelectorData {
                current_label: resolved.label.clone(),
                options: build_source_options(&registry, &resolved, &project_root),
            };
            let items = tui::DiscoveredItems {
                agents,
                skills,
                hooks,
                pi_extensions,
                extras,
            };
            match tui::run_install_flow(items, &selector)? {
                tui::InstallFlowResult::Install(sel) => {
                    break (
                        resolved,
                        sel.agents,
                        sel.skills,
                        sel.hooks,
                        sel.pi_extensions,
                        sel.harnesses,
                        sel.global,
                        sel.method,
                        sel.update_cli,
                    );
                }
                tui::InstallFlowResult::Cancelled => {
                    eprintln!("Installation cancelled.");
                    return Ok(());
                }
                tui::InstallFlowResult::SwitchSource(source) => {
                    current_source = Some(source);
                }
            }
        }
    };

    let source_dir = resolved_source.dir.clone();
    let project_root = config::project_root();
    let mapping = crate::mapping::MappingConfig::load(&source_dir);
    let mut auto_included_skill_names = std::collections::HashSet::new();

    // vstack#71: auto-install skills referenced by selected agents.
    // Without this, `vstack add --agent reviewer-error` produces a
    // .agents/reviewer-error.md whose `skills:` frontmatter points at
    // skills/dev/SKILL.md that was never copied to the
    // install mirror. Walk each agent's mapping-resolved skill set
    // (agent-skills + role-skills + prefix matches) plus transitive
    // dependencies and add any missing canonical skills.
    if !no_auto_skills && !selected_agents.is_empty() {
        let all_skills = crate::catalog::discover_skills(&source_dir).unwrap_or_default();
        let added = auto_include_agent_skills(
            &selected_agents,
            &mapping,
            &all_skills,
            &mut selected_skills,
        );
        if !added.is_empty() {
            eprintln!("Auto-installed dependent skills: {}", added.join(", "));
        }
        auto_included_skill_names.extend(added);
    }

    // Preflight every name — including auto-included skills — before the
    // first mutation: a reserved name failing only inside an install loop
    // would leave earlier items installed and the project config mutated with
    // no lock entries written. The per-installer checks stay as defense in
    // depth.
    for name in selected_agents
        .iter()
        .map(|a| a.name.as_str())
        .chain(selected_skills.iter().map(|s| s.name.as_str()))
        .chain(selected_hooks.iter().map(|h| h.name.as_str()))
    {
        crate::path_safety::validate_new_item_name(name)
            .with_context(|| format!("cannot install {name:?}"))?;
    }
    for hook in &selected_hooks {
        crate::installer::contract::validate_event(&hook.name, &hook.event)?;
    }
    // Reconciliation later renders every agent with every locked hook, so an
    // already-installed hook whose source left the contract fails the add
    // here, before this add's own items are written. With no agent installed
    // or selected nothing consumes the definition, and an unrelated add is
    // not held hostage by it.
    {
        let lock = LockFile::load(&config::lock_file_path(global)).unwrap_or_default();
        let reconciles_agents = !selected_agents.is_empty()
            || lock
                .entries
                .values()
                .any(|entry| entry.kind == config::ItemKind::Agent);
        if reconciles_agents {
            let records = crate::refresh_sources::resolve_source_records_without_update(&lock);
            let all_hooks = crate::refresh_sources::all_source_hooks(
                &crate::refresh_sources::load_refresh_sources(&records.sources),
            );
            if let Some((name, error)) =
                crate::commands::refresh::uncovered_hook_event(&lock, &all_hooks, None)
            {
                anyhow::bail!("hook {name}: {error}");
            }
        }
    }
    if add_writes_project_skill_root(
        global,
        &selected_skills,
        &harnesses,
        method,
        &auto_included_skill_names,
        &LockFile::load(&config::lock_file_path(global)).unwrap_or_default(),
        linked_project_skill_root_has_managed_auto_skill(&project_root, &auto_included_skill_names),
    ) {
        crate::commands::refresh::preflight_project_refresh(&project_root)?;
    }

    // Persist the source choice only after every pre-install validation: a
    // run that fails (or is cancelled) before installing anything must not
    // mutate sources.json — neither the remembered source nor the
    // opportunistic self-entry prune may land (vstack#1024 review round;
    // VST-255 moved this below the interactive TUI, which fails on a
    // TTY-less stdin, and below the preflights above).
    persist_confirmed_source(&resolved_source, global, &project_root)?;

    // Whether we should write/update the project-level vstack.toml.
    // Suppress when:
    //   - --global install (project files are not the install target)
    //   - the "project root" we'd write to IS the vstack source repo
    //     itself (writing project-customization sections there would
    //     clobber the upstream source mapping config)
    let writes_project_config = !global && !same_path(&project_root, &source_dir);

    // Ensure project-level vstack.toml exists for customization.
    // Merge already-installed items with newly selected ones so the
    // config template and skills reference block reflect the FULL set,
    // not just what was picked in this session.
    if writes_project_config {
        let lock = config::LockFile::load(&config::lock_file_path(false)).unwrap_or_default();
        let mut agent_names: Vec<String> = lock
            .entries
            .iter()
            .filter(|(_, e)| e.kind == config::ItemKind::Agent)
            .map(|(n, _)| n.clone())
            .collect();
        let mut skill_names: Vec<String> = lock
            .entries
            .iter()
            .filter(|(_, e)| e.kind == config::ItemKind::Skill)
            .map(|(n, _)| n.clone())
            .collect();
        for a in &selected_agents {
            if !agent_names.contains(&a.name) {
                agent_names.push(a.name.clone());
            }
        }
        for s in &selected_skills {
            if !skill_names.contains(&s.name) {
                skill_names.push(s.name.clone());
            }
        }
        agent_names.sort();
        skill_names.sort();
        crate::project_config::ensure_project_config(&project_root, &agent_names, &skill_names);

        let harnesses_by_agent: std::collections::HashMap<String, Vec<Harness>> = selected_agents
            .iter()
            .map(|agent| (agent.name.clone(), harnesses.clone()))
            .collect();
        crate::project_config::write_agent_frontmatter_defaults(
            &project_root,
            &selected_agents,
            &harnesses_by_agent,
            &mapping,
        );
    }

    let mut project_config = crate::project_config::ProjectConfig::load(&project_root);
    project_config.overlay_source_frontmatter(&mapping);

    if global {
        let unsupported: Vec<Harness> = harnesses
            .iter()
            .copied()
            .filter(|h| !h.supports_global_scope())
            .collect();
        if !unsupported.is_empty() && unsupported.len() == harnesses.len() {
            eprintln!(
                "Global install is not supported for: {}. Rerun from the target project directory for project-scoped install.",
                unsupported
                    .iter()
                    .map(|h| h.name())
                    .collect::<Vec<_>>()
                    .join(", ")
            );
            return Ok(());
        }
    }

    let mut harnesses = harnesses;
    let mut skipped_harnesses: Vec<String> = Vec::new();
    if global {
        let mut unsupported: Vec<String> = harnesses
            .iter()
            .filter(|h| !h.supports_global_scope())
            .map(|h| h.name().to_string())
            .collect();
        harnesses.retain(|h| h.supports_global_scope());
        skipped_harnesses.append(&mut unsupported);
        skipped_harnesses.sort();
        skipped_harnesses.dedup();

        if !skipped_harnesses.is_empty() {
            eprintln!(
                "Skipping project-only harnesses for global install: {}. Rerun from the target project directory to install those.",
                skipped_harnesses.join(", ")
            );
        }
    }

    if harnesses.iter().any(|h| matches!(h, Harness::Codex)) {
        installer::migrate_codex_config(global)?;
    }

    // Reconcile lock with disk: recover entries for skills installed on disk
    // but missing from the lock (e.g. after worktree creation or lock deletion),
    // and prune entries for items whose files no longer exist.
    {
        let lock_path = config::lock_file_path(global);
        let mut lock = config::LockFile::load(&lock_path).unwrap_or_default();
        if config::reconcile_lock_with_disk(&mut lock, global, &resolved_source.source) {
            let _ = lock.save(&lock_path);
        }
    }

    // Track what's already installed (to distinguish updates from new installs)
    let pre_lock = config::LockFile::load(&config::lock_file_path(global)).unwrap_or_default();
    let previously_installed: std::collections::HashSet<String> =
        pre_lock.entries.keys().cloned().collect();
    let preserved_auto_skill_methods =
        preserved_auto_skill_methods(&auto_included_skill_names, &pre_lock);

    // Perform installation
    let mut results = Vec::new();
    let mut log_lines: Vec<String> = Vec::new();
    let mut settings_note: Option<String> = None;

    // Collect computed agent→skill mappings to write to project vstack.toml
    let mut agent_skill_map: std::collections::HashMap<String, Vec<String>> =
        std::collections::HashMap::new();

    // Available skill names for role-skills merging during agent regen:
    // UNION of skills already in the lock (from prior installs) with the skills
    // being installed in this run. Using only `selected_skills` here caused
    // `vstack add --skill <new>` to drop the just-added skill from role-skills
    // merges when the existing project [agent-skills] list was authoritative
    // for affected agents (the new skill never propagated until a follow-up
    // `vstack refresh`).
    let available_skill_names: Vec<String> = {
        let mut set: std::collections::HashSet<String> = pre_lock
            .entries
            .iter()
            .filter(|(_, e)| e.kind == config::ItemKind::Skill)
            .map(|(n, _)| n.clone())
            .collect();
        for s in &selected_skills {
            set.insert(s.name.clone());
        }
        let mut v: Vec<String> = set.into_iter().collect();
        v.sort();
        v
    };

    for harness in &harnesses {
        for a in &selected_agents {
            // Merge project [agent-skills] (authoritative) with role-skills from
            // source so newly-added upstream skills (e.g. `vstack add --skill X`
            // where X is referenced by [role-skills] for the agent's role)
            // propagate into the agent's skill list in this same install pass.
            let source_skills = mapping.skills_for_agent(&a.name, &a.role, &available_skill_names);
            let project_required = project_config.agent_skills_for(&a.name);
            let (skill_names, _added) = merge_skill_lists(
                project_required.map(|v| v.as_slice()),
                &source_skills,
                |s| s.clone(),
            );

            let skill_pairs = crate::resolve::resolve_skill_pairs(&skill_names, &selected_skills);

            agent_skill_map
                .entry(a.name.clone())
                .or_insert_with(|| skill_names.clone());

            let matched_hooks = crate::resolve::matched_selected_hooks_for_agent_harness(
                &mapping,
                &a.role,
                &selected_hooks,
                harness.id(),
            );

            let existing_path = harness
                .agents_dir(global)
                .join(harness.agent_filename(&a.name));
            let file_extras = crate::resolve::read_existing_extras(&existing_path, *harness);
            if writes_project_config {
                project_config.save_extracted(&project_root, &a.name, &file_extras);
            }

            let extras = crate::resolve::build_agent_extras(
                &project_config,
                &a.name,
                &a.role,
                Some(&file_extras),
            );

            let result = installer::install_agent(
                a,
                *harness,
                global,
                &skill_pairs,
                &matched_hooks,
                &extras,
            )?;
            log_lines.push(result.detail.clone());
            results.push(result);
        }

        for s in &selected_skills {
            let skill_instr = project_config.skill_instructions_for(&s.name);
            let skill_method = preserved_auto_skill_methods
                .get(&s.name)
                .copied()
                .unwrap_or(method);
            let result = installer::install_skill(
                s,
                *harness,
                global,
                skill_method,
                skill_instr.as_deref(),
            )?;
            log_lines.push(result.detail.clone());
            results.push(result);
        }

        for h in &selected_hooks {
            let result = installer::install_hook(h, *harness, global, &selected_agents)?;
            // A harness that produced nothing says so: the alternative is a
            // summary claiming an install that wrote no file anywhere.
            if !result.installed && h.applies_to(harness.id()) {
                eprintln!("  Note: {}", result.detail);
            }
            log_lines.push(result.detail);
        }
    }

    // Pi packages install once per scope (not per harness). Records as
    // ItemKind::PiExtension with harness id "pi" so list/remove can find them.
    // Returns Ok(None) when the install was skipped (cross-scope duplicate);
    // skipped extensions are not added to the lock summary.
    let pi_in_harnesses = harnesses.iter().any(|h| matches!(h, Harness::Pi));
    let mut migrated_pi_extensions = Vec::new();
    if pi_in_harnesses {
        for ext in &selected_pi_extensions {
            match crate::pi_extension::install_pi_extension(ext, global) {
                Ok(Some(dest)) => {
                    let detail = format!("{} → {} (Pi package)", ext.name, dest.display());
                    log_lines.push(detail.clone());
                    results.push(installer::InstallResult {
                        name: ext.name.clone(),
                        kind: config::ItemKind::PiExtension,
                        harness: Harness::Pi,
                        path: dest,
                        detail,
                    });
                    migrated_pi_extensions.extend(
                        crate::pi_extension::legacy_names_for(&ext.name)
                            .iter()
                            .map(|name| name.to_string()),
                    );
                }
                Ok(None) => {
                    // Skipped — cross-scope duplicate. The skip notice was
                    // already printed by install_pi_extension. Don't record
                    // in the lock so vstack list reflects the actual state.
                }
                Err(e) => {
                    eprintln!("Warning: failed to install Pi package {}: {e}", ext.name);
                }
            }
        }
    }

    let lock_path = config::lock_file_path(global);
    let mut lock = LockFile::load(&lock_path).unwrap_or_default();

    // Write computed agent→skill mappings to project vstack.toml.
    // Must happen BEFORE lock timestamps are captured so that the
    // vstack.toml mtime doesn't post-date installed_at (which would
    // make every item appear outdated on next launch).
    if writes_project_config {
        crate::project_config::write_agent_skills(&project_root, &agent_skill_map);
    }
    // Settings seeding is per-checkout runtime state with no catalog
    // counterpart, so it runs for self-source repos too — same rule as
    // refresh. It reads the FULL installed set (lock ∪ this selection), not
    // the selection alone: the seeder dedups same-key templates first-wins,
    // and a filtered add must not reorder that against what refresh sees.
    if !global {
        let selected_names: std::collections::HashSet<&str> =
            selected_skills.iter().map(|s| s.name.as_str()).collect();
        let mut settings_skills: Vec<Skill> = selected_skills.clone();
        for skill in crate::catalog::discover_skills(&source_dir)? {
            if !selected_names.contains(skill.name.as_str())
                && lock.entries.get(&skill.name).is_some_and(|e| {
                    e.kind == config::ItemKind::Skill && e.source == resolved_source.source
                })
            {
                settings_skills.push(skill);
            }
        }
        // Same first-wins order refresh derives from the lock's BTreeMap.
        settings_skills.sort_by(|a, b| a.name.cmp(&b.name));
        if let Some(result) = crate::project_settings::ensure_skill_settings(
            &project_root,
            &settings_skills,
            &mut lock.settings_seeds,
        )? {
            settings_note = Some(format!("Project settings: {}", result.summary()));
        }
    }

    // Update lock file
    lock.version = 1;
    for legacy in &migrated_pi_extensions {
        lock.remove(legacy);
    }
    installer::record_install(
        &mut lock,
        &results,
        &resolved_source.source,
        resolved_source.source_repo.as_deref(),
        method,
    );
    for (name, preserved_method) in &preserved_auto_skill_methods {
        let Some(entry) = lock.entries.get_mut(name) else {
            continue;
        };
        if entry.kind == config::ItemKind::Skill && entry.method != *preserved_method {
            entry.method = *preserved_method;
            entry.source_hash = config::compute_source_hash(entry);
        }
    }

    // Also record hooks in the lock file. Only record harnesses that the
    // hook actually applies to — a hook with `harnesses: [claude-code]` is
    // a no-op for the other harnesses, so the lock must not claim it was
    // installed there (otherwise verify will false-fail).
    //
    // A Codex prose fallback that found no agent TOML to write into IS
    // recorded: the lock is what tells reconciliation to add the safety block
    // to the first Codex agent installed later, and presence checking knows
    // that an agent-less Codex scope has no artifact to miss.
    let now = config::now_iso();
    for harness in &harnesses {
        for h in &selected_hooks {
            if !h.applies_to(harness.id()) {
                continue;
            }
            let harness_id = harness.id().to_string();
            if let Some(existing) = lock.entries.get_mut(&h.name) {
                if !existing.harnesses.contains(&harness_id) {
                    existing.harnesses.push(harness_id);
                }
                existing.source = resolved_source.source.clone();
                existing.source_repo = resolved_source.source_repo.clone();
                existing.installed_at = now.clone();
                existing.source_hash = config::compute_source_hash(existing);
            } else {
                let mut entry = config::LockEntry {
                    name: h.name.clone(),
                    kind: config::ItemKind::Hook,
                    source: resolved_source.source.clone(),
                    source_repo: resolved_source.source_repo.clone(),
                    harnesses: vec![harness_id],
                    method,
                    installed_at: now.clone(),
                    source_hash: String::new(),
                };
                entry.source_hash = config::compute_source_hash(&entry);
                lock.add(entry);
            }
        }
    }

    lock.save(&lock_path)?;

    // Reconcile: update existing agents with newly installed skills/hooks
    reconcile_agents(global, &source_dir, &harnesses)?;

    let scope = if global { "global" } else { "project" };
    let harness_names: Vec<&str> = harnesses.iter().map(|h| h.name()).collect();

    let mut updated_names: Vec<String> = Vec::new();
    for a in &selected_agents {
        if previously_installed.contains(&a.name) {
            updated_names.push(a.name.clone());
        }
    }
    for s in &selected_skills {
        if previously_installed.contains(&s.name) {
            updated_names.push(s.name.clone());
        }
    }
    for h in &selected_hooks {
        if previously_installed.contains(&h.name) {
            updated_names.push(h.name.clone());
        }
    }
    for ext in &selected_pi_extensions {
        if previously_installed.contains(&ext.name) {
            updated_names.push(ext.name.clone());
        }
    }

    let summary = tui::SummaryData {
        agents: selected_agents.iter().map(|a| a.name.clone()).collect(),
        skills: selected_skills.iter().map(|s| s.name.clone()).collect(),
        hooks: selected_hooks
            .iter()
            .map(|h| (h.name.clone(), h.event.clone()))
            .collect(),
        pi_extensions: if pi_in_harnesses {
            selected_pi_extensions
                .iter()
                .map(|e| e.name.clone())
                .collect()
        } else {
            Vec::new()
        },
        updated: updated_names,
        harnesses: harness_names.iter().map(|h| h.to_string()).collect(),
        notes: {
            let mut notes = Vec::new();
            if !skipped_harnesses.is_empty() {
                notes.push(format!(
                    "Skipped project-only harnesses: {}. Rerun from the target project directory to install those.",
                    skipped_harnesses.join(", ")
                ));
            }
            if let Some(note) = &settings_note {
                notes.push(note.clone());
            }
            if global {
                notes.extend(harnesses.iter().flat_map(|h| {
                    h.summary_paths(true).into_iter().map(move |path| {
                        format!("{} path: {}", h.name(), config::display_path(&path))
                    })
                }));
            }
            if !global && !selected_agents.is_empty() {
                notes.push(
                    "Add per-agent guidance or instructions in vstack.toml, then run `vstack refresh` to apply".into(),
                );
            }
            notes
        },
        method: method.to_string(),
        scope: scope.to_string(),
    };

    // Show summary — TUI if interactive, text if non-interactive
    if !yes && !all && harness_filter.is_none() {
        let action = tui::run_summary_screen(&summary)?;
        if action == tui::SummaryAction::InstallMore {
            // Recursive call to restart
            return run(
                Some(resolved_source.source.clone()),
                global,
                harness_filter,
                agent_filter,
                skill_filter,
                hook_filter,
                pi_extension_filter,
                copy,
                yes,
                all,
                clobber,
                no_auto_skills,
            );
        }
    } else {
        print_install_summary(
            global,
            scope,
            method,
            &resolved_source,
            &harness_names,
            &harnesses,
            &selected_agents,
            &selected_skills,
            &selected_hooks,
            if pi_in_harnesses {
                &selected_pi_extensions
            } else {
                &[]
            },
            &previously_installed,
            &skipped_harnesses,
        );
        if !global && !selected_agents.is_empty() {
            eprintln!(
                "  Add per-agent guidance or instructions in vstack.toml, then run `vstack refresh` to apply"
            );
        }
        if let Some(note) = &settings_note {
            eprintln!("  {note}");
        }
        // Check for CLI updates in non-interactive mode
        crate::commands::update::check_update_hint();
    }

    // Run CLI binary update if requested
    if update_cli {
        eprintln!("\nUpdating vstack binary...\n");
        let _ = crate::commands::update::run(false);
        eprintln!("\nRestart vstack to use the new version.");
    }

    Ok(())
}

fn reconcile_agents(
    global: bool,
    source_dir: &std::path::Path,
    harnesses: &[Harness],
) -> anyhow::Result<()> {
    let lock_path = config::lock_file_path(global);
    let lock = config::LockFile::load(&lock_path)?;
    let mapping = crate::mapping::MappingConfig::load(source_dir);
    let mut project_config = crate::project_config::ProjectConfig::load(&config::project_root());
    project_config.overlay_source_frontmatter(&mapping);
    let writes_project_config = !global && config::project_root() != source_dir;

    // Collect all installed skill names
    let installed_skills: Vec<String> = lock
        .entries
        .iter()
        .filter(|(_, e)| e.kind == config::ItemKind::Skill)
        .map(|(name, _)| name.clone())
        .collect();

    // Collect all installed agent entries
    let agent_entries: Vec<_> = lock
        .entries
        .iter()
        .filter(|(_, e)| e.kind == config::ItemKind::Agent)
        .collect();

    if agent_entries.is_empty() {
        return Ok(());
    }

    // Discover source agents and skills for descriptions
    let source_agents = crate::catalog::discover_agents(source_dir).unwrap_or_default();
    let source_skills = crate::catalog::discover_skills(source_dir).unwrap_or_default();
    // Hooks come from EVERY recorded source, not just the one being installed
    // from: an agent's frontmatter is rewritten below with whatever hook set
    // this function can see, and a hook installed from another source — or
    // from a remote whose cache is absent or refused — is not absent, it is
    // unreadable. Read as they stand, with no fetch: reconciling is not a
    // reason to update a source the user did not name.
    let hook_records = crate::refresh_sources::resolve_source_records_without_update(&lock);
    let all_hooks = crate::refresh_sources::all_source_hooks(
        &crate::refresh_sources::load_refresh_sources(&hook_records.sources),
    );
    // Reconciliation regenerates every agent from every locked hook, so a
    // definition install would refuse fails it before any agent is touched.
    if let Some((name, error)) =
        crate::commands::refresh::uncovered_hook_event(&lock, &all_hooks, None)
    {
        anyhow::bail!("hook {name}: {error}");
    }
    // Hook entries this run cannot read, asked of the same function the agent
    // frontmatter is built from — so the two can never disagree about which
    // entries have no hook. An agent whose set includes one is left exactly as
    // installed: dropping the hook from its frontmatter while the script, the
    // settings.json registration and the lock entry all survive is the
    // inconsistency a successful `add` must not leave behind.
    let undetermined_hooks: Vec<(String, Vec<String>)> = lock
        .entries
        .values()
        .filter(|entry| entry.kind == config::ItemKind::Hook)
        .filter(|entry| crate::resolve::source_hook_for_lock_entry(&all_hooks, entry).is_none())
        .map(|entry| (entry.name.clone(), entry.harnesses.clone()))
        .collect();
    let mut regenerated_codex_agents: Vec<crate::agent::Agent> = Vec::new();
    let mut regenerated_codex_agent_names = std::collections::HashSet::new();

    for (name, entry) in &agent_entries {
        // Same reservation refresh enforces: never regenerate (or
        // save_extracted under) a name that collides with the shared
        // instruction key — a legacy `all` agent would render as both shared
        // and item-specific text.
        if let Err(err) = crate::path_safety::validate_new_item_name(name) {
            eprintln!("Warning: skipping agent reconciliation for {name:?}: {err:#}");
            continue;
        }
        let Some(agent) = source_agents.iter().find(|a| &a.name == *name) else {
            continue;
        };

        let undetermined: Vec<&str> = undetermined_hooks
            .iter()
            .filter(|(_, harnesses)| harnesses.iter().any(|h| entry.harnesses.contains(h)))
            .map(|(hook, _)| hook.as_str())
            .collect();
        if !undetermined.is_empty() {
            eprintln!(
                "  Warning: leaving agent {name} as installed: its hook set is not known this run — {} (run `vstack refresh` once every source is readable)",
                undetermined.join(", ")
            );
            continue;
        }

        // Use project [agent-skills] if present, else source mapping
        let skill_names: Vec<String> =
            if let Some(project_list) = project_config.agent_skills_for(&agent.name) {
                project_list.clone()
            } else {
                mapping.skills_for_agent(&agent.name, &agent.role, &installed_skills)
            };

        let skill_pairs = crate::resolve::resolve_skill_pairs(&skill_names, &source_skills);

        for harness_id in &entry.harnesses {
            if let Some(harness) = Harness::from_id(harness_id)
                && harnesses.contains(&harness)
            {
                let existing_path = harness
                    .agents_dir(global)
                    .join(harness.agent_filename(&agent.name));
                let file_extras = crate::resolve::read_existing_extras(&existing_path, harness);
                if writes_project_config {
                    project_config.save_extracted(
                        &config::project_root(),
                        &agent.name,
                        &file_extras,
                    );
                }
            }
        }

        let extras =
            crate::resolve::build_agent_extras(&project_config, &agent.name, &agent.role, None);

        // Regenerate for each harness this agent is installed to
        for harness_id in &entry.harnesses {
            if let Some(harness) = Harness::from_id(harness_id) {
                // Only reconcile harnesses that were part of this install
                if harnesses.contains(&harness) {
                    let matched_hooks = crate::resolve::matched_installed_hooks_for_agent_harness(
                        &lock,
                        &all_hooks,
                        &mapping,
                        &agent.role,
                        harness.id(),
                    );
                    if harness
                        .generate_agent(agent, global, &skill_pairs, &matched_hooks, &extras)
                        .is_ok()
                        && matches!(harness, Harness::Codex)
                        && regenerated_codex_agent_names.insert(agent.name.clone())
                    {
                        regenerated_codex_agents.push(agent.clone());
                    }
                }
            }
        }
    }

    if !regenerated_codex_agents.is_empty() {
        let codex_fallback_hooks =
            crate::resolve::installed_codex_fallback_hooks(&lock, &all_hooks);
        installer::install_codex_fallback_hooks_for_agents(
            &codex_fallback_hooks,
            global,
            &regenerated_codex_agents,
        )?;
    }

    Ok(())
}
