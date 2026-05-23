use crate::agent;
use crate::agent::Agent;
use crate::config::{self, InstallMethod, LockFile};
use crate::extra;
use crate::harness::Harness;
use crate::hook;
use crate::hook::Hook;
use crate::installer;
use crate::pi_extension::PiExtension;
use crate::skill;
use crate::skill::Skill;
use crate::tui;
use anyhow::Context;
use anyhow::Result;
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
        eprintln!(
            "\nRevert with:\n  vstack remove {}{}",
            revert_names.join(" "),
            scope_flag,
        );
    }
    eprintln!("{bar}\n");
}

struct ResolvedSource {
    source: String,
    label: String,
    dir: PathBuf,
    persist: bool,
}

fn source_label(source: &str) -> String {
    if Path::new(source).exists() {
        return format!("local: {source}");
    }

    let trimmed = source
        .trim_end_matches('/')
        .trim_end_matches(".git")
        .trim_start_matches("https://github.com/")
        .trim_start_matches("http://github.com/")
        .trim_start_matches("git@github.com:");
    trimmed.to_string()
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
        options.push(tui::RepoOption {
            label: source_label(&source),
            source,
        });
    }
    options
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
        // [role-skills] engineer = ["linear-dev", "github"]. Without
        // explicit --skill flags the agent's frontmatter still references
        // linear-dev, but the skill never lands on disk.
        let mut mapping = MappingConfig::default();
        mapping.role_skills.insert(
            "engineer".into(),
            vec!["linear-dev".into(), "github".into()],
        );
        let all = vec![skill("linear-dev", &[]), skill("github", &[])];
        let agents = vec![agent("reviewer-error", AgentRole::Engineer)];
        let mut selected = Vec::<Skill>::new();
        let added = auto_include_agent_skills(&agents, &mapping, &all, &mut selected);
        assert_eq!(added, vec!["github".to_string(), "linear-dev".to_string()]);
        let names: Vec<&str> = selected.iter().map(|s| s.name.as_str()).collect();
        assert!(names.contains(&"linear-dev"));
        assert!(names.contains(&"github"));
    }

    #[test]
    fn already_selected_skills_are_not_duplicated() {
        let mut mapping = MappingConfig::default();
        mapping
            .role_skills
            .insert("engineer".into(), vec!["linear-dev".into()]);
        let all = vec![skill("linear-dev", &[])];
        let agents = vec![agent("rust", AgentRole::Engineer)];
        let mut selected = vec![skill("linear-dev", &[])];
        let added = auto_include_agent_skills(&agents, &mapping, &all, &mut selected);
        assert!(added.is_empty());
        assert_eq!(selected.len(), 1);
    }

    #[test]
    fn transitive_required_dependencies_are_pulled_in() {
        // linear-orch -> linear-dev (required dep). Agent only references
        // linear-orch; auto-include must transitively pull in linear-dev.
        let mut mapping = MappingConfig::default();
        mapping
            .role_skills
            .insert("engineer".into(), vec!["linear-orch".into()]);
        let all = vec![
            skill("linear-orch", &["linear-dev"]),
            skill("linear-dev", &[]),
        ];
        let agents = vec![agent("planner", AgentRole::Engineer)];
        let mut selected = Vec::<Skill>::new();
        let added = auto_include_agent_skills(&agents, &mapping, &all, &mut selected);
        assert!(added.contains(&"linear-orch".into()));
        assert!(added.contains(&"linear-dev".into()));
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
            .insert("engineer".into(), vec!["linear-dev".into()]);
        let all = vec![skill("linear-dev", &[])];
        let mut selected = Vec::<Skill>::new();
        let added = auto_include_agent_skills(&[], &mapping, &all, &mut selected);
        assert!(added.is_empty());
        assert!(selected.is_empty());
    }
}

#[cfg(test)]
mod source_option_tests {
    use super::*;

