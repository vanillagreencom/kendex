//! The terminal's rows, pinned to the design's words. The states are
//! driven end to end through the binary in `tests/commit_offer_cli.rs`;
//! what that child cannot reach — the interactive block's lines, its
//! keyed choices and how an answer is read — is composed here.

use std::path::{Path, PathBuf};

use kendex_core::commit_offer::{
    Branch, Carry, Failed, Offer, OpenPullRequest, Operation, Owned, Rebase, Refusal, Remote, Scan,
    Step, Unavailable,
};

use super::block;
use super::{Choice, Outcome};
use crate::ui::Style;
use crate::ui::testing::{asked, plain, rich, tagged};

fn scan() -> Scan {
    Scan {
        root: PathBuf::from("/home/method/dev/site"),
        owned: (1..=12)
            .map(|n| Owned {
                path: format!(".claude/skills/{n}/SKILL.md"),
                untracked: false,
                added: false,
            })
            .collect(),
        beside: Vec::new(),
        carry: Carry::Untaken,
        others: 4,
        manifest: None,
        branch: Branch::On("main".to_owned()),
    }
}

fn origin() -> Remote {
    Remote {
        name: "origin".to_owned(),
        url: "https://github.com/acme/site.git".to_owned(),
        push_url: Some("https://github.com/acme/site.git".to_owned()),
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
    assert_eq!(
        Operation::Rebase(Rebase::Merge).article(),
        "a rebase (rebase-merge)"
    );
    assert_eq!(
        Operation::Rebase(Rebase::Apply).article(),
        "a rebase (rebase-apply)"
    );
}

/// The four choices in the design's order, skipping the ones the
/// preconditions remove, `leave` always last; an open pull request rewords
/// `push` and takes `pr` away. One row per precondition.
#[test]
fn the_choices_keep_their_order_skipping_the_removed_ones() {
    type Shape = fn(&mut Offer);
    let rows: [(&str, Shape, &[&str]); 5] = [
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
        (
            "the branch's rules require a pull request",
            |offer| offer.push = Err(Unavailable::PullRequestRequired),
            &[
                "commit them",
                "commit them on a new branch and open a pull request",
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

/// One precondition: its name, how it shapes the offer, the reason lines
/// the offer prints, and what a flag naming each choice is refused with.
type ReasonRow = (
    &'static str,
    fn(&mut Offer),
    &'static [&'static str],
    &'static [(Choice, Option<&'static str>)],
);

fn reason_rows() -> [ReasonRow; 7] {
    [
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
        (
            "the branch's rules require a pull request",
            |offer| offer.push = Err(Unavailable::PullRequestRequired),
            &["no push: this branch's rules on GitHub accept changes only through a pull request"],
            &[
                (
                    Choice::Push,
                    Some(
                        "no push: this branch's rules on GitHub accept changes only through a pull request",
                    ),
                ),
                (Choice::Pr, None),
            ],
        ),
    ]
}

/// The reason a removed choice prints, one row per precondition, and the
/// same row a flag naming that choice is refused with.
#[test]
fn a_removed_choice_prints_its_reason() {
    for (what, shape, reasons, refused) in reason_rows() {
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

/// Each question's table: every choice is taken by its own key, and Enter
/// takes the default, which never writes, pushes or opens anything except
/// on the message question, whose default is the offered message. With
/// `pr` gone its key picks nothing. One row per key.
#[test]
fn each_choice_is_taken_by_its_key() {
    use console::Key as Pressed;
    use std::fmt::Debug;

    #[track_caller]
    fn taken<T: Copy + PartialEq + Debug>(
        options: &[(crate::ui::Choice<'_>, T)],
        rows: &[(Vec<Pressed>, T)],
    ) {
        for (keys, want) in rows {
            let (_, answer) = asked(&plain(), options, keys);
            assert_eq!(answer.ok(), Some(*want), "{keys:?}");
        }
    }

    let everything = block::choices(&offer());
    taken(
        &block::keyed(&everything),
        &[
            (vec![Pressed::Char('c')], Choice::Commit),
            (vec![Pressed::Char('p')], Choice::Push),
            (vec![Pressed::Char('r')], Choice::Pr),
            (vec![Pressed::Enter], Choice::Leave),
        ],
    );
    let without = block::without_pull_request(&offer());
    taken(
        &block::keyed(&without),
        &[(vec![Pressed::Char('r'), Pressed::Char('c')], Choice::Commit)],
    );
    taken(
        &block::after_refusal_choices(true),
        &[
            (
                vec![Pressed::Char('a')],
                block::AfterRefusal::Retry(block::Retry::Same),
            ),
            (
                vec![Pressed::Char('m')],
                block::AfterRefusal::Retry(block::Retry::Different),
            ),
            (vec![Pressed::Char('?')], block::AfterRefusal::Show),
            (
                vec![Pressed::Enter],
                block::AfterRefusal::Retry(block::Retry::Leave),
            ),
        ],
    );
    taken(
        &block::after_refusal_choices(false),
        &[(
            vec![Pressed::Char('?'), Pressed::Enter],
            block::AfterRefusal::Retry(block::Retry::Leave),
        )],
    );
    taken(
        &block::AFTER_PUSH_REFUSAL,
        &[
            (vec![Pressed::Char('r')], block::Recover::PullRequest),
            (vec![Pressed::Enter], block::Recover::Leave),
        ],
    );
    taken(
        &block::MESSAGE,
        &[
            (vec![Pressed::Char('e')], block::Message::Type),
            (vec![Pressed::Enter], block::Message::Use),
        ],
    );
    taken(
        &block::stale_choices("set up bot-instructions here"),
        &[
            (vec![Pressed::Char('s')], block::Held::SetUp),
            (vec![Pressed::Enter], block::Held::Leave),
        ],
    );
}

/// A small offer: two paths, one other file, and no `gh`.
fn small() -> Offer {
    let mut small = offer();
    small.scan.owned.truncate(2);
    small.scan.others = 1;
    small.pull_request = Err(Unavailable::GhMissing);
    small
}

/// The offer and its question in both renderings, and what each answer
/// draws: a key takes its choice and Enter leaves the files as diffs. A
/// cancel draws the buttons and nothing under them, which `ui::keys` pins.
#[test]
fn the_offer_draws_accept_and_decline() {
    use console::Key as Pressed;
    let rich_offer = [
        "",
        "<33>!</> <1>/home/method/dev/site: 2 files kendex wrote are not committed</>",
        "  <36>•</> .claude/skills/1/SKILL.md",
        "  <36>•</> .claude/skills/2/SKILL.md",
        "  <36>•</> 1 other file in this repository changed; kendex leaves those alone",
        "  <36>•</> no pull request: gh is not installed",
        "  <34>[c]</> <90>commit them</><90> · </><34>[p]</> <90>commit them and push to origin/main</><90> · </><1;34>[Enter]</> <1>leave them as diffs</>",
    ];
    let plain_offer = [
        "! /home/method/dev/site: 2 files kendex wrote are not committed",
        "  .claude/skills/1/SKILL.md",
        "  .claude/skills/2/SKILL.md",
        "  1 other file in this repository changed; kendex leaves those alone",
        "  no pull request: gh is not installed",
        "  [c] commit them · [p] commit them and push to origin/main · [Enter] leave them as diffs",
    ];
    type Row = (
        &'static str,
        Pressed,
        Choice,
        &'static [&'static str],
        &'static [&'static str],
    );
    let rows: [Row; 2] = [
        (
            "accept",
            Pressed::Char('c'),
            Choice::Commit,
            &["  <34>›</> <1>commit them</>"],
            &["  › commit them"],
        ),
        (
            "decline",
            Pressed::Enter,
            Choice::Leave,
            &["  <34>›</> <1>leave them as diffs</>"],
            &["  › leave them as diffs"],
        ),
    ];
    let offered = small();
    for (what, key, want, rich_tail, plain_tail) in rows {
        for (style, head, tail) in [
            (rich(100), &rich_offer[..], rich_tail),
            (plain(), &plain_offer[..], plain_tail),
        ] {
            let mut drawn = block::offer(&style, &offered);
            let (lines, answer) = asked(
                &style,
                &block::keyed(&block::choices(&offered)),
                std::slice::from_ref(&key),
            );
            drawn.extend(lines);
            let wanted: Vec<&str> = head.iter().chain(tail.iter()).copied().collect();
            assert_eq!(tagged(&drawn), wanted, "{what}");
            assert_eq!(answer.ok(), Some(want), "{what}");
        }
    }
}

/// A refusal in both renderings: a flag naming a choice the offer lost,
/// and a commit the repository's check refused, its findings first and
/// the rest behind the show key.
#[test]
fn a_refusal_draws_its_reason_and_the_programs_words() {
    let offered = small();
    let reason = block::not_on_offer(&offered, Choice::Pr).expect("gh is missing");
    let failed = Failed {
        step: Step::Commit,
        refusal: Refusal::Said(vec![
            "commit-guards: step=doc-limits".to_owned(),
            "bot-instructions: findings=1".to_owned(),
            "drift: AGENTS.md differs from a fresh render".to_owned(),
            "commit-guards: result=1".to_owned(),
        ]),
    };
    let rows: [(Style, &[&str]); 2] = [
        (
            rich(100),
            &[
                "",
                "<33>!</> <1>/home/method/dev/site: 2 files kendex wrote are not committed</>",
                "  <31>✗</> no pull request: gh is not installed",
                "  <31>✗</> the commit was refused",
                "  <36>•</> the repository's commit check found problems:",
                "    <90>bot-instructions: findings=1</>",
                "    <90>drift: AGENTS.md differs from a fresh render</>",
                "  <36>•</> the commit check printed 2 more lines",
                "  <34>[a]</> <90>commit again with the same message</><90> · </><34>[m]</> <90>commit again with a different message</>",
                "  <34>[?]</> <90>show everything the commit check printed</><90> · </><1;34>[Enter]</> <1>leave them as diffs</>",
            ],
        ),
        (
            plain(),
            &[
                "! /home/method/dev/site: 2 files kendex wrote are not committed",
                "  no pull request: gh is not installed",
                "  the commit was refused",
                "  the repository's commit check found problems:",
                "    bot-instructions: findings=1",
                "    drift: AGENTS.md differs from a fresh render",
                "  the commit check printed 2 more lines",
                "  [a] commit again with the same message · [m] commit again with a different message · [?] show everything the commit check printed · [Enter] leave them as diffs",
            ],
        ),
    ];
    for (style, want) in rows {
        let mut drawn = block::flag_refused(&style, &offered, Choice::Pr, &reason);
        let (lines, more) = block::commit_refused(&style, &failed, super::Asking::Yes);
        assert!(more, "the rest of the check's words did not wait");
        drawn.extend(lines);
        let (lines, _) = asked(&style, &block::after_refusal_choices(more), &[]);
        drawn.extend(lines);
        assert_eq!(tagged(&drawn), want);
    }
}

/// A blank line in a program's words is still quoted, in both looks: git
/// splits a hook's output by line and keeps the empty ones (ESLint's and
/// `rustfmt --check`'s blocks), and the refusal names that output whole.
#[test]
fn a_blank_line_in_the_programs_words_keeps_its_place() {
    let failed = Failed {
        step: Step::Commit,
        refusal: Refusal::Said(vec!["a".to_owned(), String::new(), "b".to_owned()]),
    };
    let rows: [(Style, &[&str]); 2] = [
        (
            rich(100),
            &[
                "  <36>•</> git said:",
                "    <90>a</>",
                "    ",
                "    <90>b</>",
            ],
        ),
        (plain(), &["  git said:", "    a", "    ", "    b"]),
    ];
    for (style, want) in rows {
        assert_eq!(tagged(&block::everything(&style, &failed)), want);
    }
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
    assert_eq!(flags.allow_repo_effects, None, "a verb without the flag");

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

    // The held offer names `--allow-repo-effects` only where this reads
    // `Some`, so each row runs kendex's own command surface.
    for (argv, carried) in [
        (
            &["kendex", "x/y", "--commit", "--allow-repo-effects"][..],
            Some(true),
        ),
        (
            &["kendex", "add", "x/y", "--commit", "--allow-repo-effects"][..],
            Some(true),
        ),
        (&["kendex", "apply", "--commit"][..], Some(false)),
        (
            &["kendex", "remove", "x", "--commit", "--allow-repo-effects"][..],
            Some(true),
        ),
        (&["kendex", "refresh", "--commit"][..], None),
        (&["kendex", "enable", "x", "--commit"][..], None),
    ] {
        let matches = crate::Cli::command().get_matches_from(argv);
        assert_eq!(
            super::CommitFlags::from_matches(&matches).allow_repo_effects,
            carried,
            "{argv:?}"
        );
    }
}

/// A reading before the write that would not run leaves every changed file
/// kendex writes into out of the commit, and the offer says the reading
/// failed rather than calling any of them the person's earlier change.
#[test]
fn a_reading_before_the_write_that_failed_is_named_and_carries_nothing() {
    let mut read = scan();
    read.beside = vec![Owned {
        path: "kendex.toml".to_owned(),
        untracked: false,
        added: false,
    }];
    read.carry = Carry::Unread(Failed {
        step: Step::Read,
        refusal: Refusal::Said(vec!["fatal: index file corrupt".to_owned()]),
    });
    assert_eq!(
        read.count(),
        read.owned.len(),
        "a file kendex writes into rode"
    );
    let drawn = block::left_out(&plain(), &read);
    assert_eq!(
        drawn,
        [
            "  kendex could not read which files held changes before this run, so the commit leaves out 1 file it writes into and does not own whole; commit it yourself",
            "    kendex.toml",
            "  git said:",
            "    fatal: index file corrupt",
        ]
    );
}

/// git in a fixture checkout, with an identity of its own.
fn fixture_git(root: &Path, args: &[&str]) {
    let output = kendex_core::process::Hardened::git(args, Some(root))
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t")
        .run()
        .expect("git runs");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// Every head the terminal draws prints the one count the scan gives, and
/// the offer lists the one set behind it, a file kendex does not own whole
/// included where the action wrote it from a clean state. Read from a real
/// checkout against a real reading, because a scan carrying a file kendex
/// writes into exists only as that reading's answer.
#[test]
fn every_head_prints_the_count_of_what_the_commit_carries() {
    let tmp = tempfile::tempdir().expect("a fixture directory");
    let root = kendex_core::paths::canonical(tmp.path()).expect("the fixture resolves");
    fixture_git(&root, &["init", "--quiet", "-b", "main"]);
    std::fs::write(root.join("kendex.toml"), "schema = 6\n").expect("the manifest is written");
    fixture_git(&root, &["add", "-A"]);
    fixture_git(&root, &["commit", "--quiet", "-m", "one"]);
    let scope = kendex_core::model::Scope::Project { root: root.clone() };
    let render = root.join(".claude/agents/scout.md");
    let generated = kendex_core::engine::GeneratedPaths {
        whole: [render.clone()].into(),
        ..Default::default()
    };
    let before =
        kendex_core::commit_offer::Before::read(&scope, &generated, [root.join("kendex.toml")]);
    std::fs::create_dir_all(render.parent().expect("a parent")).expect("the folder is made");
    std::fs::write(&render, "scout\n").expect("the render is written");
    std::fs::write(
        root.join("kendex.toml"),
        "schema = 6\n[agents]\nscout = \"cat\"\n",
    )
    .expect("the manifest is written");
    let carried = kendex_core::commit_offer::scan(&scope, &generated, &before)
        .expect("the project reads")
        .expect("the commit carries something");
    assert_eq!(carried.count(), 2, "the manifest did not ride");
    let mut offered = offer();
    offered.scan = carried.clone();
    offered.pull_request = Err(Unavailable::GhMissing);

    let head = block::head(&root, 2);
    let heads = [
        ("no branch", block::no_branch(&plain(), &carried)),
        (
            "in progress",
            block::in_progress(&plain(), &carried, Operation::Merge),
        ),
        ("no terminal", block::no_terminal(&plain(), &carried)),
        ("held", block::stale(&plain(), &carried, &[])),
        (
            "a flag refused",
            block::flag_refused(&plain(), &offered, Choice::Pr, "gh is not installed"),
        ),
        ("the offer", block::offer(&plain(), &offered)),
    ];
    for (what, lines) in heads {
        assert!(lines[0].contains(&head), "{what}: {lines:?}");
    }
    let listed = block::offer(&plain(), &offered);
    assert_eq!(
        listed[1..3],
        ["  .claude/agents/scout.md", "  kendex.toml"],
        "the listed files"
    );
}
