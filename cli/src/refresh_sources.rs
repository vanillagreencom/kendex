use crate::agent::Agent;
use crate::config::{self, ItemKind};
use crate::hook::Hook;
use crate::mapping::MappingConfig;
use crate::pi_extension::PiExtension;
use crate::skill::Skill;
use anyhow::{Context, Result, bail};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub(crate) struct ResolvedSource {
    pub root: PathBuf,
    pub aliases: Vec<String>,
    pub source_repo: Option<String>,
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
        }
    }

    #[cfg(test)]
    pub(crate) fn from_root(root: &Path) -> Self {
        Self::load(&ResolvedSource {
            root: root.to_path_buf(),
            aliases: vec![root.to_string_lossy().into_owned()],
            source_repo: config::source_repo_for_source(Some(root), &root.to_string_lossy()),
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

impl SourceResolution {
    fn refused(err: &anyhow::Error) -> Self {
        Self::Refused(format!("{err:#}"))
    }

    /// The resolved directory for the callers that only ever had an `Option`
    /// to act on, reporting a refusal to the user on the way past.
    fn or_warn(self, key: &str) -> Option<PathBuf> {
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

/// The sources a lock resolved to, and the recorded sources that resolution
/// refused (keyed by the recorded string, so a caller holding a lock entry can
/// look its own reason up).
pub(crate) struct SourceRecords {
    pub sources: Vec<ResolvedSource>,
    pub refused: std::collections::BTreeMap<String, String>,
}

/// Resolve source directories from lock file entries.
/// Handles absolute local paths, "." (walks up from CWD), and remote shorthand (cached clones).
pub(crate) fn resolve_sources(lock: &config::LockFile) -> Vec<PathBuf> {
    resolve_source_records(lock)
        .sources
        .into_iter()
        .map(|source| source.root)
        .collect()
}

pub(crate) fn resolve_source_records(lock: &config::LockFile) -> SourceRecords {
    resolve_source_records_with(lock, resolve_recorded_source_resolution)
}

fn resolve_source_records_with(
    lock: &config::LockFile,
    mut resolver: impl FnMut(&str) -> SourceResolution,
) -> SourceRecords {
    let mut sources: Vec<ResolvedSource> = Vec::new();
    let mut refused = std::collections::BTreeMap::new();
    let mut seen = std::collections::HashSet::new();

    for entry in lock.entries.values() {
        if !seen.insert(entry.source.clone()) {
            continue;
        }
        match resolver(&entry.source) {
            SourceResolution::Resolved(dir) => {
                push_resolved_source(&mut sources, dir, entry.source.clone());
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
        return SourceRecords { sources, refused };
    }

    // Fallback: walk up from CWD to find a vstack source repo.
    if let Ok(mut dir) = std::env::current_dir() {
        loop {
            if crate::resolve::is_vstack_source(&dir) {
                let alias = dir.to_string_lossy().into_owned();
                push_resolved_source(&mut sources, dir, alias);
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
                if let Some(dir) = resolver(entry).or_warn(entry) {
                    push_resolved_source(&mut sources, dir, entry.clone());
                }
            }
        }
    }

    SourceRecords { sources, refused }
}

fn push_resolved_source(sources: &mut Vec<ResolvedSource>, root: PathBuf, alias: String) {
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
    } else {
        sources.push(ResolvedSource {
            root,
            aliases: vec![alias],
            source_repo,
        });
    }
}

pub(crate) fn load_refresh_sources(records: &[ResolvedSource]) -> Vec<RefreshSource> {
    records.iter().map(RefreshSource::load).collect()
}

fn canonicalish(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
}

fn same_path(a: &Path, b: &Path) -> bool {
    canonicalish(a) == canonicalish(b)
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

pub(crate) fn resolve_single_source(source: &str) -> Option<PathBuf> {
    resolve_single_source_with(source, true, true).or_warn(source)
}

/// Resolve a source string that a lock entry recorded at install time.
///
/// Discovery (`resolve_single_source`) applies the [`crate::resolve::is_vstack_source`]
/// layout heuristic so that walking up from CWD does not mistake an arbitrary
/// directory for a package source. A recorded source needs no such guess: the
/// user named it explicitly on `vstack add`, which accepts any directory
/// holding the asset. Applying the heuristic here silently dropped alternate
/// sources that the heuristic rejects — a dot-named dir, or one carrying only
/// `skills/` — after which the entry fell back to whatever other source was
/// loaded and edits to the real source stopped propagating.
pub(crate) fn resolve_recorded_source(source: &str) -> Option<PathBuf> {
    resolve_recorded_source_resolution(source).or_warn(source)
}

fn resolve_recorded_source_resolution(source: &str) -> SourceResolution {
    let path = Path::new(source);
    if path.is_absolute() && path.is_dir() {
        return SourceResolution::Resolved(path.to_path_buf());
    }
    if let Some(path) = resolve_recorded_local_source(source) {
        return SourceResolution::Resolved(path);
    }
    resolve_single_source_with(source, true, true)
}

/// Whether an entry's recorded source still names a source of its own.
///
/// Deliberately side-effect free (no remote fetch): callers use it in per-entry
/// loops to decide whether an entry may fall back to a different source. A
/// remote-shaped source always does — whether its clone is present, and whether
/// vstack will use its URL at all, are questions about that source and never
/// grounds to reinstall the entry from a different one.
pub(crate) fn recorded_source_exists(source: &str) -> bool {
    let path = Path::new(source);
    if path.is_absolute() {
        return path.is_dir();
    }
    resolve_recorded_local_source(source).is_some() || looks_like_remote_source(source)
}

pub(crate) fn resolve_source_path(source: &str) -> Option<PathBuf> {
    resolve_single_source_with(source, false, false).or_warn(source)
}

fn resolve_single_source_with(
    source: &str,
    update_remote: bool,
    require_vstack_source: bool,
) -> SourceResolution {
    // Absolute local path that exists.
    let p = std::path::Path::new(source);
    if p.is_absolute()
        && p.is_dir()
        && (!require_vstack_source || crate::resolve::is_vstack_source(p))
    {
        return SourceResolution::Resolved(p.to_path_buf());
    }

    // Explicit relative local source tokens in locks/registries are
    // project-scoped. Treating them as "walk upward to any vstack source" can
    // rebind a live ./source entry to the checkout running the command from a
    // linked worktree, then repair the lock to the wrong source.
    if is_explicit_relative_local_source(source) {
        return resolve_relative_local_source(source, require_vstack_source)
            .map_or(SourceResolution::Absent, SourceResolution::Resolved);
    }

    // Legacy pure hash/reconcile paths accepted bare placeholders such as
    // "source" by falling back to the nearest vstack checkout from CWD. Keep
    // that compatibility only after trying the project-relative path, and only
    // for non-discovery calls where the historical fallback existed.
    if !require_vstack_source && is_bare_local_source(source) {
        return resolve_relative_local_source(source, false)
            .or_else(find_vstack_source_from_cwd)
            .map_or(SourceResolution::Absent, SourceResolution::Resolved);
    }

    // Remote shorthand or URL: update once during top-level source resolution,
    // then use the cached clone without side effects from pure attribution and
    // hash paths.
    let remote = match RemoteSource::parse(source) {
        Ok(Some(remote)) => remote,
        Ok(None) => return SourceResolution::Absent,
        Err(err) => return SourceResolution::refused(&err),
    };
    if !cache_entry_present(&remote) {
        return SourceResolution::Absent;
    }
    if update_remote {
        eprintln!("Updating cached repo {}...", remote.display);
        // The update path runs the filesystem checks itself, on its way to the
        // git-level ones that guard `reset --hard`.
        if let Err(err) = update_cached_repo(&remote) {
            return SourceResolution::refused(&err);
        }
    } else if let Err(err) = reject_unowned_cache_entry(&remote) {
        // A symlinked entry or a redirected `.git` is some other checkout, and
        // reading it would install that checkout's uncommitted state as the
        // remote source.
        return SourceResolution::refused(&err);
    }
    SourceResolution::Resolved(remote.cache_dir)
}

/// Best-effort update of every remote source's cache entry named by a lock.
/// A refusal is reported and the entry left alone; a failed fetch keeps the
/// stale clone. Cheap enough to run before staleness checks.
pub(crate) fn refresh_remote_caches(lock: &config::LockFile) {
    let mut seen = std::collections::HashSet::new();
    for entry in lock.entries.values() {
        if !seen.insert(entry.source.clone()) {
            continue;
        }
        let remote = match RemoteSource::parse(&entry.source) {
            Ok(Some(remote)) => remote,
            Ok(None) => continue,
            Err(err) => {
                warn_once(&entry.source, &format!("{err:#}"));
                continue;
            }
        };
        if !cache_entry_present(&remote) {
            continue;
        }
        if let Err(err) = update_cached_repo(&remote) {
            warn_once(&entry.source, &format!("{err:#}"));
        }
    }
}

/// Print `message` once per process for `key`. Output dedup only — which
/// sources were refused is carried by [`SourceResolution`], never by this set;
/// two callers resolving the same source must not print the same warning
/// twice.
fn warn_once(key: &str, message: &str) {
    static SEEN: std::sync::OnceLock<std::sync::Mutex<std::collections::HashSet<String>>> =
        std::sync::OnceLock::new();
    let mut seen = SEEN
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if seen.insert(format!("{key}\u{1}{message}")) {
        eprintln!("  Warning: {message}");
    }
}

fn is_explicit_relative_local_source(source: &str) -> bool {
    source == "." || source.starts_with("./") || source.starts_with("../")
}

fn is_bare_local_source(source: &str) -> bool {
    !source.is_empty()
        && !source.starts_with('~')
        && !Path::new(source).is_absolute()
        && !source.contains('/')
        && !source.contains('\\')
        && !looks_like_remote_source(source)
}

fn resolve_recorded_local_source(source: &str) -> Option<PathBuf> {
    if !is_explicit_relative_local_source(source) && !is_bare_local_source(source) {
        return None;
    }
    resolve_relative_local_source(source, false)
}

fn resolve_relative_local_source(source: &str, require_vstack_source: bool) -> Option<PathBuf> {
    if source.starts_with('~') {
        return None;
    }
    let candidate = config::project_root().join(source);
    if !candidate.is_dir() {
        return None;
    }
    if require_vstack_source && !crate::resolve::is_vstack_source(&candidate) {
        return None;
    }
    Some(canonicalish(&candidate))
}

fn find_vstack_source_from_cwd() -> Option<PathBuf> {
    let mut dir = std::env::current_dir().ok()?;
    loop {
        if crate::resolve::is_vstack_source(&dir) {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}

// ---------------------------------------------------------------------------
// Remote sources
// ---------------------------------------------------------------------------

/// What a remote source string names: the one URL git is given and the one
/// cache key its clone lives under. Pure — nothing here consults the
/// environment, so classifying a source is independent of where clones live.
/// This is also where credential-bearing and unsupported inputs are refused,
/// before any git process sees them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RemoteIdentity {
    /// The source as recorded, safe to show: userinfo secrets, query and
    /// fragment replaced.
    pub display: String,
    /// The URL handed to git.
    pub git_url: String,
    /// The single path component under [`remote_cache_root`] the clone lives
    /// in. Derived from the repository identity, so two spellings of one repo
    /// share a clone and two repositories never do.
    pub cache_key: String,
    /// The key a pre-identity vstack derived for this exact source string.
    /// [`cache_entry_present`] adopts such a clone, so the key change does not
    /// orphan one.
    legacy_cache_key: Option<String>,
}

/// A [`RemoteIdentity`] placed in the cache: the same repository, plus where
/// its clone lives on this machine.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RemoteSource {
    pub display: String,
    pub git_url: String,
    pub cache_key: String,
    pub cache_dir: PathBuf,
    legacy_cache_dir: Option<PathBuf>,
}

impl RemoteIdentity {
    /// `Ok(None)` when `source` is not remote-shaped (a local path or bare
    /// name); `Err` when it is remote-shaped but must not be used.
    pub(crate) fn parse(source: &str) -> Result<Option<Self>> {
        let source = source.trim();
        if source.starts_with('~') {
            return Ok(None);
        }
        let url_shaped = is_url_shaped(source);
        let slug = config::parse_github_slug(source);
        if !url_shaped && slug.is_none() {
            return Ok(None);
        }
        let display = remote_source_display(source);
        // From here `source` is remote-shaped: every rejection below is a
        // refusal to use a source, never a verdict that it is a local path.
        if source.starts_with('-') {
            bail!(
                "remote source URLs must not start with `-`, which git reads as an option: {display}"
            );
        }
        if remote_authority(source)
            .chars()
            .any(|ch| ch.is_whitespace() || ch.is_control())
        {
            bail!(
                "remote source URLs must not carry whitespace or control characters in their authority: {display}"
            );
        }
        let git_url = if url_shaped {
            if is_plaintext_http(source) {
                bail!("plaintext HTTP remote sources are not supported: {display}");
            }
            reject_credential_bearing_git_url(source)?;
            source
                .strip_prefix("git+ssh://")
                .map(|rest| format!("ssh://{rest}"))
                .unwrap_or_else(|| source.to_string())
        } else if let Some(slug) = slug {
            // GitHub shorthand: built from the canonical slug, never from the
            // raw spelling — `owner/repo.git` would otherwise clone
            // `repo.git.git`, and `owner/repo/` would clone `repo/.git`.
            format!("https://github.com/{slug}.git")
        } else {
            return Ok(None);
        };
        let identity = remote_identity(&git_url).ok_or_else(|| {
            anyhow::anyhow!("remote source URL has no repository path: {display}")
        })?;
        let cache_key = cache_key_for_identity(&identity);
        let legacy_cache_key = legacy_cache_key(source, &cache_key);
        Ok(Some(Self {
            display,
            git_url,
            cache_key,
            legacy_cache_key,
        }))
    }

    fn located(self) -> RemoteSource {
        let root = remote_cache_root();
        RemoteSource {
            cache_dir: root.join(&self.cache_key),
            legacy_cache_dir: self.legacy_cache_key.map(|key| root.join(key)),
            display: self.display,
            git_url: self.git_url,
            cache_key: self.cache_key,
        }
    }
}

impl RemoteSource {
    /// [`RemoteIdentity::parse`], placed in this machine's cache.
    pub(crate) fn parse(source: &str) -> Result<Option<Self>> {
        Ok(RemoteIdentity::parse(source)?.map(RemoteIdentity::located))
    }
}

pub(crate) fn looks_like_remote_source(source: &str) -> bool {
    matches!(RemoteIdentity::parse(source), Ok(Some(_)) | Err(_))
}

pub(crate) fn remote_cache_root() -> PathBuf {
    config::global_base_dir().join(".vstack").join("cache")
}

/// `scheme://...` (any scheme, any case) or scp-like `user@host:path`.
fn is_url_shaped(source: &str) -> bool {
    if let Some(index) = source.find("://") {
        let scheme = &source[..index];
        return !scheme.is_empty()
            && scheme
                .chars()
                .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '+' | '-' | '.'));
    }
    // scp-like: `git@github.com:owner/repo.git` — an `@` before the first
    // `/`, and a `:` after the host.
    let authority_end = source.find('/').unwrap_or(source.len());
    let authority = &source[..authority_end];
    authority.contains('@') && authority.contains(':')
}

/// The authority of a remote source: `[userinfo@]host[:port]` for a
/// `scheme://` URL, `user@host` for an scp-like spelling, empty for shorthand.
fn remote_authority(source: &str) -> &str {
    if let Some(index) = source.find("://") {
        let rest = &source[index + 3..];
        return &rest[..rest.find('/').unwrap_or(rest.len())];
    }
    match source.split_once(':') {
        Some((authority, _)) if authority.contains('@') => authority,
        _ => "",
    }
}

fn is_plaintext_http(source: &str) -> bool {
    source
        .get(..7)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("http://"))
}

/// The repository a URL names, independent of how it is spelled: a GitHub
/// slug for GitHub remotes in any form, otherwise `host/path` with scheme,
/// userinfo, port-less host case, `.git` and trailing slashes normalized.
fn remote_identity(git_url: &str) -> Option<String> {
    if let Some(slug) = config::parse_github_slug(git_url) {
        return Some(format!("github.com/{slug}"));
    }
    let (host, path) = if let Some(index) = git_url.find("://") {
        let rest = &git_url[index + 3..];
        let (authority, path) = rest.split_once('/')?;
        let host = authority.rsplit('@').next()?;
        (host, path)
    } else {
        // scp-like `user@host:path`
        let (authority, path) = git_url.split_once(':')?;
        let host = authority.rsplit('@').next()?;
        (host, path)
    };
    let path = path.trim_matches('/');
    let path = path
        .strip_suffix(".git")
        .unwrap_or(path)
        .trim_end_matches('/');
    if path.is_empty() {
        return None;
    }
    Some(format!("{}/{}", host.to_ascii_lowercase(), path))
}

/// A cache key is exactly one path component made of `[a-z0-9_-]`, so it can
/// never leave the cache root, and it names exactly one repository. The
/// readable prefix keeps the `owner_repo` shape the cache always used, but it
/// lowercases and collapses — `foo/bar_baz` and `foo_bar/baz` reduce to the
/// same text — so the digest of the full identity is what keeps two
/// repositories from sharing a clone.
fn cache_key_for_identity(identity: &str) -> String {
    let raw = identity.strip_prefix("github.com/").unwrap_or(identity);
    let mut prefix = String::with_capacity(raw.len());
    let mut last_was_sep = false;
    for ch in raw.chars() {
        let next = if ch.is_ascii_alphanumeric() {
            ch.to_ascii_lowercase()
        } else if ch == '-' {
            ch
        } else {
            '_'
        };
        if next == '_' {
            if last_was_sep {
                continue;
            }
            last_was_sep = true;
        } else {
            last_was_sep = false;
        }
        prefix.push(next);
    }
    let digest = format!("{:016x}", config::fnv1a(identity.as_bytes()));
    match prefix.trim_matches('_') {
        "" => digest,
        prefix => format!("{prefix}-{digest}"),
    }
}

/// The cache key a pre-identity vstack derived for this exact source string:
/// the string with `/` replaced by `_`, case and everything else preserved.
/// `None` when it matches the current key or would not be one usable directory
/// name.
fn legacy_cache_key(source: &str, cache_key: &str) -> Option<String> {
    let legacy = source.replace('/', "_");
    let usable = !legacy.is_empty()
        && legacy != "."
        && legacy != ".."
        && legacy != cache_key
        && !legacy.contains(['/', '\\']);
    usable.then_some(legacy)
}

/// Whether `remote`'s clone is present, adopting one an older vstack left
/// under [`legacy_cache_key`]. Without the rename an upgrade orphans every
/// live clone, and each source then reads as absent on the first refresh after
/// it.
pub(crate) fn cache_entry_present(remote: &RemoteSource) -> bool {
    if remote.cache_dir.join(".git").exists() {
        return true;
    }
    let Some(legacy) = remote.legacy_cache_dir.as_ref() else {
        return false;
    };
    // Anything already occupying the canonical entry makes the rename a
    // destructive move; a legacy entry that is not a plain directory owning a
    // real `.git` is not a clone vstack made.
    if std::fs::symlink_metadata(&remote.cache_dir).is_ok() {
        return false;
    }
    let Ok(meta) = std::fs::symlink_metadata(legacy) else {
        return false;
    };
    if !meta.is_dir() || !legacy.join(".git").is_dir() {
        return false;
    }
    match std::fs::rename(legacy, &remote.cache_dir) {
        Ok(()) => {
            eprintln!(
                "  Adopted cached clone of {} as `{}`",
                remote.display, remote.cache_key
            );
            true
        }
        Err(err) => {
            warn_once(
                &remote.cache_key,
                &format!(
                    "could not adopt the existing cache entry for {}: {err}",
                    remote.display
                ),
            );
            false
        }
    }
}

// ---------------------------------------------------------------------------
// Git invocations
//
// Every `git` process vstack runs is built by `hardened_git_command` — the
// cache commands here and the repository-identity reads in `path_safety`
// alike. The update path runs `reset --hard`, and git will happily aim that at
// whatever an inherited `GIT_DIR`/`GIT_WORK_TREE`, a symlinked entry, a
// redirected `.git`, or the clone's own `core.worktree` names; the identity
// reads decide which repository an ownership boundary is judged against, and
// the same inherited variables answer for a different one. Every process here
// runs unattended, where a credential prompt is a hang.
// ---------------------------------------------------------------------------

/// Git's repository- and worktree-locating environment variables. Every one of
/// them overrides the working directory, so an inherited value — vstack invoked
/// from a hook, or from a shell that exported one — would point `reset --hard`
/// at a repository that is not the cache.
const GIT_LOCATION_ENV_VARS: &[&str] = &[
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_NAMESPACE",
    "GIT_CEILING_DIRECTORIES",
    "GIT_DISCOVERY_ACROSS_FILESYSTEM",
];

/// A `git` process pinned to `dir`: the working directory decides the
/// repository, every inherited location override is cleared, and no terminal
/// prompt can be raised. Local reads and the destructive update alike are
/// built here; network commands add ssh batch mode via
/// [`hardened_git_network_command`].
pub(crate) fn hardened_git_command(dir: &Path) -> std::process::Command {
    let mut command = std::process::Command::new("git");
    for key in GIT_LOCATION_ENV_VARS {
        command.env_remove(key);
    }
    command.env("GIT_TERMINAL_PROMPT", "0");
    command.current_dir(dir);
    command
}

/// [`hardened_git_command`] for a command that may open an ssh connection.
/// The ssh command git would choose is kept — `GIT_SSH_COMMAND`, else
/// `core.sshCommand` as configured for `dir` — with that variant's
/// noninteractive flag inserted directly after the program, where it outranks
/// any later option. `GIT_SSH` names a program, not a command line, so it is
/// left alone; `GIT_TERMINAL_PROMPT=0` is what keeps that path unattended.
fn hardened_git_network_command(dir: &Path) -> std::process::Command {
    let mut command = hardened_git_command(dir);
    if let Some(ssh) = batch_mode_ssh_command(
        std::env::var("GIT_SSH_COMMAND").ok().as_deref(),
        configured_ssh_command(dir).as_deref(),
        std::env::var("GIT_SSH").ok().as_deref(),
        configured_git_value(dir, "ssh.variant").as_deref(),
    ) {
        command.env("GIT_SSH_COMMAND", ssh);
    }
    command
}

/// `core.sshCommand` as git resolves it for `dir` (repository, then global
/// and system config).
fn configured_ssh_command(dir: &Path) -> Option<String> {
    configured_git_value(dir, "core.sshCommand")
}

fn configured_git_value(dir: &Path, key: &str) -> Option<String> {
    let output = hardened_git_command(dir)
        .args(["config", "--get", key])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    (!value.is_empty()).then_some(value)
}

/// The ssh implementations git knows how to drive. They take different
/// noninteractive options, and `simple` takes no options at all — passing
/// OpenSSH's to any of the others breaks the connection outright.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SshVariant {
    OpenSsh,
    Plink,
    TortoisePlink,
    Simple,
}

impl SshVariant {
    /// An explicit `ssh.variant`. `auto` and unknown values fall through to
    /// detection, as they do in git.
    fn named(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "ssh" => Some(Self::OpenSsh),
            "plink" | "putty" => Some(Self::Plink),
            "tortoiseplink" => Some(Self::TortoisePlink),
            "simple" => Some(Self::Simple),
            _ => None,
        }
    }

    /// Git's own auto-detection: the program's basename decides.
    fn detect(program: &str) -> Self {
        let program = program.trim_matches(['\'', '"']);
        let base = program.rsplit(['/', '\\']).next().unwrap_or(program);
        let base = base
            .strip_suffix(".exe")
            .unwrap_or(base)
            .to_ascii_lowercase();
        match base.as_str() {
            "tortoiseplink" => Self::TortoisePlink,
            "plink" | "putty" => Self::Plink,
            _ => Self::OpenSsh,
        }
    }

    fn batch_flag(self) -> Option<&'static str> {
        match self {
            Self::OpenSsh => Some("-o BatchMode=yes"),
            Self::Plink | Self::TortoisePlink => Some("-batch"),
            Self::Simple => None,
        }
    }
}

/// The `GIT_SSH_COMMAND` to set, or `None` to leave git's own selection
/// untouched — a `simple` variant takes no options, and a `GIT_SSH` program
/// is invoked with host and command arguments only, so rewriting it into a
/// command string breaks it.
fn batch_mode_ssh_command(
    inherited_command: Option<&str>,
    configured_command: Option<&str>,
    inherited_program: Option<&str>,
    configured_variant: Option<&str>,
) -> Option<String> {
    fn non_empty(value: Option<&str>) -> Option<&str> {
        value.map(str::trim).filter(|v| !v.is_empty())
    }
    let command = non_empty(inherited_command).or_else(|| non_empty(configured_command));
    if command.is_none() && non_empty(inherited_program).is_some() {
        return None;
    }
    let (program, rest) = split_shell_program(command.unwrap_or("ssh"));
    let variant = non_empty(configured_variant)
        .and_then(SshVariant::named)
        .unwrap_or_else(|| SshVariant::detect(program));
    let flag = variant.batch_flag()?;
    Some(format!("{program} {flag}{rest}"))
}

/// Split a shell command string into its program token and the remainder
/// (which keeps its leading whitespace). A quoted program token is kept whole.
fn split_shell_program(command: &str) -> (&str, &str) {
    let end = match command.chars().next() {
        Some(quote @ ('\'' | '"')) => command[1..]
            .find(quote)
            .map(|index| index + 2)
            .unwrap_or(command.len()),
        _ => command.find(char::is_whitespace).unwrap_or(command.len()),
    };
    command.split_at(end)
}

/// The `git clone` that mints a fresh cache entry. The destination is named on
/// the command line, so this one runs from the cache root.
fn cache_clone_command(remote: &RemoteSource) -> std::process::Command {
    let mut command = hardened_git_network_command(&remote_cache_root());
    // `--` so a URL is never read as an option, whatever it starts with.
    command.args(["clone", "--depth", "1", "--", &remote.git_url]);
    command.arg(&remote.cache_dir);
    command
}

/// The remediation every refusal ends with. The redacted display and the
/// cache root are safe to print; the key is identity-derived and carries no
/// userinfo.
fn refusal(remote: &RemoteSource, what: &str) -> anyhow::Error {
    anyhow::anyhow!(
        "refusing cached source {}: {what}. Remove its cache entry `{}` under {} and re-run",
        remote.display,
        remote.cache_key,
        remote_cache_root().display()
    )
}

/// Refuse a cache entry whose contents are not vstack's own directory.
///
/// A symlinked entry, or one whose `.git` is a symlink or a `gitdir:` file, is
/// some other checkout's working tree — one with the same origin passes every
/// content check — so it must be neither read as the remote source nor be the
/// target of `reset --hard`. Filesystem checks only; see
/// [`ensure_cache_entry_is_owned`] for the git-level checks that guard updates.
pub(crate) fn reject_unowned_cache_entry(remote: &RemoteSource) -> Result<()> {
    let meta = std::fs::symlink_metadata(&remote.cache_dir)
        .with_context(|| format!("inspecting cached source {}", remote.display))?;
    if meta.file_type().is_symlink() {
        return Err(refusal(
            remote,
            "its cache entry is a symlink, and updating it would run destructive git commands outside the cache",
        ));
    }
    if !meta.is_dir() {
        return Err(refusal(remote, "its cache entry is not a directory"));
    }
    // `git clone` always leaves a real `.git` directory. A symlink or a
    // `gitdir:` file there redirects the repository metadata elsewhere, so
    // `reset --hard` would act on a worktree vstack does not own even though
    // the entry itself is a plain directory.
    let git_meta = std::fs::symlink_metadata(remote.cache_dir.join(".git")).with_context(|| {
        format!(
            "inspecting git metadata for cached source {}",
            remote.display
        )
    })?;
    if !git_meta.is_dir() || git_meta.file_type().is_symlink() {
        return Err(refusal(
            remote,
            "its cache entry does not own its git metadata",
        ));
    }
    Ok(())
}

/// The checks that decide whether a cache entry is vstack's to update: the
/// filesystem checks above, then two questions for git. Where would it act —
/// the cache's own `config` can carry a `core.worktree` pointing at a user
/// checkout, which no check on the entry or its `.git` sees, and `reset --hard`
/// would then overwrite the user's copies of the tracked files. And whose
/// clone is this — an entry whose `origin` is a different repository would be
/// installed as this source after the reset, and one whose `origin` carries a
/// credential would hand it to the fetch.
pub(crate) fn ensure_cache_entry_is_owned(remote: &RemoteSource) -> Result<()> {
    reject_unowned_cache_entry(remote)?;

    // Canonicalized on both sides: the cache root is routinely reached through
    // a symlinked home or temp directory, and `git_toplevel` reports the
    // resolved path. Anything it cannot answer fails closed.
    let resolved = crate::path_safety::git_toplevel(&remote.cache_dir)
        .ok_or_else(|| refusal(remote, "its work tree could not be resolved"))?;
    let expected = std::fs::canonicalize(&remote.cache_dir)
        .map_err(|err| refusal(remote, &err.to_string()))?;
    if resolved != expected {
        // The work tree is the user location this refuses to touch; it is not
        // printed.
        return Err(refusal(
            remote,
            "its git work tree does not resolve to its cache entry, and updating it would run destructive git commands outside the cache",
        ));
    }

    let output = hardened_git_command(&remote.cache_dir)
        .args(["remote", "get-url", "origin"])
        .output()
        .with_context(|| format!("reading origin for cached source {}", remote.display))?;
    if !output.status.success() {
        return Err(refusal(
            remote,
            &format!(
                "its origin could not be read: {}",
                git_output_summary(&output)
            ),
        ));
    }
    let origin = git_stdout_line(&output.stdout);
    if remote_identity(&origin) != remote_identity(&remote.git_url) {
        return Err(refusal(
            remote,
            &format!(
                "its origin is {}, not this source",
                remote_source_display(&origin)
            ),
        ));
    }
    if let Err(err) = reject_credential_bearing_git_url(&origin) {
        return Err(refusal(
            remote,
            &format!("its origin carries a credential ({err})"),
        ));
    }
    Ok(())
}

/// Git's single-line stdout without the trailing newline — and only that, so a
/// path with legitimate trailing whitespace is left intact.
fn git_stdout_line(stdout: &[u8]) -> String {
    let text = String::from_utf8_lossy(stdout);
    let text = text.strip_suffix('\n').unwrap_or(&text);
    text.strip_suffix('\r').unwrap_or(text).to_string()
}

/// Bring a cache entry to `origin/HEAD`.
///
/// Refuses an entry vstack does not own — that error propagates, because the
/// entry's contents are some other checkout's and must not be installed. A
/// failed fetch is tolerated: the clone is still the requested source at an
/// older revision, so it is kept and the reset skipped. A failed reset is an
/// error: the entry is no longer known to match any revision.
pub(crate) fn update_cached_repo(remote: &RemoteSource) -> Result<()> {
    ensure_cache_entry_is_owned(remote)?;
    let display = &remote.display;
    let fetch = hardened_git_network_command(&remote.cache_dir)
        .args(["fetch", "origin", "--quiet"])
        .stdout(std::process::Stdio::null())
        .output()
        .with_context(|| format!("running git fetch for cached source {display}"))?;
    if !fetch.status.success() {
        // Deduped: an offline run resolves the same source from the TUI's
        // startup refresh and again from the top-level resolve.
        warn_once(
            &remote.cache_key,
            &format!(
                "git fetch failed for cached source {display}: {}; using cached version",
                git_output_summary(&fetch)
            ),
        );
        return Ok(());
    }
    let reset = hardened_git_command(&remote.cache_dir)
        .args(["reset", "--hard", "origin/HEAD"])
        .stdout(std::process::Stdio::null())
        .output()
        .with_context(|| format!("running git reset for cached source {display}"))?;
    if !reset.status.success() {
        bail!(
            "git reset failed for cached source {display}: {}",
            git_output_summary(&reset)
        );
    }
    Ok(())
}

/// Shallow-clone the remote into its cache entry.
pub(crate) fn clone_cached_repo(remote: &RemoteSource) -> Result<()> {
    let root = remote_cache_root();
    std::fs::create_dir_all(&root)
        .with_context(|| format!("creating source cache {}", root.display()))?;
    let output = cache_clone_command(remote)
        .stdout(std::process::Stdio::null())
        .output()
        .context("failed to run git clone — is git installed?")?;
    if !output.status.success() {
        bail!(
            "git clone failed for {}: {}",
            remote.display,
            git_output_summary(&output)
        );
    }
    Ok(())
}

fn git_output_summary(output: &std::process::Output) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let combined = [stderr.trim(), stdout.trim()]
        .into_iter()
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    let sanitized = combined
        .split_whitespace()
        .map(redact_token)
        .collect::<Vec<_>>()
        .join(" ");
    if sanitized.is_empty() {
        "git exited without stderr".to_string()
    } else {
        sanitized
    }
}

