//! Keeping one item for several tools at once. Every tool an item is
//! blocked for is answered by one plan: taken one at a time, each tool's
//! copy landed in the local source on top of the last and the declaration
//! kept only the first, leaving the rest with files nothing manages.
#![cfg(unix)]

use std::fs;

use kendex_core::engine::adopt::adopt;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::model::{HarnessId, ItemKind, Scope};

/// A project asking for one item for two tools, with files already at
/// both places. Handed over one tool at a time, the second capture wrote
/// over the first in the local source and the declaration stayed pinned
/// to the first tool — so the second tool kept files nothing managed and
/// the first tool's copy was gone. One plan takes both.
#[test]
#[allow(clippy::unwrap_used)]
fn every_tool_the_item_sits_at_is_kept_in_one_pass() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    fs::create_dir_all(&project).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"copy\"\n",
    )
    .unwrap();
    let body = "---\nname: handmade\ndescription: mine\n---\nMy content.\n";
    for dir in [".claude/skills/handmade", ".agents/skills/handmade"] {
        fs::create_dir_all(project.join(dir)).unwrap();
        fs::write(project.join(dir).join("SKILL.md"), body).unwrap();
    }

    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude, HarnessId::Codex],
    )
    .unwrap();
    kendex_core::apply::execute(&env, &plan).unwrap();

    // The tool-owned position is cleared, and the shared tree holds the one
    // real directory the move put there. Asserted before the follow-up
    // apply: the render restores the links, so a position left behind would
    // look settled a moment later.
    assert!(
        !project.join(".claude/skills/handmade").exists(),
        "the tool's own copy was left where it was, with nothing recording it"
    );
    assert!(project.join(".agents/skills/handmade/SKILL.md").is_file());

    let report = audit(&env, &scope).unwrap();
    kendex_core::apply::execute(&env, &report.plan).unwrap();
    for dir in [".claude/skills/handmade", ".agents/skills/handmade"] {
        let installed = fs::read_to_string(project.join(dir).join("SKILL.md")).unwrap_or_default();
        assert!(
            installed.contains("My content."),
            "{dir} was left with files nothing manages"
        );
    }
    let after = audit(&env, &scope).unwrap();
    assert_eq!(after.drift, vec![], "one tool is still waiting");
}

/// The hand-made sharing layout: one real folder at one tool's place, every
/// other tool reading it through a link. Both tools are blocked there, and
/// the two positions hold the same files — so this is one capture, not two
/// copies to choose between.
#[test]
#[allow(clippy::unwrap_used)]
fn one_folder_read_through_a_link_is_not_two_different_copies() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    fs::create_dir_all(&project).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"symlink\"\n",
    )
    .unwrap();
    let folder = project.join(".claude/skills/handmade");
    fs::create_dir_all(&folder).unwrap();
    fs::write(
        folder.join("SKILL.md"),
        "---\nname: handmade\ndescription: mine\n---\nShared by hand.\n",
    )
    .unwrap();
    let link = project.join(".agents/skills/handmade");
    fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&folder, &link).unwrap();

    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude, HarnessId::Codex],
    )
    .unwrap();
    kendex_core::apply::execute(&env, &plan).unwrap();
    assert!(
        fs::read_to_string(project.join(".agents/skills/handmade/SKILL.md"))
            .unwrap()
            .contains("Shared by hand.")
    );

    let report = audit(&env, &scope).unwrap();
    kendex_core::apply::execute(&env, &report.plan).unwrap();
    for at in [".claude/skills/handmade", ".agents/skills/handmade"] {
        assert!(
            fs::read_to_string(project.join(at).join("SKILL.md"))
                .unwrap()
                .contains("Shared by hand."),
            "{at} lost the sharing it had"
        );
    }
    assert_eq!(audit(&env, &scope).unwrap().drift, vec![]);
}

