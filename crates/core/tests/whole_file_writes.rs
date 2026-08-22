//! Writing a whole manifest from a copy someone has been holding.
//!
//! The copy carries the base of the file it came from, and every op in the
//! plan that writes that manifest binds to it — the caller's own write, and
//! the ones the plan brings itself: a schema upgrade, a repository move,
//! skills an agent gained upstream. Those bind to what the file was when
//! the plan ran, which is a later question and a weaker one: it accepts a
//! writer the copy never saw.
//!
//! Bound where the ops are built, because a plan is not a list of paths to
//! search afterwards. A scope still under the old product name has its
//! writes retargeted to the new filename once planning is done, and a
//! caller matching the path it knew would find nothing.
#![cfg(unix)]

use std::fs;
use std::path::Path;

use kendex_core::apply::{Op, Pre};
use kendex_core::engine::{PlanOptions, plan_scope};
use kendex_core::env::{Env, FakeOs};
use kendex_core::lock::Lock;
use kendex_core::manifest::{self, Base, Manifest};
use kendex_core::model::Scope;

#[allow(clippy::unwrap_used)]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

fn empty_lock() -> Lock {
    Lock {
        version: kendex_core::lock::LOCK_VERSION,
        entries: Default::default(),
        sources: Default::default(),
        settings_seeds: Default::default(),
    }
}

/// A manifest from before the current schema, so the plan carries its own
/// write of the file: the upgrade lands as a side effect of writing at all.
fn from_an_older_schema() -> Manifest {
    Manifest {
        schema: manifest::MANIFEST_SCHEMA - 1,
        ..Manifest::default()
    }
}

/// Where the plan writes this scope's manifest, and what it binds to.
fn manifest_write(report: &kendex_core::engine::EngineReport, path: &Path) -> Option<Pre> {
    report
        .plan
        .ops
        .iter()
        .find_map(|planned| match &planned.op {
            Op::WriteManifest { path: at, pre, .. } | Op::WriteFile { path: at, pre, .. }
                if at == path =>
            {
                Some(pre.clone())
            }
            _ => None,
        })
}

#[allow(clippy::unwrap_used)]
fn planned_from(env: &Env, scope: &Scope, held: &Base) -> kendex_core::engine::EngineReport {
    plan_scope(
        env,
        scope,
        &from_an_older_schema(),
        &empty_lock(),
        &PlanOptions {
            manifest_base: Some(held.clone()),
            ..PlanOptions::default()
        },
    )
    .unwrap()
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_write_the_plan_brought_binds_to_the_copy_being_written() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let env = Env::fake(&home, FakeOs::Linux);
    let scope = Scope::Global;
    let path = manifest::manifest_path(&env, &scope);
    write(&path, "schema = 4\n");

    // The editor read the file here.
    let (_, held) = manifest::read_for_mutation(&path).unwrap();
    let report = planned_from(&env, &scope, &held);
    assert_eq!(
        manifest_write(&report, &path),
        Some(Pre::from(&held)),
        "the plan's own write binds to the copy being written"
    );

    // Something else wrote it before the save reached the disk.
    write(&path, "schema = 5\n\n[forks.skill.gh]\nsource = \"cat\"\n");

    let refused = kendex_core::apply::execute(&env, &report.plan, None);
    assert!(refused.is_err(), "the copy was written over the fork");
    assert!(
        fs::read_to_string(&path).unwrap().contains("forks"),
        "and the fork is still there"
    );
}

/// A scope still under the old product name renames first, and every write
/// planned against the old filename is retargeted to the new one after the
/// ops are built. The binding has to survive that: matched by path from
/// outside, it would be looking for a name the plan no longer writes.
#[test]
#[allow(clippy::unwrap_used)]
fn a_retargeted_write_is_still_bound_to_the_copy_being_written() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let env = Env::fake(&home, FakeOs::Linux);
    let scope = Scope::Project {
        root: home.join("dev/app"),
    };
    let legacy = home.join("dev/app/vstack.toml");
    write(&legacy, "schema = 4\n");
    // The path the editor reads and the path the plan ends up writing are
    // not the same string.
    assert_eq!(manifest::manifest_path(&env, &scope), legacy);
    let renamed = home.join("dev/app/kendex.toml");

    let (_, held) = manifest::read_for_mutation(&legacy).unwrap();
    let report = planned_from(&env, &scope, &held);

    assert!(
        manifest_write(&report, &legacy).is_none(),
        "the write moved to the new name"
    );
    assert_eq!(
        manifest_write(&report, &renamed),
        Some(Pre::from(&held)),
        "and took its binding with it"
    );
}

