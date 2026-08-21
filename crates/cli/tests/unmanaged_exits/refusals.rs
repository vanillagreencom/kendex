//! The blocked shapes with no way to keep the files, and the exits that
//! have to name the scope they were read in. Every offer here is checked
//! against what a reader could actually run.

use std::fs;

use super::{folder_at, kendex, link_at, offer, plan, project_with, said};

/// folder, so the keep line must not be printed here.
#[test]
#[allow(clippy::unwrap_used)]
fn a_file_where_a_folder_goes_is_not_offered_the_adopt() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\", \"codex\"]", "symlink");
    fs::create_dir_all(project.join(".claude/skills")).unwrap();
    fs::write(
        project.join(".claude/skills/deploy"),
        "laid out by the tool that came before",
    )
    .unwrap();

    let planned = plan(home, &project);
    assert!(planned.contains("conflict: skill deploy"), "{planned}");
    assert_eq!(offer(&planned), "move them somewhere else first");
    assert!(
        planned.contains("--replace-unmanaged"),
        "the exit that handles this shape was not offered: {planned}"
    );
}

/// command that would error on the spot.
#[test]
#[allow(clippy::unwrap_used)]
fn a_link_no_declared_tool_sits_at_offers_no_command() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\"]", "symlink");
    let elsewhere = home.join("shared/deploy");
    folder_at(&elsewhere, "Kept somewhere else.");
    link_at(&project.join(".agents/skills/deploy"), &elsewhere);

    let planned = plan(home, &project);
    assert!(planned.contains("conflict: skill deploy"), "{planned}");
    assert_eq!(offer(&planned), "move them somewhere else first");
    assert!(
        fs::read_to_string(elsewhere.join("SKILL.md"))
            .unwrap()
            .contains("Kept somewhere else."),
        "planning touched the folder"
    );
}

/// the row says so.
#[test]
#[allow(clippy::unwrap_used)]
fn a_shape_that_cannot_be_kept_takes_the_whole_item_s_offer_with_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\", \"codex\"]", "copy");
    folder_at(&project.join(".claude/skills/deploy"), "By hand.");
    // A plain file where Codex reads a folder: nothing to take into the
    // local source.
    let wrong = project.join(".agents/skills/deploy");
    fs::create_dir_all(wrong.parent().unwrap()).unwrap();
    fs::write(&wrong, "not a folder").unwrap();

    let planned = plan(home, &project);
    assert_eq!(
        offer(&planned),
        "move them somewhere else first",
        "an offer that settles half the item was printed: {planned}"
    );
}

/// both run against whatever project the terminal happens to be in.
#[test]
#[allow(clippy::unwrap_used)]
fn an_exit_read_in_the_global_scope_says_so() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nUpstream.\n",
    )
    .unwrap();
    let global = home.join(".config/kendex");
    fs::create_dir_all(&global).unwrap();
    fs::write(
        global.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\n",
            catalog.display()
        ),
    )
    .unwrap();
    folder_at(&home.join(".claude/skills/deploy"), "By hand.");

    let planned = said(&kendex(home, home, &["apply", "--plan", "--global"]));
    assert_eq!(
        offer(&planned),
        "kendex adopt skill deploy --harness claude --global"
    );
    assert!(
        planned.contains("kendex apply --replace-unmanaged --global"),
        "the replacement runs against the current project without it: {planned}"
    );
}
