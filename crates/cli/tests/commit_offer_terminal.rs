//! The commit offer's questions at a terminal: the held offer's setup, the
//! setup a linked work tree is offered where its main checkout has it, and
//! the refused commit's choice to show everything the commit check printed.
//! Each drives the binary through a pseudoterminal, typing each answer once
//! its question is drawn. `commit_offer_cli.rs` holds the runs with no
//! terminal.
#![cfg(unix)]

use crate::pty;
use crate::test_util;
use test_util::rooted;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use kendex_core::process::Hardened;

/// The fixture package's launcher. `render` writes the review file from the
/// package's own doctrine, `--dry-run` names it, and `check` passes where
/// the file matches the doctrine, unless `CHECK` replaces that answer.
const LAUNCHER: &str = "#!/bin/sh\nhere=\"$(cd \"$(dirname \"$0\")/..\" && pwd)\"\nif [ \"$1\" = check ]; then\nCHECK\n  cmp -s \"$here/doctrine.md\" .github/copilot-instructions.md\n  exit $?\nfi\nfor arg in \"$@\"; do\n  if [ \"$arg\" = --dry-run ]; then\n    echo 'would write .github/copilot-instructions.md'\n    exit 0\n  fi\ndone\nmkdir -p .github\ncp \"$here/doctrine.md\" .github/copilot-instructions.md\necho 'wrote .github/copilot-instructions.md'\n";

const DECLARATION: &str = "---\nname: bot-instructions\ndescription: fixture review rules\nrepo-effects:\n  summary: \"Renders the fixture review file in this repository.\"\n  writes:\n    - \".github/copilot-instructions.md\"\n  installer: \"scripts/bot-instructions render\"\n  checker: \"scripts/bot-instructions check\"\n---\nFixture.\n";

#[allow(clippy::unwrap_used)]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) -> String {
    let out = Hardened::git(args, Some(dir))
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t")
        .run()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn command(home: &Path, cwd: &Path, args: &[&str]) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_kendex"));
    command
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("KENDEX_UI", "plain")
        .env("PATH", std::env::var("PATH").unwrap_or_default());
    command
}

/// A run at a terminal, each answer typed once its marker is drawn.
fn at_a_terminal(
    home: &Path,
    cwd: &Path,
    args: &[&str],
    steps: &[(&str, &str)],
) -> (Output, String) {
    let output = pty::conversation(command(home, cwd, args), steps, pty::Stderr::Terminal);
    let text = String::from_utf8_lossy(&output.stderr).into_owned();
    (output, text)
}

#[allow(clippy::expect_used)]
fn without_a_terminal(home: &Path, cwd: &Path, args: &[&str]) -> String {
    let output = command(home, cwd, args)
        .output()
        .expect("kendex binary runs");
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.status.success(), "{text}");
    text
}

/// A repository whose manifest installs the fixture package from a catalog
/// inside it, for the claude harness.
#[allow(clippy::unwrap_used)]
fn consumer(home: &Path, check: &str) -> PathBuf {
    let project = home.join("dev/app");
    write(
        &project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\"]\n\n[sources.cat]\npath = \"catalog\"\n\n[skills.bot-instructions]\nsource = \"cat\"\n",
    );
    let package = project.join("catalog/skills/bot-instructions");
    write(&package.join("SKILL.md"), DECLARATION);
    write(&package.join("doctrine.md"), "review rules, first cut\n");
    let launcher = package.join("scripts/bot-instructions");
    write(&launcher, &LAUNCHER.replace("CHECK", check));
    fs::set_permissions(&launcher, fs::Permissions::from_mode(0o755)).unwrap();
    write(&project.join(".gitignore"), "/.kendex-lock.json\n");
    git(&project, &["init", "-q", "-b", "main"]);
    git(&project, &["config", "user.email", "t@t"]);
    git(&project, &["config", "user.name", "t"]);
    git(&project, &["config", "commit.gpgsign", "false"]);
    git(&project, &["config", "core.hooksPath", ".git/hooks"]);
    project
}

fn head_subject(project: &Path) -> String {
    git(project, &["log", "-1", "--format=%s"])
        .trim()
        .to_owned()
}

