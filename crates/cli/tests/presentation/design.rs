//! The design system's renderings, held at the binary: `NO_COLOR` and
//! `TERM=dumb` on a run forced rich with `KENDEX_UI=pretty` print what a
//! pipe gets, and a rich run of a given width gets no line past it. `check` is the verb they are held on,
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

/// A run forced rich with `KENDEX_UI=pretty` and `NO_COLOR` set, or
/// `TERM=dumb`, prints byte for byte what a pipe gets. The rich run beside them has to
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

/// A rich run at `COLUMNS=80` gets no line wider than 80 cells, escapes
/// not counted, while the same report in a pipe has lines wider than that —
/// so the width was reached and wrapped, not merely never met. A remedy's
/// command is drawn whole, since a command split at a space reads as a
/// shorter one, so its line is the one a narrow terminal wraps itself.
#[test]
fn an_80_column_terminal_gets_no_line_past_80() {
    let at = fixture();
    let (piped, _) = check(&at, "plain", &[]);
    let (report, verdict) = check(&at, "pretty", &[("COLUMNS", "80")]);
    assert!(
        piped.lines().any(|line| cells(line) > 80),
        "no plain line reaches 80, so nothing had to wrap: {piped}"
    );
    for text in [&report, &verdict] {
        for line in text.lines().filter(|line| !is_command(line)) {
            assert!(cells(line) <= 80, "{} cells: {line:?}\n{text}", cells(line));
        }
    }
}

/// A row's command line: `fix:` or `see:` once its indent and colour are
/// taken off.
fn is_command(line: &str) -> bool {
    let mut parts = line.split('\u{1b}');
    let mut text = parts.next().unwrap_or_default().to_owned();
    for part in parts {
        text.push_str(part.split_once('m').map_or(part, |(_, rest)| rest));
    }
    let text = text.trim_start();
    text.starts_with("fix: ") || text.starts_with("see: ")
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
