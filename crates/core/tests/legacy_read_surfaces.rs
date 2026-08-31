//! Reads that only annotate rows never blank the surface over one scope.
//!
//! `CoreError::is_unreadable_record` names one class — a lock or manifest
//! another version of kendex wrote, or one damaged past parsing. Every
//! observation read absorbs exactly that class to empty and propagates
//! everything else. It matters because this build reads only the format it
//! writes: after an upgrade, every record a released kendex left is in
//! that class, so a read that failed on one would blank the Library table,
//! the Browse page, the marketplace page and the Updates page on first
//! launch.
//!
//! The other half of the split is here too. A verb that acts on the
//! record refuses one it cannot read, and the collection-steps case below
//! is what keeps that line from drifting back.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::model::{ItemKind, Scope};
use kendex_core::registry::collections::{Collection, CollectionMember};
use kendex_core::source::browse::{self, Catalog, InstallState};

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    project: PathBuf,
    scope: Scope,
}

/// A project declaring one skill from a path catalog, installed, so both
/// records exist and carry something worth losing.
#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("skills/gh")).unwrap();
    fs::write(
        catalog.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: work with github\n---\nBody.\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = {}\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.gh]\nsource = \"cat\"\n",
            kendex_core::manifest::MANIFEST_SCHEMA,
            source_path(&catalog)
        ),
    )
    .unwrap();

    let scope = Scope::Project {
        root: project.clone(),
    };
    let report = kendex_core::engine::audit(&env, &scope).unwrap();
    kendex_core::apply::execute(&env, &report.plan).unwrap();

    World {
        env,
        project,
        scope,
        _tmp: tmp,
    }
}

impl World {
    fn lock(&self) -> PathBuf {
        self.project.join(".kendex-lock.json")
    }

    fn manifest(&self) -> PathBuf {
        self.project.join("kendex.toml")
    }

    /// The record a released kendex left: this build's shape, one version
    /// back. Written as text, since `save` stamps the version it writes.
    #[allow(clippy::unwrap_used)]
    fn age_the_lock(&self) {
        let current = kendex_core::lock::LOCK_VERSION;
        let text = fs::read_to_string(self.lock()).unwrap();
        let older = text.replace(
            &format!("\"version\": {current}"),
            &format!("\"version\": {}", current - 1),
        );
        assert_ne!(older, text, "the version line must be the one rewritten");
        fs::write(self.lock(), older).unwrap();
        assert_unreadable(&kendex_core::lock::load_file(&self.lock()));
    }

    #[allow(clippy::unwrap_used)]
    fn age_the_manifest(&self) {
        let current = kendex_core::manifest::MANIFEST_SCHEMA;
        let text = fs::read_to_string(self.manifest()).unwrap();
        let older = text.replace(
            &format!("schema = {current}"),
            &format!("schema = {}", current - 1),
        );
        assert_ne!(older, text, "the schema line must be the one rewritten");
        fs::write(self.manifest(), older).unwrap();
        assert_unreadable(&kendex_core::manifest::load(&self.manifest()));
    }
}

/// The fixture is only worth anything if the file it wrote really is in
/// the class every assertion below turns on.
#[allow(clippy::unwrap_used)]
fn assert_unreadable<T>(read: &Result<T, CoreError>) {
    let error = read.as_ref().err().expect("the aged file must refuse");
    assert!(error.is_unreadable_record(), "{error}");
}

/// The Library table's From column. Every row it can still account for
/// stands; the aged scope contributes none of its own instead of taking
/// the whole table down.
#[test]
#[allow(clippy::unwrap_used)]
fn the_library_table_survives_an_aged_lock_and_an_aged_manifest() {
    for age in ["lock", "manifest"] {
        let w = world();
        let installed = kendex_core::library::provenance(&w.env, &[w.scope.clone()]).unwrap();
        assert!(
            installed.iter().any(|row| row.name == "gh"),
            "the fixture must give the table a row to lose: {installed:?}"
        );

        match age {
            "lock" => w.age_the_lock(),
            _ => w.age_the_manifest(),
        }

        let rows = kendex_core::library::provenance(&w.env, &[w.scope.clone()])
            .unwrap_or_else(|error| panic!("{age}: {error}"));
        // What is on disk is still observed, so the row is there — as
        // unmanaged with the lock gone, since the record is what said who
        // installed it.
        assert!(rows.iter().any(|row| row.name == "gh"), "{age}: {rows:?}");
    }
}

/// The Browse page's installed-state join. It reads the scope's records to
/// mark which packages are already installed; an aged lock marks none, and
/// the catalog's packages still list.
#[test]
#[allow(clippy::unwrap_used)]
fn the_browse_page_survives_an_aged_lock() {
    let w = world();
    let catalog = Catalog::Subscription {
        scope: w.scope.clone(),
        source: "cat".to_owned(),
    };
    let before = browse::packages(&w.env, &catalog).unwrap();
    assert!(
        before
            .iter()
            .any(|package| package.name == "gh" && package.state == InstallState::Installed),
        "the fixture must show gh installed first: {before:?}"
    );

    w.age_the_lock();

    let after = browse::packages(&w.env, &catalog).expect("browsing must not fail on the record");
    let gh = after
        .iter()
        .find(|package| package.name == "gh")
        .unwrap_or_else(|| panic!("the catalog's packages still list: {after:?}"));
    assert_eq!(
        gh.state,
        InstallState::Available,
        "with no record this build can read, nothing is marked installed"
    );
}

