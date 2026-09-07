//! One control per state of the offer that this module detects, driven by
//! a real repository. The two `gh` steps are driven through the CLI in
//! `crates/cli/tests/commit_offer_cli.rs`, where a fake `gh` can be put on
//! the child's `PATH`; here their failure mapping is what is proved.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use super::*;
use crate::engine::GeneratedPaths;
use crate::engine::generated_paths::INVENTORY;
use crate::error::CoreError;
use crate::process::Hardened;

/// The message is the command the person typed, with nothing enumerated:
/// a group and its subcommand together, because the group alone is not a
/// command anybody can run.
#[test]
fn the_message_is_the_command_and_nothing_else() {
    for (typed, expected) in [
        ("refresh", "chore: kendex refresh"),
        (
            "marketplace subscribe",
            "chore: kendex marketplace subscribe",
        ),
        ("source add", "chore: kendex source add"),
        ("updates", "chore: kendex updates"),
        (" apply ", "chore: kendex apply"),
    ] {
        assert_eq!(default_message(typed), expected, "{typed:?}");
    }
    assert_eq!(body(12), "kendex wrote these files.\nFiles: 12");
}

/// The timeouts table: each step's bound and the name its timeout line
/// carries.
#[test]
fn every_step_has_the_bound_the_design_gives_it() {
    for (step, seconds, name) in [
        (Step::Read, 10, "the check"),
        (Step::Stage, 30, "the staging"),
        (Step::Unstage, 30, "the unstaging"),
        (Step::Branch, 30, "the branch"),
        (Step::SwitchBack, 30, "the switch back"),
        (Step::RemoveBranch, 30, "removing the branch"),
        (Step::Commit, 300, "the commit"),
        (Step::Push, 120, "the push"),
        (Step::Probe, 15, "the check for an open pull request"),
        (Step::PullRequest, 120, "the pull request"),
    ] {
        assert_eq!(step.seconds(), seconds, "{step:?}");
        assert_eq!(step.name(), name, "{step:?}");
    }
}

/// A call that produced no exit status is one of three answers, and each
/// is drawn differently: a program that is not there, one that ran past
/// its bound, and one whose pipes broke.
#[test]
fn a_call_with_no_exit_status_is_told_apart_by_what_stopped_it() {
    let missing = CoreError::not_started("gh pr list", "No such file or directory");
    assert!(matches!(git::refusal(&missing), Refusal::NotStarted(_)));
    let late = CoreError::io(
        "git commit",
        std::io::Error::new(std::io::ErrorKind::TimedOut, "no result after 300s"),
    );
    assert_eq!(git::refusal(&late), Refusal::TimedOut);
    let broken = CoreError::io("git commit", std::io::Error::other("pipe closed"));
    assert!(matches!(git::refusal(&broken), Refusal::Said(lines) if lines.len() == 1));
    // The words a failure carries: none for a timeout, the reason for a
    // program that never started.
    let timed_out = Failed {
        step: Step::Commit,
        refusal: Refusal::TimedOut,
    };
    assert!(timed_out.timed_out());
    assert!(timed_out.said().is_empty());
    let not_started = Failed {
        step: Step::Probe,
        refusal: Refusal::NotStarted("gh: not found".to_owned()),
    };
    assert_eq!(not_started.said(), ["gh: not found"]);
}

