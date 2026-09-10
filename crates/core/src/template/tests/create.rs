//! Creating a template from a project: what the draft offers, what a save
//! copies, and what the originating project looks like afterwards.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use super::super::*;
use super::{file_item, lock_entry, skill};
use crate::env::FakeOs;
use crate::model::{HarnessId, ItemKind, Scope};
use crate::test_util::rooted;

/// A project holding one of everything the draft has to tell apart: a
/// marketplace skill, the person's own local skill, a switched-off
/// marketplace command, an unmanaged skill and agent nothing declares, an
/// unmanaged agent in a format no catalog stores, and an MCP server that
/// lives inside a tool's configuration file.
#[allow(clippy::unwrap_used)]
pub(super) struct Project {
    /// Kept so the fixture outlives the test that holds it; every path
    /// below is the canonical spelling `rooted` bound.
    pub _tmp: tempfile::TempDir,
    pub home: PathBuf,
    pub env: Env,
    pub root: PathBuf,
    pub catalog: PathBuf,
}

#[allow(clippy::unwrap_used)]
pub(super) fn seeded() -> Project {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let catalog = home.join("catalog");
    skill(&catalog.join("skills"), "gh", "market bytes");
    file_item(
        &catalog.join("commands"),
        "note.md",
        "---\ndescription: a note\n---\nCommand body.\n",
    );
    fs::write(
        catalog.join("kendex.toml"),
        "[marketplace]\nname = \"cat\"\nlicense = \"MIT\"\n",
    )
    .unwrap();

    let root = home.join("app");
    // The person's own package, captured into the project's local source.
    let local = root.join(crate::source::LOCAL_SOURCE_DIR);
    skill(&local.join("skills"), "house-style", "my own bytes");
    // Content nothing manages: the local opt-in's candidates.
    skill(&root.join(".claude/skills"), "stray", "unmanaged bytes");
    file_item(
        &root.join(".claude/agents"),
        "drifter.md",
        "---\nname: drifter\ndescription: about drifter\n---\nAgent body.\n",
    );
    // An agent in a form a catalog cannot store: no frontmatter at all.
    file_item(&root.join(".claude/agents"), "raw.md", "No frontmatter.\n");
    fs::write(
        root.join("kendex.toml"),
        format!(
            "schema = 6\n\
             [sources.cat]\n{}\n\
             [skills.gh]\nsource = \"cat\"\n\
             [skills.house-style]\nsource = \"local\"\n\
             [commands.note]\nsource = \"cat\"\nenabled = false\n\
             [skill-instructions]\n\"gh\" = \"read this first\"\n\
             [bot-instructions]\nreviewers = [\"one\"]\n",
            crate::test_util::source_path(&catalog)
        ),
    )
    .unwrap();
    let root = root.canonicalize().unwrap();
    let scope = Scope::Project { root: root.clone() };
    let mut lock = crate::lock::Lock {
        version: crate::lock::LOCK_VERSION,
        ..crate::lock::Lock::default()
    };
    for (kind, name, source) in [
        (ItemKind::Skill, "gh", "cat"),
        (ItemKind::Skill, "house-style", "local"),
        (ItemKind::Command, "note", "cat"),
    ] {
        lock.entries.insert(
            crate::lock::entry_key(kind, name, HarnessId::Claude),
            lock_entry(kind, name, source),
        );
    }
    crate::lock::save(&crate::lock::lock_path(&env, &scope), &lock).unwrap();
    Project {
        _tmp: tmp,
        home,
        env,
        root,
        catalog,
    }
}

/// Every byte under a root, so a project can be compared with itself.
#[allow(clippy::unwrap_used)]
pub(super) fn snapshot(root: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut held = BTreeMap::new();
    walk(root, root, &mut held);
    held
}

#[allow(clippy::unwrap_used)]
fn walk(root: &Path, dir: &Path, into: &mut BTreeMap<String, Vec<u8>>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() && !path.is_symlink() {
            walk(root, &path, into);
            continue;
        }
        let key = crate::paths::slashed(path.strip_prefix(root).unwrap());
        let bytes = match path.is_symlink() {
            true => fs::read_link(&path)
                .unwrap()
                .into_os_string()
                .into_encoded_bytes(),
            false => fs::read(&path).unwrap_or_default(),
        };
        into.insert(key, bytes);
    }
}

#[allow(clippy::unwrap_used)]
fn member<'a>(draft: &'a Draft, key: &str) -> &'a DraftMember {
    draft
        .members
        .iter()
        .find(|member| member.key == key)
        .unwrap_or_else(|| panic!("no draft member {key}; got {:?}", draft.members))
}

