//! Resolving a source the project REMEMBERED rather than one a user just
//! typed: the registry's selection, and the one its lock records.
//!
//! Everything here answers under one invariant — the recorded string must name
//! the tree that was read, resolved the way later readers will resolve it —
//! because these strings are re-resolved by `refresh`, `check` and `verify`
//! afterwards, and a spelling whose resolution differs from theirs writes a
//! `source_hash` for a tree the install did not come from.

use super::*;

/// Resolve a source the project remembered — the registry's selection, or the
/// one its lock records — for the fallback chain.
///
/// Returns the directory AND the string that names it, under one invariant:
/// **the recorded string must name the tree that was read, resolved the way
/// later readers will resolve it.** `refresh`, `check` and `verify` all
/// re-resolve that string later, and any spelling whose resolution here
/// differs from theirs puts a `source_hash` in the lock for a tree the install
/// did not come from — with every surface reporting green, which is this
/// issue's whole defect class.
///
/// Two branches used to break it, in opposite directions. A remembered path
/// into vstack's cache resolves through the remote its entry clones, so
/// recording the string it started FROM named a different clone than the one
/// read. And a relative spelling was tested against the process CWD while
/// every reader joins it to [`config::project_root`], so running from a
/// subdirectory that happened to hold a same-named source installed one tree
/// and hashed another.
///
/// Recording the spelling is not the invariant and never was — it is what the
/// invariant happens to require for a local source, whose spelling readers
/// resolve to the same directory. Where the two differ, the tree that was read
/// is what gets recorded.
///
/// `Ok(None)` is the one outcome that may walk on: a local candidate that names
/// nothing. A remote that is refused, an unowned cache entry or a failed clone
/// is an ERROR, because continuing past it installs items from a different
/// source over the ones already installed — the same refused-is-not-absent
/// fail-open the refresh side closed.
pub(super) fn resolve_remembered_source(
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
    // The SPELLING, because readers resolve it to this same directory — an
    // absolute path is itself, and the relative branch below now resolves the
    // way they do. Canonicalizing instead would put a machine-specific
    // absolute path in a lock file that is committed, resolving on one
    // checkout and not another.
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
    // Against the PROJECT ROOT, which is where every reader resolves a
    // relative or bare recorded source — never against the process CWD, whose
    // answer nothing downstream would agree with. A spelling readers cannot
    // resolve at all (`a/b/c` is neither explicitly relative nor bare) walks
    // on rather than installing from a tree no later command could find.
    if let Some(dir) = crate::refresh_sources::resolve_recorded_local_source(source) {
        return local(dir);
    }
    // A relative spelling with separators — `a/b/c` — is a source no READER
    // can resolve: the resolver above answers only for `./…`, `../…`, `.` and
    // a bare name. Walking on when the directory is really there installs from
    // whatever source the chain reaches next, which is the fail-open this
    // function exists to close, and the error the user finally saw named a
    // source their project never chose. "Names nothing" may walk on; "names
    // something nothing downstream can find" may not.
    if (source.contains('/') || source.contains('\\'))
        && config::project_root().join(source).is_dir()
    {
        anyhow::bail!(
            "the source this project is set to use cannot be resolved: {} names a directory under the project root, but only `./…`, `../…`, `.` and a bare name are recorded in a form later commands can resolve",
            crate::refresh_sources::remote_source_display(source)
        );
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