/// Why the pull-request choice is off: a `gh` that never started is not
/// installed, and everything else is `gh`'s own first line — a case nobody
/// anticipated names itself rather than reading as one kendex knows.
#[test]
fn the_probe_maps_its_failure_structurally() {
    let missing = Failed {
        step: Step::Probe,
        refusal: Refusal::NotStarted("gh: No such file or directory".to_owned()),
    };
    assert_eq!(gh::why(&missing), Unavailable::GhMissing);
    let said = Failed {
        step: Step::Probe,
        refusal: Refusal::Said(vec!["first".to_owned(), "second".to_owned()]),
    };
    assert_eq!(gh::why(&said), Unavailable::GhSaid("first".to_owned()));
    let silent = Failed {
        step: Step::Probe,
        refusal: Refusal::Said(Vec::new()),
    };
    assert!(
        matches!(gh::why(&silent), Unavailable::GhSaid(line) if !line.is_empty()),
        "a silent non-zero exit read as gh missing"
    );
    let late = Failed {
        step: Step::Probe,
        refusal: Refusal::TimedOut,
    };
    assert_eq!(
        gh::why(&late),
        Unavailable::GhSaid(
            "the check for an open pull request did not finish within 15 seconds".to_owned()
        )
    );
}

// ---------------------------------------------------------------------
// A repository to offer in.

struct Repo {
    _tmp: tempfile::TempDir,
    root: PathBuf,
}

impl Repo {
    /// `git init` on `main`, with an identity, hooks pinned to the
    /// repository's own directory, and one commit carrying the inventory
    /// and every file `committed` names.
    fn new(committed: &[(&str, &str)]) -> Repo {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("site");
        fs::create_dir_all(&root).unwrap();
        let repo = Repo { _tmp: tmp, root };
        repo.git(&["init", "--quiet", "-b", "main"]);
        repo.git(&["config", "user.email", "t@t"]);
        repo.git(&["config", "user.name", "t"]);
        repo.git(&["config", "commit.gpgsign", "false"]);
        repo.git(&["config", "core.hooksPath", ".git/hooks"]);
        let inventory: Vec<&str> = committed
            .iter()
            .map(|(path, _)| *path)
            .chain(std::iter::once(INVENTORY))
            .collect();
        repo.write(INVENTORY, &serde_json::to_string(&inventory).unwrap());
        for (path, content) in committed {
            repo.write(path, content);
        }
        repo.git(&["add", "-A"]);
        repo.git(&["commit", "--quiet", "-m", "one"]);
        repo
    }

    fn git(&self, args: &[&str]) -> String {
        let output = Hardened::git(args, Some(&self.root)).run().unwrap();
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).into_owned()
    }

    fn write(&self, path: &str, content: &str) {
        let full = self.root.join(path);
        fs::create_dir_all(full.parent().unwrap()).unwrap();
        fs::write(full, content).unwrap();
    }

    fn scope(&self) -> Scope {
        Scope::Project {
            root: self.root.clone(),
        }
    }

    /// What kendex renders here: `whole` owned end to end, `shared` the
    /// edit targets.
    fn generated(&self, whole: &[&str], shared: &[&str]) -> GeneratedPaths {
        GeneratedPaths {
            whole: whole.iter().map(|p| self.root.join(p)).collect(),
            shared: shared.iter().map(|p| self.root.join(p)).collect(),
        }
    }

    fn status(&self) -> String {
        self.git(&["status", "--porcelain=v1"])
    }

    /// The paths the commit at `HEAD` touched.
    fn head_files(&self) -> BTreeSet<String> {
        self.git(&["show", "--name-only", "--format=", "HEAD"])
            .lines()
            .map(str::to_owned)
            .collect()
    }

    fn scan(&self, generated: &GeneratedPaths) -> Option<Scan> {
        scan(&self.scope(), generated).unwrap()
    }

    /// A hook in this repository that prints `lines` on stderr and exits 1.
    #[cfg(unix)]
    fn refusing_hook(&self, name: &str, lines: &[&str], then: &str) {
        use std::os::unix::fs::PermissionsExt;
        let body = lines
            .iter()
            .map(|line| format!("echo '{line}' >&2"))
            .collect::<Vec<_>>()
            .join("\n");
        let hooks = self.root.join(".git/hooks");
        fs::create_dir_all(&hooks).unwrap();
        let path = hooks.join(name);
        fs::write(&path, format!("#!/bin/sh\n{body}\n{then}\nexit 1\n")).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    /// A bare repository this one calls `origin`, so a push has somewhere
    /// to land.
    fn with_origin(&self) -> PathBuf {
        let bare = self.root.parent().unwrap().join("origin.git");
        let output = Hardened::git(
            &[
                "init",
                "--quiet",
                "--bare",
                "-b",
                "main",
                &bare.to_string_lossy(),
            ],
            None,
        )
        .run()
        .unwrap();
        assert!(output.status.success());
        self.git(&["remote", "add", "origin", &bare.to_string_lossy()]);
        bare
    }
}

