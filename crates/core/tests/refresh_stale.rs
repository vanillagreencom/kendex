//! The detached background job the session check spawns, driven as the
//! job itself: it finishes the plan over unrecorded copies a check's
//! deadline cut short, and derives a drift snapshot only for a scope with
//! a remote source, since a scope of path sources has no verdict a fetch
//! could move, and drops the drift files of a project whose directory is
//! gone.
#![cfg(unix)]

use crate::test_util;
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
            "schema = 7\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\n",
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

    let text = drift::report::render_plain(
        &drift::report::check(
            &w.env,
            std::slice::from_ref(&w.scope),
            kendex_core::drift::copies::CheckMode::Settle,
        ),
        kendex_core::drift::report::Verbosity::Verbose,
    );
    assert!(
        text.contains("unmanaged copy of skill 'deploy' for Claude Code: 1 file differs from"),
        "the next check reads what the job measured: {text}"
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

/// The job drops the derived files of a project whose directory is gone,
/// a snapshot this build no longer reads included, and nothing else: not
/// the global scope's, not a live project's, not a file that is no
/// snapshot, and not a project whose existence fails to read.
#[test]
#[allow(clippy::unwrap_used)]
fn the_job_drops_the_drift_files_of_a_gone_project_and_nothing_else() {
    let w = world();
    let blocker = w.home.join("a-file");
    fs::write(&blocker, "").unwrap();
    let project = |root: PathBuf| Scope::Project { root };
    // (row, scope, schema, gone afterwards)
    let rows = [
        ("gone project", project(w.home.join("deleted")), 4, true),
        (
            "gone project, old schema",
            project(w.home.join("older")),
            1,
            true,
        ),
        ("global", Scope::Global, 4, false),
        ("live project", w.scope.clone(), 4, false),
        (
            "existence unreadable",
            project(blocker.join("app")),
            4,
            false,
        ),
    ];
    for (_, scope, schema, _) in &rows {
        let snapshot = serde_json::json!({ "schema": schema, "scope": scope.label() });
        fs::create_dir_all(w.env.drift_dir()).unwrap();
        fs::write(
            drift::snapshot::snapshot_path(&w.env, scope),
            snapshot.to_string(),
        )
        .unwrap();
        fs::write(drift::copies::memo_path(&w.env, scope), "{}").unwrap();
    }
    let not_a_snapshot = w.env.drift_dir().join("0123456789abcdef.json");
    fs::write(&not_a_snapshot, "{\"schema\": 4}").unwrap();

    drift::refresh::refresh_stale(&w.env, &[]);

    for (row, scope, _, gone) in &rows {
        for file in [
            drift::snapshot::snapshot_path(&w.env, scope),
            drift::copies::memo_path(&w.env, scope),
        ] {
            assert_eq!(!file.exists(), *gone, "{row}: {}", file.display());
        }
    }
    assert!(not_a_snapshot.is_file(), "a file that is no snapshot stays");
}
