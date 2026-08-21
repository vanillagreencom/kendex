//! A declaration over content kendex never wrote — the shape every repo
//! migrating onto kendex arrives in. The refusal names both ways out, the
//! take-over installs what was declared and keeps the old files, and a link
//! kendex did not create is still never a clobber target (invariant 6).
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

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

#[allow(clippy::unwrap_used)]
fn world() -> World {
    with_method("copy")
}

/// The other install shape: one canonical tree under `.agents/skills`, and
/// a link at each harness's own position pointing at it.
#[allow(clippy::unwrap_used)]
fn linking_world() -> World {
    with_method("symlink")
}

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

/// Point the declaration at a different set of tools.
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

/// Where the declaration installs, holding bytes some earlier tool wrote.
#[allow(clippy::unwrap_used)]
fn foreign_install(w: &World) -> PathBuf {
    let dir = w.home.join("app/.claude/skills/deploy");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nWritten by the tool that came before.\n",
    )
    .unwrap();
    dir
}

#[allow(clippy::unwrap_used)]
fn deploy_row(rows: &[DriftRow]) -> &DriftRow {
    rows.iter().find(|row| row.name == "deploy").unwrap()
}

fn take_over() -> PlanOptions {
    PlanOptions {
        replace_unmanaged: true,
        ..PlanOptions::default()
    }
}

/// The dead end this fixes: the refusal used to describe a state ("not
/// managed yet") and name no way out of it. The row now carries where the
/// files are and the cause that says what that means; the words, and the
/// ways out, belong to whichever surface is doing the telling.
#[test]
#[allow(clippy::unwrap_used)]
fn the_refusal_says_which_files_are_in_the_way() {
    let w = world();
    let dir = foreign_install(&w);

    let report = audit(&w.env, &w.scope).unwrap();
    let row = deploy_row(&report.drift);
    assert_eq!(row.state, DriftState::Conflict);
    assert_eq!(
        row.cause,
        Some(DriftCause::UnmanagedContent),
        "the cause is what lets a surface offer the two exits: {row:?}"
    );
    assert_eq!(
        row.detail,
        dir.display().to_string(),
        "the row says where they are, and the surface says what that means"
    );

    // And nothing is planned for it — the files stay exactly as they are.
    apply::execute(&w.env, &report.plan, None).unwrap();
    assert!(
        fs::read_to_string(dir.join("SKILL.md"))
            .unwrap()
            .contains("came before")
    );
}

/// The direction adopt cannot go: keep the declaration, replace the bytes.
#[test]
#[allow(clippy::unwrap_used)]
fn taking_over_installs_what_was_declared_and_keeps_the_old_files() {
    let w = world();
    let dir = foreign_install(&w);

    let report = plan_apply(&w.env, &w.scope, &take_over()).unwrap();
    assert!(
        report
            .drift
            .iter()
            .all(|row| row.state != DriftState::Conflict),
        "the take-over resolves the refusal: {:?}",
        report.drift
    );
    apply::execute(&w.env, &report.plan, None).unwrap();

    assert!(
        fs::read_to_string(dir.join("SKILL.md"))
            .unwrap()
            .contains("Upstream."),
        "the declared render is what a tool now loads"
    );
    assert!(
        trashed(&w.env.trash_dir()),
        "the files kendex did not write are recoverable, never deleted"
    );
    let after = audit(&w.env, &w.scope).unwrap();
    assert!(after.drift.is_empty(), "{:?}", after.drift);
}

/// The bytes that were in the way, found anywhere under the trash.
#[allow(clippy::unwrap_used)]
fn trashed(trash: &Path) -> bool {
    fn walk(dir: &Path, found: &mut bool) {
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                walk(&path, found);
            } else if fs::read_to_string(&path)
                .map(|text| text.contains("came before"))
                .unwrap_or(false)
            {
                *found = true;
            }
        }
    }
    let mut found = false;
    walk(trash, &mut found);
    found
}

/// Invariant 6 holds under the take-over: a link is not this position's
/// content, it is somebody else's, and following it would take bytes the
/// user never named. Only adopt, which names the folder and every tool
/// reading it, may go there.
#[test]
#[allow(clippy::unwrap_used)]
fn a_link_kendex_did_not_create_is_never_taken_over() {
    let w = world();
    let elsewhere = w.home.join("somewhere/deploy");
    fs::create_dir_all(&elsewhere).unwrap();
    fs::write(elsewhere.join("SKILL.md"), "someone else's copy").unwrap();
    let position = w.home.join("app/.claude/skills/deploy");
    fs::create_dir_all(position.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&elsewhere, &position).unwrap();

    let report = plan_apply(&w.env, &w.scope, &take_over()).unwrap();
    let row = deploy_row(&report.drift);
    assert_eq!(row.state, DriftState::Conflict, "{row:?}");
    assert!(
        row.detail.contains("link kendex did not create"),
        "{}",
        row.detail
    );
    apply::execute(&w.env, &report.plan, None).unwrap();
    assert_eq!(
        fs::read_to_string(elsewhere.join("SKILL.md")).unwrap(),
        "someone else's copy"
    );
    assert!(position.is_symlink(), "the link is left exactly as it was");
}

