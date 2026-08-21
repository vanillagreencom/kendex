//! Ownership: what an installation actually put on this machine, as
//! opposed to what its entry in the lock happens to be keyed by. Every
//! protection here rests on the same answer — files kendex wrote are its
//! own to replace, and everything else is a stranger's — so an ownership
//! read that is too generous hands a stranger's files to the writer, and
//! one that is too mean reports kendex's own output back at the user.
#![cfg(unix)]

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::{DriftCause, DriftRow, DriftState, PlanOptions, audit, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    scope: Scope,
}

/// A project asking for one skill from a local catalog, installed the way
/// the test is about.
#[allow(clippy::unwrap_used)]
fn with_method(method: &str) -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let catalog = home.join("catalog/skills/deploy");
    fs::create_dir_all(&catalog).unwrap();
    fs::write(
        catalog.join("SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nUpstream.\n",
    )
    .unwrap();
    let project = home.join("app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"{method}\"\n\n[skills.deploy]\nsource = \"cat\"\n",
            home.join("catalog").display()
        ),
    )
    .unwrap();
    World {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project { root: project },
        home,
        _tmp: tmp,
    }
}

/// Point the declaration at a set of tools, sharing one tree between them.
#[allow(clippy::unwrap_used)]
fn declare_for(w: &World, harnesses: &str) {
    fs::write(
        w.home.join("app/kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = {harnesses}\nmethod = \"symlink\"\n\n[skills.deploy]\nsource = \"cat\"\n",
            w.home.join("catalog").display()
        ),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn deploy_row(rows: &[DriftRow]) -> &DriftRow {
    rows.iter().find(|row| row.name == "deploy").unwrap()
}

/// A copy install never wrote the shared tree, so it never owned it. Read
/// as owned, a second tool's declaration over pre-existing files at
/// `.agents/skills` came back as a local edit instead of files kendex did
/// not write: `--replace-unmanaged` could not reach it, and `--discard-
/// edits` was free to write straight over content nothing had recorded.
#[test]
#[allow(clippy::unwrap_used)]
fn a_copy_install_never_owns_the_shared_tree() {
    let w = with_method("copy");
    let report = plan_apply(&w.env, &w.scope, &PlanOptions::default()).unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();

    // The second tool reads the shared tree, and somebody's files are there.
    fs::write(
        w.home.join("app/kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\n",
            w.home.join("catalog").display()
        ),
    )
    .unwrap();
    let stranger = w.home.join("app/.agents/skills/deploy");
    fs::create_dir_all(&stranger).unwrap();
    fs::write(
        stranger.join("SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nWritten by the tool that came before.\n",
    )
    .unwrap();

    let row = audit(&w.env, &w.scope)
        .unwrap()
        .drift
        .into_iter()
        .find(|row| row.name == "deploy" && row.harness == kendex_core::model::HarnessId::Codex)
        .unwrap();
    assert_eq!(
        row.cause,
        Some(DriftCause::UnmanagedContent),
        "read as kendex's own, the exits that keep these files are never offered: {row:?}"
    );

    let discard = PlanOptions {
        overwrite_edited: true,
        ..PlanOptions::default()
    };
    let report = plan_apply(&w.env, &w.scope, &discard).unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();
    assert!(
        fs::read_to_string(stranger.join("SKILL.md"))
            .unwrap()
            .contains("the tool that came before"),
        "files kendex did not write were overwritten by discarding edits"
    );
}

/// Switching a skill from a copy per tool to one shared tree writes
/// somewhere the old install never wrote. Ownership read from the entry
/// merely existing called that new position this installation's own, so
/// whatever already lived there came back as a local edit — unreachable by
/// the replacement, and overwritten outright by discarding edits, with no
/// copy in the trash.
#[test]
#[allow(clippy::unwrap_used)]
fn changing_how_a_skill_installs_never_claims_the_new_position() {
    let w = with_method("copy");
    let report = plan_apply(&w.env, &w.scope, &PlanOptions::default()).unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();

    declare_for(&w, "[\"claude\"]");
    let stranger = w.home.join("app/.agents/skills/deploy");
    fs::create_dir_all(&stranger).unwrap();
    fs::write(
        stranger.join("SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nWritten by the tool that came before.\n",
    )
    .unwrap();

    let row = deploy_row(&audit(&w.env, &w.scope).unwrap().drift).clone();
    assert_eq!(
        row.cause,
        Some(DriftCause::UnmanagedContent),
        "read as kendex's own, the exits that keep these files are never offered: {row:?}"
    );

    let discard = PlanOptions {
        overwrite_edited: true,
        ..PlanOptions::default()
    };
    let report = plan_apply(&w.env, &w.scope, &discard).unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();
    assert!(
        fs::read_to_string(stranger.join("SKILL.md"))
            .unwrap()
            .contains("the tool that came before"),
        "files kendex did not write were overwritten by discarding edits"
    );
}

/// A copy declaration never writes the shared tree, so it must not hide
/// what lives there either. Read as one of the declaration's own places,
/// hand-made content under the shared skills folder vanished from the
/// inventory of things nothing manages.
#[test]
#[allow(clippy::unwrap_used)]
fn a_copy_declaration_does_not_hide_the_shared_folder() {
    let w = with_method("copy");
    let handmade = w.home.join("app/.agents/skills/deploy");
    fs::create_dir_all(&handmade).unwrap();
    fs::write(
        handmade.join("SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nBy hand.\n",
    )
    .unwrap();

    let report = audit(&w.env, &w.scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.name == "deploy" && row.state == DriftState::Unmanaged),
        "content nothing manages was hidden by a declaration that never writes there: {:?}",
        report.drift
    );
}
