//! The two awkward shapes a tree laid out by an older tool turns up in: a
//! file where kendex writes a folder, and a folder where it writes a file.
//! Both are files kendex did not write, and both were conflicts with
//! nothing offered — the take-over said it moves what is in the way, and
//! then did not, for exactly the shapes a migration produces.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::adopt::adopt;
use kendex_core::engine::{DriftCause, DriftState, PlanOptions, audit, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{HarnessId, ItemKind, Scope};

const BEFORE: &str = "laid out by the tool that came before";

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    scope: Scope,
}

/// A catalog offering one skill (a tree) and one agent (a file), and a
/// project asking for the one the test is about.
#[allow(clippy::unwrap_used)]
fn world(body: &str) -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nUpstream.\n",
    )
    .unwrap();
    fs::create_dir_all(catalog.join("agents")).unwrap();
    fs::write(
        catalog.join("agents/scout.md"),
        "---\nname: scout\ndescription: looks around\n---\nUpstream.\n",
    )
    .unwrap();
    let project = home.join("app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n{body}",
            catalog.display()
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

/// The same catalog, shared between two tools through one tree.
#[allow(clippy::unwrap_used)]
fn shared(body: &str) -> World {
    let w = world(body);
    let toml = fs::read_to_string(w.home.join("app/kendex.toml")).unwrap();
    fs::write(
        w.home.join("app/kendex.toml"),
        toml.replace(
            "harnesses = [\"claude\"]",
            "harnesses = [\"claude\", \"codex\"]",
        )
        .replace("method = \"copy\"", "method = \"symlink\""),
    )
    .unwrap();
    w
}

fn take_over() -> PlanOptions {
    PlanOptions {
        replace_unmanaged: true,
        ..PlanOptions::default()
    }
}

/// Whether what was in the way is recoverable.
#[allow(clippy::unwrap_used)]
fn trashed(dir: &Path) -> bool {
    let Ok(entries) = fs::read_dir(dir) else {
        return false;
    };
    entries.flatten().any(|entry| {
        let path = entry.path();
        match path.is_dir() {
            true => trashed(&path),
            false => fs::read_to_string(&path)
                .map(|text| text.contains(BEFORE))
                .unwrap_or(false),
        }
    })
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_file_where_a_tree_goes_is_taken_over_too() {
    let w = world("[skills.deploy]\nsource = \"cat\"\n");
    let position = w.home.join("app/.claude/skills/deploy");
    fs::create_dir_all(position.parent().unwrap()).unwrap();
    fs::write(&position, BEFORE).unwrap();

    let refused = audit(&w.env, &w.scope).unwrap();
    assert!(
        refused
            .drift
            .iter()
            .any(|row| row.name == "deploy" && row.state == DriftState::Conflict),
        "refused on its own, as it always was: {:?}",
        refused.drift
    );

    let report = plan_apply(&w.env, &w.scope, &take_over()).unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();
    assert!(
        fs::read_to_string(position.join("SKILL.md"))
            .unwrap()
            .contains("Upstream."),
        "the folder lands where the file was"
    );
    assert!(trashed(&w.env.trash_dir()), "and the file is recoverable");
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_directory_where_a_file_goes_is_taken_over_too() {
    let w = world("[agents.scout]\nsource = \"cat\"\n");
    let position = w.home.join("app/.claude/agents/scout.md");
    fs::create_dir_all(&position).unwrap();
    fs::write(position.join("notes.md"), BEFORE).unwrap();

    let refused = audit(&w.env, &w.scope).unwrap();
    assert!(
        refused
            .drift
            .iter()
            .any(|row| row.name == "scout" && row.state == DriftState::Conflict),
        "refused on its own, as it always was: {:?}",
        refused.drift
    );

    let report = plan_apply(&w.env, &w.scope, &take_over()).unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();
    assert!(
        fs::read_to_string(&position).unwrap().contains("Upstream."),
        "the file lands where the folder was"
    );
    assert!(trashed(&w.env.trash_dir()), "and the folder is recoverable");
}

/// Two tools reading one tree both arrive at the same wrong-shaped
/// position. Only the tool that claims it plans anything for it: a second
/// trash op for a path the first one already emptied fails its
/// precondition, rolls the whole apply back, and re-planning produces the
/// same pair — a dead end of exactly the kind this feature exists to end.
#[test]
#[allow(clippy::unwrap_used)]
fn one_tree_shared_by_two_tools_is_moved_aside_once() {
    let w = shared("[skills.deploy]\nsource = \"cat\"\n");
    let canonical = w.home.join("app/.agents/skills/deploy");
    fs::create_dir_all(canonical.parent().unwrap()).unwrap();
    fs::write(&canonical, BEFORE).unwrap();

    let report = plan_apply(&w.env, &w.scope, &take_over()).unwrap();
    let moves = report
        .plan
        .ops
        .iter()
        .filter(|op| op.description.starts_with("Move the files already at"))
        .count();
    assert_eq!(moves, 1, "{:?}", report.plan.ops);
    apply::execute(&w.env, &report.plan, None).unwrap();
    assert!(
        fs::read_to_string(canonical.join("SKILL.md"))
            .unwrap()
            .contains("Upstream.")
    );
    assert!(trashed(&w.env.trash_dir()));
}

/// Both awkward shapes are unmanaged content, so both carry the cause the
/// surfaces read to offer the ways out. Without it the app showed neither
/// choice and the CLI printed neither remedy, for shapes the take-over
/// handles perfectly well.
/// A file where a folder goes is files kendex did not write, and the
/// replacement handles it — but adoption puts a folder in the local source
/// and cannot read one file as one, so the row must not offer to keep it.
/// The cause is what both surfaces read to decide, and asserting adoption
/// itself refuses is what keeps the offer and the action from drifting
/// apart.
#[test]
#[allow(clippy::unwrap_used)]
fn a_file_where_a_folder_goes_is_never_offered_the_keep() {
    let w = world("[skills.deploy]\nsource = \"cat\"\n");
    let position = w.home.join("app/.claude/skills/deploy");
    fs::create_dir_all(position.parent().unwrap()).unwrap();
    fs::write(&position, BEFORE).unwrap();

    let row = audit(&w.env, &w.scope).unwrap();
    let row = row.drift.iter().find(|row| row.name == "deploy").unwrap();
    assert_eq!(row.state, DriftState::Conflict);
    assert_eq!(row.cause, Some(DriftCause::UnmanagedWrongShape), "{row:?}");
    assert_eq!(row.detail, position.display().to_string());
    assert!(!row.cause.unwrap().can_keep());
    assert!(row.cause.unwrap().can_replace());
    assert!(
        adopt(
            &w.env,
            &w.scope,
            ItemKind::Skill,
            "deploy",
            &[HarnessId::Claude]
        )
        .is_err(),
        "the gate and what adoption can take have drifted apart"
    );
}

/// The other way round — a folder where one file goes — is the same state
/// with the same exits: replaceable, never keepable.
#[test]
#[allow(clippy::unwrap_used)]
fn a_folder_where_a_file_goes_is_never_offered_the_keep() {
    let w = world("[agents.scout]\nsource = \"cat\"\n");
    let position = w.home.join("app/.claude/agents/scout.md");
    fs::create_dir_all(&position).unwrap();
    fs::write(position.join("notes.md"), BEFORE).unwrap();

    let row = audit(&w.env, &w.scope).unwrap();
    let row = row.drift.iter().find(|row| row.name == "scout").unwrap();
    assert_eq!(row.state, DriftState::Conflict);
    assert_eq!(row.cause, Some(DriftCause::UnmanagedWrongShape), "{row:?}");
    assert_eq!(row.detail, position.display().to_string());
    assert!(!row.cause.unwrap().can_keep());
    assert!(
        adopt(
            &w.env,
            &w.scope,
            ItemKind::Agent,
            "scout",
            &[HarnessId::Claude]
        )
        .is_err(),
        "the gate and what adoption can take have drifted apart"
    );
}

/// A repo mid-migration is normally blocked for one tool and clean for
/// another, so the conflict and the write sit a few lines apart under one
/// name. The write says which tool it is for, or a reader just told deploy
/// is blocked reads it as the write that was refused.
#[test]
#[allow(clippy::unwrap_used)]
fn a_tree_write_says_which_tool_it_is_for() {
    let w = shared("[skills.deploy]\nsource = \"cat\"\n");
    let blocked = w.home.join("app/.claude/skills/deploy");
    fs::create_dir_all(&blocked).unwrap();
    fs::write(blocked.join("SKILL.md"), BEFORE).unwrap();

    let report = plan_apply(&w.env, &w.scope, &PlanOptions::default()).unwrap();
    let written: Vec<&String> = report
        .plan
        .ops
        .iter()
        .map(|op| &op.description)
        .filter(|line| line.contains("deploy's files"))
        .collect();
    assert_eq!(
        written,
        vec!["Write skill deploy's files for Codex"],
        "{:?}",
        report.plan.ops
    );
}
