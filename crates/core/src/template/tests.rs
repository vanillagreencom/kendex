//! The template index surface: what a name may be, and what rename and
//! delete do to the store and to what was installed from it.

use std::fs;
use std::path::Path;

use super::*;
use crate::env::FakeOs;
use crate::model::{HarnessId, ItemKind};
use crate::test_util::rooted;

mod create;
mod install;

/// A skill tree, the shape every kind that is a tree takes.
#[allow(clippy::unwrap_used)]
pub(super) fn skill(dir: &Path, name: &str, body: &str) {
    let skill = dir.join(name);
    fs::create_dir_all(&skill).unwrap();
    fs::write(
        skill.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: about {name}\n---\n{body}\n"),
    )
    .unwrap();
}

/// One item that is a file rather than a tree.
#[allow(clippy::unwrap_used)]
pub(super) fn file_item(dir: &Path, file: &str, text: &str) {
    fs::create_dir_all(dir).unwrap();
    fs::write(dir.join(file), text).unwrap();
}

/// A lock entry, so a declared item reads as installed rather than as
/// content nothing manages.
#[allow(clippy::unwrap_used)]
pub(super) fn lock_entry(kind: ItemKind, name: &str, source: &str) -> crate::lock::LockEntry {
    crate::lock::LockEntry {
        name: name.to_owned(),
        kind,
        harness: HarnessId::Claude,
        source: source.to_owned(),
        source_repo: source.to_owned(),
        method: crate::manifest::Method::Symlink,
        installed_at: "2026-01-01T00:00:00Z".to_owned(),
        source_hash: "hash".to_owned(),
        source_commit: None,
        rendered_hash: None,
        enabled: true,
        upstream_skills: None,
        emitted: None,
        registration: None,
        reasons: std::collections::BTreeSet::from([crate::lock::Reason::Requested]),
    }
}

/// A fake home with nothing in it, for the index tests.
#[allow(clippy::unwrap_used)]
pub(super) fn home() -> (tempfile::TempDir, Env) {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let env = Env::fake(&root, FakeOs::Linux);
    (tmp, env)
}

#[allow(clippy::unwrap_used)]
pub(super) fn saved(env: &Env, name: &str) -> Template {
    create_from_selection(
        env,
        name,
        vec![Member {
            kind: MemberKind::Skill,
            name: "code-quality".to_owned(),
            enabled: true,
            source: MemberSource::Marketplace {
                repo: "vanillagreencom/kendex".to_owned(),
                rev: None,
            },
        }],
    )
    .unwrap()
}

/// The index is the settings file, so a template written by one shell has
/// to read back whole in the other. Every member shape at once, because a
/// field that does not survive the round trip is a member that installs
/// something else.
#[test]
#[allow(clippy::unwrap_used)]
fn a_saved_template_reads_back_exactly_as_it_was_written() {
    let (_tmp, env) = home();
    let members = vec![
        Member {
            kind: MemberKind::Skill,
            name: "code-quality".to_owned(),
            enabled: true,
            source: MemberSource::Marketplace {
                repo: "vanillagreencom/kendex".to_owned(),
                rev: Some("v2".to_owned()),
            },
        },
        Member {
            kind: MemberKind::Bundle,
            name: "starter".to_owned(),
            enabled: false,
            source: MemberSource::Marketplace {
                repo: "someone/else".to_owned(),
                rev: None,
            },
        },
        Member {
            kind: MemberKind::Agent,
            name: "house".to_owned(),
            enabled: true,
            source: MemberSource::Copy {
                copy: "agents/house.md".to_owned(),
                from: Some("someone/else".to_owned()),
            },
        },
    ];
    let written = insert(
        &env,
        Template {
            name: "Rust service".to_owned(),
            id: String::new(),
            members: members.clone(),
            customizations: Customizations::default(),
        },
    )
    .unwrap();
    assert_eq!(written.members, members);
    assert_eq!(get(&env, "Rust service").unwrap(), written);
    // Read off the file itself, not off the copy the write returned: a
    // field the serializer drops would otherwise pass on the value still
    // in memory.
    let text = fs::read_to_string(env.templates_file()).unwrap();
    assert_eq!(
        toml::from_str::<index::Index>(&text).unwrap().templates,
        vec![written]
    );
}

