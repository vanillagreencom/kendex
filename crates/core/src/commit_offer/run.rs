//! What each choice runs, and what it leaves behind when a step refuses.
//!
//! `git commit --only -- <paths>` is a partial commit, and five of its
//! behaviours decide the shape here. It refuses a path git does not track,
//! so the untracked members are staged first. It commits the working
//! tree's content for the named paths, not the index's, so a person who
//! staged an older copy of a render gets the copy kendex wrote. It commits
//! a deletion of a named path that is gone, which is how a sweep's
//! removals land. It builds a temporary index and exports it to the hooks,
//! so a hook running `git diff --cached` sees the named paths and nothing
//! else and a refused commit leaves the person's own staged changes
//! exactly as they were. And it commits the whole of each file it names,
//! which is why the shared `edits` targets are out of the set.

use std::path::Path;

use crate::engine::GeneratedPaths;
use crate::process::Hardened;

use super::pathspec::Spec;
use super::pending::Selection;
use super::{Failed, Refusal, Step, git};

/// What the commit did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Committed {
    /// The re-read set was empty: the files changed since the offer, so
    /// there was nothing left to commit and no commit was made.
    Nothing,
    Made {
        /// The short name of the commit, for the line that reports it.
        sha: String,
        files: usize,
        /// Paths the selection named that the re-read set no longer covers:
        /// they changed back, or kendex stopped owning them, between the
        /// offer being drawn and the commit running. Named rather than
        /// dropped in silence — the person chose them.
        dropped: Vec<String>,
    },
}

/// What a push did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pushed {
    pub remote: String,
    pub branch: String,
}

/// What opening a pull request did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Opened {
    pub url: String,
}

/// The commit sequence: stage the selection's untracked members, then
/// commit the selection.
///
/// The set is re-derived immediately before the commit runs, and the
/// selection is narrowed to it. A path that no longer differs is reported as
/// dropped rather than committed, and when none is left the run reports that
/// nothing was committed rather than making an empty one. That re-read is
/// what makes [`Selection::Only`] true: the paths committed are exactly the
/// ones named, so a commit labelled as one action's work carries that work
/// and no other pending path.
///
/// It cannot make the commit narrower than a whole file. Where the same file
/// carries both the action's change and an earlier one, both go in, and
/// [`super::Pending::tangled`] is what names that before a person chooses.
///
/// The one mark a refusal leaves is the `git add`: a path that was
/// untracked stays staged. kendex unstages exactly the paths it staged, so
/// the index ends as it began. It unstages with `git reset`, not `git
/// restore --staged`, which resolves `HEAD` and exits 128 in a repository
/// with no commit yet — the state a first kendex write in a fresh `git
/// init` reaches whenever a hook refuses that first commit.
pub fn commit(
    root: &Path,
    generated: &GeneratedPaths,
    message: &str,
    selection: &Selection,
) -> Result<Committed, CommitFailure> {
    let Some(scan) = super::paths::scan(root, generated).map_err(CommitFailure::from)? else {
        return Ok(Committed::Nothing);
    };
    let (taken, dropped) = selection.over(&scan.owned);
    if taken.is_empty() {
        return Ok(Committed::Nothing);
    }
    let files = taken.len();
    let untracked: Vec<String> = taken
        .iter()
        .filter(|owned| owned.untracked)
        .map(|owned| owned.path.clone())
        .collect();
    let all: Vec<String> = taken.iter().map(|owned| owned.path.clone()).collect();
    stage(root, &untracked).map_err(CommitFailure::from)?;
    match make(root, &all, message) {
        Ok(()) => Ok(Committed::Made {
            sha: git::head_short(root).map_err(CommitFailure::from)?,
            files,
            dropped,
        }),
        Err(failed) => Err(CommitFailure {
            // Both facts reach the person: the refusal that stopped the
            // commit, and — where the cleanup could not put the index back
            // — that kendex own paths are still staged.
            still_staged: unstage(root, &untracked).err().map(|_| untracked.len()),
            failed,
        }),
    }
}

/// A commit that did not happen, and what it left behind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitFailure {
    pub failed: Failed,
    /// How many paths kendex staged and could not then unstage. They are
    /// still staged, against the rule that the index ends as it began.
    pub still_staged: Option<usize>,
}

impl From<Failed> for CommitFailure {
    fn from(failed: Failed) -> CommitFailure {
        CommitFailure {
            failed,
            still_staged: None,
        }
    }
}

fn stage(root: &Path, untracked: &[String]) -> Result<(), Failed> {
    if untracked.is_empty() {
        return Ok(());
    }
    let spec = Spec::write(untracked, Step::Stage)?;
    let mut args = vec!["add".to_owned()];
    args.extend(spec.args());
    git::run(Hardened::git(&borrowed(&args), Some(root)), Step::Stage)?;
    Ok(())
}

