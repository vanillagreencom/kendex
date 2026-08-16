use crate::config::{self, ItemKind, LockEntry, LockFile};
use crate::frontmatter::split_yaml_frontmatter;
use crate::harness::Harness;
use crate::scope::ScopeFilter;
use anyhow::{Context, Result};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

mod render;

pub(crate) use render::{command_arg, display_text};
use render::{humanize_age, render_report, scrub_source_credentials};

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
    /// What exactly is wrong with this one, when the section header cannot
    /// say it — a phantom missing in only some harnesses, for instance,
    /// where "run `vstack add`" is the remedy for those harnesses alone.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl Item {
    pub fn new(name: impl Into<String>, kind: ItemKind) -> Self {
        Self {
            name: name.into(),
            kind,
            detail: None,
        }
    }
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

/// Why a source this scope depends on could not be fully read. Serialized
/// with a `problem` tag carrying only that variant's fields, so a new class
/// of problem cannot fall through a string match into the wrong report.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(tag = "problem", rename_all = "lowercase")]
pub enum SourceProblem {
    /// The source path does not resolve at all — the cache was never cloned
    /// or the directory is gone. Its `entries` cannot be verified.
    Unresolvable { entries: Vec<String> },
    /// The source resolves but cannot be inventoried: its catalog
    /// configuration is unusable, or a whole kind root is missing. `refresh`
    /// fixes neither, so `entries` are reported here instead of as outdated.
    Unreadable {
        entries: Vec<String>,
        reasons: Vec<String>,
    },
    /// Discovery ran, but individual assets failed to parse.
    Discovery { failures: Vec<String> },
    /// A cache for this source exists but cannot be proven to belong to it,
    /// so nothing may be installed or verified from it. Distinct from
    /// `unresolvable`: the remedy is to remove that directory, not to add the
    /// source again.
    Unverifiable {
        entries: Vec<String>,
        reason: String,
    },
}

/// One source's problem, tagged with the lock `source` string it came from.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct SourceIssue {
    pub source: String,
    #[serde(flatten)]
    pub problem: SourceProblem,
}

/// A remote source cache that is not up to date; the report was computed
/// against whatever the cache already held.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct CacheRefreshFailure {
    pub source: String,
    /// Seconds since the FIRST failure of the current run of failures — not
    /// since the last attempt, which every TTL retry would reset. 0 for a
    /// cache that cannot be written at all.
    pub age_secs: u64,
    /// What went wrong, for the human line.
    pub reason: String,
    /// The failure has outlived two TTL windows of retries, or cannot resolve
    /// itself at all. Counts as drift: a permanently broken remote must not
    /// read as clean at every session start.
    pub persistent: bool,
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
    /// Skills present on disk but absent from the lock — `vstack add`
    /// recovers. Skills only: they are the one kind with a canonical on-disk
    /// root to scan.
    pub orphaned: Vec<Item>,
    /// Lock entries whose installed files are gone, for every kind that
    /// records an install path (extras do not).
    pub phantom: Vec<Item>,
    /// Installed agents referencing skills that are not installed.
    pub missing_skill_refs: Vec<MissingSkillRef>,
    /// Sources that could not be resolved or fully discovered.
    pub source_issues: Vec<SourceIssue>,
    /// Lock entries whose names fail [`is_safe_item_name`]; they are excluded
    /// from every other list and rendered as `<invalid name>`.
    pub invalid_names: Vec<Item>,
    /// Items a declared source ships that this scope never installed —
    /// `vstack add --<kind> <name>`, pending user approval. A suggestion, not
    /// drift: it never affects [`has_drift`](Self::has_drift).
    pub available: Vec<AvailableItem>,
    /// Entries neither outdated nor removed, in lock order (human listing only).
    #[serde(skip)]
    pub current: Vec<Item>,
}

