//! Every line the terminal's offer draws, and the questions it asks.
//!
//! One file, so the wording is reviewed in one place beside the app's
//! `copy-commit-offer.ts`, which says the same things in the same order.
//!
//! Drawn from the components: a callout heads each block, a row says each
//! thing under it, a bare detail quotes another program's words, and the
//! questions are keyed choices. The plain rendering keeps the grammar the
//! offer always printed: the head at column 0, what is said under it
//! indented two spaces, another program's words four. Each function draws
//! for a style and hands back the lines, and the caller prints them; the
//! components escape every value, so a control character in a hook's
//! output cannot move a cursor or colour a line.

use std::path::Path;

use kendex_core::commit_offer::{
    Carry, Failed, Offer, Operation, Scan, Stale, Staleness, Step, Unavailable,
};

use super::{Asking, Choice};
use crate::ui::{self, Key, Span, Status, Style};

/// Enough paths to recognise what is there without burying the choices
/// under them. The same ten the CLI already shows of a list it cut.
pub const PATHS_SHOWN: usize = 10;

/// The head line of the block, carrying the scope label the way
/// `print_set_changes` and the ledger do. Every head is drawn from a scan
/// through [`headed_by`], so each prints the one count [`Scan::count`]
/// gives.
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

/// The line that opens a block.
fn headed(style: &Style, what: &str) -> Vec<String> {
    style.callout(what, None, &[])
}

/// The head line for what one scan carries.
fn headed_by(scan: &Scan) -> String {
    head(&scan.root, scan.count())
}

/// One thing said under the head.
fn said_as(style: &Style, status: Status, line: &str) -> Vec<String> {
    style.row(status, &[Span::Prose(line)], None)
}

/// Another program's words, quoted under the line they belong to. Drawn
/// whole: wrapped between words, a hook's aligned output would lose its
/// spacing, and a command would read as a shorter one.
fn quoted(style: &Style, line: &str) -> Vec<String> {
    style.detail(None, &[Span::Command(line)])
}

/// A line and nothing more: kendex owns changed files here and the offer
/// cannot be made.
pub fn no_branch(style: &Style, scan: &Scan) -> Vec<String> {
    headed(
        style,
        &format!("{}; this checkout is on no branch", headed_by(scan)),
    )
}

pub fn in_progress(style: &Style, scan: &Scan, operation: Operation) -> Vec<String> {
    headed(
        style,
        &format!(
            "{}; {} is in progress",
            headed_by(scan),
            operation.article()
        ),
    )
}

/// Nobody is at the terminal to answer, so the flags that would have are
/// named instead.
pub fn no_terminal(style: &Style, scan: &Scan) -> Vec<String> {
    headed(
        style,
        &format!(
            "{}; run again with --commit, --push, --pull-request or --leave",
            headed_by(scan)
        ),
    )
}

/// The head of a block whose files could not be read or vouched for.
fn unchecked(style: &Style, root: &Path) -> Vec<String> {
    headed(
        style,
        &format!(
            "{}: the files kendex wrote could not be checked",
            kendex_core::paths::slashed(root)
        ),
    )
}

/// A read the offer is built from would not run, so there is no offer to
/// make. The verb's own writes still stand.
pub fn unreadable(style: &Style, root: &Path, failed: &Failed) -> Vec<String> {
    let mut lines = unchecked(style, root);
    lines.extend(refusal(style, failed));
    lines
}

/// The packages could not be asked whether their files are current, so
/// the commit is not offered. The verb's own writes still stand.
pub fn not_vouched(style: &Style, root: &Path, why: &str) -> Vec<String> {
    let mut lines = unchecked(style, root);
    lines.extend(said_as(style, Status::Failed, why));
    lines
}

