//! The desktop's half of the commit, push and pull-request offer: the read
//! that says what one project has to offer, and one command per step the
//! window can run.
//!
//! A step each rather than a command per route, because the window draws
//! the step that is running and has its own designed state for each way one
//! can refuse. Every command here is a thin pass to
//! [`kendex_core::commit_offer`], which both shells share, so the window
//! cannot offer something the terminal would refuse.
//!
//! Nothing here words anything. A refusal travels as the program's own
//! lines and the step that produced them, and `ui/src/lib/copy-commit-offer.ts`
//! is where every sentence the window shows lives.

use std::path::{Path, PathBuf};

use kendex_core::commit_offer::{
    self, Branch, Changes, Committed, Failed, Offer, Probe, Step, Unavailable,
};
use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::package::diff::PackageDiff;
use serde::Serialize;
use specta::Type;

use crate::scopes::env;

/// Why a choice is not on offer, for the labelled row the window draws
/// under the segments.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Why {
    NoRemote,
    RemoteNotDecidable,
    GhMissing,
    /// gh's own first line, so a case nobody anticipated still names
    /// itself rather than reading as one kendex knows.
    GhSaid {
        line: String,
    },
}

impl From<&Unavailable> for Why {
    fn from(why: &Unavailable) -> Why {
        match why {
            Unavailable::NoRemote => Why::NoRemote,
            Unavailable::RemoteNotDecidable => Why::RemoteNotDecidable,
            Unavailable::GhMissing => Why::GhMissing,
            Unavailable::GhSaid(line) => Why::GhSaid { line: line.clone() },
        }
    }
}

/// One project's offer, everything the dialog draws it from.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ProjectOffer {
    pub root: String,
    /// The project's folder name, which the title names.
    pub name: String,
    /// The files kendex owns whole that changed, printed whole: an
    /// abbreviation guesses at a directory and names a different file from
    /// the one being committed.
    pub files: Vec<String>,
    /// The shared configuration files kendex writes one key in.
    pub shared: Vec<String>,
    /// How many of the person's own files changed.
    pub others: u32,
    pub branch: String,
    pub remote: Option<String>,
    /// `null` where the choice stands; the reason otherwise.
    pub push: Option<Why>,
    pub pull_request: Option<Why>,
    /// The pull request already open for this branch.
    pub open_number: Option<u32>,
    pub message: String,
    pub new_branch: String,
    /// The repository every `gh` call is bound to, from the chosen remote.
    pub repo: Option<String>,
    /// The branch already tracks the chosen remote, so a push needs no
    /// `--set-upstream`.
    pub tracked: bool,
}

/// A project where kendex owns changed files and the offer cannot be made.
/// The window flags it on the project's card rather than opening a dialog
/// that offers nothing.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ProjectFlag {
    pub root: String,
    pub count: u32,
    pub reason: FlagReason,
}

#[derive(Debug, Clone, Serialize, Type)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum FlagReason {
    NoBranch,
    /// The operation as a line names it: `a rebase`.
    InProgress {
        operation: String,
    },
    /// A read the offer is built from would not run, so nothing about this
    /// project can be claimed.
    Unreadable {
        said: Vec<String>,
    },
}

/// What one read of every project the write could reach found.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CommitOfferScan {
    pub offers: Vec<ProjectOffer>,
    pub flagged: Vec<ProjectFlag>,
}

/// A step that did not go through.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Refused {
    /// The step, as its own line names it.
    pub step: String,
    /// The program's own words, whole, in order. Empty where the step ran
    /// out of time and said nothing.
    pub said: Vec<String>,
    pub timed_out: bool,
    /// The bound in whole seconds, for the line a timeout draws.
    pub seconds: u32,
    /// Whether the words are `gh`'s rather than git's.
    pub gh: bool,
}

impl From<&Failed> for Refused {
    fn from(failed: &Failed) -> Refused {
        Refused {
            step: failed.step.name().to_owned(),
            said: failed.said().to_vec(),
            timed_out: failed.timed_out(),
            seconds: whole(failed.step.seconds()),
            gh: matches!(failed.step, Step::Probe | Step::PullRequest),
        }
    }
}