const OWNED: &[&str] = &[".claude/skills/dev/SKILL.md", ".claude/CLAUDE.md"];

// ---------------------------------------------------------------------
// The preconditions and the path set.

#[test]
fn the_global_scope_and_a_folder_without_git_are_never_offered() {
    let generated = GeneratedPaths::default();
    assert_eq!(scan(&Scope::Global, &generated).unwrap(), None);
    let tmp = tempfile::tempdir().unwrap();
    let plain = Scope::Project {
        root: tmp.path().to_owned(),
    };
    assert_eq!(scan(&plain, &generated).unwrap(), None);
}

#[test]
fn a_clean_checkout_and_an_ignored_render_are_nothing_to_offer() {
    let repo = Repo::new(&[(OWNED[0], "one\n"), (".gitignore", ".codex/\n")]);
    let generated = repo.generated(&[OWNED[0], ".codex/CLAUDE.md"], &[]);
    assert_eq!(repo.scan(&generated), None);
    // Ignored paths never reach `git status` output, so a render that
    // lands under one is not a change the offer can see.
    repo.write(".codex/CLAUDE.md", "@AGENTS.md\n");
    assert_eq!(repo.scan(&generated), None);
}

/// Render-only dirty, mixed dirty, and a changed shared file: the three
/// blocks of the offer come off the one status read.
#[test]
fn the_set_is_the_changed_owned_paths_and_the_rest_is_counted_or_named() {
    let repo = Repo::new(&[
        (OWNED[0], "one\n"),
        (".claude/settings.json", "{}\n"),
        ("mine.md", "mine\n"),
    ]);
    let generated = repo.generated(OWNED, &[".claude/settings.json"]);
    repo.write(OWNED[0], "two\n");
    repo.write(OWNED[1], "@AGENTS.md\n");
    let only = repo.scan(&generated).unwrap();
    assert_eq!(
        only.owned,
        [
            Owned {
                path: OWNED[1].to_owned(),
                untracked: true
            },
            Owned {
                path: OWNED[0].to_owned(),
                untracked: false
            },
        ]
    );
    assert!(only.shared.is_empty());
    assert_eq!(only.others, 0, "render-only dirty counted other files");
    assert_eq!(only.branch, Branch::On("main".to_owned()));
    assert_eq!(only.count(), 2);

    repo.write("mine.md", "changed\n");
    repo.write(".claude/settings.json", "{\"permissions\":{}}\n");
    let mixed = repo.scan(&generated).unwrap();
    assert_eq!(mixed.owned.len(), 2, "the person's file joined the set");
    assert_eq!(mixed.shared, [".claude/settings.json"]);
    assert_eq!(
        mixed.others, 1,
        "the shared file or the render counted as other"
    );
}

/// A sweep's removal is a deletion of a path the committed inventory names
/// and the collection no longer gathers; a path that merely left the
/// inventory but still exists is the person's.
#[test]
fn a_sweeps_removal_joins_the_set_and_a_surviving_path_does_not() {
    let repo = Repo::new(&[
        (OWNED[0], "one\n"),
        (".claude/skills/old/SKILL.md", "old\n"),
        (".claude/skills/kept/SKILL.md", "kept\n"),
    ]);
    let generated = repo.generated(&[OWNED[0]], &[]);
    fs::remove_file(repo.root.join(".claude/skills/old/SKILL.md")).unwrap();
    repo.write(".claude/skills/kept/SKILL.md", "hand edited\n");
    let found = repo.scan(&generated).unwrap();
    assert_eq!(
        found.owned,
        [Owned {
            path: ".claude/skills/old/SKILL.md".to_owned(),
            untracked: false
        }]
    );
    assert_eq!(found.others, 1, "the surviving path was not the person's");
}

