//! The commit, push and pull-request offer that follows a kendex write in a
//! git project.
//!
//! kendex writes files into a checkout, and a project commits those files
//! so that a clone works without kendex. This module is what asks what to
//! do with them, and it is the whole of that answer for both surfaces: the
//! CLI and the app call the same scan, take the same choices and read the
//! same failures, so neither can offer something the other would refuse.
//!
//! **The offer is explicit.** kendex commits, pushes or opens a pull
//! request only after a person chose that in this run. There is no setting,
//! flag or state that makes any of the three happen without a choice, and
//! leaving the files as diffs is a choice of the same standing as the other
//! three.
//!
//! **kendex stages only the files it owns whole.** A file the person wrote
//! is never staged and never committed, and a shared configuration file
//! kendex writes one key in is not a file it owns whole: git has no way to
//! commit one key, so committing such a path would commit the person's
//! edits with kendex's. [`crate::engine::GeneratedPaths`] is where that
//! split is made, once, for the inventory and for this.
//!
//! **kendex never undoes a commit.** It does not revert one, does not move
//! a branch ref backwards, does not reset, and does not stash. The two
//! cleanups here — unstaging what its own `git add` staged, and removing an
//! empty branch it made a moment earlier — are kendex clearing its own
//! leftovers: no commit exists to undo, and no branch ref moves backwards.
//! [`fn@restore`] writes the working tree and nothing else: it puts a pending
//! change back to what the last commit already holds, on paths a person
//! named and confirmed, and leaves the index and every ref alone.

use std::path::PathBuf;
use std::time::Duration;

use crate::env::Env;
use crate::model::Scope;
use crate::process::{DEFAULT_TIMEOUT, INTERACTIVE_TIMEOUT};

mod changes;
mod gh;
mod git;
mod message;
mod paths;
mod pathspec;
mod pending;
mod restore;
mod run;

pub use changes::{Changed, Changes, ModeChange, file_changes};
pub use gh::{OpenPullRequest, probe};
pub use git::previous_head;
pub use message::default_message;
pub use pending::{
    Attribution, Baseline, Held, Pending, PendingFile, Selection, Tangle, Tangled, baseline,
    pending,
};
pub use restore::{RestoreFailure, RestorePlan, restore, restore_plan};
pub use run::{
    CommitFailure, Committed, Opened, Pushed, abandon_branch, body, commit, open_pull_request,
    push, push_head, start_branch,
};

#[cfg(test)]
mod tests;

/// One step of the offer: the bound it runs under, and the name a timeout
/// of it is reported by.
///
/// A bound per step rather than one for the module: a repository's own
/// pre-commit hook can run a test suite, and a bound short enough for a
/// local read would kill a hook that was working.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    /// A git read the offer is built from: status, branch, remote, refs.
    Read,
    Stage,
    Commit,
    Unstage,
    /// Putting a pending change back to what the last commit holds.
    Restore,
    Branch,
    SwitchBack,
    RemoveBranch,
    Push,
    Probe,
    PullRequest,
}

impl Step {
    /// A local read that takes longer than this is a broken checkout.
    pub const READ: Duration = Duration::from_secs(10);
    /// A repository's own pre-commit hook can run a test suite.
    pub const COMMIT: Duration = Duration::from_secs(300);
    /// The probe runs before the offer is drawn, so a person is waiting on
    /// it with nothing on screen.
    pub const PROBE: Duration = Duration::from_secs(15);

    pub fn bound(self) -> Duration {
        match self {
            Step::Read => Step::READ,
            // Local writes over the set, with no hook to wait on.
            Step::Stage
            | Step::Unstage
            | Step::Restore
            | Step::Branch
            | Step::SwitchBack
            | Step::RemoveBranch => INTERACTIVE_TIMEOUT,
            Step::Commit => Step::COMMIT,
            Step::Probe => Step::PROBE,
            Step::Push | Step::PullRequest => DEFAULT_TIMEOUT,
        }
    }