/// What the commit did.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum CommitStep {
    /// The re-read set was empty: the files changed since the offer.
    Nothing,
    Made {
        sha: String,
        files: u32,
    },
    Refused {
        refused: Refused,
        /// Paths kendex staged and could not then unstage. They are still
        /// staged, against the rule that the index ends as it began.
        #[serde(rename = "stillStaged")]
        still_staged: Option<u32>,
    },
}

/// The file's mode on each side, in git's own spelling, where the commit
/// changes it.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct FileMode {
    pub before: String,
    pub after: String,
}

/// What the window has to show for one file the offer covers.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum FileChanges {
    /// What the commit carries for this file: the two sides' contents
    /// compared, and the mode change beside it where there is one. An
    /// empty comparison with a mode change is a file whose text does not
    /// move; an empty one with neither is a file that changed back since
    /// the offer was read.
    Shown {
        diff: PackageDiff,
        mode: Option<FileMode>,
    },
    /// The offer no longer covers this path: the file has changed back, or
    /// a sweep has taken it, since the offer was read. Nothing to show, and
    /// nothing wrong.
    Nothing,
    /// A read the comparison is built from would not run.
    Refused { refused: Refused },
}

/// What one of the other steps did.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum StepResult {
    Done,
    Refused { refused: Refused },
}

/// What opening the pull request did.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum OpenResult {
    Opened { url: String },
    Refused { refused: Refused },
}

impl From<Result<(), Failed>> for StepResult {
    fn from(result: Result<(), Failed>) -> StepResult {
        match result {
            Ok(()) => StepResult::Done,
            Err(failed) => StepResult::Refused {
                refused: Refused::from(&failed),
            },
        }
    }
}

fn read(env: &Env, root: &Path) -> Result<Option<Result<ProjectOffer, ProjectFlag>>, String> {
    let scope = Scope::Project {
        root: root.to_owned(),
    };
    // The setting turns off the asking, and the window has no flag that
    // could answer instead, so nothing is read at all when it is off.
    if !commit_offer::asking(env) {
        return Ok(None);
    }
    let scan = match commit_offer::scan(&scope, &generated(env, &scope)?) {
        Ok(None) => return Ok(None),
        Ok(Some(scan)) => scan,
        Err(failed) => {
            return Ok(Some(Err(ProjectFlag {
                root: shown(root),
                count: 0,
                reason: FlagReason::Unreadable {
                    said: failed.said().to_vec(),
                },
            })));
        }
    };
    let flag = |reason: FlagReason| ProjectFlag {
        root: shown(root),
        count: counted(scan.count()),
        reason,
    };
    match &scan.branch {
        Branch::Detached => return Ok(Some(Err(flag(FlagReason::NoBranch)))),
        Branch::InProgress(operation) => {
            let operation = operation.article().to_owned();
            return Ok(Some(Err(flag(FlagReason::InProgress { operation }))));
        }
        Branch::On(_) => {}
    }
    // The window's write is not a typed command, so the message names the
    // shell the person is in rather than a verb they typed.
    match commit_offer::offer(scan, COMMAND, Probe::Gh) {
        Ok(offer) => Ok(Some(Ok(drawn(root, offer)))),
        Err(failed) => Ok(Some(Err(ProjectFlag {
            root: shown(root),
            count: 0,
            reason: FlagReason::Unreadable {
                said: failed.said().to_vec(),
            },
        }))),
    }
}

/// What the default message names when the write came from the window.
/// The rule is the command, and in the app the command is the app.
const COMMAND: &str = "app";