impl ScopeReport {
    /// True when something in this scope needs attention. `available` is
    /// deliberately excluded: a scope that installs a deliberate subset of a
    /// source is not drifting.
    pub fn has_drift(&self) -> bool {
        !(self.outdated.is_empty()
            && self.removed.is_empty()
            && self.orphaned.is_empty()
            && self.phantom.is_empty()
            && self.missing_skill_refs.is_empty()
            && self.source_issues.is_empty()
            && self.invalid_names.is_empty())
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct CheckReport {
    /// JSON shape version; bump on any incompatible field change.
    pub version: u32,
    pub cli_version: &'static str,
    pub cli_hash: &'static str,
    /// Any scope has drift, or a cache failure has become persistent.
    /// Independent of `available`.
    pub drift: bool,
    /// Remote caches that are not up to date.
    pub cache_refresh_failures: Vec<CacheRefreshFailure>,
    /// Why the background cache refresh could not even be started, if it
    /// could not. A refresh that never runs would otherwise be invisible:
    /// nothing writes a stamp, so nothing else on the read path notices.
    /// Reported, never drift — an environment where spawning cannot succeed
    /// must not exit 1 at every session start forever.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub background_refresh_error: Option<String>,
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

// A name reaches two places that make a hostile one dangerous: the drift
// report a session-start hook injects into an agent's context, and the paths
// this command joins to find installed files. Both `check` and `verify` use
// the ONE predicate defined beside the install-time validators it has to
// agree with, so a name that installs can never be reported as unsafe.
use crate::path_safety::is_safe_item_name;

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

    let out = render_report(&report, opts.quiet);
    if !out.is_empty() {
        eprint!("{out}");
    }
    Ok(report.outcome())
}

/// Compute the report without printing.
///
/// Everything the verdict is built from is local — the lock, the source
/// trees, the cache stamps — so this is instant and works offline. Nothing
/// here touches the network: a cache that is due for a refresh is handed to a
/// detached background process nobody waits on, and its outcome is read from
/// the stamp by the NEXT check. That is the whole reason a session start can
/// afford to run this. (The one write it may make is converting a stamp left
/// behind by a killed fetch; see [`config::remote_cache_problem`].)
pub fn gather(scope: ScopeFilter, opts: CheckOptions) -> Result<CheckReport> {
    let mut scopes = Vec::new();
    let mut cache_refresh_failures = Vec::new();
    let mut seen_sources: HashSet<String> = HashSet::new();
    let mut refresh_due = false;
    for &global in scope.globals() {
        let lock_path = config::lock_file_path(global);
        let lock = LockFile::load(&lock_path)
            .with_context(|| format!("loading lock file {}", lock_path.display()))?;
        // Recorded failures are read in every mode, `--offline` included:
        // they are pure disk reads, and offline is exactly the mode a user
        // reaches for when the network is misbehaving.
        for problem in config::recorded_remote_cache_problems(&lock) {
            if !seen_sources.insert(problem.source.clone()) {
                continue;
            }
            cache_refresh_failures.push(cache_failure(problem, opts.offline));
        }
        refresh_due |= config::any_remote_cache_due(&lock, Some(config::REMOTE_CACHE_TTL));
        if let Some(scope_report) = check_scope(global, &lock, opts) {
            scopes.push(scope_report);
        }
    }
    let mut background_refresh_error = None;
    if refresh_due && !opts.offline {
        // The check itself has already read everything it needs, so this
        // never fails the run — but a refresh that cannot start will never
        // start, and silence would leave the caches stale forever.
        if let Err(err) = config::spawn_detached_cache_refresh(scope.label()) {
            background_refresh_error = Some(display_text(&err.to_string()));
        }
    }
    cache_refresh_failures.sort_by(|a, b| a.source.cmp(&b.source));
    let drift = computed_drift(&scopes, &cache_refresh_failures);
    Ok(CheckReport {
        version: 1,
        cli_version: env!("CARGO_PKG_VERSION"),
        cli_hash: env!("VSTACK_GIT_HASH"),
        drift,
        cache_refresh_failures,
        background_refresh_error,
        scopes,
    })
}

/// The exit-code verdict. The background-refresh spawn error is deliberately
/// not even a parameter: it is reported, but an environment where spawning
/// can never succeed (a sandbox denying fork) must not be a permanent exit 1
/// at every session start that no vstack command can fix.
fn computed_drift(scopes: &[ScopeReport], cache_refresh_failures: &[CacheRefreshFailure]) -> bool {
    scopes.iter().any(ScopeReport::has_drift) || cache_refresh_failures.iter().any(|f| f.persistent)
}

fn cache_failure(problem: config::RemoteCacheProblem, offline: bool) -> CacheRefreshFailure {
    let persistent = problem.kind.is_persistent();
    let (age_secs, reason) = match problem.kind {
        config::RemoteCacheProblemKind::Failing {
            failing_for,
            last_attempt,
            cause,
        } => (
            failing_for.as_secs(),
            format!(
                "{} — failing for {} (last attempt {} ago{})",
                cause.map_or("the refresh did not complete", |cause| cause.describe()),
                humanize_age(failing_for.as_secs()),
                humanize_age(last_attempt.as_secs()),
                if offline { ", not re-checked" } else { "" }
            ),
        ),
        config::RemoteCacheProblemKind::Unwritable { reason } => (
            0,
            format!("cache cannot be written: {}", display_text(&reason)),
        ),
    };
    CacheRefreshFailure {
        // Scrubbed at construction so `--json` never carries a token either.
        source: scrub_source_credentials(&problem.source),
        age_secs,
        reason,
        persistent,
    }
}

/// What one resolved source ships, per kind, keyed by the lock `source`
/// string. Pi extensions also register their legacy names so a lock entry
/// recorded under an old name is neither "removed" nor re-offered.
#[derive(Default)]
struct SourceCatalog {
    kinds: HashMap<ItemKind, crate::catalog::KindInventory>,
    /// Names known under each kind, including Pi legacy aliases.
    names: HashMap<ItemKind, HashSet<String>>,
    /// `path: reason` for every asset discovery could not parse.
    failures: Vec<String>,
    /// Set when the source's own catalog configuration could not be read, so
    /// nothing about it can be inventoried.
    config_error: Option<String>,
}

impl SourceCatalog {
    /// Why an entry of `kind` cannot be verified against this source, if it
    /// cannot. Every case here is a layout or configuration problem `refresh`
    /// cannot repair, so the entry must never be reported outdated or removed.
    fn unverifiable(&self, kind: ItemKind) -> Option<String> {
        if let Some(error) = &self.config_error {
            return Some(error.clone());
        }
        match self.kinds.get(&kind) {
            Some(inventory) => inventory.unverifiable(kind),
            // A kind that was never inventoried cannot answer for its entries.
            None => Some(format!("{}: not inventoried", kind.label_plural())),
        }
    }

    fn readable(&self, kind: ItemKind) -> Option<&crate::catalog::Inventory> {
        self.kinds.get(&kind).and_then(|kind| kind.readable())
    }
}

const CATALOG_KINDS: [ItemKind; 5] = [
    ItemKind::Agent,
    ItemKind::Skill,
    ItemKind::Hook,
    ItemKind::PiExtension,
    ItemKind::Extra,
];

fn load_source_catalog(source_root: &Path) -> SourceCatalog {
    let mut catalog = SourceCatalog::default();
    // `[catalog]` decides where every kind lives. Falling back to the default
    // roots when it cannot be read would inventory a layout the source does
    // not use and call the difference drift, so the whole source is
    // unverifiable until the configuration is fixed. Loaded ONCE per source
    // and threaded into every kind.
    let config = match crate::mapping::MappingConfig::load_strict(source_root) {
        Ok(config) => config,
        Err(err) => {
            catalog.config_error = Some(format!("catalog configuration unreadable: {err:#}"));
            return catalog;
        }
    };
    for kind in CATALOG_KINDS {
        let inventory = crate::catalog::inventory(source_root, kind, &config.catalog);
        if let Some(readable) = inventory.readable() {
            let mut names: HashSet<String> = readable.names.iter().cloned().collect();
            if kind == ItemKind::PiExtension {
                for name in &readable.names {
                    for legacy in crate::pi_extension::legacy_names_for(name) {
                        names.insert((*legacy).to_string());
                    }
                }
            }
            catalog.failures.extend(readable.failures.iter().cloned());
            catalog.names.insert(kind, names);
        }
        catalog.kinds.insert(kind, inventory);
    }
    catalog.failures.sort();
    catalog
}

fn item(entry: &LockEntry) -> Item {
    Item::new(entry.name.clone(), entry.kind)
}

/// Resolve each distinct lock source once. `None` = unresolvable (cache never
/// cloned, path gone): reported as a source issue with its entries, which are
/// then neither hashed nor offered against.
fn load_catalogs<'a>(entries: &[&'a LockEntry]) -> HashMap<&'a str, Option<SourceCatalog>> {
    let mut catalogs: HashMap<&str, Option<SourceCatalog>> = HashMap::new();
    for entry in entries {
        catalogs.entry(entry.source.as_str()).or_insert_with(|| {
            config::resolve_source_path(&entry.source)
                .as_deref()
                .map(load_source_catalog)
        });
    }
    catalogs
}

