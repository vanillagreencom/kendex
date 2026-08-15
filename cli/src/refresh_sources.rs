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

/// Resolve source directories from lock file entries.
/// Handles absolute local paths, "." (walks up from CWD), and remote shorthand (cached clones).
pub(crate) fn resolve_sources(lock: &config::LockFile) -> Vec<PathBuf> {
    resolve_source_records(lock)
        .into_iter()
        .map(|source| source.root)
        .collect()
}

pub(crate) fn resolve_source_records(lock: &config::LockFile) -> Vec<ResolvedSource> {
    resolve_source_records_with(lock, resolve_recorded_source)
}

fn resolve_source_records_with(
    lock: &config::LockFile,
    mut resolver: impl FnMut(&str) -> Option<PathBuf>,
) -> Vec<ResolvedSource> {
    let mut sources: Vec<ResolvedSource> = Vec::new();
    let mut seen = std::collections::HashSet::new();

    for entry in lock.entries.values() {
        if !seen.insert(entry.source.clone()) {
            continue;
        }
        if let Some(dir) = resolver(&entry.source) {
            push_resolved_source(&mut sources, dir, entry.source.clone());
        }
    }

    // Fallback: walk up from CWD to find a vstack source repo.
    if sources.is_empty()
        && let Ok(mut dir) = std::env::current_dir()
    {
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
                if let Some(dir) = resolver(entry) {
                    push_resolved_source(&mut sources, dir, entry.clone());
                }
            }
        }
    }

    sources
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
    resolve_single_source_with(source, true, true)
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
    let path = Path::new(source);
    if path.is_absolute() && path.is_dir() {
        return Some(path.to_path_buf());
    }
    if let Some(path) = resolve_recorded_local_source(source) {
        return Some(path);
    }
    resolve_single_source(source)
}

/// Whether an entry's recorded source still names a usable directory on disk.
///
/// Deliberately side-effect free (no remote fetch): callers use it in per-entry
/// loops to decide whether an entry may fall back to a different source.
pub(crate) fn recorded_source_exists(source: &str) -> bool {
    let path = Path::new(source);
    if path.is_absolute() {
        return path.is_dir();
    }
    resolve_recorded_local_source(source).is_some()
}

pub(crate) fn resolve_source_path(source: &str) -> Option<PathBuf> {
    resolve_single_source_with(source, false, false)
}

fn resolve_single_source_with(
    source: &str,
    update_remote: bool,
    require_vstack_source: bool,
) -> Option<PathBuf> {
    // Absolute local path that exists.
    let p = std::path::Path::new(source);
    if p.is_absolute()
        && p.is_dir()
        && (!require_vstack_source || crate::resolve::is_vstack_source(p))
    {
        return Some(p.to_path_buf());
    }

    let looks_like_remote =
        source.contains('/') && !source.starts_with('.') && !source.starts_with('/');

    // Explicit relative local source tokens in locks/registries are
    // project-scoped. Treating them as "walk upward to any vstack source" can
    // rebind a live ./source entry to the checkout running the command from a
    // linked worktree, then repair the lock to the wrong source.
    if is_explicit_relative_local_source(source) {
        return resolve_relative_local_source(source, require_vstack_source);
    }

    // Legacy pure hash/reconcile paths accepted bare placeholders such as
    // "source" by falling back to the nearest vstack checkout from CWD. Keep
    // that compatibility only after trying the project-relative path, and only
    // for non-discovery calls where the historical fallback existed.
    if !require_vstack_source && is_bare_local_source(source, looks_like_remote) {
        if let Some(path) = resolve_relative_local_source(source, false) {
            return Some(path);
        }
        return find_vstack_source_from_cwd();
    }

    // Remote shorthand (owner/repo) — update once during top-level source resolution,
    // then use the cached clone without side effects from pure attribution/hash paths.
    let cached = cached_repo_dir(source);
    if cached.join(".git").exists() {
        let display = remote_source_display(source);
        // A cache entry that is not vstack's own directory is some other
        // checkout; reading it would install that checkout's uncommitted state
        // as the remote source, so it is refused on every path, not only before
        // an update.
        if let Err(err) = reject_unowned_cache_entry(&display, &cached) {
            eprintln!("  Warning: {err:#}");
            return None;
        }
        if update_remote {
            eprintln!("Updating cached repo {display}...");
            if let Err(err) = update_cached_repo_best_effort(&display, &cached) {
                eprintln!("  Warning: {err:#}");
                return None;
            }
        }
        return Some(cached);
    }

    None
}

