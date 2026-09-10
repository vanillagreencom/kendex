//! Every line the terminal's offer prints, and the two questions it asks.
//!
//! One file, so the wording is reviewed in one place beside the app's
//! `copy-commit-offer.ts`, which says the same things in the same order.
//!
//! The grammar is the one every verb already writes in: a line at column 0
//! opens a block, two spaces make a line detail of it, and four spaces
//! quote another program's words inside that detail. Every line goes
//! through `say`, which escapes it: a control character in a hook's output
//! must not move a cursor or colour a line.

use std::path::Path;

use kendex_core::commit_offer::{Failed, Offer, Operation, Step, Unavailable};

use super::super::say;
use super::Choice;
use crate::ui;

/// Enough paths to recognise what is there without burying the choices
/// under them. The same ten the CLI already shows of a list it cut.
pub const PATHS_SHOWN: usize = 10;

/// The head line of the block, carrying the scope label the way
/// `print_set_changes` and the ledger do.
pub fn head(root: &Path, count: usize) -> String {
    format!(
        "{}: {count} file{} kendex wrote {} not committed",
        kendex_core::paths::slashed(root),
        plural(count),
        match count {
            1 => "is",
            _ => "are",
        }
    )
}

fn plural(n: usize) -> &'static str {
    match n {
        1 => "",
        _ => "s",
    }
}

fn detail(line: &str) {
    say(&format!("  {line}"));
}

/// Another program's words, quoted inside the detail they belong to.
fn quoted(line: &str) {
    say(&format!("    {line}"));
}

/// A line and nothing more: kendex owns changed files here and the offer
/// cannot be made.
pub fn no_branch(root: &Path, count: usize) {
    say(&format!(
        "{}; this checkout is on no branch",
        head(root, count)
    ));
}

pub fn in_progress(root: &Path, count: usize, operation: Operation) {
    say(&format!(
        "{}; {} is in progress",
        head(root, count),
        operation.article()
    ));
}

/// Nobody is at the terminal to answer, so the flags that would have are
/// named instead.
pub fn no_terminal(root: &Path, count: usize) {
    say(&format!(
        "{}; run again with --commit, --push, --pull-request or --leave",
        head(root, count)
    ));
}

/// A read the offer is built from would not run, so there is no offer to
/// make. The verb's own writes still stand.
pub fn unreadable(root: &Path, failed: &Failed) {
    say(&format!(
        "{}: the files kendex wrote could not be checked",
        kendex_core::paths::slashed(root)
    ));
    refusal(failed);
}

/// The offer itself: what changed, what kendex leaves alone, and the
/// choices.
pub fn offer(offer: &Offer) {
    say(&head(&offer.scan.root, offer.scan.count()));
    for path in offer.scan.owned.iter().take(PATHS_SHOWN) {
        detail(&path.path);
    }
    if offer.scan.owned.len() > PATHS_SHOWN {
        detail(&format!(
            "… and {} more",
            offer.scan.owned.len() - PATHS_SHOWN
        ));
    }
    if !offer.scan.shared.is_empty() {
        detail(&format!(
            "kendex also changed {} shared file{}; it writes one key in each, so",
            offer.scan.shared.len(),
            plural(offer.scan.shared.len())
        ));
        detail("committing them would commit your own changes to them too");
        for path in &offer.scan.shared {
            quoted(path);
        }
    }
    if offer.scan.others > 0 {
        detail(&format!(
            "{} other file{} in this repository changed; kendex leaves those alone",
            offer.scan.others,
            plural(offer.scan.others)
        ));
    }
    for line in reasons(offer) {
        detail(&line);
    }
}

/// A precondition that removed a choice prints its reason as a detail line
/// under the paths, before the numbered list.
pub fn reasons(offer: &Offer) -> Vec<String> {
    let mut lines = Vec::new();
    if let Err(why) = &offer.push {
        lines.push(format!("no push: {}", said(why)));
    }
    if let Err(why) = &offer.pull_request {
        lines.push(format!("no pull request: {}", said(why)));
    }
    lines
}

/// Why the choice a flag named is not on offer, as the reason line the
/// offer would have printed for it, or `None` where the choice stands.
///
/// A pull request already open for this branch removes `pr` the way a
/// precondition does, and a flag naming it gets the same kind of answer.
pub fn not_on_offer(offer: &Offer, choice: Choice) -> Option<String> {
    match choice {
        Choice::Commit | Choice::Leave => None,
        Choice::Push => offer
            .push
            .as_ref()
            .err()
            .map(|why| format!("no push: {}", said(why))),
        Choice::Pr => match (&offer.pull_request, &offer.open) {
            (Err(why), _) => Some(format!("no pull request: {}", said(why))),
            (Ok(()), Some(open)) => Some(format!(
                "no pull request: pull request #{} is already open for this branch",
                open.number
            )),
            (Ok(()), None) => None,
        },
    }
}

