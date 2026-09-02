//! The plain lines, verb by verb. Held here rather than only on refresh
//! because a difference nobody pinned is a difference nobody notices: the
//! contract is that a script reading these keeps reading them, and it is
//! only a contract where every verb the change touched is under it.

use crate::test_util::source_path;

use std::fs;
use std::path::{Path, PathBuf};

use super::*;

/// One run's plain lines, with what differs between machines taken out:
/// the fixture's paths, and the wording of a safety finding, which the
/// rules own and this suite does not.
#[allow(clippy::unwrap_used)]
fn shape(setup: &[&str], args: &[&str]) -> Vec<String> {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let project = blocked_project(home);
    let catalog = home.join("catalog").display().to_string();
    let fill = |args: &[&str]| -> Vec<String> {
        args.iter()
            .map(|arg| arg.replace("{catalog}", &catalog))
            .collect()
    };
    if !setup.is_empty() {
        let ready = fill(setup);
        let borrowed: Vec<&str> = ready.iter().map(String::as_str).collect();
        kendex(home, &project, "plain", &borrowed);
    }
    let ready = fill(args);
    let borrowed: Vec<&str> = ready.iter().map(String::as_str).collect();
    let printed = said(&kendex(home, &project, "plain", &borrowed));
    let scope = kendex_core::paths::slashed(&project);
    printed
        .lines()
        .map(|line| match line.split_whitespace().next() {
            Some("[critical]" | "[high]" | "[medium]" | "[low]") => "  [finding]".to_owned(),
            _ => line
                .replace(&scope, "<project>")
                .replace(&catalog, "<catalog>"),
        })
        .collect()
}

/// The block every verb that plans prints before its own lines: one
/// score per item and matching result, each naming every position it
/// covers, and one conflict however many tools it blocks.
fn planned_block() -> Vec<&'static str> {
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
    ]
}

fn expect(got: Vec<String>, want: Vec<&str>) {
    assert_eq!(got, want, "the plain lines changed");
}

/// A preview says what it found and what it would do, and names no
/// command as the way out: every conflict line above it carries its own.
#[test]
fn apply_plan() {
    let mut want = planned_block();
    want.extend([
        "plan: 3 changes",
        "  - Write skill tidy's files for Claude Code",
        "  - Write skill tidy's files for Codex",
        "  - Update the install record",
        "<project>: planned 3 changes · skipped 1 item on conflict · flagged 2 items on safety",
    ]);
    expect(shape(&[], &["apply", "--plan", "--scope", "project"]), want);
}

/// add closes on the verb that was typed: the count is of changes, and a
/// run whose only change is the declaration added something rather than
/// installing anything.
#[test]
fn add() {
    let mut want = planned_block();
    want.extend([
        "plan: 4 changes",
        "  - Save kendex.toml",
        "  - Write skill tidy's files for Claude Code",
        "  - Write skill tidy's files for Codex",
        "  - Update the install record",
        "<project>: added 4 changes · skipped 1 item on conflict · flagged 2 items on safety",
        "  skipped — kendex apply --replace-unmanaged, or the kendex adopt line under each conflict above",
        "  flagged — the safety lines above",
    ]);
    expect(
        shape(&[], &["add", "{catalog}", "--skill", "tidy", "-y"]),
        want,
    );
}

/// The verdict closes the run, and the footnote about content nothing
/// manages stands above it rather than after it.
#[test]
fn verify() {
    expect(
        shape(
            &["refresh", "-y", "--scope", "project"],
            &["verify", "--scope", "project"],
        ),
        vec![
            "✓ skill tidy [claude]",
            "✓ skill tidy [codex]",
            "2 checked, 2 OK, 0 failed",
        ],
    );
    expect(
        shape(&[], &["verify", "--scope", "project"]),
        vec!["nothing installed"],
    );
}

/// check's verdict counts the lines the reader was shown and points at
/// them only where every one of them says what to run.
#[test]
fn check() {
    expect(
        shape(&[], &["check", "--scope", "project"]),
        vec!["2 items need attention — each line above says what to run"],
    );
}