/// The state that must stay quiet: an installation kendex itself wrote is
/// its own to replace, and reporting it as a stranger's would send the user
/// to adopt their own output.
#[test]
#[allow(clippy::unwrap_used)]
fn an_installation_kendex_wrote_is_never_called_a_stranger() {
    let w = world();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();

    assert!(audit(&w.env, &w.scope).unwrap().drift.is_empty());
    fs::write(
        w.home.join("app/.claude/skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nEdited by hand.\n",
    )
    .unwrap();
    let edited = audit(&w.env, &w.scope).unwrap();
    let row = deploy_row(&edited.drift);
    assert_eq!(
        row.cause,
        Some(DriftCause::LocalEdit),
        "an edit stays an edit, with its own two exits: {row:?}"
    );
}

/// A refusal plans nothing. The tree half of a linked skill is planned
/// before its harness link is looked at, so a link that turns out to be a
/// stranger's arrives after the tree's ops are already staged — and those
/// ops would otherwise run: the user's canonical tree in the trash, the
/// render in its place, and no lock entry recording any of it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refusal_at_the_link_leaves_the_tree_untouched() {
    let w = linking_world();
    let canonical = w.home.join("app/.agents/skills/deploy");
    fs::create_dir_all(&canonical).unwrap();
    fs::write(canonical.join("SKILL.md"), "the tool that came before").unwrap();
    let elsewhere = w.home.join("somewhere/deploy");
    fs::create_dir_all(&elsewhere).unwrap();
    fs::write(elsewhere.join("SKILL.md"), "someone else's copy").unwrap();
    let link = w.home.join("app/.claude/skills/deploy");
    fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&elsewhere, &link).unwrap();

    let report = plan_apply(&w.env, &w.scope, &take_over()).unwrap();
    let row = deploy_row(&report.drift);
    assert_eq!(row.state, DriftState::Conflict, "{row:?}");
    assert!(
        !report
            .plan
            .ops
            .iter()
            .any(|op| format!("{:?}", op.op).contains("deploy")),
        "nothing is planned for a refused item: {:?}",
        report.plan.ops
    );
    apply::execute(&w.env, &report.plan, None).unwrap();
    assert_eq!(
        fs::read_to_string(canonical.join("SKILL.md")).unwrap(),
        "the tool that came before"
    );
    assert!(!trashed(&w.env.trash_dir()));
}

/// The same refusal on the ordinary path: a blocked declaration must not
/// leave a rendered canonical tree behind that nothing recorded, which no
/// lock, no verify and no orphan sweep would ever reach.
#[test]
#[allow(clippy::unwrap_used)]
fn a_blocked_declaration_leaves_no_tree_nothing_recorded() {
    let w = linking_world();
    let position = w.home.join("app/.claude/skills/deploy");
    fs::create_dir_all(&position).unwrap();
    fs::write(position.join("SKILL.md"), "the tool that came before").unwrap();

    let report = audit(&w.env, &w.scope).unwrap();
    assert_eq!(deploy_row(&report.drift).state, DriftState::Conflict);
    apply::execute(&w.env, &report.plan, None).unwrap();
    assert!(
        !w.home.join("app/.agents/skills/deploy").exists(),
        "a refused item wrote its canonical tree anyway"
    );
}

/// A second tool declared over a shared tree one tool already installed.
/// The bytes are kendex's own with the user's hands on them: the second
/// tool's declaration has no record of its own to hold it, and without one
/// the take-over would read the edit as a stranger's files and trash them.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edit_under_one_tool_holds_when_another_tool_is_declared_over_it() {
    let w = linking_world();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();

    let canonical = w.home.join("app/.agents/skills/deploy/SKILL.md");
    fs::write(
        &canonical,
        "---\nname: deploy\ndescription: ship it\n---\nMine.\n",
    )
    .unwrap();
    declare_for(&w, "[\"claude\", \"codex\"]");

    let report = plan_apply(&w.env, &w.scope, &take_over()).unwrap();
    let row = deploy_row(&report.drift);
    assert_eq!(row.state, DriftState::Conflict, "{row:?}");
    assert_eq!(
        row.cause,
        Some(DriftCause::LocalEdit),
        "an edit is an edit whichever tool is asking: {row:?}"
    );
    apply::execute(&w.env, &report.plan, None).unwrap();
    assert!(
        fs::read_to_string(&canonical).unwrap().contains("Mine."),
        "the take-over trashed an edit the edit gate protects"
    );
    assert!(!trashed(&w.env.trash_dir()));
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
