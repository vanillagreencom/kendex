//! A declaration over content kendex never wrote — the shape every repo
//! migrating onto kendex arrives in. The refusal names both ways out, the
//! take-over installs what was declared and keeps the old files, and a link
//! kendex did not create is still never a clobber target (invariant 6).
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::engine::{DriftCause, DriftRow, DriftState, PlanOptions, audit, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;
use kendex_core::{apply, drift};

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    scope: Scope,
}

#[allow(clippy::unwrap_used)]
fn world() -> World {
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
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\n",
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
/// managed yet") and name no way out of it.
#[test]
#[allow(clippy::unwrap_used)]
fn the_refusal_names_both_ways_out() {
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
    assert!(
        row.detail.contains("files kendex did not write"),
        "{}",
        row.detail
    );
    assert!(
        row.detail.contains("adopt") && row.detail.contains("replace"),
        "both exits are named: {}",
        row.detail
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

/// Two different problems with two different fixes. Collapsed into one
/// count, a reader who ran `kendex findings` found nothing to review and
/// no reason the install was not happening.
#[test]
#[allow(clippy::unwrap_used)]
fn the_session_check_tells_this_apart_from_a_safety_hold() {
    let w = world();
    foreign_install(&w);

    let checked = drift::report::check(&w.env, std::slice::from_ref(&w.scope));
    assert_eq!(checked.status, drift::report::CheckStatus::Drift);
    let text = drift::report::render_plain(&checked);
    assert!(
        text.contains("blocked by files kendex did not write"),
        "{text}"
    );
    assert!(text.contains("skill 'deploy' is declared"), "{text}");
    assert!(
        text.contains("fix: kendex apply --replace-unmanaged"),
        "{text}"
    );
    assert!(
        !text.contains("held back"),
        "nothing here is waiting on a safety review: {text}"
    );
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

    let checked = drift::report::check(&w.env, std::slice::from_ref(&w.scope));
    assert_eq!(
        drift::report::render_plain(&checked),
        "",
        "{:?}",
        checked.sections
    );
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