/// A flag named a choice that is not on offer: the head line, then the
/// reason, and nothing is asked.
pub fn flag_refused(offer: &Offer, reason: &str) {
    say(&head(&offer.scan.root, offer.scan.count()));
    detail(reason);
}

fn said(why: &Unavailable) -> String {
    match why {
        Unavailable::NoRemote => "this repository has no remote".to_owned(),
        Unavailable::RemoteNotDecidable => {
            "this branch tracks no remote and the repository has more than one".to_owned()
        }
        Unavailable::GhMissing => "gh is not installed".to_owned(),
        Unavailable::GhSaid(line) => format!("gh said: {line}"),
    }
}

/// The choices this offer carries, in the order the design fixes, skipping
/// the ones the preconditions removed. `leave` is always last and is
/// always the default.
pub fn choices(offer: &Offer) -> Vec<(Choice, String)> {
    let mut choices = vec![(Choice::Commit, "commit them".to_owned())];
    // A push stands only with a remote to push to; the pair is how the
    // offer was built, and reading both keeps that true here.
    if let (Ok(()), Some(remote)) = (&offer.push, &offer.remote) {
        choices.push((
            Choice::Push,
            match &offer.open {
                Some(open) => format!(
                    "commit them and add a commit to pull request #{}",
                    open.number
                ),
                None => format!("commit them and push to {}/{}", remote.name, offer.branch),
            },
        ));
    }
    // Where a pull request is already open for this branch, `pr` is not
    // offered: the branch already has one.
    if offer.pull_request.is_ok() && offer.open.is_none() {
        choices.push((
            Choice::Pr,
            "commit them on a new branch and open a pull request".to_owned(),
        ));
    }
    choices.push((Choice::Leave, "leave them as diffs".to_owned()));
    choices
}

/// Print the numbered list and read the answer.
///
/// An answer that is not one of the printed numbers is `leave` — a typo, a
/// `9`, an `x`, a bare Enter and an end of input alike. That is how the
/// CLI's confirm already reads its answer, and it puts the safe outcome
/// behind every wrong key rather than behind a retry loop nobody asked for.
pub fn pick(choices: &[(Choice, String)]) -> std::io::Result<Choice> {
    for (nth, (_, label)) in choices.iter().enumerate() {
        detail(&format!("{}  {label}", nth + 1));
    }
    let typed = ui::ask(&format!(
        "1-{}, or Enter to {}: ",
        choices.len(),
        choices
            .last()
            .map(|(_, label)| label.as_str())
            .unwrap_or("leave them as diffs")
    ))?;
    Ok(picked(choices, &typed))
}

pub fn picked(choices: &[(Choice, String)], typed: &str) -> Choice {
    typed
        .trim()
        .parse::<usize>()
        .ok()
        .filter(|nth| *nth >= 1 && *nth <= choices.len())
        .map(|nth| choices[nth - 1].0)
        .unwrap_or(Choice::Leave)
}

/// The line the `pr` choice states before it runs: it moves the checkout,
/// and the person is told so before the message question rather than after
/// the branch exists.
pub fn will_move(new_branch: &str, from: &str) {
    detail(&format!(
        "this checkout will move to {new_branch}; {from} stays where it is"
    ));
}

/// The message question. An empty answer accepts what is offered.
pub fn message(offered: &str) -> std::io::Result<String> {
    detail(&format!("message: {offered}"));
    let typed = ui::ask("press Enter to use this message, or type a different one: ")?;
    Ok(match typed.trim() {
        "" => offered.to_owned(),
        given => given.to_owned(),
    })
}

pub fn committed(sha: &str, files: usize, branch: Option<&str>) {
    detail(&format!(
        "committed {files} file{} as {sha}{}",
        plural(files),
        match branch {
            Some(branch) => format!(" on {branch}"),
            None => String::new(),
        }
    ));
}

pub fn pushed(remote: &str, branch: &str) {
    detail(&format!("pushed to {remote}/{branch}"));
}

pub fn opened(url: &str) {
    detail(&format!("opened {url}"));
}

pub fn now_on(branch: &str) {
    detail(&format!("this checkout is now on {branch}"));
}

/// Nothing was left to commit by the time the commit ran.
pub fn nothing_to_commit() {
    detail("nothing to commit; the files changed since the offer");
}

/// What a step said when it refused, or the bound it ran past.
///
/// The words are shown whole, one line at a time, in order. Nothing is
/// summarised, reworded, truncated to a first line, or matched against a
/// pattern to decide what it means.
pub fn refusal(failed: &Failed) {
    if failed.timed_out() {
        detail(&timed_out(failed.step));
        return;
    }
    detail(program_said(failed.step));
    for line in failed.said() {
        quoted(line);
    }
}

