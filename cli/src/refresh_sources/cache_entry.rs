//! Vstack's own cache entries, as sources.
//!
//! Which entry a recorded source names — including one recorded as a PATH into
//! the cache rather than as a URL, at the entry itself or anywhere beneath it
//! — and what resolving that entry produces. The cache is state vstack fetches
//! and `reset --hard`s on a TTL, never a checkout a user maintains, so a path
//! anywhere in that subtree arrives at the same fetch, the same lease and the
//! same ownership proofs a URL does.
//!
//! Choosing between the local, relative and remote branches for one source
//! string stays in [`super`]; this is the remote branch and the mapping that
//! reaches it.

use super::*;
use crate::config;
use std::path::{Path, PathBuf};

/// The cache entry `path` lies in, and the part of `path` below it — empty
/// when `path` IS the entry. `None` when the path is nowhere in the cache.
///
/// Membership is ANCESTRY, not parent equality. The hazard is the whole
/// subtree, not its top row: a source recorded as `<cache>/<entry>/<subdir>`,
/// which is what `vstack add <cache>/<entry>/sub` writes for a repository
/// whose catalog is nested, sits in a tree vstack fetches and `reset --hard`s
/// exactly as the entry does, and reading it as a stable checkout reproduces
/// the whole silent-staleness class this module exists to close.
///
/// Each level is judged from its PARENT, never from the directory itself: an
/// entry that is a symlink pointing out of the cache is still an entry the
/// cache owns, and classifying it by where it leads is what let it be read as
/// an ordinary local directory — skipping the very ownership proofs that exist
/// to refuse it.
pub(crate) fn remote_cache_entry_for_path(path: &Path) -> Option<(PathBuf, PathBuf)> {
    if !path.is_absolute() {
        return None;
    }
    let root = canonicalish(&remote_cache_root());
    let mut entry = path;
    let mut below = PathBuf::new();
    loop {
        let parent = entry.parent()?;
        let name = entry.file_name()?;
        if canonicalish(parent) == root {
            return Some((entry.to_path_buf(), below));
        }
        // Not `Path::new(name).join(&below)` unconditionally: joining an
        // EMPTY path appends a separator, so the first step would build
        // `sub/` and every string built from it — a recorded lock source
        // included — would carry a trailing slash it never had.
        below = if below.as_os_str().is_empty() {
            PathBuf::from(name)
        } else {
            Path::new(name).join(below)
        };
        entry = parent;
    }
}

/// Whether `path` lies anywhere in vstack's own remote cache — see
/// [`remote_cache_entry_for_path`], which also says WHERE.
pub(crate) fn is_remote_cache_entry_path(path: &Path) -> bool {
    remote_cache_entry_for_path(path).is_some()
}

/// The remote a cache entry is a clone of, read from the entry's own `origin`.
///
/// The origin is the only reliable answer. A cache key is derived FROM the
/// repository identity and is not reversible back into one: an entry minted by
/// an older vstack carries a different key for the same repository, and this
/// machine can hold both — `vanillagreencom_vstack` beside
/// `vanillagreencom_vstack-ff0070a84862081c`, one repository, two keys. So the
/// directory name is never parsed back into a remote.
///
/// The remote is PINNED to the entry the caller named: `cache_dir` stays that
/// directory rather than becoming whichever key the URL hashes to today, so
/// the fetch, the lease and the drift comparison all act on the tree the
/// entries were installed from, and resolution never redirects an install to a
/// different clone — or to one that was never cloned at all. Migrating the
/// recorded source onto the URL itself is `refresh`'s job, and it happens only
/// once the canonical entry is present and current: see
/// [`migrated_cache_entry_source`].
fn cache_entry_remote(path: &Path) -> Result<RemoteSource> {
    let entry = path.display();
    let output = hardened_cache_git_command(path)?
        .args(["remote", "get-url", "origin"])
        .output()
        .with_context(|| format!("reading the origin of cache entry {entry}"))?;
    if !output.status.success() {
        bail!(
            "refusing source {entry}: it is an entry in vstack's own cache whose origin could not be read ({}), so the remote it must be fetched from is unknown",
            git_output_summary(&output)
        );
    }
    let origin = git_stdout_line(&output.stdout);
    let remote = RemoteSource::parse(&origin)
        .with_context(|| format!("refusing source {entry}: it is an entry in vstack's own cache"))?
        .ok_or_else(|| {
            anyhow::anyhow!(
                "refusing source {entry}: it is an entry in vstack's own cache whose origin {} is not a remote vstack can fetch, so it cannot be kept up to date",
                remote_source_display(&origin)
            )
        })?;
    Ok(RemoteSource {
        cache_key: path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned(),
        cache_dir: path.to_path_buf(),
        ..remote
    })
}

