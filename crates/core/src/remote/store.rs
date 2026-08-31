//! The per-commit source store: cache layout, the repository cache lock,
//! mirrors, and the checkouts published out of them.
//!
//! A downloaded catalog is never a mutable checkout. Each commit is
//! materialized once into a directory named after its object id, published
//! by rename, and read unchanged forever after. Fetching touches only the
//! bare mirror, so a refresh in one window cannot move bytes under a render
//! running in another — and two scopes pinning different revisions of one
//! repository each read their own directory instead of fighting over one.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::fs::atomic_write;
use crate::process::Hardened;

mod attribute_source;
mod signature;

pub use signature::tree_signature;

/// Where the fetched objects live: one bare mirror per repository.
const MIRRORS: &str = "mirrors";
/// Where the readable trees live: one directory per commit.
const COMMITS: &str = "commits";
/// Where the per-repository cache locks live.
const LOCKS: &str = "locks";

/// A commit pin is the full object id and nothing shorter. Anything else —
/// a tag, a branch, an abbreviated id — is a tracking selector that
/// re-resolves on every refresh, which is exactly what an abbreviation
/// should do: it is a name for a commit, not a promise about one.
pub fn is_pin(rev: &str) -> bool {
    rev.len() == 40 && rev.chars().all(|c| c.is_ascii_hexdigit())
}

/// Filesystem-safe key naming one repository's mirror, checkouts, and lock.
/// Keyed off the clone URL rather than the declared shorthand, so the same
/// repository reached by two spellings shares one mirror, and two hosts
/// serving the same `owner/repo` never share anything. The endings that say
/// nothing about which repository it is — a trailing slash, a `.git` suffix
/// — come off first, so writing one out in full does not fetch a second
/// copy of what a shorthand already downloaded.
pub fn repo_key(url: &str) -> String {
    let url = url.trim_end_matches('/');
    let url = url.strip_suffix(".git").unwrap_or(url);
    let base: String = url
        .rsplit(['/', ':'])
        .next()
        .unwrap_or("repo")
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .take(32)
        .collect();
    format!(
        "{}-{}",
        if base.is_empty() { "repo" } else { &base },
        crate::hash::fnv1a_hex(url.as_bytes())
    )
}

pub fn mirror_dir(env: &Env, key: &str) -> PathBuf {
    env.source_cache_dir()
        .join(MIRRORS)
        .join(format!("{key}.git"))
}

pub fn checkout_dir(env: &Env, key: &str, commit: &str) -> PathBuf {
    env.source_cache_dir().join(COMMITS).join(key).join(commit)
}

pub(super) fn receipt_path(env: &Env, key: &str, commit: &str) -> PathBuf {
    env.source_cache_dir()
        .join(COMMITS)
        .join(key)
        .join(format!("{commit}.published"))
}

/// Where cached safety scores for one published commit live — beside the
/// commit's receipt, never inside its tree: a write into the checkout would
/// break the tree signature the receipt vouches for.
pub fn safety_cache_dir(env: &Env, key: &str, commit: &str) -> PathBuf {
    env.source_cache_dir()
        .join(COMMITS)
        .join(key)
        .join(format!("{commit}.safety"))
}

/// Exclusive lock over one repository's cache entry. Only materialization
/// takes it — reading a published checkout needs no lock, because a
/// published checkout never changes.
pub struct CacheGuard {
    _file: crate::fs::LockedFile,
}

impl CacheGuard {
    /// Test-only view of the fd, for cloning a description copy.
    #[cfg(test)]
    pub(crate) fn file(&self) -> &fs::File {
        self._file.file()
    }
}

/// How long a resolver waits for the lock before calling the cache busy.
/// Long enough to ride out a neighbour holding it for one quick step — a
/// fetch stamp, publishing an already-materialized checkout — and far too
/// short to leave anyone waiting on someone else's download.
const LOCK_WAIT: Duration = Duration::from_millis(500);
const LOCK_POLL: Duration = Duration::from_millis(10);

