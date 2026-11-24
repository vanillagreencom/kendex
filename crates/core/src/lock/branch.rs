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
//! The same reading of the default branch answers whether a checkout on
//! it is behind origin's copy, which decides the fix the check names for
//! a package that reads behind ([`behind_default`]).

use std::path::Path;

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

/// Whether `scope` is a checkout on the default branch that origin's copy
/// of that branch, as this clone last fetched it, is ahead of with nothing
/// of its own to keep: a copy that follows the default branch and has not
/// pulled yet. Its fix is the pull, since a refresh here would write a
/// record the next pull brings anyway. Read from the refs the clone holds;
/// nothing is fetched. A copy with commits of its own is not behind in
/// this sense, because `git pull --ff-only` refuses it.
pub fn behind_default(scope: &Scope) -> Result<bool> {
    let Scope::Project { root } = scope.canonical() else {
        return Ok(false);
    };
    if crate::guard::Repo::probe(&root)?.is_none() {
        return Ok(false);
    }
    let branch = default_branch(&root)?;
    if symbolic_ref(&root, "HEAD")?.as_deref() != Some(&format!("{LOCAL_BRANCHES}{branch}")) {
        return Ok(false);
    }
    let upstream = format!("{REMOTE_BRANCHES}{branch}");
    let probe = ["rev-parse", "--verify", "--quiet", upstream.as_str()];
    let found = Hardened::git(&probe, Some(&root)).run()?;
    match found.status.code() {
        Some(0) => {}
        Some(1) => return Ok(false),
        _ => return Err(git_failed(&probe, &found)),
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
        (Some(Ok(ahead)), Some(Ok(behind)), None) => Ok(ahead == 0 && behind > 0),
        _ => Err(CoreError::GitFailed {
            command: format!("git {}", count.join(" ")),
            stderr: format!("it printed {:?}, not two counts", said.trim()),
        }),
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