fn drawn(root: &Path, offer: Offer) -> ProjectOffer {
    ProjectOffer {
        root: shown(root),
        name: root
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| shown(root)),
        files: offer
            .scan
            .owned
            .iter()
            .map(|owned| owned.path.clone())
            .collect(),
        shared: offer.scan.shared.clone(),
        others: counted(offer.scan.others),
        push: offer.push.as_ref().err().map(Why::from),
        pull_request: offer.pull_request.as_ref().err().map(Why::from),
        open_number: offer.open.as_ref().map(|open| whole(open.number)),
        message: offer.message.clone(),
        new_branch: offer.new_branch.clone(),
        repo: offer.remote.as_ref().map(|remote| remote.url.clone()),
        tracked: offer.remote.as_ref().is_some_and(|remote| remote.tracked),
        remote: offer.remote.as_ref().map(|remote| remote.name.clone()),
        branch: offer.branch,
    }
}

/// The paths kendex renders in a project, which only a plan names.
fn generated(env: &Env, scope: &Scope) -> Result<kendex_core::engine::GeneratedPaths, String> {
    kendex_core::engine::plan_apply(env, scope, &kendex_core::engine::PlanOptions::default())
        .map(|report| report.generated)
        .map_err(|error| error.to_string())
}

/// A count on its way to the window. Numbers cross this boundary as
/// 32-bit: JavaScript loses precision past 2^53, so the binding generator
/// refuses the wider ones, and a project with more paths than this holds
/// is not one any of these counts describes.
fn counted(count: usize) -> u32 {
    u32::try_from(count).unwrap_or(u32::MAX)
}

fn whole(count: u64) -> u32 {
    u32::try_from(count).unwrap_or(u32::MAX)
}

/// A path as the window shows it: what core settled, character for
/// character.
fn shown(path: &Path) -> String {
    kendex_core::paths::slashed(path)
}

/// Read every project the write could reach, and say for each one whether
/// there is an offer to make, a state to flag on its card, or nothing.
#[tauri::command(async)]
#[specta::specta]
pub fn commit_offer_scan(roots: Vec<String>) -> Result<CommitOfferScan, String> {
    let env = env()?;
    let mut found = CommitOfferScan {
        offers: Vec::new(),
        flagged: Vec::new(),
    };
    for root in roots {
        // A project whose plan will not derive is not one this offer can
        // claim anything about, and it is not a failure of the write that
        // reached it either: the read is skipped and nothing is said.
        match read(&env, &PathBuf::from(root)) {
            Ok(None) | Err(_) => {}
            Ok(Some(Ok(offer))) => found.offers.push(offer),
            Ok(Some(Err(flag))) => found.flagged.push(flag),
        }
    }
    Ok(found)
}

/// What changed in one file the offer covers, for the viewer the window
/// opens on it.
///
/// The project is read again rather than trusting the path the window
/// sends: the scan is what decides which files kendex may show, and a
/// window that has been open a while is answering about a project that has
/// moved on. A path the fresh scan does not cover is `Nothing`, whatever
/// it names.
#[tauri::command(async)]
#[specta::specta]
pub fn commit_offer_file_changes(root: String, path: String) -> Result<FileChanges, String> {
    let env = env()?;
    let root = PathBuf::from(root);
    let scope = Scope::Project { root: root.clone() };
    let scan = match commit_offer::scan(&scope, &generated(&env, &scope)?) {
        Ok(Some(scan)) => scan,
        // Nothing kendex owns changed here any more, so no path in this
        // project has a change this viewer may show.
        Ok(None) => return Ok(FileChanges::Nothing),
        Err(failed) => {
            return Ok(FileChanges::Refused {
                refused: Refused::from(&failed),
            });
        }
    };
    Ok(match commit_offer::file_changes(&scan, &path) {
        Ok(Changes::Shown(changed)) => FileChanges::Shown {
            diff: changed.diff,
            mode: changed.mode.map(|mode| FileMode {
                before: mode.before,
                after: mode.after,
            }),
        },
        Ok(Changes::NotOffered) => FileChanges::Nothing,
        Err(failed) => FileChanges::Refused {
            refused: Refused::from(&failed),
        },
    })
}