/// The package installed and committed, not set up here, then its doctrine
/// changed in the catalog: the next apply updates the installed copy, so
/// the offer touches the package and holds the commit.
fn installed_then_changed(home: &Path, check: &str) -> PathBuf {
    let project = consumer(home, check);
    without_a_terminal(home, &project, &["apply", "--yes", "--leave"]);
    git(&project, &["add", "-A"]);
    git(&project, &["commit", "-q", "-m", "install"]);
    write(
        &project.join("catalog/skills/bot-instructions/doctrine.md"),
        "review rules, second cut\n",
    );
    project
}

/// The held offer at a terminal. Set up, the package renders, its file
/// joins the offer and the commit is then offered and carries it. Where
/// its check still fails after the setup, the run says so, commits
/// nothing, and does not offer the setup a second time.
#[test]
#[allow(clippy::unwrap_used)]
fn the_held_offer_sets_the_package_up_once_and_offers_the_commit_with_its_files() {
    // Set up, commit with the offered message, and say no to the
    // repository changes the apply asks about after the offer.
    let set_up_and_commit: &[(&str, &str)] =
        &[("[s]", "s"), ("[c]", "c"), ("[e]", "\n"), ("[y]", "\n")];
    let set_up: &[(&str, &str)] = &[("[s]", "s"), ("[y]", "\n")];
    for (check, answers, committed) in [("", set_up_and_commit, true), ("  exit 1", set_up, false)]
    {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = installed_then_changed(&home, check);

        let (output, text) = at_a_terminal(&home, &project, &["apply", "--yes"], answers);

        for line in [
            "bot-instructions is not set up in this checkout, so its files in this repository were not brought up to date",
            "bot-instructions changes how this repository works, beyond the files above:",
            "Renders the fixture review file in this repository.",
        ] {
            assert!(text.contains(line), "{check:?}: missing {line:?}:\n{text}");
        }
        assert_eq!(
            text.matches("[s] set up bot-instructions here, then offer the commit with its files")
                .count(),
            1,
            "{check:?}: the setup was offered other than once:\n{text}"
        );
        assert!(
            project.join(".github/copilot-instructions.md").is_file(),
            "{check:?}: the setup did not render:\n{text}"
        );
        match committed {
            true => {
                assert_eq!(output.status.code(), Some(0), "{text}");
                assert!(text.contains("[c] commit them"), "{text}");
                let files = git(&project, &["show", "--name-only", "--format=", "HEAD"]);
                for path in [
                    ".github/copilot-instructions.md",
                    ".agents/skills/bot-instructions/doctrine.md",
                ] {
                    assert!(
                        files.lines().any(|line| line == path),
                        "{path}:\n{files}\n{text}"
                    );
                }
            }
            false => {
                assert_eq!(output.status.code(), Some(1), "{text}");
                assert!(
                    text.contains(
                        "it is still not ready after its setup ran; nothing was committed"
                    ),
                    "{text}"
                );
                assert!(!text.contains("[c] commit them"), "{text}");
                assert_eq!(head_subject(&project), "install", "{text}");
            }
        }
    }
}

/// A linked work tree of a repository whose main checkout set the package
/// up names that checkout, is asked in one step whether to set the package
/// up here too, and on a yes renders it and offers the commit with its
/// file.
#[test]
#[allow(clippy::unwrap_used)]
fn a_linked_work_tree_is_offered_the_setup_its_main_checkout_has() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let main = consumer(&home, "");
    git(&main, &["add", "-A"]);
    git(&main, &["commit", "-q", "-m", "declared"]);
    kendex_core::repo_effects::armed::arm(
        kendex_core::repo_effects::armed::record_dir(
            &kendex_core::guard::Repo::at(&main).unwrap(),
            false,
        ),
        "bot-instructions",
    )
    .unwrap();
    let linked = home.join("dev/linked");
    git(
        &main,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "second",
            linked.to_str().unwrap(),
        ],
    );

    let (output, text) = at_a_terminal(
        &home,
        &linked,
        &["apply", "--yes"],
        &[("[y]", "y"), ("[c]", "c"), ("[e]", "\n"), ("[y]", "\n")],
    );

    assert_eq!(output.status.code(), Some(0), "{text}");
    let skipped = format!(
        "bot-instructions: render skipped in this work tree; it is set up in the main checkout at {}",
        kendex_core::paths::slashed(&main)
    );
    for line in [
        skipped.as_str(),
        "bot-instructions changes how this repository works, beyond the files above:",
        "set bot-instructions up in this work tree too?",
    ] {
        assert!(text.contains(line), "missing {line:?}:\n{text}");
    }
    let files = git(&linked, &["show", "--name-only", "--format=", "HEAD"]);
    assert!(
        files
            .lines()
            .any(|line| line == ".github/copilot-instructions.md"),
        "the setup's file was not in the offer's commit:\n{files}\n{text}"
    );
}