/// Nothing was there when the copy was read, so nothing may be there when
/// it is written: a place that got its first manifest in between keeps it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_first_write_refuses_a_file_that_appeared_in_between() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let env = Env::fake(&home, FakeOs::Linux);
    let scope = Scope::Global;
    let path = manifest::manifest_path(&env, &scope);

    let (_, held) = manifest::read_for_mutation(&path).unwrap();
    assert_eq!(held, Base::absent(), "nothing to read yet");
    let report = planned_from(&env, &scope, &held);
    assert_eq!(manifest_write(&report, &path), Some(Pre::Absent));

    write(&path, "schema = 5\n\n[skills.gh]\nsource = \"cat\"\n");
    assert!(kendex_core::apply::execute(&env, &report.plan, None).is_err());
    assert!(fs::read_to_string(&path).unwrap().contains("skills.gh"));
}

/// What an apply hands back about the file it wrote, and when it is true.
///
/// A caller that writes a whole file and then reads the file back is
/// pairing its own copy with whatever landed in between: the apply lets the
/// scope go before that read, so the base it gets can already be somebody
/// else's, and the next write carrying that pair is accepted over them. The
/// apply reads it while it still owns the scope, which is the last moment
/// the answer is provably its own.
#[test]
#[allow(clippy::unwrap_used)]
fn the_apply_answers_for_the_file_it_left() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let env = Env::fake(&home, FakeOs::Linux);
    let scope = Scope::Global;
    let path = manifest::manifest_path(&env, &scope);
    write(&path, "schema = 4\n");

    let (_, held) = manifest::read_for_mutation(&path).unwrap();
    let report = planned_from(&env, &scope, &held);
    let outcome = kendex_core::apply::execute(&env, &report.plan, None).unwrap();

    // The bytes this apply left, not a later reading of the path.
    let (_, after) = manifest::read_for_mutation(&path).unwrap();
    assert_eq!(outcome.manifest_base, Some(after));

    // Someone else writes, as they may the moment the scope is free. The
    // base the apply handed back still describes what the apply wrote, so
    // the next write carrying it is refused rather than landing on top.
    let left = outcome.manifest_base.clone().unwrap();
    write(&path, "schema = 5\n\n[forks.skill.gh]\nsource = \"cat\"\n");
    assert!(manifest::check_base(&path, &left).is_err());

    let next = planned_from(&env, &scope, &left);
    let refused = kendex_core::apply::execute(&env, &next.plan, None);
    let Err(kendex_core::error::CoreError::RolledBack { cause, .. }) = &refused else {
        panic!("{refused:?}");
    };
    assert!(
        matches!(cause.as_ref(), kendex_core::error::CoreError::PlanStale { path: at } if at == &path),
        "the rollback has to keep what stopped it, or a caller can only print it: {cause:?}"
    );
    assert!(fs::read_to_string(&path).unwrap().contains("forks"));
}

/// The read that says what the file is now happens after every op has run
/// and the journal is clear. There is nothing left to roll back by then, so
/// a read that fails costs the answer and never the apply: reporting a
/// committed change as failed is how someone comes to run it twice.
#[test]
#[allow(clippy::unwrap_used)]
fn a_file_that_cannot_be_read_back_costs_the_answer_not_the_apply() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let env = Env::fake(&home, FakeOs::Linux);
    let scope = Scope::Global;
    let path = manifest::manifest_path(&env, &scope);
    write(&path, "schema = 5\n");

    // A plan that writes something else in this scope, so the manifest is
    // free to become unreadable the moment the ops are done.
    let elsewhere = home.join(".claude/skills/gh/SKILL.md");
    fs::create_dir_all(elsewhere.parent().unwrap()).unwrap();
    let plan = kendex_core::apply::Plan {
        scope: scope.clone(),
        ops: vec![kendex_core::apply::PlannedOp {
            description: "Write skill gh's files".into(),
            op: Op::WriteFile {
                path: elsewhere.clone(),
                bytes: b"---\nname: gh\n---\nBody.\n".to_vec(),
                pre: Pre::Any,
            },
        }],
    };
    // What an editor replacing the file mid-write leaves behind for an
    // instant: something that is there and cannot be read as text.
    fs::remove_file(&path).unwrap();
    fs::create_dir(&path).unwrap();

    let outcome = kendex_core::apply::execute(&env, &plan, None).unwrap();

    assert_eq!(outcome.applied, 1, "the op ran");
    assert!(elsewhere.is_file(), "and its bytes are on disk");
    assert_eq!(
        outcome.manifest_base, None,
        "with the one thing it could not answer said, not raised"
    );
}