    /// How a timeout of this step names it: `<name> did not finish within
    /// N seconds`.
    pub fn name(self) -> &'static str {
        match self {
            Step::Read => "the check",
            Step::Stage => "the staging",
            Step::Commit => "the commit",
            Step::Unstage => "the unstaging",
            Step::Restore => "the restore",
            Step::Branch => "the branch",
            Step::SwitchBack => "the switch back",
            Step::RemoveBranch => "removing the branch",
            Step::Push => "the push",
            Step::Probe => "the check for an open pull request",
            Step::PullRequest => "the pull request",
        }
    }

    /// The bound in whole seconds, for the line that reports a timeout.
    pub fn seconds(self) -> u64 {
        self.bound().as_secs()
    }
}

/// What a step said when it refused, or the bound it ran past.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// The program never ran: it is not on this machine, or what it needed
    /// to run could not be written. Nothing a program that did start can
    /// fail with belongs here, because the choice this decides — `gh is
    /// not installed` against `gh said:` — turns on exactly that.
    NotStarted(String),
    /// The program's own words, whole, one line at a time, in order:
    /// stderr first, because git puts a hook's own output there and prints
    /// nothing on stdout when a hook refuses, then stdout for a program
    /// that writes diagnostics to it, as `gh` does.
    ///
    /// Nothing is summarised, reworded, truncated to a first line, or
    /// matched against a pattern to decide what it means.
    Said(Vec<String>),
    /// The step ran past its bound. Whether it finished is not known here.
    TimedOut,
}

/// A step that did not go through, and which step it was.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failed {
    pub step: Step,
    pub refusal: Refusal,
}

impl Failed {
    /// The words to show under this failure, empty where the step ran out
    /// of time and said nothing.
    pub fn said(&self) -> &[String] {
        match &self.refusal {
            Refusal::Said(lines) => lines,
            Refusal::NotStarted(line) => std::slice::from_ref(line),
            Refusal::TimedOut => &[],
        }
    }

    pub fn timed_out(&self) -> bool {
        self.refusal == Refusal::TimedOut
    }
}

/// One changed path the offer covers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Owned {
    /// Relative to the project root, with `/` separators — the spelling
    /// git reports and the spelling both surfaces print.
    pub path: String,
    /// git reports this path as untracked, which is exactly a `git status`
    /// row beginning `??`. `git commit --only` refuses a path git does not
    /// track, so these are staged first; a path the person already staged
    /// is not one of them and is neither added nor unstaged.
    pub untracked: bool,
}

/// Where the checkout stands. Two of the three are states the offer cannot
/// be made in: a commit would land somewhere nobody asked for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Branch {
    On(String),
    Detached,
    InProgress(Operation),
}

/// A git operation the checkout is in the middle of.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Operation {
    Merge,
    Rebase,
    CherryPick,
    Bisect,
}

impl Operation {
    /// How a line names it: `a rebase is in progress`.
    pub fn article(self) -> &'static str {
        match self {
            Operation::Merge => "a merge",
            Operation::Rebase => "a rebase",
            Operation::CherryPick => "a cherry-pick",
            Operation::Bisect => "a bisect",
        }
    }
}

/// What one read of the project found: the paths the offer covers, and the
/// state of the checkout it would commit in.
///
/// The cheap half of the offer. It runs one `git status` over the whole
/// checkout and reads the branch, and nothing else — no remote, no network
/// — so a run that will not ask (a flag already answered, or nobody is
/// there to ask) pays for none of that.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scan {
    pub root: PathBuf,
    /// The files kendex owns whole that git reports as changed, sorted.
    pub owned: Vec<Owned>,
    /// The shared configuration files kendex writes one key in that git
    /// reports as changed, sorted. Named to the person and left alone.
    pub shared: Vec<String>,
    /// How many other paths in this repository changed. The person's own
    /// changes, which the offer counts and never touches.
    pub others: usize,
    pub branch: Branch,
}

impl Scan {
    pub fn count(&self) -> usize {
        self.owned.len()
    }

    /// The branch a commit would land on, or `None` in a state where the
    /// offer cannot be made.
    pub fn on_branch(&self) -> Option<&str> {
        match &self.branch {
            Branch::On(name) => Some(name),
            Branch::Detached | Branch::InProgress(_) => None,
        }
    }
}