/// A repository with no packages and its files committed: an apply writes
/// the harness's instruction file into it, and the offer covers that.
#[allow(clippy::unwrap_used)]
fn committed_without_packages(home: &Path) -> PathBuf {
    let project = consumer(home, "");
    fs::remove_dir_all(project.join("catalog")).unwrap();
    write(
        &project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\"]\n",
    );
    write(&project.join("AGENTS.md"), "# app\n");
    git(&project, &["add", "-A"]);
    git(&project, &["commit", "-q", "-m", "files"]);
    project
}

/// One run at a terminal: the verb's arguments, the rendering, where
/// stderr goes, each answer with the marker it waits for, the exit code
/// and the commit the project ends on.
struct Run {
    what: &'static str,
    args: &'static [&'static str],
    rendering: &'static str,
    stderr: fn() -> pty::Stderr,
    steps: &'static [(&'static str, &'static str)],
    code: i32,
    subject: &'static str,
}

/// The runs `the_offer_is_answered_by_its_keys` drives, one per way of
/// answering.
fn keyed_runs() -> [Run; 9] {
    let terminal = || pty::Stderr::Terminal;
    [
        Run {
            what: "commit",
            args: &["apply", "--yes"],
            rendering: "plain",
            stderr: terminal,
            steps: &[("[c]", "c"), ("[e]", "\n")],
            code: 0,
            subject: "chore: kendex apply",
        },
        Run {
            what: "commit",
            args: &["apply", "--yes"],
            rendering: "pretty",
            stderr: terminal,
            steps: &[("[c]", "c"), ("[e]", "\n")],
            code: 0,
            subject: "chore: kendex apply",
        },
        Run {
            what: "a typed message",
            args: &["apply", "--yes"],
            rendering: "plain",
            stderr: terminal,
            steps: &[("[c]", "c"), ("[e]", "efix: rendersX\x7f\n")],
            code: 0,
            subject: "fix: renders",
        },
        Run {
            what: "leave",
            args: &["apply", "--yes"],
            rendering: "pretty",
            stderr: terminal,
            steps: &[("[c]", "\n")],
            code: 0,
            subject: "files",
        },
        Run {
            what: "cancel",
            args: &["apply", "--yes"],
            rendering: "plain",
            stderr: terminal,
            steps: &[("[c]", "\x1b")],
            code: 130,
            subject: "files",
        },
        Run {
            what: "cancel at the typed message",
            args: &["apply", "--yes"],
            rendering: "plain",
            stderr: terminal,
            steps: &[("[c]", "c"), ("[e]", "e\x1b")],
            code: 130,
            subject: "files",
        },
        Run {
            what: "cancel at the typed message, stderr on a pipe",
            args: &["apply"],
            rendering: "plain",
            stderr: || pty::Stderr::Pipe,
            steps: &[("[y]", "y\n"), ("[c]", "c\n"), ("[e]", "e\n\x1b\n")],
            code: 130,
            subject: "files",
        },
        Run {
            what: "y and Enter at the consent, then the offer",
            args: &["apply"],
            rendering: "plain",
            stderr: terminal,
            steps: &[("[y]", "y\n"), ("[c]", "c"), ("[e]", "\n")],
            code: 0,
            subject: "chore: kendex apply",
        },
        Run {
            what: "typed lines, stderr on a pipe",
            args: &["apply"],
            rendering: "plain",
            stderr: || pty::Stderr::Pipe,
            steps: &[
                ("[y]", "yes\n"),
                ("[c]", "1\n"),
                ("[c]", "c\n"),
                ("[e]", "\n"),
            ],
            code: 0,
            subject: "chore: kendex apply",
        },
    ]
}

