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

/// The sources a lock resolved to, and what resolution refused on the way.
pub(crate) struct SourceRecords {
    pub sources: Vec<ResolvedSource>,
    pub refused: SourceRefusals,
}

/// The recorded sources resolution refused, keyed by the recorded string so a
/// caller holding a lock entry can look its own reason up — and whether source
/// resolution ran at all. A caller that resolved its own source (the wizard)
/// hands in the default, so an entry that produced nothing there is never told
/// a clone is missing from a cache nothing looked in.
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
        return SourceRecords {
            sources,
            refused: SourceRefusals::attempted(refused),
        };
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

    SourceRecords {
        sources,
        refused: SourceRefusals::attempted(refused),
    }
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
    // then use the cached clone as it stands — nothing here writes to the
    // cache, so the pure attribution and hash paths are read-only.
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

/// What a remote source string names: the one URL git is given, and the one
/// cache entry its clone lives in. This is also where credential-bearing and
/// unsupported inputs are refused, before any git process sees them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RemoteSource {
    /// The source as recorded, safe to show: userinfo secrets, query and
    /// fragment replaced.
    pub display: String,
    /// The URL handed to git.
    pub git_url: String,
    /// The single path component under [`remote_cache_root`] the clone lives
    /// in. Derived from the repository identity, so two spellings of one repo
    /// share a clone and two repositories never do.
    pub cache_key: String,
    pub cache_dir: PathBuf,
}

impl RemoteSource {
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
        if parse_remote_url(source).is_some_and(|url| {
            url.authority
                .chars()
                .any(|ch| ch.is_whitespace() || ch.is_control())
        }) {
            bail!(
                "remote source URLs must not carry whitespace or control characters in their authority: {display}"
            );
        }
        let git_url = if url_shaped {
            if is_plaintext_http(source) {
                bail!("plaintext HTTP remote sources are not supported: {display}");
            }
            reject_unsupported_transport(source)?;
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
        Ok(Some(Self {
            cache_dir: remote_cache_root().join(&cache_key),
            display,
            git_url,
            cache_key,
        }))
    }
}

pub(crate) fn looks_like_remote_source(source: &str) -> bool {
    matches!(RemoteSource::parse(source), Ok(Some(_)) | Err(_))
}

pub(crate) fn remote_cache_root() -> PathBuf {
    config::global_base_dir().join(".vstack").join("cache")
}

/// `scheme://...` (any scheme, any case) or scp-like `user@host:path`.
fn is_url_shaped(source: &str) -> bool {
    parse_remote_url(source).is_some()
}

fn is_plaintext_http(source: &str) -> bool {
    parse_remote_url(source).is_some_and(|url| url.scheme.eq_ignore_ascii_case("http"))
}

