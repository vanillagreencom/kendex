//! What a plan says about the packages it takes away that declared an
//! effect on the repository.
//!
//! The add side reads declarations off the bytes it is about to write. A
//! removal has no such bytes — the item is gone from the desired state —
//! so the declaration is read off the tree still on disk, and the report
//! carries it for the one window in which the uninstaller can still run.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

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
    // Resolved, because every engine entry point resolves the scope root
    // it is handed and then reports the paths it read. On macOS the temp
    // directory is reached through `/var -> private/var`, so an unresolved
    // fixture path is a second spelling of the same place and every
    // path equality here compares the two.
    let home = tmp.path().canonicalize().unwrap();
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
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.armer]\nsource = \"cat\"\n\n[skills.quiet]\nsource = \"cat\"\n",
            source_path(&source)
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
    apply::execute(&f.env, &install.plan).unwrap();

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
    apply::execute(&f.env, &removal.plan).unwrap();
    let after = audit(&f.env, &f.scope).unwrap();
    assert!(
        after.repo_effects_leaving.is_empty(),
        "{:?}",
        after.repo_effects_leaving
    );
}

/// A declaration that will not read stops the removal, with everything the
/// package left behind still in place.
///
/// The armed shim is the reason. Reading a malformed declaration as "this
/// package declares nothing" is a removal that runs no uninstaller and
/// takes the scripts away regardless, and every commit in the repository
/// then fails on a hook delegating to a file that is gone. A locally
/// edited `SKILL.md` gets there: the frontmatter no longer parses, and the
/// removal discards the edit anyway.
#[test]
#[allow(clippy::unwrap_used)]
fn a_declaration_that_will_not_read_stops_the_removal() {
    let f = fixture();
    let install = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &install.plan).unwrap();

    let tree = f.project.join(".agents/skills/armer");
    let hooks = f.project.join(".git/hooks");
    fs::create_dir_all(&hooks).unwrap();
    let shim = hooks.join("pre-commit");
    fs::write(&shim, "#!/bin/sh\nexec .agents/skills/armer/scripts/arm\n").unwrap();

    // The declaration is edited on disk into frontmatter that will not
    // parse — the block is still there, and kendex can no longer read it.
    let declaration = tree.join("SKILL.md");
    let edited = fs::read_to_string(&declaration)
        .unwrap()
        .replace("  installer:", " installer: \"unclosed\n  quoted:");
    fs::write(&declaration, &edited).unwrap();

    let error = ops::remove(&f.env, &f.scope, &["armer".to_owned()], None, false)
        .expect_err("a declaration kendex cannot read was read as declaring nothing");
    let said = error.to_string();
    assert!(
        said.contains("SKILL.md") && said.contains("repo-effects"),
        "the error names neither the file nor why: {said}"
    );

    assert!(
        tree.join("scripts/arm").is_file(),
        "the scripts the shim delegates to are gone"
    );
    assert!(shim.is_file(), "the armed hook outlived its script");
    assert!(
        fs::read_to_string(f.project.join("kendex.toml"))
            .unwrap()
            .contains("[skills.armer]"),
        "the manifest forgot a package that is still installed"
    );
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(&f.env, &f.scope)).unwrap();
    assert!(
        lock.entries.values().any(|entry| entry.name == "armer"),
        "the lock forgot a package that is still installed"
    );
}