/// A removal names what it did before it says how much of it there was.
#[test]
fn remove() {
    expect(
        shape(
            &["refresh", "-y", "--scope", "project"],
            &["remove", "tidy", "--no-sweep", "--scope", "project"],
        ),
        vec![
            "removing skill tidy for Claude Code — no longer declared here",
            "removing skill tidy for Codex — no longer declared here",
            "changes:",
            "  - Save kendex.toml",
            "  - Move skill tidy's files to the trash",
            "  - Move skill tidy's files to the trash",
            "  - Update the install record",
            "<project>: removed 4 changes",
        ],
    );
}

/// A name off a tree kendex did not write reaches the terminal as its own
/// characters, never as the escape or the line break it would act on.
///
/// The one test the escaping has, because there is one place it happens:
/// every verb's lines leave through `ui`, which escapes the composed
/// sentence there. A per-command copy of this would prove the seam over
/// again and say nothing about the command.
#[test]
#[allow(clippy::unwrap_used)]
fn a_name_off_a_foreign_tree_cannot_forge_a_line() {
    for ui in ["plain", "pretty"] {
        let tmp = tempfile::tempdir().unwrap();
        let home = &rooted(&tmp);
        let project = home.join("dev/app");
        blocked_project_at(home, &project);
        // Content nothing manages, named with the two characters that
        // would act on a terminal: a break, and an escape sequence.
        let stray = project.join(".claude/skills/we\nir\u{1b}[31md");
        fs::create_dir_all(&stray).unwrap();
        fs::write(
            stray.join("SKILL.md"),
            "---\nname: weird\ndescription: nobody declared this\n---\nbody\n",
        )
        .unwrap();

        let printed = said(&kendex(
            home,
            &project,
            ui,
            &["apply", "--plan", "--scope", "project"],
        ));
        assert!(
            printed.contains("we\\nir\\u{1b}[31md"),
            "the name was not printed as what it is ({ui}): {printed}"
        );
        assert!(
            !printed.contains('\u{1b}'),
            "a control character reached the terminal ({ui}): {printed:?}"
        );
        // The line it appears on is one line. Escaped after the message
        // was composed, the break inside the name split this in two.
        let carrying: Vec<&str> = printed
            .lines()
            .filter(|line| line.contains("we\\nir"))
            .collect();
        assert_eq!(
            carrying.len(),
            1,
            "the name was spread over {} lines ({ui}): {printed}",
            carrying.len()
        );
        assert!(
            carrying[0].contains("[Claude Code]"),
            "the name forged a line of its own ({ui}): {printed}"
        );

        // The closing line goes out through the same seam by a different
        // door: a ledger writes its own head and steps rather than saying
        // them. The place a run names is a path somebody chose, so it
        // carries whatever the filesystem allowed.
        let tmp = tempfile::tempdir().unwrap();
        let home = &rooted(&tmp);
        let project = home.join("we\u{1b}[31mird");
        blocked_project_at(home, &project);
        let printed = said(&kendex(
            home,
            &project,
            ui,
            &["refresh", "-y", "--scope", "project"],
        ));
        assert!(
            printed.contains("we\\u{1b}[31mird"),
            "the place was not printed as what it is ({ui}): {printed}"
        );
        assert!(
            !printed.contains('\u{1b}'),
            "a control character reached the terminal ({ui}): {printed:?}"
        );
    }
}