#[tauri::command(async)]
#[specta::specta]
pub fn commit_offer_commit(root: String, message: String) -> Result<CommitStep, String> {
    let env = env()?;
    let root = PathBuf::from(root);
    let scope = Scope::Project { root: root.clone() };
    let generated = generated(&env, &scope)?;
    Ok(match commit_offer::commit(&root, &generated, &message) {
        Ok(Committed::Nothing) => CommitStep::Nothing,
        Ok(Committed::Made { sha, files }) => CommitStep::Made {
            sha,
            files: counted(files),
        },
        Err(failure) => CommitStep::Refused {
            refused: Refused::from(&failure.failed),
            still_staged: failure.still_staged.map(counted),
        },
    })
}

#[tauri::command(async)]
#[specta::specta]
pub fn commit_offer_push(
    root: String,
    remote: String,
    branch: String,
    tracked: bool,
) -> Result<StepResult, String> {
    Ok(
        commit_offer::push(&PathBuf::from(root), &remote, &branch, tracked)
            .map(|_| ())
            .into(),
    )
}

/// Push a commit that already exists to a branch of its own, without
/// moving the branch it is on — the recovery a refused push offers.
#[tauri::command(async)]
#[specta::specta]
pub fn commit_offer_push_head(
    root: String,
    remote: String,
    branch: String,
) -> Result<StepResult, String> {
    Ok(
        commit_offer::push_head(&PathBuf::from(root), &remote, &branch)
            .map(|_| ())
            .into(),
    )
}

#[tauri::command(async)]
#[specta::specta]
pub fn commit_offer_start_branch(root: String, branch: String) -> Result<StepResult, String> {
    Ok(commit_offer::start_branch(&PathBuf::from(root), &branch).into())
}

/// Put the checkout back and remove the empty branch kendex made, after a
/// commit on it refused.
#[tauri::command(async)]
#[specta::specta]
pub fn commit_offer_abandon_branch(root: String, branch: String) -> Result<StepResult, String> {
    Ok(commit_offer::abandon_branch(&PathBuf::from(root), &branch).into())
}

/// The commit a recovery would put the branch back to, read before the
/// commit runs. `null` in a repository with no commit yet.
#[tauri::command(async)]
#[specta::specta]
pub fn commit_offer_previous_head(root: String) -> Result<Option<String>, String> {
    commit_offer::previous_head(&PathBuf::from(root)).map_err(|failed| failed.said().join("\n"))
}

#[tauri::command(async)]
#[specta::specta]
pub fn commit_offer_open_pull_request(
    repo: String,
    head: String,
    base: String,
    title: String,
    files: u32,
) -> Result<OpenResult, String> {
    Ok(
        match commit_offer::open_pull_request(&repo, &head, &base, &title, files as usize) {
            Ok(opened) => OpenResult::Opened { url: opened.url },
            Err(failed) => OpenResult::Refused {
                refused: Refused::from(&failed),
            },
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use kendex_core::commit_offer::Refusal;

    /// Every way a step can fail travels whole: the program's words in
    /// order, or the bound it ran past with no words at all. Nothing is
    /// summarised on the way to the window.
    #[test]
    fn a_refusal_travels_as_the_step_and_its_own_words() {
        let refused = Refused::from(&Failed {
            step: Step::Commit,
            refusal: Refusal::Said(vec![
                "commit-msg: no changelog".to_owned(),
                "  fix".to_owned(),
            ]),
        });
        assert_eq!(refused.step, "the commit");
        assert_eq!(refused.said, ["commit-msg: no changelog", "  fix"]);
        assert!(!refused.timed_out);
        assert!(!refused.gh);
        assert_eq!(refused.seconds, 300);

        let timed_out = Refused::from(&Failed {
            step: Step::PullRequest,
            refusal: Refusal::TimedOut,
        });
        assert!(timed_out.timed_out);
        assert!(timed_out.said.is_empty(), "a timeout carried words");
        assert!(timed_out.gh, "gh's step read as git's");
        assert_eq!(timed_out.seconds, 120);
    }
}
