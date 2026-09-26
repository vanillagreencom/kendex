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

use kendex_core::commit_offer::{
    Failed, Offer, Operation, Scan, Stale, Staleness, Step, Unavailable,
};

use super::super::say;
use super::{Asking, Choice};
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

/// The packages could not be asked whether their files are current, so
/// the commit is not offered. The verb's own writes still stand.
pub fn not_vouched(root: &Path, why: &str) {
    say(&format!(
        "{}: the files kendex wrote could not be checked",
        kendex_core::paths::slashed(root)
    ));
    detail(why);
}

/// A package whose files in this repository the commit would carry out of
/// date: the head line, then each package and why, in place of the commit
/// choices.
pub fn stale(scan: &Scan, stale: &[Stale]) {
    say(&head(&scan.root, scan.count()));
    for held in stale {
        let name = &held.declared.name;
        match &held.why {
            Staleness::NotSetUp => detail(&format!(
                "{name} is not set up in this checkout, so its files in this repository were not brought up to date"
            )),
            Staleness::OutOfDate(said) => {
                detail(&format!(
                    "{name} says its files in this repository are out of date:"
                ));
                for line in said {
                    quoted(line);
                }
            }
            Staleness::Unchecked(said) => {
                detail(&format!(
                    "{name} could not say whether its files in this repository are up to date:"
                ));
                for line in said {
                    quoted(line);
                }
            }
        }
    }
    detail(
        "committing now would carry those files out of date, so kendex does not offer the commit",
    );
}

/// Where nobody is at the prompt to set the package up, or its setup ran
/// and it is still not ready: what is left to the person.
pub fn stale_way_on(set_up: bool) {
    match set_up {
        true => detail("it is still not ready after its setup ran; nothing was committed"),
        false => detail(
            "set it up here first: at a terminal, where kendex offers it, or with Set up on its package page in the app",
        ),
    }
}

/// A setup chosen at the offer that did not run through.
pub fn set_up_failed(why: &str) {
    detail("the setup did not finish; nothing was committed");
    for line in why.lines() {
        quoted(line);
    }
}

/// What a person picks where a package holds the commit.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Held {
    SetUp,
    Leave,
}

/// The two choices a held offer carries, each package's own account of
/// what its setup changes above them, and the answer. As with the offer,
/// any answer but the setup's number leaves the files as diffs.
pub fn pick_stale(stale: &[Stale]) -> std::io::Result<Held> {
    for held in stale {
        detail(&format!(
            "setting {} up: {}",
            held.declared.name, held.declared.effects.summary
        ));
    }
    let names: Vec<&str> = stale
        .iter()
        .map(|held| held.declared.name.as_str())
        .collect();
    detail(&format!(
        "1  set up {} here, then offer the commit with {} files",
        names.join(" and "),
        match names.len() {
            1 => "its",
            _ => "their",
        }
    ));
    detail("2  leave them as diffs");
    let typed = ui::ask("1-2, or Enter to leave them as diffs: ")?;
    Ok(match typed.trim() {
        "1" => Held::SetUp,
        _ => Held::Leave,
    })
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
/// reason, and nothing is asked. A push the branch's rules would refuse
/// names the flag that takes the route they allow, where that route is on
/// offer.
pub fn flag_refused(offer: &Offer, choice: Choice, reason: &str) {
    say(&head(&offer.scan.root, offer.scan.count()));
    detail(reason);
    if choice == Choice::Push
        && offer.push == Err(Unavailable::PullRequestRequired)
        && not_on_offer(offer, Choice::Pr).is_none()
    {
        detail("run again with --pull-request to commit on a new branch and open one");
    }
}

fn said(why: &Unavailable) -> String {
    match why {
        Unavailable::NoRemote => "this repository has no remote".to_owned(),
        Unavailable::RemoteNotDecidable => {
            "this branch tracks no remote and the repository has more than one".to_owned()
        }
        Unavailable::GhMissing => "gh is not installed".to_owned(),
        Unavailable::GhSaid(line) => format!("gh said: {line}"),
        Unavailable::PullRequestRequired => {
            "this branch's rules on GitHub accept changes only through a pull request".to_owned()
        }
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

/// GitHub refused the push because the branch takes changes only through a
/// pull request: say so, and print the commands that put the commit on a
/// branch of its own and open the pull request, the words the recovery
/// below runs, from `commit_offer::by_hand`.
pub fn branch_rules(branch: &str, remote: &str, by_hand: &[String]) {
    detail(&format!(
        "{branch} on {remote} accepts changes only through a pull request"
    ));
    detail("to open one from this commit yourself:");
    for command in by_hand {
        quoted(command);
    }
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

/// A refused commit: its head line, then, where its words carry a
/// findings block, that block first.
///
/// With a person at the prompt the rest of what the commit check printed
/// waits behind a choice, and this returns `true`. A flag's run has nobody
/// to choose, so the rest follows the block for the log, and nothing waits.
pub fn commit_refused(failed: &Failed, asking: Asking) -> bool {
    let head = commit_refused_head(failed);
    let Some(block) = failed.findings() else {
        refused(head, failed);
        return false;
    };
    let said = failed.said();
    detail(head);
    detail("the repository's commit check found problems:");
    for line in &said[block.clone()] {
        quoted(line);
    }
    let rest = said.len() - block.len();
    if rest == 0 {
        return false;
    }
    match asking {
        Asking::Yes => {
            detail(&format!(
                "the commit check printed {rest} more line{}",
                plural(rest)
            ));
            true
        }
        Asking::No => {
            detail("the rest of what git said:");
            for line in said[..block.start].iter().chain(&said[block.end..]) {
                quoted(line);
            }
            false
        }
    }
}

/// Everything a refused commit's words held, in the order git gave them.
pub fn everything(failed: &Failed) {
    detail(program_said(failed.step));
    for line in failed.said() {
        quoted(line);
    }
}

/// The ways on from a refused commit. `more` adds the choice that shows
/// what the refusal left unshown.
pub fn after_refusal(more: bool) -> std::io::Result<AfterRefusal> {
    let mut labels = vec![
        (
            AfterRefusal::Retry(Retry::Same),
            "commit again with the same message",
        ),
        (
            AfterRefusal::Retry(Retry::Different),
            "commit again with a different message",
        ),
    ];
    if more {
        labels.push((
            AfterRefusal::Show,
            "show everything the commit check printed",
        ));
    }
    labels.push((AfterRefusal::Retry(Retry::Leave), "leave them as diffs"));
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
        .unwrap_or(AfterRefusal::Retry(Retry::Leave)))
}

/// What a person picks after a refused commit.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Retry {
    Same,
    Different,
    Leave,
}

/// An answer to [`after_refusal`]: a way on, or asking to see what the
/// refusal left unshown, which is answered by asking again.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AfterRefusal {
    Retry(Retry),
    Show,
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