/// Read the project. `None` where there is nothing to offer about: the
/// scope is not a project, the project is not a checkout, or nothing
/// kendex owns changed.
///
/// The offer setting is deliberately not read here. It turns off the
/// asking, not the choices, so a flag that names a choice still runs one —
/// [`asking`] is what a surface consults before it asks.
pub fn scan(
    scope: &Scope,
    generated: &crate::engine::GeneratedPaths,
) -> std::result::Result<Option<Scan>, Failed> {
    let Scope::Project { root } = scope else {
        return Ok(None);
    };
    if !root.join(".git").exists() {
        return Ok(None);
    }
    paths::scan(root, generated)
}

/// Whether this machine wants to be asked. Machine-local, like every other
/// field in the app settings: whether a person is asked is theirs, not
/// their project's.
pub fn asking(env: &Env) -> bool {
    crate::settings::load(env)
        .map(|settings| settings.commit_offer.asking())
        .unwrap_or(true)
}

/// The remote the offer pushes to, chosen by rule rather than by a prompt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Remote {
    pub name: String,
    /// The remote's URL. Every `gh` call is bound to it with `--repo`, so
    /// a project whose `origin` is one host and whose second remote is
    /// GitHub cannot have `gh` answer about a repository the push would
    /// never reach.
    pub url: String,
    /// The current branch already tracks this remote, so a push needs no
    /// `--set-upstream`.
    pub tracked: bool,
}

/// Why a choice is not on offer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Unavailable {
    NoRemote,
    RemoteNotDecidable,
    GhMissing,
    /// gh's own first line, so a case nobody anticipated still names
    /// itself rather than reading as one kendex knows.
    GhSaid(String),
}

/// The offer, built and ready to draw: the paths, the choices that stand,
/// and the reason for each one that does not.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Offer {
    pub scan: Scan,
    pub branch: String,
    pub remote: Option<Remote>,
    /// `Err` where the choice is not on offer, carrying its reason.
    pub push: std::result::Result<(), Unavailable>,
    pub pull_request: std::result::Result<(), Unavailable>,
    /// A pull request already open for the current branch. Where there is
    /// one, `push` adds a commit to it and the `pr` choice is not offered.
    pub open: Option<OpenPullRequest>,
    /// The default message, editable on both surfaces before the commit
    /// runs: a repository's commit-msg hook decides what it will accept
    /// and kendex cannot know that rule.
    pub message: String,
    /// The branch the `pr` route would make, and the branch the
    /// refused-push recovery would push to. Picked by the first-free rule.
    pub new_branch: String,
}

/// Whether building the offer asks `gh` about the repository.
///
/// `Skip` leaves the pull-request choice standing unprobed, and only a
/// caller that will never take that choice may pass it: a flag that
/// already answered `commit` or `push` needs the remote and nothing from
/// `gh`, and should not wait on the network or on a sign-in it does not
/// use.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Probe {
    Gh,
    Skip,
}

/// Build the whole offer from a scan: choose the remote, probe `gh` where
/// [`Probe::Gh`] asks for it, and pick the branch a pull request would use.
///
/// The probe is the one network call, and it runs only where a remote was
/// chosen, so a project with no remote pays nothing for it.
pub fn offer(scan: Scan, command: &str, probe: Probe) -> std::result::Result<Offer, Failed> {
    let Some(branch) = scan.on_branch().map(str::to_owned) else {
        // Both callers check the branch state before they reach here: the
        // states it names are flagged, never offered.
        unreachable!("an offer was built for a checkout with no branch");
    };
    let chosen = git::choose_remote(&scan.root, &branch)?;
    let new_branch = git::first_free_branch(&scan.root, chosen.as_ref())?;
    let (push, pull_request, open) = match &chosen {
        None => {
            let why = match git::remotes(&scan.root)?.is_empty() {
                true => Unavailable::NoRemote,
                false => Unavailable::RemoteNotDecidable,
            };
            (Err(why.clone()), Err(why), None)
        }
        Some(_) if probe == Probe::Skip => (Ok(()), Ok(()), None),
        Some(remote) => match gh::probe(&remote.url, &branch) {
            Ok(open) => (Ok(()), Ok(()), open),
            Err(why) => (Ok(()), Err(why), None),
        },
    };
    Ok(Offer {
        branch,
        remote: chosen,
        push,
        pull_request,
        open,
        message: message::default_message(command),
        new_branch,
        scan,
    })
}