/// The draft starts with every managed package in, the local packages out,
/// and everything a template cannot carry named with its reason.
#[test]
#[allow(clippy::unwrap_used)]
fn the_draft_includes_every_managed_package_and_offers_the_local_ones() {
    let project = seeded();
    let draft = draft_from_project(&project.env, &project.root).unwrap();

    let keys: Vec<String> = draft
        .members
        .iter()
        .map(|member| member.key.clone())
        .collect();
    assert!(keys.contains(&"skill:gh".to_owned()), "{keys:?}");
    assert!(keys.contains(&"skill:house-style".to_owned()), "{keys:?}");
    assert!(keys.contains(&"command:note".to_owned()), "{keys:?}");

    // A marketplace package is saved by identity; the person's own one is
    // copied.
    assert!(matches!(
        member(&draft, "skill:gh").origin,
        DraftOrigin::Marketplace { .. }
    ));
    assert!(matches!(
        member(&draft, "skill:house-style").origin,
        DraftOrigin::Copy { .. }
    ));
    // Switched off in the project, switched off in the draft — never
    // quietly enabled.
    assert!(!member(&draft, "command:note").enabled);

    // The local opt-in's candidates: on offer, and nothing is ticked.
    let locals: Vec<String> = draft.locals.iter().map(|local| local.key.clone()).collect();
    assert!(locals.contains(&"skill:stray".to_owned()), "{locals:?}");
    assert!(locals.contains(&"agent:drifter".to_owned()), "{locals:?}");
    // The agent no catalog can store is not on offer, and says why.
    let raw = draft
        .excluded
        .iter()
        .find(|gone| gone.name == "raw")
        .unwrap_or_else(|| panic!("raw should be excluded: {:?}", draft.excluded));
    assert!(!raw.why.is_empty());
    assert!(!locals.iter().any(|key| key == "agent:raw"), "{locals:?}");
    assert_eq!(draft.incomplete, None);
    assert_eq!(draft.suggested_name, "app");
}

/// Saving with the local opt-in off saves the managed selection alone.
/// Saving with it on copies the bytes, and the copies are the project's
/// bytes rather than a rendering of them.
#[test]
#[allow(clippy::unwrap_used)]
fn the_local_opt_in_decides_whether_unmanaged_packages_are_copied() {
    let project = seeded();
    let managed: Vec<String> = draft_from_project(&project.env, &project.root)
        .unwrap()
        .members
        .iter()
        .map(|member| member.key.clone())
        .collect();

    let off = create_from_project(
        &project.env,
        &project.root,
        &Chosen {
            name: "Off".to_owned(),
            members: managed.clone(),
            ..Chosen::default()
        },
    )
    .unwrap();
    assert!(!off.members.iter().any(|member| member.name == "stray"));

    let on = create_from_project(
        &project.env,
        &project.root,
        &Chosen {
            name: "On".to_owned(),
            members: managed,
            locals: vec!["skill:stray".to_owned(), "agent:drifter".to_owned()],
            ..Chosen::default()
        },
    )
    .unwrap();
    let stray = on
        .members
        .iter()
        .find(|member| member.name == "stray")
        .unwrap();
    let MemberSource::Copy { copy, .. } = &stray.source else {
        panic!("stray should be a copy: {:?}", stray.source);
    };
    let stored = copy_path(&project.env, &on, copy).unwrap();
    assert_eq!(
        fs::read(stored.join("SKILL.md")).unwrap(),
        fs::read(project.root.join(".claude/skills/stray/SKILL.md")).unwrap()
    );
    // The person's own managed package is copied too, so the template
    // still installs it after the project moves.
    let mine = on
        .members
        .iter()
        .find(|member| member.name == "house-style")
        .unwrap();
    let MemberSource::Copy { copy, .. } = &mine.source else {
        panic!("house-style should be a copy: {:?}", mine.source);
    };
    assert!(
        copy_path(&project.env, &on, copy)
            .unwrap()
            .join("SKILL.md")
            .is_file()
    );
}

/// The one thing this action must never do: change the project it read.
/// Every byte under the project root is compared before and after — a
/// success, a cancel (nothing called), and a refusal.
#[test]
#[allow(clippy::unwrap_used)]
fn the_originating_project_is_byte_identical_after_success_and_after_a_refusal() {
    let project = seeded();
    let before = snapshot(&project.root);
    let draft = draft_from_project(&project.env, &project.root).unwrap();
    let managed: Vec<String> = draft
        .members
        .iter()
        .map(|member| member.key.clone())
        .collect();

    // Reading the draft is the cancel case: the modal opened and nothing
    // was saved.
    assert_eq!(
        snapshot(&project.root),
        before,
        "reading the project changed it"
    );

    create_from_project(
        &project.env,
        &project.root,
        &Chosen {
            name: "Kept".to_owned(),
            members: managed.clone(),
            locals: vec!["skill:stray".to_owned(), "agent:drifter".to_owned()],
            customizations: true,
            ..Chosen::default()
        },
    )
    .unwrap();
    assert_eq!(
        snapshot(&project.root),
        before,
        "a saved template changed the project"
    );

    // A refusal: the name is already taken.
    assert!(matches!(
        create_from_project(
            &project.env,
            &project.root,
            &Chosen {
                name: "Kept".to_owned(),
                members: managed,
                locals: vec!["skill:stray".to_owned()],
                ..Chosen::default()
            },
        ),
        Err(CoreError::TemplateNameTaken { .. })
    ));
    assert_eq!(
        snapshot(&project.root),
        before,
        "a refused save changed the project"
    );
    // And the refusal left no half-built template behind.
    assert_eq!(list(&project.env).unwrap().len(), 1);
}

