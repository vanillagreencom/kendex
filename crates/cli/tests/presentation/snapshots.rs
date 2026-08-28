//! The plain lines, verb by verb. Held here rather than only on refresh
//! because a difference nobody pinned is a difference nobody notices: the
//! contract is that a script reading these keeps reading them, and it is
//! only a contract where every verb the change touched is under it.

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
    let scope = project.display().to_string();
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
/// score per installation, one conflict however many tools it blocks.
fn planned_block() -> Vec<&'static str> {
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
/// The escaping is per fragment, at the site that knows which half of its
/// sentence is foreign — never over the composed line, where a newline
/// somebody else wrote is indistinguishable from a break the caller meant
/// and a filename can forge output lines of its own.
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
    }
}

/// The place a run names is escaped too. A scope label is a path somebody
/// chose, and a path carries whatever the filesystem allowed, so the
/// closing line cannot hand a terminal an escape sequence to act on.
#[test]
#[allow(clippy::unwrap_used)]
fn the_scope_a_line_names_is_escaped_with_the_rest() {
    for ui in ["plain", "pretty"] {
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
            "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n{declared}",
            catalog.display()
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
        let drift = home.join(".local/share/kendex/drift");
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
