//! The terminal's half of the commit, push and pull-request offer.
//!
//! Where it runs: [`after_writing`] is called from [`super::engine_common::apply_report`],
//! the one door every verb executes a plan through, and from `update-pi`,
//! which writes into a project's `.pi` directory without going through it.
//! A verb cannot be added without the offer, and no verb can offer twice
//! for one project: the session below records which roots have been asked.
//!
//! What it says: every line the offer prints lives in [`block`], the way
//! the app keeps its own wording in one copy module. The two are reviewed
//! beside each other, and they say the same things in the same order.

use std::collections::BTreeMap;
use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use kendex_core::commit_offer::{self, Branch, Offer, Probe};
use kendex_core::engine::GeneratedPaths;
use kendex_core::env::Env;
use kendex_core::model::Scope;

use super::CliResult;

mod block;
mod routes;

#[cfg(test)]
mod tests;

/// The answer a flag gives without asking, and the message it carries.
///
/// One mutually exclusive group: two of them together is refused by clap
/// before the verb writes anything, naming both. Flattened into every verb
/// that offers — and only those, so a verb that never writes into a
/// project does not carry an answer to a question it never asks. The
/// values are read back off clap's matches by [`CommitFlags::from_matches`]
/// rather than off each verb's own struct, so no verb is enumerated; that
/// is why the field carrying this in a verb is never read by name.
#[derive(clap::Args, Clone, Default, Debug)]
pub struct CommitFlags {
    /// Commit the files kendex wrote, without asking
    #[arg(long, group = "commit-offer")]
    pub commit: bool,
    /// Commit them and push, without asking
    #[arg(long, group = "commit-offer")]
    pub push: bool,
    /// Commit them on a new branch and open a pull request, without asking
    #[arg(long, group = "commit-offer")]
    pub pull_request: bool,
    /// Leave them as diffs, without asking
    #[arg(long, group = "commit-offer")]
    pub leave: bool,
    /// The commit message to use instead of the default
    #[arg(long)]
    pub message: Option<String>,
}

impl CommitFlags {
    /// The flags on the verb the person ran, read off the innermost
    /// subcommand's matches. A verb that does not carry them answers
    /// nothing, which is the same as a person who was not asked.
    pub fn from_matches(matches: &clap::ArgMatches) -> CommitFlags {
        let mut at = matches;
        while let Some((_, inner)) = at.subcommand() {
            at = inner;
        }
        let flag = |id: &str| {
            at.try_get_one::<bool>(id)
                .ok()
                .flatten()
                .copied()
                .unwrap_or(false)
        };
        CommitFlags {
            commit: flag("commit"),
            push: flag("push"),
            pull_request: flag("pull_request"),
            leave: flag("leave"),
            message: at.try_get_one::<String>("message").ok().flatten().cloned(),
        }
    }
}

/// One of the four choices.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Choice {
    Commit,
    Push,
    Pr,
    Leave,
}

impl CommitFlags {
    /// The choice a flag named, or `None` where the person is to be asked.
    fn answered(&self) -> Option<Choice> {
        match (self.commit, self.push, self.pull_request, self.leave) {
            (true, _, _, _) => Some(Choice::Commit),
            (_, true, _, _) => Some(Choice::Push),
            (_, _, true, _) => Some(Choice::Pr),
            (_, _, _, true) => Some(Choice::Leave),
            _ => None,
        }
    }
}

/// What the offer did in one project, for the closing ledger and the exit
/// code.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Outcome {
    /// Left as diffs, or never offered. The ledger says nothing about it.
    Nothing,
    Committed(usize),
    Pushed(usize),
    PullRequest(usize),
    /// The commit was refused, or a flag named a choice that was not on
    /// offer: either way nothing was committed.
    CommitRefused,
    PushRefused,
    PullRequestRefused,
}