/// A refusal that names one finding per line reaches the reader as lines.
///
/// The control for the two doors, driven end to end: the breaks belong to
/// the message — `CoreError::ManifestInvalid` names one finding per line —
/// and a value inside a finding is still a value, so a manifest key
/// carrying a break is one key on one line rather than a finding of its
/// own. Escaping the composed message instead would print every break as
/// a literal `\n` and wrap the whole refusal onto one line.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refusal_naming_one_finding_per_line_keeps_its_lines() {
    // Two ordinary stray keys and one that would forge a finding of its
    // own: a TOML key is a quoted string and may hold anything.
    let manifest = format!(
        "schema = {}\nstray-one = 1\nstray-two = 2\n\"we\\nir\\u001Bd\" = 3\n",
        kendex_core::manifest::MANIFEST_SCHEMA
    );
    for ui in ["plain", "pretty"] {
        let tmp = tempfile::tempdir().unwrap();
        let home = &rooted(&tmp);
        let project = home.join("dev/app");
        blocked_project_at(home, &project);
        fs::write(project.join("kendex.toml"), &manifest).unwrap();

        let printed = said(&kendex(
            home,
            &project,
            ui,
            &["apply", "--plan", "--scope", "project"],
        ));
        assert!(
            !printed.contains('\u{1b}'),
            "a control character reached the terminal ({ui}): {printed:?}"
        );
        assert!(
            squashed(&printed).contains("we\\nir\\u{1b}d:unknowntableorkey"),
            "the key was not printed as what it is ({ui}): {printed}"
        );
    }

    // The count is asked of the plain rendering, which is the one that
    // does not wrap: the framed one breaks a long fix line to fit a box,
    // and a line count there would be a count of the box's width.
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let project = home.join("dev/app");
    blocked_project_at(home, &project);
    fs::write(project.join("kendex.toml"), &manifest).unwrap();
    let printed = said(&kendex(
        home,
        &project,
        "plain",
        &["apply", "--plan", "--scope", "project"],
    ));
    let findings: Vec<&str> = printed
        .lines()
        .filter(|line| line.contains("unknown table or key"))
        .collect();
    assert_eq!(
        findings.len(),
        3,
        "the three findings did not reach the reader as three lines: {printed}"
    );
    assert!(
        !printed.contains("\\nstray-one"),
        "a break the message wrote printed as its own escape: {printed}"
    );
}

/// The line a run ends on is one line, unless the message wrote the break.
///
/// The other half of `a_refusal_naming_one_finding_per_line_keeps_its_lines`,
/// and the control for the door that one does not reach: an ordinary
/// refusal names values nobody escaped — a path is whatever the filesystem
/// allowed — so it is escaped whole and stays one line. Splitting it first
/// would let a directory name write a second line of the run's own account
/// of why it stopped.
#[test]
#[allow(clippy::unwrap_used)]
fn a_value_in_the_closing_refusal_cannot_forge_a_line() {
    // The two characters that act on a terminal, in a directory name: a
    // break, and an escape sequence.
    let named = "we\u{1b}[31mi\nrd";
    for ui in ["plain", "pretty"] {
        let tmp = tempfile::tempdir().unwrap();
        let home = &rooted(&tmp);
        let project = home.join(named);
        blocked_project_at(home, &project);
        // A manifest with no schema key: refused in one sentence naming the
        // path, which is the shape every ordinary refusal has.
        fs::write(project.join("kendex.toml"), "name = \"v1\"\n").unwrap();

        let printed = said(&kendex(
            home,
            &project,
            ui,
            &["apply", "--plan", "--scope", "project"],
        ));
        assert!(
            !printed.contains('\u{1b}'),
            "a control character reached the terminal ({ui}): {printed:?}"
        );
        assert!(
            squashed(&printed).contains("we\\u{1b}[31mi\\nrd"),
            "the place was not printed as what it is ({ui}): {printed}"
        );

        // The refusal is what it says, on the line it says it. The place
        // is the last thing the closing sentence names, so escaped after
        // the split its break would leave "rd" on a line of its own and
        // the line opening "Error: " holding half a path — which is why
        // the whole place has to be on that one line, not merely somewhere
        // in what was printed.
        //
        // Counted in plain, which is the rendering that does not wrap: the
        // framed one breaks a long path to fit a box.
        if ui == "plain" {
            let refusals: Vec<&str> = printed
                .lines()
                .filter(|line| line.starts_with("Error: "))
                .collect();
            assert_eq!(refusals.len(), 1, "the refusal was not one line: {printed}");
            assert!(
                refusals[0].contains("we\\u{1b}[31mi\\nrd"),
                "the refusal did not carry the whole place: {printed}"
            );
        }
    }
}

