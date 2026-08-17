//! The source records a lock resolves to: which directories this scope's
//! installed items came from, the lease each cached one is read under, and
//! what resolution refused on the way.
//!
//! Resolving ONE source string — the local-path, relative and remote-cache
//! branches, and the fetch a recorded remote takes — stays in the parent
//! module. This is what a lock's worth of them adds up to, and what every
//! consumer (`refresh`, the TUI's installer, hook attribution) reads from.

use super::*;
use crate::agent::Agent;
use crate::config::{self, CacheLease, ItemKind};
use crate::hook::Hook;
use crate::mapping::MappingConfig;
use crate::pi_extension::PiExtension;
use crate::skill::Skill;
use std::path::{Path, PathBuf};

/// A source directory a caller is about to read, and the lease that keeps it
/// from being rewritten while it does.
///
/// The two live in one value because they must travel together: everything
/// downstream — discovery, hashing, copying — reads `root`, and the lease is
/// the only thing standing between that read and another process's
/// `reset --hard`. It is [`CacheLease::none`] for a local directory, which no
/// vstack process rewrites.
#[derive(Clone, Debug)]
pub(crate) struct ResolvedSource {
    pub root: PathBuf,
    pub aliases: Vec<String>,
    pub source_repo: Option<String>,
    pub lease: CacheLease,
}

#[cfg(test)]
impl ResolvedSource {
    /// A record for a test that cares only which directory an alias resolved
    /// to. Nothing is leased: the root is a fixture directory on disk.
    pub(crate) fn for_test(root: PathBuf, alias: &str, source_repo: Option<&str>) -> Self {
        Self {
            root,
            aliases: vec![alias.to_string()],
            source_repo: source_repo.map(str::to_string),
            lease: CacheLease::none(),
        }
    }
}

#[derive(Clone)]
pub struct RefreshSource {
    pub root: PathBuf,
    pub aliases: Vec<String>,
    pub source_repo: Option<String>,
    pub mapping: MappingConfig,
    pub agents: Vec<Agent>,
    pub skills: Vec<Skill>,
    pub hooks: Vec<Hook>,
    pub pi_extensions: Vec<PiExtension>,
    /// Carried from the [`ResolvedSource`] this was loaded from: a refresh
    /// reads this tree for as long as it holds these, so the lease outlives
    /// resolution by exactly that much.
    #[allow(dead_code)]
    lease: CacheLease,
}

impl RefreshSource {
    pub(crate) fn load(record: &ResolvedSource) -> Self {
        Self {
            root: record.root.clone(),
            aliases: record.aliases.clone(),
            source_repo: record.source_repo.clone(),
            mapping: MappingConfig::load(&record.root),
            agents: crate::catalog::discover_agents(&record.root).unwrap_or_default(),
            skills: crate::catalog::discover_skills(&record.root).unwrap_or_default(),
            hooks: crate::catalog::discover_hooks(&record.root).unwrap_or_default(),
            pi_extensions: crate::catalog::discover_pi_extensions(&record.root).unwrap_or_default(),
            lease: record.lease.clone(),
        }
    }

    #[cfg(test)]
    pub(crate) fn from_root(root: &Path) -> Self {
        Self::load(&ResolvedSource {
            root: root.to_path_buf(),
            aliases: vec![root.to_string_lossy().into_owned()],
            source_repo: config::source_repo_for_source(Some(root), &root.to_string_lossy()),
            lease: CacheLease::none(),
        })
    }
}

/// What resolving one recorded source string produced.
///
/// `Refused` is a source that exists and must not be substituted; `Absent` is
/// one that names nothing. Collapsing the two into `None` is what forced the
/// distinction to be rebuilt out of band.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum SourceResolution {
    Resolved(PathBuf),
    Absent,
    Refused(String),
}

/// A resolution and the lease its update took.
///
/// The pair is what a resolver hands back, because a resolved cache directory
/// with no lease behind it is a path another process may `reset --hard` at any
/// moment. Resolvers that never fetch convert in with [`From`]: they hold
/// nothing, and say so.
pub(crate) struct LeasedResolution {
    pub resolution: SourceResolution,
    pub lease: CacheLease,
}