/// Redact one whitespace-delimited token of git output: URLs (with or without
/// git's quoting around them) lose userinfo secrets and query/fragment;
/// anything else is left alone.
fn redact_token(token: &str) -> String {
    if !token.contains("://") {
        return token.to_string();
    }
    let start = token
        .find(|ch: char| ch.is_ascii_alphanumeric())
        .unwrap_or(0);
    let (prefix, rest) = token.split_at(start);
    let end = rest
        .rfind(|ch: char| !matches!(ch, '\'' | '"' | '.' | ',' | ';' | ':' | ')' | ']'))
        .map(|index| index + 1)
        .unwrap_or(rest.len());
    let (url, suffix) = rest.split_at(end);
    format!("{prefix}{}{suffix}", remote_source_display(url))
}

// ---------------------------------------------------------------------------
// Remote URL hygiene
// ---------------------------------------------------------------------------

/// A source as it may appear in diagnostics: shorthand as-is, URLs with any
/// userinfo secret and any query/fragment replaced.
pub(crate) fn remote_source_display(source: &str) -> String {
    redact_remote_query(&redact_remote_userinfo(source))
}

/// Refuse a git URL that carries a credential. Userinfo on a non-ssh scheme
/// (`https://token@host/...`), a `user:secret@` pair on any scheme, or a query
/// or fragment (`...?access_token=...`) would hand the secret to every git
/// process and to every diagnostic that echoes the origin. A bare username on
/// an ssh scheme (`ssh://git@host/...`) is how ssh remotes are spelled and is
/// kept.
pub(crate) fn reject_credential_bearing_git_url(url: &str) -> Result<()> {
    if url.contains('?') || url.contains('#') {
        bail!(
            "remote source URLs with a query or fragment are not supported: {}. Use SSH keys, gh auth login, or a Git credential helper instead.",
            remote_source_display(url)
        );
    }
    let Some(parts) = split_url_userinfo(url) else {
        return Ok(());
    };
    if parts.userinfo.is_empty() {
        return Ok(());
    }
    if !is_ssh_like_scheme(parts.scheme) || parts.userinfo.contains(':') {
        bail!(
            "credential-bearing remote source URLs are not supported: {}. Use SSH keys, gh auth login, or a Git credential helper instead.",
            remote_source_display(url)
        );
    }
    Ok(())
}

