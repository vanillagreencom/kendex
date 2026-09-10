//! The terminal's rows, pinned to the design's words. The states are
//! driven end to end through the binary in `tests/commit_offer_cli.rs`;
//! what that child cannot reach — the interactive block's lines, its
//! numbered choices and how an answer is read — is composed here.

use std::path::{Path, PathBuf};

use kendex_core::commit_offer::{
    Branch, Failed, Offer, OpenPullRequest, Operation, Owned, Refusal, Remote, Scan, Step,
    Unavailable,
};

use super::block;
use super::{Choice, Outcome};

fn scan() -> Scan {
    Scan {
        root: PathBuf::from("/home/method/dev/site"),
        owned: (1..=12)
            .map(|n| Owned {
                path: format!(".claude/skills/{n}/SKILL.md"),
                untracked: false,
            })
            .collect(),
        shared: vec![".claude/settings.json".to_owned()],
        others: 4,
        branch: Branch::On("main".to_owned()),
    }
}

fn origin() -> Remote {
    Remote {
        name: "origin".to_owned(),
        url: "https://github.com/acme/site.git".to_owned(),
        tracked: true,
    }
}

fn offer() -> Offer {
    Offer {
        scan: scan(),
        branch: "main".to_owned(),
        remote: Some(origin()),
        push: Ok(()),
        pull_request: Ok(()),
        open: None,
        message: "chore: kendex refresh".to_owned(),
        new_branch: "kendex/renders".to_owned(),
    }
}

fn labels(choices: &[(Choice, String)]) -> Vec<&str> {
    choices.iter().map(|(_, label)| label.as_str()).collect()
}

/// The head line, and the three single lines the preconditions print
/// with it.
#[test]
fn the_head_line_carries_the_scope_and_the_count() {
    let root = Path::new("/home/method/dev/site");
    assert_eq!(
        block::head(root, 12),
        "/home/method/dev/site: 12 files kendex wrote are not committed"
    );
    assert_eq!(
        block::head(root, 1),
        "/home/method/dev/site: 1 file kendex wrote is not committed"
    );
    assert_eq!(Operation::Rebase.article(), "a rebase");
}

/// The four choices in the design's order, renumbered as the preconditions
/// remove them, `leave` always last; an open pull request rewords `push`
/// and takes `pr` away. One row per precondition.
#[test]
fn the_choices_are_numbered_in_order_skipping_the_removed_ones() {
    type Shape = fn(&mut Offer);
    let rows: [(&str, Shape, &[&str]); 4] = [
        (
            "everything available",
            |_| {},
            &[
                "commit them",
                "commit them and push to origin/main",
                "commit them on a new branch and open a pull request",
                "leave them as diffs",
            ],
        ),
        (
            "no remote",
            |offer| {
                offer.remote = None;
                offer.push = Err(Unavailable::NoRemote);
                offer.pull_request = Err(Unavailable::NoRemote);
            },
            &["commit them", "leave them as diffs"],
        ),
        (
            "gh missing",
            |offer| offer.pull_request = Err(Unavailable::GhMissing),
            &[
                "commit them",
                "commit them and push to origin/main",
                "leave them as diffs",
            ],
        ),
        (
            "a pull request already open",
            |offer| {
                offer.open = Some(OpenPullRequest {
                    number: 41,
                    url: "https://github.com/acme/site/pull/41".to_owned(),
                });
            },
            &[
                "commit them",
                "commit them and add a commit to pull request #41",
                "leave them as diffs",
            ],
        ),
    ];
    for (what, shape, want) in rows {
        let mut shaped = offer();
        shape(&mut shaped);
        assert_eq!(labels(&block::choices(&shaped)), want, "{what}");
    }
    assert_eq!(
        labels(&block::without_pull_request(&offer())),
        [
            "commit them",
            "commit them and push to origin/main",
            "leave them as diffs",
        ]
    );
}