    #[test]
    fn source_options_include_default_repo_for_fresh_installs() {
        let registry = config::SourceRegistry::default();
        let project_root = std::env::temp_dir().join("vstack_source_options_default_removed");
        let resolved = ResolvedSource {
            source: "/repo/local-vstack".into(),
            label: "local: /repo/local-vstack".into(),
            dir: PathBuf::from("/repo/local-vstack"),
            persist: false,
        };

        let options = build_source_options(&registry, &resolved, &project_root);

        assert_eq!(
            options
                .iter()
                .map(|o| o.source.as_str())
                .collect::<Vec<_>>(),
            vec![crate::REPO, "/repo/local-vstack"]
        );
    }

    #[test]
    fn source_options_do_not_re_add_removed_default_repo() {
        let mut registry = config::SourceRegistry::default();
        registry.forget(crate::REPO);
        let project_root = std::env::temp_dir().join("vstack_source_options_default_removed");
        let resolved = ResolvedSource {
            source: "/repo/local-vstack".into(),
            label: "local: /repo/local-vstack".into(),
            dir: PathBuf::from("/repo/local-vstack"),
            persist: false,
        };

        let options = build_source_options(&registry, &resolved, &project_root);

        assert_eq!(options.len(), 1);
        assert_eq!(options[0].source, "/repo/local-vstack");
    }

    #[test]
    fn source_options_preserve_registered_sources_only() {
        let mut registry = config::SourceRegistry::default();
        registry.remember("owner/custom");
        let project_root = std::env::temp_dir().join("vstack_source_options_registered_only");
        let resolved = ResolvedSource {
            source: "owner/custom".into(),
            label: "owner/custom".into(),
            dir: PathBuf::from("/cache/owner_custom"),
            persist: true,
        };

        let options = build_source_options(&registry, &resolved, &project_root);

        assert_eq!(
            options
                .iter()
                .map(|o| o.source.as_str())
                .collect::<Vec<_>>(),
            vec![crate::REPO, "owner/custom"]
        );
    }
}

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

