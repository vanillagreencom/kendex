use std::collections::BTreeSet;
use std::fs;

use super::*;
use crate::env::FakeOs;
use crate::lock::{Lock, LockEntry};
use crate::manifest::Method;

fn entry(kind: ItemKind, name: &str, source: &str, repo: &str) -> LockEntry {
    LockEntry {
        name: name.to_owned(),
        kind,
        harness: HarnessId::Claude,
        source: source.to_owned(),
        source_repo: repo.to_owned(),
        method: Method::Symlink,
        installed_at: "2026-01-01T00:00:00Z".to_owned(),
        source_hash: "hash".to_owned(),
        source_commit: None,
        rendered_hash: None,
        enabled: true,
        upstream_skills: None,
        emitted: None,
        registration: None,
        reasons: BTreeSet::from([crate::lock::Reason::Requested]),
    }
}

/// Marketplace, forked, adopted, and unmanaged content each read as what
/// they are — the one join the Library table consumes.
#[test]
fn origins_are_read_off_the_lock_manifest_and_scan() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    fs::create_dir_all(project.join(".claude/skills/stray")).unwrap();
    fs::write(
        project.join(".claude/skills/stray/SKILL.md"),
        "---\nname: stray\ndescription: found on disk\n---\nbody\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\
         [sources.cat]\n\
         repo = \"owner/repo\"\n\
         [skills.gh]\n\
         source = \"cat\"\n\
         [forks.skill.fk]\n\
         source = \"cat\"\n\
         repo = \"owner/repo\"\n\
         forked-at = \"2026-01-01\"\n",
    )
    .unwrap();
    let project = crate::paths::canonical(&project).unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };
    let mut lock = Lock {
        version: crate::lock::LOCK_VERSION,
        ..Lock::default()
    };
    for (name, source) in [
        ("gh", "cat"),
        ("fk", "local"),
        ("mine", "local"),
        ("here", "in-place"),
    ] {
        let repo = match source {
            "cat" => "owner/repo",
            "in-place" => "",
            _ => "local",
        };
        lock.entries.insert(
            crate::lock::entry_key(ItemKind::Skill, name, HarnessId::Claude),
            entry(ItemKind::Skill, name, source, repo),
        );
    }
    crate::lock::save(&crate::lock::lock_path(&env, &scope), &lock).unwrap();

    let rows = provenance(&env, std::slice::from_ref(&scope)).unwrap();
    let origin = |name: &str| {
        rows.iter()
            .find(|row| row.kind == ItemKind::Skill && row.name == name)
            .map(|row| row.origin.clone())
            .unwrap_or_else(|| panic!("no row for {name}"))
    };
    assert_eq!(
        origin("gh"),
        Origin::Marketplace {
            source: "cat".to_owned(),
            repo: "owner/repo".to_owned()
        }
    );
    assert_eq!(
        origin("fk"),
        Origin::Own {
            forked_from: Some("owner/repo".to_owned()),
            source: "local".to_owned()
        }
    );
    let own = |source: &str| Origin::Own {
        forked_from: None,
        source: source.to_owned(),
    };
    assert_eq!(origin("mine"), own("local"));
    assert_eq!(origin("here"), own("in-place"));
    assert_eq!(origin("stray"), Origin::Unmanaged);
    let stray = rows
        .iter()
        .find(|row| row.name == "stray")
        .expect("stray row");
    assert_eq!(stray.scope, Scope::Project { root: project });
    assert_eq!(stray.harness, HarnessId::Claude);
}

/// A damaged current lock is an error, never an empty provenance join.
#[test]
fn a_truncated_current_lock_fails_the_library_read() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    fs::create_dir_all(&project).unwrap();
    fs::write(project.join("kendex.toml"), "schema = 6\n").unwrap();
    fs::write(
        project.join(".kendex-lock.json"),
        format!(r#"{{"version":{}"#, crate::lock::LOCK_VERSION),
    )
    .unwrap();
    let scope = Scope::Project { root: project };

    assert!(
        matches!(
            provenance(&env, std::slice::from_ref(&scope)),
            Err(crate::error::CoreError::LockCorrupt { .. })
        ),
        "Library must surface a truncated lock"
    );
}
