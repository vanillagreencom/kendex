//! Resolving the `--source` argument to a directory on disk: a local path, a
//! remote vstack repo cloned into the shared cache, or the vstack checkout
//! `add` is being run from.

use crate::config::CacheLease;
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

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

/// How a source is shown to a human — the scope summary and the TUI source
/// selector both print this. Display only: selection and installation carry
/// the raw source, and this string is credential-scrubbed because a
/// `https://user:token@host/…` remote would otherwise print its token into
/// terminal scrollback and captured logs.
pub(super) fn source_label(source: &str) -> String {
    if Path::new(source).exists() {
        // A lock-recorded local path is untrusted text like any other: a
        // matching directory whose name carries an escape would put it on the
        // picker row. Through the same redacting display as every other source
        // diagnostic — a credential-looking string can name a real path.
        return format!(
            "local: {}",
            crate::refresh_sources::remote_source_display(source)
        );
    }

    // The repository a GitHub remote NAMES, through the one parser that
    // answers that question. The prefix trimming this replaces knew three
    // spellings and left every other one long, so an `ssh://` remote and an
    // `https://` one for the same repository sat on two differently labelled
    // rows. A slug is charset-gated where it is minted, so nothing a
    // credential or a terminal acts on can reach a picker row through it.
    if let Some(slug) = crate::config::parse_github_slug(source) {
        return slug;
    }

    // Not GitHub, so there is no identity to render — the recorded spelling,
    // minus what names no part of the repository. A registry or lock written
    // by an earlier vstack can still hold a credential URL; a picker row is
    // one of the places that would print it.
    let display = crate::refresh_sources::remote_source_display(source);
    let trimmed = display.trim_end_matches('/');
    trimmed.strip_suffix(".git").unwrap_or(trimmed).to_string()
}

/// Resolve a source the project remembered — the registry's selection, or the
/// one its lock records — for the fallback chain.
///
/// `Ok(None)` is the one outcome that may walk on: a local candidate that names
/// nothing. A remote that is refused, an unowned cache entry or a failed clone
/// is an ERROR, because continuing past it installs items from a different
/// source over the ones already installed — the same refused-is-not-absent
/// fail-open the refresh side closed.
pub(super) fn resolve_remembered_source(
    source: &str,
    interactive: bool,
) -> Result<Option<LeasedSourceDir>> {
    // Ordered as `refresh` orders it: an absolute path that exists is that
    // path, then the remote reading, then a relative one. A remote-shaped
    // spelling that ALSO names a directory under the current working
    // directory is the remote — otherwise a project holding an `owner/repo`
    // subdirectory would silently install from it.
    let path = Path::new(source);
    if path.is_absolute() && path.exists() {
        return Ok(Some(LeasedSourceDir::local(std::fs::canonicalize(source)?)));
    }
    if crate::refresh_sources::looks_like_remote_source(source) {
        return clone_or_update(source, interactive)
            .map(Some)
            .with_context(|| {
                format!(
                    "resolving the source this project is set to use ({})",
                    crate::refresh_sources::remote_source_display(source)
                )
            });
    }
    if path.exists() {
        return Ok(Some(LeasedSourceDir::local(std::fs::canonicalize(source)?)));
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

pub(super) fn resolve_source(source: Option<&str>, interactive: bool) -> Result<LeasedSourceDir> {
    match source {
        Some(path) if Path::new(path).exists() => {
            Ok(LeasedSourceDir::local(std::fs::canonicalize(path)?))
        }
        Some(source) if crate::refresh_sources::looks_like_remote_source(source) => {
            clone_or_update(source, interactive)
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
            clone_or_update(crate::REPO, interactive)
        }
    }
}

/// Clone or update a remote repo into its entry under `~/.vstack/cache/`.
///
/// `interactive` is the wizard's own source lookup, which nobody typed a
/// source for: it is TTL-gated and short-bounded so the UI paints in seconds
/// even when the remote is unroutable. An explicit `vstack add <source>` asked
/// for this exact fetch and gets it unbounded.
///
/// The lease comes back with the directory: `add` discovers, hashes and copies
/// out of this tree next, and it must be the tree the fetch left behind rather
/// than one a second `add` is resetting halfway through.
fn clone_or_update(source: &str, interactive: bool) -> Result<LeasedSourceDir> {
    let remote = crate::refresh_sources::RemoteSource::parse(source)?
        .ok_or_else(|| anyhow::anyhow!("Source not found: {source}"))?;
    let display = &remote.display;

    let lease = if crate::refresh_sources::cache_entry_present(&remote) {
        // Update existing clone (handles force-pushed histories). A refusal —
        // the entry is not vstack's own clone — is an error; a failed fetch
        // keeps the stale clone.
        let (max_age, bound) = if interactive {
            (
                Some(crate::config::REMOTE_CACHE_TTL),
                crate::config::FetchBound::INTERACTIVE,
            )
        } else {
            (None, crate::config::FetchBound::Unbounded)
        };
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
                .map(|slug| format!("SSH:   git clone git@github.com:{slug}.git\n"))
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
