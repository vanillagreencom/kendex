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

/// Where the plan says its file writes go.
fn planned_writes(plan: &apply::Plan) -> Vec<PathBuf> {
    plan.ops
        .iter()
        .filter_map(|planned| match &planned.op {
            Op::WriteFile { path, .. } => Some(path.clone()),
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

    apply::execute(&f.env, &report.plan).unwrap();
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
    apply::execute(&f.env, &report.plan).unwrap();

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
    apply::execute(&f.env, &report.plan).unwrap();

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

    apply::execute(&f.env, &report.plan).unwrap();
    assert_eq!(
        fs::read_to_string(dotfiles.join("skills/ship/SKILL.md")).unwrap(),
        "---\nname: ship\ndescription: ship\n---\n\nShip the branch.\n",
        "the bytes are readable through the person's link"
    );
}

/// The line a confirmation draws names the place the write goes. A person
/// approving a preview is approving what it says, so the position in the
/// sentence and the position in the op cannot be two different places.
#[test]
#[allow(clippy::unwrap_used)]
fn the_line_a_confirmation_draws_names_the_landed_position() {
    let f = fixture();
    let elsewhere = f.project.join("shared");
    link_agents_dir(&f, &elsewhere);
    // Somebody else's files, sitting where the declaration installs.
    put(&elsewhere.join("skills/ship/SKILL.md"), "Not kendex's.\n");

    let report = kendex_core::engine::plan_apply(
        &f.env,
        &f.scope,
        &kendex_core::engine::PlanOptions {
            replace_unmanaged: true,
            ..kendex_core::engine::PlanOptions::default()
        },
    )
    .unwrap();
    let lines: Vec<String> = report.plan.ops.iter().map(apply::PlannedOp::line).collect();
    assert!(
        lines.contains(&format!(
            "Move the files already at {} to the trash",
            elsewhere.join("skills/ship").display()
        )),
        "the line names where the trashing happens: {lines:?}"
    );
}

/// An op joining a plan after it was made is landed like every op that
/// arrived with it.
#[test]
#[allow(clippy::unwrap_used)]
fn an_op_joining_a_plan_is_landed_against_the_root_the_plan_fixed() {
    let f = fixture();
    let elsewhere = f.project.join("shared");
    link_agents_dir(&f, &elsewhere);

    let mut plan = apply::Plan::landed(f.scope.clone(), Vec::new()).unwrap();
    plan.insert(
        0,
        apply::PlannedOp {
            description: apply::Description::around("write at ", ""),
            op: Op::WriteFile {
                path: f.project.join(".agents/late"),
                bytes: b"late".to_vec(),
                pre: apply::Pre::Absent,
            },
        },
    )
    .unwrap();

    assert_eq!(
        planned_writes(&plan),
        vec![elsewhere.join("late")],
        "the op that joined late lands like the rest"
    );
    assert_eq!(
        plan.ops[0].line(),
        format!("write at {}", elsewhere.join("late").display()),
    );
}

/// The root a plan was made with is the root an op joining it is held to.
/// Re-deriving one now would read it after the swap, and the write would
/// go wherever the replacement points.
#[test]
#[allow(clippy::unwrap_used)]
fn an_op_joining_a_plan_after_the_project_was_swapped_is_refused() {
    let f = fixture();
    let mut plan = apply::Plan::landed(f.scope.clone(), Vec::new()).unwrap();

    let moved = f.home.join("moved");
    let victim = f.home.join("victim");
    fs::create_dir_all(&victim).unwrap();
    fs::rename(&f.project, &moved).unwrap();
    std::os::unix::fs::symlink(&victim, &f.project).unwrap();

    // Derived now, the way a caller inserting a record write derives it:
    // through the scope, which reads the replacement.
    let path = kendex_core::manifest::manifest_path(&f.env, &f.scope);
    assert!(path.starts_with(&victim), "the caller derived {path:?}");

    let refused = plan
        .insert(
            0,
            apply::PlannedOp {
                description: "save the record at {}".into(),
                op: Op::WriteFile {
                    path,
                    bytes: b"schema = 6\n".to_vec(),
                    pre: apply::Pre::Absent,
                },
            },
        )
        .unwrap_err();
    assert!(
        matches!(refused, CoreError::ScopeEscape { .. }),
        "an op joining this plan must land inside the root it fixed: {refused}"
    );
    assert!(plan.ops.is_empty(), "nothing joined the plan");
    assert!(!victim.join("kendex.toml").exists());
}

/// A raw `..` that no existing directory resolves away is refused on the
/// way in, so an op cannot walk out of the plan's root by spelling.
#[test]
#[allow(clippy::unwrap_used)]
fn an_op_joining_a_plan_cannot_walk_out_of_its_root() {
    let f = fixture();
    let mut plan = apply::Plan::landed(f.scope.clone(), Vec::new()).unwrap();

    let refused = plan
        .insert(
            0,
            apply::PlannedOp {
                description: "write at {}".into(),
                op: Op::WriteFile {
                    path: f.project.join("absent/../../victim"),
                    bytes: b"taken".to_vec(),
                    pre: apply::Pre::Absent,
                },
            },
        )
        .unwrap_err();
    assert!(
        matches!(refused, CoreError::ScopeEscape { .. }),
        "{refused}"
    );
    assert!(plan.ops.is_empty(), "nothing joined the plan");
}

/// A name is content, and a preview draws it whole. The position an op
/// acts on is not something to go looking for in the sentence — any token
/// worth searching for is a token some name is allowed to be, and `{}` is
/// a name kendex accepts.
#[test]
#[allow(clippy::unwrap_used)]
fn a_name_that_reads_like_a_slot_is_drawn_as_itself() {
    let f = fixture();
    put(
        &f.home.join("catalog/skills/{}/SKILL.md"),
        "---\nname: \"{}\"\ndescription: braces\n---\n\nBraces.\n",
    );
    put(
        &f.project.join("kendex.toml"),
        &format!(
            "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\n\n[skills.\"{{}}\"]\nsource = \"cat\"\n",
            f.home.join("catalog").display()
        ),
    );

    let report = audit(&f.env, &f.scope).unwrap();
    let lines: Vec<String> = report.plan.ops.iter().map(apply::PlannedOp::line).collect();
    assert!(
        lines.contains(
            &"Write skill {}'s files for Claude Code, in the folder its tools share".to_owned()
        ),
        "the name is drawn as itself: {lines:?}"
    );
}

/// A restore puts bytes back through a link that was there all along:
/// the journal records the caller's own spelling, and the pre-image goes
/// back at the place that spelling reaches.
#[test]
#[allow(clippy::unwrap_used)]
fn a_restore_reaches_through_a_link_that_never_moved() {
    let f = fixture();
    let elsewhere = f.project.join("shared");
    link_agents_dir(&f, &elsewhere);
    let held = f.project.join(".agents/skills/ship/SKILL.md");
    put(&held, "the bytes an apply would put back\n");

    // What an apply that died mid-write leaves behind, recorded at the
    // spelling its caller had.
    let dir = apply::journal::journal_dir_for(&f.env.journal_dir(), &apply::scope_key(&f.scope));
    apply::journal::write(&dir, &[held.clone()]).unwrap();
    fs::write(&held, "half-written\n").unwrap();

    assert!(apply::recover(&f.env, &f.scope).unwrap(), "recovery ran");
    assert_eq!(
        fs::read_to_string(elsewhere.join("skills/ship/SKILL.md")).unwrap(),
        "the bytes an apply would put back\n",
        "the pre-image is back at the place the link points at"
    );
    assert!(!apply::journal::pending(&dir), "the journal is spent");
}

/// A subscription's preview and its note name the file the write goes to.
///
/// Both are drawn from the op, so a config directory the person keeps
/// somewhere else cannot leave the two disagreeing — which is what a
/// spelling derived a second time, after the plan was landed, would do.
#[test]
#[allow(clippy::unwrap_used)]
fn a_subscription_says_the_file_its_write_lands_in() {
    let f = fixture();
    let dotfiles = f.home.join("dotfiles/config");
    fs::create_dir_all(dotfiles.join("kendex")).unwrap();
    std::os::unix::fs::symlink(&dotfiles, f.home.join(".config")).unwrap();

    let subscribed = kendex_core::source_ops::subscribe(
        &f.env,
        &Scope::Global,
        &f.home.join("catalog").display().to_string(),
        Some("cat"),
    )
    .unwrap();
    let derived = f.env.global_manifest_file();
    let landed = dotfiles.join("kendex").join(derived.file_name().unwrap());
    assert_ne!(
        derived, landed,
        "the config directory is reached through a link"
    );
    let said = subscribed
        .report
        .plan
        .ops
        .iter()
        .map(apply::PlannedOp::line)
        .find(|line| line.starts_with("Subscribes"))
        .expect("the subscription writes the manifest");

    assert!(
        said.ends_with(&landed.display().to_string()),
        "the preview names the file the write lands in: {said}"
    );
    assert!(
        subscribed.report.notes.contains(&said),
        "and the note says the same thing: {:?}",
        subscribed.report.notes
    );
}
