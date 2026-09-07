//! The path an agent is told to read a required skill from is the place
//! that skill's own delivery wrote.
//!
//! `render::agent::skill_root` answers in the short spelling an agent
//! reads — `~/.codex/skills`, not an absolute fixture path — so it cannot
//! call the adapter surfaces directly. This holds the copy half of its
//! table to `own_dir`, which is where a copy delivery actually writes: the
//! two are one answer or the prose sends an agent to a path nothing wrote.
#![cfg(unix)]

use std::path::{Path, PathBuf};

use kendex_core::engine::desired::own_dir;
use kendex_core::env::{Env, FakeOs};
use kendex_core::manifest::Method;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::render::agent::skill_root;

/// The prose spelling of a path under the fixture's home or project root.
fn shown(path: &Path, home: &Path, project: &Path) -> String {
    match path.strip_prefix(project) {
        Ok(rest) => rest.display().to_string(),
        Err(_) => match path.strip_prefix(home) {
            Ok(rest) => format!("~/{}", rest.display()),
            Err(_) => path.display().to_string(),
        },
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_copy_roots_are_the_places_a_copy_delivery_writes() {
    let home = PathBuf::from("/h");
    let project = PathBuf::from("/p");
    let env = Env::fake(&home, FakeOs::Linux);
    let scopes = [
        Scope::Project {
            root: project.clone(),
        },
        Scope::Global,
    ];

    for scope in &scopes {
        for harness in HarnessId::ALL {
            // Cursor holds no global skills, so a copy writes nothing and
            // there is no directory for the prose to name.
            let Some(dir) = own_dir(&env, scope, harness, ItemKind::Skill) else {
                continue;
            };
            assert_eq!(
                skill_root(harness, scope, Method::Copy),
                shown(&dir, &home, &project),
                "{harness:?} at {scope:?}"
            );
        }
    }
}
