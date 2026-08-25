//! One item requiring another: what installs, what is held back, and what
//! goes away. The manifest records choices — what was asked for, which
//! optional extras were taken, what stays removed — and every plan derives
//! the rest, so losing the lock loses nothing.
#![cfg(unix)]

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::{SetDirection, audit, ops, plan_refresh};
use kendex_core::env::{Env, FakeOs};
use kendex_core::lock::{Lock, Reason, load as load_lock, lock_path};
use kendex_core::manifest::{self, ManifestFile};
use kendex_core::model::{HarnessId, ItemKind, Scope};

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    source: PathBuf,
}

/// A skill, with whatever its frontmatter should say about what it needs.
#[allow(clippy::unwrap_used)]
fn skill(source: &Path, name: &str, dependencies: &str) {
    let dir = source.join("skills").join(name);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: the {name} skill\n{dependencies}---\nBody.\n"),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn fixture(declarations: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(home.join(".codex")).unwrap();

    let source = home.join("catalog");
    skill(&source, "dev", "dependencies:\n  required: [github]\n");
    skill(&source, "github", "");

    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{declarations}",
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
        source,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();
}

#[allow(clippy::unwrap_used)]
fn lock_of(f: &Fixture) -> Lock {
    load_lock(&lock_path(&f.env, &f.scope)).unwrap()
}

#[allow(clippy::unwrap_used)]
fn manifest_of(f: &Fixture) -> kendex_core::manifest::Manifest {
    match manifest::load(&manifest::manifest_path(&f.env, &f.scope)).unwrap() {
        ManifestFile::Current(manifest) => *manifest,
        other => panic!("expected a current manifest, got {other:?}"),
    }
}

fn required_by(source: &str, name: &str, scope: &Scope) -> Reason {
    Reason::RequiredBy {
        by: kendex_core::lock::InstallRef {
            source: source.to_owned(),
            kind: ItemKind::Skill,
            name: name.to_owned(),
            harness: HarnessId::Claude,
            scope: scope.clone(),
        },
    }
}

#[allow(clippy::unwrap_used)]
fn remove(f: &Fixture, name: &str, sweep: bool) -> kendex_core::engine::EngineReport {
    let report = ops::remove(&f.env, &f.scope, &[name.to_owned()], None, sweep).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();
    report
}

fn installed(f: &Fixture, name: &str) -> bool {
    f.project.join(".claude/skills").join(name).exists()
}

/// An installation can exist for several reasons at once, and each one is a
/// value the record can be read back from — never a sentence.
#[test]
#[allow(clippy::unwrap_used)]
fn an_installation_records_every_reason_it_exists() {
    let f = fixture("[skills.dev]\nsource = \"cat\"\n\n[skills.github]\nsource = \"cat\"\n");
    apply_now(&f);

    let lock = lock_of(&f);
    let scope = f.scope.canonical();
    assert_eq!(
        lock.entries["skill:dev:claude"].reasons,
        BTreeSet::from([Reason::Requested])
    );
    assert_eq!(
        lock.entries["skill:github:claude"].reasons,
        BTreeSet::from([Reason::Requested, required_by("cat", "dev", &scope)])
    );
}

/// Declaring one skill installs what it needs, and the manifest still holds
/// only the choice: a derived install must never read as a request, or
/// removing the thing that wanted it could never take it away.
#[test]
#[allow(clippy::unwrap_used)]
fn a_dependency_installs_without_being_declared() {
    let f = fixture("[skills.dev]\nsource = \"cat\"\n");
    apply_now(&f);

    assert!(installed(&f, "dev") && installed(&f, "github"));
    assert!(!manifest_of(&f).skills.contains_key("github"));
    let scope = f.scope.canonical();
    assert_eq!(
        lock_of(&f).entries["skill:github:claude"].reasons,
        BTreeSet::from([required_by("cat", "dev", &scope)])
    );
}