/// The name rules, one row each. A duplicate never overwrites: creation
/// refuses and the template that was there is untouched.
#[test]
#[allow(clippy::unwrap_used)]
fn a_name_is_required_bounded_and_never_reused() {
    let (_tmp, env) = home();
    saved(&env, "Rust service");
    let member = || {
        vec![Member {
            kind: MemberKind::Skill,
            name: "other".to_owned(),
            enabled: true,
            source: MemberSource::Marketplace {
                repo: "a/b".to_owned(),
                rev: None,
            },
        }]
    };
    let rows: [(&str, &str, bool); 4] = [
        ("empty", "", false),
        ("only spaces", "   ", false),
        ("already taken", "Rust service", false),
        ("past the ceiling", &"x".repeat(81), false),
    ];
    for (row, name, allowed) in rows {
        let result = create_from_selection(&env, name, member());
        assert_eq!(result.is_ok(), allowed, "{row}");
    }
    // The refusals left the one template alone, and its members with it.
    let held = list(&env).unwrap();
    assert_eq!(held.len(), 1);
    assert_eq!(held[0].name, "Rust service");
    assert_eq!(held[0].members.len(), 1);
    // A name that is free saves, and the trim is what a person typed
    // rather than what they leaned on the space bar for.
    let fresh = create_from_selection(&env, "  Web app  ", member()).unwrap();
    assert_eq!(fresh.name, "Web app");
}

/// A rename moves no bytes: the store is keyed by the id the create
/// reserved, so a renamed template's copies are where they were.
#[test]
#[allow(clippy::unwrap_used)]
fn a_rename_keeps_the_store_and_the_id() {
    let (_tmp, env) = home();
    let before = saved(&env, "Rust service");
    let store = env.template_store_dir().join(&before.id);
    fs::create_dir_all(&store).unwrap();
    fs::write(store.join("marker"), b"kept").unwrap();

    let after = rename(&env, "Rust service", "Rust API").unwrap();
    assert_eq!(after.id, before.id);
    assert_eq!(after.members, before.members);
    assert_eq!(fs::read(store.join("marker")).unwrap(), b"kept");
    assert!(matches!(
        get(&env, "Rust service"),
        Err(CoreError::NoSuchTemplate { .. })
    ));
    // A rename onto a name another template holds refuses, and neither
    // template moves.
    saved(&env, "Web app");
    assert!(matches!(
        rename(&env, "Rust API", "Web app"),
        Err(CoreError::TemplateNameTaken { .. })
    ));
    assert_eq!(get(&env, "Rust API").unwrap().id, before.id);
}

/// Delete takes the index entry and the template's own store, and nothing
/// else. What was installed from it lives in the destination's own files.
#[test]
#[allow(clippy::unwrap_used)]
fn delete_removes_the_store_and_refuses_a_name_it_does_not_hold() {
    let (_tmp, env) = home();
    let template = saved(&env, "Rust service");
    let store = env.template_store_dir().join(&template.id);
    fs::create_dir_all(&store).unwrap();
    fs::write(store.join("marker"), b"kept").unwrap();

    delete(&env, "Rust service").unwrap();
    assert!(list(&env).unwrap().is_empty());
    assert!(!store.exists());
    assert!(matches!(
        delete(&env, "Rust service"),
        Err(CoreError::NoSuchTemplate { .. })
    ));
}

/// Members are added by identity: the same package from the same
/// marketplace twice is one member, and the same name from two
/// marketplaces is two.
#[test]
#[allow(clippy::unwrap_used)]
fn members_deduplicate_by_identity_and_not_by_name() {
    let (_tmp, env) = home();
    saved(&env, "Rust service");
    let from = |repo: &str| Member {
        kind: MemberKind::Skill,
        name: "code-quality".to_owned(),
        enabled: true,
        source: MemberSource::Marketplace {
            repo: repo.to_owned(),
            rev: None,
        },
    };
    let again = add_members(
        &env,
        "Rust service",
        vec![from("vanillagreencom/kendex"), from("someone/else")],
    )
    .unwrap();
    assert_eq!(again.members.len(), 2);
    let repos: Vec<_> = again
        .members
        .iter()
        .map(|member| match &member.source {
            MemberSource::Marketplace { repo, .. } => repo.clone(),
            MemberSource::Copy { copy, .. } => copy.clone(),
        })
        .collect();
    assert_eq!(repos, ["vanillagreencom/kendex", "someone/else"]);

    let fewer = remove_members(
        &env,
        "Rust service",
        &[MemberRef {
            kind: MemberKind::Skill,
            name: "code-quality".to_owned(),
        }],
    )
    .unwrap();
    assert!(fewer.members.is_empty());
}
