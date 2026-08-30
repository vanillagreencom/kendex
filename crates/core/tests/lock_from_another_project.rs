//! A lock that travelled with a copied checkout names the paths of the
//! checkout it came from.
//!
//! Refresh reads `emitted.paths` as the positions this scope owns and takes
//! back the ones it no longer renders. Pointed at another tree those are
//! somebody else's files, and a project scope writes only inside its own
//! root — so the record is refused, naming the path, and the other tree is
//! not read as this one's to take.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::engine::{PlanOptions, audit, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::model::Scope;

/// One path as it sits on disk, in whatever detail tells two states apart:
/// a file by its bytes, a link by its target, a directory by being one.
#[derive(Debug, PartialEq, Eq)]
enum Entry {
    Dir,
    /// Read as text: every file this fixture puts on disk is one, and a
    /// failed comparison has to be readable.
    File(String),
    Link(PathBuf),
}

#[allow(clippy::unwrap_used)]
fn put(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// Every path under `root`, keyed by its place in the tree. Comparing two of
/// these compares the file list and the contents at once, so a file gone, a
/// file added and a byte changed all read as a difference.
#[allow(clippy::unwrap_used)]
fn snapshot(root: &Path) -> BTreeMap<PathBuf, Entry> {
    let mut found = BTreeMap::new();
    let mut queue = vec![root.to_path_buf()];
    while let Some(dir) = queue.pop() {
        for entry in fs::read_dir(&dir).unwrap() {
            let path = entry.unwrap().path();
            let key = path.strip_prefix(root).unwrap().to_path_buf();
            let meta = fs::symlink_metadata(&path).unwrap();
            if meta.file_type().is_symlink() {
                found.insert(key, Entry::Link(fs::read_link(&path).unwrap()));
            } else if meta.is_dir() {
                found.insert(key, Entry::Dir);
                queue.push(path);
            } else {
                let bytes = fs::read(&path).unwrap();
                found.insert(
                    key,
                    Entry::File(String::from_utf8_lossy(&bytes).into_owned()),
                );
            }
        }
    }
    found
}

#[allow(clippy::unwrap_used)]
fn declare(root: &Path, catalog: &Path) {
    put(
        &root.join("kendex.toml"),
        &format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.ship]\nsource = \"cat\"\n",
            source_path(&catalog)
        ),
    );
}

fn project(root: &Path) -> Scope {
    Scope::Project {
        root: root.to_path_buf(),
    }
}

/// What `kendex refresh` plans with: it sweeps what nothing accounts for.
fn refresh() -> PlanOptions {
    PlanOptions {
        sweep_unneeded: true,
        ..PlanOptions::default()
    }
}