/// A rename's origin is a deletion, so a renamed-away inventory path joins
/// the set as a sweep's removal. The copy row, which git emits only under
/// `status.renames=copies`, is proved against its documented bytes in
/// `paths.rs`.
#[test]
fn a_renames_origin_is_a_removal() {
    let repo = Repo::new(&[(".claude/skills/old/SKILL.md", "old content here\n")]);
    let generated = repo.generated(&[], &[]);
    repo.git(&["config", "status.renames", "copies"]);
    fs::create_dir_all(repo.root.join(".claude/skills/moved")).unwrap();
    repo.git(&[
        "mv",
        ".claude/skills/old/SKILL.md",
        ".claude/skills/moved/SKILL.md",
    ]);
    assert!(repo.status().starts_with("R  "), "{}", repo.status());
    let renamed = repo.scan(&generated).unwrap();
    assert_eq!(
        renamed.owned,
        [Owned {
            path: ".claude/skills/old/SKILL.md".to_owned(),
            untracked: false
        }]
    );
    assert_eq!(renamed.others, 1, "the moved-to path was not the person's");
}

/// The two states the offer cannot be made in, each read where git keeps
/// it. The operation outranks the detached `HEAD` it leaves behind.
#[test]
fn a_detached_head_and_an_operation_in_progress_are_read_off_the_git_directory() {
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    let generated = repo.generated(&[OWNED[0]], &[]);
    repo.write(OWNED[0], "two\n");
    for (marker, operation) in [
        ("MERGE_HEAD", Operation::Merge),
        ("REBASE_HEAD", Operation::Rebase),
        ("rebase-merge/", Operation::Rebase),
        ("rebase-apply/", Operation::Rebase),
        ("CHERRY_PICK_HEAD", Operation::CherryPick),
        ("BISECT_LOG", Operation::Bisect),
    ] {
        let path = repo.root.join(".git").join(marker);
        match marker.ends_with('/') {
            true => fs::create_dir_all(&path).unwrap(),
            false => fs::write(&path, "").unwrap(),
        }
        assert_eq!(
            repo.scan(&generated).unwrap().branch,
            Branch::InProgress(operation),
            "{marker}"
        );
        match marker.ends_with('/') {
            true => fs::remove_dir_all(&path).unwrap(),
            false => fs::remove_file(&path).unwrap(),
        }
    }
    let head = repo.git(&["rev-parse", "HEAD"]);
    repo.git(&["checkout", "--quiet", "--detach", head.trim()]);
    let detached = repo.scan(&generated).unwrap();
    assert_eq!(detached.branch, Branch::Detached);
    assert_eq!(detached.on_branch(), None);
    assert_eq!(Operation::CherryPick.article(), "a cherry-pick");
}

/// The remote rule: the branch's upstream, else `origin`, else the only
/// one, else none. `tracked` only where the branch's own upstream is the
/// remote that was chosen.
#[test]
fn the_remote_is_chosen_by_rule_and_never_by_a_prompt() {
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    assert_eq!(git::choose_remote(&repo.root, "main").unwrap(), None);
    assert!(git::remotes(&repo.root).unwrap().is_empty());

    repo.git(&["remote", "add", "alpha", "https://example.com/a.git"]);
    let only = git::choose_remote(&repo.root, "main").unwrap().unwrap();
    assert_eq!((only.name.as_str(), only.tracked), ("alpha", false));

    repo.git(&["remote", "add", "beta", "https://example.com/b.git"]);
    assert_eq!(
        git::choose_remote(&repo.root, "main").unwrap(),
        None,
        "two remotes with no origin and no upstream were decided"
    );

    repo.git(&["remote", "add", "origin", "https://example.com/o.git"]);
    let origin = git::choose_remote(&repo.root, "main").unwrap().unwrap();
    assert_eq!(origin.name, "origin");
    assert_eq!(origin.url, "https://example.com/o.git");
    assert!(
        !origin.tracked,
        "a branch with no upstream read as tracking origin"
    );

    repo.git(&["config", "branch.main.remote", "beta"]);
    repo.git(&["config", "branch.main.merge", "refs/heads/main"]);
    let upstream = git::choose_remote(&repo.root, "main").unwrap().unwrap();
    assert_eq!((upstream.name.as_str(), upstream.tracked), ("beta", true));
}

