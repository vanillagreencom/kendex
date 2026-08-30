//! One item requiring another: what installs, what is held back, and what
//! goes away. The manifest records choices — what was asked for, which
//! optional extras were taken, what stays removed — and every plan derives
//! the rest, so losing the lock loses nothing.
#![cfg(unix)]

#[path = "../../../test_util.rs"]
mod test_util;
use test_util::source_path;

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
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{declarations}",
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
        source,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
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

fn required_by(source: &str, name: &str) -> Reason {
    Reason::RequiredBy {
        by: kendex_core::lock::InstallRef {
            source: source.to_owned(),
            kind: ItemKind::Skill,
            name: name.to_owned(),
            harness: HarnessId::Claude,
        },
    }
}

#[allow(clippy::unwrap_used)]
fn remove(f: &Fixture, name: &str, sweep: bool) -> kendex_core::engine::EngineReport {
    let report = ops::remove(&f.env, &f.scope, &[name.to_owned()], None, sweep).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
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
    assert_eq!(
        lock.entries["skill:dev:claude"].reasons,
        BTreeSet::from([Reason::Requested])
    );
    assert_eq!(
        lock.entries["skill:github:claude"].reasons,
        BTreeSet::from([Reason::Requested, required_by("cat", "dev")])
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
    assert_eq!(
        lock_of(&f).entries["skill:github:claude"].reasons,
        BTreeSet::from([required_by("cat", "dev")])
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
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(!installed(&f, "github"), "refresh brought it back");

    fs::remove_file(lock_path(&f.env, &f.scope)).unwrap();
    let report = plan_refresh(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
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
    apply::execute(&f.env, &kept.plan).unwrap();
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
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(installed(&f, "dev"), "a missing dependency blocked a skill");
}

/// Two skills that need each other are a co-install their authors meant, so
/// both install and the note says what that means for the reader: the name
/// they declared, and what taking it takes along.
#[test]
#[allow(clippy::unwrap_used)]
fn skills_that_require_each_other_install_and_are_reported() {
    let f = fixture("[skills.dev]\nsource = \"cat\"\n");
    skill(&f.source, "github", "dependencies:\n  required: [dev]\n");

    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(installed(&f, "dev") && installed(&f, "github"));
    assert!(
        report
            .notes
            .iter()
            .any(|note| note == "installing dev also installs github (required)"),
        "{:?}",
        report.notes
    );
}

/// A skill listing itself resolves to the item that wrote the line. Said
/// out loud: the reader owns the catalog line that put it there, and going
/// quiet leaves a declaration that does nothing looking deliberate.
#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_that_requires_itself_is_named() {
    let f = fixture("[skills.dev]\nsource = \"cat\"\n");
    skill(&f.source, "dev", "dependencies:\n  required: [dev]\n");

    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(installed(&f, "dev"));
    assert!(
        report
            .notes
            .iter()
            .any(|note| note == "dev lists itself as required — that line installs nothing"),
        "{:?}",
        report.notes
    );
}

/// A dependency filtered to no tool installs nothing, so the note that
/// says it co-installs is not made: the missing-dependency finding beside
/// it is what that arrangement actually produces.
#[test]
#[allow(clippy::unwrap_used)]
fn a_cycle_split_across_tools_claims_no_co_install() {
    let f = fixture(
        "[skills.dev]\nsource = \"cat\"\nharnesses = [\"claude\"]\n\n[skills.github]\nsource = \"cat\"\nharnesses = [\"codex\"]\n",
    );
    skill(&f.source, "github", "dependencies:\n  required: [dev]\n");

    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        !report
            .notes
            .iter()
            .any(|note| note.contains("also installs")),
        "neither declaration installs the other: {:?}",
        report.notes
    );
    assert!(
        report
            .warnings
            .iter()
            .any(|w| w.message.contains("missing required dependency")),
        "and the arrangement is still reported: {:?}",
        report.warnings
    );
}

/// The reaches guard on its own: both edges install, so the graph carries
/// the cycle, but the requested item runs on a tool its partner does not.
/// "Also installs" is a claim about every tool, and here it is false for
/// one of them.
#[test]
#[allow(clippy::unwrap_used)]
fn a_cycle_reaching_only_some_tools_claims_no_co_install() {
    let f = fixture(
        "[skills.dev]\nsource = \"cat\"\nharnesses = [\"claude\", \"codex\"]\n\n[skills.github]\nsource = \"cat\"\nharnesses = [\"claude\"]\n",
    );
    skill(&f.source, "github", "dependencies:\n  required: [dev]\n");

    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        !report
            .notes
            .iter()
            .any(|note| note.contains("also installs")),
        "codex runs dev without github: {:?}",
        report.notes
    );
}

/// The zero-harness guard on its own: neither declaration lands anywhere,
/// so every reference between them installs nothing and there is no
/// co-install to report — not even the vacuous one a cycle over two
/// tool-less declarations would otherwise produce.
#[test]
#[allow(clippy::unwrap_used)]
fn references_between_declarations_no_tool_holds_claim_no_co_install() {
    let f = fixture(
        "[skills.dev]\nsource = \"cat\"\nharnesses = []\n\n[skills.github]\nsource = \"cat\"\nharnesses = []\n",
    );
    skill(&f.source, "github", "dependencies:\n  required: [dev]\n");

    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        !report
            .notes
            .iter()
            .any(|note| note.contains("also installs")),
        "a reference that installs nothing was reported as a co-install: {:?}",
        report.notes
    );
}

mod more;
