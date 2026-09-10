//! Installing a template: into an empty place and a populated one, twice
//! over, and what a destination keeps once the template is gone.

use std::fs;

use super::super::*;
use super::create::{seeded, snapshot};
use super::skill;
use crate::model::Scope;

/// The whole project, saved with its own local package copied in.
#[allow(clippy::unwrap_used)]
fn template_of(project: &super::create::Project, name: &str) -> Template {
    let draft = draft_from_project(&project.env, &project.root).unwrap();
    create_from_project(
        &project.env,
        &project.root,
        &Chosen {
            name: name.to_owned(),
            members: draft
                .members
                .iter()
                .map(|member| member.key.clone())
                .collect(),
            locals: vec!["skill:stray".to_owned()],
            customizations: true,
            ..Chosen::default()
        },
    )
    .unwrap()
}

/// A fresh project directory this machine can install into.
#[allow(clippy::unwrap_used)]
fn destination(project: &super::create::Project, name: &str) -> Scope {
    let root = project.home.join(name);
    fs::create_dir_all(root.join(".claude")).unwrap();
    Scope::Project {
        root: root.canonicalize().unwrap(),
    }
}

/// What the template resolves to on this machine: which repository carries
/// its marketplace members, which copies it owns, and what it cannot
/// reach.
#[test]
#[allow(clippy::unwrap_used)]
fn a_resolution_names_the_repository_the_copies_and_what_is_missing() {
    let project = seeded();
    let template = template_of(&project, "Rust service");
    let resolution = resolve(&project.env, &template).unwrap();

    assert_eq!(resolution.missing, Vec::new());
    assert_eq!(resolution.groups.len(), 1, "{:?}", resolution.groups);
    let group = &resolution.groups[0];
    // Nothing subscribes to it personally yet, so the install would.
    assert_eq!(group.source, None);
    let items: Vec<&str> = group.items.iter().map(|item| item.name.as_str()).collect();
    assert!(items.contains(&"gh"), "{items:?}");
    assert!(items.contains(&"note"), "{items:?}");
    let copies: Vec<&str> = resolution
        .copies
        .iter()
        .map(|copy| copy.name.as_str())
        .collect();
    assert!(copies.contains(&"house-style"), "{copies:?}");
    assert!(copies.contains(&"stray"), "{copies:?}");
    assert_eq!(resolution.count(), template.members.len());
}

/// A copy the store no longer holds keeps its member visible and names it
/// as missing, and installing refuses rather than writing the rest.
#[test]
#[allow(clippy::unwrap_used)]
fn a_template_with_an_unreachable_member_refuses_before_it_writes_anything() {
    let project = seeded();
    let template = template_of(&project, "Rust service");
    let stray = template
        .members
        .iter()
        .find(|member| member.name == "stray")
        .unwrap();
    let MemberSource::Copy { copy, .. } = &stray.source else {
        panic!("stray should be a copy");
    };
    fs::remove_dir_all(copy_path(&project.env, &template, copy).unwrap()).unwrap();

    let resolution = resolve(&project.env, &template).unwrap();
    let missing: Vec<&str> = resolution
        .missing
        .iter()
        .map(|member| member.name.as_str())
        .collect();
    assert_eq!(missing, ["stray"], "{:?}", resolution.missing);

    let target = destination(&project, "fresh");
    let before = snapshot(match &target {
        Scope::Project { root } => root,
        Scope::Global => unreachable!("built as a project scope"),
    });
    assert!(matches!(
        install(&project.env, &template, &target, None, None),
        Err(CoreError::TemplateMemberUnavailable { .. })
    ));
    let Scope::Project { root } = &target else {
        unreachable!("built as a project scope")
    };
    assert_eq!(snapshot(root), before);
}

