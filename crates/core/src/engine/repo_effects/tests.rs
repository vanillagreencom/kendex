use std::fs;
use std::os::unix::fs::PermissionsExt;

use super::*;
use crate::env::FakeOs;

/// A switched-off installation keeps its declaration under the
/// `.disabled` name, and it is the same declaration: the removal that
/// finds it is the one that runs the uninstaller before the scripts go.
#[test]
#[allow(clippy::unwrap_used)]
fn a_switched_off_installation_still_declares_what_it_armed() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let root = home.join("dev/app");
    let scope = Scope::Project { root: root.clone() };
    let lock = crate::lock::Lock::default();

    let tree = root.join(".agents/skills/armer");
    fs::create_dir_all(&tree).unwrap();
    fs::write(
        tree.join("SKILL.md.disabled"),
        "---\nname: armer\n---\nBody.\n",
    )
    .unwrap();

    let found = installed_tree(&env, &scope, &lock, "armer").unwrap();
    let found = found.expect("the disabled declaration was read as an absent one");
    assert_eq!(found.root, tree);
    assert_eq!(found.declaration, tree.join("SKILL.md.disabled"));
    assert!(found.text.contains("name: armer"), "{}", found.text);
}

/// A namespaced package delivered by copy lives under the harness's
/// own spelling of its name, not the shared tree's.
///
/// `rendered_name` joins the plugin and the item with the separator
/// that harness will load — a hyphen where names must be lower-kebab —
/// while the canonical tree joins them with two underscores. Probing
/// the canonical spelling in a harness's own directory found nothing,
/// so the package read as declaring nothing and the removal went ahead
/// without running the uninstaller it had.
#[test]
#[allow(clippy::unwrap_used)]
fn a_namespaced_copy_declares_what_it_armed() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let root = home.join("dev/app");
    let scope = Scope::Project { root: root.clone() };
    let name = "plugin/armer";
    let harness = crate::model::HarnessId::Opencode;

    let mut before = crate::lock::Lock::default();
    before.entries.insert(
        "opencode:skill:plugin/armer".to_owned(),
        entry(name, harness),
    );
    let after = crate::lock::Lock::default();

    let dir = crate::engine::desired::own_dir(&env, &scope, harness, ItemKind::Skill)
        .expect("opencode reads skills from a directory of its own");
    let tree = dir.join(crate::harness::rendered_name(harness, name));
    assert_ne!(
        tree,
        dir.join(crate::harness::canonical_name(name)),
        "this harness spells a namespaced name the way the shared tree does, so it cannot show the gap"
    );
    fs::create_dir_all(&tree).unwrap();
    fs::write(
        tree.join("SKILL.md"),
        "---\nname: plugin/armer\nrepo-effects:\n  summary: Arms git hooks.\n  uninstaller: scripts/off\n---\nBody.\n",
    )
    .unwrap();

    let leaving = leaving(&env, &scope, &before, &after).unwrap();
    assert_eq!(leaving.len(), 1, "the departing package declared nothing");
    assert_eq!(leaving[0].root, tree);
    assert_eq!(
        leaving[0].effects.uninstaller.as_deref(),
        Some("scripts/off")
    );
}

fn entry(name: &str, harness: crate::model::HarnessId) -> crate::lock::LockEntry {
    crate::lock::LockEntry {
        name: name.to_owned(),
        kind: ItemKind::Skill,
        harness,
        source: "cat".to_owned(),
        source_repo: "owner/catalog".to_owned(),
        method: crate::manifest::Method::Copy,
        installed_at: "2026-01-01T00:00:00Z".to_owned(),
        source_hash: "x".to_owned(),
        source_commit: None,
        rendered_hash: None,
        enabled: true,
        upstream_skills: None,
        emitted: None,
        registration: None,
        reasons: Default::default(),
    }
}

/// A candidate with no `SKILL.md` is a candidate to move past; a
/// candidate whose `SKILL.md` will not read is the end of the search.
///
/// Swallowing the read spelled the second case as the first, and the
/// caller reads that as "this package declares nothing" — which is how
/// a removal takes a package's scripts away with its hook shims still
/// delegating to them. The lock is empty, so the canonical tree is the
/// only candidate and the answer is about the read, nothing else.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_declaration_is_an_error_not_an_absent_one() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let root = home.join("dev/app");
    let scope = Scope::Project { root: root.clone() };
    let lock = crate::lock::Lock::default();

    assert!(
        installed_tree(&env, &scope, &lock, "armer")
            .unwrap()
            .is_none(),
        "a tree that is not there declares nothing"
    );

    let tree = root.join(".agents/skills/armer");
    fs::create_dir_all(&tree).unwrap();
    let declaration = tree.join("SKILL.md");
    fs::write(&declaration, "---\nname: armer\n---\nBody.\n").unwrap();
    let readable = installed_tree(&env, &scope, &lock, "armer").unwrap();
    assert_eq!(readable.map(|found| found.root), Some(tree));

    fs::set_permissions(&declaration, fs::Permissions::from_mode(0o000)).unwrap();
    // Root reads a mode-000 file, so there is no unreadable file to make.
    if fs::read_to_string(&declaration).is_ok() {
        return;
    }
    let err = installed_tree(&env, &scope, &lock, "armer").unwrap_err();
    assert!(
        err.to_string().contains("SKILL.md"),
        "the error did not name the file it could not read: {err}"
    );
}