/// The declaration already names a tool, and the files being kept are
/// another tool's. The list is extended: pinning it to the tool being
/// answered now would leave the one already on it with files nothing
/// manages.
#[test]
#[allow(clippy::unwrap_used)]
fn a_harness_list_already_there_is_extended_not_replaced() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    fs::create_dir_all(&project).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\", \"opencode\"]\nmethod = \"copy\"\n\n[skills.handmade]\nsource = \"local\"\nharnesses = [\"claude\"]\n",
    )
    .unwrap();
    fs::create_dir_all(project.join(".opencode/skills/handmade")).unwrap();
    fs::write(
        project.join(".opencode/skills/handmade/SKILL.md"),
        "---\nname: handmade\ndescription: mine\n---\nMy content.\n",
    )
    .unwrap();

    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Opencode],
    )
    .unwrap();
    kendex_core::apply::execute(&env, &plan).unwrap();

    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    let declared = manifest.split("[skills.handmade]").nth(1).unwrap_or("");
    assert!(
        declared.contains("\"claude\"") && declared.contains("\"opencode\""),
        "the tool already on the list was dropped:\n{manifest}"
    );
}

/// The tools hold different files under one name, and there is one
/// place in the local source to put them. Picking one would send the
/// other to the trash without asking, so the choice goes back to the
/// reader and nothing moves.
#[test]
#[allow(clippy::unwrap_used)]
fn tools_holding_different_files_are_a_choice_not_a_merge() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    fs::create_dir_all(&project).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"copy\"\n",
    )
    .unwrap();
    for (dir, text) in [
        (".claude/skills/handmade", "what Claude Code had"),
        (".agents/skills/handmade", "what Codex had"),
    ] {
        fs::create_dir_all(project.join(dir)).unwrap();
        fs::write(
            project.join(dir).join("SKILL.md"),
            format!("---\nname: handmade\ndescription: mine\n---\n{text}\n"),
        )
        .unwrap();
    }

    let error = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude, HarnessId::Codex],
    )
    .unwrap_err();
    assert!(
        matches!(error, CoreError::AdoptedCopiesDiffer { .. }),
        "{error}"
    );
    assert!(
        fs::read_to_string(project.join(".claude/skills/handmade/SKILL.md"))
            .unwrap()
            .contains("what Claude Code had")
    );
    assert!(
        fs::read_to_string(project.join(".agents/skills/handmade/SKILL.md"))
            .unwrap()
            .contains("what Codex had")
    );
    assert!(!project.join(".kendex-local/skills/handmade").exists());
}

/// Keeping a hand-made shared folder through the tool that links at it
/// declares the tool holding the folder too. Counted only by the links
/// pointing at it, the tool whose own place IS the folder was left off, and
/// a declaration built from that list took the skill away from the one tool
/// that had it all along.
#[test]
#[allow(clippy::unwrap_used)]
fn the_tool_holding_a_shared_folder_stays_declared() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    fs::create_dir_all(&project).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\", \"codex\", \"opencode\"]\nmethod = \"symlink\"\n",
    )
    .unwrap();
    let folder = project.join(".claude/skills/handmade");
    fs::create_dir_all(&folder).unwrap();
    fs::write(
        folder.join("SKILL.md"),
        "---\nname: handmade\ndescription: mine\n---\nShared by hand.\n",
    )
    .unwrap();
    let link = project.join(".agents/skills/handmade");
    fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&folder, &link).unwrap();

    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Codex],
    )
    .unwrap();
    kendex_core::apply::execute(&env, &plan).unwrap();

    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    let declared = manifest.split("[skills.handmade]").nth(1).unwrap_or("");
    assert!(
        declared.contains("\"claude\""),
        "the tool holding the folder lost the skill:\n{manifest}"
    );
}

/// The verb refuses what the offer withholds. A reader can name the item
/// directly, and taking one spelling while the other stays leaves a file a
/// later switch reads as kendex's own and writes over.
#[test]
#[allow(clippy::unwrap_used)]
fn both_spellings_are_refused_by_the_verb_too() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    fs::create_dir_all(&project).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n",
    )
    .unwrap();
    let dir = project.join(".claude/agents");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("scout.md"), "on by hand").unwrap();
    fs::write(dir.join("scout.md.disabled"), "off by hand").unwrap();

    let refused = adopt(&env, &scope, ItemKind::Agent, "scout", &[HarnessId::Claude]);

    assert!(
        matches!(refused, Err(CoreError::TogglesDiffer { .. })),
        "half the pair was taken: {refused:?}"
    );
    assert!(
        dir.join("scout.md").is_file() && dir.join("scout.md.disabled").is_file(),
        "and both are left where they are"
    );
}
