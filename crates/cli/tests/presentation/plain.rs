//! Anything but a terminal gets the lines a script already parses. What
//! this file pins is that the presentation layer added nothing to them:
//! no frame, no symbol, no colour, and the same hierarchy the verbs
//! wrote — a headline at column 0 and its detail two spaces in.

use crate::test_util::source_path;

use super::*;

/// The run the issue names, said plainly. Every line of it, in order,
/// with nothing repeated and nothing framed.
#[test]
#[allow(clippy::unwrap_used)]
fn the_blocked_refresh_prints_the_lines_scripts_parse() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let project = blocked_project(home);
    let printed = said(&kendex(
        home,
        &project,
        "plain",
        &["refresh", "-y", "--scope", "project"],
    ));
    let scope = kendex_core::paths::slashed(&project);

    let shape: Vec<String> = printed
        .lines()
        .map(|line| match line.split_whitespace().next() {
            // The finding text is the safety rules' to word, and the
            // position under it is a path; what this pins is the shape.
            Some("[critical]" | "[high]" | "[medium]" | "[low]") => "  [finding]".to_owned(),
            _ => line.replace(&scope, "<project>"),
        })
        .collect();
    assert_eq!(
        shape,
        vec![
            "safety: skill growth-guards for Claude Code, Codex scores 75/100",
            "  [finding]",
            "  also at <project>/.agents/skills/growth-guards/SKILL.md:5",
            "safety: skill tidy for Claude Code, Codex scores 75/100",
            "  [finding]",
            "  also at <project>/.agents/skills/tidy/SKILL.md:5",
            "conflict: skill growth-guards for Claude Code, Codex: <project>/.claude/skills/growth-guards already holds files kendex did not write",
            "  also at <project>/.agents/skills/growth-guards",
            "  differs from the catalog in 2 files: SKILL.md, references/rules.md",
            "  to keep those files: kendex adopt skill growth-guards --harness claude --harness codex",
            "  to install what kendex.toml asks for instead: kendex apply --replace-unmanaged",
            "<project>: this changes what is installed",
            "  - install skill tidy for Claude Code — asked for",
            "  - install skill tidy for Codex — asked for",
            "<project>: refreshed 3 changes · skipped 1 item on conflict · flagged 2 items on safety",
            "  skipped — kendex apply --replace-unmanaged, or the kendex adopt line under each conflict above",
            "  flagged — the safety lines above",
        ],
        "{printed}"
    );
}

/// The bound the issue set, and the reason for it: a run whose output a
/// reader scrolls past is a run that reported nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn the_blocked_refresh_reads_under_twenty_lines() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let project = blocked_project(home);
    let printed = said(&kendex(
        home,
        &project,
        "plain",
        &["refresh", "-y", "--scope", "project"],
    ));
    let lines = printed.lines().filter(|line| !line.is_empty()).count();
    assert!(lines < 20, "the run printed {lines} lines: {printed}");
}

/// Nothing said twice: one conflict however many tools it blocks, one
/// line naming the way out of it, and one closing ledger.
#[test]
#[allow(clippy::unwrap_used)]
fn nothing_is_said_twice() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let project = blocked_project(home);
    let printed = said(&kendex(
        home,
        &project,
        "plain",
        &["refresh", "-y", "--scope", "project"],
    ));
    for once in [
        "safety: skill growth-guards",
        "safety: skill tidy",
        "conflict:",
        "to keep those files:",
        "to install what kendex.toml asks for instead:",
        ": refreshed ",
    ] {
        assert_eq!(
            printed.matches(once).count(),
            1,
            "{once:?} was printed more than once: {printed}"
        );
    }
}

/// Not one character of the frame reaches anything but a terminal. This
/// is the whole non-interactive contract: a script's `grep` sees the same
/// bytes it saw before a presentation layer existed.
#[test]
#[allow(clippy::unwrap_used)]
fn no_framing_reaches_a_pipe() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let project = blocked_project(home);
    for args in [
        vec!["refresh", "-y", "--scope", "project"],
        vec!["apply", "--plan", "--scope", "project"],
        vec!["verify", "--scope", "project"],
        vec!["check", "--scope", "project"],
    ] {
        let printed = said(&kendex(home, &project, "plain", &args));
        let found: Vec<char> = FRAMING
            .into_iter()
            .filter(|symbol| printed.contains(*symbol))
            .collect();
        assert!(
            found.is_empty(),
            "{args:?} put {found:?} in a pipe: {printed}"
        );
    }
}

