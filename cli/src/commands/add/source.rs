//! Resolving the `--source` argument to a directory on disk: a local path, a
//! remote vstack repo cloned into the shared cache, or the vstack checkout
//! `add` is being run from.

use super::ResolvedSource;
mod cache_path;
mod label;
use crate::config::{self, CacheLease};
use crate::resolve::{same_path, source_from_project_lock};
use anyhow::{Context, Result};
use cache_path::resolve_cache_path_source;
pub(in crate::commands::add) use label::source_label;
use std::path::{Path, PathBuf};

/// Whether `add` must fetch a cached remote source before reading it, or may
/// serve the clone it already has while that one is fresh.
///
/// The question this answers is "did the user ask for THIS source", not "may I
/// prompt" — and deriving it from interactivity conflated the two. An explicit
/// `vstack add <source>` then ran under the wizard's TTL: a cache fetched
/// within the last six hours was installed as-is even though upstream had
/// moved, and the fresh stamp that left behind read as current to `check`
/// until the TTL expired, so nothing reported it. Callers state which they
/// mean.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum SourceFetch {
    /// Fetch before reading: no TTL gate, no time bound. Either the user named
    /// this source in the command — fetching it IS the command — or the run is
    /// non-interactive, where no menu is waiting on the answer and a scripted
    /// install must get what upstream has now. Git prompts as it normally
    /// would, which `vstack add` already allows.
    Now,
    /// Serve a cache younger than the TTL, and kill a fetch that outlives the
    /// interactive bound. Only the wizard looking a source up on the user's
    /// behalf — the one it opens on, and any source picked from its dialog —
    /// where an unroutable remote must not hang a menu. `check` reports the
    /// staleness this leaves behind.
    CachedWhileFresh,
}

impl SourceFetch {
    /// The policy for the source a `vstack add` invocation starts from.
    /// `named_source` is the SOURCE argument as typed; the wizard states its
    /// own intent when it switches sources, and never comes through here.
    pub(super) fn for_invocation(named_source: Option<&str>, interactive: bool) -> Self {
        match named_source {
            Some(_) => Self::Now,
            None if interactive => Self::CachedWhileFresh,
            None => Self::Now,
        }
    }

    /// The cache age this policy tolerates, and the deadline it fetches under.
    pub(super) fn policy(self) -> (Option<std::time::Duration>, config::FetchBound) {
        match self {
            Self::Now => (None, config::FetchBound::Unbounded),
            Self::CachedWhileFresh => (
                Some(config::REMOTE_CACHE_TTL),
                config::FetchBound::INTERACTIVE,
            ),
        }
    }
}

/// A source directory `add` is about to read, and the lease that keeps a
/// cached one from being fetched and reset while it does. Local directories
/// lease nothing — no vstack process rewrites them.
pub(super) struct LeasedSourceDir {
    pub dir: PathBuf,
    pub lease: CacheLease,
}

impl LeasedSourceDir {
    fn local(dir: PathBuf) -> Self {
        Self {
            dir,
            lease: CacheLease::none(),
        }
    }
}