/// A package whose files in this repository the commit would carry out of
/// date: the head line, then each package and why, in place of the commit
/// choices.
pub fn stale(style: &Style, scan: &Scan, stale: &[Stale]) -> Vec<String> {
    let mut lines = headed(style, &headed_by(scan));
    for held in stale {
        let name = &held.disclosure.name;
        let mut say = |status, line: String, said: &[String]| {
            lines.extend(said_as(style, status, &line));
            for line in said {
                lines.extend(quoted(style, line));
            }
        };
        match &held.why {
            Staleness::NotSetUp => say(
                Status::Decision,
                format!(
                    "{name} is not set up in this checkout, so its files in this repository were not brought up to date"
                ),
                &[],
            ),
            Staleness::OutOfDate(said) => say(
                Status::Decision,
                format!("{name} says its files in this repository are out of date:"),
                said,
            ),
            Staleness::Unchecked(said) => say(
                Status::Decision,
                format!(
                    "{name} could not say whether its files in this repository are up to date:"
                ),
                said,
            ),
            Staleness::Split { left, said } => {
                match left.is_empty() {
                    false => say(
                        Status::Decision,
                        format!(
                            "the commit would carry some of {name}'s changed files and leave these out:"
                        ),
                        left,
                    ),
                    true => say(
                        Status::Decision,
                        format!(
                            "the commit would carry some of {name}'s changed files and leave out a change they were rendered from"
                        ),
                        &[],
                    ),
                }
                say(
                    Status::Notice,
                    format!("{name}'s check over the commit says:"),
                    said,
                );
            }
        }
    }
    lines.extend(said_as(
        style,
        Status::Notice,
        "committing now would carry those files out of date, so kendex does not offer the commit",
    ));
    lines
}

/// Where nobody is at the prompt to set the package up, or its setup ran
/// and it is still not ready: what is left to the person.
pub fn stale_way_on(style: &Style, set_up: bool) -> Vec<String> {
    match set_up {
        true => said_as(
            style,
            Status::Failed,
            "it is still not ready after its setup ran; nothing was committed",
        ),
        false => said_as(
            style,
            Status::Decision,
            "set it up here first: at a terminal, where kendex offers it, with --allow-repo-effects, or with Set up on its package page in the app",
        ),
    }
}

/// A commit that would split a package's changed files: no setup clears
/// it, so the files are left as diffs for the person to commit together.
pub fn split_way_on(style: &Style) -> Vec<String> {
    let mut lines = said_as(
        style,
        Status::Notice,
        "the repository's check renders from what a commit holds, so these belong in one commit",
    );
    lines.extend(said_as(
        style,
        Status::Decision,
        "they are left as diffs; commit them together yourself",
    ));
    lines
}

/// A setup chosen at the offer that did not run through.
pub fn set_up_failed(style: &Style, why: &str) -> Vec<String> {
    let mut lines = said_as(
        style,
        Status::Failed,
        "the setup did not finish; nothing was committed",
    );
    for line in why.lines() {
        lines.extend(quoted(style, line));
    }
    lines
}

/// What a person picks where a package holds the commit.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Held {
    SetUp,
    Leave,
}

/// The two choices a held offer carries, the disclosure of what each
/// package's setup changes above them, and the answer. The same block
/// every other setup's yes is given against. Enter leaves the files as
/// diffs.
pub fn pick_stale(stale: &[Stale]) -> std::io::Result<Held> {
    disclose_stale(stale);
    ui::choose(&stale_choices(&set_up_label(stale)))
}

/// What each held package's setup changes, the block a yes is given
/// against, whether a person or `--allow-repo-effects` gives it.
pub fn disclose_stale(stale: &[Stale]) {
    for held in stale {
        super::super::repo_effects::print_disclosure(&held.disclosure);
    }
}