/// Every source-level problem in this scope, sorted by source. Pure over its
/// inputs.
fn source_issues_for(
    catalogs: &HashMap<&str, Option<SourceCatalog>>,
    entries: &[&LockEntry],
) -> Vec<SourceIssue> {
    let mut issues = Vec::new();
    let mut sources: Vec<&str> = catalogs.keys().copied().collect();
    sources.sort();
    for source in sources {
        let named = |selected: &dyn Fn(&LockEntry) -> bool| {
            let mut names: Vec<String> = entries
                .iter()
                .filter(|e| e.source == source && selected(e))
                .map(|e| e.name.clone())
                .collect();
            names.sort();
            names
        };
        let Some(catalog) = &catalogs[source] else {
            // A source can fail to resolve for two very different reasons,
            // and telling a user to re-add a source whose cache holds another
            // repository sends them in a circle.
            let problem = match config::remote_cache_lookup(source) {
                config::RemoteCacheLookup::Unverifiable { reason, .. } => {
                    SourceProblem::Unverifiable {
                        entries: named(&|_| true),
                        // The reason quotes the cache's recorded origin URL,
                        // which can carry a cloned-with token.
                        reason: scrub_source_credentials(&reason),
                    }
                }
                _ => SourceProblem::Unresolvable {
                    entries: named(&|_| true),
                },
            };
            issues.push(SourceIssue {
                source: scrub_source_credentials(source),
                problem,
            });
            continue;
        };
        let unreadable = named(&|e| catalog.unverifiable(e.kind).is_some());
        if !unreadable.is_empty() {
            let mut reasons: Vec<String> = entries
                .iter()
                .filter(|e| e.source == source)
                .filter_map(|e| catalog.unverifiable(e.kind))
                .collect();
            reasons.sort();
            reasons.dedup();
            issues.push(SourceIssue {
                source: scrub_source_credentials(source),
                problem: SourceProblem::Unreadable {
                    entries: unreadable,
                    reasons,
                },
            });
        }
        if !catalog.failures.is_empty() {
            issues.push(SourceIssue {
                source: scrub_source_credentials(source),
                problem: SourceProblem::Discovery {
                    failures: catalog.failures.clone(),
                },
            });
        }
    }
    issues
}

