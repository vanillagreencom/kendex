//! The promise the committed posture exists for: someone clones the
//! repository and every tool they use finds the skills, without kendex ever
//! having run on their machine.

use std::fs;

use crate::{World, git, link_text, read};

/// A bare clone into a path nothing in the original ever named, checked
/// through the tool's own directory rather than the shared one — an
/// absolute link would resolve back to the fixture home and pass a weaker
/// assertion.
#[test]
#[allow(clippy::unwrap_used)]
fn a_clone_has_working_skills_with_no_kendex_run() {
    let world = World::new(&["claude", "codex"]);
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);
    world.commit_all("install deploy");

    let clone = world.tmp.path().join("elsewhere/fresh-checkout");
    fs::create_dir_all(clone.parent().unwrap()).unwrap();
    git(
        &world.project,
        &["clone", "--quiet", ".", &clone.display().to_string()],
    );

    // Codex and Pi read the shared tree directly.
    assert!(read(&clone.join(".agents/skills/deploy/SKILL.md")).contains("Run the deploy."));
    // Claude reads its own directory, which is a link that had to survive
    // the move to a path the original never knew about.
    let claude = clone.join(".claude/skills/deploy");
    assert_eq!(link_text(&claude), "../../.agents/skills/deploy");
    assert!(read(&claude.join("SKILL.md")).contains("Run the deploy."));

    // The ledger stayed behind; the trees did not.
    assert!(!clone.join(".kendex-lock.json").exists());
    assert!(clone.join("kendex.toml").is_file());
}

/// An install written before relative links converges on the next apply
/// instead of being called a conflict — the migration path for every scope
/// that already exists.
#[test]
#[allow(clippy::unwrap_used)]
fn an_absolute_link_from_an_older_install_migrates_on_refresh() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);

    // Respell the link the way the older build wrote it.
    let link = world.at(".claude/skills/deploy");
    let canonical = world.at(".agents/skills/deploy");
    fs::remove_file(&link).unwrap();
    std::os::unix::fs::symlink(&canonical, &link).unwrap();
    assert_eq!(link_text(&link), canonical.display().to_string());

    // The drift is named for what it costs, not as an unownable link.
    let said = crate::said(&world.try_run(&["verify"]));
    assert!(said.contains("clone"), "{said}");

    world.run(&["refresh", "-y"]);
    assert_eq!(link_text(&link), "../../.agents/skills/deploy");
    assert!(read(&link.join("SKILL.md")).contains("Run the deploy."));
    assert!(world.try_run(&["verify"]).status.success());
}

/// Copy delivery is the escape hatch for a checkout that cannot hold links
/// at all: a clone of a copy install has real files everywhere.
#[test]
#[allow(clippy::unwrap_used)]
fn a_copy_install_clones_as_plain_directories() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "--method", "copy", "-y"]);
    world.commit_all("install deploy by copy");

    let clone = world.tmp.path().join("elsewhere/copy-checkout");
    fs::create_dir_all(clone.parent().unwrap()).unwrap();
    git(
        &world.project,
        &["clone", "--quiet", ".", &clone.display().to_string()],
    );
    let claude = clone.join(".claude/skills/deploy");
    assert!(claude.is_dir() && !claude.is_symlink());
    assert!(read(&claude.join("SKILL.md")).contains("Run the deploy."));
}