/// The cache entry a remote shorthand source (`owner/repo`) is cloned into.
pub(crate) fn cached_repo_dir(source: &str) -> PathBuf {
    remote_cache_root().join(source.replace('/', "_"))
}

pub(crate) fn remote_cache_root() -> PathBuf {
    config::global_base_dir().join(".vstack").join("cache")
}

/// Best-effort update of every remote source's cache entry named by a lock.
/// A refusal is reported and the entry left alone; a failed fetch keeps the
/// stale clone. Cheap enough to run before staleness checks.
pub(crate) fn refresh_remote_caches(lock: &config::LockFile) {
    let mut seen = std::collections::HashSet::new();
    for entry in lock.entries.values() {
        let src = &entry.source;
        // Only remote sources (owner/repo format)
        if !(src.contains('/') && !src.starts_with('.') && !src.starts_with('/')) {
            continue;
        }
        if !seen.insert(src.clone()) {
            continue;
        }
        let cached = cached_repo_dir(src);
        if !cached.join(".git").exists() {
            continue;
        }
        if let Err(err) = update_cached_repo_best_effort(&remote_source_display(src), &cached) {
            eprintln!("  Warning: {err:#}");
        }
    }
}

fn is_explicit_relative_local_source(source: &str) -> bool {
    source == "." || source.starts_with("./") || source.starts_with("../")
}

fn is_bare_local_source(source: &str, looks_like_remote: bool) -> bool {
    !source.is_empty()
        && !source.starts_with('~')
        && !Path::new(source).is_absolute()
        && !looks_like_remote
}

