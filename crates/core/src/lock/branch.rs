//! Whether a check may write a project's committed install record where it
//! stands (D007).
//!
//! The record a project commits is written on the repository's default
//! branch, after each merge; a checkout on any other branch leaves it as
//! that branch holds it, because a record written there is stale the
//! moment another branch on the same package merges ahead of it. So the
//! settle `kendex check` makes for a copy it proved against its source
//! (D001) runs only where this answers [`Recording::Here`]. The rule keys
//! on the branch the checkout has checked out, never on whether it is a
//! linked worktree, so a standalone clone on a branch is covered too.
//!
//! The same reading of the default branch answers what record a pull of
//! origin's copy would bring a checkout on it, which decides the fix the
//! check names for a package that reads behind ([`pulled_record`]).

use std::path::Path;

use super::LockFile;
use crate::error::{CoreError, Result};
use crate::model::Scope;
use crate::process::Hardened;

/// The branch the record is kept on where the clone records no remote
/// HEAD.
const FALLBACK_BRANCH: &str = "main";

/// Where the default branch is read from: what `git clone` sets to the
/// branch the remote's own HEAD named.
const REMOTE_HEAD: &str = "refs/remotes/origin/HEAD";
const REMOTE_BRANCHES: &str = "refs/remotes/origin/";
const LOCAL_BRANCHES: &str = "refs/heads/";

/// Whether the committed record may be written from this checkout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Recording {
    /// The global scope, whose record is not committed; a project outside
    /// Git; or a checkout on the default branch.
    Here,
    /// A checkout of a Git repository whose HEAD is not the default
    /// branch, a detached HEAD included.
    Elsewhere(OffBranch),
}

/// What a checkout off the default branch has checked out, and the branch
/// the record is written on instead.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OffBranch {
    /// The branch HEAD names, or `None` for a detached HEAD.
    pub head: Option<String>,
    pub records_on: String,
}

/// The answer for `scope`. A git that cannot say whether the project is a
/// checkout, or what it has checked out, is an error rather than
/// [`Recording::Here`]: the write this gates is the one a wrong answer
/// makes.
pub fn recording(scope: &Scope) -> Result<Recording> {
    let Scope::Project { root } = scope.canonical() else {
        return Ok(Recording::Here);
    };
    if crate::guard::Repo::probe(&root)?.is_none() {
        return Ok(Recording::Here);
    }
    let records_on = default_branch(&root)?;
    let head = symbolic_ref(&root, "HEAD")?;
    if head.as_deref() == Some(&format!("{LOCAL_BRANCHES}{records_on}")) {
        return Ok(Recording::Here);
    }
    Ok(Recording::Elsewhere(OffBranch {
        head: head.map(|target| match target.strip_prefix(LOCAL_BRANCHES) {
            Some(branch) => branch.to_owned(),
            None => target,
        }),
        records_on,
    }))
}

