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

use std::collections::{BTreeMap, BTreeSet};

use kendex_core::commit_offer::{
    self, Attribution, Baseline, Branch, Changes, Committed, Failed, Held, Offer, Pending, Probe,
    RestorePlan, Selection, Step, Tangled, Unavailable,
};
use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::package::diff::PackageDiff;
use serde::{Deserialize, Serialize};
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

/// What one action did to one changed path, on its way to the window.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub enum DidWhat {
    /// The path was clean before the action; the change is the action's.
    Action,
    /// The path already carried a change before the action, and the action
    /// changed it again. A commit of it carries both.
    Both,
    /// The action left this path as it found it.
    Older,
}

impl From<Attribution> for DidWhat {
    fn from(attribution: Attribution) -> DidWhat {
        match attribution {
            Attribution::Action => DidWhat::Action,
            Attribution::Both => DidWhat::Both,
            Attribution::Older => DidWhat::Older,
        }
    }
}

/// One changed path kendex owns, and what the action that opened this offer
/// did to it.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ChangedFile {
    pub path: String,
    pub did: DidWhat,
    /// This path did not exist before: the change is that it now does.
    pub added: bool,
    /// Nothing stands at this path now: the change is that it is gone.
    pub removed: bool,
}

/// Why the action's own work cannot be committed on its own, one file at a
/// time.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct TangledFile {
    pub path: String,
    pub reason: TangleReason,
}

#[derive(Debug, Clone, Copy, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub enum TangleReason {
    /// The action changed this file and it already carried an earlier
    /// change. git commits whole files, so both go in together.
    CarriesEarlier,
    /// The action adds or takes away a rendered path, and the file that
    /// declares what kendex renders here carries an earlier change of its
    /// own.
    DeclaresWhatChanged,
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
    pub files: Vec<ChangedFile>,
    /// The paths a commit of only this action's work would carry. Empty
    /// where the offer was opened by a person rather than by an action, in
    /// which case there is no action to scope to.
    pub action_paths: Vec<String>,
    /// Whether committing only the action's work and committing everything
    /// pending would make different commits. Where they would not, there is
    /// no choice to put to the reader.
    pub choice: bool,
    /// What stops the action's work from being committed on its own.
    pub tangled: Vec<TangledFile>,
    /// The shared configuration files kendex writes one key in.
    pub shared: Vec<String>,
    /// The project's manifest, where this action wrote it and the commit
    /// does not carry it. `null` where every declaration these renders
    /// need is committed already, or where a person opened the offer and
    /// there is no action to attribute a change to.
    pub manifest: Option<String>,
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

