//! The optional dependencies an install takes, end to end through the
//! window's own command: a name the picker ticked lands on disk and is
//! recorded as the choice, and an unticked one is not installed.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_app::marketplaces::install::{InstallItem, install};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{ItemKind, Scope};
use test_util::{rooted, source_path};

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn skill(catalog: &Path, name: &str, dependencies: &str) {
    let dir = catalog.join("skills").join(name);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: the {name} skill\n{dependencies}---\nBody.\n"),
    )
    .unwrap();
}

/// A project subscribed to a catalog whose `dev` skill offers `linear` as
/// an optional extra and requires nothing.
#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let catalog = home.join("catalog");
    skill(&catalog, "dev", "dependencies:\n  optional: [linear]\n");
    skill(&catalog, "linear", "");
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(home.join(".claude")).unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n",
            source_path(&catalog)
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

fn install_dev(f: &Fixture, optional: &[&str]) -> Result<(), String> {
    install(
        &f.env,
        f.scope.clone(),
        "cat".to_owned(),
        vec![InstallItem {
            kind: ItemKind::Skill,
            name: "dev".to_owned(),
        }],
        None,
        None,
        false,
        None,
        None,
        optional.iter().map(|name| (*name).to_owned()).collect(),
    )
    .map(|_| ())
}

fn installed(f: &Fixture, name: &str) -> bool {
    f.project.join(".claude/skills").join(name).exists()
}

#[allow(clippy::unwrap_used)]
fn manifest(f: &Fixture) -> String {
    fs::read_to_string(f.project.join("kendex.toml")).unwrap()
}

/// The headline behaviour: tick an optional extra, get it installed — and
/// the manifest records the choice, so the next plan derives it again.
#[test]
fn a_ticked_optional_dependency_installs_and_is_recorded() {
    let f = fixture();
    install_dev(&f, &["linear"]).expect("install dev with linear");

    assert!(installed(&f, "dev"), "the package itself");
    assert!(
        installed(&f, "linear"),
        "the optional extra that was ticked"
    );
    let manifest = manifest(&f);
    assert!(
        manifest.contains("[optional-dependencies]") && manifest.contains("dev = [\"linear\"]"),
        "{manifest}"
    );
}

/// The must-fail control beside it: the same install with nothing ticked
/// brings the package alone. An extra nobody asked for is not installed,
/// and nothing is recorded about it.
#[test]
fn an_unticked_optional_dependency_installs_nothing() {
    let f = fixture();
    install_dev(&f, &[]).expect("install dev alone");

    assert!(installed(&f, "dev"));
    assert!(!installed(&f, "linear"), "nobody asked for it");
    assert!(
        !manifest(&f).contains("optional-dependencies"),
        "{}",
        manifest(&f)
    );
}