impl Outcome {
    /// The ledger part this outcome earns, or `None` where it earns none.
    ///
    /// No next step is added under any of them: the block above already
    /// carries the words and the way on, and the ledger's own rule is that
    /// a part points back at a block the run printed.
    pub fn part(&self) -> Option<String> {
        Some(match self {
            Outcome::Nothing => return None,
            Outcome::Committed(files) => format!("committed {files} file{}", plural(*files)),
            Outcome::Pushed(files) => {
                format!("committed and pushed {files} file{}", plural(*files))
            }
            Outcome::PullRequest(files) => format!(
                "committed {files} file{}, pull request open",
                plural(*files)
            ),
            Outcome::CommitRefused => "not committed".to_owned(),
            Outcome::PushRefused => "committed, not pushed".to_owned(),
            Outcome::PullRequestRefused => "committed and pushed, no pull request".to_owned(),
        })
    }

    /// A choice the person took that was refused or timed out. The run
    /// exits 1 for it, and the refusal is its own failure line rather than
    /// one more item in a verb's failure count.
    fn refused(&self) -> bool {
        matches!(
            self,
            Outcome::CommitRefused | Outcome::PushRefused | Outcome::PullRequestRefused
        )
    }
}

fn plural(n: usize) -> &'static str {
    match n {
        1 => "",
        _ => "s",
    }
}

/// This run: what the person typed, the flag they passed with it, and the
/// projects the offer has already been made in.
///
/// A run rather than a call, because "kendex asks at most once per run per
/// project" is a property of the run and several verbs execute more than
/// one plan into one scope. The command is the run's own identity — the
/// verb the person typed, which is what the default message names — and no
/// call site can compose a different one.
struct Session {
    flags: CommitFlags,
    command: String,
}

static SESSION: OnceLock<Session> = OnceLock::new();

/// What every project the offer reached answered, in the order they were
/// reached. The closing ledger reads its own scope's answer back.
static ANSWERED: Mutex<BTreeMap<PathBuf, Outcome>> = Mutex::new(BTreeMap::new());

/// Ctrl-C at the offer comes after the write,
/// so the scope keeps its place — its snapshot is still recorded and its
/// closing ledger line still printed — and only the offer is skipped, in
/// this project and in every project after it. The run then exits 130.
static CANCELLED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Whether the person cancelled at the offer, for the exit code.
pub fn cancelled() -> bool {
    CANCELLED.load(std::sync::atomic::Ordering::Relaxed)
}

/// Record the run before any verb dispatches: the command the person
/// typed, without its flags and arguments, and the flag that answers the
/// offer.
pub fn begin(command: &str, flags: CommitFlags) {
    let _ = SESSION.set(Session {
        flags,
        command: command.to_owned(),
    });
}

/// The record, whole even after a panic elsewhere poisoned the lock: an
/// answer already written is still the answer.
fn record_of() -> std::sync::MutexGuard<'static, BTreeMap<PathBuf, Outcome>> {
    ANSWERED
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// What one project answered, for its closing ledger line.
pub fn answered(scope: &Scope) -> Outcome {
    let Scope::Project { root } = scope else {
        return Outcome::Nothing;
    };
    record_of().get(root).cloned().unwrap_or(Outcome::Nothing)
}

fn record(root: &Path, outcome: Outcome) {
    record_of().insert(root.to_owned(), outcome);
}

/// Whether this project has already been asked in this run.
fn asked(root: &Path) -> bool {
    record_of().contains_key(root)
}

/// The offer, made once for one project scope after a write into it.
///
/// A refusal of the choice the person took is recorded and not returned:
/// the verb goes on to close its scope with the ledger line that names it,
/// and the run exits 1 at the end through [`refused`], with nothing further
/// printed. The block above already carries the words and the way on, and
/// a refusal is its own failure line, never one more item in a verb's
/// failure count.
pub fn after_writing(env: &Env, scope: &Scope, generated: &GeneratedPaths) -> CliResult {
    let Scope::Project { root } = scope else {
        return Ok(());
    };
    if asked(root) || cancelled() {
        return Ok(());
    }
    let outcome = match make(env, scope, root, generated) {
        // Nothing kendex owns had changed by this write: not an answer,
        // so a later report the same verb applies into this project can
        // still offer. `drift-hook` writes an empty report before the one
        // that renders the hook.
        Ok(None) => return Ok(()),
        Ok(Some(outcome)) => outcome,
        Err(error) if crate::ui::cancelled(error.as_ref()) => {
            CANCELLED.store(true, std::sync::atomic::Ordering::Relaxed);
            Outcome::Nothing
        }
        Err(error) => return Err(error),
    };
    record(root, outcome);
    Ok(())
}