impl From<SourceResolution> for LeasedResolution {
    fn from(resolution: SourceResolution) -> Self {
        Self {
            resolution,
            lease: CacheLease::none(),
        }
    }
}

impl SourceResolution {
    pub(super) fn refused(err: &anyhow::Error) -> Self {
        Self::Refused(format!("{err:#}"))
    }

    /// What to report when this produced no root — the refusal, or why the
    /// source is absent. `None` when it resolved.
    ///
    /// One place decides it, so `refresh`, `check` and `verify` name the same
    /// cause for the same state. Telling a refused source to `vstack add`
    /// itself sends the user back to the refusal.
    pub(crate) fn unresolved_note(&self, source: &str) -> Option<String> {
        match self {
            Self::Resolved(_) => None,
            Self::Refused(reason) => Some(reason.clone()),
            Self::Absent => Some(absent_source_reason(source)),
        }
    }

    /// The resolved directory for the callers that only ever had an `Option`
    /// to act on, reporting a refusal to the user on the way past.
    pub(super) fn or_warn(self, key: &str) -> Option<PathBuf> {
        match self {
            Self::Resolved(dir) => Some(dir),
            Self::Absent => None,
            Self::Refused(reason) => {
                warn_once(key, &reason);
                None
            }
        }
    }
}

/// The sources a lock resolved to, and what resolution refused on the way.
pub(crate) struct SourceRecords {
    pub sources: Vec<ResolvedSource>,
    pub refused: SourceRefusals,
}

/// The recorded sources resolution refused, keyed by the recorded string so a
/// caller holding a lock entry can look its own reason up — and whether source
/// resolution ran at all. Every refresh path now resolves each entry's own
/// source from its lock, so a refusal is always available to the report.
#[derive(Clone, Debug, Default)]
pub struct SourceRefusals {
    reasons: std::collections::BTreeMap<String, String>,
    attempted: bool,
}

impl SourceRefusals {
    fn attempted(reasons: std::collections::BTreeMap<String, String>) -> Self {
        Self {
            reasons,
            attempted: true,
        }
    }

    pub(crate) fn reason(&self, source: &str) -> Option<&str> {
        self.reasons.get(source).map(String::as_str)
    }

    /// Whether these refusals came from a pass that actually resolved sources.
    pub(crate) fn attempted_resolution(&self) -> bool {
        self.attempted
    }
}

/// Resolve source directories from lock file entries.
/// Handles absolute local paths, "." (walks up from CWD), and remote shorthand (cached clones).
pub(crate) fn resolve_source_records(lock: &config::LockFile) -> SourceRecords {
    resolve_source_records_with(lock, resolve_recorded_source_resolution)
}

/// [`resolve_source_records`] reading each cache entry as it stands, with no
/// fetch.
///
/// For a caller that is reconciling rather than updating: it needs to know
/// which assets every recorded source carries, and updating a source it was
/// not asked to install from would be a side effect of asking.
pub(crate) fn resolve_source_records_without_update(lock: &config::LockFile) -> SourceRecords {
    resolve_source_records_with(lock, |source| source_path_resolution(source).into())
}

