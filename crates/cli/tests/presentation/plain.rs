//! Anything but a terminal gets the lines a script already parses. What
//! this file pins is that the presentation layer added nothing to them:
//! no frame, no symbol, no colour, and the same hierarchy the verbs
//! wrote — a headline at column 0 and its detail two spaces in.

use super::*;

/// The run the issue names, said plainly. Every line of it, in order,
/// with nothing repeated and nothing framed.
#[test]
#[allow(clippy::unwrap_used)]
fn the_blocked_refresh_prints_the_lines_scripts_parse() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = blocked_project(home);
    let printed = said(&kendex(
        home,
        &project,
        "plain",
        &["refresh", "-y", "--scope", "project"],
    ));
    let scope = project.display().to_string();

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
            "safety: skill growth-guards for Claude Code scores 75/100",
            "  [finding]",
            "safety: skill growth-guards for Codex scores 75/100",
            "  [finding]",
            "safety: skill tidy for Claude Code scores 75/100",
            "  [finding]",
            "safety: skill tidy for Codex scores 75/100",
            "  [finding]",
            "conflict: skill growth-guards for Claude Code, Codex: <project>/.claude/skills/growth-guards already holds files kendex did not write",
            "  also at <project>/.agents/skills/growth-guards",
            "  differs from the catalog in 2 files: SKILL.md, references/rules.md (it carries a source: vstack stamp)",
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
    let home = tmp.path();
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
    let home = tmp.path();
    let project = blocked_project(home);
    let printed = said(&kendex(
        home,
        &project,
        "plain",
        &["refresh", "-y", "--scope", "project"],
    ));
    for once in [
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
    let home = tmp.path();
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
    let home = tmp.path();
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