/// Split every verifiable entry into outdated / removed / current.
fn classify(
    catalogs: &HashMap<&str, Option<SourceCatalog>>,
    entries: &[&LockEntry],
) -> (Vec<Item>, Vec<Item>, Vec<Item>) {
    let (mut outdated, mut removed, mut current) = (Vec::new(), Vec::new(), Vec::new());
    for entry in entries {
        // Reported under source_issues; the source cannot answer for it.
        let Some(catalog) = &catalogs[entry.source.as_str()] else {
            continue;
        };
        if catalog.unverifiable(entry.kind).is_some() {
            continue;
        }
        // "Removed" needs positive evidence: every configured root for the
        // kind was READ (an empty readable root proves the source ships
        // nothing of this kind) and every candidate in them parsed, so the
        // discovered names are the whole truth. An item whose files exist but
        // no longer parse falls through to the hash check instead of being
        // condemned.
        let known = catalog
            .names
            .get(&entry.kind)
            .is_some_and(|names| names.contains(&entry.name));
        let discovery_complete = catalog
            .readable(entry.kind)
            .is_some_and(|inv| inv.names_are_complete());
        if !known && discovery_complete {
            removed.push(item(entry));
        } else if config::is_source_changed(entry) {
            outdated.push(item(entry));
        } else {
            current.push(item(entry));
        }
    }
    (outdated, removed, current)
}