fn resolve_source_records_with(
    lock: &config::LockFile,
    mut resolver: impl FnMut(&str) -> LeasedResolution,
) -> SourceRecords {
    let mut sources: Vec<ResolvedSource> = Vec::new();
    let mut refused = std::collections::BTreeMap::new();
    let mut seen = std::collections::HashSet::new();

    for entry in lock.entries.values() {
        if !seen.insert(entry.source.clone()) {
            continue;
        }
        let LeasedResolution { resolution, lease } = resolver(&entry.source);
        match resolution {
            SourceResolution::Resolved(dir) => {
                push_resolved_source(&mut sources, dir, entry.source.clone(), lease);
            }
            SourceResolution::Absent => {}
            SourceResolution::Refused(reason) => {
                warn_once(&entry.source, &reason);
                refused.insert(entry.source.clone(), reason);
            }
        }
    }

    // A refused remote cache is a source that exists and must not be
    // substituted: no fallback stands in for it.
    if !sources.is_empty() || !refused.is_empty() {
        return SourceRecords {
            sources,
            refused: SourceRefusals::attempted(refused),
        };
    }

    // Fallback: walk up from CWD to find a vstack source repo. A local
    // checkout, so there is no cache for anyone to rewrite under it.
    if let Ok(mut dir) = std::env::current_dir() {
        loop {
            if crate::resolve::is_vstack_source(&dir) {
                let alias = dir.to_string_lossy().into_owned();
                push_resolved_source(&mut sources, dir, alias, CacheLease::none());
                break;
            }
            if !dir.pop() {
                break;
            }
        }
    }

    // Fallback: try the source registry (cached remote repos).
    if sources.is_empty() {
        let reg_path = config::source_registry_path();
        if let Ok(registry) = config::SourceRegistry::load(&reg_path) {
            for entry in registry.current.iter().chain(registry.entries.iter()) {
                let LeasedResolution { resolution, lease } = resolver(entry);
                if let Some(dir) = resolution.or_warn(entry) {
                    push_resolved_source(&mut sources, dir, entry.clone(), lease);
                }
            }
        }
    }

    SourceRecords {
        sources,
        refused: SourceRefusals::attempted(refused),
    }
}

fn push_resolved_source(
    sources: &mut Vec<ResolvedSource>,
    root: PathBuf,
    alias: String,
    lease: CacheLease,
) {
    let source_repo = config::source_repo_for_source(Some(&root), &alias);
    if let Some(existing) = sources
        .iter_mut()
        .find(|source| same_path(&source.root, &root))
    {
        if !existing.aliases.iter().any(|known| known == &alias) {
            existing.aliases.push(alias);
        }
        if existing.source_repo.is_none() {
            existing.source_repo = source_repo;
        }
        // Two spellings of one remote share one lease; the record keeps
        // whichever it was handed first, and the second drops here.
        if !existing.lease.is_held() {
            existing.lease = lease;
        }
    } else {
        sources.push(ResolvedSource {
            root,
            aliases: vec![alias],
            source_repo,
            lease,
        });
    }
}

pub(crate) fn load_refresh_sources(records: &[ResolvedSource]) -> Vec<RefreshSource> {
    records.iter().map(RefreshSource::load).collect()
}

pub(crate) fn refresh_source_for_entry<'a>(
    sources: &'a [RefreshSource],
    entry: &config::LockEntry,
) -> Option<&'a RefreshSource> {
    if let Some(source) = sources
        .iter()
        .find(|source| source.aliases.iter().any(|alias| alias == &entry.source))
    {
        return Some(source);
    }

    let entry_path = Path::new(&entry.source);
    if entry_path.is_absolute()
        && let Some(source) = sources
            .iter()
            .find(|source| same_path(&source.root, entry_path))
    {
        return Some(source);
    }

    // Legacy fallback: an entry that recorded no usable source at all may bind
    // to the sole loaded source. A recorded path or remote that merely no
    // longer resolves must not — see `may_rebind_to_fallback_source`.
    if sources.len() == 1 && may_rebind_to_fallback_source(&entry.source) {
        sources.first()
    } else {
        None
    }
}

/// Whether an entry may be bound to a source it did not record.
///
/// Only a legacy placeholder qualifies: an empty source, or a bare token that
/// is neither path-like (`/…`, `~…`, `.`, `./…`, `../…`) nor remote-like
/// (`owner/repo`, a URL) — the shapes pre-1.0 locks and disk recovery wrote
/// when no source was known — and only while that token does not name a live
/// project-relative directory. A recorded path or remote that no longer
/// resolves stays bound to what it recorded and is reported missing:
/// rebinding it would refresh the entry from a source it was never installed
/// from, and a same-named asset there would silently replace the real one.
pub(crate) fn may_rebind_to_fallback_source(source: &str) -> bool {
    is_legacy_placeholder_source(source) && !recorded_source_exists(source)
}

