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
    let records_on = match symbolic_ref(&root, REMOTE_HEAD)? {
        Some(target) => match target.strip_prefix(REMOTE_BRANCHES) {
            Some(branch) => branch.to_owned(),
            // git points the remote HEAD at one of the remote's own
            // branches; one set by hand to anything else names no branch
            // the record could be written on.
            None => {
                return Err(CoreError::GitFailed {
                    command: format!("git symbolic-ref --quiet {REMOTE_HEAD}"),
                    stderr: format!("it names {target}, which is not a branch of origin"),
                });
            }
        },
        None => FALLBACK_BRANCH.to_owned(),
    };
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
        _ => Err(CoreError::GitFailed {
            command: format!("git {}", args.join(" ")),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        }),
    }
}
