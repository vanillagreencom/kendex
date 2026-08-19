//! The commands the report prints, as commands: pasteable as written, scoped
//! to what they repair, and never naming something that does not exist.
//!
//! Every one of them is offered to a reader to paste, so what is under test is
//! the shell word and the flag beside it rather than the prose around them.

use super::*;

/// A local source is a PATH, not a URL: `?` and `#` are a query and a
/// fragment in one and ordinary characters in a directory name in the other.
/// The URL redaction was applied to every source, so a local path rendered as
/// `/sources/x?<redacted>` and both remedy commands built from it named a
/// directory that does not exist.
#[test]
fn a_local_source_path_survives_into_the_report_and_its_remedy_commands() {
    let dir = tmpdir("local?src#1");
    let source = dir.to_string_lossy().into_owned();
    let mut report = ScopeReport {
        scope: "project",
        installed: 1,
        ..Default::default()
    };
    report.source_issues.push(SourceIssue {
        source: scrub_source_credentials(&source),
        problem: SourceProblem::Unresolvable {
            entries: vec!["alpha".into()],
            reason: "source not found".into(),
            restore: Some(source.clone()),
        },
    });
    report.available.push(AvailableItem {
        name: "beta".into(),
        kind: ItemKind::Skill,
        source: scrub_source_credentials(&source),
        add_argument: Some(source.clone()),
    });

    let mut out = String::new();
    render_scope(&mut out, &report, false);
    assert!(
        !out.contains("<redacted>"),
        "a local path carries no credential to redact: {out}"
    );
    assert!(
        out.contains(&source),
        "the prose must name the real directory: {out}"
    );
    let arg = command_arg(&source);
    assert!(
        out.contains(&format!("`vstack add {arg}`")),
        "the unreachable-source remedy must name it too: {out}"
    );
    assert!(
        out.contains(&format!("`vstack add {arg} --skill <name>`")),
        "and so must the available-item remedy: {out}"
    );

    // The proof is the directory, not the string: the pasted argument has to
    // resolve to the one that is actually there.
    let probe = std::process::Command::new("sh")
        .arg("-c")
        .arg(format!("test -d {arg} && printf ok"))
        .output()
        .expect("sh runs");
    assert_eq!(
        String::from_utf8_lossy(&probe.stdout),
        "ok",
        "the pasted command must name the directory that exists, got {arg}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// A remedy command has to WORK when pasted: an ssh source keeps its
/// `git@` (the round-4 scrub dropped it and the suggested command died on
/// publickey), and a long local path is never truncated inside backticks.
#[test]
fn remedy_commands_are_pasteable_for_ssh_and_long_sources() {
    let ssh = "ssh://git@example.com/owner/repo";
    let mut report = ScopeReport {
        scope: "project",
        installed: 1,
        ..Default::default()
    };
    report.source_issues.push(SourceIssue {
        source: scrub_source_credentials(ssh),
        problem: SourceProblem::Unresolvable {
            entries: vec!["alpha".into()],
            reason: "source not found".into(),
            restore: Some(ssh.to_string()),
        },
    });
    let mut out = String::new();
    render_scope(&mut out, &report, true);
    assert!(
        out.contains("`vstack add ssh://git@example.com/owner/repo`"),
        "the command must keep the working ssh user: {out}"
    );

    let long = format!("/sources/{}", "x".repeat(200));
    let mut report = ScopeReport {
        scope: "project",
        installed: 1,
        ..Default::default()
    };
    report.source_issues.push(SourceIssue {
        source: long.clone(),
        problem: SourceProblem::Unresolvable {
            entries: vec!["alpha".into()],
            reason: "source not found".into(),
            restore: Some(long.clone()),
        },
    });
    let mut out = String::new();
    render_scope(&mut out, &report, true);
    assert!(
        out.contains(&format!("`vstack add {long}`")),
        "the command must carry the whole argument: {out}"
    );
}

/// `add` and `remove` default to PROJECT scope, so a global section's
/// remediation commands must carry `-g` or they act on the wrong install —
/// silently, when a project item shares the name. Asserted per command by
/// scanning the rendered report, so a command added to `render_scope` later
/// cannot silently miss the flag.
#[test]
fn every_global_remediation_command_carries_the_scope_flag() {
    for quiet in [false, true] {
        let mut global = String::new();
        render_scope(&mut global, &populated_scope("global"), quiet);
        let commands = rendered_commands(&global);
        let scoped: Vec<&(String, String)> = commands
            .iter()
            .filter(|(sub, _)| sub == "add" || sub == "remove")
            .collect();
        assert!(
            scoped.len() >= 10,
            "the fixture must reach every remediation command, saw {scoped:?} in:\n{global}"
        );
        for (sub, next) in &scoped {
            assert_eq!(
                next, "-g",
                "`vstack {sub}` ran unscoped in a global report:\n{global}"
            );
        }
        // `refresh` is correct unflagged: it reinstalls at every scope an
        // item is locked at.
        assert!(
            commands
                .iter()
                .any(|(sub, next)| sub == "refresh" && next != "-g"),
            "the outdated remedy must stay scope-less:\n{global}"
        );

        // Control: the project rendering carries no flag, and transforming
        // it into the global one takes nothing but the flag and the header,
        // so scope is the ONLY difference between the two.
        let mut project = String::new();
        render_scope(&mut project, &populated_scope("project"), quiet);
        assert!(
            !project.contains(" -g"),
            "the project report must stay unflagged:\n{project}"
        );
        assert_eq!(
            global,
            project
                .replace("vstack add", "vstack add -g")
                .replace("vstack remove", "vstack remove -g")
                .replace("project scope", "global scope"),
            "scope must change nothing but the flag and the header"
        );
    }
}