/// Without a remote the offer stands with push and pull request off, and
/// says which of the two rules failed.
#[test]
fn without_a_remote_the_offer_names_why_push_and_pull_request_are_off() {
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    let generated = repo.generated(&[OWNED[0]], &[]);
    repo.write(OWNED[0], "two\n");
    let none = offer(repo.scan(&generated).unwrap(), "refresh", Probe::Gh).unwrap();
    assert_eq!(none.push, Err(Unavailable::NoRemote));
    assert_eq!(none.pull_request, Err(Unavailable::NoRemote));
    assert_eq!(none.message, "chore: kendex refresh");
    assert_eq!(none.new_branch, "kendex/renders");
    assert_eq!(none.branch, "main");

    repo.git(&["remote", "add", "alpha", "https://example.com/a.git"]);
    repo.git(&["remote", "add", "beta", "https://example.com/b.git"]);
    let several = offer(repo.scan(&generated).unwrap(), "refresh", Probe::Gh).unwrap();
    assert_eq!(several.push, Err(Unavailable::RemoteNotDecidable));
    assert_eq!(several.pull_request, Err(Unavailable::RemoteNotDecidable));
}

/// Free means no local ref and no remote-tracking ref for the chosen
/// remote carries the name; another remote's ref does not count.
#[test]
fn the_new_branch_is_the_first_free_name() {
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    assert_eq!(
        git::first_free_branch(&repo.root, None).unwrap(),
        "kendex/renders"
    );
    repo.git(&["branch", "kendex/renders"]);
    let head = repo.git(&["rev-parse", "HEAD"]);
    repo.git(&[
        "update-ref",
        "refs/remotes/origin/kendex/renders-2",
        head.trim(),
    ]);
    repo.git(&[
        "update-ref",
        "refs/remotes/other/kendex/renders-3",
        head.trim(),
    ]);
    let origin = Remote {
        name: "origin".to_owned(),
        url: String::new(),
        tracked: false,
    };
    assert_eq!(
        git::first_free_branch(&repo.root, Some(&origin)).unwrap(),
        "kendex/renders-3"
    );
    assert_eq!(
        git::first_free_branch(&repo.root, None).unwrap(),
        "kendex/renders-2"
    );
}

// ---------------------------------------------------------------------
// The commit.

/// The set's untracked members are staged, the whole set is committed and
/// nothing else is: the person's modified file and their own staged change
/// are exactly where they were.
#[test]
fn the_commit_takes_the_set_and_leaves_the_persons_changes_alone() {
    let repo = Repo::new(&[
        (OWNED[0], "one\n"),
        ("mine.md", "mine\n"),
        ("staged.md", "s\n"),
    ]);
    let generated = repo.generated(OWNED, &[]);
    repo.write(OWNED[0], "two\n");
    repo.write(OWNED[1], "@AGENTS.md\n");
    repo.write("mine.md", "changed\n");
    repo.write("staged.md", "staged\n");
    repo.git(&["add", "staged.md"]);
    let before = git::previous_head(&repo.root).unwrap().unwrap();

    let made = commit(&repo.root, &generated, "chore: kendex refresh").unwrap();
    let Committed::Made { sha, files } = made else {
        panic!("nothing was committed");
    };
    assert_eq!(files, 2);
    assert_ne!(sha, before);
    assert_eq!(git::head_short(&repo.root).unwrap(), sha);
    assert_eq!(
        repo.head_files(),
        OWNED
            .iter()
            .map(|p| (*p).to_owned())
            .collect::<BTreeSet<_>>()
    );
    assert_eq!(
        repo.git(&["log", "-1", "--format=%s"]).trim(),
        "chore: kendex refresh"
    );
    let status = repo.status();
    assert!(status.contains(" M mine.md"), "{status}");
    assert!(status.contains("M  staged.md"), "{status}");
    assert!(!status.contains(".claude/"), "{status}");

    // Re-derived immediately before the commit runs: nothing left means
    // no commit, not an empty one.
    assert_eq!(
        commit(&repo.root, &generated, "again").unwrap(),
        Committed::Nothing
    );
    assert_eq!(git::head_short(&repo.root).unwrap(), sha);
}