/// The reason a removed choice prints, one row per precondition, and the
/// same row a flag naming that choice is refused with.
#[test]
fn a_removed_choice_prints_its_reason() {
    type Shape = fn(&mut Offer);
    type Row = (
        &'static str,
        Shape,
        &'static [&'static str],
        &'static [(Choice, Option<&'static str>)],
    );
    let rows: [Row; 6] = [
        (
            "everything available",
            |_| {},
            &[],
            &[(Choice::Push, None), (Choice::Pr, None)],
        ),
        (
            "no remote",
            |offer| {
                offer.push = Err(Unavailable::NoRemote);
                offer.pull_request = Err(Unavailable::NoRemote);
            },
            &[
                "no push: this repository has no remote",
                "no pull request: this repository has no remote",
            ],
            &[],
        ),
        (
            "several remotes, none tracked",
            |offer| {
                offer.push = Err(Unavailable::RemoteNotDecidable);
                offer.pull_request = Err(Unavailable::RemoteNotDecidable);
            },
            &[
                "no push: this branch tracks no remote and the repository has more than one",
                "no pull request: this branch tracks no remote and the repository has more than one",
            ],
            &[(
                Choice::Push,
                Some("no push: this branch tracks no remote and the repository has more than one"),
            )],
        ),
        (
            "gh missing",
            |offer| offer.pull_request = Err(Unavailable::GhMissing),
            &["no pull request: gh is not installed"],
            &[(Choice::Pr, Some("no pull request: gh is not installed"))],
        ),
        (
            "gh said why",
            |offer| {
                offer.pull_request = Err(Unavailable::GhSaid(
                    "To get started with GitHub CLI, please run:  gh auth login".to_owned(),
                ));
            },
            &[
                "no pull request: gh said: To get started with GitHub CLI, please run:  gh auth login",
            ],
            &[],
        ),
        (
            "a pull request already open",
            |offer| {
                offer.open = Some(OpenPullRequest {
                    number: 41,
                    url: String::new(),
                });
            },
            &[],
            &[
                (
                    Choice::Pr,
                    Some("no pull request: pull request #41 is already open for this branch"),
                ),
                (Choice::Push, None),
            ],
        ),
    ];
    for (what, shape, reasons, refused) in rows {
        let mut shaped = offer();
        shape(&mut shaped);
        assert_eq!(block::reasons(&shaped), reasons, "{what}");
        for (choice, reason) in refused {
            assert_eq!(
                block::not_on_offer(&shaped, *choice).as_deref(),
                *reason,
                "{what}: {choice:?}"
            );
        }
    }
}

/// An answer that is not one of the printed numbers is `leave`: a typo, a
/// `9`, an `x`, a bare Enter and an end of input alike.
#[test]
fn an_answer_off_the_list_leaves_the_files_as_diffs() {
    let choices = block::choices(&offer());
    assert_eq!(block::picked(&choices, "1"), Choice::Commit);
    assert_eq!(block::picked(&choices, " 2\n"), Choice::Push);
    assert_eq!(block::picked(&choices, "3"), Choice::Pr);
    assert_eq!(block::picked(&choices, "4"), Choice::Leave);
    for off in ["", "0", "5", "9", "x", "yes"] {
        assert_eq!(block::picked(&choices, off), Choice::Leave, "{off:?}");
    }
    // Renumbered: with `pr` gone, `3` is `leave`.
    let without = block::without_pull_request(&offer());
    assert_eq!(block::picked(&without, "3"), Choice::Leave);
}

