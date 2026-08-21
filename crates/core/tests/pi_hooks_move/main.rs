//! Moving pi hooks out of the directory name Pi reserved: what kendex may
//! take, what it must leave, and what it has to say about the difference.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

mod asked_for;
mod custom;
mod gates;
mod global;
mod held_back;
mod links;
mod retirement;
mod strangers;
mod unreadable;

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

/// A source catalog carrying one pi hook and one agent.
#[allow(clippy::unwrap_used)]
fn catalog(home: &Path) -> PathBuf {
    let catalog = home.join("cat");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    fs::create_dir_all(catalog.join("agents")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        catalog.join("hooks/guard.sh"),
        "#!/bin/sh\n# ---\n# name: guard\n# event: PreToolUse\n# description: a guard\n# harnesses: [pi]\n# ---\nexit 0\n",
    )
    .unwrap();
    fs::write(
        catalog.join("agents/helper.md"),
        "---\nname: helper\ndescription: a helper\n---\n\nHelp.\n",
    )
    .unwrap();
    catalog
}

/// A project managing one pi hook, declared by the given manifest body.
#[allow(clippy::unwrap_used)]
fn world_declaring(body: &str) -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let project = home.join("app");
    fs::create_dir_all(project.join(".pi")).unwrap();
    fs::write(
        project.join(".pi/settings.json"),
        r#"{ "packages": ["./packages/pi-hooks"] }"#,
    )
    .unwrap();
    let catalog = catalog(&home);
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"pi\"]\nmethod = \"symlink\"\n\n{body}",
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

fn world() -> World {
    world_declaring("[hooks.guard]\nsource = \"cat\"\n")
}

/// A managed project with no pi hook at all — so the move runs with an
/// empty set of lock entries to claim anything by.
fn world_without_hooks() -> World {
    world_declaring("[agents.helper]\nsource = \"cat\"\n")
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

/// One hook's script, put back under the reserved name, and the registry
/// with it when the hook has one — a hook installed disabled does not.
#[allow(clippy::unwrap_used)]
fn regress(w: &World, file: &str) {
    let dot = w.dot();
    fs::create_dir_all(dot.join("hooks")).unwrap();
    fs::rename(
        dot.join("kendex/hooks").join(file),
        dot.join("hooks").join(file),
    )
    .unwrap();
    if let Ok(registry) = fs::read_to_string(dot.join("kendex/hooks.json")) {
        fs::write(
            dot.join("hooks.json"),
            registry.replace(".pi/kendex/hooks/", ".pi/hooks/"),
        )
        .unwrap();
    }
}

/// A world already installed at the new paths, then regressed to the
/// layout an earlier kendex wrote. A hook's lock entry records no path of
/// its own — no `emitted`, and `rendered_hash` is a hash of the script's
/// bytes — so the lock a current install writes is the same one an older
/// kendex wrote, and moving the files with the registry command rewritten
/// is the whole of the old layout.
#[allow(clippy::unwrap_used)]
fn regressed() -> World {
    let w = world();
    apply(&w);
    regress(&w, "guard.sh");
    fs::remove_dir_all(w.dot().join("kendex")).unwrap();
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

/// A hook installed disabled keeps its bytes under the `.disabled` name,
/// and that copy is kendex's too — read as a stranger it would keep the
/// reserved directory, and pi's warning, alive forever.
#[test]
#[allow(clippy::unwrap_used)]
fn a_disabled_hook_moves_under_its_disabled_name() {
    let w = world_declaring("[hooks.guard]\nsource = \"cat\"\nenabled = false\n");
    apply(&w);
    assert!(w.dot().join("kendex/hooks/guard.sh.disabled").is_file());
    regress(&w, "guard.sh.disabled");
    fs::remove_dir_all(w.dot().join("kendex")).unwrap();

    apply(&w);

    assert!(
        !w.dot().join("hooks").exists(),
        "the reserved directory goes with the file it held"
    );
    assert!(w.dot().join("kendex/hooks/guard.sh.disabled").is_file());
}