impl ProjectOffer {
    /// Whether this write can be shown to have done anything in this
    /// project. Every file reading as older work means one of two things,
    /// and both end the same way: the write changed nothing here, or no
    /// reading was taken before it and nothing may be attributed to it.
    fn acted(&self) -> bool {
        self.files.iter().any(|file| file.did != DidWhat::Older)
    }
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
    Nothing {
        /// Paths the selection named that the re-read set no longer covers.
        /// Every path it named, since none was left.
        dropped: Vec<String>,
    },
    Made {
        sha: String,
        files: u32,
        /// Paths the selection named that the re-read set no longer covers.
        dropped: Vec<String>,
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

/// `key` is the root exactly as the caller spelled it. Every field a surface
/// matches on carries it back unchanged: the window looks an answer up under
/// the string it sent, and `shown` is a DISPLAY spelling — on Windows
/// `paths::slashed` swaps the separator, so a key built from it never
/// compares equal to the registered path the window holds. `RegisteredProject`
/// in `app_settings.rs` keeps the same rule with `display()`.
fn read(
    env: &Env,
    root: &Path,
    key: &str,
    since: Option<&Baseline>,
) -> Result<Option<Result<ProjectOffer, ProjectFlag>>, String> {
    let scope = Scope::Project {
        root: root.to_owned(),
    };
    let scan = match commit_offer::scan(&scope, &generated(env, &scope)?) {
        Ok(None) => return Ok(None),
        Ok(Some(scan)) => scan,
        Err(failed) => {
            return Ok(Some(Err(ProjectFlag {
                root: key.to_owned(),
                count: 0,
                reason: FlagReason::Unreadable {
                    said: failed.said().to_vec(),
                },
            })));
        }
    };
    let flag = |reason: FlagReason| ProjectFlag {
        root: key.to_owned(),
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
    // Read against the state the action found, where an action opened this.
    // A person who opened the review themselves has no action to scope to,
    // and every pending change is theirs to choose from.
    let pending = since.map(|since| commit_offer::pending(&scan, since));
    // The window's write is not a typed command, so the message names the
    // shell the person is in rather than a verb they typed.
    match commit_offer::offer(scan, COMMAND, Probe::Gh) {
        Ok(offer) => Ok(Some(Ok(drawn(root, key, offer, pending.as_ref())))),
        Err(failed) => Ok(Some(Err(ProjectFlag {
            root: key.to_owned(),
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

fn drawn(root: &Path, key: &str, offer: Offer, pending: Option<&Pending>) -> ProjectOffer {
    let did: BTreeMap<&str, &kendex_core::commit_offer::PendingFile> = pending
        .map(|pending| {
            pending
                .files
                .iter()
                .map(|file| (file.path.as_str(), file))
                .collect()
        })
        .unwrap_or_default();
    ProjectOffer {
        root: key.to_owned(),
        name: named(root),
        files: offer
            .scan
            .owned
            .iter()
            .map(|owned| match did.get(owned.path.as_str()) {
                // No action opened this offer, so nothing is attributed to
                // one: every pending change stands on its own.
                None => ChangedFile {
                    path: owned.path.clone(),
                    did: DidWhat::Older,
                    added: owned.untracked,
                    removed: false,
                },
                Some(file) => ChangedFile {
                    path: owned.path.clone(),
                    did: file.attribution.into(),
                    added: file.untracked,
                    removed: file.gone,
                },
            })
            .collect(),
        action_paths: pending
            .map(|pending| pending.action_set().into_iter().collect())
            .unwrap_or_default(),
        choice: pending.is_some_and(|pending| !pending.same()),
        tangled: pending
            .map(|pending| {
                pending
                    .tangled()
                    .into_iter()
                    .map(|tangle| TangledFile {
                        path: tangle.path,
                        reason: match tangle.reason {
                            Tangled::CarriesEarlier => TangleReason::CarriesEarlier,
                            Tangled::DeclaresWhatChanged => TangleReason::DeclaresWhatChanged,
                        },
                    })
                    .collect()
            })
            .unwrap_or_default(),
        shared: offer.scan.shared.clone(),
        manifest: pending.and_then(|pending| pending.manifest_not_carried().map(str::to_owned)),
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

/// What a project is called on a card and in a title: its folder's last
/// segment, falling back to the whole path where it has none.
fn named(root: &Path) -> String {
    root.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| shown(root))
}

/// What one project's pending kendex changes held before an action ran, on
/// its way to the window and back.
#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ProjectBaseline {
    pub root: String,
    pub held: Vec<HeldPath>,
}

/// One path that already carried a pending change, and what stood there.
#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct HeldPath {
    pub path: String,
    /// A digest of what stood there, `null` where nothing stood there and
    /// `""` where it could not be read. Three states, because a reading
    /// that could not be taken must never compare equal to a later one.
    pub digest: Option<String>,
    pub unreadable: bool,
}

impl ProjectBaseline {
    fn into_core(self) -> Baseline {
        Baseline {
            held: self
                .held
                .into_iter()
                .map(|held| {
                    let state = match (held.unreadable, held.digest) {
                        (true, _) => Held::Unreadable,
                        (false, Some(digest)) => Held::At(digest),
                        (false, None) => Held::Gone,
                    };
                    (held.path, state)
                })
                .collect(),
        }
    }
}

fn baseline_of(key: &str, baseline: &Baseline) -> ProjectBaseline {
    ProjectBaseline {
        root: key.to_owned(),
        held: baseline
            .held
            .iter()
            .map(|(path, state)| HeldPath {
                path: path.clone(),
                digest: match state {
                    Held::At(digest) => Some(digest.clone()),
                    Held::Gone | Held::Unreadable => None,
                },
                unreadable: *state == Held::Unreadable,
            })
            .collect(),
    }
}

/// Read what every project the next write could reach holds now, so the
/// offer after that write can say what the write itself did.
///
/// Taken before the action runs and handed back to [`commit_offer_scan`]
/// afterwards. A project this cannot read contributes nothing: the reading
/// after the action then finds no baseline for it and treats every pending
/// change there as the action's, which over-reports rather than claiming a
/// change is somebody else's.
#[tauri::command(async)]
#[specta::specta]
pub fn commit_offer_baseline(roots: Vec<String>) -> Result<Vec<ProjectBaseline>, String> {
    let env = env()?;
    let mut taken = Vec::new();
    for key in roots {
        let scope = Scope::Project {
            root: PathBuf::from(&key),
        };
        let Ok(generated) = generated(&env, &scope) else {
            continue;
        };
        if let Ok(baseline) = commit_offer::baseline(&scope, &generated) {
            taken.push(baseline_of(&key, &baseline));
        }
    }
    Ok(taken)
}

/// Read every project the write could reach, and say for each one whether
/// there is an offer to make, a state to flag on its card, or nothing.
///
/// `since` is what [`commit_offer_baseline`] read before the write. A
/// project whose pending changes the write did not touch has no offer to
/// make about it, whatever else is pending there: editing one project may
/// not put another project's older work in front of the reader.
#[tauri::command(async)]
#[specta::specta]
pub fn commit_offer_scan(
    roots: Vec<String>,
    since: Vec<ProjectBaseline>,
) -> Result<Vec<ProjectOffer>, String> {
    let env = env()?;
    // The setting turns off the asking, and the window has no flag that
    // could answer instead, so nothing is read at all when it is off. The
    // passive read behind `project_changes_scan` is not asking, and keeps
    // running: what is pending stays on the project's card and in its
    // review, and only the question goes away.
    if !commit_offer::asking(&env) {
        return Ok(Vec::new());
    }
    let mut taken: BTreeMap<String, Baseline> = since
        .into_iter()
        .map(|one| (one.root.clone(), one.into_core()))
        .collect();
    let mut offers = Vec::new();
    for root in roots {
        // A project whose plan will not derive is not one this offer can
        // claim anything about, and it is not a failure of the write that
        // reached it either: the read is skipped and nothing is said.
        //
        // A missing reading is NOT an empty one. Where no reading of this
        // project was taken before the write — its own read refused, or the
        // plan would not derive then either — an empty baseline would
        // report every pending change as this action's, putting somebody
        // else's work in a dialog headed by this write and committing it
        // under that label. Passed on as `None`, nothing is attributed to
        // an action, and the filter below then makes no offer at all: a
        // write that cannot be shown to have done anything here says
        // nothing. What is waiting still reaches the person through
        // `project_changes_scan` and the review page.
        let before = taken.remove(&root);
        match read(&env, &PathBuf::from(&root), &root, before.as_ref()) {
            Ok(None) | Err(_) => {}
            // An offer is made about what the write did. A project where it
            // did nothing is left alone: its pending changes are on the
            // project's card and in its own review, which is where deferred
            // work belongs.
            Ok(Some(Ok(offer))) if !offer.acted() => {}
            Ok(Some(Ok(offer))) => offers.push(offer),
            // A project whose state allows no offer is not flagged from
            // here. `project_changes_scan` reads that state on the ordinary
            // refresh path with the reason behind it, and the card and the
            // review draw from that one answer, so a write is not a second
            // route to the same fact with less of it.
            Ok(Some(Err(_))) => {}
        }
    }
    Ok(offers)
}

/// Build the offer for one project because a person asked for it, rather
/// than because a write left it behind.
///
/// The setting that turns off asking is not consulted: it decides whether
/// kendex opens the question by itself, and this is the person opening it.
/// Nothing is attributed to an action either — there is none — so every
/// pending change is theirs to choose from.
#[tauri::command(async)]
#[specta::specta]
pub fn commit_offer_open(root: String) -> Result<OpenOffer, String> {
    let env = env()?;
    Ok(match read(&env, &PathBuf::from(&root), &root, None)? {
        Some(Ok(offer)) => OpenOffer::Offer {
            offer: Box::new(offer),
        },
        Some(Err(flag)) => OpenOffer::Blocked { flag },
        None => OpenOffer::Nothing,
    })
}

/// What asking for one project's offer answered with.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum OpenOffer {
    Offer {
        offer: Box<ProjectOffer>,
    },
    /// Nothing kendex owns has changed here any more.
    Nothing,
    /// The offer cannot be made in this project's state, and the state says
    /// why — the same reason the project's card carries.
    Blocked {
        flag: ProjectFlag,
    },
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

/// Which of a project's pending kendex changes a step is about, as the
/// window states it.
#[derive(Debug, Clone, Deserialize, Type)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ChangeSelection {
    /// Every pending change kendex owns in this project.
    All,
    /// Exactly these paths. Core re-reads the project and narrows them to
    /// what it still covers, so a window that has been open a while cannot
    /// name a path the project has moved past.
    Only { paths: Vec<String> },
}

impl ChangeSelection {
    fn into_core(self) -> Selection {
        match self {
            ChangeSelection::All => Selection::All,
            ChangeSelection::Only { paths } => {
                Selection::Only(paths.into_iter().collect::<BTreeSet<String>>())
            }
        }
    }
}

#[tauri::command(async)]
#[specta::specta]
pub fn commit_offer_commit(
    root: String,
    message: String,
    selection: ChangeSelection,
) -> Result<CommitStep, String> {
    let env = env()?;
    let root = PathBuf::from(root);
    let scope = Scope::Project { root: root.clone() };
    let generated = generated(&env, &scope)?;
    let selection = selection.into_core();
    Ok(
        match commit_offer::commit(&root, &generated, &message, &selection) {
            Ok(Committed::Nothing { dropped }) => CommitStep::Nothing { dropped },
            Ok(Committed::Made {
                sha,
                files,
                dropped,
            }) => CommitStep::Made {
                sha,
                files: counted(files),
                dropped,
            },
            Err(failure) => CommitStep::Refused {
                refused: Refused::from(&failure.failed),
                still_staged: failure.still_staged.map(counted),
            },
        },
    )
}

/// What one project holds for the review a person opens themselves.
///
/// Read on the ordinary refresh path — start-up, focus, an explicit scan,
/// and behind every write — and it opens nothing: it is what the project's
/// card and its review draw from. Deliberately the cheap half of the offer:
/// no remote is chosen and `gh` is not asked, so a passive read costs no
/// network call.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ProjectChanges {
    pub root: String,
    /// The project's folder name.
    pub name: String,
    pub state: ChangesState,
}

/// What a passive read of one project found.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ChangesState {
    /// Nothing kendex owns has changed here.
    Clean,
    /// Changes are pending, and this is what stands behind them.
    Pending {
        /// The files kendex owns whole that changed.
        files: Vec<String>,
        /// The shared configuration files kendex writes one key in.
        shared: Vec<String>,
        /// How many of the person's own files changed.
        others: u32,
        /// The branch a commit would land on, or `null` where none would.
        branch: Option<String>,
        /// The git operation the checkout is in the middle of, as a line
        /// names it, or `null`.
        operation: Option<String>,
    },
    /// A read this answer is built from would not run. Not zero changes —
    /// nothing is known about this project at all.
    Unreadable { said: Vec<String> },
}

#[tauri::command(async)]
#[specta::specta]
pub fn project_changes_scan(roots: Vec<String>) -> Result<Vec<ProjectChanges>, String> {
    let env = env()?;
    let mut found = Vec::new();
    for key in roots {
        let root = PathBuf::from(&key);
        let scope = Scope::Project { root: root.clone() };
        // A project whose plan will not derive is one this read can claim
        // nothing about, and dropping it would leave the window with no row
        // — which every surface draws exactly as it draws a clean project.
        // It gets a row saying it could not be read, carrying the reason.
        let generated = match generated(&env, &scope) {
            Ok(generated) => generated,
            Err(error) => {
                found.push(ProjectChanges {
                    root: key,
                    name: named(&root),
                    state: ChangesState::Unreadable { said: vec![error] },
                });
                continue;
            }
        };
        found.push(ProjectChanges {
            root: key,
            name: named(&root),
            state: match commit_offer::scan(&scope, &generated) {
                Ok(None) => ChangesState::Clean,
                Ok(Some(scan)) => ChangesState::Pending {
                    files: scan.owned.iter().map(|owned| owned.path.clone()).collect(),
                    shared: scan.shared.clone(),
                    others: counted(scan.others),
                    branch: scan.on_branch().map(str::to_owned),
                    operation: match &scan.branch {
                        Branch::InProgress(operation) => Some(operation.article().to_owned()),
                        Branch::On(_) | Branch::Detached => None,
                    },
                },
                Err(failed) => ChangesState::Unreadable {
                    said: failed.said().to_vec(),
                },
            },
        });
    }
    Ok(found)
}

/// What putting the named paths back to what the last commit holds would
/// do, path by path.
#[derive(Debug, Clone, Default, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct RestoreEffect {
    /// Paths whose committed content comes back over what stands there now.
    pub restored: Vec<String>,
    /// Paths the last commit does not hold. Putting them back means taking
    /// them away, and kendex takes nothing away by deleting: they move to
    /// the trash.
    pub removed: Vec<String>,
    /// Paths named that the offer no longer covers.
    pub dropped: Vec<String>,
    /// Paths not named that go with them anyway, because what is being put
    /// back cannot stand without them.
    pub added: Vec<String>,
    /// Paths this changes that the next write into the project would write
    /// again, because kendex still renders them. A restore moves the working
    /// tree and does not change what kendex is asked to render, so saying
    /// the effect is a removal without saying this would promise something
    /// that does not last.
    pub rerendered: Vec<String>,
}

impl From<RestorePlan> for RestoreEffect {
    fn from(plan: RestorePlan) -> RestoreEffect {
        RestoreEffect {
            restored: plan.restored,
            removed: plan.removed,
            dropped: plan.dropped,
            added: plan.added,
            rerendered: plan.rerendered,
        }
    }
}

/// What a restore answered with: the exact effect, or the words of a step
/// that would not run.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum RestoreResult {
    Effect {
        effect: RestoreEffect,
    },
    /// The words of a step that would not run, beside what had already been
    /// written when it stopped. A restore writes in two passes and a failure
    /// in the second leaves the first standing, so saying only that it
    /// refused would tell a person nothing happened while their files had
    /// already moved. Every list in `done` is empty where it stopped before
    /// writing anything.
    Refused {
        refused: Refused,
        done: RestoreEffect,
    },
}

/// The exact effect of putting these paths back, without putting any of
/// them back. What the confirmation states.
#[tauri::command(async)]
#[specta::specta]
pub fn project_changes_restore_plan(
    root: String,
    paths: Vec<String>,
) -> Result<RestoreResult, String> {
    let env = env()?;
    let scope = Scope::Project {
        root: PathBuf::from(root),
    };
    let generated = generated(&env, &scope)?;
    let chosen: BTreeSet<String> = paths.into_iter().collect();
    Ok(
        match commit_offer::restore_plan(&scope, &generated, &chosen) {
            Ok(plan) => RestoreResult::Effect {
                effect: plan.into(),
            },
            // The preview writes nothing, so it has nothing to account for.
            Err(failed) => RestoreResult::Refused {
                refused: Refused::from(&failed),
                done: RestoreEffect::default(),
            },
        },
    )
}

/// Put these paths back to what the last commit holds.
///
/// The effect is derived again here rather than taken from the preview a
/// person read: a preview describes a project that may have moved on, and a
/// restore may never take a path the offer has stopped covering.
#[tauri::command(async)]
#[specta::specta]
pub fn project_changes_restore(root: String, paths: Vec<String>) -> Result<RestoreResult, String> {
    let env = env()?;
    let scope = Scope::Project {
        root: PathBuf::from(root),
    };
    let generated = generated(&env, &scope)?;
    let chosen: BTreeSet<String> = paths.into_iter().collect();
    Ok(
        match commit_offer::restore(&env, &scope, &generated, &chosen) {
            Ok(plan) => RestoreResult::Effect {
                effect: plan.into(),
            },
            // What the run had already written travels with the refusal: a
            // failure among the removals leaves every restored path on disk.
            Err(failure) => RestoreResult::Refused {
                refused: Refused::from(&failure.failed),
                done: failure.done.into(),
            },
        },
    )
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
    use kendex_core::commit_offer::{Branch, Offer, Owned, Refusal, Scan};

    /// The root a surface matches on is the string the caller sent, never a
    /// display spelling of it. The window looks every answer up under the
    /// string it holds — `settings.projects` — so a key put through
    /// `shown` would compare equal to nothing: no reading would reach the
    /// scan, every pending path would read as this action's, and "Only this
    /// action" would commit the lot.
    ///
    /// A verbatim path proves it on any platform: `paths::slashed` strips
    /// the `\\?\` prefix, which is pure string work rather than a
    /// separator swap, so the two spellings differ here as they do on
    /// Windows.
    #[test]
    fn a_root_travels_back_in_the_spelling_it_arrived_in() {
        const KEY: &str = r"\\?\C:\Users\me\dev\site";
        assert_ne!(
            shown(&PathBuf::from(KEY)),
            KEY,
            "the display spelling matches the key, so this proves nothing"
        );
        assert_eq!(baseline_of(KEY, &Baseline::default()).root, KEY);
    }

    /// With no reading taken before the write, nothing is attributed to it:
    /// every pending change reads as older work and [`ProjectOffer::acted`]
    /// is false, which is what `commit_offer_scan` filters on to make no
    /// offer about that project. An empty baseline in its place would do
    /// the opposite — every pending change would read as this action's, and
    /// "Only this action" would commit somebody else's work under this
    /// write's label.
    ///
    /// What this pins is the attribution and the filter it feeds. The one
    /// line joining them, `taken.remove(&root)` passed on as it is rather
    /// than defaulted, is not covered: `commit_offer_scan` reads the
    /// machine through `Env::detect`, and no test in this crate can hand it
    /// one.
    #[test]
    fn a_write_no_reading_was_taken_for_is_credited_with_nothing() {
        let root = PathBuf::from("/home/method/dev/site");
        let unattributed = drawn(
            &root,
            "/home/method/dev/site",
            Offer {
                scan: Scan {
                    root: root.clone(),
                    owned: vec![Owned {
                        path: ".claude/CLAUDE.md".to_owned(),
                        untracked: false,
                    }],
                    shared: Vec::new(),
                    manifest: None,
                    others: 0,
                    branch: Branch::On("main".to_owned()),
                },
                branch: "main".to_owned(),
                remote: None,
                push: Ok(()),
                pull_request: Ok(()),
                open: None,
                message: "chore: kendex refresh".to_owned(),
                new_branch: "kendex/renders".to_owned(),
            },
            // No reading was taken before the write.
            None,
        );
        assert!(
            !unattributed.acted(),
            "a write with no reading behind it was reported as having acted"
        );
        assert!(unattributed.action_paths.is_empty());
        assert!(
            unattributed
                .files
                .iter()
                .all(|file| file.did == DidWhat::Older),
            "pending changes were attributed to a write nothing was read for"
        );
    }

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
