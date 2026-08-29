//! A harness directory somebody pointed somewhere else.
//!
//! The two answers pull against each other. A link inside the scope is a
//! layout, not an attack: the write goes where the link points and the plan
//! says so. A link that leaves the scope root is refused, and the refusal
//! names the place it would have written.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply::{self, Op};
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::model::Scope;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    home: PathBuf,
    project: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn put(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// A project declaring one skill from a path source beside it. The temp
/// root is resolved: on macOS it is reached through `/var -> private/var`,
/// and a fixture spelling the unresolved form would compare against
/// nothing the engine produces.
#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let project = home.join("dev/app");
    let source = home.join("catalog");
    put(
        &source.join("skills/ship/SKILL.md"),
        "---\nname: ship\ndescription: ship\n---\n\nShip the branch.\n",
    );
    put(
        &project.join("kendex.toml"),
        &format!(
            "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\n\n[skills.ship]\nsource = \"cat\"\n",
            source.display()
        ),
    );
    Fixture {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project {
            root: project.clone(),
        },
        home,
        project,
        _tmp: tmp,
    }
}

/// Point the shared tree's directory at `target`, the way a person who
/// keeps that folder somewhere else would.
#[allow(clippy::unwrap_used)]
fn link_agents_dir(f: &Fixture, target: &Path) {
    fs::create_dir_all(target).unwrap();
    std::os::unix::fs::symlink(target, f.project.join(".agents")).unwrap();
}

/// Where the plan says this skill's tree goes.
fn planned_tree(plan: &apply::Plan) -> Vec<PathBuf> {
    plan.ops
        .iter()
        .filter_map(|planned| match &planned.op {
            Op::WriteTree { root, .. } => Some(root.clone()),
            _ => None,
        })
        .collect()
}

/// A link inside the scope is followed: the bytes land at its target, and
/// the plan names that position rather than the spelling it was joined
/// from. A plan naming the joined spelling would describe a write that
/// happens elsewhere.
#[test]
#[allow(clippy::unwrap_used)]
fn a_link_inside_the_scope_is_written_through_and_planned_by_where_it_lands() {
    let f = fixture();
    let elsewhere = f.project.join("shared");
    link_agents_dir(&f, &elsewhere);

    let report = audit(&f.env, &f.scope).unwrap();
    assert_eq!(
        planned_tree(&report.plan),
        vec![elsewhere.join("skills/ship")],
        "the plan names the place the link points at"
    );

    apply::execute(&f.env, &report.plan, None).unwrap();
    assert_eq!(
        fs::read_to_string(elsewhere.join("skills/ship/SKILL.md")).unwrap(),
        "---\nname: ship\ndescription: ship\n---\n\nShip the branch.\n",
        "the bytes are through the link, at its target"
    );
}

/// A link that leaves the scope root is refused, naming where the write
/// would have gone, and nothing is written there.
#[test]
#[allow(clippy::unwrap_used)]
fn a_link_out_of_the_scope_is_refused_by_the_place_it_lands() {
    let f = fixture();
    let outside = f.home.join("victim");
    link_agents_dir(&f, &outside);

    let refused = audit(&f.env, &f.scope).unwrap_err();
    let CoreError::ScopeEscape { landed, root, .. } = refused else {
        panic!("a write out of the scope must be refused: {refused}");
    };
    assert_eq!(landed, outside.join("skills/ship"));
    assert_eq!(root, f.project);
    assert!(
        !outside.join("skills").exists(),
        "the refusal wrote nothing at the far end"
    );
}

/// The record's own paths are held to the same rule. A lock names a
/// position under the project, and the write it licenses is a removal —
/// so a directory on the way to it that points out of the project takes a
/// tree at the far end unless the landing is judged.
#[test]
#[allow(clippy::unwrap_used)]
fn a_recorded_path_that_now_lands_outside_takes_nothing_with_it() {
    let f = fixture();
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();

    // The same position the lock recorded, reached through a link out of
    // the project, with somebody else's tree at the end of it.
    let victim = f.home.join("victim");
    put(&victim.join("skills/ship/SKILL.md"), "Not kendex's.\n");
    fs::remove_dir_all(f.project.join(".agents")).unwrap();
    std::os::unix::fs::symlink(&victim, f.project.join(".agents")).unwrap();

    put(
        &f.project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\"]\n",
    );
    let refused = kendex_core::engine::plan_apply(
        &f.env,
        &f.scope,
        &kendex_core::engine::PlanOptions {
            remove_orphans: true,
            removal_filter: Some(vec!["ship".into()]),
            ..kendex_core::engine::PlanOptions::default()
        },
    )
    .unwrap_err();
    let CoreError::ScopeEscape { landed, .. } = refused else {
        panic!("a removal landing out of the scope must be refused: {refused}");
    };
    assert_eq!(landed, victim.join("skills/ship"));
    assert_eq!(
        fs::read_to_string(victim.join("skills/ship/SKILL.md")).unwrap(),
        "Not kendex's.\n"
    );
}