/// Both removal orders, over an installation that is asked for *and*
/// required: taking one reason away never takes the installation away while
/// another reason stands.
#[test]
#[allow(clippy::unwrap_used)]
fn a_multi_edge_installation_survives_every_removal_order() {
    let f = fixture("[skills.dev]\nsource = \"cat\"\n\n[skills.github]\nsource = \"cat\"\n");
    apply_now(&f);

    // The dependent goes first: github was asked for, so it stays, and its
    // record no longer claims anything requires it.
    remove(&f, "dev", false);
    assert!(!installed(&f, "dev") && installed(&f, "github"));
    assert_eq!(
        lock_of(&f).entries["skill:github:claude"].reasons,
        BTreeSet::from([Reason::Requested])
    );
    remove(&f, "github", false);
    assert!(!installed(&f, "github"));

    // The other order: github goes while dev still requires it, so the
    // removal is written down and dev says what it is missing.
    let f = fixture("[skills.dev]\nsource = \"cat\"\n\n[skills.github]\nsource = \"cat\"\n");
    apply_now(&f);
    let report = remove(&f, "github", false);
    assert!(installed(&f, "dev") && !installed(&f, "github"));
    assert!(manifest_of(&f).is_suppressed(ItemKind::Skill, "github"));
    assert!(
        report
            .warnings
            .iter()
            .any(|w| w.name == "dev" && w.message.contains("missing required dependency")),
        "{:?}",
        report.warnings
    );
}

/// A removal stays a removal: the next refresh honors it, and so does a
/// scope whose record was deleted entirely — the choice lives in the
/// manifest, not in the cache.
#[test]
#[allow(clippy::unwrap_used)]
fn a_suppressed_dependency_survives_refresh_and_lock_loss() {
    let f = fixture("[skills.dev]\nsource = \"cat\"\n");
    apply_now(&f);
    assert!(installed(&f, "github"));

    remove(&f, "github", false);
    assert!(!installed(&f, "github"));

    let report = plan_refresh(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();
    assert!(!installed(&f, "github"), "refresh brought it back");

    fs::remove_file(lock_path(&f.env, &f.scope)).unwrap();
    let report = plan_refresh(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();
    assert!(!installed(&f, "github"), "a lost record brought it back");
    assert!(installed(&f, "dev"));
    assert!(
        audit(&f.env, &f.scope)
            .unwrap()
            .warnings
            .iter()
            .any(|w| w.name == "dev" && w.message.contains("missing required dependency"))
    );
}

/// Removing the last thing that needed something offers to take it too, and
/// only takes it when asked. What was asked for by name is never swept.
#[test]
#[allow(clippy::unwrap_used)]
fn removing_the_last_dependent_offers_to_sweep_what_it_needed() {
    let f = fixture("[skills.dev]\nsource = \"cat\"\n");
    apply_now(&f);

    let kept = ops::remove(&f.env, &f.scope, &["dev".to_owned()], None, false).unwrap();
    assert_eq!(kept.sweepable.len(), 1);
    assert_eq!(kept.sweepable[0].name, "github");
    apply::execute(&f.env, &kept.plan, None).unwrap();
    assert!(installed(&f, "github"), "swept without being asked");

    let f = fixture("[skills.dev]\nsource = \"cat\"\n");
    apply_now(&f);
    let swept = remove(&f, "dev", true);
    assert!(!installed(&f, "github"));
    assert!(
        swept
            .set_changes
            .iter()
            .any(|c| c.name == "github" && c.direction == SetDirection::Remove)
    );
}

/// A name the catalog does not carry is said out loud, with what to do about
/// it, and the item that wants it still installs.
#[test]
#[allow(clippy::unwrap_used)]
fn a_dependency_the_catalog_lacks_is_a_finding() {
    let f = fixture("[skills.dev]\nsource = \"cat\"\n");
    skill(&f.source, "dev", "dependencies:\n  required: [nowhere]\n");

    let report = audit(&f.env, &f.scope).unwrap();
    let warning = report
        .warnings
        .iter()
        .find(|w| w.message.contains("nowhere"))
        .expect("the missing dependency is reported");
    assert_eq!(warning.name, "dev");
    assert!(warning.remediation.as_ref().unwrap().contains("nowhere"));
    apply::execute(&f.env, &report.plan, None).unwrap();
    assert!(installed(&f, "dev"), "a missing dependency blocked a skill");
}

/// Two skills that need each other are a co-install their authors meant, so
/// both install and the pair is reported as information.
#[test]
#[allow(clippy::unwrap_used)]
fn skills_that_require_each_other_install_and_are_reported() {
    let f = fixture("[skills.dev]\nsource = \"cat\"\n");
    skill(&f.source, "github", "dependencies:\n  required: [dev]\n");

    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();
    assert!(installed(&f, "dev") && installed(&f, "github"));
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("require each other") && note.contains("github")),
        "{:?}",
        report.notes
    );
}

mod more;
