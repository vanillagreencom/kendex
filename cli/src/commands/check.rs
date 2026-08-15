use crate::config::{self, ItemKind, LockEntry, LockFile};
use crate::frontmatter::split_yaml_frontmatter;
use crate::harness::Harness;
use crate::scope::ScopeFilter;
use anyhow::{Context, Result};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

fn skill_disk_path(global: bool, name: &str) -> PathBuf {
    if global {
        config::global_state_dir().join("skills").join(name)
    } else {
        config::project_root()
            .join(".agents")
            .join("skills")
            .join(name)
    }
}

fn find_installed_agent_file(global: bool, agent: &LockEntry) -> Option<PathBuf> {
    for harness in Harness::ALL {
        let dir = harness.agents_dir(global);
        let path = dir.join(format!("{}.md", agent.name));
        if path.exists() {
            return Some(path);
        }
        let toml = dir.join(format!("{}.toml", agent.name));
        if toml.exists() {
            return Some(toml);
        }
    }
    None
}

fn parse_skills_field(frontmatter: &str) -> Vec<String> {
    for line in frontmatter.lines() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix("skills:") {
            let rest = rest.trim();
            // YAML inline list `skills: a, b, c` (Cursor / Claude / OpenCode
            // generated agents) — split on commas.
            if !rest.is_empty() && !rest.starts_with('[') {
                return rest
                    .split(',')
                    .map(|s| s.trim().trim_matches('"').trim_matches('\''))
                    .filter(|s| !s.is_empty())
                    .map(String::from)
                    .collect();
            }
            // YAML inline list `skills: [a, b]`
            if let Some(stripped) = rest.strip_prefix('[').and_then(|r| r.strip_suffix(']')) {
                return stripped
                    .split(',')
                    .map(|s| s.trim().trim_matches('"').trim_matches('\''))
                    .filter(|s| !s.is_empty())
                    .map(String::from)
                    .collect();
            }
        }
    }
    Vec::new()
}

fn parse_required_skills_section(content: &str) -> Vec<String> {
    let Some(start) = content.find("## Required Skills") else {
        return Vec::new();
    };
    let after_header = &content[start + "## Required Skills".len()..];
    let section = after_header
        .find("\n## ")
        .map(|end| &after_header[..end])
        .unwrap_or(after_header);

    section
        .lines()
        .filter_map(|line| {
            let trimmed = line.trim_start();
            let rest = trimmed.strip_prefix("- `")?;
            let end = rest.find('`')?;
            let name = rest[..end].trim();
            if name.is_empty() {
                None
            } else {
                Some(name.to_string())
            }
        })
        .collect()
}

fn read_agent_skills(path: &Path) -> Vec<String> {
    let Ok(content) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    if let Ok((fm, _body)) = split_yaml_frontmatter(&content) {
        return parse_skills_field(&fm);
    }
    // Codex agents keep their skill inventory inside developer_instructions.
    if let Some(body) = crate::agent::extract_body_from_codex_toml(&content) {
        let skills = parse_required_skills_section(&body);
        if !skills.is_empty() {
            return skills;
        }
    }

    // Backward compatibility for older Codex agent files generated with an
    // unsupported top-level `skills = [...]` field.
    for line in content.lines() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix("skills =") {
            let rest = rest.trim();
            if let Some(stripped) = rest.strip_prefix('[').and_then(|r| r.strip_suffix(']')) {
                return stripped
                    .split(',')
                    .map(|s| s.trim().trim_matches('"').trim_matches('\''))
                    .filter(|s| !s.is_empty())
                    .map(String::from)
                    .collect();
            }
        }
    }
    Vec::new()
}

/// Output and network controls for `vstack check`.
#[derive(Debug, Clone, Copy, Default)]
pub struct CheckOptions {
    /// Print the report as JSON on stdout instead of the human report on stderr.
    pub json: bool,
    /// Print nothing when no drift was found; the human report drops the
    /// per-item listing and keeps only the drift sections.
    pub quiet: bool,
    /// Skip every network call: no CLI version lookup and no remote source
    /// cache fetch. Sources are read exactly as cached.
    pub offline: bool,
    /// Suppress the "available in source but not installed" case.
    pub no_available: bool,
}