fn is_legacy_placeholder_source(source: &str) -> bool {
    let source = source.trim();
    if source.is_empty() {
        return true;
    }
    let path_like = Path::new(source).is_absolute()
        || source.starts_with('~')
        || is_explicit_relative_local_source(source)
        || source == "..";
    let remote_like = source.contains('/') || source.contains("://") || source.contains('@');
    !path_like && !remote_like
}

pub(crate) fn all_source_hooks(sources: &[RefreshSource]) -> Vec<Hook> {
    sources
        .iter()
        .flat_map(|source| source.hooks.iter().cloned())
        .collect()
}

pub(crate) fn all_source_pi_extensions(sources: &[RefreshSource]) -> Vec<PiExtension> {
    sources
        .iter()
        .flat_map(|source| source.pi_extensions.iter().cloned())
        .collect()
}

pub(crate) fn resolve_skill_pairs_from_sources(
    names: &[String],
    lock: &config::LockFile,
    sources: &[RefreshSource],
) -> Vec<(String, String)> {
    names
        .iter()
        .map(|name| {
            let description = lock
                .entries
                .get(name)
                .filter(|entry| entry.kind == ItemKind::Skill)
                .and_then(|entry| refresh_source_for_entry(sources, entry))
                .and_then(|source| source.skills.iter().find(|skill| &skill.name == name))
                .or_else(|| {
                    sources
                        .iter()
                        .flat_map(|source| source.skills.iter())
                        .find(|skill| &skill.name == name)
                })
                .map(|skill| skill.description.clone())
                .unwrap_or_else(|| name.clone());
            (name.clone(), description)
        })
        .collect()
}

pub(crate) fn source_pi_extension_for_lock_name<'a>(
    pi_extensions: &'a [PiExtension],
    name: &str,
) -> Option<&'a PiExtension> {
    pi_extensions.iter().find(|e| e.name == name).or_else(|| {
        pi_extensions
            .iter()
            .find(|e| crate::pi_extension::legacy_names_for(&e.name).contains(&name))
    })
}

/// Resolve a source string that a lock entry recorded at install time.
///
/// Discovery (`resolve_single_source_with(.., true, true)`) applies the
/// [`crate::resolve::is_vstack_source`] layout heuristic so that walking up
/// from CWD does not mistake an arbitrary directory for a package source. A
/// recorded source needs no such guess: the user named it explicitly on
/// `vstack add`, which accepts any directory holding the asset. Applying the
/// heuristic here silently dropped alternate sources that the heuristic
/// rejects — a dot-named dir, or one carrying only `skills/` — after which the
/// entry fell back to whatever other source was loaded and edits to the real
/// source stopped propagating.
fn resolve_recorded_source_resolution(source: &str) -> LeasedResolution {
    let path = Path::new(source);
    if path.is_absolute() && path.is_dir() {
        return SourceResolution::Resolved(path.to_path_buf()).into();
    }
    if let Some(path) = resolve_recorded_local_source(source) {
        return SourceResolution::Resolved(path).into();
    }
    resolve_single_source_with(source, true, true)
}

/// Why a recorded source produced nothing, for a caller holding no refusal map
/// of its own. One wording, so `refresh`, `check` and `verify` name the same
/// cause and the same command for the same state.
pub(crate) fn absent_source_reason(source: &str) -> String {
    if looks_like_remote_source(source) {
        format!(
            "remote cache not present — run `vstack add {}`",
            remote_source_display(source)
        )
    } else if source.trim().is_empty() {
        "source not found (none recorded)".to_string()
    } else {
        // Named so the user can see WHICH source vanished, through the same
        // redacting display every other source diagnostic uses: a credential
        // URL malformed enough to evade `parse_remote_url` classifies as a
        // local path and reaches here, and a lock file records the string
        // verbatim.
        format!("source not found: {}", remote_source_display(source))
    }
}

#[cfg(test)]
pub(super) mod tests;