/// The must-fail control for the containment refusal. Without it the copied
/// record is read as this project's own: every path it names is a position
/// the new render does not produce, so refresh takes them to the trash —
/// out of the other checkout.
#[test]
#[allow(clippy::unwrap_used)]
fn a_lock_carried_from_another_checkout_is_refused_and_that_checkout_stands() {
    let tmp = tempfile::tempdir().unwrap();
    // Resolved: the engine resolves a scope root before writing any of the
    // paths it records, and on macOS the temp directory is reached through
    // `/var -> private/var`.
    let home = tmp.path().canonicalize().unwrap();
    let catalog = home.join("catalog");
    put(
        &catalog.join("skills/ship/SKILL.md"),
        "---\nname: ship\ndescription: ship\n---\n\nShip the branch.\n",
    );
    let env = Env::fake(&home, FakeOs::Linux);

    let installed = home.join("dev/app");
    declare(&installed, &catalog);
    let report = audit(&env, &project(&installed)).unwrap();
    kendex_core::apply::execute(&env, &report.plan).unwrap();

    // A second checkout of the same project, seeded with the first one's
    // lock — which is how a linked worktree gets one.
    let elsewhere = home.join("dev/worktree");
    declare(&elsewhere, &catalog);
    fs::copy(
        installed.join(".kendex-lock.json"),
        elsewhere.join(".kendex-lock.json"),
    )
    .unwrap();

    let before = snapshot(&installed);
    assert_eq!(
        before.get(Path::new(".agents/skills/ship/SKILL.md")),
        Some(&Entry::File(
            fs::read_to_string(catalog.join("skills/ship/SKILL.md")).unwrap()
        )),
        "the install this refusal protects is on disk to begin with"
    );
    assert_eq!(
        before.get(Path::new(".claude/skills/ship")),
        Some(&Entry::Link(PathBuf::from("../../.agents/skills/ship"))),
        "and so is the link the tool reads it through"
    );

    // The whole operation, the way refresh runs it: plan the scope, and
    // carry out whatever it planned.
    let refused = match plan_apply(&env, &project(&elsewhere), &refresh()) {
        Ok(report) => {
            kendex_core::apply::execute(&env, &report.plan).unwrap();
            None
        }
        Err(error) => Some(error),
    };

    assert_eq!(
        snapshot(&installed),
        before,
        "the checkout the lock came from is exactly as it was"
    );
    let refused = refused.expect("a record naming another project is refused");
    assert!(
        matches!(
            &refused,
            CoreError::LockOutsideProject { key, recorded, root, .. }
                if key == "skill:ship:claude"
                    && recorded == &installed.join(".agents/skills/ship")
                    && root == &elsewhere
        ),
        "the refusal names the entry, the path it claims and the project that cannot hold it: {refused:?}"
    );
}

/// The refusal is about reaching past the root, not about recording paths:
/// a project whose lock names its own positions refreshes as it always did.
#[test]
#[allow(clippy::unwrap_used)]
fn a_lock_naming_its_own_project_refreshes() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let catalog = home.join("catalog");
    put(
        &catalog.join("skills/ship/SKILL.md"),
        "---\nname: ship\ndescription: ship\n---\n\nShip the branch.\n",
    );
    let env = Env::fake(&home, FakeOs::Linux);

    let root = home.join("dev/app");
    declare(&root, &catalog);
    let report = audit(&env, &project(&root)).unwrap();
    kendex_core::apply::execute(&env, &report.plan).unwrap();

    let again = plan_apply(&env, &project(&root), &refresh()).unwrap();
    assert!(
        again.plan.ops.is_empty(),
        "an install that is where its record says settles: {:?}",
        again.plan.ops
    );
}

/// The paths one entry claims, rewritten as they sit in the file.
#[allow(clippy::unwrap_used)]
fn claim(lock: &Path, key: &str, paths: &[PathBuf]) {
    let mut record: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(lock).unwrap()).unwrap();
    record["entries"][key]["emitted"]["paths"] = paths
        .iter()
        .map(|path| serde_json::Value::String(path.display().to_string()))
        .collect();
    fs::write(lock, serde_json::to_string_pretty(&record).unwrap()).unwrap();
}

