//! The desktop's account of what a package does to the repository, and the
//! yes that is separate from installing it.
//!
//! An install from the window is one command that plans and writes. The
//! effect a package declares must come back out of it unrun, with what a
//! person needs in order to decide — and arming is a second command, so a
//! window that closes the dialog leaves the repository as it was.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

use kendex_app::marketplaces::install::{InstallItem, install};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{ItemKind, Scope};

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = std::process::Command::new("git")
        .args(["-c", "user.email=t@t", "-c", "user.name=t"])
        .args(args)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[allow(clippy::unwrap_used)]
fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), &target).unwrap();
        }
    }
}

/// A git project subscribed to a catalog that offers the repository's own
/// growth-guards package beside an inert one, with Claude on the machine.
#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    let shipped = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../skills/growth-guards")
        .canonicalize()
        .unwrap();
    copy_tree(&shipped, &catalog.join("skills/growth-guards"));
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun the deploy.\n",
    )
    .unwrap();
    fs::create_dir_all(home.join(".claude")).unwrap();
    fs::create_dir_all(project.join(".agents")).unwrap();
    git(&project, &["init", "--quiet", "-b", "main"]);
    fs::write(project.join("README.md"), "the app\n").unwrap();
    git(&project, &["add", "."]);
    git(&project, &["commit", "--quiet", "-m", "start"]);
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\npath = \"{}\"\n",
            catalog.display()
        ),
    )
    .unwrap();
    Fixture {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        _tmp: tmp,
    }
}

fn install_skill(f: &Fixture, name: &str) -> kendex_app::marketplaces::install::Installed {
    install(
        &f.env,
        f.scope.clone(),
        "cat".to_owned(),
        vec![InstallItem {
            kind: ItemKind::Skill,
            name: name.to_owned(),
        }],
        None,
        None,
        false,
        None,
        None,
    )
    .unwrap_or_else(|error| panic!("install {name}: {error}"))
}

/// Installing writes the package and hands back its account — what
/// changes, where it writes, which companions are here, how to undo it —
/// with the repository untouched. The separate yes is what arms it.
#[test]
#[allow(clippy::unwrap_used)]
fn the_effect_comes_back_unrun_and_a_separate_yes_arms_it() {
    let f = fixture();
    let installed = install_skill(&f, "growth-guards");

    assert!(
        f.project
            .join(".agents/skills/growth-guards/scripts/install-git-hooks")
            .is_file(),
        "the package did not install"
    );
    assert!(
        !f.project.join(".git/hooks/kendex-guards").exists(),
        "the install armed the hooks with nobody asked"
    );
    assert!(
        installed.repo_effects.withheld.is_empty(),
        "{:?}",
        installed.repo_effects.withheld
    );
    let [offer] = installed.repo_effects.shown.as_slice() else {
        panic!("one offer: {:?}", installed.repo_effects);
    };
    assert_eq!(offer.declared.name, "growth-guards");
    assert!(offer.declared.effects.summary.contains("every commit"));
    let hooks = f.project.join(".git/hooks");
    let written: Vec<&str> = offer.writes.iter().map(|w| w.path.as_str()).collect();
    assert!(
        written.contains(&hooks.join("pre-commit").to_str().unwrap()),
        "{written:?}"
    );
    assert!(offer.writes.iter().all(|w| w.shared), "{:?}", offer.writes);
    let size_ratchet = offer
        .companions
        .iter()
        .find(|c| c.name == "size-ratchet")
        .unwrap();
    assert!(!size_ratchet.installed, "{:?}", offer.companions);
    assert!(offer.declared.effects.removal.is_some());

    kendex_app::repo_effects::apply(&f.scope, &offer.declared).unwrap();
    assert!(
        f.project.join(".git/hooks/kendex-guards").is_file(),
        "the yes did not arm the hooks"
    );
}

/// A package with no declaration adds nothing to the install: no offer,
/// no notice, and the window has nothing to open.
#[test]
fn an_inert_package_brings_no_offer() {
    let f = fixture();
    let installed = install_skill(&f, "deploy");
    assert!(
        installed.repo_effects.is_empty(),
        "{:?}",
        installed.repo_effects
    );
    assert!(installed.packages.iter().any(|p| p.name == "deploy"));
}