pub fn lock_repo(env: &Env, key: &str) -> Result<CacheGuard> {
    let dir = env.source_cache_dir().join(LOCKS);
    fs::create_dir_all(&dir).map_err(|e| CoreError::io(&dir, e))?;
    let path = dir.join(format!("{key}.lock"));
    let deadline = Instant::now() + LOCK_WAIT;
    loop {
        match crate::fs::LockedFile::try_exclusive(&path) {
            Ok(Some(file)) => return Ok(CacheGuard { _file: file }),
            Ok(None) if Instant::now() >= deadline => {
                return Err(CoreError::CacheBusy { lock: path });
            }
            Ok(None) => std::thread::sleep(LOCK_POLL),
            // A filesystem that cannot lock at all is its own failure;
            // waiting out the deadline would misname it "busy".
            Err(error) => return Err(CoreError::io(&path, error)),
        }
    }
}

fn run(git: Hardened) -> Result<()> {
    let command = git.label().to_owned();
    let output = git.run()?;
    if output.status.success() {
        Ok(())
    } else {
        Err(CoreError::GitFailed {
            command,
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        })
    }
}

fn stdout(git: Hardened) -> Option<String> {
    let output = git.run().ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
        .filter(|text| !text.is_empty())
}

/// Clone the mirror if it is missing. A mirror holds objects and refs only,
/// so nothing here can write outside the cache.
///
/// An empty `--template` is the third attribute source, and the last one
/// the host still had. A template directory — the host's `init.templateDir`
/// or `GIT_TEMPLATE_DIR` — is copied into every repository git creates,
/// and one holding `info/attributes` lands it inside the mirror, where no
/// setting on the checkout reaches it: `core.attributesFile=` is the
/// global file, `GIT_ATTR_NOSYSTEM` the system one, and an attribute
/// source names a tree, not a file beside the object store. Measured: with
/// `* text eol=crlf` in a template, a mirror cloned without this converts
/// the checkout even with the attribute source pinned. Emptied, git copies
/// no template at all and the mirror carries no `info` directory.
pub fn ensure_mirror(mirror: &Path, url: &str) -> Result<()> {
    if mirror.join("HEAD").is_file() {
        return Ok(());
    }
    if let Some(parent) = mirror.parent() {
        fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
    }
    // A half-written mirror from an interrupted clone would fail every
    // later fetch; git refuses to clone onto an existing directory, so the
    // remains go first.
    if mirror.exists() {
        fs::remove_dir_all(mirror).map_err(|e| CoreError::io(mirror, e))?;
    }
    run(Hardened::git(
        &[
            "clone",
            "--quiet",
            "--mirror",
            "--template=",
            url,
            &mirror.display().to_string(),
        ],
        None,
    ))
}

/// Update every ref, following tags that moved upstream — a mirror's
/// refspec is forced, so a moved tag lands here and is previewed like any
/// other upstream change.
///
/// This is the one somebody sits and waits for: the mirror already exists,
/// so an update is a small transfer, and a link that cannot manage it in
/// half a minute is a link to report rather than keep waiting on. The first
/// clone keeps the long timeout — that one really can be slow.
pub fn fetch(mirror: &Path) -> Result<()> {
    fetch_within(mirror, crate::process::INTERACTIVE_TIMEOUT)
}

/// [`fetch`] with the caller's own deadline — the detached background
/// refresh allows more than an interactive wait but still must finish.
pub fn fetch_within(mirror: &Path, timeout: Duration) -> Result<()> {
    run(Hardened::git_bare(mirror, &["fetch", "--prune", "--quiet"]).timeout(timeout))
}

/// The commit a selector names right now, read from the mirror alone.
/// `None` means the mirror cannot answer — an unknown ref, or no mirror.
pub fn resolve_ref(mirror: &Path, selector: &str) -> Option<String> {
    stdout(Hardened::git_bare(
        mirror,
        &[
            "rev-parse",
            "--verify",
            "--quiet",
            &format!("{selector}^{{commit}}"),
        ],
    ))
}

/// Every branch and tag the mirror holds, as full ref names — what a tree
/// URL's `<ref>/<path>` split resolves against. `None` when the mirror
/// cannot answer at all, which callers must treat as "cannot normalize",
/// never as an empty repository.
pub fn ref_names(mirror: &Path) -> Option<Vec<String>> {
    let output = Hardened::git_bare(
        mirror,
        &[
            "for-each-ref",
            "--format=%(refname)",
            "refs/heads",
            "refs/tags",
        ],
    )
    .run()
    .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .map(str::to_owned)
            .collect(),
    )
}

pub fn has_commit(mirror: &Path, commit: &str) -> bool {
    Hardened::git_bare(mirror, &["cat-file", "-e", &format!("{commit}^{{commit}}")])
        .run()
        .is_ok_and(|output| output.status.success())
}