/// A rendered path holding pathspec metacharacters names itself and no
/// other file. The must-fail control is the literal option: without it
/// `a[b].md` is a glob that matches `ab.md`, the person's file.
#[test]
fn a_path_with_metacharacters_commits_itself_and_nothing_it_would_match() {
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    let generated = repo.generated(&["docs/a[b].md"], &[]);
    repo.write("docs/a[b].md", "ours\n");
    repo.write("docs/ab.md", "theirs\n");
    let Committed::Made { files, .. } = commit(&repo.root, &generated, "m").unwrap() else {
        panic!("nothing was committed");
    };
    assert_eq!(files, 1);
    assert_eq!(
        repo.head_files(),
        BTreeSet::from(["docs/a[b].md".to_owned()])
    );
    assert!(repo.status().contains("?? docs/ab.md"), "{}", repo.status());
}

/// A hook's refusal reaches the person whole and in order, and the index
/// ends as it began: the untracked member kendex staged is unstaged.
#[cfg(unix)]
#[test]
fn a_refused_commit_carries_the_hooks_words_and_puts_the_index_back() {
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    let generated = repo.generated(OWNED, &[]);
    repo.write(OWNED[0], "two\n");
    repo.write(OWNED[1], "@AGENTS.md\n");
    repo.refusing_hook(
        "pre-commit",
        &[
            "commit-msg: crates/ changed without a changelog entry",
            "  write one of: changelog.d/*/*.md",
        ],
        "",
    );
    let before = git::head_short(&repo.root).unwrap();
    let refused = commit(&repo.root, &generated, "m").unwrap_err();
    assert_eq!(refused.failed.step, Step::Commit);
    assert_eq!(
        refused.failed.said(),
        [
            "commit-msg: crates/ changed without a changelog entry",
            "  write one of: changelog.d/*/*.md",
        ]
    );
    assert_eq!(refused.still_staged, None);
    assert_eq!(git::head_short(&repo.root).unwrap(), before);
    let status = repo.status();
    assert!(
        status.contains("?? .claude/CLAUDE.md"),
        "still staged: {status}"
    );
    assert!(
        status.contains(" M .claude/skills/dev/SKILL.md"),
        "{status}"
    );
}

/// The cleanup itself refusing is reported rather than swallowed: the
/// hook takes the write bit off the git directory, so the reset that
/// would unstage cannot take the index lock and kendex's own paths are
/// still staged.
#[cfg(unix)]
#[test]
fn a_cleanup_that_cannot_unstage_says_how_many_paths_are_still_staged() {
    use std::os::unix::fs::PermissionsExt;
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    let generated = repo.generated(OWNED, &[]);
    repo.write(OWNED[1], "@AGENTS.md\n");
    repo.refusing_hook("pre-commit", &["no"], "chmod 555 .git");
    let refused = commit(&repo.root, &generated, "m").unwrap_err();
    fs::set_permissions(repo.root.join(".git"), fs::Permissions::from_mode(0o755)).unwrap();
    let _ = fs::remove_file(repo.root.join(".git/index.lock"));
    assert_eq!(
        refused.failed.said()[0],
        "no",
        "{:?}",
        refused.failed.said()
    );
    assert_eq!(refused.still_staged, Some(1));
    assert!(
        repo.status().contains("A  .claude/CLAUDE.md"),
        "{}",
        repo.status()
    );
}