/// The verb that names a scope it could not check says it on one line.
///
/// The third door, and the one the two above do not reach: `verify` carries
/// on past a scope it could not read, so its refusal is a headline of its
/// own with the error inside it. The error still picks the door, and the
/// three below take all of it: a sentence, the parser's diagram, and one
/// finding per line. The headline is one line under every one of them,
/// whatever the place is called. Composed rather than routed, a directory
/// named `ap<break>0 checked, 0 OK, 0 failed` printed that count as a line
/// of kendex's own verdict.
#[test]
#[allow(clippy::unwrap_used)]
fn a_scope_that_could_not_be_checked_is_named_on_one_line() {
    // A place named with the two characters that act on a terminal, and
    // with the run's own closing line, which is what a forged line would
    // be for.
    let named = "ap\u{1b}[31mp\n0 checked, 0 OK, 0 failed";
    // `said`, then the whole run: the refusal is every line but the
    // closing verdict, so a count pins the door as well as the headline.
    for (manifest, findings, said_lines) in [
        // Refused whole: a sentence naming the place and nothing else, so
        // the break in the place is the only one anywhere near it.
        ("schema = 99\n", 0, 2),
        // Refused as the parser's diagram: the source line, the caret under
        // it, and what the parser wanted, each on a line of its own.
        ("schema = 6\nthis is not toml [[[\n", 0, 6),
        // Refused a finding at a time.
        ("schema = 6\nstray-one = 1\nstray-two = 2\n", 2, 4),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = &rooted(&tmp);
        let project = home.join(named);
        fs::create_dir_all(project.join(".claude")).unwrap();
        fs::write(project.join("kendex.toml"), manifest).unwrap();

        let printed = said(&kendex(
            home,
            &project,
            "plain",
            &["verify", "--scope", "project"],
        ));
        assert!(
            !printed.contains('\u{1b}'),
            "a control character reached the terminal: {printed}"
        );
        let headlines: Vec<&str> = printed
            .lines()
            .filter(|line| line.contains("not checked:"))
            .collect();
        assert_eq!(
            headlines.len(),
            1,
            "the scope was named on {} lines: {printed}",
            headlines.len()
        );
        assert!(
            headlines[0].contains("ap\\u{1b}[31mp\\n0 checked"),
            "the place was not printed as what it is: {printed}"
        );
        // Nothing the place is called may reach the reader as a line, and
        // the run's real verdict is the only line that reads as one.
        let forged: Vec<&str> = printed
            .lines()
            .filter(|line| line.trim_start().starts_with("0 checked, 0 OK, 0 failed"))
            .collect();
        assert!(
            forged.is_empty(),
            "a directory name forged a line: {printed}"
        );
        assert_eq!(
            printed.lines().filter(|line| !line.is_empty()).count(),
            said_lines,
            "the refusal was said on the wrong number of lines: {printed}"
        );
        assert!(
            printed.lines().any(|line| line == "nothing installed"),
            "the run did not close on its own verdict: {printed}"
        );
        // The door the error chose. A manifest refusal keeps its findings
        // on lines of their own; a parser failure is inside the headline.
        let named_findings = printed
            .lines()
            .filter(|line| line.contains("unknown table or key"))
            .count();
        assert_eq!(named_findings, findings, "wrong door: {printed}");
    }
}

/// The parser's caret stays under the character it points at.
///
/// A `toml::de::Error` is a diagram: the source line, then a caret line
/// under it, then what the parser wanted. The breaks are the diagram, so
/// this refusal is split before it is escaped like the manifest one —
/// escaped whole, the caret arrives as a literal `\n` in the middle of a
/// sentence and points at nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn the_parsers_caret_lands_under_the_line_it_points_at() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\nthis is not toml [[[\n",
    )
    .unwrap();

    let printed = said(&kendex(
        home,
        &project,
        "plain",
        &["apply", "--plan", "--scope", "project"],
    ));
    let printed: Vec<&str> = printed.lines().collect();
    // The column is the parser's own, read back off the line that names
    // it, so this compares the diagram against what it says rather than
    // against a number written down twice.
    let named = printed
        .iter()
        .find_map(|line| line.split("column ").nth(1))
        .and_then(|rest| rest.trim().parse::<usize>().ok())
        .unwrap_or_else(|| panic!("no column named: {printed:#?}"));
    let at = printed
        .iter()
        .position(|line| line.contains("this is not toml"))
        .unwrap_or_else(|| panic!("the source line was not shown: {printed:#?}"));
    let source = printed[at];
    let caret = printed
        .get(at + 1)
        .unwrap_or_else(|| panic!("no line under the source line: {printed:#?}"));
    // The gutter is however wide the line number made it, read off the
    // source line rather than assumed.
    let gutter = source.find("| ").unwrap() + 2;
    assert_eq!(
        caret.find('^'),
        Some(gutter + named - 1),
        "the caret is not under column {named}: {printed:#?}"
    );
}