/// The materialization rules a receipt vouches for, beside the signature.
/// A signature alone says the bytes are the ones that were written, never
/// that they are the ones `check_out` writes now. The number rises
/// whenever `check_out` changes what it writes for a commit.
const RECEIPT_RULES: &str = "kendex-checkout 2";

/// A published checkout, if the cache holds this commit unmodified under
/// today's materialization rules. A mismatch is not an error, an
/// unreadable or unrecognized receipt included: the caller re-materializes
/// from the mirror.
pub fn published(env: &Env, key: &str, commit: &str) -> Option<PathBuf> {
    let dir = checkout_dir(env, key, commit);
    if !dir.is_dir() {
        return None;
    }
    let recorded = fs::read_to_string(receipt_path(env, key, commit)).ok()?;
    let (rules, signature) = recorded.split_once('\n')?;
    (rules == RECEIPT_RULES && signature.trim() == tree_signature(&dir).ok()?).then_some(dir)
}

/// Materialize a commit and publish it atomically. The checkout is built in
/// a staging sibling and renamed into place, so an interrupted or failed
/// publish leaves no directory anyone could read: not a partial one, and
/// not the one it was replacing.
///
/// Every caller holds this repository's cache lock across the call, and
/// this takes none of its own: an OS lock belongs to the open file
/// description, so taking one here would report the caller's own as busy.
pub fn publish(env: &Env, key: &str, mirror: &Path, commit: &str) -> Result<PathBuf> {
    // Callers test `published` before taking the lock, so the commit can
    // arrive while this one waits. Publishing over it would move a
    // directory out from under whoever the first publisher handed it to.
    if let Some(dir) = published(env, key, commit) {
        return Ok(dir);
    }
    let dir = checkout_dir(env, key, commit);
    let parent = dir.parent().unwrap_or(&dir).to_path_buf();
    fs::create_dir_all(&parent).map_err(|e| CoreError::io(&parent, e))?;
    let staging = parent.join(format!(".staging-{}", std::process::id()));
    if staging.exists() {
        fs::remove_dir_all(&staging).map_err(|e| CoreError::io(&staging, e))?;
    }
    let replaced = parent.join(format!(".replaced-{}", std::process::id()));
    let _ = fs::remove_dir_all(&replaced);
    // Two trees of one commit can share a signature, so the order is what
    // keeps a receipt from vouching for the directory it replaces: the old
    // directory leaves view, the receipt lands, the new directory lands. A
    // reader that sees a directory always finds the receipt for it, and in
    // between sees none, which reads as a miss.
    let result = check_out(&staging, mirror, commit)
        .and_then(|()| tree_signature(&staging))
        .and_then(|signature| {
            if dir.exists() {
                fs::rename(&dir, &replaced).map_err(|e| CoreError::io(&dir, e))?;
            }
            atomic_write(
                &receipt_path(env, key, commit),
                &format!("{RECEIPT_RULES}\n{signature}\n"),
            )
        });
    if let Err(error) = result {
        let _ = fs::remove_dir_all(&staging);
        // What was here is out of view under a receipt that may name the
        // tree that never landed, so it goes too: the mirror rebuilds it.
        let _ = fs::remove_dir_all(&replaced);
        return Err(error);
    }
    fs::rename(&staging, &dir).map_err(|e| CoreError::io(&dir, e))?;
    let _ = fs::remove_dir_all(&replaced);
    Ok(dir)
}

/// Write one commit's tree into `into`, using the mirror's index as scratch
/// — the only file in the mirror this touches. `git worktree` is
/// deliberately unused: it would leave admin state in the mirror and a
/// `.git` pointer inside a directory that is meant to be plain content.
///
/// The catalog's own `.gitattributes` decides nothing about what lands
/// either: the write reads its attributes out of the tree
/// [`attribute_source`] names instead of out of the commit, so no rule the
/// source committed is in force for any path. `process::MATERIALISING`
/// says why the host half is settled where it is and this half is an
/// argument.
fn check_out(into: &Path, mirror: &Path, commit: &str) -> Result<()> {
    let attributes = attribute_source::for_commit(commit)?;
    fs::create_dir_all(into).map_err(|e| CoreError::io(into, e))?;
    run(Hardened::git_bare(mirror, &["read-tree", commit]))?;
    run(Hardened::git_into(
        mirror,
        into,
        attributes,
        &["checkout-index", "--all", "--force"],
    ))
}