// ---------------------------------------------------------------------
// The branch, the push, and gh.

/// The `pr` route's branch: made and switched to before anything is
/// committed, and taken away again, checkout restored, when the commit on
/// it did not happen.
#[test]
fn the_branch_is_made_before_the_commit_and_abandoned_after_a_refusal() {
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    start_branch(&repo.root, "kendex/renders").unwrap();
    assert_eq!(
        git::head_branch(&repo.root).unwrap().as_deref(),
        Some("kendex/renders")
    );
    let again = start_branch(&repo.root, "kendex/renders").unwrap_err();
    assert_eq!(again.step, Step::Branch);
    assert!(
        again
            .said()
            .iter()
            .any(|line| line.contains("already exists")),
        "{:?}",
        again.said()
    );
    abandon_branch(&repo.root, "kendex/renders").unwrap();
    assert_eq!(
        git::head_branch(&repo.root).unwrap().as_deref(),
        Some("main")
    );
    assert!(
        !repo
            .git(&["branch", "--list", "kendex/renders"])
            .contains("renders")
    );
}

/// A push lands on the remote, sets the upstream where the branch had
/// none, and a refused push carries the remote's words. The recovery push
/// puts an existing commit on a branch of its own without moving the
/// local branch.
#[cfg(unix)]
#[test]
fn a_push_lands_or_is_refused_in_the_remotes_words() {
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    let bare = repo.with_origin();
    let pushed = push(&repo.root, "origin", "main", false).unwrap();
    assert_eq!(
        (pushed.remote.as_str(), pushed.branch.as_str()),
        ("origin", "main")
    );
    assert_eq!(
        repo.git(&["config", "branch.main.remote"]).trim(),
        "origin",
        "the first push set no upstream"
    );

    let head_pushed = push_head(&repo.root, "origin", "kendex/renders").unwrap();
    assert_eq!(head_pushed.branch, "kendex/renders");
    assert_eq!(
        git::head_branch(&repo.root).unwrap().as_deref(),
        Some("main")
    );
    assert!(
        !repo
            .git(&["branch", "--list", "kendex/renders"])
            .contains("renders"),
        "the recovery made a local branch"
    );

    {
        use std::os::unix::fs::PermissionsExt;
        let hook = bare.join("hooks/pre-receive");
        fs::write(
            &hook,
            "#!/bin/sh\necho 'GH006: Protected branch update failed for refs/heads/main.' >&2\nexit 1\n",
        )
        .unwrap();
        fs::set_permissions(&hook, fs::Permissions::from_mode(0o755)).unwrap();
    }
    repo.write(OWNED[0], "two\n");
    repo.git(&["commit", "--quiet", "-am", "two"]);
    let refused = push(&repo.root, "origin", "main", true).unwrap_err();
    assert_eq!(refused.step, Step::Push);
    assert!(
        refused
            .said()
            .iter()
            .any(|line| line.contains("GH006: Protected branch update failed")),
        "{:?}",
        refused.said()
    );
}

/// `previous_head` is what a recovery would put the branch back to, and
/// there is nothing to put it back to in a repository with no commit.
#[test]
fn the_previous_head_is_none_before_the_first_commit() {
    let tmp = tempfile::tempdir().unwrap();
    let root: &Path = tmp.path();
    let init = Hardened::git(&["init", "--quiet", "-b", "main"], Some(root))
        .run()
        .unwrap();
    assert!(init.status.success());
    assert_eq!(previous_head(root).unwrap(), None);
    assert_eq!(
        git::first_free_branch(root, None).unwrap(),
        "kendex/renders"
    );
    assert!(git::committed_inventory(root).unwrap().is_empty());
}