/// An install into an empty project writes every member, twice over: the
/// second run changes nothing, because a package already installed from
/// the same source is a no-op.
#[test]
#[allow(clippy::unwrap_used)]
fn installing_twice_leaves_the_same_project() {
    let project = seeded();
    let template = template_of(&project, "Rust service");
    let target = destination(&project, "fresh");
    let Scope::Project { root } = &target else {
        unreachable!("built as a project scope")
    };

    let landed = install(&project.env, &template, &target, None, None).unwrap();
    assert_eq!(landed.subscribed, ["cat"].map(|_| project_repo(&project)));
    let declared = landed.declared.join(", ");
    for wanted in [
        "skill gh",
        "command note",
        "skill house-style",
        "skill stray",
    ] {
        assert!(declared.contains(wanted), "{declared}");
    }
    // The template's own copies are the destination's own bytes now, not a
    // link back into the template.
    let copied = root
        .join(crate::source::LOCAL_SOURCE_DIR)
        .join("skills/house-style/SKILL.md");
    assert!(copied.is_file(), "{}", copied.display());
    assert!(!copied.is_symlink());
    // The carried customization landed.
    let manifest = fs::read_to_string(root.join("kendex.toml")).unwrap();
    assert!(manifest.contains("read this first"), "{manifest}");

    let after_first = snapshot(root);
    install(&project.env, &template, &target, None, None).unwrap();
    assert_eq!(
        snapshot(root),
        after_first,
        "a repeat install changed the project"
    );
}

/// The repository the fixture's marketplace is a folder at — what an
/// install subscribes to.
#[allow(clippy::unwrap_used)]
fn project_repo(project: &super::create::Project) -> String {
    crate::paths::slashed(&project.catalog.canonicalize().unwrap())
}

/// A populated destination keeps what it already had, and a local package
/// it owns under a template member's name with other bytes is a refusal
/// naming it — never a silent overwrite.
#[test]
#[allow(clippy::unwrap_used)]
fn a_populated_destination_keeps_its_own_packages_and_refuses_a_clash() {
    let project = seeded();
    let template = template_of(&project, "Rust service");
    let target = destination(&project, "populated");
    let Scope::Project { root } = &target else {
        unreachable!("built as a project scope")
    };
    // A package of the destination's own, unrelated to the template.
    let local = root.join(crate::source::LOCAL_SOURCE_DIR);
    skill(&local.join("skills"), "theirs", "their own bytes");
    fs::write(
        root.join("kendex.toml"),
        "schema = 6\n[skills.theirs]\nsource = \"local\"\n",
    )
    .unwrap();
    // And one wearing a template member's name with different bytes.
    skill(&local.join("skills"), "house-style", "their house style");

    // The marketplace group lands, then the local copy refuses. What
    // landed travels back with the reason it stopped: reporting the
    // refusal alone would deny the packages that are in, and reporting
    // success would deny the rest of the template that is not.
    let stopped = install(&project.env, &template, &target, None, None).unwrap();
    let why = stopped
        .stopped
        .clone()
        .unwrap_or_else(|| panic!("the run should say it stopped: {stopped:?}"));
    assert!(why.contains("house-style"), "{why}");
    assert!(
        stopped.declared.iter().any(|one| one == "skill gh"),
        "what landed before the refusal is reported: {:?}",
        stopped.declared
    );
    // Their bytes are untouched.
    let theirs = fs::read_to_string(local.join("skills/house-style/SKILL.md")).unwrap();
    assert!(theirs.contains("their house style"), "{theirs}");

    // With the clash gone, the install lands and the destination's own
    // package is still declared.
    fs::remove_dir_all(local.join("skills/house-style")).unwrap();
    install(&project.env, &template, &target, None, None).unwrap();
    let manifest = fs::read_to_string(root.join("kendex.toml")).unwrap();
    assert!(manifest.contains("[skills.theirs]"), "{manifest}");
    assert!(manifest.contains("[skills.house-style]"), "{manifest}");
    assert!(local.join("skills/theirs/SKILL.md").is_file());
}

/// A destination that already customized a package keeps its own value:
/// a template's settings fill gaps, they do not replace answers.
#[test]
#[allow(clippy::unwrap_used)]
fn a_destination_keeps_a_customization_it_already_set() {
    let project = seeded();
    let template = template_of(&project, "Rust service");
    let target = destination(&project, "opinionated");
    let Scope::Project { root } = &target else {
        unreachable!("built as a project scope")
    };
    fs::write(
        root.join("kendex.toml"),
        "schema = 6\n[skill-instructions]\n\"gh\" = \"ours, not the template's\"\n",
    )
    .unwrap();

    install(&project.env, &template, &target, None, None).unwrap();
    let manifest = fs::read_to_string(root.join("kendex.toml")).unwrap();
    assert!(manifest.contains("ours, not the template's"), "{manifest}");
    assert!(!manifest.contains("read this first"), "{manifest}");
}