/// Replace a URL query/fragment with a marker. Git clone URLs have no
/// legitimate use for either, and both are places a token gets carried.
fn redact_remote_query(url: &str) -> String {
    match url.find(['?', '#']) {
        Some(index) => format!("{}<redacted>", &url[..=index]),
        None => url.to_string(),
    }
}

struct UrlUserInfo<'a> {
    scheme: &'a str,
    prefix: &'a str,
    userinfo: &'a str,
    host: &'a str,
    suffix: &'a str,
}

fn split_url_userinfo(input: &str) -> Option<UrlUserInfo<'_>> {
    let scheme_end = input.find("://")?;
    let authority_start = scheme_end + 3;
    // The authority runs to the first `/` and nothing else: stopping at
    // whitespace made a malformed `user:tok en@host` URL parse as having no
    // userinfo at all, so its secret was printed in full.
    let authority_end = input[authority_start..]
        .find('/')
        .map(|idx| authority_start + idx)
        .unwrap_or(input.len());
    let authority = &input[authority_start..authority_end];
    let at = authority.rfind('@')?;
    Some(UrlUserInfo {
        scheme: &input[..scheme_end],
        prefix: &input[..authority_start],
        userinfo: &authority[..at],
        host: &authority[at + 1..],
        suffix: &input[authority_end..],
    })
}