fn make(root: &Path, all: &[String], message: &str) -> Result<(), Failed> {
    let spec = Spec::write(all, Step::Commit)?;
    let mut args = vec!["commit".to_owned(), "--only".to_owned()];
    args.extend(spec.args());
    args.push("-m".to_owned());
    args.push(message.to_owned());
    git::run(Hardened::git(&borrowed(&args), Some(root)), Step::Commit)?;
    Ok(())
}

/// Put the index back the way it was. A cleanup that itself refuses leaves
/// kendex's own paths staged, against the rule that the index ends as it
/// began, so it is reported rather than swallowed under the refusal that
/// led to it.
fn unstage(root: &Path, untracked: &[String]) -> Result<(), Failed> {
    if untracked.is_empty() {
        return Ok(());
    }
    let spec = Spec::write(untracked, Step::Unstage)?;
    let mut args = vec!["reset".to_owned(), "--quiet".to_owned()];
    args.extend(spec.args());
    git::run(Hardened::git(&borrowed(&args), Some(root)), Step::Unstage)?;
    Ok(())
}

/// Push the branch the commit landed on.
pub fn push(root: &Path, remote: &str, branch: &str, tracked: bool) -> Result<Pushed, Failed> {
    let mut args = vec!["push"];
    if !tracked {
        args.push("--set-upstream");
    }
    args.push(remote);
    args.push(branch);
    git::run(Hardened::git(&args, Some(root)), Step::Push)?;
    Ok(Pushed {
        remote: remote.to_owned(),
        branch: branch.to_owned(),
    })
}

/// Push a commit that already exists to a branch of its own, without
/// moving the branch it is on.
///
/// This is the recovery a refused push offers, and it pushes rather than
/// making a branch locally so it cannot fast-forward a branch somebody
/// else named: `<branch>` is picked by the first-free rule, and a name only
/// the remote knows about surfaces as a second refused push.
pub fn push_head(root: &Path, remote: &str, branch: &str) -> Result<Pushed, Failed> {
    git::run(
        Hardened::git(
            &["push", remote, &format!("HEAD:refs/heads/{branch}")],
            Some(root),
        ),
        Step::Push,
    )?;
    Ok(Pushed {
        remote: remote.to_owned(),
        branch: branch.to_owned(),
    })
}

/// Move the checkout to the branch a pull request will be opened from,
/// before anything is committed — so the branch the person was on gains no
/// commit and needs nothing undone.
pub fn start_branch(root: &Path, branch: &str) -> Result<(), Failed> {
    git::run(
        Hardened::git(&["switch", "-c", branch], Some(root)),
        Step::Branch,
    )?;
    Ok(())
}

/// Put the checkout back and take away the branch kendex made a moment
/// earlier, after a commit on it refused.
///
/// Not an undo: no commit exists to undo, and no branch ref moves
/// backwards. It is kendex clearing its own leftover, the same as unstaging
/// its own `git add`. A step of it that fails is reported and the run stops
/// there rather than trying anything else.
pub fn abandon_branch(root: &Path, branch: &str) -> Result<(), Failed> {
    git::run(
        Hardened::git(&["switch", "-"], Some(root)),
        Step::SwitchBack,
    )?;
    git::run(
        Hardened::git(&["branch", "-d", branch], Some(root)),
        Step::RemoveBranch,
    )?;
    Ok(())
}

/// The pull request's body: two lines, no more.
pub fn body(files: usize) -> String {
    format!("kendex wrote these files.\nFiles: {files}")
}

/// Open the pull request. `--repo` binds it to the remote the offer chose,
/// so it cannot be opened against a repository the push never reached.
///
/// The title and body are passed rather than left out: `gh pr create` with
/// no terminal to prompt at refuses without them.
pub fn open_pull_request(
    repo: &str,
    head: &str,
    base: &str,
    title: &str,
    files: usize,
) -> Result<Opened, Failed> {
    let stdout = git::run(
        Hardened::gh(&[
            "pr",
            "create",
            "--repo",
            repo,
            "--head",
            head,
            "--base",
            base,
            "--title",
            title,
            "--body",
            &body(files),
        ]),
        Step::PullRequest,
    )?;
    // `gh` prints the pull request's URL on stdout. A `gh` that exits zero
    // and prints nothing is a pull request kendex cannot name, which is
    // that step failing to produce what it was asked for.
    let url = String::from_utf8_lossy(&stdout)
        .lines()
        .map(str::trim)
        .rfind(|line| !line.is_empty())
        .map(str::to_owned);
    match url {
        Some(url) => Ok(Opened { url }),
        None => Err(Failed {
            step: Step::PullRequest,
            refusal: Refusal::Said(vec!["gh reported no pull request address".to_owned()]),
        }),
    }
}

fn borrowed(args: &[String]) -> Vec<&str> {
    args.iter().map(String::as_str).collect()
}