/// The remote spec a source recorded as a cache-entry path should be rewritten
/// to, so the lock records the remote rather than one machine's clone of it.
///
/// Only when the recorded path IS the entry the spec resolves to. That makes
/// the rewrite correct by CONSTRUCTION rather than by a freshness check:
/// resolution has already fetched and leased that directory this run, the
/// caller hashes that same directory next, and the spec names it too — one
/// tree throughout, with no window in which they can disagree.
///
/// The alternative was to rewrite a legacy-key path onto the current key's
/// entry once a fetch of THAT entry succeeded. It cannot be made sound at
/// acceptable cost. The two clones are different directories, so the lock
/// would be committed to one while the install came from the other, and the
/// only thing standing between them is a fetch this pass would have to run —
/// unbounded, inside the lock-write loop, once per migrating entry. The
/// production case for this defect had seventeen of them, each able to stall
/// on another process's guard. And the check is only as good as its answer:
/// `lease_remote_cache` reports `Ok` for a fetch that ran and failed and for a
/// cache it could not write, both of which leave the clone where it was, while
/// a cache this process already holds reports `Fresh` — which is the state the
/// correct case is in, so gating on `Updated` refused the one migration that
/// was free and sound.
///
/// So a legacy-key path is left exactly as recorded. That costs it nothing:
/// it resolves through its own entry and is fetched on every refresh like any
/// other remote. `vstack add` is what moves it — given that path it now
/// records the remote spec — and the entry it leaves behind is inert.
///
/// A path BELOW an entry is never rewritten either: a remote spec names a
/// repository and cannot carry a subdirectory.
pub(crate) fn migrated_cache_entry_source(source: &str) -> Option<String> {
    let (entry, below) = remote_cache_entry_for_path(Path::new(source))?;
    if !below.as_os_str().is_empty() {
        return None;
    }
    let remote = cache_entry_remote(&entry).ok()?;
    let canonical = RemoteSource::parse(&remote.git_url).ok()??;
    same_path(&canonical.cache_dir, &entry).then_some(canonical.git_url)
}

/// The remote a recorded source names, whether it is spelled as a URL, as
/// GitHub shorthand, or as a path into vstack's own cache.
///
/// `Ok(None)` when the source names no remote at all; `Err` when it names one
/// that must not be used. Callers that enumerate a lock's caches read this
/// rather than [`RemoteSource::parse`], so a cache entry a fetch mutates and a
/// cache entry a report reads can never be two different directories.
pub(crate) fn remote_for_source(source: &str) -> Result<Option<RemoteSource>> {
    if let Some((entry, _)) = remote_cache_entry_for_path(Path::new(source)) {
        // The remote belongs to the ENTRY whatever part of it the source
        // named: the entry is the clone git fetches and resets, so a source
        // pointing at a subdirectory is kept fresh by fetching the whole of
        // the tree it sits in.
        if !entry.join(".git").exists() {
            return Ok(None);
        }
        return cache_entry_remote(&entry).map(Some);
    }
    RemoteSource::parse(source)
}

/// Resolve a source that names a path in the cache: the entry is fetched,
/// leased and proved vstack's own exactly as a URL-spelled source is, and the
/// part of the path BELOW the entry is then taken inside the tree that fetch
/// left behind.
pub(super) fn resolve_cache_path_source(
    entry: &Path,
    below: &Path,
    update_remote: bool,
) -> LeasedResolution {
    if !entry.join(".git").exists() {
        // Nothing to map: an entry that is not there is absent, not refused,
        // and `vstack add` is what puts one back.
        return SourceResolution::Absent.into();
    }
    let remote = match cache_entry_remote(entry) {
        Ok(remote) => remote,
        // Fail closed. A cache entry whose remote cannot be established is a
        // source whose freshness cannot be established either, and every
        // caller reports that rather than counting its bytes clean.
        Err(err) => return SourceResolution::refused(&err).into(),
    };
    let mut resolved = resolve_remote_source(remote, update_remote);
    if below.as_os_str().is_empty() {
        return resolved;
    }
    // The lease stays with the resolution: it protects the whole entry, and
    // the subdirectory is read out of it.
    if let SourceResolution::Resolved(dir) = &resolved.resolution {
        let sub = dir.join(below);
        resolved.resolution = if sub.is_dir() {
            SourceResolution::Resolved(sub)
        } else {
            SourceResolution::Absent
        };
    }
    resolved
}

