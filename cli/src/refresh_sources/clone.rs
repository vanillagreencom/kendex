//! Minting a cache entry: the `git clone` that creates one, and the refusals
//! deciding whether its destination may be written at all.
//!
//! Every refusal here is a LOCAL fact — a directory in the way, a symlink, an
//! entry that cannot be stat'd — and none is a failure to reach the remote,
//! which is why they are raised where an access hint cannot cover them.

use super::*;

/// Shallow-clone the remote into its cache entry, and lease it: the caller
/// reads what was cloned, and a concurrent `add` or `refresh` would otherwise
/// be free to fetch and `reset --hard` it mid-read.
///
/// The clone lands in a staging directory and is RENAMED into the entry, so
/// the entry itself appears whole or not at all. It is the one cache write no
/// lock can cover — the lock lives inside a `.git` that does not exist yet —
/// and a reader looks for exactly that `.git` to decide the cache is present.
/// Cloning in place therefore published a half-checked-out tree to every
/// concurrent reader, which is the same false "removed" a mid-`reset` tree
/// produces, with the same `vstack remove` printed beside it.
/// Refuse a cache destination `git clone` must not be pointed at, BEFORE any
/// network work is attempted.
///
/// Every refusal here is a local fact — a directory in the way, a symlink, an
/// entry that cannot be stat'd — and none of them is a failure to reach the
/// remote. `add` wraps its clone in a private-repo access hint (`gh auth
/// login`, `GH_TOKEN`), which is the right advice for a fetch that could not
/// authenticate and the wrong advice for a stale directory: a user was told to
/// check their credentials about a folder on their own disk. Raised on its own
/// so that hint never covers it.
pub(crate) fn ensure_cache_dir_is_clonable(remote: &RemoteSource) -> Result<()> {
    // `git clone` FOLLOWS a symlink at its destination, writing the repository
    // into the link target — outside the cache root — and `add` then installs
    // from there, with the ownership refusal only arriving on a later refresh.
    // Every other write path proves the entry is vstack's own directory before
    // touching it; this is the one that did not.
    match std::fs::symlink_metadata(&remote.cache_dir) {
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
        Err(err) => {
            return Err(refusal(
                remote,
                &format!("its cache entry could not be inspected: {err}"),
            ));
        }
        Ok(meta) if meta.is_dir() => {
            let empty = std::fs::read_dir(&remote.cache_dir)
                .map(|mut entries| entries.next().is_none())
                .unwrap_or(false);
            if !empty {
                return Err(refusal(
                    remote,
                    "its cache entry already exists and is not one of vstack's clones — a directory is in the way with no `.git` of its own",
                ));
            }
        }
        Ok(_) => {
            return Err(refusal(
                remote,
                "its cache entry is not a directory vstack can clone into",
            ));
        }
    }
    Ok(())
}

pub(crate) fn clone_cached_repo(remote: &RemoteSource) -> Result<CacheLease> {
    let root = remote_cache_root();
    std::fs::create_dir_all(&root)
        .with_context(|| format!("creating source cache {}", root.display()))?;
    ensure_cache_dir_is_clonable(remote)?;
    // Dot-prefixed, so it can never be read as a cache key: every consumer of
    // the cache root skips dot entries, and a partial clone must not be one
    // any lookup can land on even by name. Keyed by pid as well, so two
    // processes cloning the same remote stage into different directories and
    // neither can delete the other's work in progress — and so a path left
    // behind by a killed clone is reclaimed rather than accumulating.
    let staging = root.join(format!(
        ".staging-{}-{}",
        remote.cache_key,
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&staging);
    let output = cache_clone_command(remote, &staging)?
        .stdout(std::process::Stdio::null())
        .output()
        .context("failed to run git clone — is git installed?")?;
    if !output.status.success() {
        let _ = std::fs::remove_dir_all(&staging);
        bail!(
            "git clone failed for {}: {}",
            remote.display,
            git_output_summary(&output)
        );
    }
    // The publish. `rename` onto a path that does not exist — or onto the
    // empty directory tolerated above — is atomic, so no reader ever sees the
    // entry in a state the clone was still building. A rename that fails means
    // somebody else published one first, and installing from a tree this run
    // did not clone is exactly what the ownership proofs exist to prevent.
    if let Err(err) = std::fs::rename(&staging, &remote.cache_dir) {
        let _ = std::fs::remove_dir_all(&staging);
        return Err(refusal(
            remote,
            &format!(
                "its cache entry could not be published ({err}); retry once no other vstack process is adding it"
            ),
        ));
    }
    // Nothing to fetch — the clone IS the newest revision — and everything to
    // hold: the caller discovers, hashes and copies out of this tree next.
    let (attempt, lease) = config::lease_cached_source(remote)?;
    attempt.report(remote);
    Ok(lease)
}

/// The `git clone` that mints a fresh cache entry. The destination is named on
/// the command line, so this one runs from the cache root.
/// `dest` is the directory git writes into, which is the staging path rather
/// than the entry itself — see [`clone_cached_repo`].
pub(crate) fn cache_clone_command(
    remote: &RemoteSource,
    dest: &Path,
) -> Result<std::process::Command> {
    let mut command = hardened_git_network_command(&remote_cache_root())?;
    // `--` so a URL is never read as an option, whatever it starts with.
    command.args(["clone", "--depth", "1", "--", &remote.git_url]);
    command.arg(dest);
    Ok(command)
}

#[cfg(test)]
mod tests;