fn is_ssh_like_scheme(scheme: &str) -> bool {
    scheme.eq_ignore_ascii_case("ssh") || scheme.eq_ignore_ascii_case("git+ssh")
}

/// Redact the secret part of a URL's userinfo, keeping a legitimate username.
pub(crate) fn redact_remote_userinfo(input: &str) -> String {
    let Some(parts) = split_url_userinfo(input) else {
        return input.to_string();
    };
    let redacted_userinfo = if let Some((username, _)) = parts.userinfo.split_once(':') {
        if username.is_empty() {
            "<redacted>".to_string()
        } else {
            format!("{username}:<redacted>")
        }
    } else if is_ssh_like_scheme(parts.scheme) {
        parts.userinfo.to_string()
    } else {
        "<redacted>".to_string()
    };
    format!(
        "{}{}@{}{}",
        parts.prefix, redacted_userinfo, parts.host, parts.suffix
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{InstallMethod, LockEntry};
    use std::cell::RefCell;
    use std::collections::HashMap;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn tmpdir(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before epoch")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "vstack-refresh-source-{label}-{}-{nanos}",
            std::process::id()
        ))
    }

    fn make_vstack_source(root: &Path, name: &str) -> PathBuf {
        let source = root.join(name);
        std::fs::create_dir_all(source.join("agents")).unwrap();
        std::fs::create_dir_all(source.join("skills")).unwrap();
        source
    }

    fn lock_entry(name: &str, source: &str) -> LockEntry {
        LockEntry {
            name: name.into(),
            kind: ItemKind::Agent,
            source: source.into(),
            source_repo: None,
            harnesses: vec!["claude-code".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        }
    }

    #[test]
    fn resolve_single_source_accepts_absolute_vstack_source() {
        let root = tmpdir("absolute");
        let source = root.join("source");
        std::fs::create_dir_all(source.join("agents")).unwrap();
        std::fs::create_dir_all(source.join("hooks")).unwrap();

        assert_eq!(
            resolve_single_source(&source.to_string_lossy()),
            Some(source.clone())
        );
        assert!(resolve_single_source(&root.to_string_lossy()).is_none());

        let _ = std::fs::remove_dir_all(root);
    }

    /// `vstack add <SOURCE>` accepts any directory holding the asset, so a lock
    /// entry may record one that the discovery heuristic rejects — a dot-named
    /// dir, or one carrying only `skills/`. Dropping it here is what made
    /// refresh fall back to the majority source and stop propagating edits.
    #[test]
    fn resolve_source_records_keeps_a_source_the_layout_heuristic_rejects() {
        let root = tmpdir("recorded-alternate");
        let alternate = root.join(".agents");
        std::fs::create_dir_all(alternate.join("skills/demo")).unwrap();
        assert!(
            !crate::resolve::is_vstack_source(&alternate),
            "fixture must exercise the heuristic-rejected case"
        );
        assert_eq!(resolve_single_source(&alternate.to_string_lossy()), None);

        assert_eq!(
            resolve_recorded_source(&alternate.to_string_lossy()),
            Some(alternate.clone())
        );

        let mut lock = config::LockFile::default();
        lock.add(lock_entry("demo", &alternate.to_string_lossy()));
        let records = resolve_source_records(&lock).sources;

        assert_eq!(
            records.iter().map(|r| r.root.clone()).collect::<Vec<_>>(),
            vec![alternate]
        );

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn resolve_source_records_resolves_relative_sources_from_project_root() {
        let root = tmpdir("recorded-relative");
        let project = root.join("project");
        let relative_source = project.join("vendor").join("vstack");
        std::fs::create_dir_all(relative_source.join("skills/demo")).unwrap();

        let mut lock = config::LockFile::default();
        lock.add(lock_entry("demo", "./vendor/vstack"));

        let records = crate::test_util::with_project_root(&project, || {
            assert_eq!(
                resolve_recorded_source("./vendor/vstack"),
                Some(std::fs::canonicalize(&relative_source).unwrap())
            );
            assert!(recorded_source_exists("./vendor/vstack"));
            resolve_source_records(&lock).sources
        });

        assert_eq!(records.len(), 1);
        assert_eq!(
            records[0].root,
            std::fs::canonicalize(&relative_source).unwrap()
        );
        assert_eq!(records[0].aliases, vec!["./vendor/vstack".to_string()]);

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn resolve_source_records_records_remote_shorthand_repo_identity() {
        let root = tmpdir("remote-identity");
        let source = make_vstack_source(&root, "source");
        let mut lock = config::LockFile::default();
        lock.add(lock_entry("demo", "vanillagreencom/vstack"));

        let records = resolve_source_records_with(&lock, |source_name| {
            if source_name == "vanillagreencom/vstack" {
                SourceResolution::Resolved(source.clone())
            } else {
                SourceResolution::Absent
            }
        })
        .sources;

        assert_eq!(records.len(), 1);
        assert_eq!(
            records[0].source_repo.as_deref(),
            Some("vanillagreencom/vstack")
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn resolve_source_records_does_not_infer_identity_from_local_layout() {
        let root = tmpdir("local-layout-identity");
        let source = make_vstack_source(&root, "source");
        let mut lock = config::LockFile::default();
        lock.add(lock_entry("demo", &source.to_string_lossy()));

        let records = resolve_source_records(&lock).sources;

        assert_eq!(records.len(), 1);
        assert_eq!(records[0].source_repo, None);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn relative_parent_source_uses_current_worktree_lexical_neighbor() {
        let root = tmpdir("recorded-relative-parent");
        let main_project = root.join("dev").join("consumer");
        let main_checkout_neighbor = root.join("dev").join("vstack");
        let linked_worktree = root
            .join("dev")
            .join(".worktrees")
            .join("consumer")
            .join("issue-1");
        let worktree_neighbor = root
            .join("dev")
            .join(".worktrees")
            .join("consumer")
            .join("vstack");
        std::fs::create_dir_all(&main_project).unwrap();
        std::fs::create_dir_all(main_checkout_neighbor.join("skills/demo")).unwrap();
        std::fs::create_dir_all(&linked_worktree).unwrap();
        std::fs::create_dir_all(worktree_neighbor.join("skills/demo")).unwrap();

        let resolved = crate::test_util::with_project_root(&linked_worktree, || {
            resolve_recorded_source("../vstack")
        });

        assert_eq!(
            resolved,
            Some(std::fs::canonicalize(&worktree_neighbor).unwrap()),
            "copied relative lock sources are resolved from the current worktree root"
        );
        assert_ne!(
            resolved,
            Some(std::fs::canonicalize(&main_checkout_neighbor).unwrap()),
            "../vstack must not silently keep pointing at the main checkout after a lock is copied"
        );

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn recorded_remote_shorthand_does_not_bind_to_project_local_shadow_dir() {
        let root = tmpdir("remote-shadow");
        let project = root.join("project");
        let shadow = project.join("owner").join("repo");
        std::fs::create_dir_all(&shadow).unwrap();

        crate::test_util::with_project_root(&project, || {
            assert!(resolve_recorded_local_source("owner/repo").is_none());
            assert_ne!(resolve_recorded_source("owner/repo"), Some(shadow.clone()));
            // The shorthand names a remote, so it is a source of its own —
            // never one whose entry may be reinstalled from somewhere else.
            assert!(recorded_source_exists("owner/repo"));
        });

        let _ = std::fs::remove_dir_all(root);
    }

    /// An entry that recorded a real source — live or vanished — must never be
    /// silently rebound to the sole other loaded source; that reinstalled it
    /// from a repo it was never installed from (a same-named asset there
    /// replaced the real one). A vanished source is reported missing instead.
    #[test]
    fn refresh_source_for_entry_never_rebinds_a_recorded_source() {
        let root = tmpdir("no-rebind");
        let alternate = root.join(".agents");
        std::fs::create_dir_all(alternate.join("skills/demo")).unwrap();
        let only_source = make_vstack_source(&root, "other");
        let sources = vec![RefreshSource::from_root(&only_source)];

        let live = lock_entry("demo", &alternate.to_string_lossy());
        assert!(
            refresh_source_for_entry(&sources, &live).is_none(),
            "an entry whose recorded source exists must not bind to a different source"
        );

        let vanished = lock_entry("demo", &root.join("deleted-repo").to_string_lossy());
        assert!(
            refresh_source_for_entry(&sources, &vanished).is_none(),
            "a recorded absolute source that vanished must not bind to a different source"
        );

        let uncached_remote = lock_entry("demo", "owner/repo");
        assert!(
            refresh_source_for_entry(&sources, &uncached_remote).is_none(),
            "a recorded remote that did not resolve must not bind to a local source"
        );

        let project = root.join("project");
        std::fs::create_dir_all(&project).unwrap();
        let vanished_relative = lock_entry("demo", "./vendor/gone");
        crate::test_util::with_project_root(&project, || {
            assert!(
                refresh_source_for_entry(&sources, &vanished_relative).is_none(),
                "a recorded relative source that vanished must not bind to a different source"
            );
        });

        let _ = std::fs::remove_dir_all(root);
    }

    /// The fallback exists for locks that recorded no usable source at all:
    /// an empty source (disk recovery into an empty lock) or a bare
    /// placeholder token (pre-1.0 hash/reconcile paths). Even those bind only
    /// while exactly one source is loaded and the token names no live
    /// project-relative directory.
    #[test]
    fn refresh_source_for_entry_falls_back_only_for_legacy_placeholder_sources() {
        let root = tmpdir("legacy-placeholder");
        let project = root.join("project");
        std::fs::create_dir_all(&project).unwrap();
        let only_source = make_vstack_source(&root, "other");
        let sources = vec![RefreshSource::from_root(&only_source)];

        crate::test_util::with_project_root(&project, || {
            for placeholder in ["", "source"] {
                assert_eq!(
                    refresh_source_for_entry(&sources, &lock_entry("demo", placeholder))
                        .map(|s| s.root.clone()),
                    Some(only_source.clone()),
                    "legacy placeholder {placeholder:?} keeps the single-source fallback"
                );
            }

            std::fs::create_dir_all(project.join("source")).unwrap();
            assert!(
                refresh_source_for_entry(&sources, &lock_entry("demo", "source")).is_none(),
                "a bare token that names a live project-relative dir is a real source"
            );

            for legacy in ["", "  ", "local"] {
                assert!(
                    may_rebind_to_fallback_source(legacy),
                    "{legacy:?} is a legacy placeholder"
                );
            }
            for recorded in [
                "/gone/checkout",
                "~/gone",
                ".",
                "./gone",
                "../gone",
                "owner/repo",
                "https://github.com/owner/repo.git",
                "git@github.com:owner/repo.git",
            ] {
                assert!(
                    !may_rebind_to_fallback_source(recorded),
                    "{recorded:?} is a recorded source, never rebound"
                );
            }
        });

        let second = make_vstack_source(&root, "second");
        let two_sources = vec![
            RefreshSource::from_root(&only_source),
            RefreshSource::from_root(&second),
        ];
        assert!(
            refresh_source_for_entry(&two_sources, &lock_entry("demo", "")).is_none(),
            "no fallback when more than one source is loaded"
        );

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn refresh_source_for_entry_does_not_fallback_for_live_relative_source() {
        let root = tmpdir("relative-no-rebind");
        let project = root.join("project");
        let relative_source = project.join("vendor").join("vstack");
        std::fs::create_dir_all(relative_source.join("skills/demo")).unwrap();
        let only_source = make_vstack_source(&root, "other");
        let sources = vec![RefreshSource::from_root(&only_source)];
        let live_relative = lock_entry("demo", "./vendor/vstack");

        crate::test_util::with_project_root(&project, || {
            assert!(
                refresh_source_for_entry(&sources, &live_relative).is_none(),
                "a live relative source must not rebind to the sole loaded source"
            );
        });

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn resolve_source_records_calls_resolver_once_per_unique_lock_source() {
        let root = tmpdir("resolver-count");
        let source_a = root.join("source-a");
        let source_b = root.join("source-b");
        let mut lock = config::LockFile::default();
        lock.add(lock_entry("rust", "owner/repo"));
        lock.add(LockEntry {
            name: "dev".into(),
            kind: ItemKind::Skill,
            source: "owner/repo".into(),
            source_repo: None,
            harnesses: vec!["claude-code".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        });
        lock.add(lock_entry("scout", "other/repo"));

        let counts: RefCell<HashMap<String, usize>> = RefCell::new(HashMap::new());
        let records = resolve_source_records_with(&lock, |source| {
            *counts.borrow_mut().entry(source.to_string()).or_default() += 1;
            match source {
                "owner/repo" => SourceResolution::Resolved(source_a.clone()),
                "other/repo" => SourceResolution::Resolved(source_b.clone()),
                _ => SourceResolution::Absent,
            }
        })
        .sources;

        assert_eq!(records.len(), 2);
        assert_eq!(counts.borrow().get("owner/repo"), Some(&1));
        assert_eq!(counts.borrow().get("other/repo"), Some(&1));

        let _ = std::fs::remove_dir_all(root);
    }

    // -----------------------------------------------------------------------
    // Remote cache git hardening
    // -----------------------------------------------------------------------

    /// Test-side git: unhardened with respect to the ownership checks under
    /// test, but never redirected by an inherited location override.
    fn git(repo: &Path, args: &[&str]) {
        let mut command = std::process::Command::new("git");
        for key in GIT_LOCATION_ENV_VARS {
            command.env_remove(key);
        }
        let output = command.args(args).current_dir(repo).output().unwrap();
        assert!(
            output.status.success(),
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn git_stdout(repo: &Path, args: &[&str]) -> String {
        let mut command = std::process::Command::new("git");
        for key in GIT_LOCATION_ENV_VARS {
            command.env_remove(key);
        }
        let output = command.args(args).current_dir(repo).output().unwrap();
        assert!(output.status.success(), "git {args:?} failed");
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    }

    /// A committed repository at `dir` with `README.md` tracked.
    fn init_git_repo(dir: &Path) {
        std::fs::create_dir_all(dir).unwrap();
        git(dir, &["init", "-q", "-b", "main"]);
        git(dir, &["config", "user.email", "test@example.com"]);
        git(dir, &["config", "user.name", "Test"]);
        git(dir, &["config", "commit.gpgsign", "false"]);
        std::fs::write(dir.join("README.md"), "upstream\n").unwrap();
        git(dir, &["add", "README.md"]);
        git(dir, &["commit", "-q", "-m", "init"]);
    }

    fn file_url(path: &Path) -> String {
        format!("file://{}", path.display())
    }

    /// A remote whose clone lives at `cache` and whose origin is `origin`.
    fn remote_at(cache: &Path, origin: &Path) -> RemoteSource {
        RemoteSource {
            display: "owner/repo".to_string(),
            git_url: file_url(origin),
            cache_key: cache.file_name().unwrap().to_string_lossy().into_owned(),
            cache_dir: cache.to_path_buf(),
            legacy_cache_dir: None,
        }
    }

    /// Clone `origin` into `cache` the way vstack would have.
    fn clone_into(origin: &Path, cache: &Path) {
        std::fs::create_dir_all(cache.parent().unwrap()).unwrap();
        git(
            cache.parent().unwrap(),
            &["clone", "-q", &file_url(origin), cache.to_str().unwrap()],
        );
    }

    /// The reproduced escape's fixture: a real cache directory owning a real
    /// `.git` — so every filesystem check passes — cloned from `origin`, whose
    /// own `core.worktree` names the victim directory. The victim holds a file
    /// the upstream repo also tracks, with different contents.
    struct RedirectedCache {
        root: PathBuf,
        remote: RemoteSource,
        victim: PathBuf,
    }

    fn redirected_cache_at(root: &Path, cache: &Path) -> RedirectedCache {
        let origin = root.join("origin");
        init_git_repo(&origin);
        let victim = root.join("victim");
        std::fs::create_dir_all(&victim).unwrap();
        std::fs::write(victim.join("README.md"), "precious\n").unwrap();
        clone_into(&origin, cache);
        git(
            cache,
            &["config", "core.worktree", victim.to_str().unwrap()],
        );
        RedirectedCache {
            root: root.to_path_buf(),
            remote: remote_at(cache, &origin),
            victim,
        }
    }

    fn redirected_cache(label: &str) -> RedirectedCache {
        let root = tmpdir(label);
        let cache = root.join("cache").join("owner_repo");
        redirected_cache_at(&root, &cache)
    }

    fn victim_readme(fx: &RedirectedCache) -> String {
        std::fs::read_to_string(fx.victim.join("README.md")).unwrap()
    }

    /// Control for the fixture: the unhardened update main used to run really
    /// does overwrite the victim's file. Without this, the refusal tests below
    /// would pass against a fixture that never reproduced the escape.
    #[test]
    fn control_unhardened_reset_in_a_worktree_redirected_cache_clobbers_the_victim() {
        let fx = redirected_cache("control-clobber");
        git(&fx.remote.cache_dir, &["reset", "--hard", "origin/HEAD"]);
        assert_eq!(
            victim_readme(&fx),
            "upstream\n",
            "the fixture must reproduce the escape for the refusal tests to mean anything"
        );
        let _ = std::fs::remove_dir_all(fx.root);
    }

    #[test]
    fn update_cached_repo_refuses_a_cache_whose_worktree_points_outside_it() {
        let fx = redirected_cache("refuse-redirected-worktree");

        let err = update_cached_repo(&fx.remote).unwrap_err().to_string();
        assert!(err.contains("refusing cached source owner/repo"), "{err}");
        assert!(err.contains("does not resolve to its cache entry"), "{err}");
        assert!(err.contains("Remove its cache entry `owner_repo`"), "{err}");
        assert!(
            !err.contains(&fx.victim.display().to_string()),
            "the victim path may not be printed: {err}"
        );
        assert_eq!(victim_readme(&fx), "precious\n");
        let _ = std::fs::remove_dir_all(fx.root);
    }

    #[test]
    fn update_cached_repo_brings_an_owned_cache_to_origin_head() {
        let root = tmpdir("owned-update");
        let origin = root.join("origin");
        init_git_repo(&origin);
        let cache = root.join("cache").join("owner_repo");
        clone_into(&origin, &cache);
        std::fs::write(origin.join("README.md"), "newer\n").unwrap();
        git(&origin, &["commit", "-q", "-am", "update"]);
        // Local edits in the cache are vstack's to discard.
        std::fs::write(cache.join("README.md"), "scribble\n").unwrap();

        update_cached_repo(&remote_at(&cache, &origin)).unwrap();

        assert_eq!(
            std::fs::read_to_string(cache.join("README.md")).unwrap(),
            "newer\n"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn update_tolerates_a_failed_fetch_and_keeps_the_stale_cache() {
        let root = tmpdir("fetch-fail");
        let origin = root.join("origin");
        init_git_repo(&origin);
        let cache = root.join("cache").join("owner_repo");
        clone_into(&origin, &cache);
        let remote = remote_at(&cache, &origin);
        std::fs::remove_dir_all(&origin).unwrap();

        update_cached_repo(&remote).unwrap();
        assert_eq!(
            std::fs::read_to_string(cache.join("README.md")).unwrap(),
            "upstream\n"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn update_reports_a_failed_reset_as_an_error() {
        let root = tmpdir("reset-fail");
        let origin = root.join("origin");
        init_git_repo(&origin);
        let cache = root.join("cache").join("owner_repo");
        clone_into(&origin, &cache);
        // The fetch succeeds; the reset cannot take the index lock.
        std::fs::write(cache.join(".git").join("index.lock"), "").unwrap();

        let err = update_cached_repo(&remote_at(&cache, &origin))
            .unwrap_err()
            .to_string();
        assert!(err.contains("git reset failed"), "{err}");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn update_refuses_a_cache_whose_origin_is_another_repository() {
        let root = tmpdir("origin-mismatch");
        let origin = root.join("origin");
        init_git_repo(&origin);
        let other = root.join("other");
        init_git_repo(&other);
        let cache = root.join("cache").join("owner_repo");
        clone_into(&other, &cache);

        let err = update_cached_repo(&remote_at(&cache, &origin))
            .unwrap_err()
            .to_string();
        assert!(err.contains("its origin is"), "{err}");
        assert!(err.contains("not this source"), "{err}");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn update_refuses_a_cache_whose_origin_carries_a_credential() {
        let root = tmpdir("origin-credential");
        let cache = root.join("cache").join("owner_repo");
        init_git_repo(&cache);
        // Identity-equal to the clean expected URL: userinfo normalizes away,
        // so the mismatch check alone would accept this and then fetch with
        // the token.
        git(
            &cache,
            &[
                "remote",
                "add",
                "origin",
                "https://cache-token@github.com/Owner/Repo.git",
            ],
        );
        let remote = RemoteSource::parse("owner/repo").unwrap().unwrap();
        let remote = RemoteSource {
            cache_dir: cache.clone(),
            ..remote
        };

        let err = update_cached_repo(&remote).unwrap_err().to_string();
        assert!(err.contains("carries a credential"), "{err}");
        assert!(!err.contains("cache-token"), "{err}");

        // A clean origin with the same identity passes the origin checks.
        git(
            &cache,
            &[
                "remote",
                "set-url",
                "origin",
                "https://github.com/Owner/Repo.git",
            ],
        );
        ensure_cache_entry_is_owned(&remote).unwrap();
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_cache_entry_is_refused_on_every_resolution_path() {
        let root = tmpdir("symlinked-cache-entry");
        let checkout = root.join("user-checkout");
        init_git_repo(&checkout);
        std::fs::write(checkout.join("uncommitted.txt"), "precious\n").unwrap();
        std::fs::write(checkout.join("README.md"), "precious\n").unwrap();
        let home = root.join("home");

        crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
            let remote = RemoteSource::parse("owner/repo").unwrap().unwrap();
            std::fs::create_dir_all(remote.cache_dir.parent().unwrap()).unwrap();
            std::os::unix::fs::symlink(&checkout, &remote.cache_dir).unwrap();

            let err = reject_unowned_cache_entry(&remote).unwrap_err().to_string();
            assert!(err.contains("symlink"), "{err}");
            let err = update_cached_repo(&remote).unwrap_err().to_string();
            assert!(err.contains("symlink"), "{err}");
            // Neither the read-only nor the updating resolution returns the
            // linked checkout as the remote source, and both report the
            // refusal rather than an absent source.
            for resolution in [
                resolve_single_source_with("owner/repo", false, false),
                resolve_single_source_with("owner/repo", true, true),
            ] {
                assert!(
                    matches!(&resolution, SourceResolution::Refused(reason) if reason.contains("symlink")),
                    "{resolution:?}"
                );
            }
            assert_eq!(resolve_source_path("owner/repo"), None);
            assert_eq!(resolve_single_source("owner/repo"), None);
            assert!(recorded_source_exists("owner/repo"));
        });
        assert_eq!(
            std::fs::read_to_string(checkout.join("README.md")).unwrap(),
            "precious\n"
        );
        assert!(checkout.join("uncommitted.txt").exists());
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn cache_entry_whose_git_metadata_is_redirected_is_refused() {
        let root = tmpdir("redirected-gitdir");
        let checkout = root.join("user-checkout");
        init_git_repo(&checkout);
        std::fs::write(checkout.join("README.md"), "precious\n").unwrap();
        // A plain directory, so the entry check passes, whose `.git` points at
        // the user's real repository.
        let cache = root.join("cache").join("owner_repo");
        std::fs::create_dir_all(&cache).unwrap();
        std::os::unix::fs::symlink(checkout.join(".git"), cache.join(".git")).unwrap();
        let remote = remote_at(&cache, &checkout);

        let err = update_cached_repo(&remote).unwrap_err().to_string();
        assert!(err.contains("does not own its git metadata"), "{err}");

        // A `gitdir:` file is the same redirection by another spelling.
        std::fs::remove_file(cache.join(".git")).unwrap();
        std::fs::write(
            cache.join(".git"),
            format!("gitdir: {}\n", checkout.join(".git").display()),
        )
        .unwrap();
        let err = update_cached_repo(&remote).unwrap_err().to_string();
        assert!(err.contains("does not own its git metadata"), "{err}");
        assert_eq!(
            std::fs::read_to_string(checkout.join("README.md")).unwrap(),
            "precious\n"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    fn command_env(
        command: &std::process::Command,
    ) -> std::collections::BTreeMap<String, Option<String>> {
        command
            .get_envs()
            .map(|(key, value)| {
                (
                    key.to_string_lossy().into_owned(),
                    value.map(|v| v.to_string_lossy().into_owned()),
                )
            })
            .collect()
    }

    #[test]
    fn every_git_invocation_is_non_interactive_and_drops_location_overrides() {
        let root = tmpdir("git-env");
        let home = root.join("home");
        crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
            git_env_assertions(&root)
        });
        let _ = std::fs::remove_dir_all(root);
    }

    fn git_env_assertions(root: &Path) {
        let dir = remote_cache_root().join("owner_repo");
        std::fs::create_dir_all(&dir).unwrap();
        let local = command_env(&hardened_git_command(&dir));
        // Control: a bare `git` carries none of it, so the assertions below
        // are claims about the hardening and not about two empty maps.
        assert_ne!(command_env(&std::process::Command::new("git")), local);

        for key in GIT_LOCATION_ENV_VARS {
            assert_eq!(
                local.get(*key),
                Some(&None),
                "{key} is not cleared: {local:?}"
            );
        }
        assert_eq!(
            local
                .get("GIT_TERMINAL_PROMPT")
                .cloned()
                .flatten()
                .as_deref(),
            Some("0")
        );

        let network = command_env(&hardened_git_network_command(&dir));
        for (key, value) in &local {
            assert_eq!(
                network.get(key),
                Some(value),
                "{key} differs on the network path"
            );
        }
        // Which ssh command lands here depends on the runner's own git config
        // and environment; that selection is covered exhaustively by the
        // `batch_mode_ssh_command` tests. What must hold everywhere is that
        // the network path adds nothing but that one variable, and that
        // whatever it sets is noninteractive.
        for (key, value) in &network {
            if key != "GIT_SSH_COMMAND" {
                assert_eq!(local.get(key), Some(value), "{key} differs");
            }
        }
        if let Some(ssh) = network.get("GIT_SSH_COMMAND").cloned().flatten() {
            assert!(
                ssh.contains("-o BatchMode=yes") || ssh.contains("-batch"),
                "{ssh}"
            );
        }
        // Cloning is as unattended as fetching and must be built by the same
        // constructor.
        let remote = remote_at(&dir, &root.join("origin"));
        assert_eq!(command_env(&cache_clone_command(&remote)), network);
    }

    #[test]
    fn batch_mode_ssh_command_follows_git_precedence_and_outranks_later_options() {
        // Nothing configured.
        assert_eq!(
            batch_mode_ssh_command(None, None, None, None).as_deref(),
            Some("ssh -o BatchMode=yes")
        );
        assert_eq!(
            batch_mode_ssh_command(Some("   "), None, None, None).as_deref(),
            Some("ssh -o BatchMode=yes")
        );
        // GIT_SSH_COMMAND outranks core.sshCommand.
        assert_eq!(
            batch_mode_ssh_command(
                Some("ssh -i /keys/a"),
                Some("/opt/ssh -i /keys/b"),
                Some("/x"),
                None
            )
            .as_deref(),
            Some("ssh -o BatchMode=yes -i /keys/a")
        );
        assert_eq!(
            batch_mode_ssh_command(None, Some("/opt/ssh -i /keys/b"), Some("/x"), None).as_deref(),
            Some("/opt/ssh -o BatchMode=yes -i /keys/b")
        );
        // An inherited BatchMode=no is outranked: OpenSSH takes the first
        // value it sees, and ours comes directly after the program.
        assert_eq!(
            batch_mode_ssh_command(Some("ssh -o BatchMode=no -i k"), None, None, None).as_deref(),
            Some("ssh -o BatchMode=yes -o BatchMode=no -i k")
        );
        // A quoted program token stays whole.
        assert_eq!(
            batch_mode_ssh_command(Some("'/my ssh' -v"), None, None, None).as_deref(),
            Some("'/my ssh' -o BatchMode=yes -v")
        );
    }

    /// `-o BatchMode=yes` is OpenSSH's spelling and nobody else's. Git drives
    /// four ssh implementations; handing the wrong one OpenSSH's option — or
    /// rewriting a `GIT_SSH` program into a command line at all — breaks the
    /// connection instead of making it noninteractive.
    #[test]
    fn batch_mode_matches_the_ssh_variant_git_would_use() {
        // Auto-detected by program basename, as git detects it.
        for program in [
            "plink",
            "/usr/bin/plink",
            "PuTTY.exe",
            "C:\\tools\\TortoisePlink.exe",
        ] {
            let command = format!("{program} -i key");
            assert_eq!(
                batch_mode_ssh_command(Some(&command), None, None, None).as_deref(),
                Some(format!("{program} -batch -i key").as_str()),
                "{program}"
            );
        }
        // An explicit ssh.variant outranks detection in both directions.
        assert_eq!(
            batch_mode_ssh_command(Some("/opt/myssh"), None, None, Some("tortoiseplink"))
                .as_deref(),
            Some("/opt/myssh -batch")
        );
        assert_eq!(
            batch_mode_ssh_command(Some("plink"), None, None, Some("ssh")).as_deref(),
            Some("plink -o BatchMode=yes")
        );
        // `auto` and unknown values fall through to detection, as in git.
        for variant in ["auto", "nonsense"] {
            assert_eq!(
                batch_mode_ssh_command(Some("plink"), None, None, Some(variant)).as_deref(),
                Some("plink -batch"),
                "{variant}"
            );
        }
        // `simple` accepts no options at all, and a GIT_SSH program is invoked
        // with host and command arguments only: both are left exactly as git
        // has them.
        assert_eq!(
            batch_mode_ssh_command(Some("/opt/simple-ssh"), None, None, Some("simple")),
            None
        );
        assert_eq!(
            batch_mode_ssh_command(None, None, Some("/path with space/ssh"), None),
            None
        );
        assert_eq!(
            batch_mode_ssh_command(None, None, Some("/x"), Some("ssh")),
            None
        );
    }

    #[test]
    fn core_ssh_command_is_read_from_git_config() {
        let root = tmpdir("core-ssh-command");
        let repo = root.join("repo");
        init_git_repo(&repo);
        git(
            &repo,
            &["config", "core.sshCommand", "/opt/ssh -i /keys/id"],
        );
        git(&repo, &["config", "ssh.variant", "plink"]);

        // `git config --get` ignores GIT_SSH_COMMAND, so this holds on any
        // runner; the precedence between the two is covered above.
        assert_eq!(
            configured_ssh_command(&repo).as_deref(),
            Some("/opt/ssh -i /keys/id")
        );
        assert_eq!(
            configured_git_value(&repo, "ssh.variant").as_deref(),
            Some("plink")
        );
        assert_eq!(configured_git_value(&repo, "core.noSuchKey"), None);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn remote_source_parse_derives_one_key_per_repository_identity() {
        let root = tmpdir("remote-parse");
        let home = root.join("home");
        crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
            let cache_root = home.join(".vstack").join("cache");
            let shorthand = RemoteSource::parse("Owner/Repo").unwrap().unwrap();
            // Built from the canonical slug, never the raw spelling.
            assert_eq!(shorthand.git_url, "https://github.com/owner/repo.git");
            assert!(
                shorthand.cache_key.starts_with("owner_repo-"),
                "{}",
                shorthand.cache_key
            );
            assert_eq!(
                shorthand.cache_dir,
                cache_root.join(&shorthand.cache_key),
                "the clone lives under the cache root, one component down"
            );
            assert_eq!(shorthand.display, "Owner/Repo");

            // A shorthand carrying `.git` or a trailing slash names the same
            // repository and must not build `repo.git.git` or `repo/.git`.
            for spelling in ["Owner/Repo.git", "owner/repo/"] {
                let remote = RemoteSource::parse(spelling).unwrap().unwrap();
                assert_eq!(remote.git_url, shorthand.git_url, "{spelling}");
                assert_eq!(remote.cache_key, shorthand.cache_key, "{spelling}");
            }

            // Every spelling of the same GitHub repo shares the clone.
            for spelling in [
                "https://github.com/owner/repo.git",
                "https://github.com/Owner/Repo",
                "git@github.com:owner/repo.git",
                "ssh://git@github.com/owner/repo.git",
                "git+ssh://git@github.com/owner/repo.git",
            ] {
                let remote = RemoteSource::parse(spelling).unwrap().unwrap();
                assert_eq!(remote.cache_key, shorthand.cache_key, "{spelling}");
            }
            assert_eq!(
                RemoteSource::parse("git+ssh://git@github.com/owner/repo.git")
                    .unwrap()
                    .unwrap()
                    .git_url,
                "ssh://git@github.com/owner/repo.git"
            );

            // Another host never shares a key with GitHub, and two hosts never
            // share one with each other.
            let gitlab = RemoteSource::parse("https://gitlab.com/owner/repo.git")
                .unwrap()
                .unwrap();
            assert!(
                gitlab.cache_key.starts_with("gitlab_com_owner_repo-"),
                "{}",
                gitlab.cache_key
            );
            let gitea = RemoteSource::parse("ssh://git@gitea.example.org:2222/owner/repo.git")
                .unwrap()
                .unwrap();
            assert_ne!(gitea.cache_key, gitlab.cache_key);
            assert_ne!(gitea.cache_key, shorthand.cache_key);

            // Not remote-shaped.
            for local in ["/abs/path", "./vendor", "../vstack", "name", "", "~/x"] {
                assert_eq!(RemoteSource::parse(local).unwrap(), None, "{local}");
            }
        });
        let _ = std::fs::remove_dir_all(root);
    }

    /// The readable half of a cache key lowercases and collapses runs, so it
    /// alone puts distinct repositories in one directory — and whichever
    /// source populated it first would then decide what every later one
    /// installs.
    #[test]
    fn distinct_repositories_never_share_a_cache_key() {
        let root = tmpdir("distinct-keys");
        let home = root.join("home");
        crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
            let key = |source: &str| {
                RemoteSource::parse(source)
                    .unwrap_or_else(|err| panic!("{source}: {err}"))
                    .unwrap_or_else(|| panic!("{source} is not remote-shaped"))
                    .cache_key
            };
            for (a, b) in [
                // Collapsing `_` and `/` alike.
                ("foo/bar_baz", "foo_bar/baz"),
                ("https://gitea.example/a/b_c", "https://gitea.example/a_b/c"),
                ("https://gitea.example/a.b/c", "https://gitea.example/a_b/c"),
                // Case is part of a path everywhere but GitHub.
                (
                    "https://gitea.example/Owner/repo",
                    "https://gitea.example/owner/repo",
                ),
            ] {
                let (ka, kb) = (key(a), key(b));
                assert_eq!(
                    ka.rsplit_once('-').unwrap().0,
                    kb.rsplit_once('-').unwrap().0,
                    "{a} vs {b}: the readable prefixes must collide, or this pair proves nothing"
                );
                assert_ne!(ka, kb, "{a} vs {b}");
            }
            // Spellings of one repository still share theirs.
            for spelling in ["owner/repo.git", "owner/repo/", "Owner/Repo"] {
                assert_eq!(key(spelling), key("owner/repo"), "{spelling}");
            }
        });
        let _ = std::fs::remove_dir_all(root);
    }

    /// A clone made before the key became identity-derived is adopted, not
    /// orphaned: without the rename every existing cache entry reads as absent
    /// on the first refresh after the upgrade.
    #[test]
    fn a_clone_under_the_pre_identity_cache_key_is_adopted() {
        let root = tmpdir("legacy-cache-key");
        let home = root.join("home");
        let origin = root.join("origin");
        init_git_repo(&origin);

        crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
            let remote = RemoteSource::parse("Owner/Repo").unwrap().unwrap();
            // Control: with nothing under either key the source is absent, so
            // the adoption below is what makes the difference.
            assert!(!cache_entry_present(&remote));
            assert_eq!(
                resolve_single_source_with("Owner/Repo", false, false),
                SourceResolution::Absent
            );

            let legacy = remote_cache_root().join("Owner_Repo");
            clone_into(&origin, &legacy);

            assert!(cache_entry_present(&remote));
            assert!(!legacy.exists(), "the legacy entry is renamed, not copied");
            assert_eq!(
                resolve_single_source_with("Owner/Repo", false, false),
                SourceResolution::Resolved(remote.cache_dir.clone())
            );
            assert_eq!(
                std::fs::read_to_string(remote.cache_dir.join("README.md")).unwrap(),
                "upstream\n"
            );
        });
        let _ = std::fs::remove_dir_all(root);
    }

    /// A remote-shaped source that git must not be handed is refused at parse,
    /// before any process sees it — and stays a source, so no entry of its own
    /// is quietly reinstalled from somewhere else.
    #[test]
    fn remote_sources_git_must_not_be_handed_are_refused_at_parse() {
        for source in [
            // git reads a leading `-` as an option, not a repository.
            "--upload-pack=evil@host:repo.git",
            // A malformed authority stops userinfo parsing, and the secret
            // then reaches git and every diagnostic unredacted.
            "https://user:to ken@github.com/owner/repo.git",
            "https://user:to\tken@github.com/owner/repo.git",
        ] {
            let err = RemoteSource::parse(source)
                .unwrap_err()
                .to_string()
                .to_lowercase();
            assert!(!err.contains("ken"), "{source}: {err}");
            assert!(looks_like_remote_source(source), "{source}");
            assert!(recorded_source_exists(source), "{source}");
        }
        // The whole authority is redacted for display even when it is
        // malformed, so a diagnostic never carries the secret.
        assert!(
            !remote_source_display("https://user:to ken@github.com/owner/repo.git").contains("ken")
        );
    }

    #[test]
    fn clone_never_lets_a_url_be_read_as_an_option() {
        let root = tmpdir("clone-args");
        let home = root.join("home");
        crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
            let remote = remote_at(
                &remote_cache_root().join("owner_repo"),
                &root.join("origin"),
            );
            let args: Vec<String> = cache_clone_command(&remote)
                .get_args()
                .map(|arg| arg.to_string_lossy().into_owned())
                .collect();
            let end_of_options = args.iter().position(|arg| arg == "--").expect("`--`");
            assert!(
                args[end_of_options + 1..].contains(&remote.git_url),
                "{args:?}"
            );
        });
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn remote_source_cache_keys_are_always_one_safe_path_component() {
        let root = tmpdir("remote-keys");
        let home = root.join("home");
        crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
            for source in [
                "a/..",
                "../x/y",
                "https://host/../..",
                "https://host/a/../b.git",
                "https://host/%2e%2e/x",
                "git@host:../x",
                "https://host/a\\b/c",
                "https://host//",
                "https://Ünïcode.example/o/r",
            ] {
                let Ok(Some(remote)) = RemoteSource::parse(source) else {
                    continue;
                };
                let key = &remote.cache_key;
                assert!(!key.is_empty(), "{source}");
                assert!(!key.contains('/') && !key.contains('\\'), "{source}: {key}");
                assert!(key != "." && key != "..", "{source}: {key}");
                assert!(
                    key.chars().all(|ch| ch.is_ascii_lowercase()
                        || ch.is_ascii_digit()
                        || matches!(ch, '_' | '-')),
                    "{source}: {key}"
                );
                assert_eq!(
                    remote.cache_dir.parent(),
                    Some(remote_cache_root().as_path()),
                    "{source}"
                );
            }
        });
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn remote_source_parse_refuses_credentials_and_plaintext_before_any_git_runs() {
        for source in [
            "https://token@github.com/Owner/Repo.git",
            "HTTPS://token@github.com/Owner/Repo.git",
            "https://user:token@github.com/Owner/Repo.git",
            "ssh://git:token@github.com/Owner/Repo.git",
            "git+ssh://git:token@github.com/Owner/Repo.git",
            "https://github.com/Owner/Repo.git?access_token=token",
            "https://github.com/Owner/Repo.git#token",
            "https://token@evil.example/Owner/Repo.git?k=token",
        ] {
            let err = RemoteSource::parse(source).unwrap_err().to_string();
            assert!(!err.contains("token"), "{source}: {err}");
            assert!(err.contains("<redacted>"), "{source}: {err}");
            assert!(looks_like_remote_source(source), "{source}");
        }
        let err = RemoteSource::parse("http://github.com/Owner/Repo.git")
            .unwrap_err()
            .to_string();
        assert!(err.contains("plaintext HTTP"), "{err}");

        // Legitimate usernames and shorthand are kept.
        for source in [
            "https://github.com/Owner/Repo.git",
            "ssh://git@github.com/Owner/Repo.git",
            "git+ssh://git@github.com/Owner/Repo.git",
            "git@github.com:Owner/Repo.git",
            "Owner/Repo",
        ] {
            RemoteSource::parse(source).unwrap_or_else(|err| panic!("{source}: {err}"));
        }
        assert_eq!(
            remote_source_display("https://user:token@github.com/Owner/Repo.git?k=secret"),
            "https://user:<redacted>@github.com/Owner/Repo.git?<redacted>"
        );
        assert_eq!(
            remote_source_display("ssh://git@github.com/Owner/Repo.git"),
            "ssh://git@github.com/Owner/Repo.git"
        );
        assert_eq!(remote_source_display("Owner/Repo"), "Owner/Repo");
    }

    #[test]
    fn git_output_summary_redacts_query_tokens_and_userinfo_in_urls() {
        let output = std::process::Output {
            status: std::process::ExitStatus::default(),
            stdout: Vec::new(),
            stderr: b"fatal: unable to access 'https://x@github.com/o/r.git?access_token=secret/': 403\nhint: see https://docs.example/help#anchor".to_vec(),
        };
        let summary = git_output_summary(&output);
        assert!(!summary.contains("secret"), "{summary}");
        assert!(!summary.contains("x@"), "{summary}");
        assert!(summary.contains("fatal: unable to access"), "{summary}");
        assert!(
            summary.contains("'https://<redacted>@github.com/o/r.git?<redacted>':"),
            "{summary}"
        );
        // A fragment is redacted; the surrounding prose is untouched.
        assert!(
            summary.contains("hint: see https://docs.example/help#<redacted>"),
            "{summary}"
        );
    }

    #[test]
    fn clone_cached_repo_makes_a_shallow_clone_in_the_cache_root() {
        let root = tmpdir("clone");
        let origin = root.join("origin");
        init_git_repo(&origin);
        std::fs::write(origin.join("README.md"), "second\n").unwrap();
        git(&origin, &["commit", "-q", "-am", "second"]);
        let home = root.join("home");
        crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
            let cache = remote_cache_root().join("owner_repo");
            assert!(!cache.exists());
            clone_cached_repo(&remote_at(&cache, &origin)).unwrap();
            assert_eq!(
                std::fs::read_to_string(cache.join("README.md")).unwrap(),
                "second\n"
            );
            assert_eq!(
                git_stdout(&cache, &["rev-parse", "--is-shallow-repository"]),
                "true"
            );
            // The fresh clone is owned and updatable.
            update_cached_repo(&remote_at(&cache, &origin)).unwrap();
        });
        let _ = std::fs::remove_dir_all(root);
    }

    /// The whole-lock best-effort refresh the TUI runs at startup uses the same
    /// guarded update: a redirected cache entry is refused and the victim
    /// stays untouched; an owned entry is updated. Asserted directly after the
    /// call, so a no-op loop body cannot pass on the strength of later calls.
    #[test]
    fn refresh_remote_caches_refuses_a_redirected_entry_and_updates_an_owned_one() {
        let root = tmpdir("refresh-remote-caches");
        let home = root.join("home");
        let cache_root = home.join(".vstack").join("cache");
        let fx = redirected_cache_at(&root, &cache_root.join("owner_repo"));
        // An owned entry for `other/repo` with a newer origin.
        let origin = root.join("other-origin");
        init_git_repo(&origin);
        let owned = cache_root.join("other_repo");
        clone_into(&origin, &owned);
        std::fs::write(origin.join("README.md"), "newer\n").unwrap();
        git(&origin, &["commit", "-q", "-am", "update"]);
        // The origin check runs against the recorded source, so record the
        // sources these clones really came from.
        let mut lock = config::LockFile::default();
        lock.add(lock_entry("demo", &file_url(&root.join("origin"))));
        lock.add(lock_entry("scout", &file_url(&origin)));

        crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
            // Pin the fixture clones to the keys the recorded sources derive.
            let demo = RemoteSource::parse(&file_url(&root.join("origin")))
                .unwrap()
                .unwrap();
            let scout = RemoteSource::parse(&file_url(&origin)).unwrap().unwrap();
            std::fs::rename(&fx.remote.cache_dir, &demo.cache_dir).unwrap();
            std::fs::rename(&owned, &scout.cache_dir).unwrap();

            refresh_remote_caches(&lock);

            assert_eq!(
                victim_readme(&fx),
                "precious\n",
                "the redirected worktree must be untouched"
            );
            assert_eq!(
                std::fs::read_to_string(scout.cache_dir.join("README.md")).unwrap(),
                "newer\n",
                "the owned entry must be updated by refresh_remote_caches itself"
            );
        });
        let _ = std::fs::remove_dir_all(root);
    }

    /// A refused remote is a source that exists: no entry falls back to another
    /// loaded source, and no CWD or registry fallback stands in for it.
    #[test]
    fn refused_remote_source_is_never_substituted() {
        let root = tmpdir("refused-no-substitute");
        let home = root.join("home");
        let other_source = make_vstack_source(&root, "other");
        std::fs::create_dir_all(other_source.join("skills/demo")).unwrap();

        crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
            // Control: the test process runs inside a vstack checkout, so a
            // lock whose sole source resolves to nothing does fall back to it.
            let mut absent = config::LockFile::default();
            absent.add(lock_entry("demo", "/nowhere/at/all"));
            assert!(
                !resolve_source_records(&absent).sources.is_empty(),
                "control: the CWD fallback must be reachable for the refusal case to prove anything"
            );

            let cache = RemoteSource::parse("owner/repo")
                .unwrap()
                .unwrap()
                .cache_dir;
            let fx = redirected_cache_at(&root, &cache);

            let mut lock = config::LockFile::default();
            lock.add(lock_entry("demo", "owner/repo"));
            let records = resolve_source_records(&lock);
            assert!(records.sources.is_empty());
            assert!(
                records.refused["owner/repo"].contains("does not resolve to its cache entry"),
                "{:?}",
                records.refused
            );

            // With another source loaded, the refused entry does not rebind
            // to it.
            let sources = vec![RefreshSource::from_root(&other_source)];
            assert!(
                refresh_source_for_entry(&sources, &lock_entry("demo", "owner/repo")).is_none()
            );
            assert_eq!(victim_readme(&fx), "precious\n");
        });
        let _ = std::fs::remove_dir_all(root);
    }
}