/// The record `git pull --ff-only` would bring `scope`: the lock origin's
/// copy of the default branch holds, as this clone last fetched it, where
/// `scope` is a checkout on that branch strictly behind it whose lock is
/// the one `HEAD` commits. `None` where no such pull applies or the pull
/// would not bring origin's lock: a checkout on another branch or a
/// detached HEAD, where the pull would move another branch or refuse; a
/// copy with commits of its own, which `--ff-only` refuses; a copy at
/// origin's commit, with nothing to pull; and a lock git reports in
/// `git status` at all, untracked, ignored or changed since `HEAD`, which
/// the merge refuses to overwrite where origin changes the file
/// (git-read-tree(1), "Two Tree Merge") and leaves as it is where origin
/// does not. Read from the refs and objects the clone holds; nothing is
/// fetched. Origin's copy goes through the decoder the file on disk does,
/// so one this build cannot read is refused as that file would be, as
/// [`CoreError::OriginLockUnreadable`] naming the copy.
pub fn pulled_record(scope: &Scope) -> Result<Option<LockFile>> {
    let Scope::Project { root } = scope.canonical() else {
        return Ok(None);
    };
    if crate::guard::Repo::probe(&root)?.is_none() {
        return Ok(None);
    }
    let branch = default_branch(&root)?;
    if symbolic_ref(&root, "HEAD")?.as_deref() != Some(&format!("{LOCAL_BRANCHES}{branch}")) {
        return Ok(None);
    }
    let upstream = format!("{REMOTE_BRANCHES}{branch}");
    if resolved(&root, &upstream)?.is_none() {
        return Ok(None);
    }
    let range = format!("HEAD...{upstream}");
    let count = ["rev-list", "--left-right", "--count", range.as_str()];
    let counted = run(&root, &count)?;
    let said = String::from_utf8_lossy(&counted);
    let mut sides = said.split_whitespace().map(str::parse::<u64>);
    match (sides.next(), sides.next(), sides.next()) {
        (Some(Ok(0)), Some(Ok(behind)), None) if behind > 0 => {}
        (Some(Ok(_)), Some(Ok(_)), None) => return Ok(None),
        _ => {
            return Err(CoreError::GitFailed {
                command: format!("git {}", count.join(" ")),
                stderr: format!("it printed {:?}, not two counts", said.trim()),
            });
        }
    }
    // `./` resolves against the directory git runs in (gitrevisions(7),
    // "<rev>:<path>"; a pathspec likewise), which is the project root,
    // and a project in a subdirectory of its repository keeps its lock
    // there rather than at the repository's top.
    let path = format!("./{}", super::LOCK_FILE);
    // Without `--no-optional-locks` the read may take the index lock to
    // refresh it, which a git command the person runs meanwhile meets.
    let status = [
        "--no-optional-locks",
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
        "--ignored",
        "--",
        path.as_str(),
    ];
    if !run(&root, &status)?.is_empty() {
        return Ok(None);
    }
    let copy = format!("{upstream}:{path}");
    let Some(object) = resolved(&root, &copy)? else {
        return Ok(Some(LockFile::Absent));
    };
    let blob = run(&root, &["cat-file", "blob", object.as_str()])?;
    let unreadable = |reason: String| CoreError::OriginLockUnreadable {
        copy: copy.clone(),
        reason,
    };
    let text = String::from_utf8(blob).map_err(|_| unreadable("it is not UTF-8".to_owned()))?;
    // Decoded against the local lock's path, which places the record's
    // positions under this project as the file on disk would be, so a
    // refusal from it names that file and the fix for it: told apart here
    // by its kind, it names origin's copy and the decoder's reason alone.
    let lock = crate::env::Env::project_lock_file(&root);
    super::parse_text(&lock, &text)
        .map(|lock| Some(LockFile::Current(lock)))
        .map_err(|error| match error {
            CoreError::LockCorrupt { message, .. } => unreadable(message),
            CoreError::SchemaTooNew { found, .. } => {
                unreadable(format!("it was written by a newer kendex (format {found})"))
            }
            CoreError::LegacyProjectLock { .. } => {
                unreadable("it is a version 10 record".to_owned())
            }
            CoreError::LockOutsideProject { key, recorded, .. } => unreadable(format!(
                "it records {key} at {}, outside the project",
                recorded.display()
            )),
            // The read of this machine's half beside the local lock, whose
            // fault is that local file's.
            other => other,
        })
}

/// The branch the record is kept on: the one the remote HEAD names.
fn default_branch(root: &Path) -> Result<String> {
    match symbolic_ref(root, REMOTE_HEAD)? {
        Some(target) => match target.strip_prefix(REMOTE_BRANCHES) {
            Some(branch) => Ok(branch.to_owned()),
            // git points the remote HEAD at one of the remote's own
            // branches; one set by hand to anything else names no branch
            // the record could be written on.
            None => Err(CoreError::GitFailed {
                command: format!("git symbolic-ref --quiet {REMOTE_HEAD}"),
                stderr: format!("it names {target}, which is not a branch of origin"),
            }),
        },
        None => Ok(FALLBACK_BRANCH.to_owned()),
    }
}

/// What a git command that must succeed printed.
fn run(root: &Path, args: &[&str]) -> Result<Vec<u8>> {
    let output = Hardened::git(args, Some(root)).run()?;
    match output.status.success() {
        true => Ok(output.stdout),
        false => Err(git_failed(args, &output)),
    }
}

fn git_failed(args: &[&str], output: &std::process::Output) -> CoreError {
    CoreError::GitFailed {
        command: format!("git {}", args.join(" ")),
        stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
    }
}

/// The ref `name` points at, or `None` where it is no symbolic ref: a
/// detached HEAD, or a remote HEAD the clone never recorded.
fn symbolic_ref(root: &Path, name: &str) -> Result<Option<String>> {
    quiet_answer(root, &["symbolic-ref", "--quiet", name])
}

/// The object `spec` names, or `None` where it names none: a missing ref,
/// or a path the revision does not hold.
fn resolved(root: &Path, spec: &str) -> Result<Option<String>> {
    quiet_answer(root, &["rev-parse", "--verify", "--quiet", spec])
}

/// The line a `--quiet` git read prints, or `None` where it exits 1, which
/// `--quiet` makes the answer "there is none" alone; any other failure is
/// git's.
fn quiet_answer(root: &Path, args: &[&str]) -> Result<Option<String>> {
    let output = Hardened::git(args, Some(root)).run()?;
    match output.status.code() {
        Some(0) => Ok(Some(
            String::from_utf8_lossy(&output.stdout)
                .trim_end()
                .to_owned(),
        )),
        Some(1) => Ok(None),
        _ => Err(git_failed(args, &output)),
    }
}
