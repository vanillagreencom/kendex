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

/// A folder that is not a skill. Kept, it goes to the trash and the
/// declaration is rewritten around a local source that has nothing to
/// give, so the apply that follows installs nothing — the reader is told
/// their files were kept and they are gone.
#[test]
#[allow(clippy::unwrap_used)]
fn a_folder_that_is_not_a_skill_is_not_offered_the_keep() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\"]", "copy");
    let here = project.join(".claude/skills/deploy");
    fs::create_dir_all(&here).unwrap();
    fs::write(here.join("notes.md"), "somebody else's folder").unwrap();

    let planned = plan(home, &project);
    assert!(planned.contains("conflict: skill deploy"), "{planned}");
    assert_eq!(offer(&planned), "move them somewhere else first");
}

/// The scope-wide flag reaches every blocked item and refuses the whole run
/// over one it could only half take over. Printed on the strength of a
/// single replaceable item, it is a command guaranteed to fail.
#[test]
#[allow(clippy::unwrap_used)]
fn the_scope_wide_exit_is_not_printed_beside_an_item_it_would_refuse() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\", \"codex\"]", "copy");
    // One item wholly replaceable.
    folder_at(&project.join(".claude/skills/deploy"), "By hand.");
    folder_at(&project.join(".agents/skills/deploy"), "By hand.");
    // A second item with one replaceable copy and one shared folder, which
    // is never written over.
    let elsewhere = home.join("shared/lint");
    folder_at(&elsewhere, "Shared by hand.");
    fs::write(
        project.join("kendex.toml"),
        fs::read_to_string(project.join("kendex.toml"))
            .unwrap()
            .replace(
                "[skills.deploy]\nsource = \"cat\"\n",
                "[skills.deploy]\nsource = \"cat\"\n\n[skills.lint]\nsource = \"cat\"\n",
            ),
    )
    .unwrap();
    fs::create_dir_all(home.join("catalog/skills/lint")).unwrap();
    fs::write(
        home.join("catalog/skills/lint/SKILL.md"),
        "---\nname: lint\ndescription: lints it\n---\nUpstream.\n",
    )
    .unwrap();
    folder_at(&project.join(".claude/skills/lint"), "By hand.");
    link_at(&project.join(".agents/skills/lint"), &elsewhere);

    let planned = plan(home, &project);
    assert!(planned.contains("conflict: skill lint"), "{planned}");
    assert!(
        !planned.contains("--replace-unmanaged"),
        "a command that would refuse the whole run was printed: {planned}"
    );
}

/// A hard conflict beside files in the way. Both exits act on the whole
/// item and the engine refuses one it could only half settle, so the row
/// carries neither — a link kendex will not touch takes the offer with it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hard_conflict_beside_the_files_takes_both_exits_with_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\", \"codex\"]", "copy");
    folder_at(&project.join(".claude/skills/deploy"), "By hand.");
    // Codex's place is a link into somewhere that is not a skill at all,
    // which adoption refuses and replacement never writes over.
    let elsewhere = home.join("notes");
    fs::create_dir_all(&elsewhere).unwrap();
    fs::write(elsewhere.join("read-me.txt"), "not a skill").unwrap();
    link_at(&project.join(".agents/skills/deploy"), &elsewhere);

    let planned = plan(home, &project);
    assert!(planned.contains("conflict: skill deploy"), "{planned}");
    assert_eq!(offer(&planned), "move them somewhere else first");
    assert!(
        !planned.contains("--replace-unmanaged"),
        "half the item was offered a take-over: {planned}"
    );
}

/// A place adoption cannot enter, beside one it can. Keeping is one move
/// for the whole item, so an offer naming only the tool that works would
/// settle its copy and leave the other blocked with the item no longer
/// its tool's.
#[test]
#[allow(clippy::unwrap_used)]
fn a_place_adoption_cannot_enter_takes_the_offer_with_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\", \"codex\"]", "copy");
    folder_at(&project.join(".claude/skills/deploy"), "By hand.");
    // Codex's copy is a folder that is not a skill: adoption has nothing
    // to take there, and the local source would not find it again.
    let here = project.join(".agents/skills/deploy");
    fs::create_dir_all(&here).unwrap();
    fs::write(here.join("notes.md"), "somebody else's folder").unwrap();

    let planned = plan(home, &project);
    assert_eq!(
        offer(&planned),
        "move them somewhere else first",
        "half the item was offered a keep: {planned}"
    );
}