fn resolve_source_for_app(
    source: Option<&str>,
    registry: &config::SourceRegistry,
    project_root: &Path,
) -> Result<ResolvedSource> {
    match source {
        Some(path) if Path::new(path).exists() => {
            let dir = std::fs::canonicalize(path)?;
            Ok(ResolvedSource {
                source: dir.display().to_string(),
                label: source_label(path),
                dir,
                persist: true,
            })
        }
        Some(source) => Ok(ResolvedSource {
            source: source.to_string(),
            label: source_label(source),
            dir: resolve_source(Some(source))?,
            persist: true,
        }),
        None => {
            // Prefer the source selected for THIS project. Source selection is
            // intentionally project-scoped: choosing a repo while working in
            // one project must not silently change the source used by another.
            if let Some(current) = registry.current_for_project(project_root)
                && let Ok(dir) = resolve_source(Some(current))
            {
                return Ok(ResolvedSource {
                    source: current.to_string(),
                    label: source_label(current),
                    dir,
                    persist: true,
                });
            }

            // Existing projects already record installed item sources in the
            // lock file. Use that before any global/default source so a
            // project's repo choice remains stable across invocations.
            if let Some(current) = source_from_project_lock(project_root)
                && let Ok(dir) = resolve_source(Some(&current))
            {
                return Ok(ResolvedSource {
                    label: source_label(&current),
                    source: current,
                    dir,
                    persist: true,
                });
            }

            // Fallback: walk up from CWD looking for a vstack source
            let mut dir = std::env::current_dir()?;
            loop {
                if crate::resolve::is_vstack_source(&dir) {
                    return Ok(ResolvedSource {
                        source: dir.display().to_string(),
                        label: source_label(dir.to_str().unwrap_or("local")),
                        dir,
                        persist: false,
                    });
                }
                if !dir.pop() {
                    break;
                }
            }

            let source = crate::REPO.to_string();
            Ok(ResolvedSource {
                label: source_label(&source),
                dir: resolve_source(Some(&source))?,
                source,
                persist: true,
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

    let mut registry =
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
        let resolved = resolve_source_for_app(current_source.as_deref(), &registry, &project_root)?;
        if resolved.persist {
            if global {
                registry.remember(&resolved.source);
            } else {
                registry.remember_for_project(&project_root, &resolved.source);
            }
            registry.save(&config::source_registry_path())?;
        }
        let source_dir = resolved.dir.clone();
        let agents_dir = source_dir.join("agents");
        let skills_dir = source_dir.join("skills");
        let hooks_dir = source_dir.join("hooks");
        let pi_ext_dir = source_dir.join("pi-extensions");

        let all_agents = agent::discover_agents(&agents_dir)?;
        let all_skills = skill::discover_skills(&skills_dir)?;
        let all_hooks = hook::discover_hooks(&hooks_dir)?;
        let all_pi_extensions =
            crate::pi_extension::discover_pi_extensions(&pi_ext_dir).unwrap_or_default();
        let extras = extra::discover_extras(&source_dir)?;
        let dep_graph = skill::build_dependency_graph(&all_skills);

        // Filter semantics: passing any item filter restricts the install to
        // only the kinds named; unfiltered kinds get nothing. Use `--all` for
        // "everything," or `--skill '*'` as the per-kind "all of this kind"
        // sentinel when combining with narrower filters.
        let any_item_filter = agent_filter.is_some()
            || skill_filter.is_some()
            || hook_filter.is_some()
            || pi_extension_filter.is_some();
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
            eprintln!(
                "No agents, skills, hooks, pi-packages, or extras found in {}",
                source_dir.display()
            );
            return Ok(());
        }

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
        } else if yes || harness_filter.is_some() {
            let harnesses = if let Some(ref filter) = harness_filter {
                filter.iter().filter_map(|f| Harness::from_id(f)).collect()
            } else {
                Harness::ALL
                    .iter()
                    .copied()
                    .filter(|h| h.is_detected())
                    .collect::<Vec<_>>()
            };

            if harnesses.is_empty() {
                eprintln!("No harnesses selected or detected. Use --agent to specify.");
                return Ok(());
            }

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
    let mapping = crate::mapping::MappingConfig::load(&source_dir);

    // vstack#71: auto-install skills referenced by selected agents.
    // Without this, `vstack add --agent reviewer-error` produces a
    // .agents/reviewer-error.md whose `skills:` frontmatter points at
    // skills/linear-dev/SKILL.md that was never copied to the
    // install mirror. Walk each agent's mapping-resolved skill set
    // (agent-skills + role-skills + prefix matches) plus transitive
    // dependencies and add any missing canonical skills.
    if !no_auto_skills && !selected_agents.is_empty() {
        let skills_source_dir = source_dir.join("skills");
        let all_skills = skill::discover_skills(&skills_source_dir).unwrap_or_default();
        let added = auto_include_agent_skills(
            &selected_agents,
            &mapping,
            &all_skills,
            &mut selected_skills,
        );
        if !added.is_empty() {
            eprintln!("Auto-installed dependent skills: {}", added.join(", "));
        }
    }

    // Whether we should write/update the project-level vstack.toml.
    // Suppress when:
    //   - --global install (project files are not the install target)
    //   - the "project root" we'd write to IS the vstack source repo
    //     itself (writing project-customization sections there would
    //     clobber the upstream source mapping config)
    let writes_project_config = !global && config::project_root() != source_dir;

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
        crate::project_config::ensure_project_config(
            &config::project_root(),
            &agent_names,
            &skill_names,
        );

        let harnesses_by_agent: std::collections::HashMap<String, Vec<Harness>> = selected_agents
            .iter()
            .map(|agent| (agent.name.clone(), harnesses.clone()))
            .collect();
        crate::project_config::write_agent_frontmatter_defaults(
            &config::project_root(),
            &selected_agents,
            &harnesses_by_agent,
            &mapping,
        );
    }

    let mut project_config = crate::project_config::ProjectConfig::load(&config::project_root());
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

    // Perform installation
    let mut results = Vec::new();
    let mut log_lines: Vec<String> = Vec::new();

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

            let matched_hooks: Vec<hook::Hook> = mapping
                .hooks_for_agent(&a.role, &selected_hooks)
                .into_iter()
                .cloned()
                .collect();

            let existing_path = harness
                .agents_dir(global)
                .join(harness.agent_filename(&a.name));
            let file_extras = crate::resolve::read_existing_extras(&existing_path, *harness);
            if writes_project_config {
                project_config.save_extracted(&config::project_root(), &a.name, &file_extras);
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
            let result = installer::install_skill(s, *harness, global, method, skill_instr)?;
            log_lines.push(result.detail.clone());
            results.push(result);
        }

        for h in &selected_hooks {
            let detail = installer::install_hook(h, *harness, global, &selected_agents)?;
            log_lines.push(detail);
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

    // Write computed agent→skill mappings to project vstack.toml.
    // Must happen BEFORE lock timestamps are captured so that the
    // vstack.toml mtime doesn't post-date installed_at (which would
    // make every item appear outdated on next launch).
    if writes_project_config {
        crate::project_config::write_agent_skills(&config::project_root(), &agent_skill_map);
    }

    // Update lock file
    let lock_path = config::lock_file_path(global);
    let mut lock = LockFile::load(&lock_path).unwrap_or_default();
    lock.version = 1;
    for legacy in &migrated_pi_extensions {
        lock.remove(legacy);
    }
    installer::record_install(&mut lock, &results, &resolved_source.source, method);

    // Also record hooks in the lock file. Only record harnesses that the
    // hook actually applies to — a hook with `harnesses: [claude-code]` is
    // a no-op for the other harnesses, so the lock must not claim it was
    // installed there (otherwise verify will false-fail).
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
                existing.installed_at = now.clone();
                existing.source_hash = config::compute_source_hash(existing);
            } else {
                let mut entry = config::LockEntry {
                    name: h.name.clone(),
                    kind: config::ItemKind::Hook,
                    source: resolved_source.source.clone(),
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

fn resolve_source(source: Option<&str>) -> Result<PathBuf> {
    match source {
        Some(path) if Path::new(path).exists() => Ok(std::fs::canonicalize(path)?),
        Some(source) if looks_like_remote(source) => clone_or_update(source),
        Some(source) => {
            anyhow::bail!(
                "Source not found: {source}\n\
                 Use a local path or GitHub shorthand (owner/repo)"
            );
        }
        None => {
            // Walk up from CWD to find a local vstack repo first
            let mut dir = std::env::current_dir()?;
            loop {
                if crate::resolve::is_vstack_source(&dir) {
                    return Ok(dir);
                }
                if !dir.pop() {
                    break;
                }
            }
            // Fall back to default remote repo
            clone_or_update(crate::REPO)
        }
    }
}

fn source_from_project_lock(project_root: &Path) -> Option<String> {
    let lock = config::LockFile::load(&project_root.join(".vstack-lock.json")).ok()?;
    let mut counts = std::collections::BTreeMap::<String, usize>::new();
    for entry in lock.entries.values() {
        *counts.entry(entry.source.clone()).or_default() += 1;
    }
    counts
        .into_iter()
        .max_by(|(a_source, a_count), (b_source, b_count)| {
            a_count.cmp(b_count).then_with(|| b_source.cmp(a_source))
        })
        .map(|(source, _)| source)
}

fn looks_like_remote(source: &str) -> bool {
    // owner/repo, https://github.com/..., git@github.com:...
    source.contains('/') && !source.starts_with('.') && !source.starts_with('/')
        || source.starts_with("https://")
        || source.starts_with("git@")
}

/// Clone or update a remote repo into ~/.vstack/cache/<owner>/<repo>
fn clone_or_update(source: &str) -> Result<PathBuf> {
    let cache_dir = crate::config::global_base_dir()
        .join(".vstack")
        .join("cache");
    std::fs::create_dir_all(&cache_dir)?;

    // Normalize source to a git URL and a cache key
    let (git_url, cache_key) = if source.starts_with("https://") || source.starts_with("git@") {
        // Full URL — extract owner/repo for cache key
        let key = source
            .trim_end_matches('/')
            .trim_end_matches(".git")
            .rsplit('/')
            .take(2)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect::<Vec<_>>()
            .join("_");
        (source.to_string(), key)
    } else {
        // owner/repo shorthand
        let url = format!("https://github.com/{}.git", source);
        let key = source.replace('/', "_");
        (url, key)
    };

    let repo_dir = cache_dir.join(&cache_key);

    if repo_dir.join(".git").exists() {
        // Update existing clone (handles force-pushed histories)
        eprintln!("Updating cached repo...");
        let fetch = std::process::Command::new("git")
            .args(["fetch", "origin", "--quiet"])
            .current_dir(&repo_dir)
            .status();
        if fetch.is_ok_and(|s| s.success()) {
            let _ = std::process::Command::new("git")
                .args(["reset", "--hard", "origin/HEAD"])
                .current_dir(&repo_dir)
                .stderr(std::process::Stdio::null())
                .status();
        }
    } else {
        // Fresh shallow clone
        eprintln!("Cloning {}...", git_url);
        let status = std::process::Command::new("git")
            .args([
                "clone",
                "--depth",
                "1",
                &git_url,
                repo_dir.to_str().unwrap(),
            ])
            .status()
            .context("failed to run git clone — is git installed?")?;
        if !status.success() {
            anyhow::bail!(
                "git clone failed. For private repos, make sure you have access:\n\
                 \n\
                 SSH:   git clone git@github.com:{source}.git\n\
                 HTTPS: gh auth login\n\
                 Token: export GH_TOKEN=<your-token>"
            );
        }
    }

    if !crate::resolve::is_vstack_source(&repo_dir) {
        anyhow::bail!(
            "Cloned repo doesn't look like a vstack repo (no agents/, skills/, or hooks/ found)"
        );
    }

    Ok(repo_dir)
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

    if agent_entries.is_empty() || installed_skills.is_empty() {
        return Ok(());
    }

    // Discover source agents and skills for descriptions
    let agents_dir = source_dir.join("agents");
    let skills_dir = source_dir.join("skills");
    let hooks_dir = source_dir.join("hooks");

    let source_agents = crate::agent::discover_agents(&agents_dir).unwrap_or_default();
    let source_skills = crate::skill::discover_skills(&skills_dir).unwrap_or_default();
    let source_hooks = crate::hook::discover_hooks(&hooks_dir).unwrap_or_default();

    for (name, entry) in &agent_entries {
        let Some(agent) = source_agents.iter().find(|a| &a.name == *name) else {
            continue;
        };

        // Use project [agent-skills] if present, else source mapping
        let skill_names: Vec<String> =
            if let Some(project_list) = project_config.agent_skills_for(&agent.name) {
                project_list.clone()
            } else {
                mapping.skills_for_agent(&agent.name, &agent.role, &installed_skills)
            };

        let skill_pairs = crate::resolve::resolve_skill_pairs(&skill_names, &source_skills);

        let matched_hooks: Vec<crate::hook::Hook> = mapping
            .hooks_for_agent(&agent.role, &source_hooks)
            .into_iter()
            .cloned()
            .collect();

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
                    let _ = harness.generate_agent(
                        agent,
                        global,
                        &skill_pairs,
                        &matched_hooks,
                        &extras,
                    );
                }
            }
        }
    }

    Ok(())
}
