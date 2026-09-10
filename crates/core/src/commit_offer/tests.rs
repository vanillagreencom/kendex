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

    /// A repository with no commit in it — the state a first kendex write
    /// in a fresh `git init` meets, where `HEAD` names nothing.
    fn empty() -> Repo {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("site");
        fs::create_dir_all(&root).unwrap();
        let repo = Repo { _tmp: tmp, root };
        repo.git(&["init", "--quiet", "-b", "main"]);
        repo.git(&["config", "user.email", "t@t"]);
        repo.git(&["config", "user.name", "t"]);
        repo.git(&["config", "commit.gpgsign", "false"]);
        repo.git(&["config", "core.hooksPath", ".git/hooks"]);
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

    /// A hook in this repository: `body` under `/bin/sh`, ending at `exit`.
    #[cfg(unix)]
    fn hook(&self, name: &str, body: &str, exit: u8) {
        use std::os::unix::fs::PermissionsExt;
        let hooks = self.root.join(".git/hooks");
        fs::create_dir_all(&hooks).unwrap();
        let path = hooks.join(name);
        fs::write(&path, format!("#!/bin/sh\n{body}\nexit {exit}\n")).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    /// A hook in this repository that prints `lines` on stderr and exits 1.
    #[cfg(unix)]
    fn refusing_hook(&self, name: &str, lines: &[&str], then: &str) {
        let body = lines
            .iter()
            .map(|line| format!("echo '{line}' >&2"))
            .collect::<Vec<_>>()
            .join("\n");
        self.hook(name, &format!("{body}\n{then}"), 1);
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

    let made = commit(
        &repo.root,
        &generated,
        "chore: kendex refresh",
        &Selection::All,
    )
    .unwrap();
    let Committed::Made {
        sha,
        files,
        dropped,
    } = made
    else {
        panic!("nothing was committed");
    };
    assert_eq!(files, 2);
    // Every pending path is taken, so none is dropped.
    assert!(dropped.is_empty(), "{dropped:?}");
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
        commit(&repo.root, &generated, "again", &Selection::All).unwrap(),
        Committed::Nothing
    );
    assert_eq!(git::head_short(&repo.root).unwrap(), sha);
}

/// A rendered path holding pathspec metacharacters names itself and no
/// other file. Each row is an owned path and the person's file the row
/// would reach if the path were read as a pattern; an item name carries
/// any of these, since the render validator rejects only `/`, `\\` and
/// `..` in one.
///
/// The colon in the second row sits inside a segment. An entry never
/// begins with one, because every render lands under a directory or a
/// fixed top-level name, so what the row covers is a colon git reads as
/// ordinary text rather than one opening a prefix.
///
/// The must-fail control is the entries' `:(literal)` prefix: without it
/// `a[b].md` is a glob that matches `ab.md` and `:(glob)x*.md` one that
/// matches `:(glob)xy.md`, and the person's file lands in the commit.
#[test]
fn a_path_with_metacharacters_commits_itself_and_nothing_it_would_match() {
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    let mut rows = vec![("docs/a[b].md", "docs/ab.md")];
    // A `:` cannot be in a Windows filename, so the shape that opens a
    // segment with pathspec magic is exercised where it can exist. The
    // row above is its portable twin.
    if cfg!(unix) {
        rows.push(("docs/:(glob)x*.md", "docs/:(glob)xy.md"));
    }
    let owned: Vec<&str> = rows.iter().map(|(ours, _)| *ours).collect();
    let generated = repo.generated(&owned, &[]);
    for (ours, theirs) in &rows {
        repo.write(ours, "ours\n");
        repo.write(theirs, "theirs\n");
    }
    let Committed::Made { files, .. } =
        commit(&repo.root, &generated, "m", &Selection::All).unwrap()
    else {
        panic!("nothing was committed");
    };
    assert_eq!(files, rows.len());
    assert_eq!(
        repo.head_files(),
        owned
            .iter()
            .map(|p| (*p).to_owned())
            .collect::<BTreeSet<_>>()
    );
    let status = repo.status();
    for (_, theirs) in &rows {
        assert!(status.contains(&format!("?? {theirs}")), "{status}");
    }
}

/// A hook reads the same git a plain `git commit` gives it. The selection
/// travels inside the pathspec file, so no git-wide option becomes
/// `GIT_LITERAL_PATHSPECS=1` in the environment git hands the hook — where
/// the hook's own `:(glob)` pathspec would match nothing and its `git
/// check-ignore` would exit 128 on magic the hook never wrote. Both are
/// read from the hook child itself, the only place the leak is visible:
/// the argv kendex builds shows nothing either way.
///
/// The must-fail control is the git-wide option: put `--literal-pathspecs`
/// back on the commit and all three lines change.
#[cfg(unix)]
#[test]
fn a_hook_reads_the_git_a_plain_commit_would_give_it() {
    let repo = Repo::new(&[
        (OWNED[0], "one\n"),
        ("docs/one.md", "a\n"),
        ("docs/deep/two.md", "b\n"),
        (".gitignore", "ignored/\n"),
    ]);
    let generated = repo.generated(OWNED, &[]);
    repo.write(OWNED[0], "two\n");
    repo.write(OWNED[1], "@AGENTS.md\n");
    // Outside the checkout: a file the hook wrote inside it would be one
    // more change in the working tree the commit is being made from.
    let record = repo.root.parent().unwrap().join("hook-record");
    repo.hook(
        "pre-commit",
        &format!(
            "{{ echo \"literal=${{GIT_LITERAL_PATHSPECS-unset}}\"\n\
             echo \"glob=$(git ls-files -- ':(glob)docs/**/*.md' | wc -l | tr -d ' ')\"\n\
             echo ignored/x.md | git check-ignore --stdin >/dev/null 2>&1\n\
             echo \"check-ignore=$?\"; }} > '{}'",
            record.display()
        ),
        0,
    );

    let Committed::Made { files, .. } =
        commit(&repo.root, &generated, "m", &Selection::All).unwrap()
    else {
        panic!("nothing was committed");
    };
    assert_eq!(files, 2);

    // What the glob is expected to reach is the repository's own answer to
    // the same pathspec, not a number written here: a fixture that grew a
    // markdown file would otherwise pin a total nothing produces.
    let matched = repo.git(&["ls-files", "--", ":(glob)docs/**/*.md"]);
    let expected = matched.lines().count();
    assert!(expected > 0, "the fixture matched nothing: {matched:?}");
    let seen = fs::read_to_string(&record).unwrap();
    assert_eq!(
        seen,
        format!("literal=unset\nglob={expected}\ncheck-ignore=0\n")
    );
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
    let refused = commit(&repo.root, &generated, "m", &Selection::All).unwrap_err();
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
    let refused = commit(&repo.root, &generated, "m", &Selection::All).unwrap_err();
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

// ---------------------------------------------------------------------
// What one file the offer covers changed.

/// What this path has to show, or the test fails naming what came back.
fn shown(scan: &Scan, path: &str) -> Changed {
    match file_changes(scan, path).unwrap() {
        Changes::Shown(changed) => changed,
        other => panic!("{path} answered {other:?} rather than a comparison"),
    }
}

/// The viewer reads only what the scan covers. Every other path in the
/// repository is the person's own — work in progress, an ignored file
/// holding a secret — and a window that could name one could show it.
#[test]
fn only_a_path_the_scan_covers_has_changes_to_show() {
    let repo = Repo::new(&[
        (OWNED[0], "one\n"),
        (".claude/settings.json", "{}\n"),
        ("mine.md", "mine\n"),
    ]);
    let generated = repo.generated(OWNED, &[".claude/settings.json"]);
    repo.write(OWNED[0], "two\n");
    repo.write(".claude/settings.json", "{\"permissions\":{}}\n");
    repo.write("mine.md", "a secret\n");
    let found = repo.scan(&generated).unwrap();

    let owned = shown(&found, OWNED[0]);
    assert_eq!(
        owned.diff.files.len(),
        1,
        "one file named, one file compared"
    );
    assert_eq!(owned.diff.files[0].path, OWNED[0]);
    assert_eq!(
        (owned.diff.total_additions, owned.diff.total_deletions),
        (1, 1)
    );

    // A shared file is the person's own with one key of kendex's in it, so
    // the rest of it — their environment values, their credentials — is
    // theirs. The offer names such a file and commits nothing of it, and
    // nothing here reads one.
    assert_eq!(
        file_changes(&found, ".claude/settings.json").unwrap(),
        Changes::NotOffered,
        "a shared configuration file was read"
    );

    for outside in [
        // The person's own changed file, which the scan counts and never
        // covers.
        "mine.md",
        // A path that was never changed at all.
        ".claude/skills/dev/other.md",
        // A path reaching out of the project, which no scan can name.
        "../mine.md",
        // The same, spelled absolutely.
        "/etc/passwd",
    ] {
        assert_eq!(
            file_changes(&found, outside).unwrap(),
            Changes::NotOffered,
            "{outside} was shown"
        );
    }
}

/// A file this change adds has nothing at `HEAD` to compare against, and a
/// file it deletes has nothing in the working tree; both are a change to
/// show rather than a read that failed.
#[test]
fn a_file_added_or_deleted_by_the_change_still_shows_what_it_is() {
    const ADDED: &str = ".claude/skills/dev/NEW.md";
    let repo = Repo::new(&[(OWNED[0], "one\n"), (OWNED[1], "two\n")]);
    repo.write(ADDED, "brand new\n");
    fs::remove_file(repo.root.join(OWNED[1])).unwrap();
    let generated = repo.generated(&[OWNED[0], OWNED[1], ADDED], &[]);
    let found = repo.scan(&generated).unwrap();

    let added = shown(&found, ADDED);
    assert_eq!(
        added.diff.files[0].status,
        crate::package::diff::FileStatus::Added
    );
    assert_eq!(added.diff.total_deletions, 0);
    assert_eq!(added.mode, None, "a file arriving is not a mode change");

    let removed = shown(&found, OWNED[1]);
    assert_eq!(
        removed.diff.files[0].status,
        crate::package::diff::FileStatus::Removed
    );
    assert_eq!(removed.diff.total_additions, 0);
    assert_eq!(removed.mode, None, "a file going is not a mode change");
}

/// A harness-native link is a path kendex writes and commits: what git
/// stores for it is the link's own target text, so the viewer reads the
/// link rather than following it. Reading through it, or refusing it, would
/// tell a person the commit deletes a link it rewrites.
#[cfg(unix)]
#[test]
fn a_link_kendex_owns_reads_as_its_target_text() {
    const LINK: &str = ".claude/skills/dev";
    let repo = Repo::new(&[(".agents/skills/dev/SKILL.md", "body\n")]);
    fs::create_dir_all(repo.root.join(".claude/skills")).unwrap();
    let at = repo.root.join(LINK);
    std::os::unix::fs::symlink("../../.agents/skills/dev", &at).unwrap();
    let generated = repo.generated(&[LINK], &[]);

    // Untracked: the commit adds the link, and the row says so.
    let added = shown(&repo.scan(&generated).unwrap(), LINK);
    assert_eq!(
        added.diff.files[0].status,
        crate::package::diff::FileStatus::Added
    );
    assert_eq!(hunk_text(&added.diff), ["+../../.agents/skills/dev"]);

    // Committed, then respelled the way one apply converges an absolute
    // link to a relative one: one line replaced by another, never a
    // deletion.
    repo.git(&["add", "-A"]);
    repo.git(&["commit", "--quiet", "-m", "link"]);
    fs::remove_file(&at).unwrap();
    std::os::unix::fs::symlink("../../../.agents/skills/dev", &at).unwrap();
    let respelled = shown(&repo.scan(&generated).unwrap(), LINK);
    assert_eq!(
        respelled.diff.files[0].status,
        crate::package::diff::FileStatus::Modified
    );
    assert_eq!(
        hunk_text(&respelled.diff),
        ["-../../.agents/skills/dev", "+../../../.agents/skills/dev"]
    );
    assert_eq!(
        (
            respelled.diff.total_additions,
            respelled.diff.total_deletions
        ),
        (1, 1)
    );
    // A link is mode 120000 on both sides, so respelling one changes no
    // mode; the comparison is the whole of the change.
    assert_eq!(respelled.mode, None);
}

/// git carries changes the contents do not show — a registration script
/// regaining its execute bit is one kendex itself makes. The offer covers
/// the path, so the viewer says what the commit carries rather than
/// drawing an empty comparison, which reads as nothing having changed.
#[cfg(unix)]
#[test]
fn a_change_the_contents_do_not_show_is_not_an_empty_comparison() {
    use std::os::unix::fs::PermissionsExt;
    const SCRIPT: &str = ".claude/hooks/check.sh";
    let repo = Repo::new(&[(SCRIPT, "#!/bin/sh\n")]);
    let generated = repo.generated(&[SCRIPT], &[]);
    let at = repo.root.join(SCRIPT);
    fs::set_permissions(&at, fs::Permissions::from_mode(0o755)).unwrap();

    let found = repo.scan(&generated).unwrap();
    assert_eq!(found.count(), 1, "the mode change left the offer's set");
    let only_mode = shown(&found, SCRIPT);
    assert!(
        only_mode.diff.files.is_empty(),
        "the contents were reported as changed"
    );
    assert_eq!(
        only_mode.mode,
        Some(ModeChange {
            before: "100644".to_owned(),
            after: "100755".to_owned()
        })
    );

    // The same commit rewriting the script as well: the mode is read from
    // git rather than inferred from an empty comparison, so both halves of
    // a mixed change are reported.
    repo.write(SCRIPT, "#!/bin/sh\necho hi\n");
    fs::set_permissions(&at, fs::Permissions::from_mode(0o755)).unwrap();
    let both = shown(&repo.scan(&generated).unwrap(), SCRIPT);
    assert_eq!(both.diff.total_additions, 1, "the rewrite went unreported");
    assert_eq!(
        both.mode,
        Some(ModeChange {
            before: "100644".to_owned(),
            after: "100755".to_owned()
        }),
        "the mode change was hidden by the content change"
    );
}

/// Every line one comparison's hunks hold, with the sign the viewer draws.
fn hunk_text(diff: &crate::package::diff::PackageDiff) -> Vec<String> {
    diff.files
        .iter()
        .flat_map(|file| &file.hunks)
        .flat_map(|hunk| &hunk.lines)
        .map(|line| {
            let sign = match line.kind {
                crate::package::diff::LineKind::Add => "+",
                crate::package::diff::LineKind::Remove => "-",
                crate::package::diff::LineKind::Context => " ",
            };
            format!("{sign}{}", line.text)
        })
        .collect()
}

/// Absent and unreadable are different answers. A file this change deletes
/// is absent; a read the machine refused is a step that failed, and the
/// window is told so rather than shown a deletion nobody made.
#[cfg(unix)]
#[test]
fn a_read_the_machine_refuses_is_a_failure_and_never_a_deletion() {
    use std::os::unix::fs::PermissionsExt;
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    let generated = repo.generated(&[OWNED[0]], &[]);
    repo.write(OWNED[0], "two\n");
    let found = repo.scan(&generated).unwrap();
    let at = repo.root.join(OWNED[0]);

    fs::set_permissions(&at, fs::Permissions::from_mode(0o000)).unwrap();
    let refused = file_changes(&found, OWNED[0]);
    // Running as root reads a mode-0 file anyway, so the property this
    // asserts is not reachable there and the case says so instead of
    // passing on a read that was never refused.
    if fs::read(&at).is_ok() {
        fs::set_permissions(&at, fs::Permissions::from_mode(0o644)).unwrap();
        return;
    }
    let failed = refused.expect_err("an unreadable file read as a deletion");
    assert!(
        failed.said().iter().any(|line| line.contains(OWNED[0])),
        "the failure did not name the file: {:?}",
        failed.said()
    );
    fs::set_permissions(&at, fs::Permissions::from_mode(0o644)).unwrap();

    // The control: the same path, gone, is the deletion it looks like.
    fs::remove_file(&at).unwrap();
    let gone = shown(&repo.scan(&generated).unwrap(), OWNED[0]);
    assert_eq!(
        gone.diff.files[0].status,
        crate::package::diff::FileStatus::Removed
    );
}

/// The leaf is not the only component that can be a link. An ancestor
/// replaced by one carries an ordinary read out of the project, so the
/// read is refused: the path the offer named no longer names a file inside
/// this project, and the window shows no bytes from outside it.
#[cfg(unix)]
#[test]
fn a_link_above_the_file_takes_the_read_out_of_the_project_and_is_refused() {
    const INSIDE: &str = ".claude/skills/dev/SKILL.md";
    let repo = Repo::new(&[(INSIDE, "ours\n")]);
    let generated = repo.generated(&[INSIDE], &[]);
    // Somewhere this project must never read from, holding a name the
    // covered path would reach through a swapped ancestor.
    let outside = repo.root.parent().unwrap().join("elsewhere");
    fs::create_dir_all(outside.join("dev")).unwrap();
    fs::write(outside.join("dev/SKILL.md"), "SECRET-FROM-OUTSIDE\n").unwrap();

    fs::remove_dir_all(repo.root.join(".claude/skills")).unwrap();
    std::os::unix::fs::symlink(&outside, repo.root.join(".claude/skills")).unwrap();

    let found = repo.scan(&generated).unwrap();
    assert!(
        found.owned.iter().any(|owned| owned.path == INSIDE),
        "the swapped ancestor left the covered path out of the scan, so this case proves nothing"
    );
    let failed = file_changes(&found, INSIDE).expect_err("the read followed the swapped ancestor");
    let said = failed.said().join("\n");
    assert!(
        said.contains(".claude/skills"),
        "the refusal did not name the link: {said}"
    );
    assert!(
        !said.contains("SECRET-FROM-OUTSIDE"),
        "bytes from outside the project reached the window"
    );
}

/// A first kendex write in a fresh `git init` is a state the offer
/// supports: `HEAD` names nothing, so every covered path is one this
/// change adds. Every call that names `HEAD` asks whether there is one
/// first, or opening a file there would answer with git's refusal instead
/// of the file.
#[test]
fn the_first_commit_in_a_fresh_repository_reads_as_files_being_added() {
    let repo = Repo::empty();
    repo.write(OWNED[0], "one\n");
    let generated = repo.generated(&[OWNED[0]], &[]);
    let found = repo.scan(&generated).unwrap();
    assert_eq!(found.count(), 1, "the write left the offer's set");

    let added = shown(&found, OWNED[0]);
    assert_eq!(
        added.diff.files[0].status,
        crate::package::diff::FileStatus::Added
    );
    assert_eq!(hunk_text(&added.diff), ["+one"]);
    assert_eq!(added.mode, None, "a file arriving is not a mode change");
}

/// A package update can replace the file `foo` with the folder `foo/bar`,
/// and the scan offers both. Neither side may read a directory as a file:
/// `foo` is the removal it is, and `foo/bar` the addition it is, so both
/// halves of the replacement can be opened.
#[test]
fn a_file_replaced_by_a_folder_of_the_same_name_shows_both_halves() {
    const WAS_FILE: &str = ".claude/skills/dev";
    const NOW_INSIDE: &str = ".claude/skills/dev/SKILL.md";
    let repo = Repo::new(&[(WAS_FILE, "the whole skill\n")]);
    fs::remove_file(repo.root.join(WAS_FILE)).unwrap();
    repo.write(NOW_INSIDE, "the skill's body\n");
    let generated = repo.generated(&[WAS_FILE, NOW_INSIDE], &[]);
    let found = repo.scan(&generated).unwrap();

    let gone = shown(&found, WAS_FILE);
    assert_eq!(
        gone.diff.files[0].status,
        crate::package::diff::FileStatus::Removed,
        "the folder standing where the file was read as something else"
    );
    assert_eq!(hunk_text(&gone.diff), ["-the whole skill"]);

    let arrived = shown(&found, NOW_INSIDE);
    assert_eq!(
        arrived.diff.files[0].status,
        crate::package::diff::FileStatus::Added
    );
    assert_eq!(hunk_text(&arrived.diff), ["+the skill's body"]);
}

/// The commit stages with `git add`, and staging is where a repository's
/// attributes apply: a checkout with `core.autocrlf` on, or a
/// `.gitattributes` naming end-of-line conversion, holds bytes on disk that
/// are not the bytes committed. The after side is what git would stage, so
/// the window shows the one line that changed and not every line in the
/// file — which is what a person on Windows would otherwise be asked to
/// approve.
#[test]
fn the_after_side_is_what_git_would_stage_and_not_the_bytes_on_disk() {
    const ATTRIBUTES: &str = ".gitattributes";
    let repo = Repo::new(&[
        (ATTRIBUTES, "* text=auto eol=lf\n"),
        (OWNED[0], "one\ntwo\n"),
    ]);
    // The same file with one line edited, written the way a checkout under
    // `core.autocrlf` holds it.
    repo.write(OWNED[0], "one\r\ntwo changed\r\n");
    let generated = repo.generated(&[OWNED[0]], &[]);
    let found = repo.scan(&generated).unwrap();

    let opened = shown(&found, OWNED[0]);
    assert_eq!(
        opened.diff.files[0].status,
        crate::package::diff::FileStatus::Modified
    );
    assert_eq!(
        hunk_text(&opened.diff),
        [" one", "-two", "+two changed"],
        "the line endings on disk were compared against the blob git holds"
    );
}

/// The replacement runs the other way too: an update can put the file `foo`
/// back where the folder `foo/bar` stood. Then the covered path `foo/bar`
/// has an ancestor that is a regular file, which no read can continue
/// through — the walk has to answer that the leaf is gone, or the deletion
/// draws as the machine's word for a path that stopped at a file.
#[test]
fn a_folder_replaced_by_a_file_of_the_same_name_shows_both_halves() {
    const WAS_INSIDE: &str = ".claude/skills/dev/SKILL.md";
    const NOW_FILE: &str = ".claude/skills/dev";
    let repo = Repo::new(&[(WAS_INSIDE, "the skill's body\n")]);
    fs::remove_dir_all(repo.root.join(NOW_FILE)).unwrap();
    repo.write(NOW_FILE, "the whole skill\n");
    let generated = repo.generated(&[WAS_INSIDE, NOW_FILE], &[]);
    let found = repo.scan(&generated).unwrap();

    let gone = shown(&found, WAS_INSIDE);
    assert_eq!(
        gone.diff.files[0].status,
        crate::package::diff::FileStatus::Removed,
        "the file standing where the folder was read as something else"
    );
    assert_eq!(hunk_text(&gone.diff), ["-the skill's body"]);

    let arrived = shown(&found, NOW_FILE);
    assert_eq!(
        arrived.diff.files[0].status,
        crate::package::diff::FileStatus::Added
    );
    assert_eq!(hunk_text(&arrived.diff), ["+the whole skill"]);
}

/// Both reads that name a covered path hand it to git in a pathspec
/// position, so both go through `pathspec::literal`. A path opening with
/// the `:` a pathspec magic prefix starts with is read as magic without it
/// and
/// matches nothing at all: `ls-tree` then reports no before side and the
/// file draws as one this change adds, when it is one the change rewrites.
#[cfg(unix)]
#[test]
fn a_path_git_would_read_as_pathspec_magic_is_taken_as_the_path_it_is() {
    const OURS: &str = ":note.md";
    let repo = Repo::new(&[(OURS, "ours\n")]);
    repo.write(OURS, "ours changed\n");
    let generated = repo.generated(&[OURS], &[]);
    let found = repo.scan(&generated).unwrap();
    assert_eq!(found.count(), 1, "the path left the offer's set");

    let opened = shown(&found, OURS);
    assert_eq!(
        opened.diff.files[0].status,
        crate::package::diff::FileStatus::Modified,
        "the before side was lost, so a rewrite drew as an addition"
    );
    assert_eq!(hunk_text(&opened.diff), ["-ours", "+ours changed"]);
}

/// A rendered path can also hold `[`, `*` or `?`, and `git diff` globs a
/// pathspec. Without the literal prefix the mode read gets a row per file
/// the path's shape names, and it reads the first — so a changed file of
/// the person's own that sorts ahead of the one they opened hands over its
/// mode as though it were theirs.
#[cfg(unix)]
#[test]
fn a_glob_shaped_path_reads_its_own_mode_and_not_a_neighbours() {
    use std::os::unix::fs::PermissionsExt;
    const OURS: &str = "docs/a[0].md";
    // What `docs/a[0].md` globs to. It sorts ahead of the path itself,
    // since `0` precedes `[`, so a globbing read lists it first.
    const DECOY: &str = "docs/a0.md";
    let repo = Repo::new(&[(OURS, "ours\n"), (DECOY, "theirs\n")]);
    repo.write(OURS, "ours changed\n");
    fs::set_permissions(repo.root.join(DECOY), fs::Permissions::from_mode(0o755)).unwrap();
    let generated = repo.generated(&[OURS], &[]);
    let found = repo.scan(&generated).unwrap();
    assert_eq!(
        found.others, 1,
        "the decoy is the person's own changed file"
    );

    let opened = shown(&found, OURS);
    assert_eq!(hunk_text(&opened.diff), ["-ours", "+ours changed"]);
    assert_eq!(
        opened.mode, None,
        "the decoy's mode was reported as this file's"
    );
}

// ---------------------------------------------------------------------
// Which pending change one action made, and which was already there.

/// What the action did to each covered path, as a sorted list the rows
/// below read.
fn attributed(scan: &Scan, since: &Baseline) -> Vec<(String, Attribution)> {
    pending(scan, since)
        .files
        .iter()
        .map(|file| (file.path.clone(), file.attribution))
        .collect()
}

/// The comparison is of the content, not of the path list. A file the
/// action left exactly as it found it is earlier work whatever its name;
/// one it changed is the action's; one it changed that was already changed
/// is both, because git commits whole files and no commit can carry one and
/// not the other.
#[test]
fn what_the_action_did_is_read_from_the_content_and_not_from_the_names() {
    let repo = Repo::new(&[
        (OWNED[0], "one\n"),
        (OWNED[1], "two\n"),
        ("docs/left.md", "left\n"),
    ]);
    let generated = repo.generated(&[OWNED[0], OWNED[1], "docs/left.md"], &[]);
    // Left as diffs before the action ran: one file rewritten, one still
    // clean.
    repo.write(OWNED[0], "one, edited by hand\n");
    repo.write("docs/left.md", "left, edited by hand\n");
    let before = baseline(&repo.scope(), &generated).unwrap();
    assert_eq!(before.held.len(), 2, "the pending paths were not read");

    // The action rewrites one clean file, rewrites one already-pending file
    // again, and leaves the third alone.
    repo.write(OWNED[1], "two, written by kendex\n");
    repo.write(OWNED[0], "one, written by kendex over the edit\n");

    // The scan sorts by path, so the rows read in that order.
    let scan = repo.scan(&generated).unwrap();
    assert_eq!(
        attributed(&scan, &before),
        [
            (OWNED[1].to_owned(), Attribution::Action),
            (OWNED[0].to_owned(), Attribution::Both),
            ("docs/left.md".to_owned(), Attribution::Older),
        ]
    );

    let pending = pending(&scan, &before);
    assert!(pending.acted(), "an action that wrote read as having not");
    assert!(!pending.same(), "the two choices read as one commit");
    // The file the action changed over an earlier edit is named, and the
    // one the action never touched is not — it is simply left out.
    assert_eq!(
        pending
            .tangled()
            .iter()
            .map(|tangle| (tangle.path.clone(), tangle.reason))
            .collect::<Vec<_>>(),
        [(OWNED[0].to_owned(), Tangled::CarriesEarlier)]
    );
}

/// A project the action never wrote in has nothing to offer about, however
/// much is pending there. This is what stops a write in one project putting
/// another project's old work in front of the reader.
#[test]
fn an_action_that_wrote_nothing_here_has_nothing_to_offer_about_it() {
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    let generated = repo.generated(&[OWNED[0]], &[]);
    repo.write(OWNED[0], "left as a diff\n");
    let before = baseline(&repo.scope(), &generated).unwrap();

    let scan = repo.scan(&generated).unwrap();
    let pending = pending(&scan, &before);
    assert!(!pending.acted());
    assert_eq!(pending.action_set(), BTreeSet::new());
}

/// A reading the machine refused is not a match. Reporting it as unchanged
/// would put earlier work into a commit labelled as the action's — the one
/// thing this comparison exists to stop.
#[test]
fn a_reading_that_could_not_be_taken_never_compares_as_unchanged() {
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    let generated = repo.generated(&[OWNED[0]], &[]);
    repo.write(OWNED[0], "edited by hand\n");
    let mut before = baseline(&repo.scope(), &generated).unwrap();
    before.held.insert(OWNED[0].to_owned(), Held::Unreadable);

    let scan = repo.scan(&generated).unwrap();
    assert_eq!(
        attributed(&scan, &before),
        [(OWNED[0].to_owned(), Attribution::Both)]
    );
}

/// A commit that adds or takes away a rendered path carries the files that
/// declare what kendex renders here. Where their own pending change is not
/// the action's, the action's work cannot be committed on its own, and the
/// file that stops it is named rather than quietly taken.
#[test]
fn a_render_the_action_adds_takes_its_declarations_with_it() {
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    let generated = repo.generated(&[OWNED[0], OWNED[1]], &[]);
    // Earlier work in the inventory alone, left as a diff.
    repo.write(INVENTORY, "[\"changed by hand\"]");
    let before = baseline(&repo.scope(), &generated).unwrap();

    // The action adds a render.
    repo.write(OWNED[1], "@AGENTS.md\n");
    let scan = repo.scan(&generated).unwrap();
    let pending = pending(&scan, &before);

    assert!(
        pending.action_set().contains(INVENTORY),
        "a render was added without the file that records it"
    );
    assert_eq!(
        pending
            .tangled()
            .iter()
            .map(|tangle| (tangle.path.clone(), tangle.reason))
            .collect::<Vec<_>>(),
        [(INVENTORY.to_owned(), Tangled::DeclaresWhatChanged)]
    );
}

/// A render the action only rewrites changes no declaration, so a
/// declaration's own earlier change stays out of the action's commit.
#[test]
fn a_render_the_action_only_rewrites_leaves_the_declarations_alone() {
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    let generated = repo.generated(&[OWNED[0]], &[]);
    repo.write(INVENTORY, "[\"changed by hand\"]");
    let before = baseline(&repo.scope(), &generated).unwrap();

    repo.write(OWNED[0], "one, written by kendex\n");
    let scan = repo.scan(&generated).unwrap();
    let pending = pending(&scan, &before);

    assert_eq!(
        pending.action_set(),
        [OWNED[0].to_owned()].into_iter().collect::<BTreeSet<_>>()
    );
    assert!(pending.tangled().is_empty(), "{:?}", pending.tangled());
}

/// The manifest is not a file kendex owns whole. `manifest::fold` edits the
/// keys kendex holds and leaves the rest of the document — comments, key
/// order, a note inside a declaration — exactly as the person wrote it, so
/// neither a commit nor the restore that writes over this set may take it.
///
/// Both spellings are checked. A source catalog moves the declaration that
/// drives renders to a sibling file, so a fixed name here would claim the
/// maintainer's published catalogue and miss the file that actually matters.
#[test]
fn the_manifest_is_never_one_of_the_files_the_offer_covers() {
    for (name, catalog) in [("an ordinary project", false), ("a source catalog", true)] {
        let repo = Repo::new(&[
            (OWNED[0], "one\n"),
            ("kendex.toml", "# a note the person wrote\n"),
            ("kendex-local.toml", "schema = 6\n"),
        ]);
        let generated = repo.generated(&[OWNED[0]], &[]);
        repo.write(
            "kendex.toml",
            match catalog {
                true => "is_source_catalog = true\n# the person edited their note\n",
                false => "# the person edited their note\n",
            },
        );
        repo.write("kendex-local.toml", "schema = 6\n[skills]\ngh = \"kit\"\n");
        repo.write(OWNED[0], "one, written by kendex\n");

        let scan = repo.scan(&generated).unwrap();
        let covered: Vec<&str> = scan.owned.iter().map(|one| one.path.as_str()).collect();
        assert!(!covered.contains(&"kendex.toml"), "{name}: {covered:?}");
        assert!(
            !covered.contains(&"kendex-local.toml"),
            "{name}: {covered:?}"
        );
        // Counted as the person's own changed files, which is what they are.
        assert_eq!(scan.others, 2, "{name}");
    }
}

/// The restore writes `HEAD` over what it is given, so a hand-authored file
/// must never reach it — not as a chosen path, and not as a companion the
/// plan adds on the reader's behalf.
#[test]
fn putting_a_render_back_never_writes_over_the_manifest() {
    let home = tempfile::tempdir().unwrap();
    let env = env_in(&crate::test_util::rooted(&home));
    let repo = Repo::new(&[(OWNED[0], "one\n"), ("kendex.toml", "# committed\n")]);
    let generated = repo.generated(&[OWNED[0], OWNED[1]], &[]);
    // The action adds a render, and the person has edited their manifest.
    repo.write(OWNED[1], "added\n");
    repo.write(INVENTORY, "[\"a\",\"b\"]");
    repo.write("kendex.toml", "# an uncommitted note\n");

    let chosen: BTreeSet<String> = [OWNED[1].to_owned(), "kendex.toml".to_owned()]
        .into_iter()
        .collect();
    let done = restore(&env, &repo.scope(), &generated, &chosen).unwrap();
    // Named and refused rather than silently taken.
    assert_eq!(done.dropped, ["kendex.toml".to_owned()]);
    assert!(!done.restored.contains(&"kendex.toml".to_owned()));
    assert!(!done.added.contains(&"kendex.toml".to_owned()));
    assert_eq!(
        fs::read_to_string(repo.root.join("kendex.toml")).unwrap(),
        "# an uncommitted note\n",
        "the person's uncommitted note was written over"
    );
    // The inventory still travels, because kendex owns that one end to end.
    assert_eq!(done.added, [INVENTORY.to_owned()]);
}

// ---------------------------------------------------------------------
// What a selected commit carries, proved by the commit and the tree it
// leaves behind.

/// The paths of one commit, and what `git status` says afterwards.
fn committed_and_left(repo: &Repo) -> (BTreeSet<String>, String) {
    (repo.head_files(), repo.status())
}

/// Only this action's work goes in, and everything else stays exactly where
/// it was: earlier kendex work still pending, the person's own changes,
/// their staged copy, and the shared configuration file kendex writes one
/// key in.
#[test]
fn only_this_actions_work_is_committed_and_the_rest_stays_pending() {
    const SHARED: &str = ".mcp.json";
    const EARLIER: &str = "docs/earlier.md";
    const GONE: &str = "docs/gone.md";
    let repo = Repo::new(&[
        (OWNED[0], "one\n"),
        (EARLIER, "earlier\n"),
        (GONE, "gone\n"),
        ("mine.md", "mine\n"),
        ("staged.md", "s\n"),
        (SHARED, "{}\n"),
    ]);
    let generated = repo.generated(&[OWNED[0], OWNED[1], EARLIER, GONE], &[SHARED]);
    // Everything that was already there before the action: one render left
    // as a diff, the person's own change, their staged copy, and the shared
    // configuration file kendex writes one key in.
    repo.write(EARLIER, "earlier, left as a diff\n");
    repo.write("mine.md", "changed\n");
    repo.write("staged.md", "staged\n");
    repo.write(SHARED, "{\"servers\":{}}\n");
    repo.git(&["add", "staged.md"]);
    let before = baseline(&repo.scope(), &generated).unwrap();

    // The action: one render rewritten, one added, one taken away.
    repo.write(OWNED[0], "one, written by kendex\n");
    repo.write(OWNED[1], "@AGENTS.md\n");
    fs::remove_file(repo.root.join(GONE)).unwrap();

    let scan = repo.scan(&generated).unwrap();
    let pending = pending(&scan, &before);
    let chosen = Selection::Only(pending.action_set());

    let made = commit(&repo.root, &generated, "chore: kendex install", &chosen).unwrap();
    let Committed::Made { files, dropped, .. } = made else {
        panic!("nothing was committed");
    };
    assert!(dropped.is_empty(), "{dropped:?}");

    let (in_commit, left) = committed_and_left(&repo);
    // The action's three paths, and NOT the render that was already pending
    // before it.
    assert_eq!(
        in_commit,
        [OWNED[0], OWNED[1], GONE]
            .into_iter()
            .map(str::to_owned)
            .collect::<BTreeSet<_>>()
    );
    assert_eq!(files, in_commit.len());
    // The addition is a file in the commit, and the removal is a removal.
    assert_eq!(
        repo.git(&["show", &format!("HEAD:{}", OWNED[1])]),
        "@AGENTS.md\n"
    );
    assert!(
        !repo
            .git(&["ls-tree", "--name-only", "HEAD", "--", GONE])
            .contains(GONE),
        "the removal did not land"
    );
    // Everything else is exactly where it was.
    assert!(left.contains(&format!(" M {EARLIER}")), "{left}");
    assert!(left.contains(" M mine.md"), "{left}");
    assert!(left.contains("M  staged.md"), "{left}");
    assert!(left.contains(&format!(" M {SHARED}")), "{left}");
}

/// The same project, the same moment, the other choice: everything pending
/// goes in. The earlier render joins the commit and nothing of the
/// person's does.
#[test]
fn all_pending_changes_commits_the_earlier_work_too() {
    let repo = Repo::new(&[
        (OWNED[0], "one\n"),
        ("docs/earlier.md", "earlier\n"),
        ("mine.md", "mine\n"),
    ]);
    let generated = repo.generated(&[OWNED[0], "docs/earlier.md"], &[]);
    repo.write("docs/earlier.md", "earlier, left as a diff\n");
    repo.write("mine.md", "changed\n");
    let before = baseline(&repo.scope(), &generated).unwrap();
    repo.write(OWNED[0], "one, written by kendex\n");

    let scan = repo.scan(&generated).unwrap();
    let pending = pending(&scan, &before);
    // The two choices differ here, which is what makes the choice worth
    // putting to a reader at all.
    assert!(!pending.same());

    commit(
        &repo.root,
        &generated,
        "chore: kendex refresh",
        &Selection::All,
    )
    .unwrap();
    let (in_commit, left) = committed_and_left(&repo);
    assert_eq!(
        in_commit,
        [OWNED[0], "docs/earlier.md"]
            .into_iter()
            .map(str::to_owned)
            .collect::<BTreeSet<_>>()
    );
    assert!(left.contains(" M mine.md"), "{left}");
}

/// A file both the action and earlier work changed goes in whole or not at
/// all: git commits whole files. The action's commit carries the earlier
/// edit with it, which is why the surfaces name the file and make the
/// reader say yes.
#[test]
fn one_file_that_carries_both_changes_goes_in_whole() {
    let repo = Repo::new(&[(OWNED[0], "one\nkeep\n")]);
    let generated = repo.generated(&[OWNED[0]], &[]);
    repo.write(OWNED[0], "one\nedited by hand\n");
    let before = baseline(&repo.scope(), &generated).unwrap();
    repo.write(OWNED[0], "written by kendex\nedited by hand\n");

    let scan = repo.scan(&generated).unwrap();
    let pending = pending(&scan, &before);
    assert_eq!(
        pending
            .tangled()
            .iter()
            .map(|tangle| tangle.reason)
            .collect::<Vec<_>>(),
        [Tangled::CarriesEarlier]
    );

    commit(
        &repo.root,
        &generated,
        "chore: kendex refresh",
        &Selection::Only(pending.action_set()),
    )
    .unwrap();
    // The whole file is in the commit, the hand edit with it, and nothing
    // of it is left pending.
    assert_eq!(
        repo.git(&["show", &format!("HEAD:{}", OWNED[0])]),
        "written by kendex\nedited by hand\n"
    );
    assert!(!repo.status().contains(OWNED[0]), "{}", repo.status());
}

/// A path the project stopped holding a change for between the offer being
/// drawn and the commit running is left out and named, never guessed at.
#[test]
fn a_chosen_path_that_changed_back_is_dropped_and_named() {
    let repo = Repo::new(&[(OWNED[0], "one\n"), (OWNED[1], "two\n")]);
    let generated = repo.generated(&[OWNED[0], OWNED[1]], &[]);
    repo.write(OWNED[0], "one, written by kendex\n");
    repo.write(OWNED[1], "two, written by kendex\n");
    let chosen: BTreeSet<String> = [OWNED[0], OWNED[1]]
        .into_iter()
        .map(str::to_owned)
        .collect();
    // One of them changes back before the commit runs.
    repo.write(OWNED[1], "two\n");

    let made = commit(
        &repo.root,
        &generated,
        "chore: kendex refresh",
        &Selection::Only(chosen),
    )
    .unwrap();
    let Committed::Made { files, dropped, .. } = made else {
        panic!("nothing was committed");
    };
    assert_eq!(files, 1);
    assert_eq!(dropped, [OWNED[1].to_owned()]);
    assert_eq!(
        repo.head_files(),
        [OWNED[0].to_owned()].into_iter().collect::<BTreeSet<_>>()
    );
}

/// A selection the fresh reading covers none of is nothing to commit, and
/// no empty commit is made for it.
#[test]
fn a_selection_the_project_no_longer_covers_commits_nothing() {
    let repo = Repo::new(&[(OWNED[0], "one\n"), (OWNED[1], "two\n")]);
    let generated = repo.generated(&[OWNED[0], OWNED[1]], &[]);
    repo.write(OWNED[1], "two, written by kendex\n");
    let before = git::head_short(&repo.root).unwrap();
    assert_eq!(
        commit(
            &repo.root,
            &generated,
            "chore: kendex refresh",
            &Selection::Only([OWNED[0].to_owned()].into_iter().collect()),
        )
        .unwrap(),
        Committed::Nothing
    );
    assert_eq!(git::head_short(&repo.root).unwrap(), before);
}

// ---------------------------------------------------------------------
// Putting a pending change back to what the last commit holds.

fn env_in(home: &Path) -> Env {
    Env::fake(home, crate::env::FakeOs::Linux)
}

/// The committed version comes back over a file that was rewritten, a file
/// kendex added moves to the trash rather than being deleted, and a file it
/// removed comes back. Everything else — the index, the person's own
/// changes, the shared file — is exactly where it was.
#[test]
fn putting_files_back_restores_what_the_commit_holds_and_trashes_the_rest() {
    let home = tempfile::tempdir().unwrap();
    let env = env_in(&crate::test_util::rooted(&home));
    const SHARED: &str = ".mcp.json";
    let repo = Repo::new(&[
        (OWNED[0], "committed\n"),
        ("docs/swept.md", "swept\n"),
        ("mine.md", "mine\n"),
        ("staged.md", "s\n"),
        (SHARED, "{}\n"),
    ]);
    let generated = repo.generated(&[OWNED[0], OWNED[1], "docs/swept.md"], &[SHARED]);
    repo.write(OWNED[0], "rewritten\n");
    repo.write(OWNED[1], "added\n");
    fs::remove_file(repo.root.join("docs/swept.md")).unwrap();
    repo.write("mine.md", "changed\n");
    repo.write("staged.md", "staged\n");
    repo.write(SHARED, "{\"servers\":{}}\n");
    repo.git(&["add", "staged.md"]);

    let scan = repo.scan(&generated).unwrap();
    let chosen: BTreeSet<String> = scan.owned.iter().map(|one| one.path.clone()).collect();
    let planned = restore_plan(&repo.scope(), &generated, &chosen).unwrap();
    let done = restore(&env, &repo.scope(), &generated, &chosen).unwrap();
    // The preview is what ran, not a guess beside it.
    assert_eq!(planned, done);
    assert_eq!(
        done.restored,
        [OWNED[0].to_owned(), "docs/swept.md".to_owned()]
    );
    assert_eq!(done.removed, [OWNED[1].to_owned()]);

    assert_eq!(
        fs::read_to_string(repo.root.join(OWNED[0])).unwrap(),
        "committed\n"
    );
    assert_eq!(
        fs::read_to_string(repo.root.join("docs/swept.md")).unwrap(),
        "swept\n"
    );
    assert!(
        !repo.root.join(OWNED[1]).exists(),
        "the added file is still there"
    );
    // Removal never deletes: what was taken away is in the trash.
    let trashed: Vec<String> = fs::read_dir(env.trash_dir())
        .unwrap()
        .flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(trashed.len(), 1, "{trashed:?}");
    assert!(trashed[0].ends_with("CLAUDE.md"), "{trashed:?}");

    // Nothing else moved.
    let left = repo.status();
    assert!(left.contains(" M mine.md"), "{left}");
    assert!(left.contains("M  staged.md"), "{left}");
    assert!(left.contains(&format!(" M {SHARED}")), "{left}");
    assert!(!left.contains(".claude/"), "{left}");
}

/// Putting back a render kendex added takes the files that declare it back
/// too, and says so. Left behind, the next write into this project would
/// put the render straight back.
#[test]
fn putting_back_a_render_that_was_added_takes_its_declarations_with_it() {
    let home = tempfile::tempdir().unwrap();
    let env = env_in(&crate::test_util::rooted(&home));
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    let generated = repo.generated(&[OWNED[0], OWNED[1]], &[]);
    repo.write(OWNED[1], "added\n");
    repo.write(INVENTORY, "[\"a\",\"b\"]");

    let chosen: BTreeSet<String> = [OWNED[1].to_owned()].into_iter().collect();
    let done = restore(&env, &repo.scope(), &generated, &chosen).unwrap();
    assert_eq!(done.added, [INVENTORY.to_owned()]);
    assert_eq!(done.restored, [INVENTORY.to_owned()]);
    assert_eq!(done.removed, [OWNED[1].to_owned()]);
    assert!(!repo.status().contains(INVENTORY), "{}", repo.status());
}

/// Only what the offer covers is put back. A path the person names that
/// kendex does not own, or that has changed back, is reported and left
/// alone.
#[test]
fn putting_files_back_touches_nothing_the_offer_does_not_cover() {
    let home = tempfile::tempdir().unwrap();
    let env = env_in(&crate::test_util::rooted(&home));
    let repo = Repo::new(&[(OWNED[0], "one\n"), ("mine.md", "mine\n")]);
    let generated = repo.generated(&[OWNED[0]], &[]);
    repo.write(OWNED[0], "rewritten\n");
    repo.write("mine.md", "changed\n");

    let chosen: BTreeSet<String> = ["mine.md".to_owned()].into_iter().collect();
    let done = restore(&env, &repo.scope(), &generated, &chosen).unwrap();
    assert!(done.empty(), "{done:?}");
    assert_eq!(done.dropped, ["mine.md".to_owned()]);
    assert_eq!(
        fs::read_to_string(repo.root.join("mine.md")).unwrap(),
        "changed\n"
    );
}

/// A restore writes in two passes, and a failure among the removals leaves
/// the first pass standing. Reporting that as a bare refusal tells a person
/// nothing happened while their files have already moved, so what was
/// written travels with the failure.
#[cfg(unix)]
#[test]
fn a_restore_that_stops_part_way_reports_what_it_already_wrote() {
    use std::os::unix::fs::PermissionsExt;
    let home = tempfile::tempdir().unwrap();
    let env = env_in(&crate::test_util::rooted(&home));
    let repo = Repo::new(&[(OWNED[0], "committed\n")]);
    let generated = repo.generated(&[OWNED[0], OWNED[1]], &[]);
    repo.write(OWNED[0], "rewritten\n");
    repo.write(OWNED[1], "added\n");

    // The trash cannot be written, so moving the added file there fails —
    // after the restore pass has already put the rewritten one back.
    let trash = env.trash_dir();
    fs::create_dir_all(&trash).unwrap();
    fs::set_permissions(&trash, fs::Permissions::from_mode(0o500)).unwrap();

    let chosen: BTreeSet<String> = [OWNED[0].to_owned(), OWNED[1].to_owned()]
        .into_iter()
        .collect();
    let failure = restore(&env, &repo.scope(), &generated, &chosen).unwrap_err();
    fs::set_permissions(&trash, fs::Permissions::from_mode(0o700)).unwrap();

    assert_eq!(failure.failed.step, Step::Restore);
    assert!(!failure.failed.said().is_empty());
    // The account names the pass that landed and claims no removal.
    assert_eq!(failure.done.restored, [OWNED[0].to_owned()]);
    assert!(
        failure.done.removed.is_empty(),
        "{:?}",
        failure.done.removed
    );
    // And it is true: that file really is back, and the other is still there.
    assert_eq!(
        fs::read_to_string(repo.root.join(OWNED[0])).unwrap(),
        "committed\n"
    );
    assert!(repo.root.join(OWNED[1]).exists());
}

/// A restore that stops before writing anything has nothing to account for,
/// so it reports an empty one rather than claiming work it never did.
#[test]
fn a_restore_that_writes_nothing_accounts_for_nothing() {
    let home = tempfile::tempdir().unwrap();
    let env = env_in(&crate::test_util::rooted(&home));
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    let generated = repo.generated(&[OWNED[0]], &[]);
    // Nothing is pending, so the plan is empty and the run writes nothing.
    let done = restore(&env, &repo.scope(), &generated, &BTreeSet::new()).unwrap();
    assert!(done.empty(), "{done:?}");
    let straight: Box<RestoreFailure> = failed_read().into();
    assert_eq!(straight.done, RestorePlan::default());
}

/// A read that would not run, for the conversion above.
fn failed_read() -> Failed {
    Failed {
        step: Step::Restore,
        refusal: Refusal::Said(vec!["git said no".to_owned()]),
    }
}

/// The born question is asked of the exit status, and only git's own "no
/// commit yet" exit answers it.
///
/// A read that took every non-zero exit for an unborn `HEAD` — which is what
/// `git::read`, and so `previous_head`, does — would put every chosen path
/// in `removed` and trash the files the person asked to put back. The three
/// states are checked against real git rather than assumed: 0 where a commit
/// resolves, 1 where the repository has none, and 128 with git's words where
/// it is not a repository at all.
#[test]
fn only_gits_own_unborn_exit_answers_the_born_question() {
    let repo = Repo::new(&[(OWNED[0], "one\n")]);
    assert!(
        git::born(&repo.root).unwrap(),
        "a commit did not read as born"
    );

    let empty = Repo::empty();
    assert!(
        !git::born(&empty.root).unwrap(),
        "an unborn HEAD did not read as unborn"
    );

    // Not a repository: git exits 128 and says so. Answering `false` here is
    // the fail-open this rule exists to stop.
    let tmp = tempfile::tempdir().unwrap();
    let plain = crate::test_util::rooted(&tmp);
    let failed = git::born(&plain).unwrap_err();
    assert_eq!(failed.step, Step::Read);
    assert!(!failed.said().is_empty(), "git said nothing");
}

/// A repository git cannot read refuses rather than taking the files away.
/// The refusal here comes from the status read the plan is built from, which
/// is the first thing to meet a broken `HEAD`; the rule that keeps the born
/// read itself from answering for one is pinned above.
#[test]
fn a_repository_git_cannot_read_refuses_rather_than_trashing() {
    let home = tempfile::tempdir().unwrap();
    let env = env_in(&crate::test_util::rooted(&home));
    let repo = Repo::new(&[(OWNED[0], "committed\n")]);
    let generated = repo.generated(&[OWNED[0]], &[]);
    repo.write(OWNED[0], "rewritten\n");
    // A `HEAD` naming an object the store does not hold: git exits 128 on
    // every read of it rather than 1, which is its "no commit yet" answer.
    fs::write(repo.root.join(".git/HEAD"), format!("{}\n", "0".repeat(40))).unwrap();

    let chosen: BTreeSet<String> = [OWNED[0].to_owned()].into_iter().collect();
    let failure = restore(&env, &repo.scope(), &generated, &chosen).unwrap_err();
    assert_eq!(failure.failed.step, Step::Read);
    assert!(!failure.failed.said().is_empty(), "git said nothing");
    assert!(failure.done.empty(), "{:?}", failure.done);
    assert!(
        !failure.failed.said().iter().any(|line| line.is_empty()),
        "an empty line stood in for git's words"
    );
    // The file it was asked to put back is still there, unmoved.
    assert_eq!(
        fs::read_to_string(repo.root.join(OWNED[0])).unwrap(),
        "rewritten\n"
    );
    let trash = env.trash_dir();
    assert!(
        !trash.exists() || fs::read_dir(&trash).unwrap().next().is_none(),
        "a file was trashed"
    );
}

/// An unborn `HEAD` is still an answer, not a failure: a first kendex write
/// in a fresh `git init` reaches it, and everything pending there is a file
/// the restore takes away.
#[test]
fn an_unborn_head_still_answers_and_the_restore_takes_the_files_away() {
    let home = tempfile::tempdir().unwrap();
    let env = env_in(&crate::test_util::rooted(&home));
    let repo = Repo::empty();
    repo.write(OWNED[0], "written by kendex\n");
    let generated = repo.generated(&[OWNED[0]], &[]);

    let chosen: BTreeSet<String> = [OWNED[0].to_owned()].into_iter().collect();
    let done = restore(&env, &repo.scope(), &generated, &chosen).unwrap();
    assert_eq!(done.removed, [OWNED[0].to_owned()]);
    assert!(done.restored.is_empty(), "{:?}", done.restored);
    assert!(!repo.root.join(OWNED[0]).exists());
}

/// A restore moves the working tree; it does not change what kendex is asked
/// to render. A render taken away comes back the next time kendex writes
/// here, so the plan names it rather than promising a removal that does not
/// last. kendex cannot revert the commit of the declaration that asks for it.
#[test]
fn the_plan_names_what_the_next_write_would_put_back() {
    let repo = Repo::new(&[(OWNED[0], "committed\n")]);
    let generated = repo.generated(&[OWNED[0], OWNED[1]], &[]);
    repo.write(OWNED[0], "rewritten\n");
    repo.write(OWNED[1], "added\n");

    let chosen: BTreeSet<String> = [OWNED[0].to_owned(), OWNED[1].to_owned()]
        .into_iter()
        .collect();
    let plan = restore_plan(&repo.scope(), &generated, &chosen).unwrap();
    // Both: the one being removed and the one being written back over.
    assert_eq!(
        plan.rerendered,
        [OWNED[1].to_owned(), OWNED[0].to_owned()]
            .into_iter()
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect::<Vec<_>>()
    );

    // A path kendex has stopped rendering is not among them: nothing will
    // write it again, so the removal lasts and the plan says nothing.
    let dropped = repo.generated(&[OWNED[0]], &[]);
    let only_gone: BTreeSet<String> = [OWNED[1].to_owned()].into_iter().collect();
    let plan = restore_plan(&repo.scope(), &dropped, &only_gone).unwrap();
    assert!(plan.rerendered.is_empty(), "{:?}", plan.rerendered);
}