/// The detection, not the override: with no terminal on either stream and
/// nothing asked for, a run is plain. The override is a test's way in and
/// a CI switch, never what decides an ordinary run.
#[test]
#[allow(clippy::unwrap_used)]
fn a_run_with_no_terminal_is_plain_without_being_told() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let project = blocked_project(home);
    let printed = said(&kendex(
        home,
        &project,
        "",
        &["refresh", "-y", "--scope", "project"],
    ));
    assert!(
        printed.contains(": refreshed 3 changes · skipped 1 item on conflict"),
        "{printed}"
    );
    let found: Vec<char> = FRAMING
        .into_iter()
        .filter(|symbol| printed.contains(*symbol))
        .collect();
    assert!(found.is_empty(), "an undetected terminal framed: {printed}");
}

/// A payload prints as itself. `show --file` exists to put a package's
/// file in front of the reader, so escaping it the way a value in a
/// sentence is escaped hands them one line of literal `\n` instead of the
/// file — which is the whole feature.
#[test]
#[allow(clippy::unwrap_used)]
fn show_file_prints_the_files_own_lines() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let project = home.join("dev/app");
    blocked_project_at(home, &project);
    fs::write(
        home.join("catalog/skills/tidy/SKILL.md"),
        "---\nname: tidy\ndescription: does tidy\n---\nfirst line\nsecond line\nthird line\n",
    )
    .unwrap();
    kendex(
        home,
        &project,
        "plain",
        &["refresh", "-y", "--scope", "project"],
    );

    let printed = said(&kendex(
        home,
        &project,
        "plain",
        &["show", "skill", "tidy", "--file", "SKILL.md"],
    ));
    for line in ["first line", "second line", "third line"] {
        assert!(
            printed.lines().any(|out| out == line),
            "{line:?} did not reach the reader as its own line: {printed:?}"
        );
    }
    assert!(
        !printed.contains("\\n"),
        "the file was collapsed onto one line: {printed:?}"
    );
}

/// A run that wrote says so, even when what follows the write fails.
///
/// The repository-effects account is asked after the write, because the
/// script an effect runs is the one the install just put on disk. That
/// puts a fallible call between the write and the closing line, and an
/// error there used to return straight to main: disk changed, no snapshot
/// recorded for the next session-start check, and nothing said about it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_failure_after_the_write_still_records_and_reports_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    let armed = catalog.join("skills/armed");
    fs::create_dir_all(armed.join("scripts")).unwrap();
    fs::write(
        armed.join("SKILL.md"),
        "---\nname: armed\ndescription: arms something\nrepo-effects:\n  \
         summary: \"writes a file outside kendex's own folders\"\n  writes:\n    \
         - \".github/x\"\n  installer: \"scripts/boom\"\n---\nbody\n",
    )
    .unwrap();
    let boom = armed.join("scripts/boom");
    fs::write(&boom, "#!/bin/sh\nexit 1\n").unwrap();
    fs::set_permissions(&boom, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = \
             [\"claude\"]\nmethod = \"copy\"\n\n[skills.armed]\nsource = \"cat\"\n",
            source_path(&catalog)
        ),
    )
    .unwrap();

    let output = kendex(
        home,
        &project,
        "plain",
        &["apply", "-y", "--allow-repo-effects", "--scope", "project"],
    );
    let printed = said(&output);
    assert!(
        !output.status.success(),
        "the installer did not fail: {printed}"
    );
    assert!(
        printed.contains("applied 2 changes"),
        "the run said nothing about what it wrote: {printed}"
    );
    let drift = Env::host_rooted(home.clone()).drift_dir();
    let recorded = fs::read_dir(&drift).map(|d| d.count()).unwrap_or(0);
    assert_eq!(
        recorded, 1,
        "no snapshot recorded for a scope that was written: {printed}"
    );
}
