//! Moving pi hooks out of the directory name Pi reserved: what kendex may
//! take, what it must leave, and what it has to say about the difference.
#![cfg(unix)]

use std::fs;

use std::path::PathBuf;

use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

mod held_back;
mod strangers;

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    project: PathBuf,
    catalog: PathBuf,
}

impl World {
    fn dot(&self) -> PathBuf {
        self.project.join(".pi")
    }

    fn scope(&self) -> Scope {
        Scope::Project {
            root: self.project.clone(),
        }
    }
}

#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let project = home.join("app");
    fs::create_dir_all(project.join(".pi")).unwrap();
    fs::write(
        project.join(".pi/settings.json"),
        r#"{ "packages": ["./packages/pi-hooks"] }"#,
    )
    .unwrap();
    let catalog = home.join("cat");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        catalog.join("hooks/guard.sh"),
        "#!/bin/sh\n# ---\n# name: guard\n# event: PreToolUse\n# description: a guard\n# harnesses: [pi]\n# ---\nexit 0\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"pi\"]\nmethod = \"symlink\"\n\n[hooks.guard]\nsource = \"cat\"\n",
            catalog.display()
        ),
    )
    .unwrap();
    World {
        env: Env::fake(&home, FakeOs::Linux),
        home,
        project,
        catalog,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn apply(w: &World) {
    let report = audit(&w.env, &w.scope()).unwrap();
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();
}

#[allow(clippy::unwrap_used)]
fn notes(w: &World) -> Vec<String> {
    audit(&w.env, &w.scope()).unwrap().notes
}

/// A second hook, so a held file has a sibling that still moves.
#[allow(clippy::unwrap_used)]
fn declare_second_hook(w: &World) {
    fs::write(
        w.catalog.join("hooks/other.sh"),
        "#!/bin/sh\n# ---\n# name: other\n# event: Stop\n# description: another guard\n# harnesses: [pi]\n# ---\nexit 0\n",
    )
    .unwrap();
    let manifest = w.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        format!("{text}\n[hooks.other]\nsource = \"cat\"\n"),
    )
    .unwrap();
}

/// One hook's artifacts, put back under the reserved name.
#[allow(clippy::unwrap_used)]
fn regress(w: &World, name: &str) {
    let dot = w.dot();
    fs::create_dir_all(dot.join("hooks")).unwrap();
    fs::rename(
        dot.join(format!("kendex/hooks/{name}.sh")),
        dot.join(format!("hooks/{name}.sh")),
    )
    .unwrap();
    let registry = fs::read_to_string(dot.join("kendex/hooks.json")).unwrap();
    fs::write(
        dot.join("hooks.json"),
        registry.replace(".pi/kendex/hooks/", ".pi/hooks/"),
    )
    .unwrap();
}

/// A world already installed at the new paths, then regressed to the
/// layout an earlier kendex wrote — so the lock records exactly what a
/// real one would, and the registry spells the old command.
#[allow(clippy::unwrap_used)]
fn regressed() -> World {
    let w = world();
    apply(&w);
    let dot = w.dot();
    fs::create_dir_all(dot.join("hooks")).unwrap();
    fs::rename(
        dot.join("kendex/hooks/guard.sh"),
        dot.join("hooks/guard.sh"),
    )
    .unwrap();
    let registry = fs::read_to_string(dot.join("kendex/hooks.json")).unwrap();
    fs::write(
        dot.join("hooks.json"),
        registry.replace(".pi/kendex/hooks/", ".pi/hooks/"),
    )
    .unwrap();
    fs::remove_dir_all(dot.join("kendex")).unwrap();
    w
}

/// Drop the record of what apply wrote, as a lock from before that record
/// existed carries it.
#[allow(clippy::unwrap_used)]
fn forget_rendered_hash(w: &World) {
    let path = w.project.join(".kendex-lock.json");
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    lock["entries"]["hook:guard:pi"]
        .as_object_mut()
        .unwrap()
        .remove("renderedHash");
    fs::write(&path, serde_json::to_string_pretty(&lock).unwrap()).unwrap();
}

fn about(notes: &[String], needle: &str) -> Vec<String> {
    notes
        .iter()
        .filter(|note| note.contains(needle))
        .cloned()
        .collect()
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_older_install_in_the_reserved_directory_moves_out_of_it() {
    let w = regressed();
    apply(&w);

    assert!(
        !w.dot().join("hooks").exists(),
        "the directory itself has to go: pi's check never looks inside it"
    );
    assert!(!w.dot().join("hooks.json").exists());
    assert!(w.dot().join("kendex/hooks/guard.sh").is_file());
    let registry = fs::read_to_string(w.dot().join("kendex/hooks.json")).unwrap();
    assert!(
        registry.contains("kendex/hooks/guard.sh"),
        "the carrier is pointed at the new path: {registry}"
    );

    // Settled: the move retires itself instead of re-planning forever.
    let report = audit(&w.env, &w.scope()).unwrap();
    assert!(report.plan.ops.is_empty(), "{:?}", report.plan.ops);
    assert!(report.notes.is_empty(), "{:?}", report.notes);
}