/// The held offer's two choices: `s` sets the packages up, Enter leaves
/// the files as diffs.
pub fn stale_choices(set_up: &str) -> [(ui::Choice<'_>, Held); 2] {
    [
        (
            ui::Choice {
                key: Key::Char('s'),
                label: set_up,
            },
            Held::SetUp,
        ),
        (
            ui::Choice {
                key: Key::Enter,
                label: "leave them as diffs",
            },
            Held::Leave,
        ),
    ]
}

fn set_up_label(stale: &[Stale]) -> String {
    let names: Vec<&str> = stale
        .iter()
        .map(|held| held.disclosure.name.as_str())
        .collect();
    format!(
        "set up {} here, then offer the commit with {} files",
        names.join(" and "),
        match names.len() {
            1 => "its",
            _ => "their",
        }
    )
}

/// The offer itself: what changed, what kendex leaves alone, and why a
/// choice is missing. The choices follow, from [`pick`].
pub fn offer(style: &Style, offer: &Offer) -> Vec<String> {
    let paths = offer.scan.carried();
    let mut lines = headed(style, &headed_by(&offer.scan));
    for path in paths.iter().take(PATHS_SHOWN) {
        lines.extend(said_as(style, Status::Notice, path));
    }
    if paths.len() > PATHS_SHOWN {
        lines.extend(said_as(
            style,
            Status::Notice,
            &format!("… and {} more", paths.len() - PATHS_SHOWN),
        ));
    }
    lines.extend(left_out(style, &offer.scan));
    if offer.scan.others > 0 {
        lines.extend(said_as(
            style,
            Status::Notice,
            &format!(
                "{} other file{} in this repository changed; kendex leaves those alone",
                offer.scan.others,
                plural(offer.scan.others)
            ),
        ));
    }
    for line in reasons(offer) {
        lines.extend(said_as(style, Status::Notice, &line));
    }
    lines
}

/// The files the write changed that the commit leaves out, and why: one
/// held a change before this run, which a commit of the whole file would
/// carry too, or the reading that would tell had not run. Drawn in the
/// offer, and before the commit a flag answered, where no offer is drawn.
pub fn left_out(style: &Style, scan: &Scan) -> Vec<String> {
    let mut lines = Vec::new();
    let paths = scan.left_out();
    match &scan.carry {
        Carry::Read(_) => {
            for path in paths {
                lines.extend(said_as(
                    style,
                    Status::Decision,
                    &format!(
                        "{path} held changes before this run, so the commit leaves it out; commit it yourself"
                    ),
                ));
            }
        }
        Carry::Unread(failed) if !paths.is_empty() => {
            lines.extend(said_as(
                style,
                Status::Decision,
                &format!(
                    "kendex could not read which files held changes before this run, so the commit leaves out {} file{} it writes into and does not own whole; commit {} yourself",
                    paths.len(),
                    plural(paths.len()),
                    match paths.len() {
                        1 => "it",
                        _ => "them",
                    }
                ),
            ));
            for path in paths {
                lines.extend(quoted(style, path));
            }
            lines.extend(refusal(style, failed));
        }
        Carry::Unread(_) | Carry::Untaken => {}
    }
    lines
}

/// A precondition that removed a choice prints its reason as a line under
/// the paths, before the choices.
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
pub fn flag_refused(style: &Style, offer: &Offer, choice: Choice, reason: &str) -> Vec<String> {
    let mut lines = headed(style, &headed_by(&offer.scan));
    lines.extend(said_as(style, Status::Failed, reason));
    if choice == Choice::Push
        && offer.push == Err(Unavailable::PullRequestRequired)
        && not_on_offer(offer, Choice::Pr).is_none()
    {
        lines.extend(said_as(
            style,
            Status::Decision,
            "run again with --pull-request to commit on a new branch and open one",
        ));
    }
    lines
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

/// What each choice is pressed with. The letter is the one its label
/// leads with where that is free: `c`ommit, `p`ush, pull `r`equest, and
/// Enter for `leave`, the default.
fn key(choice: Choice) -> Key {
    match choice {
        Choice::Commit => Key::Char('c'),
        Choice::Push => Key::Char('p'),
        Choice::Pr => Key::Char('r'),
        Choice::Leave => Key::Enter,
    }
}

/// The choices as keyed buttons, each answering with its choice.
pub fn keyed(choices: &[(Choice, String)]) -> Vec<(ui::Choice<'_>, Choice)> {
    choices
        .iter()
        .map(|(choice, label)| {
            (
                ui::Choice {
                    key: key(*choice),
                    label,
                },
                *choice,
            )
        })
        .collect()
}

/// Draw the choices and read the one pressed. Enter leaves the files as
/// diffs; a key the offer does not show picks nothing.
pub fn pick(choices: &[(Choice, String)]) -> std::io::Result<Choice> {
    ui::choose(&keyed(choices))
}

/// The line the `pr` choice states before it runs: it moves the checkout,
/// and the person is told so before the message question rather than after
/// the branch exists.
pub fn will_move(style: &Style, new_branch: &str, from: &str) -> Vec<String> {
    said_as(
        style,
        Status::Notice,
        &format!("this checkout will move to {new_branch}; {from} stays where it is"),
    )
}

/// How the message question is answered.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Message {
    Use,
    Type,
}

pub const MESSAGE: [(ui::Choice<'static>, Message); 2] = [
    (
        ui::Choice {
            key: Key::Enter,
            label: "use this message",
        },
        Message::Use,
    ),
    (
        ui::Choice {
            key: Key::Char('e'),
            label: "type a different one",
        },
        Message::Type,
    ),
];

/// The message question. Enter keeps what is offered; `e` reads a line in
/// its place, and an empty line keeps it too.
pub fn message(offered: &str) -> std::io::Result<String> {
    ui::stderr(&said_as(
        &ui::style(),
        Status::Notice,
        &format!("message: {offered}"),
    ));
    match ui::choose(&MESSAGE)? {
        Message::Use => Ok(offered.to_owned()),
        Message::Type => typed_or(offered),
    }
}

/// The message to commit again with, where the person chose a different
/// one: read as typed straight away, since the choice already said so, and
/// an empty line keeps the one the commit was refused with.
pub fn different_message(refused: &str) -> std::io::Result<String> {
    ui::stderr(&said_as(
        &ui::style(),
        Status::Notice,
        &format!("type the new message; an empty line keeps: {refused}"),
    ));
    typed_or(refused)
}

fn typed_or(kept: &str) -> std::io::Result<String> {
    Ok(match ui::typed()? {
        typed if typed.is_empty() => kept.to_owned(),
        typed => typed,
    })
}

pub fn committed(style: &Style, sha: &str, files: usize, branch: Option<&str>) -> Vec<String> {
    said_as(
        style,
        Status::Done,
        &format!(
            "committed {files} file{} as {sha}{}",
            plural(files),
            match branch {
                Some(branch) => format!(" on {branch}"),
                None => String::new(),
            }
        ),
    )
}

pub fn pushed(style: &Style, remote: &str, branch: &str) -> Vec<String> {
    said_as(style, Status::Done, &format!("pushed to {remote}/{branch}"))
}

pub fn opened(style: &Style, url: &str) -> Vec<String> {
    said_as(style, Status::Done, &format!("opened {url}"))
}

pub fn now_on(style: &Style, branch: &str) -> Vec<String> {
    said_as(
        style,
        Status::Notice,
        &format!("this checkout is now on {branch}"),
    )
}

/// Nothing was left to commit by the time the commit ran.
pub fn nothing_to_commit(style: &Style) -> Vec<String> {
    said_as(
        style,
        Status::Notice,
        "nothing to commit; the files changed since the offer",
    )
}

/// What a step said when it refused, or the bound it ran past.
///
/// The words are shown whole, one line at a time, in order. Nothing is
/// summarised, reworded, truncated to a first line, or matched against a
/// pattern to decide what it means.
pub fn refusal(style: &Style, failed: &Failed) -> Vec<String> {
    if failed.timed_out() {
        return said_as(style, Status::Failed, &timed_out(failed.step));
    }
    let mut lines = said_as(style, Status::Notice, program_said(failed.step));
    for line in failed.said() {
        lines.extend(quoted(style, line));
    }
    lines
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
pub fn refused(style: &Style, what: &str, failed: &Failed) -> Vec<String> {
    // A step that ran out of time reads as that step's refusal with the
    // bound in place of the program's words, so the head line the refusal
    // would have carried is the bound line itself.
    let mut lines = match failed.timed_out() {
        true => Vec::new(),
        false => said_as(style, Status::Failed, what),
    };
    lines.extend(refusal(style, failed));
    lines
}

/// kendex staged paths it could not then unstage, against the rule that
/// the index ends as it began.
pub fn still_staged(style: &Style, count: usize) -> Vec<String> {
    said_as(
        style,
        Status::Failed,
        &format!(
            "kendex staged {count} file{} it could not unstage; they are still staged",
            plural(count)
        ),
    )
}

pub fn commit_is_on(style: &Style, branch: &str) -> Vec<String> {
    said_as(
        style,
        Status::Notice,
        &format!("the commit is on {branch} in this checkout; kendex did not undo it"),
    )
}

/// GitHub refused the push because the branch takes changes only through a
/// pull request: say so, and print the commands that put the commit on a
/// branch of its own and open the pull request, the words the recovery
/// below runs, from `commit_offer::by_hand`.
pub fn branch_rules(style: &Style, branch: &str, remote: &str, by_hand: &[String]) -> Vec<String> {
    let mut lines = said_as(
        style,
        Status::Decision,
        &format!("{branch} on {remote} accepts changes only through a pull request"),
    );
    lines.extend(said_as(
        style,
        Status::Notice,
        "to open one from this commit yourself:",
    ));
    for command in by_hand {
        lines.extend(quoted(style, command));
    }
    lines
}

pub fn branch_is_on(style: &Style, remote: &str, branch: &str) -> Vec<String> {
    said_as(
        style,
        Status::Decision,
        &format!("the branch {branch} is on {remote}; open the pull request yourself"),
    )
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

pub fn back_on(style: &Style, from: &str, branch: &str) -> Vec<String> {
    said_as(
        style,
        Status::Notice,
        &format!("this checkout is back on {from} and {branch} is gone"),
    )
}

/// After the recovery push: the local branch still carries the commit, and
/// the way to put it back is printed rather than run.
///
/// `--mixed` and not `--keep`: `--keep` restores the working tree to the
/// commit it resets to, which would take kendex's files off disk with no
/// warning, and `--mixed` moves the branch and leaves them where they are,
/// as the diffs the person started with.
pub fn how_to_put_back(style: &Style, from: &str, before: &str) -> Vec<String> {
    let mut lines = first_commit_stays(style, from);
    lines.extend(said_as(
        style,
        Status::Notice,
        &format!("to put {from} back where it was, leaving the files as diffs again:"),
    ));
    lines.extend(quoted(style, &format!("git reset --mixed {before}")));
    lines
}

/// The recovery pushed a first commit, so there is no commit to put the
/// branch back to and no reset line to print.
pub fn first_commit_stays(style: &Style, from: &str) -> Vec<String> {
    said_as(
        style,
        Status::Notice,
        &format!("{from} in this checkout still carries the commit"),
    )
}

/// A refused commit: its head line, then, where its words carry a
/// findings block, that block first.
///
/// With a person at the prompt the rest of what the commit check printed
/// waits behind a choice, and the second half is `true`. A flag's run has
/// nobody to choose, so the rest follows the block for the log, and
/// nothing waits.
pub fn commit_refused(style: &Style, failed: &Failed, asking: Asking) -> (Vec<String>, bool) {
    let head = commit_refused_head(failed);
    let Some(block) = failed.findings() else {
        return (refused(style, head, failed), false);
    };
    let said = failed.said();
    let mut lines = said_as(style, Status::Failed, head);
    lines.extend(said_as(
        style,
        Status::Notice,
        "the repository's commit check found problems:",
    ));
    for line in &said[block.clone()] {
        lines.extend(quoted(style, line));
    }
    let rest = said.len() - block.len();
    if rest == 0 {
        return (lines, false);
    }
    match asking {
        Asking::Yes => {
            lines.extend(said_as(
                style,
                Status::Notice,
                &format!("the commit check printed {rest} more line{}", plural(rest)),
            ));
            (lines, true)
        }
        Asking::No => {
            lines.extend(said_as(style, Status::Notice, "the rest of what git said:"));
            for line in said[..block.start].iter().chain(&said[block.end..]) {
                lines.extend(quoted(style, line));
            }
            (lines, false)
        }
    }
}

/// Everything a refused commit's words held, in the order git gave them.
pub fn everything(style: &Style, failed: &Failed) -> Vec<String> {
    let mut lines = said_as(style, Status::Notice, program_said(failed.step));
    for line in failed.said() {
        lines.extend(quoted(style, line));
    }
    lines
}

/// The ways on from a refused commit, as keyed buttons. `more` adds the
/// choice that shows what the refusal left unshown.
pub fn after_refusal_choices(more: bool) -> Vec<(ui::Choice<'static>, AfterRefusal)> {
    let choice = |key, label| ui::Choice { key, label };
    let mut choices = vec![
        (
            choice(Key::Char('a'), "commit again with the same message"),
            AfterRefusal::Retry(Retry::Same),
        ),
        (
            choice(Key::Char('m'), "commit again with a different message"),
            AfterRefusal::Retry(Retry::Different),
        ),
    ];
    if more {
        choices.push((
            choice(Key::Char('?'), "show everything the commit check printed"),
            AfterRefusal::Show,
        ));
    }
    choices.push((
        choice(Key::Enter, "leave them as diffs"),
        AfterRefusal::Retry(Retry::Leave),
    ));
    choices
}

/// The ways on from a refused commit, and the answer. Enter leaves the
/// files as diffs.
pub fn after_refusal(more: bool) -> std::io::Result<AfterRefusal> {
    ui::choose(&after_refusal_choices(more))
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
pub const AFTER_PUSH_REFUSAL: [(ui::Choice<'static>, Recover); 2] = [
    (
        ui::Choice {
            key: Key::Char('r'),
            label: "push the commit to a new branch and open a pull request",
        },
        Recover::PullRequest,
    ),
    (
        ui::Choice {
            key: Key::Enter,
            label: "leave it here",
        },
        Recover::Leave,
    ),
];

pub fn after_push_refusal() -> std::io::Result<Recover> {
    ui::choose(&AFTER_PUSH_REFUSAL)
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
