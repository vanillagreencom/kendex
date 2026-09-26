//! The design system's renderings, held at the binary: `NO_COLOR` and
//! `TERM=dumb` on a terminal print what a pipe gets, and a terminal of a
//! given width gets no line past it. `check` is the verb they are held on,
//! the first one built only from the components.

use super::*;

/// The blocked fixture, which every run of one test reads: `check` is
/// read-only there, so each run sees the same tree at the same paths.
struct Fixture {
    home: PathBuf,
    project: PathBuf,
    _tmp: tempfile::TempDir,
}

#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = blocked_project(&home);
    Fixture {
        home,
        project,
        _tmp: tmp,
    }
}

/// `kendex check --scope project` over the fixture, with `extra` set on
/// top of the suite's environment: stdout and stderr.
#[allow(clippy::expect_used)]
fn check(at: &Fixture, ui: &str, extra: &[(&str, &str)]) -> (String, String) {
    let mut run = Command::new(env!("CARGO_BIN_EXE_kendex"));
    run.args(["check", "--scope", "project"])
        .current_dir(&at.project)
        .env_clear()
        .envs(test_util::fixture_env(&at.home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("KENDEX_UI", ui)
        .env("LANG", "C.UTF-8")
        .env("PATH", std::env::var("PATH").unwrap_or_default());
    for (name, value) in extra {
        run.env(name, value);
    }
    let output = run.output().expect("kendex binary runs");
    (
        String::from_utf8_lossy(&output.stdout).into_owned(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
    )
}

/// A run with a terminal attached and `NO_COLOR` set, or `TERM=dumb`,
/// prints byte for byte what a pipe gets. The rich run beside them has to
/// differ, or the comparison would pass on a verb that never drew rich.
#[test]
fn no_color_and_a_dumb_terminal_print_what_a_pipe_gets() {
    let at = fixture();
    let piped = check(&at, "plain", &[]);
    assert!(
        !piped.0.is_empty(),
        "the fixture has nothing to report: {piped:?}"
    );
    for (case, extra) in [
        ("NO_COLOR", [("NO_COLOR", "1")]),
        ("TERM=dumb", [("TERM", "dumb")]),
    ] {
        assert_eq!(check(&at, "pretty", &extra), piped, "{case}");
    }
    let rich = check(&at, "pretty", &[]);
    assert!(
        rich.0.contains('\u{1b}') && rich != piped,
        "the rich run drew no colour: {rich:?}"
    );
}

/// An 80-column terminal gets no line wider than 80 cells, escapes not
/// counted, while the same report in a pipe has lines wider than that —
/// so the width was reached and wrapped, not merely never met.
#[test]
fn an_80_column_terminal_gets_no_line_past_80() {
    let at = fixture();
    let widest = |text: &str| text.lines().map(cells).max().unwrap_or(0);
    let (piped, _) = check(&at, "plain", &[]);
    let (report, verdict) = check(&at, "pretty", &[("COLUMNS", "80")]);
    assert!(
        widest(&piped) > 80,
        "no plain line reaches 80, so nothing had to wrap: {piped}"
    );
    for text in [&report, &verdict] {
        assert!(widest(text) <= 80, "a line passed 80 cells:\n{text}");
    }
}

/// Terminal cells in a drawn line: escape sequences take none, and every
/// other character here takes one.
fn cells(line: &str) -> usize {
    let mut count = 0;
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        match c {
            '\u{1b}' => {
                for end in chars.by_ref() {
                    if end == 'm' {
                        break;
                    }
                }
            }
            _ => count += 1,
        }
    }
    count
}