/// The offer's keys at a terminal, in both renderings: a key takes its
/// choice, `e` reads the message as a typed line where a backspace takes
/// back a character, Enter leaves the files as diffs, and Escape cancels,
/// at the offer and at the typed message alike, read raw or as a line.
/// A cancel keeps the write and the closing ledger, commits nothing, and
/// exits 130; a leave exits as the verb does. The Enter typed after the
/// consent's `y` does not answer the offer drawn after it. With stderr on
/// a pipe the answers are typed lines, and one that picks nothing draws
/// the choices again.
#[test]
#[allow(clippy::unwrap_used)]
fn the_offer_is_answered_by_its_keys() {
    for run in keyed_runs() {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = committed_without_packages(&home);
        let mut command = command(&home, &project, run.args);
        command.env("KENDEX_UI", run.rendering);
        let output = pty::conversation(command, run.steps, (run.stderr)());
        let text = String::from_utf8_lossy(&output.stderr).into_owned();
        let what = format!("{} {}", run.what, run.rendering);

        assert_eq!(output.status.code(), Some(run.code), "{what}:\n{text}");
        assert_eq!(head_subject(&project), run.subject, "{what}:\n{text}");
        assert!(
            text.contains("[c]") && text.contains("[Enter]"),
            "{what}: the keys were not drawn:\n{text}"
        );
        assert!(
            text.contains("applied 1 change"),
            "{what}: no closing ledger:\n{text}"
        );
    }
}

/// Choosing a different message after a refused commit reads it straight
/// away, every character of it, and commits again with it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_different_message_after_a_refusal_is_read_whole() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = committed_without_packages(&home);
    let hook = project.join(".git/hooks/commit-msg");
    write(
        &hook,
        "#!/bin/sh\nif grep -q '^chore: kendex apply' \"$1\"; then\n  echo 'commit-msg: say what the commit does' >&2\n  exit 1\nfi\n",
    );
    fs::set_permissions(&hook, fs::Permissions::from_mode(0o755)).unwrap();

    let (output, text) = at_a_terminal(
        &home,
        &project,
        &["apply", "--yes"],
        &[
            ("[c]", "c"),
            ("[e]", "\n"),
            ("[m]", "mfeat: keep entries\n"),
        ],
    );

    assert_eq!(output.status.code(), Some(0), "{text}");
    assert!(
        text.contains("commit-msg: say what the commit does"),
        "{text}"
    );
    assert_eq!(head_subject(&project), "feat: keep entries", "{text}");
}

/// A refused commit at a terminal leads with the findings block and keeps
/// the rest of what the commit check printed behind a choice. Picking it
/// prints everything, and the choices come back without it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refused_commit_shows_everything_the_check_printed_on_asking() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = committed_without_packages(&home);
    let hook = project.join(".git/hooks/pre-commit");
    write(
        &hook,
        "#!/bin/sh\necho 'commit-guards: step=doc-limits'\necho '  === pre-commit: doc-limits'\necho 'commit-guards: result=1'\necho 'bot-instructions: findings=1' >&2\necho 'drift: AGENTS.md differs from a fresh render' >&2\nexit 1\n",
    );
    fs::set_permissions(&hook, fs::Permissions::from_mode(0o755)).unwrap();

    let (output, text) = at_a_terminal(
        &home,
        &project,
        &["apply", "--yes"],
        &[("[c]", "c"), ("[e]", "\n"), ("[?]", "?"), ("[a]", "\n")],
    );

    assert_eq!(output.status.code(), Some(1), "{text}");
    let at = |line: &str| {
        text.find(line)
            .unwrap_or_else(|| panic!("missing {line:?}:\n{text}"))
    };
    assert!(
        at("drift: AGENTS.md differs from a fresh render")
            < at("the commit check printed 3 more lines"),
        "{text}"
    );
    assert_eq!(
        text.matches("[?] show everything the commit check printed")
            .count(),
        1,
        "the second menu offered the show again:\n{text}"
    );
    let shown = at("> show everything the commit check printed");
    let rest = text[shown..]
        .find("commit-guards: step=doc-limits")
        .unwrap_or_else(|| panic!("the rest was never shown:\n{text}"));
    assert!(
        text[shown + rest..].contains("[Enter] leave them as diffs"),
        "no second menu after the full output:\n{text}"
    );
    assert_eq!(head_subject(&project), "files");
}
