//! Resolving the `--source` argument to a directory on disk: a local path, a
//! remote vstack repo cloned into the shared cache, or the vstack checkout
//! `add` is being run from.

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

pub(super) fn resolve_source(source: Option<&str>, interactive: bool) -> Result<PathBuf> {
    match source {
        Some(path) if Path::new(path).exists() => Ok(std::fs::canonicalize(path)?),
        Some(source) if looks_like_remote(source) => clone_or_update(source, interactive),
        Some(source) => {
            anyhow::bail!(
                "Source not found: {source}\n\
                 Use a local path or GitHub shorthand (owner/repo)"
            );
        }
        None => {
            // Walk up from CWD to find a local vstack repo first
            let mut dir = std::env::current_dir()?;
            loop {
                if crate::resolve::is_vstack_source(&dir) {
                    return Ok(dir);
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

fn looks_like_remote(source: &str) -> bool {
    // owner/repo, https://github.com/..., git@github.com:...
    source.contains('/') && !source.starts_with('.') && !source.starts_with('/')
        || source.starts_with("https://")
        || source.starts_with("git@")
}

/// Clone or update a remote repo into `~/.vstack/cache/<host>_<owner>_<repo>`
fn clone_or_update(source: &str, interactive: bool) -> Result<PathBuf> {
    let cache_dir = crate::config::global_base_dir()
        .join(".vstack")
        .join("cache");
    std::fs::create_dir_all(&cache_dir)?;

    // Normalize source to a git URL and a cache directory. Both come from the
    // one host-aware source parser `check` and `refresh` also use, so every
    // accepted form of the same remote lands in the SAME cache, two different
    // remotes never share one, and the URL git resolves is always the endpoint
    // that cache is keyed on. `http://` is refused: a cache feeds executable
    // content into a project.
    if source.starts_with("http://") {
        anyhow::bail!(
            "`{source}` uses cleartext http:// — vstack installs executable content from a source, so use https:// or ssh"
        );
    }
    let git_url = crate::config::remote_git_url(source);
    let existing = crate::config::remote_cache_lookup(source);
    if let crate::config::RemoteCacheLookup::Unverifiable { reason, .. } = &existing {
        anyhow::bail!(
            "refusing to install from the cache for `{source}`: {reason}. Remove that directory under ~/.vstack/cache to re-clone."
        );
    }
    let repo_dir = match existing {
        // An existing clone — at the current key or one an earlier release
        // wrote — is adopted rather than re-cloned.
        crate::config::RemoteCacheLookup::Usable(dir) => Some(dir),
        _ => crate::config::remote_cache_dir(source),
    };
    let (Some(repo_dir), Some(git_url)) = (repo_dir, git_url) else {
        anyhow::bail!(
            "`{source}` is not a source vstack can fetch: use `owner/repo`, an https:// URL, or git@host:owner/repo"
        );
    };

    if repo_dir.join(".git").exists() {
        // Update existing clone (handles force-pushed histories) through the
        // one guarded fetch, reporting every outcome the way `refresh` does.
        // Interactive resolution (the wizard's own source lookup) is
        // TTL-gated and short-bounded so the UI paints in seconds even when
        // the remote is unroutable; an explicit non-interactive `vstack add`
        // asked for this exact fetch and gets it unbounded.
        let (max_age, bound) = if interactive {
            (
                Some(crate::config::REMOTE_CACHE_TTL),
                crate::config::FetchBound::INTERACTIVE,
            )
        } else {
            (None, crate::config::FetchBound::Unbounded)
        };
        crate::refresh_sources::update_cached_repo(&repo_dir, max_age, bound);
    } else {
        // Fresh shallow clone. Same builder as every other cache git call:
        // nothing inherited may redirect it at another repository's index or
        // objects, and it may not stop to ask a human anything. Nothing is
        // pinned — there is no cache to pin to yet.
        // Scrubbed: a `https://user:token@host/…` remote must not print its
        // token into terminal scrollback or a captured CI log.
        eprintln!(
            "Cloning {}...",
            crate::commands::check::display_text(&git_url)
        );
        let status = crate::config::git_command_for_cache()
            .args([
                "clone",
                "--depth",
                "1",
                &git_url,
                repo_dir.to_str().unwrap(),
            ])
            .status()
            .context("failed to run git clone — is git installed?")?;
        if !status.success() {
            // The GitHub SSH hint belongs only to the shorthand it expands;
            // any other source already names its own endpoint, and printing a
            // github.com command for a gitlab source is a wrong instruction.
            let retry = if crate::config::is_remote_source_slug(source) {
                crate::commands::check::command_arg(&format!("git@github.com:{source}.git"))
            } else {
                crate::commands::check::command_arg(&git_url)
            };
            anyhow::bail!(
                "git clone failed. For private repos, make sure you have access:\n\
                 \n\
                 SSH:   git clone {retry}\n\
                 HTTPS: gh auth login\n\
                 Token: export GH_TOKEN=<your-token>"
            );
        }
        crate::config::record_cache_clone(&repo_dir);
    }

    if !crate::resolve::is_vstack_source(&repo_dir) {
        anyhow::bail!(
            "Cloned repo doesn't look like a vstack repo (no catalog table or source item directories found)"
        );
    }

    Ok(repo_dir)
}