/// vstack#71: for every installed agent, verify each skill its frontmatter
/// references is actually installed. The bug bites when `[role-skills]`
/// declares a skill the user never ran `vstack add --skill <name>` for, and
/// the agent ends up referencing a SKILL.md that does not exist on disk.
///
/// Returns the missing references plus any referenced name too unsafe to
/// resolve — those are never joined into a path and never echoed back as a
/// command for an agent to run.
fn missing_skill_refs_for(
    global: bool,
    entries: &[&LockEntry],
    disk_skill_names: &HashSet<&str>,
) -> (Vec<MissingSkillRef>, Vec<Item>) {
    let installed_skill_names: HashSet<&str> = entries
        .iter()
        .filter(|e| e.kind == ItemKind::Skill)
        .map(|e| e.name.as_str())
        .chain(disk_skill_names.iter().copied())
        .collect();
    let mut missing = Vec::new();
    let mut invalid = Vec::new();
    for agent in entries.iter().filter(|e| e.kind == ItemKind::Agent) {
        let Some(agent_path) = find_installed_agent_file(global, agent) else {
            continue;
        };
        let mut skills = read_agent_skills(&agent_path);
        skills.sort();
        skills.dedup();
        for skill_name in skills {
            if !is_safe_item_name(ItemKind::Skill, &skill_name) {
                invalid.push(Item::new(skill_name, ItemKind::Skill));
                continue;
            }
            if installed_skill_names.contains(skill_name.as_str())
                || skill_disk_path(global, &skill_name)
                    .join("SKILL.md")
                    .exists()
            {
                continue;
            }
            missing.push(MissingSkillRef {
                agent: agent.name.clone(),
                skill: skill_name,
            });
        }
    }
    (missing, invalid)
}

/// Items a declared source ships that this scope never installed — lock keys
/// are bare names, so a name absent from them is absent under every kind. A
/// kind is offered only where the scope already installs that kind: a global
/// scope holding nothing but Pi packages is not asking for agents, and a
/// project without Pi packages is not asking for them.
fn available_for(
    catalogs: &HashMap<&str, Option<SourceCatalog>>,
    entries: &[&LockEntry],
    lock_names: &HashSet<&str>,
) -> Vec<AvailableItem> {
    let mut available = Vec::new();
    let installed_kinds: HashSet<ItemKind> = entries.iter().map(|e| e.kind).collect();
    let mut sources: Vec<&str> = catalogs.keys().copied().collect();
    sources.sort();
    // Dedupe on the OFFER, not the name: two sources shipping a skill of the
    // same name are two different implementations, and the add command is
    // source-qualified precisely so the user picks which one.
    let mut seen: HashSet<(&str, ItemKind, &str)> = HashSet::new();
    for source in sources {
        let Some(catalog) = &catalogs[source] else {
            continue;
        };
        for kind in CATALOG_KINDS {
            if kind.add_filter_flag().is_none() || !installed_kinds.contains(&kind) {
                continue;
            }
            let Some(inventory) = catalog.readable(kind) else {
                continue;
            };
            for name in &inventory.names {
                let installed = lock_names.contains(name.as_str())
                    || crate::pi_extension::legacy_names_for(name)
                        .iter()
                        .any(|legacy| lock_names.contains(legacy));
                if installed
                    || !is_safe_item_name(kind, name)
                    || !seen.insert((source, kind, name.as_str()))
                {
                    continue;
                }
                available.push(AvailableItem {
                    name: name.clone(),
                    kind,
                    source: scrub_source_credentials(source),
                });
            }
        }
    }
    available.sort_by(|a, b| {
        a.name
            .cmp(&b.name)
            .then_with(|| a.kind.label_short().cmp(b.kind.label_short()))
            .then_with(|| a.source.cmp(&b.source))
    });
    available
}

