//! An item switched off parks its content under a suffixed name, and a
//! hand-made file sits there just as easily. The pair is one position: the
//! offer, the capture and the declaration all have to read it the same way.

use std::fs;

use super::{follow, offer, plan, project_with};

/// A hand-made file parked under the switched-off spelling. The plan reads
/// the pair as one position, so the offer has to as well — asking about
/// one spelling tells the reader to move files adoption would have taken.
#[test]
#[allow(clippy::unwrap_used)]
fn a_file_under_the_switched_off_name_is_still_offered_the_keep() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\"]", "copy");
    fs::create_dir_all(home.join("catalog/agents")).unwrap();
    fs::write(
        home.join("catalog/agents/scout.md"),
        "---\nname: scout\ndescription: looks around\n---\nUpstream.\n",
    )
    .unwrap();
    let manifest = project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        format!("{text}\n[agents.scout]\nsource = \"cat\"\n"),
    )
    .unwrap();
    let parked = project.join(".claude/agents/scout.md.disabled");
    fs::create_dir_all(parked.parent().unwrap()).unwrap();
    fs::write(&parked, "the tool that came before").unwrap();

    let planned = plan(home, &project);
    assert!(planned.contains("conflict: agent scout"), "{planned}");
    assert_eq!(
        offer(&planned),
        "kendex adopt agent scout --harness claude",
        "the offer was withheld from a position adoption can take: {planned}"
    );

    // Run it, because an offer that only prints is how a way out that
    // cannot be taken ships.
    follow(home, &project, &planned);
    let after = plan(home, &project);
    assert!(!after.contains("conflict: agent scout"), "{after}");
    assert!(
        fs::read_to_string(project.join("kendex.toml"))
            .unwrap()
            .contains("[agents.scout]\nsource = \"local\""),
        "the kept file was not written into the manifest"
    );
}

/// Keeping something that was switched off leaves it switched off. The
/// apply that follows writes what the declaration says, so declaring it on
/// would turn it on behind the reader.
#[test]
#[allow(clippy::unwrap_used)]
fn keeping_a_switched_off_item_leaves_it_switched_off() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\"]", "copy");
    fs::create_dir_all(home.join("catalog/agents")).unwrap();
    fs::write(
        home.join("catalog/agents/scout.md"),
        "---\nname: scout\ndescription: looks around\n---\nUpstream.\n",
    )
    .unwrap();
    let manifest = project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        format!("{text}\n[agents.scout]\nsource = \"cat\"\n"),
    )
    .unwrap();
    let parked = project.join(".claude/agents/scout.md.disabled");
    fs::create_dir_all(parked.parent().unwrap()).unwrap();
    fs::write(&parked, "the tool that came before").unwrap();

    follow(home, &project, &plan(home, &project));

    let written = fs::read_to_string(&manifest).unwrap();
    assert!(
        written.contains("enabled = false"),
        "the item was turned on by being kept:\n{written}"
    );
    assert!(
        !project.join(".claude/agents/scout.md").exists(),
        "and it is still parked on disk"
    );
}

/// A skill folder keeps its name whether the skill is on or off — the
/// marker inside it is what carries the toggle, so a folder holding only
/// the switched-off marker is a position adoption can take.
#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_parked_inside_its_folder_is_offered_the_keep() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\"]", "copy");
    let here = project.join(".claude/skills/deploy");
    fs::create_dir_all(&here).unwrap();
    fs::write(
        here.join("SKILL.md.disabled"),
        "---\nname: deploy\ndescription: ship it\n---\nBy hand.\n",
    )
    .unwrap();

    let planned = plan(home, &project);
    assert_eq!(
        offer(&planned),
        "kendex adopt skill deploy --harness claude",
        "{planned}"
    );
    follow(home, &project, &planned);
    assert!(
        fs::read_to_string(project.join("kendex.toml"))
            .unwrap()
            .contains("enabled = false"),
        "a skill kept while switched off was turned on"
    );
}

/// Content under both spellings at once. An item is on or off, not both,
/// so picking one would either trash the copy it did not pick or write a
/// declaration that switches the other — the reader is asked instead.
#[test]
#[allow(clippy::unwrap_used)]
fn content_under_both_spellings_is_never_offered_the_keep() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\"]", "copy");
    fs::create_dir_all(home.join("catalog/agents")).unwrap();
    fs::write(
        home.join("catalog/agents/scout.md"),
        "---\nname: scout\ndescription: looks around\n---\nUpstream.\n",
    )
    .unwrap();
    let manifest = project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        format!("{text}\n[agents.scout]\nsource = \"cat\"\n"),
    )
    .unwrap();
    let dir = project.join(".claude/agents");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("scout.md"), "on by hand").unwrap();
    fs::write(dir.join("scout.md.disabled"), "off by hand").unwrap();

    let planned = plan(home, &project);
    assert_eq!(
        offer(&planned),
        "move them somewhere else first",
        "{planned}"
    );
    assert!(
        dir.join("scout.md.disabled").is_file(),
        "both are left alone"
    );
}