/// What the process exit code reports. `Clean` → 0, `Drift` → 1; a check that
/// could not run returns `Err` and exits 2 — see `main.rs`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CheckOutcome {
    Clean,
    Drift,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Item {
    pub name: String,
    pub kind: ItemKind,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct AvailableItem {
    pub name: String,
    pub kind: ItemKind,
    /// The lock `source` string the item was found in.
    pub source: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct MissingSkillRef {
    pub agent: String,
    pub skill: String,
}

/// One scope's findings. Every list is sorted by name so the human, JSON, and
/// hook renderings are stable across runs.
#[derive(Debug, Clone, Serialize, Default)]
pub struct ScopeReport {
    pub scope: &'static str,
    /// Lock entries in this scope.
    pub installed: usize,
    /// Lock entries whose source content changed since install — `vstack refresh`.
    pub outdated: Vec<Item>,
    /// Lock entries whose source resolves but no longer ships the item —
    /// `vstack remove <name>`.
    pub removed: Vec<Item>,
    /// Skills present on disk but absent from the lock — `vstack add` recovers.
    pub orphaned: Vec<Item>,
    /// Lock entries whose canonical files are gone from disk.
    pub phantom: Vec<Item>,
    /// Installed agents referencing skills that are not installed.
    pub missing_skill_refs: Vec<MissingSkillRef>,
    /// Items a declared source ships that this scope never installed —
    /// `vstack add --<kind> <name>`, pending user approval.
    pub available: Vec<AvailableItem>,
    /// Entries neither outdated nor removed, in lock order (human listing only).
    #[serde(skip)]
    pub current: Vec<Item>,
}

impl ScopeReport {
    pub fn has_drift(&self) -> bool {
        !(self.outdated.is_empty()
            && self.removed.is_empty()
            && self.orphaned.is_empty()
            && self.phantom.is_empty()
            && self.missing_skill_refs.is_empty()
            && self.available.is_empty())
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct CheckReport {
    /// JSON shape version; bump on any incompatible field change.
    pub version: u32,
    pub cli_version: &'static str,
    pub cli_hash: &'static str,
    pub drift: bool,
    pub scopes: Vec<ScopeReport>,
}

impl CheckReport {
    pub fn outcome(&self) -> CheckOutcome {
        if self.drift {
            CheckOutcome::Drift
        } else {
            CheckOutcome::Clean
        }
    }
}

pub fn run(scope: ScopeFilter, opts: CheckOptions) -> Result<CheckOutcome> {
    let report = gather(scope, opts)?;

    if opts.json {
        println!("{}", config::to_json_pretty(&report)?);
        return Ok(report.outcome());
    }

    if !opts.quiet {
        eprintln!("vstack {} ({})", report.cli_version, report.cli_hash);
        // The CLI version lookup is a human hint, not drift, so machine and
        // quiet modes never pay for it; `--offline` forbids it outright.
        if !opts.offline
            && let Some(remote_version) = crate::commands::update::get_remote_version()
        {
            if remote_version != report.cli_version {
                eprintln!(
                    "  CLI update available: {} → {}  (run: vstack update)",
                    report.cli_version, remote_version
                );
            } else {
                eprintln!("  CLI is up to date.");
            }
        }
    }

    let mut out = String::new();
    for scope_report in &report.scopes {
        render_scope(&mut out, scope_report, opts.quiet);
    }
    if !out.is_empty() {
        eprint!("{out}");
    }
    Ok(report.outcome())
}

/// Compute the report without printing. Refreshes remote source caches
/// (bounded by [`config::REMOTE_CACHE_TTL`]) unless offline; performs no other
/// side effect.
pub fn gather(scope: ScopeFilter, opts: CheckOptions) -> Result<CheckReport> {
    let mut scopes = Vec::new();
    for &global in scope.globals() {
        let lock_path = config::lock_file_path(global);
        let lock = LockFile::load(&lock_path)
            .with_context(|| format!("loading lock file {}", lock_path.display()))?;
        if !opts.offline {
            config::refresh_remote_caches_older_than(&lock, Some(config::REMOTE_CACHE_TTL));
        }
        if let Some(scope_report) = check_scope(global, &lock, opts) {
            scopes.push(scope_report);
        }
    }
    let drift = scopes.iter().any(ScopeReport::has_drift);
    Ok(CheckReport {
        version: 1,
        cli_version: env!("CARGO_PKG_VERSION"),
        cli_hash: env!("VSTACK_GIT_HASH"),
        drift,
        scopes,
    })
}

/// Names each resolved source ships, per kind, keyed by the lock `source`
/// string. Pi extensions also register their legacy names so a lock entry
/// recorded under an old name is neither "removed" nor re-offered.
struct SourceCatalog {
    names: HashMap<ItemKind, HashSet<String>>,
    /// Kinds `vstack add` can install by name filter, in offer order.
    offered: Vec<(ItemKind, Vec<String>)>,
}

fn load_source_catalog(source_root: &Path) -> SourceCatalog {
    let mut names: HashMap<ItemKind, HashSet<String>> = HashMap::new();
    let mut offered = Vec::new();

    let agents: Vec<String> = crate::catalog::discover_agents(source_root)
        .unwrap_or_default()
        .into_iter()
        .map(|a| a.name)
        .collect();
    names.insert(ItemKind::Agent, agents.iter().cloned().collect());
    offered.push((ItemKind::Agent, agents));

    let skills: Vec<String> = crate::catalog::discover_skills(source_root)
        .unwrap_or_default()
        .into_iter()
        .map(|s| s.name)
        .collect();
    names.insert(ItemKind::Skill, skills.iter().cloned().collect());
    offered.push((ItemKind::Skill, skills));

    let hooks: Vec<String> = crate::catalog::discover_hooks(source_root)
        .unwrap_or_default()
        .into_iter()
        .map(|h| h.name)
        .collect();
    names.insert(ItemKind::Hook, hooks.iter().cloned().collect());
    offered.push((ItemKind::Hook, hooks));

    let pi: Vec<String> = crate::catalog::discover_pi_extensions(source_root)
        .unwrap_or_default()
        .into_iter()
        .map(|e| e.name)
        .collect();
    let mut pi_names: HashSet<String> = pi.iter().cloned().collect();
    for name in &pi {
        for legacy in crate::pi_extension::legacy_names_for(name) {
            pi_names.insert((*legacy).to_string());
        }
    }
    names.insert(ItemKind::PiExtension, pi_names);
    offered.push((ItemKind::PiExtension, pi));

    // Extras install through the TUI only, so they are never offered; they
    // still count for the removed-upstream case.
    names.insert(
        ItemKind::Extra,
        crate::catalog::discover_extras(source_root)
            .unwrap_or_default()
            .into_iter()
            .map(|e| e.name().to_string())
            .collect(),
    );

    SourceCatalog { names, offered }
}

fn check_scope(global: bool, lock: &LockFile, opts: CheckOptions) -> Option<ScopeReport> {
    // Scan disk for skills that should be in the lock but aren't
    let disk_skills = config::scan_installed_skills_on_disk(global);
    let lock_names: HashSet<&str> = lock.entries.keys().map(|s| s.as_str()).collect();
    let mut orphaned: Vec<Item> = disk_skills
        .iter()
        .filter(|d| !lock_names.contains(d.name.as_str()))
        .map(|d| Item {
            name: d.name.clone(),
            kind: ItemKind::Skill,
        })
        .collect();
    orphaned.sort_by(|a, b| a.name.cmp(&b.name));

    if lock.entries.is_empty() && orphaned.is_empty() {
        return None;
    }

    // Check for lock entries whose files are missing from disk
    let disk_skill_names: HashSet<&str> = disk_skills.iter().map(|d| d.name.as_str()).collect();
    let phantom: Vec<Item> = lock
        .entries
        .values()
        .filter(|e| e.kind == ItemKind::Skill && !disk_skill_names.contains(e.name.as_str()))
        // Only report if the canonical dir is truly gone
        .filter(|e| !skill_disk_path(global, &e.name).exists())
        .map(|e| Item {
            name: e.name.clone(),
            kind: e.kind,
        })
        .collect();

    // Resolve each distinct lock source once. An unresolvable source (cache
    // never cloned, path gone) yields no catalog: its entries can be neither
    // "removed" nor offered, and staleness falls through to the hash check.
    let mut catalogs: HashMap<&str, Option<SourceCatalog>> = HashMap::new();
    for entry in lock.entries.values() {
        catalogs.entry(entry.source.as_str()).or_insert_with(|| {
            config::resolve_source_path(&entry.source)
                .as_deref()
                .map(load_source_catalog)
        });
    }

    let mut outdated = Vec::new();
    let mut removed = Vec::new();
    let mut current = Vec::new();
    for entry in lock.entries.values() {
        let item = Item {
            name: entry.name.clone(),
            kind: entry.kind,
        };
        // "Removed" needs positive evidence: the source still ships other
        // items of this kind, just not this one. A kind that discovers to
        // nothing (layout moved, catalog config broken) falls through to the
        // hash check rather than condemning every entry.
        let shipped = catalogs
            .get(entry.source.as_str())
            .and_then(Option::as_ref)
            .and_then(|catalog| catalog.names.get(&entry.kind))
            .filter(|names| !names.is_empty())
            .map(|names| names.contains(&entry.name));
        match shipped {
            Some(false) => removed.push(item),
            _ if config::is_source_changed(entry) => outdated.push(item),
            _ => current.push(item),
        }
    }

    // vstack#71: for every installed agent, verify each skill its
    // frontmatter references is actually installed. The bug bites
    // when [role-skills] declares a skill the user never ran
    // `vstack add --skill <name>` for, and the agent ends up
    // referencing a SKILL.md that does not exist on disk.
    let installed_skill_names: HashSet<&str> = lock
        .entries
        .values()
        .filter(|e| e.kind == ItemKind::Skill)
        .map(|e| e.name.as_str())
        .chain(disk_skill_names.iter().copied())
        .collect();
    let mut missing_skill_refs = Vec::new();
    for agent in lock.entries.values().filter(|e| e.kind == ItemKind::Agent) {
        let Some(agent_path) = find_installed_agent_file(global, agent) else {
            continue;
        };
        let mut skills = read_agent_skills(&agent_path);
        skills.sort();
        skills.dedup();
        for skill_name in skills {
            if installed_skill_names.contains(skill_name.as_str())
                || skill_disk_path(global, &skill_name)
                    .join("SKILL.md")
                    .exists()
            {
                continue;
            }
            missing_skill_refs.push(MissingSkillRef {
                agent: agent.name.clone(),
                skill: skill_name,
            });
        }
    }

    // Available: shipped by a declared source, absent from the lock under any
    // kind (lock keys are bare names). A kind is offered only where the scope
    // already installs that kind — a global scope holding nothing but Pi
    // packages is not asking for agents, and a project without Pi packages
    // is not asking for them.
    let mut available = Vec::new();
    if !opts.no_available {
        let installed_kinds: HashSet<ItemKind> = lock.entries.values().map(|e| e.kind).collect();
        let mut sources: Vec<&str> = catalogs.keys().copied().collect();
        sources.sort();
        let mut seen: HashSet<&str> = HashSet::new();
        for source in sources {
            let Some(catalog) = catalogs.get(source).and_then(Option::as_ref) else {
                continue;
            };
            for (kind, names) in &catalog.offered {
                if !installed_kinds.contains(kind) {
                    continue;
                }
                for name in names {
                    let installed = lock_names.contains(name.as_str())
                        || crate::pi_extension::legacy_names_for(name)
                            .iter()
                            .any(|legacy| lock_names.contains(legacy));
                    if installed || !seen.insert(name.as_str()) {
                        continue;
                    }
                    available.push(AvailableItem {
                        name: name.clone(),
                        kind: *kind,
                        source: source.to_string(),
                    });
                }
            }
        }
        available.sort_by(|a, b| a.name.cmp(&b.name));
    }

    Some(ScopeReport {
        scope: if global { "global" } else { "project" },
        installed: lock.entries.len(),
        outdated,
        removed,
        orphaned,
        phantom,
        missing_skill_refs,
        available,
        current,
    })
}

fn add_flag_for(kind: ItemKind) -> &'static str {
    match kind {
        ItemKind::Agent => "--agent",
        ItemKind::Skill => "--skill",
        ItemKind::Hook => "--hook",
        ItemKind::PiExtension => "--pi-extension",
        ItemKind::Extra => "",
    }
}

fn plural_label(kind: ItemKind) -> &'static str {
    match kind {
        ItemKind::Agent => "agents",
        ItemKind::Skill => "skills",
        ItemKind::Hook => "hooks",
        ItemKind::PiExtension => "pi-packages",
        ItemKind::Extra => "extras",
    }
}

/// Human report for one scope. `quiet` drops the header and per-item listing
/// and prints nothing at all for a scope without drift.
fn render_scope(out: &mut String, report: &ScopeReport, quiet: bool) {
    use std::fmt::Write as _;

    if quiet && !report.has_drift() {
        return;
    }

    if quiet {
        let _ = writeln!(out, "vstack drift — {} scope:", report.scope);
    } else {
        let _ = writeln!(
            out,
            "\n{} scope: {} item(s)",
            report.scope, report.installed
        );
        for item in &report.current {
            let _ = writeln!(out, "  ✓ {} ({})", item.name, item.kind);
        }
        for item in &report.outdated {
            let _ = writeln!(out, "  ! {} ({})  ← outdated", item.name, item.kind);
        }
        for item in &report.removed {
            let _ = writeln!(
                out,
                "  ✗ {} ({})  ← removed from source",
                item.name, item.kind
            );
        }
    }

    if !report.outdated.is_empty() {
        let _ = writeln!(
            out,
            "\n  {} outdated — run `vstack refresh` to update:",
            report.outdated.len()
        );
        for item in &report.outdated {
            let _ = writeln!(out, "    ! {} ({})", item.name, item.kind);
        }
    }

    if !report.removed.is_empty() {
        let _ = writeln!(
            out,
            "\n  {} no longer in source — run `vstack remove <name>`:",
            report.removed.len()
        );
        for item in &report.removed {
            let _ = writeln!(out, "    ✗ {} ({})", item.name, item.kind);
        }
    }

    if !report.orphaned.is_empty() {
        let _ = writeln!(
            out,
            "\n  {} installed on disk but missing from lock — run `vstack add` to recover:",
            report.orphaned.len()
        );
        for item in &report.orphaned {
            let _ = writeln!(out, "    ? {} ({})", item.name, item.kind);
        }
    }

    if !report.phantom.is_empty() {
        let _ = writeln!(
            out,
            "\n  {} in lock but missing from disk — run `vstack add` to clean up, or `vstack remove <name>`:",
            report.phantom.len()
        );
        for item in &report.phantom {
            let _ = writeln!(out, "    ✗ {} ({})", item.name, item.kind);
        }
    }

    if !report.missing_skill_refs.is_empty() {
        let agents: HashSet<&str> = report
            .missing_skill_refs
            .iter()
            .map(|r| r.agent.as_str())
            .collect();
        let _ = writeln!(
            out,
            "\n  {} agent(s) reference uninstalled skill(s):",
            agents.len()
        );
        for r in &report.missing_skill_refs {
            let _ = writeln!(
                out,
                "    ✗ agent {} references skill {} but it's not installed; run `vstack add --skill {} .` or `vstack add` to auto-install dependent skills.",
                r.agent, r.skill, r.skill
            );
        }
    }

    if !report.available.is_empty() {
        let _ = writeln!(
            out,
            "\n  {} available in source but not installed — suggestions only, ask before adding:",
            report.available.len()
        );
        for kind in [
            ItemKind::Agent,
            ItemKind::Skill,
            ItemKind::Hook,
            ItemKind::PiExtension,
        ] {
            let names: Vec<&str> = report
                .available
                .iter()
                .filter(|a| a.kind == kind)
                .map(|a| a.name.as_str())
                .collect();
            if names.is_empty() {
                continue;
            }
            let _ = writeln!(
                out,
                "    + {} (`vstack add {} <name>`): {}",
                plural_label(kind),
                add_flag_for(kind),
                names.join(", ")
            );
        }
    }
}

#[cfg(test)]
mod parse_skills_field_tests {
    use super::{parse_required_skills_section, parse_skills_field};

    #[test]
    fn comma_separated_inline() {
        // Real-world shape from .claude/agents/<name>.md.
        let fm = "name: reviewer-error\nskills: dev, linear\nrole: engineer";
        let skills = parse_skills_field(fm);
        assert_eq!(skills, vec!["dev".to_string(), "linear".to_string()]);
    }

    #[test]
    fn yaml_inline_list_brackets() {
        let fm = "name: rust\nskills: [rust-tooling, rust-runtime, \"rust-unsafe\"]";
        let skills = parse_skills_field(fm);
        assert_eq!(
            skills,
            vec![
                "rust-tooling".to_string(),
                "rust-runtime".to_string(),
                "rust-unsafe".to_string(),
            ]
        );
    }

    #[test]
    fn quoted_values_are_unwrapped() {
        let fm = "skills: \"github\", 'linear'";
        let skills = parse_skills_field(fm);
        assert_eq!(skills, vec!["github".to_string(), "linear".to_string()]);
    }

    #[test]
    fn empty_or_missing_field_yields_empty_vec() {
        assert!(parse_skills_field("name: x").is_empty());
        assert!(parse_skills_field("skills:").is_empty());
        assert!(parse_skills_field("skills: []").is_empty());
    }

    #[test]
    fn required_skills_section_lists_codex_skill_names() {
        let body = "# Agent\n\n## Required Skills\n\n- `dev`: Delegation (`.agents/skills/dev/SKILL.md`)\n- `github`: GitHub helpers (`.agents/skills/github/SKILL.md`)\n\n## Other\n\nText.";
        let skills = parse_required_skills_section(body);
        assert_eq!(skills, vec!["dev".to_string(), "github".to_string()]);
    }

    #[test]
    fn missing_required_skills_section_yields_empty_vec() {
        assert!(parse_required_skills_section("# Agent\n\n## Notes\n").is_empty());
    }
}

#[cfg(test)]
mod scope_report_tests {
    use super::*;
    use crate::config::{InstallMethod, LockEntry};
    use crate::test_util::{with_home_and_config, with_project_root};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn tmpdir(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "vstack-check-{label}-{}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write_skill(source: &Path, name: &str, body: &str) {
        let dir = source.join("skills").join(name);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("SKILL.md"),
            format!("---\nname: {name}\ndescription: {name} skill\n---\n\n{body}\n"),
        )
        .unwrap();
    }

    fn write_hook(source: &Path, name: &str) {
        std::fs::create_dir_all(source.join("hooks")).unwrap();
        std::fs::write(
            source.join("hooks").join(format!("{name}.sh")),
            format!(
                "#!/usr/bin/env bash\n# ---\n# name: {name}\n# event: PreToolUse\n# matcher: Bash\n# description: {name}\n# ---\nexit 0\n"
            ),
        )
        .unwrap();
    }

    fn write_agent(source: &Path, name: &str) {
        std::fs::create_dir_all(source.join("agents")).unwrap();
        std::fs::write(
            source.join("agents").join(format!("{name}.md")),
            format!("---\nname: {name}\ndescription: {name}\nmodel: sonnet\nrole: engineer\n---\n\nbody\n"),
        )
        .unwrap();
    }

    /// Lock entry with the hash the source has RIGHT NOW, so it reads as
    /// current until the source changes.
    fn locked(source: &Path, kind: ItemKind, name: &str) -> LockEntry {
        let mut entry = LockEntry {
            name: name.into(),
            kind,
            source: source.to_string_lossy().into_owned(),
            source_repo: None,
            harnesses: vec!["claude-code".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-08-15T00:00:00Z".into(),
            source_hash: String::new(),
        };
        entry.source_hash = config::compute_source_hash(&entry);
        entry
    }

    /// Materialize a project-scope skill so it is neither phantom nor orphaned.
    fn install_skill_on_disk(project: &Path, name: &str) {
        let dir = project.join(".agents").join("skills").join(name);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("SKILL.md"), "installed\n").unwrap();
        std::fs::write(dir.join(".vstack-refreshed"), "").unwrap();
    }

    fn names(items: &[Item]) -> Vec<&str> {
        items.iter().map(|i| i.name.as_str()).collect()
    }

    fn with_sandbox<R>(label: &str, body: impl FnOnce(&Path, &Path) -> R) -> R {
        let root = tmpdir(label);
        let home = root.join("home");
        let config_dir = root.join("config");
        let project = root.join("project");
        let source = root.join("source");
        for dir in [&home, &config_dir, &project, &source] {
            std::fs::create_dir_all(dir).unwrap();
        }
        let result = with_home_and_config(&home, &config_dir, || {
            with_project_root(&project, || body(&project, &source))
        });
        let _ = std::fs::remove_dir_all(&root);
        result
    }

    #[test]
    fn empty_lock_and_empty_disk_yields_no_scope_report() {
        with_sandbox("empty", |_project, _source| {
            let lock = LockFile::default();
            assert!(check_scope(false, &lock, CheckOptions::default()).is_none());
        });
    }

    #[test]
    fn current_install_against_unchanged_source_is_clean() {
        with_sandbox("clean", |project, source| {
            write_skill(source, "alpha", "one");
            install_skill_on_disk(project, "alpha");
            let mut lock = LockFile::default();
            lock.add(locked(source, ItemKind::Skill, "alpha"));

            let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
            assert!(!report.has_drift(), "{report:?}");
            assert_eq!(names(&report.current), vec!["alpha"]);
        });
    }

    #[test]
    fn classifies_outdated_removed_and_available() {
        with_sandbox("classify", |project, source| {
            write_skill(source, "alpha", "one");
            write_skill(source, "gone", "was here");
            install_skill_on_disk(project, "alpha");
            install_skill_on_disk(project, "gone");
            let mut lock = LockFile::default();
            lock.add(locked(source, ItemKind::Skill, "alpha"));
            lock.add(locked(source, ItemKind::Skill, "gone"));

            // Now drift the source: alpha edited, gone deleted, beta added,
            // plus a hook and an agent the scope never installed.
            write_skill(source, "alpha", "two");
            std::fs::remove_dir_all(source.join("skills").join("gone")).unwrap();
            write_skill(source, "beta", "new");
            write_hook(source, "guard");
            write_agent(source, "helper");

            let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
            assert!(report.has_drift());
            assert_eq!(names(&report.outdated), vec!["alpha"]);
            assert_eq!(names(&report.removed), vec!["gone"]);
            // Only kinds the scope already installs are offered: skills yes,
            // hooks and agents no.
            let offered: Vec<(&str, ItemKind)> = report
                .available
                .iter()
                .map(|a| (a.name.as_str(), a.kind))
                .collect();
            assert_eq!(offered, vec![("beta", ItemKind::Skill)]);
            assert_eq!(report.available[0].source, source.to_string_lossy());

            // Control: --no-available must drop the suggestion and nothing else.
            let muted = check_scope(
                false,
                &lock,
                CheckOptions {
                    no_available: true,
                    ..CheckOptions::default()
                },
            )
            .unwrap();
            assert!(muted.available.is_empty());
            assert_eq!(names(&muted.outdated), vec!["alpha"]);
            assert_eq!(names(&muted.removed), vec!["gone"]);
        });
    }

    #[test]
    fn a_kind_that_discovers_to_nothing_is_not_reported_removed() {
        with_sandbox("no-condemn", |project, source| {
            write_skill(source, "alpha", "one");
            install_skill_on_disk(project, "alpha");
            let mut lock = LockFile::default();
            lock.add(locked(source, ItemKind::Skill, "alpha"));

            // The whole skills root vanishes: that is a layout problem, not
            // proof alpha was removed upstream.
            std::fs::remove_dir_all(source.join("skills")).unwrap();

            let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
            assert!(report.removed.is_empty(), "{report:?}");
            assert_eq!(names(&report.outdated), vec!["alpha"]);
        });
    }

    #[test]
    fn quiet_render_is_empty_for_a_clean_scope_and_names_the_scope_on_drift() {
        let clean = ScopeReport {
            scope: "project",
            installed: 1,
            current: vec![Item {
                name: "alpha".into(),
                kind: ItemKind::Skill,
            }],
            ..ScopeReport::default()
        };
        let mut out = String::new();
        render_scope(&mut out, &clean, true);
        assert!(
            out.is_empty(),
            "quiet clean scope must print nothing: {out:?}"
        );
        // Control: the verbose render of the same scope is not empty.
        render_scope(&mut out, &clean, false);
        assert!(out.contains("✓ alpha (skill)"));

        let drifted = ScopeReport {
            scope: "global",
            installed: 2,
            outdated: vec![Item {
                name: "alpha".into(),
                kind: ItemKind::Skill,
            }],
            removed: vec![Item {
                name: "old".into(),
                kind: ItemKind::Hook,
            }],
            available: vec![AvailableItem {
                name: "beta".into(),
                kind: ItemKind::Skill,
                source: "owner/repo".into(),
            }],
            ..ScopeReport::default()
        };
        let mut out = String::new();
        render_scope(&mut out, &drifted, true);
        assert!(out.starts_with("vstack drift — global scope:"), "{out}");
        assert!(out.contains("`vstack refresh`"), "{out}");
        assert!(out.contains("`vstack remove <name>`"), "{out}");
        assert!(
            out.contains("skills (`vstack add --skill <name>`): beta"),
            "{out}"
        );
        assert!(
            !out.contains("✓"),
            "quiet render must not list current items"
        );
    }

    #[test]
    fn json_shape_carries_every_case_and_drift_flag() {
        let report = CheckReport {
            version: 1,
            cli_version: "0.0.0",
            cli_hash: "abc",
            drift: true,
            scopes: vec![ScopeReport {
                scope: "project",
                installed: 1,
                missing_skill_refs: vec![MissingSkillRef {
                    agent: "rust".into(),
                    skill: "dev".into(),
                }],
                ..ScopeReport::default()
            }],
        };
        let json: serde_json::Value =
            serde_json::from_str(&config::to_json_pretty(&report).unwrap()).unwrap();
        assert_eq!(json["drift"], true);
        let scope = &json["scopes"][0];
        for key in [
            "outdated",
            "removed",
            "orphaned",
            "phantom",
            "missing_skill_refs",
            "available",
        ] {
            assert!(scope[key].is_array(), "missing {key}: {scope}");
        }
        assert_eq!(scope["missing_skill_refs"][0]["agent"], "rust");
        assert!(scope.get("current").is_none(), "current is human-only");
        assert_eq!(report.outcome(), CheckOutcome::Drift);
    }
}