fn check_scope(global: bool, lock: &LockFile, opts: CheckOptions) -> Option<ScopeReport> {
    // Skills on disk that should be in the lock but aren't.
    let disk_skills = config::scan_installed_skills_on_disk(global);
    let lock_names: HashSet<&str> = lock.entries.keys().map(|s| s.as_str()).collect();
    let mut orphaned: Vec<Item> = disk_skills
        .iter()
        .filter(|d| {
            !lock_names.contains(d.name.as_str()) && is_safe_item_name(ItemKind::Skill, &d.name)
        })
        .map(|d| Item::new(d.name.clone(), ItemKind::Skill))
        .collect();
    orphaned.sort_by(|a, b| a.name.cmp(&b.name));

    if lock.entries.is_empty() && orphaned.is_empty() {
        return None;
    }

    // Names that cannot be rendered or joined safely leave the pipeline here.
    let (unsafe_entries, entries): (Vec<&LockEntry>, Vec<&LockEntry>) = lock
        .entries
        .values()
        .partition(|e| !is_safe_item_name(e.kind, &e.name));
    let mut invalid_names: Vec<Item> = unsafe_entries.iter().map(|e| item(e)).collect();

    // Lock entries whose installed artifacts are gone, for every kind except
    // extras (which record no single install path) — the same presence check
    // `vstack verify` runs, over the same disk evidence, so the two commands
    // cannot disagree about what is installed.
    let disk_skill_set: HashSet<String> = disk_skills.iter().map(|d| d.name.clone()).collect();
    let phantom: Vec<Item> = entries
        .iter()
        .filter_map(|e| {
            crate::commands::verify::missing_install(e, global, &disk_skill_set).map(|note| Item {
                detail: Some(note),
                ..item(e)
            })
        })
        .collect();

    let catalogs = load_catalogs(&entries);
    let source_issues = source_issues_for(&catalogs, &entries);
    let (outdated, removed, mut current) = classify(&catalogs, &entries);
    // An entry whose install is missing is not "current", whatever its hash
    // says: listing it with a ✓ beside its own phantom line reads as a
    // contradiction.
    let phantom_names: HashSet<&str> = phantom.iter().map(|i| i.name.as_str()).collect();
    current.retain(|i| !phantom_names.contains(i.name.as_str()));

    let disk_skill_names: HashSet<&str> = disk_skills.iter().map(|d| d.name.as_str()).collect();
    let (missing_skill_refs, invalid_refs) =
        missing_skill_refs_for(global, &entries, &disk_skill_names);
    invalid_names.extend(invalid_refs);
    // Two agents can reference the same bad skill name, and a name can be
    // both a bad lock entry and a bad reference: report each once.
    invalid_names
        .sort_by(|a, b| (&a.name, a.kind.label_short()).cmp(&(&b.name, b.kind.label_short())));
    invalid_names.dedup_by(|a, b| a.name == b.name && a.kind == b.kind);

    let available = if opts.no_available {
        Vec::new()
    } else {
        available_for(&catalogs, &entries, &lock_names)
    };

    Some(ScopeReport {
        scope: if global { "global" } else { "project" },
        installed: lock.entries.len(),
        outdated,
        removed,
        orphaned,
        phantom,
        missing_skill_refs,
        source_issues,
        invalid_names,
        available,
        current,
    })
}

#[cfg(test)]
mod test_support;
#[cfg(test)]
mod tests;
