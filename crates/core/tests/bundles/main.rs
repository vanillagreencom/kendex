//! Bundles: a curated set installed under one name. The manifest records
//! that the set is installed and nothing else — its members derive on every
//! plan, each carrying an edge back to the bundle — so uninstalling it can
//! take exactly what nothing else accounts for and leave everything else
//! standing.
#![cfg(unix)]

#[path = "../../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::{EngineReport, PlanOptions, SetDirection, audit, ops, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::lock::{BundleRef, InstallRef, Lock, Reason, load as load_lock, lock_path};
use kendex_core::manifest::{self, ManifestFile};
use kendex_core::model::{HarnessId, ItemKind, Scope};

/// A set whose members include the skill the manifest also asks for and
/// another member requires — three edges on one installation.
const STARTER_WITH_GITHUB: &str = "[bundles.starter]\ndescription = \"the starter set\"\nskills = [\"dev\", \"docs\", \"github\"]\n";

pub struct Fixture {
    _tmp: tempfile::TempDir,
    pub env: Env,
    pub scope: Scope,
    pub project: PathBuf,
    pub source: PathBuf,
}

#[allow(clippy::unwrap_used)]
pub fn write(root: &Path, rel: &str, text: &str) {
    let path = root.join(rel);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

#[allow(clippy::unwrap_used)]
fn skill(source: &Path, name: &str, dependencies: &str) {
    write(
        source,
        &format!("skills/{name}/SKILL.md"),
        &format!("---\nname: {name}\ndescription: the {name} skill\n{dependencies}---\nBody.\n"),
    );
}

/// A catalog offering one set — two skills, an agent and a command — plus a
/// skill nobody's set carries, and a project pointed at it.
#[allow(clippy::unwrap_used)]
pub fn fixture(declarations: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let source = home.join("catalog");
    skill(&source, "dev", "dependencies:\n  required: [github]\n");
    skill(&source, "github", "");
    skill(&source, "docs", "");
    write(
        &source,
        "agents/writer.md",
        "---\nname: writer\ndescription: writes things\n---\n\nWrite.\n",
    );
    write(
        &source,
        "commands/review.md",
        "---\ndescription: review a change\n---\n\nRead it.\n",
    );
    catalog_bundles(
        &source,
        "[bundles.starter]\ndescription = \"the starter set\"\nskills = [\"dev\", \"docs\"]\nagents = [\"writer\"]\ncommands = [\"review\"]\n",
    );

    write(
        &project,
        "kendex.toml",
        &format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{declarations}",
            source_path(&source)
        ),
    );

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

/// What the catalog says it offers as a set — rewritten whenever a test needs
/// upstream to change its mind.
pub fn catalog_bundles(source: &Path, table: &str) {
    write(source, "kendex.toml", table);
}

#[allow(clippy::unwrap_used)]
pub fn apply_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
pub fn lock_of(f: &Fixture) -> Lock {
    load_lock(&lock_path(&f.env, &f.scope)).unwrap()
}

#[allow(clippy::unwrap_used)]
pub fn manifest_of(f: &Fixture) -> kendex_core::manifest::Manifest {
    match manifest::load(&manifest::manifest_path(&f.env, &f.scope)).unwrap() {
        ManifestFile::Current(manifest) => *manifest,
        other => panic!("expected a current manifest, got {other:?}"),
    }
}

#[allow(clippy::unwrap_used)]
pub fn remove(f: &Fixture, name: &str, sweep: bool) -> EngineReport {
    let report = ops::remove(&f.env, &f.scope, &[name.to_owned()], None, sweep).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    report
}

pub fn installed(f: &Fixture, kind: ItemKind, name: &str) -> bool {
    let path = match kind {
        ItemKind::Skill => f.project.join(".claude/skills").join(name),
        ItemKind::Agent => f.project.join(".claude/agents").join(format!("{name}.md")),
        ItemKind::Command => f
            .project
            .join(".claude/commands")
            .join(format!("{name}.md")),
        other => panic!("no path for a {}", other.name()),
    };
    path.exists() || path.is_symlink()
}

pub fn member_of(source: &str, bundle: &str) -> Reason {
    Reason::MemberOf {
        bundle: BundleRef {
            source: source.to_owned(),
            name: bundle.to_owned(),
        },
    }
}

pub fn required_by(source: &str, name: &str) -> Reason {
    Reason::RequiredBy {
        by: InstallRef {
            source: source.to_owned(),
            kind: ItemKind::Skill,
            name: name.to_owned(),
            harness: HarnessId::Claude,
        },
    }
}

/// The whole set installs from one declaration, across every kind it carries,
/// and the manifest still holds only the choice: members that read as
/// requests could never be uninstalled with the set that brought them.
#[test]
#[allow(clippy::unwrap_used)]
fn a_bundle_installs_its_members_and_the_manifest_holds_only_the_bundle() {
    let f = fixture("[bundles.starter]\nsource = \"cat\"\n");
    apply_now(&f);

    assert!(installed(&f, ItemKind::Skill, "dev"));
    assert!(installed(&f, ItemKind::Skill, "docs"));
    assert!(installed(&f, ItemKind::Agent, "writer"));
    assert!(installed(&f, ItemKind::Command, "review"));

    let manifest = manifest_of(&f);
    assert!(manifest.skills.is_empty() && manifest.agents.is_empty());
    assert_eq!(manifest.bundles["starter"].source, "cat");

    let lock = lock_of(&f);
    for key in ["skill:dev:claude", "agent:writer:claude"] {
        assert_eq!(
            lock.entries[key].reasons,
            BTreeSet::from([member_of("cat", "starter")]),
            "{key}"
        );
    }
    // What a member needs comes in behind it, as its own kind of edge.
    assert_eq!(
        lock.entries["skill:github:claude"].reasons,
        BTreeSet::from([required_by("cat", "dev")])
    );
}

/// Uninstalling the set takes the members nothing else accounts for, keeps
/// the ones something does, and says which is which — with the reason.
#[test]
#[allow(clippy::unwrap_used)]
fn uninstalling_a_bundle_removes_only_what_nothing_else_holds() {
    let f = fixture("[bundles.starter]\nsource = \"cat\"\n\n[agents.writer]\nsource = \"cat\"\n");
    apply_now(&f);

    let report = remove(&f, "starter", false);
    assert!(!installed(&f, ItemKind::Skill, "dev"));
    assert!(!installed(&f, ItemKind::Skill, "docs"));
    assert!(!installed(&f, ItemKind::Command, "review"));
    assert!(
        installed(&f, ItemKind::Agent, "writer"),
        "a member the user asked for was taken away with the set"
    );

    let gone: Vec<&str> = report
        .set_changes
        .iter()
        .filter(|change| change.direction == SetDirection::Remove)
        .map(|change| change.name.as_str())
        .collect();
    assert!(gone.contains(&"dev") && gone.contains(&"docs") && gone.contains(&"review"));
    let dev = report
        .set_changes
        .iter()
        .find(|change| change.name == "dev")
        .unwrap();
    assert!(dev.reason.contains("part of the starter bundle"), "{dev:?}");

    let kept = report
        .kept
        .iter()
        .find(|kept| kept.name == "writer")
        .expect("the member that stays is named in the preview");
    assert_eq!(kept.reason, "asked for");
    assert!(!manifest_of(&f).bundles.contains_key("starter"));
}

/// An installation held by three edges at once — asked for, carried by a set,
/// and required by another item — survives until the last of them is gone,
/// whichever order they go in.
#[test]
#[allow(clippy::unwrap_used)]
fn a_multi_edge_member_behaves_through_every_removal_order() {
    let declarations = "[bundles.starter]\nsource = \"cat\"\n\n[skills.github]\nsource = \"cat\"\n";

    // The set goes first: github was asked for and dev still needs it.
    let f = fixture(declarations);
    catalog_bundles(&f.source, STARTER_WITH_GITHUB);
    apply_now(&f);
    assert_eq!(
        lock_of(&f).entries["skill:github:claude"].reasons,
        BTreeSet::from([
            Reason::Requested,
            member_of("cat", "starter"),
            required_by("cat", "dev"),
        ])
    );
    remove(&f, "starter", false);
    assert!(installed(&f, ItemKind::Skill, "github"));
    assert_eq!(
        lock_of(&f).entries["skill:github:claude"].reasons,
        BTreeSet::from([Reason::Requested])
    );
    remove(&f, "github", false);
    assert!(!installed(&f, ItemKind::Skill, "github"));

    // The request goes first: the set and the dependency still hold it, so
    // the removal is written down rather than undone by the next plan.
    let f = fixture(declarations);
    catalog_bundles(&f.source, STARTER_WITH_GITHUB);
    apply_now(&f);
    remove(&f, "github", false);
    assert!(!installed(&f, ItemKind::Skill, "github"));
    assert!(manifest_of(&f).is_suppressed(ItemKind::Skill, "github"));
    assert!(
        installed(&f, ItemKind::Skill, "dev"),
        "the set went with it"
    );

    // And with the set gone too, the request alone still holds it.
    let f = fixture(declarations);
    catalog_bundles(&f.source, STARTER_WITH_GITHUB);
    apply_now(&f);
    remove(&f, "starter", false);
    assert!(installed(&f, ItemKind::Skill, "github"));
    assert!(!installed(&f, ItemKind::Skill, "docs"));
}

/// Taking one member away is durable: the set stays installed, the audit says
/// how much of it is not, and neither a refresh nor a lost record brings it
/// back. Asking for the set again is what restores it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_member_removed_from_a_bundle_stays_removed() {
    let f = fixture("[bundles.starter]\nsource = \"cat\"\n");
    apply_now(&f);
    assert!(installed(&f, ItemKind::Skill, "docs"));

    remove(&f, "docs", false);
    assert!(!installed(&f, ItemKind::Skill, "docs"));
    assert!(manifest_of(&f).is_suppressed(ItemKind::Skill, "docs"));

    let report = plan_apply(
        &f.env,
        &f.scope,
        &PlanOptions {
            sweep_unneeded: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(
        !installed(&f, ItemKind::Skill, "docs"),
        "refresh restored it"
    );

    fs::remove_file(lock_path(&f.env, &f.scope)).unwrap();
    let report = plan_apply(
        &f.env,
        &f.scope,
        &PlanOptions {
            sweep_unneeded: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(
        !installed(&f, ItemKind::Skill, "docs"),
        "a lost record restored it"
    );
    assert!(installed(&f, ItemKind::Skill, "dev"), "the rest of the set");

    let audited = audit(&f.env, &f.scope).unwrap();
    assert!(
        audited
            .notes
            .iter()
            .any(|note| note.contains("starter") && note.contains("1 member held back")),
        "{:?}",
        audited.notes
    );

    // Asking for the set again asks for all of it.
    let request = ops::AddRequest {
        source: Some("cat".to_owned()),
        bundles: vec!["starter".to_owned()],
        no_auto_skills: true,
        ..ops::AddRequest::default()
    };
    let report = ops::add(&f.env, &f.scope, &request).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(installed(&f, ItemKind::Skill, "docs"));
}

mod contested;
mod more;
