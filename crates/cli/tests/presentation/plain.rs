//! Anything but a terminal gets the lines a script already parses. What
//! this file pins is that the presentation layer adds nothing to them:
//! no frame, no symbol, no colour, and the same hierarchy the verbs
//! wrote — a headline at column 0 and its detail two spaces in.

use crate::test_util::source_path;

use super::*;

/// The blocked refresh keeps its headline and detail hierarchy without framing.
#[test]
#[allow(clippy::unwrap_used)]
fn the_blocked_refresh_keeps_the_plain_output_hierarchy() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let project = blocked_project(home);
    let printed = said(&kendex(
        home,
        &project,
        "plain",
        &["refresh", "-y", "--scope", "project"],
    ));
    let shape: Vec<usize> = printed
        .lines()
        .map(|line| line.len() - line.trim_start().len())
        .collect();
    assert_eq!(
        shape,
        [0, 2, 4, 4, 4, 2, 0, 2, 4, 2, 4, 0, 2, 2, 0, 2, 2, 2],
        "{printed}"
    );
    assert!(FRAMING.into_iter().all(|symbol| !printed.contains(symbol)));
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
/// error there returning straight to main would leave the disk changed, no
/// snapshot recorded for the next session-start check, and nothing said
/// about it.
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
            "schema = 7\n\n[sources.cat]\n{}\n\n[install]\nharnesses = \
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