/// Resolve a source the project remembered — the registry's selection, or the
/// one its lock records — for the fallback chain.
///
/// Returns the directory AND the string that names it, because the two can
/// differ: a remembered path into vstack's cache resolves through the remote
/// its entry clones, and the caller must record the source it actually read
/// rather than the one it started from. Recording the remembered string
/// instead put a legacy-key path in the lock beside a `source_hash` taken
/// against the canonical entry the install had really come from — `check` then
/// passed and `verify` failed on one state.
///
/// `Ok(None)` is the one outcome that may walk on: a local candidate that names
/// nothing. A remote that is refused, an unowned cache entry or a failed clone
/// is an ERROR, because continuing past it installs items from a different
/// source over the ones already installed — the same refused-is-not-absent
/// fail-open the refresh side closed.
fn resolve_remembered_source(
    source: &str,
    fetch: SourceFetch,
) -> Result<Option<(LeasedSourceDir, String)>> {
    // Ordered as `refresh` orders it: an absolute path that is a source
    // DIRECTORY is that path, then the remote reading, then a relative one. A
    // remote-shaped spelling that ALSO names a directory under the current
    // working directory is the remote — otherwise a project holding an
    // `owner/repo` subdirectory would silently install from it.
    //
    // A directory, not merely something that exists: a source is a tree items
    // are read out of, so a regular file at a remembered path is a local
    // candidate that names nothing — the one outcome that may walk on.
    let path = Path::new(source);
    if let Some(resolved) = resolve_cache_path_source(source, fetch) {
        return resolved.map(Some);
    }
    // The SPELLING, not the canonicalized directory: only the cache branch
    // above changes what gets recorded, which is what makes the rule above
    // true. Canonicalizing here would also rewrite every non-canonical local
    // spelling — and a relative `./src`, which stays supported for a legacy or
    // hand-edited lock, would become a machine-specific absolute path in a
    // file that is committed, resolving on one checkout and not another.
    let local = |dir: PathBuf| Ok(Some((LeasedSourceDir::local(dir), source.to_string())));
    if path.is_absolute() && path.is_dir() {
        return local(std::fs::canonicalize(source)?);
    }
    if crate::refresh_sources::looks_like_remote_source(source) {
        return clone_or_update(source, fetch)
            .map(|leased| Some((leased, source.to_string())))
            .with_context(|| {
                format!(
                    "resolving the source this project is set to use ({})",
                    crate::refresh_sources::remote_source_display(source)
                )
            });
    }
    if path.is_dir() {
        return local(std::fs::canonicalize(source)?);
    }
    // A spelling that opens with a scheme is an attempt at a URL, so it names
    // something even when the strict parser cannot read it. Walking on would
    // install from whatever source the chain reaches next.
    if crate::refresh_sources::names_a_transport(source) {
        anyhow::bail!(
            "the source this project is set to use is not a usable URL: {}",
            crate::refresh_sources::remote_source_display(source)
        );
    }
    Ok(None)
}

fn resolve_source(source: Option<&str>, fetch: SourceFetch) -> Result<LeasedSourceDir> {
    if let Some(source) = source
        && let Some(resolved) = resolve_cache_path_source(source, fetch)
    {
        return resolved.map(|(leased, _)| leased);
    }
    match source {
        Some(path) if Path::new(path).is_dir() => {
            Ok(LeasedSourceDir::local(std::fs::canonicalize(path)?))
        }
        Some(source) if crate::refresh_sources::looks_like_remote_source(source) => {
            clone_or_update(source, fetch)
        }
        Some(source) => {
            anyhow::bail!(
                "Source not found: {}\n\
                 Use a local path or GitHub shorthand (owner/repo)",
                crate::refresh_sources::remote_source_display(source)
            );
        }
        None => {
            // Walk up from CWD to find a local vstack repo first
            let mut dir = std::env::current_dir()?;
            loop {
                if crate::resolve::is_vstack_source(&dir) {
                    return Ok(LeasedSourceDir::local(dir));
                }
                if !dir.pop() {
                    break;
                }
            }
            // Fall back to default remote repo
            clone_or_update(crate::REPO, fetch)
        }
    }
}

