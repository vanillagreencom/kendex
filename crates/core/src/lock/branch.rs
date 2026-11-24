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
/// `scope` is a checkout on that branch behind it with nothing of its own.
/// `None` where no such pull applies: a copy with commits of its own is
/// one `--ff-only` refuses, and a copy at origin's commit has nothing to
/// pull. Read from the objects the clone holds; nothing is fetched. The
/// copy goes through the decoder the file on disk does, so one this build
/// cannot read is the refusal that file would get.
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
    let counted = Hardened::git(&count, Some(&root)).run()?;
    if !counted.status.success() {
        return Err(git_failed(&count, &counted));
    }
    let said = String::from_utf8_lossy(&counted.stdout);
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
    // `./` resolves against the project root git runs in, which a project
    // in a subdirectory of its repository needs.
    let lock = crate::env::Env::project_lock_file(&root);
    let Some(object) = resolved(&root, &format!("{upstream}:./{}", super::LOCK_FILE))? else {
        return Ok(Some(LockFile::Absent));
    };
    let read = ["cat-file", "blob", object.as_str()];
    let blob = Hardened::git(&read, Some(&root)).run()?;
    if !blob.status.success() {
        return Err(git_failed(&read, &blob));
    }
    let text = String::from_utf8(blob.stdout).map_err(|_| CoreError::LockCorrupt {
        path: lock.clone(),
        message: format!("the copy at {upstream} is not UTF-8"),
    })?;
    super::parse_text(&lock, &text).map(|lock| Some(LockFile::Current(lock)))
}

/// The object `spec` names, or `None` where it names none: `--quiet`
/// makes exit 1 that answer alone, for a missing ref and a path the
/// revision does not hold alike; any other failure is git's.
fn resolved(root: &Path, spec: &str) -> Result<Option<String>> {
    let args = ["rev-parse", "--verify", "--quiet", spec];
    let output = Hardened::git(&args, Some(root)).run()?;
    match output.status.code() {
        Some(0) => Ok(Some(
            String::from_utf8_lossy(&output.stdout).trim().to_owned(),
        )),
        Some(1) => Ok(None),
        _ => Err(git_failed(&args, &output)),
    }
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

fn git_failed(args: &[&str], output: &std::process::Output) -> CoreError {
    CoreError::GitFailed {
        command: format!("git {}", args.join(" ")),
        stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
    }
}

/// The ref `name` points at, or `None` where it is no symbolic ref: a
/// detached HEAD, or a remote HEAD the clone never recorded. `--quiet`
/// makes exit 1 that answer alone; any other failure is git's.
fn symbolic_ref(root: &Path, name: &str) -> Result<Option<String>> {
    let args = ["symbolic-ref", "--quiet", name];
    let output = Hardened::git(&args, Some(root)).run()?;
    match output.status.code() {
        Some(0) => Ok(Some(
            String::from_utf8_lossy(&output.stdout)
                .trim_end()
                .to_owned(),
        )),
        Some(1) => Ok(None),
        _ => Err(git_failed(&args, &output)),
    }
}
