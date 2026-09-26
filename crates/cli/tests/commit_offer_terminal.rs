//! The commit offer's questions at a terminal: the held offer's setup, the
//! setup a linked work tree is offered where its main checkout has it, and
//! the refused commit's choice to show everything the commit check printed.
//! Each drives the binary through a pseudoterminal with its answers typed
//! ahead; `commit_offer_cli.rs` holds the runs with no terminal.
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

fn at_a_terminal(home: &Path, cwd: &Path, args: &[&str], answers: &str) -> (Output, String) {
    let output = pty::sent_to_a_terminal(command(home, cwd, args), answers.as_bytes());
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
    for (check, answers, committed) in [("", "1\n1\n\nn\n", true), ("  exit 1", "1\nn\n", false)] {
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
            text.matches("1  set up bot-instructions here, then offer the commit with its files")
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
                assert!(text.contains("1  commit them"), "{text}");
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
                assert!(!text.contains("1  commit them"), "{text}");
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

    let (output, text) = at_a_terminal(&home, &linked, &["apply", "--yes"], "y\n1\n\nn\n");

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

/// A refused commit at a terminal leads with the findings block and keeps
/// the rest of what the commit check printed behind a choice. Picking it
/// prints everything, and the choices come back without it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refused_commit_shows_everything_the_check_printed_on_asking() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = consumer(&home, "");
    fs::remove_dir_all(project.join("catalog")).unwrap();
    write(
        &project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\"]\n",
    );
    write(&project.join("AGENTS.md"), "# app\n");
    git(&project, &["add", "-A"]);
    git(&project, &["commit", "-q", "-m", "files"]);
    let hook = project.join(".git/hooks/pre-commit");
    write(
        &hook,
        "#!/bin/sh\necho 'commit-guards: step=doc-limits'\necho '  === pre-commit: doc-limits'\necho 'commit-guards: result=1'\necho 'bot-instructions: findings=1' >&2\necho 'drift: AGENTS.md differs from a fresh render' >&2\nexit 1\n",
    );
    fs::set_permissions(&hook, fs::Permissions::from_mode(0o755)).unwrap();

    let (output, text) = at_a_terminal(&home, &project, &["apply", "--yes"], "1\n\n3\n3\n");

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
        text.matches("show everything the commit check printed")
            .count(),
        1,
        "the second menu offered the show again:\n{text}"
    );
    let shown = at("show everything the commit check printed");
    let rest = text[shown..]
        .find("commit-guards: step=doc-limits")
        .unwrap_or_else(|| panic!("the rest was never shown:\n{text}"));
    assert!(
        text[shown + rest..].contains("3  leave them as diffs"),
        "no second menu after the full output:\n{text}"
    );
    assert_eq!(head_subject(&project), "files");
}