/// A template is a saved selection, not a subscription: deleting it after
/// an install reaches nothing the install wrote.
#[test]
#[allow(clippy::unwrap_used)]
fn deleting_a_template_leaves_every_project_it_installed_into_alone() {
    let project = seeded();
    let template = template_of(&project, "Rust service");
    let target = destination(&project, "fresh");
    let Scope::Project { root } = &target else {
        unreachable!("built as a project scope")
    };
    install(&project.env, &template, &target, None, None).unwrap();
    let before = snapshot(root);

    delete(&project.env, "Rust service").unwrap();
    assert!(!env_store(&project.env, &template).exists());
    assert_eq!(
        snapshot(root),
        before,
        "deleting the template changed the project"
    );
    // And the copied package still reads, because the bytes are the
    // project's own.
    let copied = root
        .join(crate::source::LOCAL_SOURCE_DIR)
        .join("skills/house-style/SKILL.md");
    assert!(fs::read_to_string(copied).unwrap().contains("my own bytes"));
}

#[allow(clippy::unwrap_used)]
fn env_store(env: &Env, template: &Template) -> std::path::PathBuf {
    env.template_store_dir().join(&template.id)
}

/// Two members of one repository pinned at different revisions is not a
/// selection anything can install: a scope reads one repository at one
/// revision. Reported against the member that disagrees rather than
/// resolved by keeping whichever was seen first.
#[test]
#[allow(clippy::unwrap_used)]
fn members_of_one_repository_pinned_differently_are_reported_not_reduced() {
    let project = seeded();
    let repo = project_repo(&project);
    let pinned = |name: &str, rev: &str| Member {
        kind: MemberKind::Skill,
        name: name.to_owned(),
        enabled: true,
        source: MemberSource::Marketplace {
            repo: repo.clone(),
            rev: Some(rev.to_owned()),
        },
    };
    let template = create_from_selection(
        &project.env,
        "Two pins",
        vec![pinned("gh", "v1"), pinned("note", "v2")],
    )
    .unwrap();

    let resolution = resolve(&project.env, &template).unwrap();
    assert_eq!(resolution.missing.len(), 1, "{:?}", resolution.missing);
    assert_eq!(resolution.missing[0].name, "note");
    assert!(
        resolution.missing[0].why.contains("one revision"),
        "{}",
        resolution.missing[0].why
    );
    // And the install refuses whole rather than picking a pin.
    assert!(matches!(
        install(
            &project.env,
            &template,
            &destination(&project, "pinned"),
            None,
            None
        ),
        Err(CoreError::TemplateMemberUnavailable { .. })
    ));
}

/// Taking a fresh copy into a template that already holds one is a
/// replacement, and a refused replacement puts back what it replaced —
/// which is what the operation's own doc promises.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refused_replacement_leaves_the_template_as_it_was() {
    let project = seeded();
    let template = template_of(&project, "Rust service");
    let stray = template
        .members
        .iter()
        .find(|member| member.name == "stray")
        .unwrap();
    let MemberSource::Copy { copy, .. } = &stray.source else {
        panic!("stray should be a copy");
    };
    let stored = copy_path(&project.env, &template, copy).unwrap();
    let before = fs::read_to_string(stored.join("SKILL.md")).unwrap();

    // The project's copy has moved on, and a second member named in the
    // same call cannot be copied at all — the project holds no such
    // package, so the resolve refuses after the first write would have
    // gone in.
    skill(
        &project.root.join(".claude/skills"),
        "stray",
        "changed since the template was made",
    );
    let refused = add_from_project(
        &project.env,
        "Rust service",
        &project.root,
        &[
            MemberRef {
                kind: MemberKind::Skill,
                name: "stray".to_owned(),
                repo: None,
            },
            MemberRef {
                kind: MemberKind::Skill,
                name: "never-here".to_owned(),
                repo: None,
            },
        ],
    );
    assert!(refused.is_err(), "{refused:?}");
    // The bytes the template held are the bytes it still holds.
    assert_eq!(
        fs::read_to_string(stored.join("SKILL.md")).unwrap(),
        before,
        "a refused replacement changed the template's own copy"
    );
}
