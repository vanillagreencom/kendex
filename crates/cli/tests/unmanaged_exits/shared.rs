//! A folder several tools read through links somebody set up by hand.
//! One folder is one answer, whichever method the declaration names and
//! wherever the folder itself sits.

use std::fs;

use super::{folder_at, follow, link_at, offer, plan, project_with, settled};

/// The layout the whole issue started from: one real folder at one tool's
/// place, the other tool reading it through a link somebody made. Both
/// tools are blocked, and keeping it is one move covering both — named for
/// the tools adoption can act through, not the tool a row happens to be
/// about.
#[test]
#[allow(clippy::unwrap_used)]
fn a_folder_shared_by_hand_is_kept_by_the_offer_it_prints() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\", \"codex\"]", "symlink");
    let folder = project.join(".claude/skills/deploy");
    folder_at(&folder, "Shared by hand.");
    link_at(&project.join(".agents/skills/deploy"), &folder);

    let planned = plan(home, &project);
    assert!(
        planned.contains(".claude/skills/deploy"),
        "the folder the link points at is what the reader decides about: {planned}"
    );
    // Replacing a link is never right: the files are not at that position,
    // and writing over it breaks the sharing somebody set up.
    assert!(!planned.contains("--replace-unmanaged"), "{planned}");
    assert_eq!(
        offer(&planned),
        "kendex adopt skill deploy --harness claude --harness codex --harness pi"
    );

    follow(home, &project, &planned);
    settled(
        home,
        &project,
        &[".claude/skills/deploy", ".agents/skills/deploy"],
        "Shared by hand.",
        &[],
    );
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(
        !manifest.contains("[skills.deploy]\nsource = \"local\"\nharnesses"),
        "a tool that was blocked a moment ago lost the skill:\n{manifest}"
    );
}

/// The same sharing, with the folder somewhere neither tool would look. It
/// is reached through the one tool whose own place is the link, and naming
/// the other — which has nothing there — would error on the spot.
#[test]
#[allow(clippy::unwrap_used)]
fn a_folder_outside_every_tool_is_kept_through_the_tool_that_links_at_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\", \"codex\"]", "symlink");
    let elsewhere = home.join("shared/deploy");
    folder_at(&elsewhere, "Kept somewhere else.");
    link_at(&project.join(".agents/skills/deploy"), &elsewhere);

    let planned = plan(home, &project);
    // Pi reads the same directory Codex does, so keeping the folder clears
    // its link too — the command says so rather than touching a tool it
    // never mentioned.
    assert_eq!(
        offer(&planned),
        "kendex adopt skill deploy --harness codex --harness pi"
    );

    follow(home, &project, &planned);
    settled(
        home,
        &project,
        &[".claude/skills/deploy", ".agents/skills/deploy"],
        "Kept somewhere else.",
        &[],
    );
}