/// The repository a URL names, independent of how it is spelled: a GitHub
/// slug for GitHub remotes in any form, otherwise `host/path` with scheme,
/// userinfo, port-less host case, `.git` and trailing slashes normalized.
fn remote_identity(git_url: &str) -> Option<String> {
    let Some(url) = parse_remote_url(git_url) else {
        // The bare `owner/repo` shorthand, which is the one shape that parser
        // does not describe.
        return config::parse_github_slug(git_url).map(|slug| format!("github.com/{slug}"));
    };
    let path = url.path.trim_matches('/');
    let path = path
        .strip_suffix(".git")
        .unwrap_or(path)
        .trim_end_matches('/');
    if path.is_empty() {
        return None;
    }
    let host = url.host.to_ascii_lowercase();
    // GitHub owner and repository names are case-insensitive. Deciding that
    // from the host this parser reports, rather than from a second parser's
    // case-SENSITIVE prefix match, is what keeps `git@GitHub.com:Owner/Repo`
    // in the same cache entry as every other spelling of it.
    if host == "github.com" {
        return Some(format!("github.com/{}", path.to_ascii_lowercase()));
    }
    Some(format!("{host}/{path}"))
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

/// Whether `remote`'s clone is on this machine.
///
/// A cache entry written by an earlier vstack under a different key is not
/// reused: the key derives from the repository identity now, and re-cloning is
/// one `vstack add` away. Every caller reports the absence with that command.
pub(crate) fn cache_entry_present(remote: &RemoteSource) -> bool {
    remote.cache_dir.join(".git").exists()
}

// ---------------------------------------------------------------------------
// Git invocations
//
// EVERY `git` process vstack runs is built by `hardened_git_command`: the cache
// commands here, the repository-identity reads in `path_safety`, the Pi
// package's HEAD read, the source-repository read in `config`, and `report`'s
// origin read. The update path runs `reset --hard`, and git will happily aim
// that at whatever an inherited `GIT_DIR`/`GIT_WORK_TREE`, a symlinked entry, a
// redirected `.git`, or the clone's own `core.worktree` names; the identity
// reads decide which repository an ownership boundary is judged against, and
// the same inherited variables answer for a different one. An inherited
// `GIT_CONFIG_*` names programs git RUNS (`core.fsmonitor`, `core.hooksPath`,
// `core.sshCommand`) for any of them. Every process here runs unattended, where
// a credential prompt is a hang. What differs between callers is how much of
// the environment is hostile: the cache is vstack's own repository, the project
// is the user's — see `GIT_CACHE_ONLY_ENV_VARS`.
// ---------------------------------------------------------------------------

/// Inherited git configuration no vstack command may run under, whichever
/// repository it asks about. The location variables each override the working
/// directory, so an inherited value — vstack invoked from a hook, or from a
/// shell that exported one — would answer for a repository that is not the one
/// being asked about. The `GIT_CONFIG_*` family injects arbitrary
/// configuration into the same command, including `core.fsmonitor`,
/// `core.hooksPath` and `core.sshCommand` — programs git runs, or hands vstack
/// back to re-export.
const GIT_INHERITED_ENV_VARS: &[&str] = &[
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_NAMESPACE",
    // Every way an environment hands git configuration to the process it
    // starts. `GIT_CONFIG_PARAMETERS` is the one git sets ITSELF for every
    // subprocess of a `git -c key=value` invocation, so it is present in
    // exactly the hook environment this scrubbing exists for — and an injected
    // `core.sshCommand` was read back by `configured_ssh_command` and
    // re-exported to the fetch.
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG",
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_SYSTEM",
    "GIT_CONFIG_NOSYSTEM",
    "GIT_CONFIG_COUNT",
    // Names the directory git runs its own helper programs from.
    "GIT_EXEC_PATH",
];

/// Cleared for the cache only. Where the repository is vstack's own clone an
/// inherited discovery limit is hostile; for the user's own project it is
/// configuration, and clearing it changed the answer the callers that anchor
/// against a project fail closed on.
const GIT_CACHE_ONLY_ENV_VARS: &[&str] =
    &["GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM"];

/// A `git` process pinned to `dir`: the working directory decides the
/// repository, every inherited location and configuration override is cleared,
/// and no terminal prompt can be raised. Reads about the user's own project are
/// built here; the cache adds [`hardened_cache_git_command`], and network
/// commands add ssh batch mode via [`hardened_git_network_command`].
pub(crate) fn hardened_git_command(dir: &Path) -> std::process::Command {
    let mut command = std::process::Command::new("git");
    for key in GIT_INHERITED_ENV_VARS {
        command.env_remove(key);
    }
    // The indexed pairs are read only up to `GIT_CONFIG_COUNT`, which is
    // cleared above; they are dropped as well so nothing depends on that.
    if let Some(count) = std::env::var("GIT_CONFIG_COUNT")
        .ok()
        .and_then(|count| count.trim().parse::<usize>().ok())
    {
        for index in 0..count.min(4096) {
            command.env_remove(format!("GIT_CONFIG_KEY_{index}"));
            command.env_remove(format!("GIT_CONFIG_VALUE_{index}"));
        }
    }
    command.env("GIT_TERMINAL_PROMPT", "0");
    command.current_dir(dir);
    command
}

/// [`hardened_git_command`] for a command about the cache, where vstack owns
/// the repository and every inherited answer about where one lives is hostile.
fn hardened_cache_git_command(dir: &Path) -> std::process::Command {
    let mut command = hardened_git_command(dir);
    for key in GIT_CACHE_ONLY_ENV_VARS {
        command.env_remove(key);
    }
    command
}

/// [`hardened_cache_git_command`] for a command that may open an ssh
/// connection. The ssh program git would choose is kept — `GIT_SSH_COMMAND`,
/// else `core.sshCommand` as configured for `dir` — and given its own
/// variant's noninteractive flag. A command carrying arguments of its own is
/// left exactly as the user wrote it; see [`batch_mode_ssh_command`].
fn hardened_git_network_command(dir: &Path) -> std::process::Command {
    let mut command = hardened_cache_git_command(dir);
    if let Some(ssh) = network_ssh_command(dir) {
        command.env("GIT_SSH_COMMAND", ssh);
    }
    command
}

/// The `GIT_SSH_COMMAND` [`hardened_git_network_command`] sets for `dir`, from
/// the inputs git itself would consult. Named so a test can assert the value
/// the command actually carries.
fn network_ssh_command(dir: &Path) -> Option<String> {
    batch_mode_ssh_command(
        std::env::var("GIT_SSH_COMMAND").ok().as_deref(),
        configured_ssh_command(dir).as_deref(),
        std::env::var("GIT_SSH").ok().as_deref(),
        std::env::var("GIT_SSH_VARIANT").ok().as_deref(),
        configured_git_value(dir, "ssh.variant").as_deref(),
    )
}

/// `core.sshCommand` as git resolves it for `dir` (repository, then global
/// and system config).
fn configured_ssh_command(dir: &Path) -> Option<String> {
    configured_git_value(dir, "core.sshCommand")
}

fn configured_git_value(dir: &Path, key: &str) -> Option<String> {
    let output = hardened_cache_git_command(dir)
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
        // Lowercased first: `PLINK.EXE` keeps its suffix through an
        // ASCII-exact strip and was detected as OpenSSH.
        let base = base.to_ascii_lowercase();
        let base = base.strip_suffix(".exe").unwrap_or(&base);
        match base {
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
/// untouched.
///
/// The option is APPENDED to the command git would run. Git appends
/// `<host> git-upload-pack <path>` after the whole string, so a trailing option
/// stays ahead of the positionals — which is what lets a command carrying
/// arguments of its own (`ssh -i key`, `env FOO=bar ssh`) be made
/// noninteractive at all: inserting after its first token corrupted it, and
/// leaving it alone lost batch mode for the commonest spelling there is.
/// `GIT_TERMINAL_PROMPT=0` does not reach ssh's own host-key prompt, so that
/// is a hang waiting for a tty.
///
/// Appending means an explicit `-o BatchMode=no` earlier in the user's own
/// command wins, OpenSSH taking the first value it sees. That is the user's
/// instruction, and it is theirs to give.
///
/// `None` — git's selection untouched — for the `simple` variant, which takes
/// no options at all; for a `GIT_SSH` program, invoked with host and command
/// arguments only; and for a plink-family command carrying arguments, where
/// where an option goes is the implementation's business.
fn batch_mode_ssh_command(
    inherited_command: Option<&str>,
    configured_command: Option<&str>,
    inherited_program: Option<&str>,
    inherited_variant: Option<&str>,
    configured_variant: Option<&str>,
) -> Option<String> {
    fn non_empty(value: Option<&str>) -> Option<&str> {
        value.map(str::trim).filter(|v| !v.is_empty())
    }
    let command = non_empty(inherited_command).or_else(|| non_empty(configured_command));
    if command.is_none() && non_empty(inherited_program).is_some() {
        return None;
    }
    let command = command.unwrap_or("ssh");
    let (program, arguments) = split_program_token(command);
    // `GIT_SSH_VARIANT` outranks `ssh.variant`, as it does in git.
    let variant = non_empty(inherited_variant)
        .and_then(SshVariant::named)
        .or_else(|| non_empty(configured_variant).and_then(SshVariant::named))
        .unwrap_or_else(|| SshVariant::detect(program));
    match variant {
        SshVariant::OpenSsh => Some(format!("{command} {}", variant.batch_flag()?)),
        SshVariant::Plink | SshVariant::TortoisePlink if arguments.trim().is_empty() => {
            Some(format!("{command} {}", variant.batch_flag()?))
        }
        _ => None,
    }
}

/// A command string split into its program token and the rest. A quoted token
/// is one token however much whitespace it contains.
fn split_program_token(command: &str) -> (&str, &str) {
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
    // a symlinked home or temp directory. Anything git cannot answer fails
    // closed, naming which of the three ways it failed.
    let toplevel = hardened_cache_git_command(&remote.cache_dir)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .map_err(|err| refusal(remote, &format!("git could not be run to read it: {err}")))?;
    if !toplevel.status.success() {
        return Err(refusal(
            remote,
            &format!(
                "its work tree could not be read: {}",
                git_output_summary(&toplevel)
            ),
        ));
    }
    // The work tree is the user location this refuses to touch; it is not
    // printed, here or below.
    let resolved = PathBuf::from(git_stdout_line(&toplevel.stdout))
        .canonicalize()
        .map_err(|err| refusal(remote, &format!("its work tree does not resolve: {err}")))?;
    let expected = std::fs::canonicalize(&remote.cache_dir)
        .map_err(|err| refusal(remote, &err.to_string()))?;
    if resolved != expected {
        return Err(refusal(
            remote,
            "its git work tree does not resolve to its cache entry, and updating it would run destructive git commands outside the cache",
        ));
    }

    let output = hardened_cache_git_command(&remote.cache_dir)
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
    // An entry minted before the transport policy — or by anything else — can
    // hold an origin vstack would refuse as a source. Fetching it would pull
    // this source's content over that transport anyway.
    if let Err(err) = reject_unsupported_transport(&origin) {
        return Err(refusal(remote, &format!("its origin is unusable ({err})")));
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
    let reset = hardened_cache_git_command(&remote.cache_dir)
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
    // `rfind` reports where the character starts; the URL ends where it ends,
    // which is one byte later only for single-byte characters.
    let end = rest
        .char_indices()
        .rev()
        .find(|(_, ch)| !matches!(ch, '\'' | '"' | '.' | ',' | ';' | ':' | ')' | ']'))
        .map(|(index, ch)| index + ch.len_utf8())
        .unwrap_or(rest.len());
    let (url, suffix) = rest.split_at(end);
    format!("{prefix}{}{suffix}", remote_source_display(url))
}

// ---------------------------------------------------------------------------
// Remote URL hygiene
// ---------------------------------------------------------------------------

/// A source as it may appear in diagnostics: shorthand as-is, URLs with any
/// userinfo secret and any query/fragment replaced, and every control or
/// direction-changing character escaped — a lock file records source strings
/// verbatim, and a refusal that echoed one would put its terminal escapes on
/// vstack's own stderr.
pub(crate) fn remote_source_display(source: &str) -> String {
    escape_unprintable(&redact_stray_userinfo(&redact_remote_query(
        &redact_remote_userinfo(source),
    )))
}

/// Redact anything shaped like `user:secret@` wherever it sits, after the
/// authority has had its own pass.
///
/// A malformed URL puts a credential where the authority redaction cannot see
/// it — `https:///user:token@host/repo` parses with an EMPTY authority, so the
/// secret is path text and was echoed verbatim. Redaction has to be
/// conservative about a shape it could not parse, including for a URL that is
/// about to be refused: the refusal prints it.
fn redact_stray_userinfo(text: &str) -> String {
    text.split_inclusive('/')
        .map(|segment| {
            let Some(at) = segment.rfind('@') else {
                return segment.to_string();
            };
            let (userinfo, host) = segment.split_at(at);
            match userinfo.split_once(':') {
                // A bare `user@host` is how ssh remotes are spelled.
                None => segment.to_string(),
                Some((username, _)) => format!("{username}:<redacted>{host}"),
            }
        })
        .collect()
}

/// Escape what a terminal would act on rather than print.
pub(crate) fn escape_unprintable(text: &str) -> String {
    fn is_unprintable(ch: char) -> bool {
        ch.is_control()
            || matches!(ch,
                '\u{200b}'..='\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{feff}')
    }
    if !text.chars().any(is_unprintable) {
        return text.to_string();
    }
    text.chars()
        .map(|ch| {
            if is_unprintable(ch) {
                format!("\\u{{{:x}}}", ch as u32)
            } else {
                ch.to_string()
            }
        })
        .collect()
}

/// The transports vstack hands to git. Anything else — `git://`, which is
/// unauthenticated and unencrypted, and any unknown scheme, which makes git run
/// a `git-remote-<scheme>` helper — is refused before a process sees it. `file`
/// is here because a local clone is how a source is exercised offline.
const SUPPORTED_TRANSPORTS: &[&str] = &["https", "ssh", "git+ssh", "file"];

/// Refuse a URL whose transport vstack does not hand to git, and one that names
/// no host to reach over a network transport.
///
/// The hostless form is not merely malformed: `https:///user:token@host/repo`
/// parses with an empty authority, so its credential sits in the path where
/// neither the credential refusal nor the authority redaction could see it, and
/// git was handed the token as-is.
pub(crate) fn reject_unsupported_transport(url: &str) -> Result<()> {
    let Some(parsed) = parse_remote_url(url) else {
        return Ok(());
    };
    let display = remote_source_display(url);
    // `file://` is the one spelling that legitimately names no host.
    if parsed.host.is_empty() && !parsed.scheme.eq_ignore_ascii_case("file") {
        bail!("remote source URL names no host: {display}");
    }
    // The scp-like spelling carries no scheme and is ssh by definition.
    if parsed.scp_like() {
        return Ok(());
    }
    if !SUPPORTED_TRANSPORTS
        .iter()
        .any(|transport| parsed.scheme.eq_ignore_ascii_case(transport))
    {
        bail!(
            "remote source transport `{}` is not supported: {display}. Use https, ssh or git+ssh",
            escape_unprintable(parsed.scheme)
        );
    }
    Ok(())
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
    let Some(parts) = parse_remote_url(url) else {
        return Ok(());
    };
    if parts.userinfo.is_empty() {
        return Ok(());
    }
    if !parts.allows_bare_username() || parts.userinfo.contains(':') {
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

/// One parse of the remote-URL grammar, for every question asked about a
/// source: is it a URL at all, what is its authority, does it carry a
/// credential, how is it displayed, and which repository does it name. Four
/// hand-rolled splitters used to answer those separately and disagreed on
/// where userinfo ends — the scp-like `user:secret@host:path` had no authority
/// by one of them, so its secret was neither refused nor redacted.
struct RemoteUrl<'a> {
    /// Empty for the scp-like spelling, which carries no scheme.
    scheme: &'a str,
    /// `[userinfo@]host` — never the path, and never a port-less prefix of it.
    authority: &'a str,
    /// Everything before the authority's last `@`; empty when it has none.
    userinfo: &'a str,
    host: &'a str,
    /// The repository path, without the `/` or scp `:` that introduces it.
    path: &'a str,
    /// The input up to where the authority starts, and from where it ends —
    /// enough to rebuild the input with a redacted userinfo.
    prefix: &'a str,
    suffix: &'a str,
}

impl RemoteUrl<'_> {
    /// The `[user@]host:path` spelling, which carries no scheme and is ssh.
    fn scp_like(&self) -> bool {
        self.scheme.is_empty()
    }

    /// Whether a bare `user@` is how this spelling names a remote rather than
    /// a credential. Both ssh spellings carry a username; nothing else does.
    fn allows_bare_username(&self) -> bool {
        self.scp_like()
            || self.scheme.eq_ignore_ascii_case("ssh")
            || self.scheme.eq_ignore_ascii_case("git+ssh")
    }
}

fn parse_remote_url(input: &str) -> Option<RemoteUrl<'_>> {
    if let Some(scheme_end) = input.find("://") {
        let scheme = &input[..scheme_end];
        if scheme.is_empty()
            || !scheme
                .chars()
                .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '+' | '-' | '.'))
        {
            return None;
        }
        let authority_start = scheme_end + 3;
        // The authority runs to the first `/` and nothing else: stopping at
        // whitespace made a malformed `user:tok en@host` URL parse as having
        // no userinfo at all, so its secret was printed in full.
        let authority_end = input[authority_start..]
            .find('/')
            .map(|index| authority_start + index)
            .unwrap_or(input.len());
        let authority = &input[authority_start..authority_end];
        let (userinfo, host) = split_authority(authority);
        let suffix = &input[authority_end..];
        return Some(RemoteUrl {
            scheme,
            authority,
            userinfo,
            host,
            path: suffix.strip_prefix('/').unwrap_or(""),
            prefix: &input[..authority_start],
            suffix,
        });
    }
    // scp-like `[user@]host:path` — an `@` and a `:` before the first `/`.
    let head_end = input.find('/').unwrap_or(input.len());
    let head = &input[..head_end];
    if !head.contains('@') || !head.contains(':') {
        return None;
    }
    // Everything before the LAST `@` is userinfo here too: reading the first
    // `:` as the host separator instead put a `user:secret@host` credential
    // beyond every check.
    let at = head.rfind('@')?;
    let authority_end = input[at + 1..]
        .find(':')
        .map(|index| at + 1 + index)
        .unwrap_or(head_end);
    let authority = &input[..authority_end];
    let (userinfo, host) = split_authority(authority);
    let suffix = &input[authority_end..];
    Some(RemoteUrl {
        scheme: "",
        authority,
        userinfo,
        host,
        path: suffix.strip_prefix(':').unwrap_or(""),
        prefix: "",
        suffix,
    })
}

fn split_authority(authority: &str) -> (&str, &str) {
    match authority.rfind('@') {
        Some(at) => (&authority[..at], &authority[at + 1..]),
        None => ("", authority),
    }
}

/// Redact the secret part of a URL's userinfo, keeping a legitimate username.
pub(crate) fn redact_remote_userinfo(input: &str) -> String {
    let Some(parts) = parse_remote_url(input) else {
        return input.to_string();
    };
    if parts.userinfo.is_empty() {
        return input.to_string();
    }
    let redacted_userinfo = if let Some((username, _)) = parts.userinfo.split_once(':') {
        if username.is_empty() {
            "<redacted>".to_string()
        } else {
            format!("{username}:<redacted>")
        }
    } else if parts.allows_bare_username() {
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
            resolve_single_source_with(&source.to_string_lossy(), true, true),
            SourceResolution::Resolved(source.clone())
        );
        assert_eq!(
            resolve_single_source_with(&root.to_string_lossy(), true, true),
            SourceResolution::Absent
        );

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
        assert_eq!(
            resolve_single_source_with(&alternate.to_string_lossy(), true, true),
            SourceResolution::Absent
        );

        assert_eq!(
            resolve_recorded_source_resolution(&alternate.to_string_lossy()),
            SourceResolution::Resolved(alternate.clone())
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
                resolve_recorded_source_resolution("./vendor/vstack"),
                SourceResolution::Resolved(std::fs::canonicalize(&relative_source).unwrap())
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
            resolve_recorded_source_resolution("../vstack")
        });

        assert_eq!(
            resolved,
            SourceResolution::Resolved(std::fs::canonicalize(&worktree_neighbor).unwrap()),
            "copied relative lock sources are resolved from the current worktree root"
        );
        assert_ne!(
            resolved,
            SourceResolution::Resolved(std::fs::canonicalize(&main_checkout_neighbor).unwrap()),
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
            assert_ne!(
                resolve_recorded_source_resolution("owner/repo"),
                SourceResolution::Resolved(shadow.clone())
            );
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
        for key in GIT_INHERITED_ENV_VARS.iter().chain(GIT_CACHE_ONLY_ENV_VARS) {
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
        for key in GIT_INHERITED_ENV_VARS.iter().chain(GIT_CACHE_ONLY_ENV_VARS) {
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
        // The fixture label shares no token with any asserted string: the
        // refusal ends with the cache root path, so a label containing one
        // would satisfy the assertions whichever refusal fired.
        let root = tmpdir("borrowed-worktree");
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
            assert!(err.contains("its cache entry is a symlink"), "{err}");
            let err = update_cached_repo(&remote).unwrap_err().to_string();
            assert!(err.contains("its cache entry is a symlink"), "{err}");
            // Neither the read-only nor the updating resolution returns the
            // linked checkout as the remote source, and both report the
            // refusal rather than an absent source.
            for resolution in [
                resolve_single_source_with("owner/repo", false, false),
                resolve_single_source_with("owner/repo", true, true),
            ] {
                assert!(
                    matches!(&resolution, SourceResolution::Refused(reason) if reason.contains("its cache entry is a symlink")),
                    "{resolution:?}"
                );
            }
            assert_eq!(resolve_source_path("owner/repo"), None);
            assert!(recorded_source_exists("owner/repo"));
        });
        assert_eq!(
            std::fs::read_to_string(checkout.join("README.md")).unwrap(),
            "precious\n"
        );
        assert!(checkout.join("uncommitted.txt").exists());
        let _ = std::fs::remove_dir_all(root);
    }

    /// A cache entry that is not a directory at all. The callers all gate on
    /// `.git` being present, which a plain file cannot satisfy, so this pins
    /// the check's own contract: without it the entry falls through to the
    /// git-metadata read and answers with an `inspecting` context error.
    #[test]
    fn a_cache_entry_that_is_not_a_directory_is_refused() {
        let root = tmpdir("plain-file");
        let home = root.join("home");
        crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
            let remote = RemoteSource::parse("owner/repo").unwrap().unwrap();
            std::fs::create_dir_all(remote.cache_dir.parent().unwrap()).unwrap();
            std::fs::write(&remote.cache_dir, "not a clone\n").unwrap();

            for err in [
                reject_unowned_cache_entry(&remote),
                ensure_cache_entry_is_owned(&remote),
                update_cached_repo(&remote),
            ] {
                let err = format!("{:#}", err.unwrap_err());
                assert!(err.contains("its cache entry is not a directory"), "{err}");
            }
        });
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
    fn every_git_invocation_is_non_interactive_and_drops_inherited_git_config() {
        let root = tmpdir("git-env");
        let home = root.join("home");
        crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
            git_env_assertions(&root)
        });
        let _ = std::fs::remove_dir_all(root);
    }

    fn git_env_assertions(root: &Path) {
        let dir = remote_cache_root().join("owner_repo");
        init_git_repo(&dir);
        let project = command_env(&hardened_git_command(&dir));
        // Control: a bare `git` carries none of it, so the assertions below
        // are claims about the hardening and not about two empty maps.
        assert_ne!(command_env(&std::process::Command::new("git")), project);

        for key in GIT_INHERITED_ENV_VARS {
            assert_eq!(
                project.get(*key),
                Some(&None),
                "{key} is not cleared: {project:?}"
            );
        }
        assert_eq!(
            project
                .get("GIT_TERMINAL_PROMPT")
                .cloned()
                .flatten()
                .as_deref(),
            Some("0")
        );
        // The user's own project keeps its discovery configuration: clearing
        // it changed the answer the callers that anchor against a project
        // fail closed on.
        for key in GIT_CACHE_ONLY_ENV_VARS {
            assert_eq!(project.get(*key), None, "{key} is cleared for a project");
        }

        let cache = command_env(&hardened_cache_git_command(&dir));
        for key in GIT_INHERITED_ENV_VARS.iter().chain(GIT_CACHE_ONLY_ENV_VARS) {
            assert_eq!(
                cache.get(*key),
                Some(&None),
                "{key} is not cleared for the cache: {cache:?}"
            );
        }

        // The network path is the cache path plus exactly one variable, whose
        // value is asserted against the same inputs the constructor reads.
        git(&dir, &["config", "core.sshCommand", "/opt/vstack-test-ssh"]);
        // A variant the fixture would not get by detection, so dropping that
        // input from the constructor changes the value asserted below.
        git(&dir, &["config", "ssh.variant", "plink"]);
        let network = command_env(&hardened_git_network_command(&dir));
        for (key, value) in &cache {
            assert_eq!(
                network.get(key),
                Some(value),
                "{key} differs on the network path"
            );
        }
        for (key, value) in &network {
            if key != "GIT_SSH_COMMAND" {
                assert_eq!(cache.get(key), Some(value), "{key} differs");
            }
        }
        // What the value should BE for given inputs is asserted against
        // literals in `the_network_command_carries_the_ssh_command_git_would_have_used`;
        // what this asserts is that the command carries it at all.
        let expected = network_ssh_command(&dir);
        // Control: with a single-token `core.sshCommand` configured there IS a
        // value to carry, so the equality below cannot pass by both sides
        // being `None`. A runner exporting its own multi-token
        // `GIT_SSH_COMMAND` (which is left untouched by design) outranks the
        // fixture, and only there is `None` a legitimate answer.
        if std::env::var_os("GIT_SSH_COMMAND").is_none()
            && std::env::var_os("GIT_SSH_VARIANT").is_none()
        {
            assert!(
                expected.is_some(),
                "the fixture must produce an ssh command for this assertion to bite"
            );
        }
        assert_eq!(
            network.get("GIT_SSH_COMMAND").cloned().flatten(),
            expected,
            "the network command must carry the ssh command built from git's own inputs"
        );

        // Cloning is as unattended as fetching and must be built by the same
        // constructor — for the cache root, which is where it runs.
        let remote = remote_at(&dir, &root.join("origin"));
        assert_eq!(
            command_env(&cache_clone_command(&remote)),
            command_env(&hardened_git_network_command(&remote_cache_root()))
        );
    }

    const CONFIG_INJECTION_HELPER: &str = "refresh_sources::tests::inherited_git_config_helper";
    const SSH_WIRING_HELPER: &str = "refresh_sources::tests::network_ssh_command_helper";

    /// Every way an environment hands git configuration to the process it
    /// starts is a way to name a program git will RUN — `core.sshCommand` most
    /// directly, since vstack reads it back and re-exports it to the fetch.
    /// The list of scrubbed variables cannot be checked by iterating itself, so
    /// each vector is set in a child process and the resulting git answer is
    /// what is asserted.
    #[test]
    fn no_inherited_git_configuration_reaches_the_commands_vstack_runs() {
        let root = tmpdir("inherited-git-config");
        let dir = root.join("work");
        std::fs::create_dir_all(&dir).unwrap();
        let injected = root.join("evil-ssh");
        let config_file = root.join("injected.gitconfig");
        std::fs::write(
            &config_file,
            format!("[core]\n\tsshCommand = {}\n", injected.display()),
        )
        .unwrap();

        let parameters = format!("'core.sshCommand={}'", injected.display());
        let vectors: Vec<Vec<(&str, &std::ffi::OsStr)>> = vec![
            // The one git sets itself for every subprocess of `git -c ...`.
            vec![(
                "GIT_CONFIG_PARAMETERS",
                std::ffi::OsStr::new(parameters.as_str()),
            )],
            vec![("GIT_CONFIG", config_file.as_os_str())],
            vec![("GIT_CONFIG_GLOBAL", config_file.as_os_str())],
            vec![
                ("GIT_CONFIG_COUNT", std::ffi::OsStr::new("1")),
                ("GIT_CONFIG_KEY_0", std::ffi::OsStr::new("core.sshCommand")),
                ("GIT_CONFIG_VALUE_0", injected.as_os_str()),
            ],
        ];
        for vector in vectors {
            let mut env = vector;
            env.push(("VSTACK_TEST_INJECTED_SSH", injected.as_os_str()));
            env.push(("VSTACK_TEST_WORK_DIR", dir.as_os_str()));
            crate::test_util::run_test_helper(CONFIG_INJECTION_HELPER, &env, None);
        }
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    #[ignore = "driven by no_inherited_git_configuration_reaches_the_commands_vstack_runs, which sets one injection vector per run"]
    fn inherited_git_config_helper() {
        let (Some(injected), Some(dir)) = (
            std::env::var("VSTACK_TEST_INJECTED_SSH").ok(),
            std::env::var_os("VSTACK_TEST_WORK_DIR"),
        ) else {
            return;
        };
        let dir = PathBuf::from(dir);

        // Control: an unhardened `git config --get` in this environment DOES
        // return the injected program, so the assertions below are about the
        // scrubbing and not about a vector that never worked.
        let unhardened = std::process::Command::new("git")
            .args(["config", "--get", "core.sshCommand"])
            .current_dir(&dir)
            .output()
            .unwrap();
        assert_eq!(
            git_stdout_line(&unhardened.stdout),
            injected,
            "the injection vector must reach an unhardened git for this to prove anything"
        );

        assert_ne!(
            configured_ssh_command(&dir).as_deref(),
            Some(injected.as_str()),
            "the injected core.sshCommand was read back"
        );
        let network = network_ssh_command(&dir).unwrap_or_default();
        assert!(
            !network.contains(&injected),
            "the injected core.sshCommand was re-exported to the fetch: {network}"
        );

        // Scrubbing must leave a WORKING git: dropping the indexed pairs while
        // leaving `GIT_CONFIG_COUNT` set makes every command exit
        // "missing config key", which is not an answer either.
        let probe = hardened_git_command(&dir)
            .args(["config", "--get", "core.noSuchKeyHere"])
            .output()
            .unwrap();
        assert_eq!(
            probe.status.code(),
            Some(1),
            "the hardened command is not a usable git: {}",
            git_output_summary(&probe)
        );
    }

    /// The three environment inputs of [`network_ssh_command`] are only proven
    /// against literals: an expectation recomputed from the same reads compares
    /// a value with itself, and dropping any one read is a real regression —
    /// losing the `GIT_SSH_COMMAND` read overwrites the user's own wrapper.
    #[test]
    fn the_network_command_carries_the_ssh_command_git_would_have_used() {
        let root = tmpdir("network-ssh-wiring");
        std::fs::create_dir_all(&root).unwrap();
        for (env, expected) in [
            (
                vec![("GIT_SSH_COMMAND", "/opt/user-ssh -i /keys/id")],
                "/opt/user-ssh -i /keys/id -o BatchMode=yes",
            ),
            // A `GIT_SSH` program is invoked with host and command arguments
            // only, so git's own selection is left alone.
            (vec![("GIT_SSH", "/opt/user-ssh")], "none"),
            (
                vec![("GIT_SSH_COMMAND", "ssh"), ("GIT_SSH_VARIANT", "plink")],
                "ssh -batch",
            ),
            (
                vec![("GIT_SSH_COMMAND", "ssh"), ("GIT_SSH_VARIANT", "simple")],
                "none",
            ),
        ] {
            let mut env: Vec<(&str, &std::ffi::OsStr)> = env
                .iter()
                .map(|(key, value)| (*key, std::ffi::OsStr::new(*value)))
                .collect();
            env.push(("VSTACK_TEST_EXPECTED_SSH", std::ffi::OsStr::new(expected)));
            env.push(("VSTACK_TEST_WORK_DIR", root.as_os_str()));
            crate::test_util::run_test_helper(SSH_WIRING_HELPER, &env, None);
        }
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    #[ignore = "driven by the_network_command_carries_the_ssh_command_git_would_have_used, which sets one input combination per run"]
    fn network_ssh_command_helper() {
        let (Some(expected), Some(dir)) = (
            std::env::var("VSTACK_TEST_EXPECTED_SSH").ok(),
            std::env::var_os("VSTACK_TEST_WORK_DIR"),
        ) else {
            return;
        };
        let dir = PathBuf::from(dir);
        let expected = (expected != "none").then_some(expected);
        assert_eq!(network_ssh_command(&dir), expected);
        // And the value the command actually carries is that same one.
        let network = command_env(&hardened_git_network_command(&dir));
        assert_eq!(network.get("GIT_SSH_COMMAND").cloned().flatten(), expected);
    }

    #[test]
    fn batch_mode_ssh_command_follows_git_precedence() {
        // Nothing configured.
        assert_eq!(
            batch_mode_ssh_command(None, None, None, None, None).as_deref(),
            Some("ssh -o BatchMode=yes")
        );
        assert_eq!(
            batch_mode_ssh_command(Some("   "), None, None, None, None).as_deref(),
            Some("ssh -o BatchMode=yes")
        );
        // GIT_SSH_COMMAND outranks core.sshCommand.
        assert_eq!(
            batch_mode_ssh_command(Some("ssh"), Some("/opt/ssh"), Some("/x"), None, None)
                .as_deref(),
            Some("ssh -o BatchMode=yes")
        );
        assert_eq!(
            batch_mode_ssh_command(None, Some("/opt/ssh"), Some("/x"), None, None).as_deref(),
            Some("/opt/ssh -o BatchMode=yes")
        );
        // A quoted program token is one token, whitespace and all.
        assert_eq!(
            batch_mode_ssh_command(Some("'/my ssh'"), None, None, None, None).as_deref(),
            Some("'/my ssh' -o BatchMode=yes")
        );
        // GIT_SSH_VARIANT outranks ssh.variant, as it does in git.
        assert_eq!(
            batch_mode_ssh_command(Some("/opt/ssh"), None, None, Some("plink"), Some("ssh"))
                .as_deref(),
            Some("/opt/ssh -batch")
        );
        assert_eq!(
            batch_mode_ssh_command(
                Some("plink"),
                None,
                None,
                Some("ssh"),
                Some("tortoiseplink")
            )
            .as_deref(),
            Some("plink -o BatchMode=yes")
        );
        // An unknown or `auto` GIT_SSH_VARIANT falls through to ssh.variant,
        // and then to detection — again as in git.
        assert_eq!(
            batch_mode_ssh_command(Some("/opt/ssh"), None, None, Some("auto"), Some("plink"))
                .as_deref(),
            Some("/opt/ssh -batch")
        );
        assert_eq!(
            batch_mode_ssh_command(Some("plink"), None, None, Some("auto"), None).as_deref(),
            Some("plink -batch")
        );
    }

    /// A `GIT_SSH_COMMAND` git runs through a shell may be anything —
    /// `env FOO=bar ssh`, a wrapper with its own arguments — and inserting an
    /// option after its first token corrupts it. Appending keeps the command
    /// intact AND noninteractive: git puts the host and upload-pack arguments
    /// after the whole string, so a trailing option is still an option.
    #[test]
    fn a_command_carrying_arguments_is_made_noninteractive_without_being_rewritten() {
        for command in [
            "ssh -i /keys/a",
            "env FOO=bar ssh",
            "'/my ssh' -v",
            "ssh -o StrictHostKeyChecking=accept-new -i k",
        ] {
            let expected = format!("{command} -o BatchMode=yes");
            assert_eq!(
                batch_mode_ssh_command(Some(command), None, None, None, None).as_deref(),
                Some(expected.as_str()),
                "{command}"
            );
            assert_eq!(
                batch_mode_ssh_command(None, Some(command), None, None, None).as_deref(),
                Some(expected.as_str()),
                "{command}"
            );
        }
        // The user's own explicit choice stands: OpenSSH takes the first value
        // it sees, and ours comes after theirs.
        assert_eq!(
            batch_mode_ssh_command(Some("ssh -o BatchMode=no -i k"), None, None, None, None)
                .as_deref(),
            Some("ssh -o BatchMode=no -i k -o BatchMode=yes")
        );
        // Where an option goes is the plink family's business, so a plink
        // command carrying arguments is left exactly as it is.
        for command in ["plink -i key", "/usr/bin/tortoiseplink -P 22"] {
            assert_eq!(
                batch_mode_ssh_command(Some(command), None, None, None, None),
                None,
                "{command}"
            );
        }
        assert_eq!(
            batch_mode_ssh_command(Some("/opt/myssh -v"), None, None, None, Some("plink")),
            None
        );
    }

    /// `-o BatchMode=yes` is OpenSSH's spelling and nobody else's. Git drives
    /// four ssh implementations; handing the wrong one OpenSSH's option — or
    /// rewriting a `GIT_SSH` program into a command line at all — breaks the
    /// connection instead of making it noninteractive.
    #[test]
    fn batch_mode_matches_the_ssh_variant_git_would_use() {
        // Auto-detected by program basename, as git detects it — case and
        // `.exe` suffix included.
        for program in [
            "plink",
            "/usr/bin/plink",
            "PuTTY.exe",
            "PLINK.EXE",
            "C:\\tools\\TortoisePlink.exe",
        ] {
            assert_eq!(
                batch_mode_ssh_command(Some(program), None, None, None, None).as_deref(),
                Some(format!("{program} -batch").as_str()),
                "{program}"
            );
        }
        // A quoted program token is unquoted before its basename decides:
        // `'/usr/bin/plink'` ends in `plink'`, which detects as OpenSSH and
        // takes an option plink rejects.
        for program in ["'/usr/bin/plink'", "\"/usr/bin/plink\""] {
            assert_eq!(
                batch_mode_ssh_command(Some(program), None, None, None, None).as_deref(),
                Some(format!("{program} -batch").as_str()),
                "{program}"
            );
        }
        // An explicit ssh.variant outranks detection in both directions, in
        // every spelling git accepts for it.
        for variant in ["tortoiseplink", "plink", "putty"] {
            assert_eq!(
                batch_mode_ssh_command(Some("/opt/myssh"), None, None, None, Some(variant))
                    .as_deref(),
                Some("/opt/myssh -batch"),
                "{variant}"
            );
        }
        assert_eq!(
            batch_mode_ssh_command(Some("plink"), None, None, None, Some("ssh")).as_deref(),
            Some("plink -o BatchMode=yes")
        );
        // `auto` and unknown values fall through to detection, as in git.
        for variant in ["auto", "nonsense"] {
            assert_eq!(
                batch_mode_ssh_command(Some("plink"), None, None, None, Some(variant)).as_deref(),
                Some("plink -batch"),
                "{variant}"
            );
        }
        // `simple` accepts no options at all, and a GIT_SSH program is invoked
        // with host and command arguments only: both are left exactly as git
        // has them.
        assert_eq!(
            batch_mode_ssh_command(Some("/opt/simple-ssh"), None, None, None, Some("simple")),
            None
        );
        assert_eq!(
            batch_mode_ssh_command(None, None, Some("/path with space/ssh"), None, None),
            None
        );
        assert_eq!(
            batch_mode_ssh_command(None, None, Some("/x"), None, Some("ssh")),
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

            // Every spelling of the same GitHub repo shares the clone —
            // including a mixed-case HOST, which a case-sensitive prefix match
            // read as some other forge and gave a second clone of its own.
            for spelling in [
                "https://github.com/owner/repo.git",
                "https://github.com/Owner/Repo",
                "https://GitHub.com/Owner/Repo.git",
                "git@github.com:owner/repo.git",
                "git@GitHub.com:Owner/Repo.git",
                "ssh://git@github.com/owner/repo.git",
                "ssh://git@GitHub.COM/Owner/Repo.git",
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

    /// A remote-shaped source that git must not be handed is refused at parse,
    /// before any process sees it — and stays a source, so no entry of its own
    /// is quietly reinstalled from somewhere else.
    #[test]
    fn remote_sources_git_must_not_be_handed_are_refused_at_parse() {
        // The secret each case carries, where it carries one — bound per case
        // so the leak assertion cannot pass on a string that never held it.
        for (source, secret) in [
            // git reads a leading `-` as an option, not a repository.
            ("--upload-pack=evil@host:repo.git", None),
            // A malformed authority stops userinfo parsing, and the secret
            // then reaches git and every diagnostic unredacted.
            (
                "https://user:to ken@github.com/owner/repo.git",
                Some("to ken"),
            ),
            (
                "https://user:to\tken@github.com/owner/repo.git",
                Some("to\tken"),
            ),
        ] {
            let err = RemoteSource::parse(source).unwrap_err().to_string();
            if let Some(secret) = secret {
                assert!(source.contains(secret), "{source}: fixture");
                assert!(!err.contains(secret), "{source}: {err}");
                assert!(!err.contains("ken"), "{source}: {err}");
                // The whole authority is redacted for display even when it is
                // malformed, so no diagnostic can carry the secret.
                assert!(!remote_source_display(source).contains("ken"), "{source}");
            }
            assert!(looks_like_remote_source(source), "{source}");
            assert!(recorded_source_exists(source), "{source}");
        }
        // A bare local source starting with `-` is not remote-shaped at all:
        // the shape gate runs before the leading-dash refusal, so such a
        // directory is never reported as a refused remote.
        assert_eq!(RemoteSource::parse("-my-source-dir").unwrap(), None);
        assert!(!looks_like_remote_source("-my-source-dir"));
        assert!(!recorded_source_exists("-my-source-dir"));
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

    /// The scp-like spelling is the same grammar with different punctuation,
    /// and it used to be parsed by different code: a `user:secret@host:path`
    /// source had no authority by one splitter and no userinfo by another, so
    /// its secret was neither refused nor redacted and became a cache
    /// directory name.
    #[test]
    fn scp_like_sources_are_refused_and_redacted_like_any_other_url() {
        for source in [
            "user:ghp_SECRET@github.com:owner/repo.git",
            "u:ghp_SECRET@host:owner/repo.git",
            "git:ghp_SECRET@github.com:owner/repo.git",
        ] {
            let err = RemoteSource::parse(source).unwrap_err().to_string();
            assert!(!err.contains("ghp_SECRET"), "{source}: {err}");
            assert!(err.contains("<redacted>"), "{source}: {err}");
            assert!(
                !remote_source_display(source).contains("ghp_SECRET"),
                "{source}"
            );
            assert!(looks_like_remote_source(source), "{source}");
        }
        // Whitespace and control characters inside the userinfo are caught by
        // the authority guard, which used to inspect an empty string here.
        let err = RemoteSource::parse("u:tok\nen@host:owner/repo.git")
            .unwrap_err()
            .to_string();
        assert!(!err.contains("tok"), "{err}");
        // A credential-free whitespace source: the credential check cannot
        // stand in for the authority guard, so this is what proves it fires.
        let err = RemoteSource::parse("https://git hub.com/owner/repo.git")
            .unwrap_err()
            .to_string();
        assert!(err.contains("whitespace or control characters"), "{err}");
        // And a control character that is NOT whitespace, which every other
        // input here is: `\t` and `\n` are both, so they prove only half the
        // guard.
        for control in ['\u{1}', '\u{7f}'] {
            let source = format!("https://git{control}hub.com/owner/repo.git");
            let err = RemoteSource::parse(&source).unwrap_err().to_string();
            assert!(
                err.contains("whitespace or control characters"),
                "{control:?}: {err}"
            );
            assert!(!err.contains(control), "{control:?}: {err}");
        }
        // The ssh username every scp remote carries is still kept.
        let remote = RemoteSource::parse("git@github.com:Owner/Repo.git")
            .unwrap()
            .unwrap();
        assert_eq!(remote.display, "git@github.com:Owner/Repo.git");
    }

    /// A lock file records source strings verbatim, so a refusal or warning
    /// that echoed one would put its terminal escapes on vstack's own stderr
    /// with no cache entry and no network involved.
    #[test]
    fn control_characters_never_reach_a_diagnostic() {
        let escaped = remote_source_display("git@github.com:owner/re\u{1b}[31mpo.git");
        assert!(!escaped.contains('\u{1b}'), "{escaped}");
        assert!(escaped.contains("\\u{1b}"), "{escaped}");
        let err = RemoteSource::parse("-\u{1b}[31m@github.com:owner/repo.git")
            .unwrap_err()
            .to_string();
        assert!(!err.contains('\u{1b}'), "{err}");
        // A direction override reads as part of the surrounding line, so it is
        // escaped too.
        assert!(!remote_source_display("owner/re\u{202e}po").contains('\u{202e}'));
    }

    /// A URL git must not be handed is refused before a process sees it, and
    /// the refusal cannot be the place the credential appears.
    #[test]
    fn unsupported_transports_and_hostless_urls_are_refused_before_git_runs() {
        // An empty authority puts the credential in the PATH, where neither the
        // authority redaction nor the credential refusal could see it: git was
        // handed the token and every diagnostic echoed it.
        let err = RemoteSource::parse("https:///user:ghp_LEAKTEST@host/repo")
            .unwrap_err()
            .to_string();
        assert!(!err.contains("ghp_LEAKTEST"), "{err}");
        assert!(err.contains("<redacted>"), "{err}");
        assert!(err.contains("names no host"), "{err}");
        assert!(
            !remote_source_display("https:///user:ghp_LEAKTEST@host/repo").contains("ghp_LEAKTEST")
        );

        for source in [
            "https:///owner/repo",
            "ssh:///owner/repo.git",
            "git@:owner/repo.git",
        ] {
            let err = RemoteSource::parse(source).unwrap_err().to_string();
            assert!(err.contains("names no host"), "{source}: {err}");
        }

        // `git://` is unauthenticated and unencrypted; an unknown scheme makes
        // git run a `git-remote-<scheme>` helper.
        for source in [
            "git://github.com/owner/repo",
            "ftp://host/owner/repo.git",
            "weird://host/owner/repo",
        ] {
            let err = RemoteSource::parse(source).unwrap_err().to_string();
            assert!(err.contains("transport"), "{source}: {err}");
            assert!(looks_like_remote_source(source), "{source}");
            assert!(recorded_source_exists(source), "{source}");
        }

        // The supported transports, in every spelling, still parse.
        for source in [
            "https://github.com/Owner/Repo.git",
            "ssh://git@github.com/Owner/Repo.git",
            "git+ssh://git@github.com/Owner/Repo.git",
            "git@github.com:Owner/Repo.git",
            "file:///srv/mirror/repo.git",
            "Owner/Repo",
        ] {
            RemoteSource::parse(source).unwrap_or_else(|err| panic!("{source}: {err}"));
        }
    }

    /// An entry minted before the transport policy can hold an origin vstack
    /// would refuse as a source; fetching it pulls this source's content over
    /// that transport anyway.
    #[test]
    fn a_cache_entry_whose_origin_uses_an_unsupported_transport_is_refused() {
        let root = tmpdir("origin-transport");
        let origin = root.join("origin");
        init_git_repo(&origin);
        let home = root.join("home");

        crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
            let remote = RemoteSource::parse("owner/repo").unwrap().unwrap();
            clone_into(&origin, &remote.cache_dir);
            // Control: an https origin for the same repository is accepted.
            git(
                &remote.cache_dir,
                &["remote", "set-url", "origin", &remote.git_url],
            );
            ensure_cache_entry_is_owned(&remote).unwrap();

            git(
                &remote.cache_dir,
                &[
                    "remote",
                    "set-url",
                    "origin",
                    "git://github.com/owner/repo.git",
                ],
            );
            let err = ensure_cache_entry_is_owned(&remote)
                .unwrap_err()
                .to_string();
            assert!(err.contains("its origin is unusable"), "{err}");
            assert!(err.contains("transport"), "{err}");
            // And the update refuses before fetching over it.
            let err = update_cached_repo(&remote).unwrap_err().to_string();
            assert!(err.contains("its origin is unusable"), "{err}");
        });
        let _ = std::fs::remove_dir_all(root);
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

    /// Every git failure this module reports runs its output through
    /// `redact_token`. A repository or path name whose last character before a
    /// trailing quote is multi-byte turned that handled error into a panic.
    #[test]
    fn redaction_survives_multi_byte_characters_at_a_url_boundary() {
        for token in [
            "'https://github.com/owner/rep\u{00f6}'",
            "https://github.com/owner/rep\u{00f6}",
            "\u{00e9}",
            "'https://github.com/o/r.git':",
        ] {
            let redacted = redact_token(token);
            assert!(!redacted.is_empty(), "{token}");
        }
        assert_eq!(
            redact_token("'https://user:tok@github.com/owner/rep\u{00f6}'"),
            "'https://user:<redacted>@github.com/owner/rep\u{00f6}'"
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
                records
                    .refused
                    .reason("owner/repo")
                    .is_some_and(|reason| reason.contains("does not resolve to its cache entry")),
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
