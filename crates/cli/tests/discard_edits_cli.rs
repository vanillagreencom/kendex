//! The discard exit the drift report prints. It is named for one package
//! because it takes one package: `refresh --discard-edits` is the whole
//! scope, so printing that as the fix for one line would spend every other
//! hand-edited package's work on resolving this one.
#![cfg(unix)]

mod common;

use std::fs;

use common::{declare_pending_work, kendex, project_with_two_skills};

#[test]
#[allow(clippy::unwrap_used)]
fn discarding_one_packages_edits_leaves_the_other_packages_edits_alone() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with_two_skills(home);

    let output = kendex(home, &project, &["apply", "-y"]);
    assert!(
        output.status.success(),
        "apply: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let gh = project.join(".claude/skills/gh/SKILL.md");
    let lint = project.join(".claude/skills/lint/SKILL.md");
    assert!(gh.is_file() && lint.is_file(), "both skills installed");

    fs::write(&gh, "my gh edit").unwrap();
    fs::write(&lint, "my lint edit").unwrap();

    // The command the drift report prints for one edited package.
    let output = kendex(home, &project, &["discard-edits", "skill", "gh"]);
    assert!(
        output.status.success(),
        "discard-edits: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    assert!(
        fs::read_to_string(&gh).unwrap().contains("Upstream gh."),
        "the named package came back"
    );
    assert_eq!(
        fs::read_to_string(&lint).unwrap(),
        "my lint edit",
        "following the printed fix took another package's edits"
    );
}

/// The control on the scope-wide spelling: it is still there, it still
/// takes everything, and that is why it is not what the report prints.
#[test]
#[allow(clippy::unwrap_used)]
fn refresh_with_discard_edits_is_the_whole_scope() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with_two_skills(home);

    assert!(kendex(home, &project, &["apply", "-y"]).status.success());
    let gh = project.join(".claude/skills/gh/SKILL.md");
    let lint = project.join(".claude/skills/lint/SKILL.md");
    fs::write(&gh, "my gh edit").unwrap();
    fs::write(&lint, "my lint edit").unwrap();

    let output = kendex(home, &project, &["refresh", "-y", "--discard-edits"]);
    assert!(
        output.status.success(),
        "refresh: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    assert!(fs::read_to_string(&gh).unwrap().contains("Upstream gh."));
    assert!(
        fs::read_to_string(&lint)
            .unwrap()
            .contains("Upstream lint."),
        "the scope-wide flag takes every edit — the reason it is not a fix line"
    );
}

// The command names one package, so it acts on one package or on nothing.
// A scope always has other work waiting sooner or later, and a plan built
// to carry this package's permission carries that work too — executing it
// under a line saying this package was restored spends the one on the
// other.
#[test]
#[allow(clippy::unwrap_used)]
fn a_clean_target_applies_nothing_even_with_work_waiting() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with_two_skills(home);
    assert!(kendex(home, &project, &["apply", "-y"]).status.success());

    let lint = project.join(".claude/skills/lint/SKILL.md");
    fs::write(&lint, "my lint edit").unwrap();
    declare_pending_work(&project);
    let notes = project.join(".claude/skills/notes/SKILL.md");
    assert!(!notes.exists(), "the waiting work has not run yet");

    // gh is clean: there is nothing here to discard.
    let output = kendex(home, &project, &["discard-edits", "skill", "gh"]);
    let said = String::from_utf8_lossy(&output.stderr).into_owned()
        + &String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "{said}");
    assert!(said.contains("no edits to discard"), "{said}");
    assert!(
        !notes.exists(),
        "a clean target ran the scope's waiting work: {said}"
    );
    assert_eq!(
        fs::read_to_string(&lint).unwrap(),
        "my lint edit",
        "and took another package's edits with it"
    );
}

/// Declared but never installed reads the same way: there is no edit here,
/// so there is nothing to put back.
#[test]
#[allow(clippy::unwrap_used)]
fn a_target_with_no_installation_applies_nothing() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with_two_skills(home);
    assert!(kendex(home, &project, &["apply", "-y"]).status.success());
    fs::write(project.join(".claude/skills/lint/SKILL.md"), "my lint edit").unwrap();
    declare_pending_work(&project);

    let notes = project.join(".claude/skills/notes/SKILL.md");
    let output = kendex(home, &project, &["discard-edits", "skill", "notes"]);
    let said = String::from_utf8_lossy(&output.stderr).into_owned()
        + &String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "{said}");
    assert!(said.contains("no edits to discard"), "{said}");
    assert!(!notes.exists(), "nothing was installed under it: {said}");
}
