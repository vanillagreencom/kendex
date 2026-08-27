//! What a plan says about the packages it takes away that declared an
//! effect on the repository.
//!
//! The add side reads declarations off the bytes it is about to write. A
//! removal has no such bytes — the item is gone from the desired state —
//! so the declaration is read off the tree still on disk, and the report
//! carries it for the one window in which the uninstaller can still run.
#![cfg(unix)]

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::{audit, ops};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let source = home.join("catalog");
    let armer = source.join("skills/armer");
    fs::create_dir_all(armer.join("scripts")).unwrap();
    fs::write(
        armer.join("SKILL.md"),
        "---\nname: armer\ndescription: arms something\nrepo-effects:\n  summary: \"arms the repository\"\n  installer: \"scripts/arm\"\n  uninstaller: \"scripts/arm --off\"\n---\nBody.\n",
    )
    .unwrap();
    fs::write(armer.join("scripts/arm"), "#!/bin/sh\nexit 0\n").unwrap();
    let quiet = source.join("skills/quiet");
    fs::create_dir_all(&quiet).unwrap();
    fs::write(
        quiet.join("SKILL.md"),
        "---\nname: quiet\ndescription: changes nothing\n---\nBody.\n",
    )
    .unwrap();

    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.armer]\nsource = \"cat\"\n\n[skills.quiet]\nsource = \"cat\"\n",
            source.display()
        ),
    )
    .unwrap();

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        _tmp: tmp,
    }
}

/// The removal carries the declaration, read off the installed tree,
/// rooted where the uninstaller resolves — and only for a package that
/// declared one.
#[test]
#[allow(clippy::unwrap_used)]
fn a_removal_carries_the_effects_of_what_it_takes_away() {
    let f = fixture();
    let install = audit(&f.env, &f.scope).unwrap();
    assert_eq!(install.repo_effects.len(), 1, "{:?}", install.repo_effects);
    assert!(
        install.repo_effects_leaving.is_empty(),
        "an install has nothing leaving: {:?}",
        install.repo_effects_leaving
    );
    apply::execute(&f.env, &install.plan, None).unwrap();

    let quiet = ops::remove(&f.env, &f.scope, &["quiet".to_owned()], None, false).unwrap();
    assert!(
        quiet.repo_effects_leaving.is_empty(),
        "a package that declared nothing has nothing to undo: {:?}",
        quiet.repo_effects_leaving
    );

    let removal = ops::remove(&f.env, &f.scope, &["armer".to_owned()], None, false).unwrap();
    assert!(
        removal.repo_effects.is_empty(),
        "a removal offers nothing to arm: {:?}",
        removal.repo_effects
    );
    let [leaving] = removal.repo_effects_leaving.as_slice() else {
        panic!(
            "expected one leaving effect: {:?}",
            removal.repo_effects_leaving
        );
    };
    assert_eq!(leaving.name, "armer");
    assert_eq!(leaving.root, f.project.join(".agents/skills/armer"));
    assert_eq!(
        leaving.effects.uninstaller.as_deref(),
        Some("scripts/arm --off")
    );
    assert!(
        leaving.root.join("scripts/arm").is_file(),
        "the script is still there to run while the plan is only planned"
    );

    // Once the plan has executed there is nothing left to leave.
    apply::execute(&f.env, &removal.plan, None).unwrap();
    let after = audit(&f.env, &f.scope).unwrap();
    assert!(
        after.repo_effects_leaving.is_empty(),
        "{:?}",
        after.repo_effects_leaving
    );
}