/// The customization opt-in carries the package settings and nothing else:
/// a project setting that is not about a package stays with the project.
#[test]
#[allow(clippy::unwrap_used)]
fn the_customization_opt_in_carries_package_settings_only() {
    let project = seeded();
    let managed: Vec<String> = draft_from_project(&project.env, &project.root)
        .unwrap()
        .members
        .iter()
        .map(|member| member.key.clone())
        .collect();

    let off = create_from_project(
        &project.env,
        &project.root,
        &Chosen {
            name: "Off".to_owned(),
            members: managed.clone(),
            ..Chosen::default()
        },
    )
    .unwrap();
    assert!(off.customizations.is_empty());

    let on = create_from_project(
        &project.env,
        &project.root,
        &Chosen {
            name: "On".to_owned(),
            members: managed,
            customizations: true,
            ..Chosen::default()
        },
    )
    .unwrap();
    assert_eq!(
        on.customizations
            .skill_instructions
            .get("gh")
            .map(String::as_str),
        Some("read this first")
    );
    // The review-bot table is the project's, not any package's.
    let text = fs::read_to_string(project.env.templates_file()).unwrap();
    assert!(!text.contains("reviewers"), "{text}");
}

/// A package installed from a marketplace and edited here is two things
/// under one name. Neither is picked for the person: the save refuses
/// until they choose, and each choice records what it says it does.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edited_marketplace_package_requires_a_choice() {
    let project = seeded();
    // The installed copy drifts from the marketplace's bytes.
    skill(
        &project.root.join(".claude/skills"),
        "gh",
        "edited here, not upstream",
    );
    let draft = draft_from_project(&project.env, &project.root).unwrap();
    let DraftOrigin::Choice { hash, .. } = &member(&draft, "skill:gh").origin else {
        panic!(
            "gh should be a choice: {:?}",
            member(&draft, "skill:gh").origin
        );
    };
    assert!(hash.is_some());

    let chosen = |name: &str, sides: BTreeMap<String, Side>| Chosen {
        name: name.to_owned(),
        members: vec!["skill:gh".to_owned()],
        sides,
        ..Chosen::default()
    };
    // Unanswered, the save refuses and says what has to be decided.
    assert!(matches!(
        create_from_project(
            &project.env,
            &project.root,
            &chosen("Unanswered", BTreeMap::new())
        ),
        Err(CoreError::TemplateMemberUnresolved { .. })
    ));

    let upstream = create_from_project(
        &project.env,
        &project.root,
        &chosen(
            "Upstream",
            BTreeMap::from([("skill:gh".to_owned(), Side::Marketplace)]),
        ),
    )
    .unwrap();
    assert!(matches!(
        upstream.members[0].source,
        MemberSource::Marketplace { .. }
    ));

    let mine = create_from_project(
        &project.env,
        &project.root,
        &chosen(
            "Mine",
            BTreeMap::from([("skill:gh".to_owned(), Side::Copy)]),
        ),
    )
    .unwrap();
    let MemberSource::Copy { copy, from } = &mine.members[0].source else {
        panic!("gh should be a copy: {:?}", mine.members[0].source);
    };
    // The bytes are the edited ones, and the copy still says where the
    // package came from.
    let stored = copy_path(&project.env, &mine, copy).unwrap();
    let text = fs::read_to_string(stored.join("SKILL.md")).unwrap();
    assert!(text.contains("edited here, not upstream"), "{text}");
    assert!(from.is_some());
}

/// A choice naming something the draft does not list is refused, and so is
/// a selection with nothing in it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_selection_is_checked_against_the_project_it_claims_to_come_from() {
    let project = seeded();
    assert!(matches!(
        create_from_project(
            &project.env,
            &project.root,
            &Chosen {
                name: "Invented".to_owned(),
                members: vec!["skill:never-existed".to_owned()],
                ..Chosen::default()
            },
        ),
        Err(CoreError::TemplateMemberUnknown { .. })
    ));
    assert!(matches!(
        create_from_project(
            &project.env,
            &project.root,
            &Chosen {
                name: "Empty".to_owned(),
                ..Chosen::default()
            },
        ),
        Err(CoreError::TemplateEmpty)
    ));
    assert!(list(&project.env).unwrap().is_empty());
}

/// One package several tools read from one shared folder is one package.
/// Counted per installation it would be saved twice, and the second copy
/// would clash with the first.
#[test]
#[allow(clippy::unwrap_used)]
fn a_package_several_tools_read_is_counted_once() {
    let project = seeded();
    // A second tool reading the same shared tree, and a third root the
    // scan also sees.
    skill(
        &project.root.join(".agents/skills"),
        "stray",
        "unmanaged bytes",
    );
    let draft = draft_from_project(&project.env, &project.root).unwrap();
    let strays = draft
        .locals
        .iter()
        .filter(|local| local.name == "stray")
        .count();
    assert_eq!(strays, 1, "{:?}", draft.locals);
    let gh = draft.members.iter().filter(|m| m.name == "gh").count();
    assert_eq!(gh, 1, "{:?}", draft.members);
}