/// Clone or update a remote repo into its entry under `~/.vstack/cache/`.
///
/// How hard it fetches is [`SourceFetch`]'s answer, not this function's.
///
/// The lease comes back with the directory: `add` discovers, hashes and copies
/// out of this tree next, and it must be the tree the fetch left behind rather
/// than one a second `add` is resetting halfway through.
fn clone_or_update(source: &str, fetch: SourceFetch) -> Result<LeasedSourceDir> {
    let remote = crate::refresh_sources::RemoteSource::parse(source)?
        .ok_or_else(|| anyhow::anyhow!("Source not found: {source}"))?;
    let display = &remote.display;

    let lease = if crate::refresh_sources::cache_entry_present(&remote) {
        // Update existing clone (handles force-pushed histories). A refusal —
        // the entry is not vstack's own clone — is an error; a failed fetch
        // keeps the stale clone.
        let (max_age, bound) = fetch.policy();
        // Announce only a fetch that is actually going to run: within the TTL
        // there is nothing to wait on and nothing to say.
        if crate::config::remote_cache_fetch_due(&remote.cache_dir, max_age) {
            eprintln!("Updating cached repo {display}...");
        }
        crate::refresh_sources::update_cached_repo_bounded(&remote, max_age, bound)?
    } else {
        // Fresh shallow clone
        eprintln!("Cloning {display}...");
        let lease = crate::refresh_sources::clone_cached_repo(&remote).with_context(|| {
            let ssh_hint = crate::config::parse_github_slug(source)
                .map(|slug| {
                    format!(
                        "SSH:   git clone {}\n",
                        crate::display::command_arg(&format!("git@github.com:{slug}.git"))
                    )
                })
                .unwrap_or_default();
            format!(
                "caching {display} failed. For private repos, make sure you have access:\n\
                 \n\
                 {ssh_hint}\
                 HTTPS: gh auth login\n\
                 Token: export GH_TOKEN=<your-token>"
            )
        })?;
        // A clone IS the newest possible fetch. Without this the very next
        // `check` would find no stamp, call the entry due, and spawn a
        // background refresh of a clone made seconds ago.
        crate::config::record_cache_clone(&remote.cache_dir);
        lease
    };

    if !crate::resolve::is_vstack_source(&remote.cache_dir) {
        anyhow::bail!(
            "Cloned repo doesn't look like a vstack repo (no catalog table or source item directories found)"
        );
    }

    Ok(LeasedSourceDir {
        dir: remote.cache_dir,
        lease,
    })
}

/// The source this `add` will install from, with the fetch policy its caller
/// states. `source` is what to resolve; [`SourceFetch`] is how hard to chase
/// it, and the two are separate because the same source string arrives both
/// ways — typed on the command line, and picked from the wizard's dialog.
pub(super) fn resolve_source_for_app(
    source: Option<&str>,
    registry: &config::SourceRegistry,
    project_root: &Path,
    fetch: SourceFetch,
) -> Result<ResolvedSource> {
    if let Some(named) = source
        && let Some(resolved) = resolve_cache_path_source(named, fetch)
    {
        let (leased, recorded) = resolved?;
        return Ok(ResolvedSource {
            source_repo: config::source_repo_for_source(Some(&leased.dir), &recorded),
            label: source_label(&recorded),
            source: recorded,
            dir: leased.dir,
            persist: true,
            lease: leased.lease,
        });
    }
    match source {
        // A local source is a DIRECTORY. Anything else that happens to exist
        // at that path names no source, and reading a catalog out of it yields
        // an empty install rather than the refusal the user needs.
        Some(path) if Path::new(path).is_dir() => {
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
            let resolved = resolve_source(Some(source), fetch)?;
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
                && let Some((resolved, recorded)) = resolve_remembered_source(current, fetch)?
                && usable(&resolved.dir)
            {
                // `recorded`, never `current`: the two differ exactly when the
                // remembered string is a cache path, and what goes in the lock
                // has to be the source the install was read from.
                return Ok(ResolvedSource {
                    source_repo: config::source_repo_for_source(Some(&resolved.dir), &recorded),
                    label: source_label(&recorded),
                    source: recorded,
                    dir: resolved.dir,
                    persist: true,
                    lease: resolved.lease,
                });
            }

            // Existing projects already record installed item sources in the
            // lock file. Use that before any global/default source so a
            // project's repo choice remains stable across invocations.
            if let Some(current) = source_from_project_lock(project_root)
                && let Some((resolved, recorded)) = resolve_remembered_source(&current, fetch)?
                && usable(&resolved.dir)
            {
                return Ok(ResolvedSource {
                    source_repo: config::source_repo_for_source(Some(&resolved.dir), &recorded),
                    label: source_label(&recorded),
                    source: recorded,
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
            let resolved = resolve_source(Some(&source), fetch)?;
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