/// The remote half of [`resolve_single_source_with`], reached by a source
/// spelled as a URL and by one spelled as a path into the cache alike — so
/// both arrive at the same fetch, the same lease and the same ownership
/// proofs, and neither can be given a freshness the other is denied.
pub(super) fn resolve_remote_source(remote: RemoteSource, update_remote: bool) -> LeasedResolution {
    if !cache_entry_present(&remote) {
        return SourceResolution::Absent.into();
    }
    if update_remote {
        eprintln!("Updating cached repo {}...", remote.display);
        // The update path runs the filesystem checks itself, on its way to the
        // git-level ones that guard `reset --hard`.
        return match update_cached_repo(&remote) {
            // The lease travels with the directory it protects: whoever reads
            // this root holds it until the read is done.
            Ok(lease) => LeasedResolution {
                resolution: SourceResolution::Resolved(remote.cache_dir),
                lease,
            },
            Err(err) => SourceResolution::refused(&err).into(),
        };
    } else if config::remote_cache_fetch_in_flight(&remote.cache_dir) {
        // Read-only, and another process is mid-fetch: this tree is being
        // `reset --hard` right now, so every question asked of it — which
        // assets it ships, what they hash to, even which repository its
        // `.git/config` names — can be answered wrongly rather than not at
        // all. Probed, never waited on: the session-start check runs this path
        // and must stay local, so the answer is "not this run" rather than a
        // lease taken out from under an install.
        return SourceResolution::Busy.into();
    } else if let Err(err) = ensure_cache_entry_is_owned(&remote) {
        // The same question the update path asks, because reading an entry is
        // how its content becomes the installed asset: a symlinked entry or a
        // redirected `.git` is some other checkout, and an entry whose origin
        // is a different repository would be installed as this source. Every
        // check is a read; only the fetch and reset the update path adds are
        // not.
        return SourceResolution::refused(&err).into();
    }
    SourceResolution::Resolved(remote.cache_dir).into()
}

/// What `add` must install a cache path from: the remote its entry clones,
/// the part of the path below that entry, and — when the path IS the entry —
/// the remote spec to record in place of one machine's clone of it.
///
/// `None` for every source that is not a path in a cache entry this machine
/// holds — including a path in the cache root whose entry is not there, which
/// resolution calls ABSENT and `add`'s ordinary chain answers for. `Err` for
/// an entry whose remote cannot be established, which `add` refuses exactly as
/// `check` does: without that, `check` could exit 1 telling a user to re-add a
/// source while the `vstack add` it prescribed exited 0 having installed from
/// the very entry `check` had just refused.
pub(crate) fn cache_path_install_source(source: &str) -> Option<Result<CachePathSource>> {
    let (entry, below) = remote_cache_entry_for_path(Path::new(source))?;
    if !entry.join(".git").exists() {
        return None;
    }
    Some(cache_entry_remote(&entry).map(|remote| CachePathSource {
        remote,
        entry,
        below,
    }))
}

/// [`cache_path_install_source`]'s answer.
pub(crate) struct CachePathSource {
    /// Pinned to the entry the path named, as everywhere else in this module.
    pub remote: RemoteSource,
    pub entry: PathBuf,
    /// Empty when the source named the entry itself.
    pub below: PathBuf,
}

impl CachePathSource {
    /// Whether the source named the entry itself rather than something inside
    /// it — the one shape a remote spec can stand in for.
    pub(crate) fn is_entry_root(&self) -> bool {
        self.below.as_os_str().is_empty()
    }
}

#[cfg(test)]
mod tests;
