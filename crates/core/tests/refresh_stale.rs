//! The detached background job the session check spawns, driven as the
//! job itself: it finishes the plan over unrecorded copies a check's
//! deadline cut short, and derives a drift snapshot only for a scope with
//! a remote source, since a scope of path sources has no verdict a fetch
//! could move.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::PathBuf;

use kendex_core::drift;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    scope: Scope,
}

/// A path catalog offering one skill, and a project declaring it over a
/// copy of the person's own.
#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nUpstream.\n",
    )
    .unwrap();
    let project = home.join("app");
    fs::create_dir_all(project.join(".claude/skills/deploy")).unwrap();
    fs::write(
        project.join(".claude/skills/deploy/SKILL.md"),
        "the tool that came before",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\n",
            source_path(&catalog)
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

/// The job finishes the plan the check owes: driven over an occupied
/// scope with no memo, it leaves the memo the next check reads, and the
/// next check judges the copy without planning again.
#[test]
#[allow(clippy::unwrap_used)]
fn the_job_finishes_the_plan_over_unrecorded_copies() {
    let w = world();
    let memo = drift::copies::memo_path(&w.env, &w.scope);
    assert!(!memo.exists());

    let notes = drift::refresh::refresh_stale(&w.env, std::slice::from_ref(&w.scope));
    assert!(notes.is_empty(), "{notes:?}");
    assert!(
        memo.is_file(),
        "the job leaves the memo the next check reads"
    );

    let text = drift::report::render_plain(&drift::report::check_within(
        &w.env,
        std::slice::from_ref(&w.scope),
        std::time::Duration::ZERO,
    ));
    assert!(
        text.contains("unmanaged copy of skill 'deploy' for Claude Code: 1 file differs from"),
        "a check with no time to plan reads what the job measured: {text}"
    );
}

/// A scope of path sources gets no snapshot from the job: nothing a fetch
/// could move is in it, and the check reads its absent snapshot as
/// nothing to say. The remote side of the gate is
/// `drift_check::the_job_derives_the_snapshot_of_a_scope_with_a_remote_source`.
#[test]
#[allow(clippy::unwrap_used)]
fn a_scope_of_path_sources_gets_no_snapshot_from_the_job() {
    let w = world();
    drift::refresh::refresh_stale(&w.env, std::slice::from_ref(&w.scope));
    assert!(
        matches!(
            drift::snapshot::load(&w.env, &w.scope),
            drift::snapshot::SnapshotFile::Absent
        ),
        "no remote source, no snapshot"
    );
    assert!(w.home.join("app/kendex.toml").is_file());
}