/// The line a step that ran out of time prints in place of the program's
/// words: the step's name and its bound.
pub fn timed_out(step: Step) -> String {
    format!(
        "{} did not finish within {} seconds",
        step.name(),
        step.seconds()
    )
}

/// Whose words follow: gh's for the two steps that run it, git's for the
/// rest.
pub fn program_said(step: Step) -> &'static str {
    match step {
        Step::Probe | Step::PullRequest => "gh said:",
        Step::Read
        | Step::Stage
        | Step::Commit
        | Step::Unstage
        | Step::Restore
        | Step::Branch
        | Step::SwitchBack
        | Step::RemoveBranch
        | Step::Push => "git said:",
    }
}

/// The head line of a refusal, before its words.
pub fn refused(what: &str, failed: &Failed) {
    // A step that ran out of time reads as that step's refusal with the
    // bound in place of the program's words, so the head line the refusal
    // would have carried is the bound line itself.
    if !failed.timed_out() {
        detail(what);
    }
    refusal(failed);
}

/// kendex staged paths it could not then unstage, against the rule that
/// the index ends as it began.
pub fn still_staged(count: usize) {
    detail(&format!(
        "kendex staged {count} file{} it could not unstage; they are still staged",
        plural(count)
    ));
}

pub fn commit_is_on(branch: &str) {
    detail(&format!(
        "the commit is on {branch} in this checkout; kendex did not undo it"
    ));
}

pub fn branch_is_on(remote: &str, branch: &str) {
    detail(&format!(
        "the branch {branch} is on {remote}; open the pull request yourself"
    ));
}

/// The head line of a commit that did not happen: the staging is its own
/// step and its own line, because it runs before any commit and the
/// commit's line would name something that never ran.
pub fn commit_refused_head(failed: &Failed) -> &'static str {
    match failed.step {
        // The set is re-derived before the commit, and that read can fail
        // like the one the offer was built from.
        Step::Read => "the files could not be checked",
        Step::Stage => "the files could not be staged",
        _ => "the commit was refused",
    }
}

/// The head line of a `git switch -` or `git branch -d` that refused after
/// a commit on the branch kendex made did not happen. The run stops there.
pub const NOT_PUT_BACK: &str = "the checkout could not be put back";

pub fn back_on(from: &str, branch: &str) {
    detail(&format!(
        "this checkout is back on {from} and {branch} is gone"
    ));
}

/// After the recovery push: the local branch still carries the commit, and
/// the way to put it back is printed rather than run.
///
/// `--mixed` and not `--keep`: `--keep` restores the working tree to the
/// commit it resets to, which would take kendex's files off disk with no
/// warning, and `--mixed` moves the branch and leaves them where they are,
/// as the diffs the person started with.
pub fn how_to_put_back(from: &str, before: &str) {
    detail(&format!("{from} in this checkout still carries the commit"));
    detail(&format!(
        "to put {from} back where it was, leaving the files as diffs again:"
    ));
    quoted(&format!("git reset --mixed {before}"));
}

/// The recovery pushed a first commit, so there is no commit to put the
/// branch back to and no reset line to print.
pub fn first_commit_stays(from: &str) {
    detail(&format!("{from} in this checkout still carries the commit"));
}

/// The three ways on from a refused commit.
pub fn after_refusal() -> std::io::Result<Retry> {
    let labels = [
        (Retry::Same, "commit again with the same message"),
        (Retry::Different, "commit again with a different message"),
        (Retry::Leave, "leave them as diffs"),
    ];
    for (nth, (_, label)) in labels.iter().enumerate() {
        detail(&format!("{}  {label}", nth + 1));
    }
    let typed = ui::ask(&format!(
        "1-{}, or Enter to leave them as diffs: ",
        labels.len()
    ))?;
    Ok(typed
        .trim()
        .parse::<usize>()
        .ok()
        .filter(|nth| *nth >= 1 && *nth <= labels.len())
        .map(|nth| labels[nth - 1].0)
        .unwrap_or(Retry::Leave))
}

/// What a person picks after a refused commit.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Retry {
    Same,
    Different,
    Leave,
}

/// The two ways on from a refused push, where a pull request is available.
pub fn after_push_refusal() -> std::io::Result<Recover> {
    detail("1  push the commit to a new branch and open a pull request");
    detail("2  leave it here");
    let typed = ui::ask("1-2, or Enter to leave it here: ")?;
    Ok(match typed.trim() {
        "1" => Recover::PullRequest,
        _ => Recover::Leave,
    })
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Recover {
    PullRequest,
    Leave,
}

/// The choices offered again after the `pr` route could not make its
/// branch: the same list without `pr`.
pub fn without_pull_request(offer: &Offer) -> Vec<(Choice, String)> {
    choices(offer)
        .into_iter()
        .filter(|(choice, _)| *choice != Choice::Pr)
        .collect()
}