/// The must-fail control for the escape a prefix comparison alone lets
/// through: `<project>/../elsewhere` starts with `<project>` component for
/// component, and every operation on it lands in `elsewhere`.
#[test]
#[allow(clippy::unwrap_used)]
fn a_lock_walking_back_out_of_its_project_is_refused_and_the_tree_it_points_at_stands() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let catalog = home.join("catalog");
    put(
        &catalog.join("skills/ship/SKILL.md"),
        "---\nname: ship\ndescription: ship\n---\n\nShip the branch.\n",
    );
    let env = Env::fake(&home, FakeOs::Linux);

    let installed = home.join("dev/app");
    declare(&installed, &catalog);
    let report = audit(&env, &project(&installed)).unwrap();
    kendex_core::apply::execute(&env, &report.plan).unwrap();

    // A project of its own, whose record claims the other one's positions
    // by walking out of this one.
    let elsewhere = home.join("dev/other");
    declare(&elsewhere, &catalog);
    let out = |rest: &str| elsewhere.join("..").join("app").join(rest);
    fs::copy(
        installed.join(".kendex-lock.json"),
        elsewhere.join(".kendex-lock.json"),
    )
    .unwrap();
    claim(
        &elsewhere.join(".kendex-lock.json"),
        "skill:ship:claude",
        &[out(".agents/skills/ship"), out(".claude/skills/ship")],
    );
    assert!(
        out(".agents/skills/ship").starts_with(&elsewhere),
        "the escape is one a prefix comparison reads as inside"
    );

    let before = snapshot(&installed);
    assert_eq!(
        before.get(Path::new(".agents/skills/ship/SKILL.md")),
        Some(&Entry::File(
            fs::read_to_string(catalog.join("skills/ship/SKILL.md")).unwrap()
        )),
        "the install this refusal protects is on disk to begin with"
    );

    let refused = match plan_apply(&env, &project(&elsewhere), &refresh()) {
        Ok(report) => {
            kendex_core::apply::execute(&env, &report.plan).unwrap();
            None
        }
        Err(error) => Some(error),
    };

    assert_eq!(
        snapshot(&installed),
        before,
        "the tree the record walked out to is exactly as it was"
    );
    let refused = refused.expect("a record walking out of its project is refused");
    assert!(
        matches!(
            &refused,
            CoreError::LockOutsideProject { key, recorded, root, .. }
                if key == "skill:ship:claude"
                    && recorded == &out(".agents/skills/ship")
                    && root == &elsewhere
        ),
        "the refusal names the entry, the path it claims and the project that cannot hold it: {refused:?}"
    );
}

/// Containment is not ownership. A second checkout nested below this root
/// sits inside it, so every path a lock carried out of that checkout names
/// passes the boundary check — and the parent's refresh then reads them as
/// positions it owns and takes back the ones its own render does not
/// produce, out of the nested tree. The record says which root wrote it, so
/// the read can tell.
#[test]
#[allow(clippy::unwrap_used)]
fn a_lock_from_a_checkout_nested_inside_the_project_is_refused_and_that_checkout_stands() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let catalog = home.join("catalog");
    put(
        &catalog.join("skills/ship/SKILL.md"),
        "---\nname: ship\ndescription: ship\n---\n\nShip the branch.\n",
    );
    let env = Env::fake(&home, FakeOs::Linux);

    let outer = home.join("dev/app");
    declare(&outer, &catalog);
    let report = audit(&env, &project(&outer)).unwrap();
    kendex_core::apply::execute(&env, &report.plan).unwrap();

    // A checkout of its own, living under the first one — a vendored
    // repository, or a worktree somebody put inside the tree it came from.
    let nested = outer.join("vendor/thing");
    declare(&nested, &catalog);
    let report = audit(&env, &project(&nested)).unwrap();
    kendex_core::apply::execute(&env, &report.plan).unwrap();

    // Its lock, carried up to the project holding it. Every path it names
    // starts with the outer root, so containment waves all of them through.
    fs::copy(
        nested.join(".kendex-lock.json"),
        outer.join(".kendex-lock.json"),
    )
    .unwrap();
    let before = snapshot(&nested);
    assert_eq!(
        before.get(Path::new(".agents/skills/ship/SKILL.md")),
        Some(&Entry::File(
            fs::read_to_string(catalog.join("skills/ship/SKILL.md")).unwrap()
        )),
        "the install this refusal protects is on disk to begin with"
    );
    assert!(
        nested.join(".agents/skills/ship").starts_with(&outer),
        "the claim is one containment reads as inside"
    );

    let refused = match plan_apply(&env, &project(&outer), &refresh()) {
        Ok(report) => {
            kendex_core::apply::execute(&env, &report.plan).unwrap();
            None
        }
        Err(error) => Some(error),
    };

    assert_eq!(
        snapshot(&nested),
        before,
        "the checkout the lock came from is exactly as it was"
    );
    let refused = refused.expect("a record another checkout wrote is refused");
    assert!(
        matches!(
            &refused,
            CoreError::LockFromAnotherProject { recorded, root, .. }
                if recorded == &nested && root == &outer
        ),
        "the refusal names the project that wrote the record and the one reading it: {refused:?}"
    );
}
