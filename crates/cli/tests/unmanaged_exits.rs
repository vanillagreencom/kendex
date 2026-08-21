//! Which way out the CLI prints, for the states where only one of the two
//! works. A folder several tools read through links they made themselves
//! can be kept and must never be written over; a file sitting where a
//! folder goes is the reverse. Printing the wrong one is worse than
//! printing none: the reader follows it and the command errors.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .output()
        .expect("kendex binary runs")
}

fn said(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

/// A project asking two tools for one skill, with a folder already at one
/// tool's place and the other tool's place a link at it.
#[allow(clippy::unwrap_used)]
fn shared_by_hand(home: &Path) -> PathBuf {
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nUpstream.\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"symlink\"\n\n[skills.deploy]\nsource = \"cat\"\n",
            catalog.display()
        ),
    )
    .unwrap();
    let folder = project.join(".claude/skills/deploy");
    fs::create_dir_all(&folder).unwrap();
    fs::write(
        folder.join("SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nShared by hand.\n",
    )
    .unwrap();
    let link = project.join(".agents/skills/deploy");
    fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&folder, &link).unwrap();
    project
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_folder_shared_by_hand_is_offered_the_way_out_that_keeps_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    fs::create_dir_all(home.join("dev/app/.claude")).unwrap();
    let project = shared_by_hand(home);

    let planned = said(&kendex(home, &project, &["apply", "--plan"]));
    assert!(
        planned.contains("to keep those files: adopt skill deploy --harness"),
        "the state with a way out was printed without it: {planned}"
    );
    assert!(
        planned.contains(".claude/skills/deploy"),
        "the folder the link points at is what the reader has to decide about: {planned}"
    );
    // Replacing a link is never right: the bytes are not at this position,
    // and writing over it breaks the sharing somebody set up.
    assert!(
        !planned.contains("--replace-unmanaged"),
        "an exit that cannot work here was offered: {planned}"
    );
    assert!(
        project.join(".claude/skills/deploy/SKILL.md").is_file(),
        "planning changed the folder"
    );
}

/// A file where a folder goes is files kendex did not write, and the
/// replacement handles it — but adoption reads a skill's position as a
/// folder, so the keep line must not be printed here.
#[test]
#[allow(clippy::unwrap_used)]
fn a_file_where_a_folder_goes_is_not_offered_the_adopt() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    fs::create_dir_all(home.join("dev/app/.claude/skills")).unwrap();
    let project = shared_by_hand(home);
    fs::remove_dir_all(project.join(".claude/skills/deploy")).unwrap();
    fs::remove_file(project.join(".agents/skills/deploy")).unwrap();
    fs::write(
        project.join(".claude/skills/deploy"),
        "laid out by the tool that came before",
    )
    .unwrap();

    let planned = said(&kendex(home, &project, &["apply", "--plan"]));
    assert!(planned.contains("conflict: skill deploy"), "{planned}");
    assert!(
        !planned.contains("adopt skill deploy"),
        "a way out that errors on the spot was printed: {planned}"
    );
    assert!(
        planned.contains("to keep those files: move them somewhere else first"),
        "and the way out that does work was not said: {planned}"
    );
    assert!(
        planned.contains("--replace-unmanaged"),
        "the exit that handles this shape was not offered: {planned}"
    );
}