/// And the same refusal cannot be made to forge a line.
///
/// Everything the parser prints is either its own words or a source line
/// under a `N | ` gutter, so a manifest can add a line to the diagram but
/// never a line of its own. The place is a value somebody chose, escaped
/// where the error composes it, so a directory named for the run's verdict
/// stays inside the sentence naming it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_manifest_cannot_write_a_line_of_the_diagram_itself() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let project = home.join("we\u{1b}[31mi\nrd");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n0 checked, 0 OK, 0 failed \u{1b}[31m [[[\n",
    )
    .unwrap();

    let printed = said(&kendex(
        home,
        &project,
        "plain",
        &["apply", "--plan", "--scope", "project"],
    ));
    assert!(
        !printed.contains('\u{1b}'),
        "a control character reached the terminal: {printed:?}"
    );
    assert!(
        printed.contains("we\\u{1b}[31mi\\nrd/kendex.toml: invalid TOML"),
        "the place was not named as what it is, on one line: {printed}"
    );
    for line in printed.lines() {
        assert!(
            !line.trim_start().starts_with("0 checked, 0 OK, 0 failed"),
            "the manifest wrote a line of its own: {printed}"
        );
    }
    // What it did get is a line of the diagram, under the parser's gutter.
    assert!(
        printed
            .lines()
            .any(|line| line.contains("| 0 checked, 0 OK, 0 failed \\u{1b}[31m")),
        "the source line was not shown as what it is: {printed}"
    );
}

/// The line a verb puts on the screen while it waits is escaped too.
///
/// Its own test, and the only one here that needs a real terminal: the
/// spinner draws through `indicatif`, which writes nothing at all down a
/// pipe, so every other test in this file is blind to it. What it carries
/// is the place the run is working on — a path somebody chose, and one that
/// carries whatever the filesystem allowed.
#[test]
#[allow(clippy::unwrap_used)]
fn the_line_shown_while_a_verb_waits_is_escaped() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let named = "we\u{1b}[31mi\nrd";
    let project = home.join(named);
    blocked_project_at(home, &project);

    let sent = kendex_on_a_terminal(home, &project, &["apply", "--plan", "--scope", "project"]);
    // The spinner drew, so what follows is about what it drew rather than
    // about a line nothing put on the screen. It draws on a tick a tenth of
    // a second in, and planning this fixture takes seconds in a test build;
    // a machine fast enough to beat it fails here rather than passing on an
    // empty run.
    assert!(
        sent.contains("planning "),
        "the spinner never reached the terminal: {sent:?}"
    );
    // The escape sequence alone, not the whole name: a terminal turns a
    // break in what it is sent into a carriage return and a newline, so the
    // name is not one run of bytes on this side however it was written.
    assert!(
        !sent.contains("we\u{1b}[31m"),
        "the place reached the terminal as its own escape sequence: {sent:?}"
    );
    // On the spinner's own line, not merely somewhere on the screen: the
    // escaped name reaches the terminal on the safety lines, the conflict
    // lines and the closing verdict too, and other tests cover those. What
    // follows the last "planning " is the label the spinner drew, so an
    // empty one fails here rather than riding on a line it did not write.
    let label = sent.rsplit("planning ").next().expect("a tail");
    let shown = format!("{}/we\\u{{1b}}[31mi\\nrd", home.display());
    assert!(
        label.starts_with(&shown),
        "the place was not shown as what it is: {sent:?}"
    );
}

/// The stdout half of the same seam. A verb's own lines go out through
/// `ui::out`, and the names on them come off a tree kendex did not write:
/// `project add` lists what is there and not managed, and that listing is
/// composed of directory names.
///
/// Its own test because nothing else covers `out`: the check report is
/// scrubbed by `drift::report::text` before it gets there, so a run of it
/// would stay green with the escape taken out of `out` altogether.
#[test]
#[allow(clippy::unwrap_used)]
fn a_name_reaching_stdout_is_printed_as_what_it_is() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let project = home.join("dev/app");
    blocked_project_at(home, &project);
    let stray = project.join(".claude/skills/ev\u{1b}[31mil");
    fs::create_dir_all(&stray).unwrap();
    fs::write(
        stray.join("SKILL.md"),
        "---\nname: evil\ndescription: paints the terminal\n---\nMine.\n",
    )
    .unwrap();

    let output = kendex(
        home,
        &project,
        "plain",
        &["project", "add", &project.display().to_string()],
    );
    let printed = String::from_utf8_lossy(&output.stdout).into_owned();
    assert!(
        printed.contains("not managed yet:"),
        "the offer was not printed: {printed}"
    );
    assert!(
        !printed.contains('\u{1b}'),
        "an escape sequence reached stdout: {printed:?}"
    );
    assert!(
        printed.contains("ev\\u{1b}[31mil"),
        "the name was not printed as what it is: {printed}"
    );
}