/// Whether a choice the person took was refused or timed out in any
/// project this run reached, for the exit code.
pub fn refused() -> bool {
    record_of().values().any(Outcome::refused)
}

/// `None` where nothing kendex owns had changed, which records nothing;
/// every other way out is an outcome the run remembers for this project.
fn make(
    env: &Env,
    scope: &Scope,
    root: &std::path::Path,
    generated: &GeneratedPaths,
) -> Result<Option<Outcome>, Box<dyn std::error::Error>> {
    let default = Session {
        flags: CommitFlags::default(),
        command: String::new(),
    };
    let session = SESSION.get().unwrap_or(&default);
    let scan = match commit_offer::scan(scope, generated) {
        Ok(None) => return Ok(None),
        Ok(Some(scan)) => scan,
        // A read the offer is built from that would not run leaves the
        // offer unbuildable. The verb's own writes still stand, so this is
        // one line rather than a failure of the run.
        Err(failed) => {
            block::unreadable(root, &failed);
            return Ok(Some(Outcome::Nothing));
        }
    };
    let answered = session.flags.answered();
    // Two states where kendex owns changed files and cannot offer at all:
    // a commit would land somewhere nobody asked for.
    match &scan.branch {
        Branch::Detached => {
            block::no_branch(root, scan.count());
            return Ok(Some(Outcome::Nothing));
        }
        Branch::InProgress(operation) => {
            block::in_progress(root, scan.count(), *operation);
            return Ok(Some(Outcome::Nothing));
        }
        Branch::On(_) => {}
    }
    if answered == Some(Choice::Leave) {
        return Ok(Some(Outcome::Nothing));
    }
    if answered.is_none() {
        // The setting turns off the asking, not the choices — which is why
        // it is read here and not before a flag has had its say.
        if !commit_offer::asking(env) {
            return Ok(Some(Outcome::Nothing));
        }
        if !std::io::stdin().is_terminal() {
            block::no_terminal(root, scan.count());
            return Ok(Some(Outcome::Nothing));
        }
    }
    // A flag that already chose `commit` never pushes, so `gh` is not
    // asked about the branch's rules or a pull request. One that chose
    // `push` is, so a push the rules would refuse is refused before the
    // commit rather than after it.
    let probe = match answered {
        Some(Choice::Commit) => Probe::Skip,
        Some(Choice::Push) | Some(Choice::Pr) | Some(Choice::Leave) | None => Probe::Gh,
    };
    let offer = match commit_offer::offer(scan, &session.command, probe) {
        Ok(offer) => offer,
        Err(failed) => {
            block::unreadable(root, &failed);
            return Ok(Some(Outcome::Nothing));
        }
    };
    match answered {
        Some(choice) => {
            // A precondition that removed the choice a flag names refuses
            // with that precondition's reason, and the verb's writes still
            // stand. Nothing was committed, which is what the ledger says.
            if let Some(reason) = block::not_on_offer(&offer, choice) {
                block::flag_refused(&offer, choice, &reason);
                return Ok(Some(Outcome::CommitRefused));
            }
            routes::take(
                &offer,
                generated,
                choice,
                session.flags.message.clone(),
                Asking::No,
            )
            .map(Some)
        }
        None => ask(&offer, generated, session.flags.message.clone()).map(Some),
    }
}

/// Whether the person is at the prompt: a flag's answer takes its route
/// once and reports, where a person is asked again after a refusal the
/// design offers a way on from.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Asking {
    Yes,
    No,
}

/// Draw the block, take the answer, take the route.
fn ask(
    offer: &Offer,
    generated: &GeneratedPaths,
    message: Option<String>,
) -> Result<Outcome, Box<dyn std::error::Error>> {
    block::offer(offer);
    let choices = block::choices(offer);
    let choice = block::pick(&choices)?;
    routes::take(offer, generated, choice, message, Asking::Yes)
}
