//! The two awkward shapes a tree laid out by an older tool turns up in: a
//! file where kendex writes a folder, and a folder where it writes a file.
//! Both are files kendex did not write, and both were conflicts with
//! nothing offered — the take-over said it moves what is in the way, and
//! then did not, for exactly the shapes a migration produces.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::{DriftState, PlanOptions, audit, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

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