/// The verdict counts what the reader was shown. The report drops lines to
/// fit its own budgets, so a count taken from the report behind it would
/// name items that never reached the page.
#[test]
#[allow(clippy::unwrap_used)]
fn the_verdict_counts_the_lines_the_report_actually_printed() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let project = crowded_project(home, 14);
    let output = kendex(home, &project, "plain", &["check", "--scope", "project"]);
    let report = String::from_utf8_lossy(&output.stdout).into_owned();
    let verdict = said(&output);

    let shown = report
        .lines()
        .filter(|line| line.starts_with("  ") && !line.starts_with("  … and "))
        .count();
    assert!(
        report.contains("… and "),
        "the fixture has to overflow a section: {report}"
    );
    assert!(shown < 14, "nothing was dropped: {report}");
    assert!(
        verdict.starts_with(&format!("{shown} items need attention")),
        "the verdict counted {} rather than the {shown} lines above it: {verdict}",
        verdict.split(' ').next().unwrap_or_default()
    );
}

/// A project declaring more blocked installs than one section will print.
#[allow(clippy::unwrap_used)]
fn crowded_project(home: &Path, count: usize) -> PathBuf {
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    let mut declared = String::new();
    for n in 0..count {
        let name = format!("skill{n:02}");
        skill(&catalog, &name, "Upstream.\n");
        let at = project.join(format!(".claude/skills/{name}"));
        fs::create_dir_all(&at).unwrap();
        fs::write(at.join("SKILL.md"), "By hand.\n").unwrap();
        declared.push_str(&format!("\n[skills.{name}]\nsource = \"cat\"\n"));
    }
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n{declared}",
            source_path(&catalog)
        ),
    )
    .unwrap();
    project
}

/// A warning about the run belongs above the line that says the run
/// ended. The snapshot is derived after the write, and its failure is the
/// one warning that can arrive that late.
#[test]
#[allow(clippy::unwrap_used)]
fn a_late_warning_lands_above_the_closing_ledger() {
    for ui in ["plain", "pretty"] {
        let tmp = tempfile::tempdir().unwrap();
        let home = &rooted(&tmp);
        let project = blocked_project(home);
        kendex(
            home,
            &project,
            "plain",
            &["apply", "-y", "--scope", "project"],
        );
        // The snapshot's own directory, made unwritable so deriving it
        // fails after the plan has already been written.
        let drift = Env::host_rooted(home.clone()).drift_dir();
        assert!(drift.is_dir(), "the fixture never derived a snapshot");
        let mut mode = fs::metadata(&drift).unwrap().permissions();
        mode.set_readonly(true);
        fs::set_permissions(&drift, mode).unwrap();

        let printed = said(&kendex(
            home,
            &project,
            ui,
            &["apply", "-y", "--replace-unmanaged", "--scope", "project"],
        ));
        let mut perms = fs::metadata(&drift).unwrap().permissions();
        perms.set_readonly(false);
        fs::set_permissions(&drift, perms).unwrap();

        // A process that may write anywhere cannot be shown a write it
        // cannot do; this fixture needs an ordinary user.
        let warned = printed
            .lines()
            .position(|line| line.contains("snapshot not derived"));
        let closed = printed
            .lines()
            .position(|line| line.contains(": applied ") || line.contains(": up to date"));
        assert!(
            warned.is_some(),
            "the fixture could not make the snapshot fail — running as root? ({ui}): {printed}"
        );
        assert!(
            warned < closed,
            "the warning landed under the line saying the run ended ({ui}): {printed}"
        );
    }
}