fn resolve_recorded_local_source(source: &str) -> Option<PathBuf> {
    let looks_like_remote =
        source.contains('/') && !source.starts_with('.') && !source.starts_with('/');
    if !is_explicit_relative_local_source(source)
        && !is_bare_local_source(source, looks_like_remote)
    {
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
// Remote cache git invocations
//
// Every `git` process that touches a cache entry is built by `cache_git_program`
// and nothing else: the update path runs `reset --hard`, and git will happily
// aim that at whatever an inherited `GIT_DIR`/`GIT_WORK_TREE`, a symlinked
// entry, a redirected `.git`, or the clone's own `core.worktree` names.
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

/// The ssh command for a cache git invocation, in batch mode. An inherited
/// `GIT_SSH_COMMAND` is extended rather than replaced, so a caller's own ssh
/// binary and options keep working; git appends the host and remote command
/// after this string, so the added option still lands before them.
fn batch_mode_ssh_command(inherited: Option<&str>) -> String {
    let base = inherited
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("ssh");
    format!("{base} -o BatchMode=yes")
}

/// The one constructor every cache `git` invocation is built from. Cloning,
/// reading an origin and updating all run unattended inside an add or refresh:
/// a credential prompt in any of them hangs the run, and an inherited
/// repository override in any of them points git outside the cache.
fn cache_git_program() -> std::process::Command {
    let mut command = std::process::Command::new("git");
    for key in GIT_LOCATION_ENV_VARS {
        command.env_remove(key);
    }
    command.env("GIT_TERMINAL_PROMPT", "0");
    command.env(
        "GIT_SSH_COMMAND",
        batch_mode_ssh_command(std::env::var("GIT_SSH_COMMAND").ok().as_deref()),
    );
    command
}

/// A `git` invocation pinned to an existing cache entry: the working directory
/// decides the repository, with every inherited override cleared.
fn cache_git_command(repo_dir: &Path) -> std::process::Command {
    let mut command = cache_git_program();
    command.current_dir(repo_dir);
    command
}

/// The `git clone` that mints a fresh cache entry. The destination is named on
/// the command line, so this one runs from the caller's working directory.
fn cache_clone_command(git_url: &str, cache_dir: &Path) -> std::process::Command {
    let mut command = cache_git_program();
    command.args(["clone", "--depth", "1", git_url]);
    command.arg(cache_dir);
    command
}

/// Refuse a cache entry whose contents are not vstack's own directory.
///
/// A symlinked entry, or one whose `.git` is a symlink or a `gitdir:` file, is
/// some other checkout's working tree — one with the same origin passes every
/// content check — so it must be neither read as the remote source nor be the
/// target of `reset --hard`. Filesystem checks only; see
/// [`ensure_cache_entry_is_owned`] for the git-level check that guards updates.
pub(crate) fn reject_unowned_cache_entry(display: &str, repo_dir: &Path) -> Result<()> {
    let meta = std::fs::symlink_metadata(repo_dir)
        .with_context(|| format!("inspecting cached source {display}"))?;
    // The path is never printed: a cache key is reconstructed from the recorded
    // source and can embed URL userinfo. `display` is already redacted.
    if meta.file_type().is_symlink() {
        bail!(
            "refusing cached source {display}: its cache entry is a symlink, and updating it would run destructive git commands outside the cache"
        );
    }
    if !meta.is_dir() {
        bail!("refusing cached source {display}: its cache entry is not a directory");
    }
    // `git clone` always leaves a real `.git` directory. A symlink or a
    // `gitdir:` file there redirects the repository metadata elsewhere, so
    // `reset --hard` would act on a worktree vstack does not own even though
    // the entry itself is a plain directory.
    let git_meta = std::fs::symlink_metadata(repo_dir.join(".git"))
        .with_context(|| format!("inspecting git metadata for cached source {display}"))?;
    if !git_meta.is_dir() || git_meta.file_type().is_symlink() {
        bail!("refusing cached source {display}: its cache entry does not own its git metadata");
    }
    Ok(())
}

/// The checks that decide whether a cache entry is vstack's to update: the
/// filesystem checks above, plus asking git where it would act. The
/// environment is sanitized, but the cache's own `config` can still carry a
/// `core.worktree` pointing at a user checkout, and no check on the entry or
/// its `.git` sees that — `reset --hard` would then overwrite the user's copies
/// of the tracked files. Refuse unless git's answer is the cache entry itself.
pub(crate) fn ensure_cache_entry_is_owned(display: &str, repo_dir: &Path) -> Result<()> {
    reject_unowned_cache_entry(display, repo_dir)?;
    let output = cache_git_command(repo_dir)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .with_context(|| format!("resolving the work tree of cached source {display}"))?;
    if !output.status.success() {
        bail!(
            "refusing to update cached source {display}: its work tree could not be resolved: {}",
            git_output_summary(&output)
        );
    }
    let toplevel = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim());
    // Canonicalized on both sides: the cache root is routinely reached through
    // a symlinked home or temp directory, and git reports the resolved path. A
    // path that will not canonicalize fails closed.
    let resolved = std::fs::canonicalize(&toplevel).map_err(|err| {
        anyhow::anyhow!(
            "refusing to update cached source {display}: its work tree could not be resolved: {err}"
        )
    })?;
    let expected = std::fs::canonicalize(repo_dir)
        .map_err(|err| anyhow::anyhow!("refusing to update cached source {display}: {err}"))?;
    if resolved != expected {
        // Neither path is printed: the work tree is the user location this
        // refuses to touch.
        bail!(
            "refusing to update cached source {display}: its git work tree does not resolve to its cache entry, and updating it would run destructive git commands outside the cache"
        );
    }
    Ok(())
}

/// Bring a cache entry to `origin/HEAD`. Refuses an entry vstack does not own;
/// otherwise a failed fetch or reset is an error the caller decides about.
pub(crate) fn update_cached_repo(display: &str, repo_dir: &Path) -> Result<()> {
    ensure_cache_entry_is_owned(display, repo_dir)?;
    fetch_and_reset_owned_cache(display, repo_dir)
}

/// The destructive step itself. Private so that every caller has passed
/// through [`ensure_cache_entry_is_owned`] first.
fn fetch_and_reset_owned_cache(display: &str, repo_dir: &Path) -> Result<()> {
    let fetch = cache_git_command(repo_dir)
        .args(["fetch", "origin", "--quiet"])
        .stdout(std::process::Stdio::null())
        .output()
        .with_context(|| format!("running git fetch for cached source {display}"))?;
    if !fetch.status.success() {
        bail!(
            "git fetch failed for cached source {display}: {}",
            git_output_summary(&fetch)
        );
    }
    let reset = cache_git_command(repo_dir)
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

/// Update a cache in place, tolerating a failed fetch but not a refusal.
///
/// The two failures are not the same news. A fetch that failed leaves a cache
/// vstack owns, whose stale contents are still the requested source at an
/// older revision, so callers may use it. A refusal means the entry's contents
/// are some other checkout's working tree, and returning it would install that
/// tree's uncommitted state as the remote source; that error propagates.
pub(crate) fn update_cached_repo_best_effort(display: &str, repo_dir: &Path) -> Result<()> {
    ensure_cache_entry_is_owned(display, repo_dir)?;
    if let Err(err) = fetch_and_reset_owned_cache(display, repo_dir) {
        eprintln!("  Warning: {err:#}; using cached version");
    }
    Ok(())
}

/// Shallow-clone `git_url` into a fresh cache entry.
pub(crate) fn clone_cached_repo(display: &str, git_url: &str, cache_dir: &Path) -> Result<()> {
    reject_credential_bearing_git_url(git_url)?;
    if let Some(parent) = cache_dir.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating source cache {}", parent.display()))?;
    }
    let output = cache_clone_command(git_url, cache_dir)
        .stdout(std::process::Stdio::null())
        .output()
        .context("failed to run git clone — is git installed?")?;
    if !output.status.success() {
        bail!(
            "git clone failed for {display}: {}",
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
        .map(redact_remote_userinfo)
        .collect::<Vec<_>>()
        .join(" ");
    if sanitized.is_empty() {
        "git exited without stderr".to_string()
    } else {
        sanitized
    }
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
    let authority_end = input[authority_start..]
        .find(['/', ' ', '\t', '\n', '\r'])
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
        let records = resolve_source_records(&lock);

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
            resolve_source_records(&lock)
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
                Some(source.clone())
            } else {
                None
            }
        });

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

        let records = resolve_source_records(&lock);

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
            assert!(!recorded_source_exists("owner/repo"));
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
                "owner/repo" => Some(source_a.clone()),
                "other/repo" => Some(source_b.clone()),
                _ => None,
            }
        });

        assert_eq!(records.len(), 2);
        assert_eq!(counts.borrow().get("owner/repo"), Some(&1));
        assert_eq!(counts.borrow().get("other/repo"), Some(&1));

        let _ = std::fs::remove_dir_all(root);
    }

    // -----------------------------------------------------------------------
    // Remote cache git hardening
    // -----------------------------------------------------------------------

    fn git(repo: &Path, args: &[&str]) {
        let output = std::process::Command::new("git")
            .args(args)
            .current_dir(repo)
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
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

    /// The reproduced escape's fixture: a real cache directory owning a real
    /// `.git` — so every filesystem check passes — cloned from `origin`, whose
    /// own `core.worktree` names the victim directory. The victim holds a file
    /// the upstream repo also tracks, with different contents.
    struct RedirectedCache {
        root: PathBuf,
        cache: PathBuf,
        victim: PathBuf,
    }

    fn redirected_cache(label: &str) -> RedirectedCache {
        let root = tmpdir(label);
        let origin = root.join("origin");
        init_git_repo(&origin);
        let victim = root.join("victim");
        std::fs::create_dir_all(&victim).unwrap();
        std::fs::write(victim.join("README.md"), "precious\n").unwrap();
        let cache = root.join("cache").join("owner_repo");
        std::fs::create_dir_all(cache.parent().unwrap()).unwrap();
        git(
            &root,
            &[
                "clone",
                "-q",
                origin.to_str().unwrap(),
                cache.to_str().unwrap(),
            ],
        );
        git(
            &cache,
            &["config", "core.worktree", victim.to_str().unwrap()],
        );
        RedirectedCache {
            root,
            cache,
            victim,
        }
    }

    /// Control for the fixture: the unhardened update main used to run really
    /// does overwrite the victim's file. Without this, the refusal tests below
    /// would pass against a fixture that never reproduced the escape.
    #[test]
    fn control_unhardened_reset_in_a_worktree_redirected_cache_clobbers_the_victim() {
        let fx = redirected_cache("control-clobber");
        let status = std::process::Command::new("git")
            .args(["reset", "--hard", "origin/HEAD"])
            .current_dir(&fx.cache)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(status.success());
        assert_eq!(
            std::fs::read_to_string(fx.victim.join("README.md")).unwrap(),
            "upstream\n",
            "the fixture must reproduce the escape for the refusal tests to mean anything"
        );
        let _ = std::fs::remove_dir_all(fx.root);
    }

    #[test]
    fn update_cached_repo_refuses_a_cache_whose_worktree_points_outside_it() {
        let fx = redirected_cache("refuse-redirected-worktree");

        let err = update_cached_repo("owner/repo", &fx.cache)
            .unwrap_err()
            .to_string();
        assert!(err.contains("refusing to update"), "{err}");
        assert!(err.contains("does not resolve to its cache entry"), "{err}");
        assert!(
            !err.contains(&fx.cache.display().to_string())
                && !err.contains(&fx.victim.display().to_string()),
            "neither the cache path nor the victim path may be printed: {err}"
        );
        assert_eq!(
            std::fs::read_to_string(fx.victim.join("README.md")).unwrap(),
            "precious\n",
            "the redirected worktree must be untouched"
        );

        // The best-effort path refuses too — a refusal is not a tolerated
        // fetch failure.
        let err = update_cached_repo_best_effort("owner/repo", &fx.cache)
            .unwrap_err()
            .to_string();
        assert!(err.contains("refusing to update"), "{err}");
        assert_eq!(
            std::fs::read_to_string(fx.victim.join("README.md")).unwrap(),
            "precious\n"
        );
        let _ = std::fs::remove_dir_all(fx.root);
    }

    #[test]
    fn update_cached_repo_brings_an_owned_cache_to_origin_head() {
        let root = tmpdir("owned-update");
        let origin = root.join("origin");
        init_git_repo(&origin);
        let cache = root.join("cache").join("owner_repo");
        std::fs::create_dir_all(cache.parent().unwrap()).unwrap();
        git(
            &root,
            &[
                "clone",
                "-q",
                origin.to_str().unwrap(),
                cache.to_str().unwrap(),
            ],
        );
        std::fs::write(origin.join("README.md"), "newer\n").unwrap();
        git(&origin, &["commit", "-q", "-am", "update"]);
        // Local edits in the cache are vstack's to discard.
        std::fs::write(cache.join("README.md"), "scribble\n").unwrap();

        update_cached_repo("owner/repo", &cache).unwrap();

        assert_eq!(
            std::fs::read_to_string(cache.join("README.md")).unwrap(),
            "newer\n"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn best_effort_update_tolerates_a_failed_fetch_and_keeps_the_stale_cache() {
        let root = tmpdir("best-effort-fetch-fail");
        let origin = root.join("origin");
        init_git_repo(&origin);
        let cache = root.join("cache").join("owner_repo");
        std::fs::create_dir_all(cache.parent().unwrap()).unwrap();
        git(
            &root,
            &[
                "clone",
                "-q",
                origin.to_str().unwrap(),
                cache.to_str().unwrap(),
            ],
        );
        std::fs::remove_dir_all(&origin).unwrap();

        update_cached_repo_best_effort("owner/repo", &cache).unwrap();
        assert_eq!(
            std::fs::read_to_string(cache.join("README.md")).unwrap(),
            "upstream\n"
        );
        // The strict form reports the same fetch failure instead.
        let err = update_cached_repo("owner/repo", &cache)
            .unwrap_err()
            .to_string();
        assert!(err.contains("git fetch failed"), "{err}");
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn cache_entry_that_is_a_symlink_is_refused_before_any_git_runs() {
        let root = tmpdir("symlinked-cache-entry");
        let checkout = root.join("user-checkout");
        init_git_repo(&checkout);
        std::fs::write(checkout.join("uncommitted.txt"), "precious\n").unwrap();
        std::fs::write(checkout.join("README.md"), "precious\n").unwrap();
        let cache = root.join("cache").join("owner_repo");
        std::fs::create_dir_all(cache.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&checkout, &cache).unwrap();

        let err = reject_unowned_cache_entry("owner/repo", &cache)
            .unwrap_err()
            .to_string();
        assert!(err.contains("symlink"), "{err}");
        assert!(!err.contains(&cache.display().to_string()), "{err}");
        let err = update_cached_repo("owner/repo", &cache)
            .unwrap_err()
            .to_string();
        assert!(err.contains("symlink"), "{err}");
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

        let err = update_cached_repo("owner/repo", &cache)
            .unwrap_err()
            .to_string();
        assert!(err.contains("does not own its git metadata"), "{err}");

        // A `gitdir:` file is the same redirection by another spelling.
        std::fs::remove_file(cache.join(".git")).unwrap();
        std::fs::write(
            cache.join(".git"),
            format!("gitdir: {}\n", checkout.join(".git").display()),
        )
        .unwrap();
        let err = update_cached_repo("owner/repo", &cache)
            .unwrap_err()
            .to_string();
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
    fn every_cache_git_invocation_is_non_interactive_and_drops_location_overrides() {
        let cache_dir = Path::new("/vstack/cache/owner_repo");
        let update = command_env(&cache_git_command(cache_dir));
        // Control: a bare `git` carries none of it, so the assertions below
        // are claims about the hardening and not about two empty maps.
        assert_ne!(command_env(&std::process::Command::new("git")), update);

        for key in GIT_LOCATION_ENV_VARS {
            assert_eq!(
                update.get(*key),
                Some(&None),
                "{key} is not cleared: {update:?}"
            );
        }
        assert_eq!(
            update
                .get("GIT_TERMINAL_PROMPT")
                .cloned()
                .flatten()
                .as_deref(),
            Some("0")
        );
        assert!(
            update
                .get("GIT_SSH_COMMAND")
                .cloned()
                .flatten()
                .is_some_and(|v| v.contains("BatchMode=yes")),
            "{update:?}"
        );
        // Cloning is as unattended as updating and must be built by the same
        // constructor.
        assert_eq!(
            command_env(&cache_clone_command(
                "https://github.com/owner/repo.git",
                cache_dir
            )),
            update
        );
    }

    #[test]
    fn batch_mode_ssh_command_extends_an_inherited_command() {
        assert_eq!(batch_mode_ssh_command(None), "ssh -o BatchMode=yes");
        assert_eq!(batch_mode_ssh_command(Some("   ")), "ssh -o BatchMode=yes");
        assert_eq!(
            batch_mode_ssh_command(Some("ssh -i /keys/id_ed25519")),
            "ssh -i /keys/id_ed25519 -o BatchMode=yes"
        );
    }

    #[test]
    fn credential_bearing_urls_are_rejected_and_never_echoed() {
        for url in [
            "https://token@github.com/Owner/Repo.git",
            "https://user:token@github.com/Owner/Repo.git",
            "ssh://git:token@github.com/Owner/Repo.git",
            "https://github.com/Owner/Repo.git?access_token=token",
            "https://github.com/Owner/Repo.git#token",
        ] {
            let err = reject_credential_bearing_git_url(url)
                .unwrap_err()
                .to_string();
            assert!(!err.contains("token"), "{url}: {err}");
            assert!(err.contains("<redacted>"), "{url}: {err}");
        }
        // Legitimate usernames and shorthand are kept.
        for url in [
            "https://github.com/Owner/Repo.git",
            "ssh://git@github.com/Owner/Repo.git",
            "git+ssh://git@github.com/Owner/Repo.git",
            "git@github.com:Owner/Repo.git",
            "Owner/Repo",
        ] {
            reject_credential_bearing_git_url(url).unwrap_or_else(|err| panic!("{url}: {err}"));
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
    fn clone_cached_repo_refuses_a_credential_bearing_url_before_running_git() {
        let root = tmpdir("clone-credential");
        let cache = root.join("cache").join("owner_repo");
        let err = clone_cached_repo(
            "https://<redacted>@github.com/Owner/Repo.git",
            "https://token@github.com/Owner/Repo.git",
            &cache,
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("credential-bearing"), "{err}");
        assert!(!cache.exists(), "no clone may be attempted");
        let _ = std::fs::remove_dir_all(root);
    }

    /// The whole-lock best-effort refresh the TUI runs at startup uses the same
    /// guarded update: a redirected cache entry is refused, and the victim
    /// stays untouched.
    #[test]
    fn refresh_remote_caches_refuses_a_redirected_entry_and_updates_an_owned_one() {
        let fx = redirected_cache("refresh-remote-caches");
        let home = fx.root.join("home");
        let cache_root = home.join(".vstack").join("cache");
        std::fs::create_dir_all(&cache_root).unwrap();
        // The redirected fixture becomes the cache entry for `owner/repo`.
        std::fs::rename(&fx.cache, cache_root.join("owner_repo")).unwrap();
        // An owned entry for `other/repo` with a newer origin.
        let origin = fx.root.join("other-origin");
        init_git_repo(&origin);
        let owned = cache_root.join("other_repo");
        git(
            &fx.root,
            &[
                "clone",
                "-q",
                origin.to_str().unwrap(),
                owned.to_str().unwrap(),
            ],
        );
        std::fs::write(origin.join("README.md"), "newer\n").unwrap();
        git(&origin, &["commit", "-q", "-am", "update"]);

        let mut lock = config::LockFile::default();
        lock.add(lock_entry("demo", "owner/repo"));
        lock.add(lock_entry("scout", "other/repo"));

        crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
            assert_eq!(cached_repo_dir("owner/repo"), cache_root.join("owner_repo"));
            refresh_remote_caches(&lock);
            // The updating resolution refuses the entry instead of returning
            // it; the owned one updates and resolves.
            assert_eq!(resolve_single_source("owner/repo"), None);
            assert_eq!(
                resolve_single_source("other/repo").as_deref(),
                Some(owned.as_path())
            );
        });

        assert_eq!(
            std::fs::read_to_string(fx.victim.join("README.md")).unwrap(),
            "precious\n",
            "the redirected worktree must be untouched"
        );
        assert_eq!(
            std::fs::read_to_string(owned.join("README.md")).unwrap(),
            "newer\n",
            "the owned entry must still be updated"
        );
        let _ = std::fs::remove_dir_all(fx.root);
    }
}