/// The line between the two policies, from the mutation side. Collection
/// steps plan what `kendex add <collection>` writes, so an aged manifest
/// refuses here — read as declaring nothing it would plan every member as
/// a fresh subscription, print that listing, take the person's yes and
/// fetch every repository, and only then meet the same refusal from the
/// install. The record's own message, at the door, costs none of that.
#[test]
#[allow(clippy::unwrap_used)]
fn collection_steps_refuse_an_aged_manifest() {
    let w = world();
    let collection = Collection {
        id: "kit".to_owned(),
        name: "kit".to_owned(),
        members: vec![CollectionMember {
            repo: "owner/other".to_owned(),
            kind: ItemKind::Skill,
            name: "deploy".to_owned(),
            commit: Some("0".repeat(40)),
        }],
    };
    w.age_the_manifest();

    let error = kendex_core::source_ops::collection_steps(&w.env, &w.scope, &collection)
        .expect_err("a plan against a record this build cannot read must refuse");
    assert!(error.is_unreadable_record(), "{error}");
    assert!(error.to_string().contains("schema 5"), "{error}");
}

/// The Updates page, and with it the sidebar badge and the Library's
/// edited flags. `updates_overview` loops this per scope and propagates,
/// so one scope refusing here takes every scope's rows down — which is
/// what an aged record would have done to every user who had one.
///
/// A path-source fixture offers no update standing, so what is pinned is
/// the call answering and the shape of the degrade: an aged lock reads as
/// no record, giving the same report the scope gives with no lock at all.
/// The rows themselves are `package_pins`' ground, over a git source.
#[test]
#[allow(clippy::unwrap_used)]
fn the_updates_page_survives_an_aged_lock_in_one_of_its_scopes() {
    let readable = world();
    let aged = world();

    let baseline = kendex_core::package::updates::updates(&aged.env, &aged.scope).unwrap();

    aged.age_the_lock();
    let after = kendex_core::package::updates::updates(&aged.env, &aged.scope)
        .expect("an aged record must not take the page down");

    fs::remove_file(aged.lock()).unwrap();
    let recordless = kendex_core::package::updates::updates(&aged.env, &aged.scope).unwrap();
    assert_eq!(
        after, recordless,
        "an aged record reads as no record, not as a refusal"
    );
    assert_eq!(
        baseline, recordless,
        "and the fixture's own rows are unmoved"
    );

    // The scope beside it in the same loop is untouched.
    kendex_core::package::updates::updates(&readable.env, &readable.scope).unwrap();
}

/// The same page's other half: an aged manifest declares nothing this
/// build can name, so the scope reports no rows rather than refusing. That
/// is the answer a scope with no manifest already gets.
#[test]
#[allow(clippy::unwrap_used)]
fn the_updates_page_survives_an_aged_manifest() {
    let w = world();
    w.age_the_manifest();
    let report = kendex_core::package::updates::updates(&w.env, &w.scope)
        .expect("the page must answer, not refuse");
    assert!(report.rows.is_empty(), "{:?}", report.rows);
}

/// The rule itself, at both readers. Only the one class is absorbed: a
/// record another project wrote is a refusal this scope must not swallow,
/// because reading it as "nothing recorded" is how a lock carried in with
/// a copied checkout would come to look like a fresh scope.
#[test]
#[allow(clippy::unwrap_used)]
fn observation_absorbs_the_one_class_and_nothing_else() {
    let w = world();
    w.age_the_lock();
    assert!(
        kendex_core::lock::observed(&w.lock())
            .unwrap()
            .entries
            .is_empty(),
        "an aged lock observes as empty"
    );
    w.age_the_manifest();
    assert_eq!(
        kendex_core::manifest::observed(&w.manifest()).unwrap(),
        kendex_core::manifest::Manifest::default(),
        "an aged manifest observes as empty"
    );

    // A lock at this build's own version, naming another project as its
    // author. Not this class, and not absorbed.
    let elsewhere = another_projects_lock(&w.project);
    fs::write(w.lock(), elsewhere).unwrap();
    let error = kendex_core::lock::observed(&w.lock()).unwrap_err();
    assert!(!error.is_unreadable_record(), "{error}");
    assert!(
        matches!(error, CoreError::LockFromAnotherProject { .. }),
        "{error}"
    );
}

/// A well-formed lock at the current version whose `root` names somewhere
/// else — the shape a checkout copied from another machine carries.
fn another_projects_lock(project: &Path) -> String {
    format!(
        r#"{{"version":{},"root":"{}","entries":{{}}}}"#,
        kendex_core::lock::LOCK_VERSION,
        project.join("elsewhere").display()
    )
}