/// A timed-out step reads as that step's refusal with the bound in place
/// of the program's words; the words otherwise follow `git said:` or
/// `gh said:`.
#[test]
fn a_timeout_names_the_step_and_its_bound() {
    assert_eq!(
        block::timed_out(Step::Commit),
        "the commit did not finish within 300 seconds"
    );
    assert_eq!(
        block::timed_out(Step::Push),
        "the push did not finish within 120 seconds"
    );
    assert_eq!(
        block::timed_out(Step::PullRequest),
        "the pull request did not finish within 120 seconds"
    );
    assert_eq!(
        block::timed_out(Step::Branch),
        "the branch did not finish within 30 seconds"
    );
    assert_eq!(block::program_said(Step::Commit), "git said:");
    assert_eq!(block::program_said(Step::Push), "git said:");
    assert_eq!(block::program_said(Step::Probe), "gh said:");
    assert_eq!(block::program_said(Step::PullRequest), "gh said:");
    let staging = Failed {
        step: Step::Stage,
        refusal: Refusal::Said(vec!["fatal: index.lock".to_owned()]),
    };
    assert_eq!(
        block::commit_refused_head(&staging),
        "the files could not be staged"
    );
    let unread = Failed {
        step: Step::Read,
        refusal: Refusal::Said(vec!["fatal: not a git repository".to_owned()]),
    };
    assert_eq!(
        block::commit_refused_head(&unread),
        "the files could not be checked"
    );
    assert_eq!(
        block::commit_refused_head(&Failed {
            step: Step::Commit,
            refusal: Refusal::TimedOut
        }),
        "the commit was refused"
    );
    let failed = Failed {
        step: Step::Commit,
        refusal: Refusal::TimedOut,
    };
    assert!(failed.timed_out());
}

/// The closing ledger's part for each outcome, and which outcomes exit 1.
#[test]
fn the_ledger_part_names_what_the_offer_did() {
    for (outcome, part) in [
        (Outcome::Nothing, None),
        (Outcome::Committed(12), Some("committed 12 files")),
        (Outcome::Committed(1), Some("committed 1 file")),
        (Outcome::Pushed(12), Some("committed and pushed 12 files")),
        (
            Outcome::PullRequest(12),
            Some("committed 12 files, pull request open"),
        ),
        (Outcome::CommitRefused, Some("not committed")),
        (Outcome::PushRefused, Some("committed, not pushed")),
        (
            Outcome::PullRequestRefused,
            Some("committed and pushed, no pull request"),
        ),
    ] {
        assert_eq!(outcome.part().as_deref(), part, "{outcome:?}");
    }
    for outcome in [
        Outcome::Nothing,
        Outcome::Committed(1),
        Outcome::Pushed(1),
        Outcome::PullRequest(1),
    ] {
        assert!(!outcome.refused(), "{outcome:?}");
    }
    for outcome in [
        Outcome::CommitRefused,
        Outcome::PushRefused,
        Outcome::PullRequestRefused,
    ] {
        assert!(outcome.refused(), "{outcome:?}");
    }
}

/// The flags answer once; two never both stand, and the innermost
/// subcommand is where they are read from.
#[test]
fn the_flags_are_read_off_the_verb_the_person_ran() {
    use clap::CommandFactory;
    #[derive(clap::Parser)]
    struct Fake {
        #[command(subcommand)]
        command: Verb,
    }
    #[derive(clap::Subcommand)]
    enum Verb {
        Refresh {
            #[command(flatten)]
            _commit: super::CommitFlags,
        },
        List,
    }
    let matches =
        Fake::command().get_matches_from(["kendex", "refresh", "--push", "--message", "m"]);
    let flags = super::CommitFlags::from_matches(&matches);
    assert!(flags.push && !flags.commit && !flags.pull_request && !flags.leave);
    assert_eq!(flags.message.as_deref(), Some("m"));
    assert_eq!(flags.answered(), Some(Choice::Push));

    let none =
        super::CommitFlags::from_matches(&Fake::command().get_matches_from(["kendex", "list"]));
    assert_eq!(none.answered(), None);
    assert!(
        Fake::command()
            .try_get_matches_from(["kendex", "refresh", "--commit", "--leave"])
            .is_err(),
        "two answers stood together"
    );
    assert!(
        Fake::command()
            .try_get_matches_from(["kendex", "list", "--commit"])
            .is_err(),
        "a verb that never offers took the flag"
    );
}
