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

/// The place a refused op's path now reaches, when that is why it was
/// refused.
fn moved_target(error: &CoreError) -> Option<PathBuf> {
    match error {
        // Refused as its op's turn came, so the transaction rolled back
        // what ran before it.
        CoreError::RolledBack { cause, .. } => moved_target(cause),
        CoreError::TargetMoved { now, .. } => Some(now.clone()),
        _ => None,
    }
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

/// Where the plan puts this skill's harness link.
fn planned_links(plan: &apply::Plan) -> Vec<PathBuf> {
    plan.ops
        .iter()
        .filter_map(|planned| match &planned.op {
            Op::Symlink { link, .. } => Some(link.clone()),
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

/// Between the plan and the apply the project directory is renamed and a
/// link left in its place. Every planned path still spells the old
/// project, so nothing about it reads as outside a scope root; what says
/// so is that the paths no longer land where the plan put them.
#[test]
#[allow(clippy::unwrap_used)]
fn a_project_directory_swapped_for_a_link_stops_the_apply() {
    let f = fixture();
    let report = audit(&f.env, &f.scope).unwrap();

    let moved = f.home.join("moved");
    let victim = f.home.join("victim");
    fs::create_dir_all(&victim).unwrap();
    fs::rename(&f.project, &moved).unwrap();
    std::os::unix::fs::symlink(&victim, &f.project).unwrap();

    let refused = apply::execute(&f.env, &report.plan, None).unwrap_err();
    assert!(
        matches!(moved_target(&refused), Some(now) if now.starts_with(&victim)),
        "the refusal names where the write would have gone: {refused}"
    );
    assert!(
        !victim.join(".agents").exists(),
        "nothing was written through the replacement link"
    );
}

/// The same swap, to a folder still inside the project. Containment holds
/// the whole way through, so only comparing against the landing the plan
/// showed catches it.
#[test]
#[allow(clippy::unwrap_used)]
fn an_ancestor_swapped_for_a_link_inside_the_project_stops_the_apply() {
    let f = fixture();
    let report = audit(&f.env, &f.scope).unwrap();

    let elsewhere = f.project.join("elsewhere");
    fs::create_dir_all(&elsewhere).unwrap();
    std::os::unix::fs::symlink(&elsewhere, f.project.join(".agents")).unwrap();

    let refused = apply::execute(&f.env, &report.plan, None).unwrap_err();
    assert_eq!(
        moved_target(&refused),
        Some(elsewhere.join("skills/ship")),
        "the refusal names the position inside the project the write moved to: {refused}"
    );
    assert!(
        !elsewhere.join("skills").exists(),
        "the write did not follow the link"
    );
}

/// One op in the plan makes the link the next op's path would be reached
/// through. Nothing is wrong when the plan is made, which is why the
/// question is asked again as each op's turn comes.
#[test]
#[allow(clippy::unwrap_used)]
fn a_link_an_earlier_op_creates_stops_the_op_behind_it() {
    let f = fixture();
    let victim = f.home.join("victim");
    fs::create_dir_all(&victim).unwrap();
    let link = f.project.join("link");

    let plan = apply::Plan::landed(
        f.scope.clone(),
        vec![
            apply::PlannedOp {
                description: "make the link".into(),
                op: Op::Symlink {
                    link: link.clone(),
                    target: victim.clone(),
                    pre: apply::Pre::Absent,
                },
            },
            apply::PlannedOp {
                description: "write behind it".into(),
                op: Op::WriteFile {
                    path: link.join("taken"),
                    bytes: b"kendex's".to_vec(),
                    pre: apply::Pre::Absent,
                },
            },
        ],
    )
    .unwrap();

    let refused = apply::execute(&f.env, &plan, None).unwrap_err();
    assert_eq!(
        moved_target(&refused),
        Some(victim.join("taken")),
        "the second op is refused by where its path now reaches: {refused}"
    );
    assert!(!victim.join("taken").exists(), "nothing was written there");
    assert!(
        !link.exists() && !link.is_symlink(),
        "the first op rolled back"
    );
}

/// A link the landing moved has to keep meaning what it meant. Its text is
/// read from the parent it sits in, and landing gave it another one.
#[test]
#[allow(clippy::unwrap_used)]
fn a_link_the_landing_moved_still_reaches_the_tree_it_named() {
    let f = fixture();
    let shared = f.project.join("shared");
    fs::create_dir_all(&shared).unwrap();
    fs::create_dir_all(f.project.join(".claude")).unwrap();
    std::os::unix::fs::symlink(&shared, f.project.join(".claude/skills")).unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();

    let landed = shared.join("ship");
    assert!(
        landed.is_symlink(),
        "the link landed through .claude/skills"
    );
    let destination = fs::canonicalize(&landed).unwrap();
    assert_eq!(
        destination,
        fs::canonicalize(f.project.join(".agents/skills/ship")).unwrap(),
        "it reaches the tree it was made to reach"
    );
    assert_eq!(
        fs::read_to_string(landed.join("SKILL.md")).unwrap(),
        "---\nname: ship\ndescription: ship\n---\n\nShip the branch.\n",
    );
}

/// An apply that never finished leaves pre-images to put back. They go
/// back where they were taken from, so a directory swapped for a link in
/// the meantime stops the restore rather than sending somebody's bytes
/// through it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_restore_whose_path_moved_is_refused_and_leaves_the_journal() {
    let f = fixture();
    let held = f.project.join(".agents/skills/ship/SKILL.md");
    put(&held, "the bytes an apply would put back\n");

    // What an apply that died mid-write leaves behind.
    let dir = apply::journal::journal_dir_for(&f.env.journal_dir(), &apply::scope_key(&f.scope));
    apply::journal::write(&dir, &[held.clone()]).unwrap();

    let victim = f.home.join("victim");
    fs::create_dir_all(&victim).unwrap();
    fs::remove_dir_all(f.project.join(".agents")).unwrap();
    std::os::unix::fs::symlink(&victim, f.project.join(".agents")).unwrap();

    let refused = apply::recover(&f.env, &f.scope).unwrap_err();
    assert_eq!(
        moved_target(&refused),
        Some(victim.join("skills/ship/SKILL.md")),
        "the restore is refused by where the path now reaches: {refused}"
    );
    assert!(
        !victim.join("skills").exists(),
        "nothing was restored through the link"
    );
    assert!(
        apply::journal::pending(&dir),
        "the journal stands, for a person to look at"
    );
}

/// The dotfiles shape at global scope: the harness directory is a link
/// into a repository the person keeps their config in. Nothing encloses
/// the global scope, so there is no root for the write to leave — it goes
/// where the link points, and the plan says so.
#[test]
#[allow(clippy::unwrap_used)]
fn a_global_harness_directory_kept_in_a_dotfiles_repo_is_written_through() {
    let f = fixture();
    let dotfiles = f.home.join("dotfiles/.claude");
    fs::create_dir_all(dotfiles.join("skills")).unwrap();
    std::os::unix::fs::symlink(&dotfiles, f.home.join(".claude")).unwrap();
    put(
        &f.env.global_manifest_file(),
        &format!(
            "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\n\n[skills.ship]\nsource = \"cat\"\n",
            f.home.join("catalog").display()
        ),
    );

    let report = audit(&f.env, &Scope::Global).unwrap();
    assert_eq!(
        planned_links(&report.plan),
        vec![dotfiles.join("skills/ship")],
        "the plan names the place the link points at"
    );

    apply::execute(&f.env, &report.plan, None).unwrap();
    assert_eq!(
        fs::read_to_string(dotfiles.join("skills/ship/SKILL.md")).unwrap(),
        "---\nname: ship\ndescription: ship\n---\n\nShip the branch.\n",
        "the bytes are readable through the person's link"
    );
}
