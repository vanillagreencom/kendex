//! Installing a template: into an empty place and a populated one, twice
//! over, and what a destination keeps once the template is gone.

use std::fs;

use super::super::*;
use super::create::{seeded, snapshot};
use super::skill;
use crate::env::FakeOs;
use crate::model::{HarnessId, Scope};
use crate::test_util::rooted;

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
            fingerprint: draft.fingerprint.clone(),
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

/// A home with no personal manifest yet is read as its first write would
/// create it, so a member of the default marketplace resolves onto the
/// seeded subscription and the install reuses it — rather than the
/// unsubscribed arm subscribing a second time and being refused as a
/// duplicate before anything lands. Never fetched, the subscription
/// stands as any declared one does: the member waits on a refresh. Read
/// the absent file as empty and this case is what goes red.
#[test]
#[allow(clippy::unwrap_used)]
fn a_member_of_the_default_marketplace_resolves_onto_the_seeded_subscription() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(home, FakeOs::Linux);
    assert!(!crate::manifest::manifest_path(&env, &Scope::Global).exists());
    let template = Template {
        name: "Starter".to_owned(),
        id: "starter".to_owned(),
        members: vec![Member {
            kind: MemberKind::Skill,
            name: "gh".to_owned(),
            enabled: true,
            source: MemberSource::Marketplace {
                repo: crate::manifest::DEFAULT_SOURCE_REPO.to_owned(),
                rev: None,
            },
        }],
        customizations: Customizations::default(),
    };

    let resolution = resolve(&env, &template).unwrap();
    assert_eq!(resolution.groups.len(), 1, "{:?}", resolution.groups);
    assert_eq!(
        resolution.groups[0].source.as_deref(),
        Some(crate::manifest::DEFAULT_SOURCE_NAME)
    );
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

    let landed = install(
        &project.env,
        &template,
        &target,
        Some(vec![HarnessId::Claude]),
        None,
    )
    .unwrap();
    assert_eq!(landed.subscribed, ["cat"].map(|_| project_repo(&project)));
    let declared = landed.declared.join(", ");
    for wanted in [
        "skill gh",
        "command note",
        "skill house-style",
        "command preview",
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
    // A copied command is rendered from the local source like the skill
    // beside it: the reserved source offers its commands by name.
    let rendered = root.join(".claude/commands/preview.md");
    assert!(rendered.is_file(), "{}", rendered.display());
    // The carried customization landed.
    let manifest = fs::read_to_string(root.join("kendex.toml")).unwrap();
    assert!(manifest.contains("read this first"), "{manifest}");

    let after_first = snapshot(root);
    install(
        &project.env,
        &template,
        &target,
        Some(vec![HarnessId::Claude]),
        None,
    )
    .unwrap();
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
                which: MemberWhich::Copy,
            },
            MemberRef {
                kind: MemberKind::Skill,
                name: "never-here".to_owned(),
                which: MemberWhich::Copy,
            },
        ],
        &LicenseAnswer::default(),
    );
    assert!(refused.is_err(), "{refused:?}");
    // The bytes the template held are the bytes it still holds.
    assert_eq!(
        fs::read_to_string(stored.join("SKILL.md")).unwrap(),
        before,
        "a refused replacement changed the template's own copy"
    );
}

/// A package the project had switched off stays switched off where the
/// template installs it. `Member::enabled`'s own doc says so, and the
/// copy path honoured it while the marketplace path dropped it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_member_saved_switched_off_installs_switched_off() {
    let project = seeded();
    // The fixture project has `note` declared with enabled = false and
    // `gh` enabled, both from the same marketplace.
    let draft = draft_from_project(&project.env, &project.root).unwrap();
    let template = create_from_project(
        &project.env,
        &project.root,
        &Chosen {
            name: "Mixed switches".to_owned(),
            members: draft
                .members
                .iter()
                .filter(|member| member.name == "gh" || member.name == "note")
                .map(|member| member.key.clone())
                .collect(),
            fingerprint: draft.fingerprint.clone(),
            ..Chosen::default()
        },
    )
    .unwrap();
    let off = template
        .members
        .iter()
        .find(|member| member.name == "note")
        .unwrap();
    assert!(!off.enabled, "the saved switch should be off");

    let target = destination(&project, "switches");
    let Scope::Project { root } = &target else {
        unreachable!("built as a project scope")
    };
    // A harness to render into: the switch is about the artifact, and a
    // destination nothing renders to has none to look at.
    install(
        &project.env,
        &template,
        &target,
        Some(vec![HarnessId::Claude]),
        None,
    )
    .unwrap();

    // The files, not the declaration. The manifest saying `enabled =
    // false` over a file rendered enabled is the defect this row exists
    // for, so what is asserted is what is on disk.
    let parked = root.join(".claude/commands/note.md.disabled");
    let live = root.join(".claude/commands/note.md");
    assert!(parked.is_file(), "{}", parked.display());
    assert!(!live.exists(), "{}", live.display());
    let on = root.join(".claude/skills/gh/SKILL.md");
    assert!(on.is_file(), "{}", on.display());
}

/// A carried customization reaches the file it is about, not only the
/// manifest that names it.
///
/// The carrier runs after the add that rendered the destination, so a
/// manifest-only write left the installed skill without the instruction
/// its own manifest said it carried — until some later apply happened to
/// run. What is asserted is the rendered file.
#[test]
#[allow(clippy::unwrap_used)]
fn a_carried_customization_reaches_the_installed_file() {
    let project = seeded();
    let draft = draft_from_project(&project.env, &project.root).unwrap();
    let template = create_from_project(
        &project.env,
        &project.root,
        &Chosen {
            name: "With settings".to_owned(),
            members: draft
                .members
                .iter()
                .filter(|member| member.name == "gh")
                .map(|member| member.key.clone())
                .collect(),
            customizations: true,
            fingerprint: draft.fingerprint.clone(),
            ..Chosen::default()
        },
    )
    .unwrap();
    assert!(
        !template.customizations.is_empty(),
        "the fixture should carry a skill instruction: {:?}",
        template.customizations
    );

    let target = destination(&project, "instructed");
    let Scope::Project { root } = &target else {
        unreachable!("built as a project scope")
    };
    install(
        &project.env,
        &template,
        &target,
        Some(vec![HarnessId::Claude]),
        None,
    )
    .unwrap();

    let rendered = fs::read_to_string(root.join(".claude/skills/gh/SKILL.md")).unwrap();
    assert!(rendered.contains("read this first"), "{rendered}");
}

/// Removing a member takes its customizations with it, and a later install
/// carries only what the template still holds.
///
/// The customizations are keyed by package name and nothing else in the
/// template ties them to a member, so a removal that left them behind kept
/// declarations for a package the template no longer holds — and
/// `carry_customizations` writes every key the template carries into the
/// destination's manifest without asking whether a member of that name is
/// still there. Left behind they would be saved, shown, and installed into
/// every later destination.
#[test]
#[allow(clippy::unwrap_used)]
fn removing_a_member_takes_its_customizations_out_of_the_template() {
    let project = seeded();
    // A second instruction, so one member's settings can be told from the
    // other's on both sides of the removal.
    let declared = project.root.join("kendex.toml");
    let manifest = fs::read_to_string(&declared).unwrap();
    fs::write(
        &declared,
        manifest.replace(
            "\"gh\" = \"read this first\"",
            "\"gh\" = \"read this first\"\n\"house-style\" = \"and this one after\"",
        ),
    )
    .unwrap();

    let draft = draft_from_project(&project.env, &project.root).unwrap();
    let template = create_from_project(
        &project.env,
        &project.root,
        &Chosen {
            name: "Both".to_owned(),
            members: draft
                .members
                .iter()
                .filter(|member| member.name == "gh" || member.name == "house-style")
                .map(|member| member.key.clone())
                .collect(),
            customizations: true,
            fingerprint: draft.fingerprint.clone(),
            ..Chosen::default()
        },
    )
    .unwrap();
    assert_eq!(
        template
            .customizations
            .skill_instructions
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        vec!["gh", "house-style"],
        "the fixture should carry both instructions"
    );

    let after = remove_members(
        &project.env,
        "Both",
        &[MemberRef {
            kind: MemberKind::Skill,
            name: "gh".to_owned(),
            which: MemberWhich::Any,
        }],
    )
    .unwrap();
    assert_eq!(
        after
            .customizations
            .skill_instructions
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        vec!["house-style"],
        "the removed package's instruction stayed in the template"
    );

    // And the install writes what the template still holds, and only that.
    let target = destination(&project, "pruned");
    let Scope::Project { root } = &target else {
        unreachable!("built as a project scope")
    };
    install(
        &project.env,
        &after,
        &target,
        Some(vec![HarnessId::Claude]),
        None,
    )
    .unwrap();
    let written = fs::read_to_string(root.join("kendex.toml")).unwrap();
    assert!(written.contains("and this one after"), "{written}");
    assert!(!written.contains("read this first"), "{written}");
}

/// One kind and name claimed by two members is not installable anywhere,
/// so the resolution says so and the install writes nothing.
///
/// The storage model allows the shape on purpose — a template may hold one
/// package from two marketplaces, and as a copy of its own beside a
/// marketplace's, which is what MemberWhich carries three states for — but
/// a place declares one package under one name. Unanswered, the preview
/// claimed the whole template installs and the run proved otherwise
/// half-way through: the second group's add refused with the first group's
/// writes on disk, and a copy taken after a marketplace member of the same
/// name replaced the declaration the same run had just written.
#[test]
#[allow(clippy::unwrap_used)]
fn one_name_claimed_by_two_members_refuses_before_anything_is_written() {
    let project = seeded();
    let market = |repo: &str| Member {
        kind: MemberKind::Skill,
        name: "gh".to_owned(),
        enabled: true,
        source: MemberSource::Marketplace {
            repo: repo.to_owned(),
            rev: None,
        },
    };

    // Two marketplaces offering one name.
    let twins = create_from_selection(
        &project.env,
        "Twins",
        vec![market("owner/first"), market("owner/second")],
    )
    .unwrap();

    // A marketplace member beside this template's own copy of that name.
    skill(
        &project.root.join(".claude/skills"),
        "gh",
        "edited here, not upstream",
    );
    let draft = draft_from_project(&project.env, &project.root).unwrap();
    create_from_project(
        &project.env,
        &project.root,
        &Chosen {
            name: "Both ways".to_owned(),
            fingerprint: draft.fingerprint,
            members: vec!["skill:gh".to_owned()],
            sides: std::collections::BTreeMap::from([(
                "skill:gh".to_owned(),
                Side::Copy {
                    license: LicenseAnswer {
                        confirmed: true,
                        basis: None,
                    },
                },
            )]),
            ..Chosen::default()
        },
    )
    .unwrap();
    let both = add_members(&project.env, "Both ways", vec![market("owner/first")]).unwrap();
    assert_eq!(both.members.len(), 2, "{:?}", both.members);

    for (template, claimants) in [
        (&twins, vec!["owner/first", "owner/second"]),
        (&both, vec!["owner/first", "own copy"]),
    ] {
        let resolution = resolve(&project.env, template).unwrap();
        // One row, about the name rather than about either claimant, naming
        // both of them.
        assert_eq!(resolution.missing.len(), 1, "{:?}", resolution.missing);
        let row = &resolution.missing[0];
        assert_eq!(
            (row.kind, row.name.as_str(), &row.which),
            (MemberKind::Skill, "gh", &MemberWhich::Any)
        );
        for claimant in &claimants {
            assert!(row.why.contains(claimant), "{}", row.why);
        }
        // And neither claimant is offered as installable, or the preview
        // would say the template installs and refuse in the same breath.
        assert_eq!(resolution.groups, Vec::new());
        assert_eq!(resolution.copies, Vec::new());

        // Nothing is written: not a subscription, not a declaration, not a
        // byte of a copy.
        let target = destination(&project, &format!("into-{}", template.id));
        let Scope::Project { root } = &target else {
            unreachable!("built as a project scope")
        };
        let before = snapshot(root);
        let refused = install(
            &project.env,
            template,
            &target,
            Some(vec![HarnessId::Claude]),
            None,
        );
        let Err(CoreError::TemplateMemberUnavailable { why, .. }) = refused else {
            panic!("a contested name should refuse the install: {refused:?}");
        };
        assert!(why.contains("declares one package under a name"), "{why}");
        assert_eq!(
            snapshot(root),
            before,
            "the refused install wrote into {}",
            root.display()
        );
    }
}

/// A bundle and a plugin are two kinds and one `[bundles.<name>]`, so one
/// name held as both is one contested name: resolution refuses it before
/// anything is written, naming both claimants, and under two names the
/// pair installs. Keyed on the member kind instead, the preview offered
/// both and the install declared the first and refused the second with the
/// first's writes on disk.
#[test]
#[allow(clippy::unwrap_used)]
fn a_bundle_and_a_plugin_under_one_name_are_one_contested_name() {
    let project = seeded();
    let market = |kind: MemberKind, name: &str, repo: &str| Member {
        kind,
        name: name.to_owned(),
        enabled: true,
        source: MemberSource::Marketplace {
            repo: repo.to_owned(),
            rev: None,
        },
    };

    let clash = create_from_selection(
        &project.env,
        "Clash",
        vec![
            market(MemberKind::Bundle, "review", "owner/first"),
            market(MemberKind::Plugin, "review", "owner/second"),
        ],
    )
    .unwrap();
    let resolution = resolve(&project.env, &clash).unwrap();
    assert_eq!(resolution.missing.len(), 1, "{:?}", resolution.missing);
    let row = &resolution.missing[0];
    assert_eq!(
        (row.kind, row.name.as_str(), &row.which),
        (MemberKind::Bundle, "review", &MemberWhich::Any)
    );
    for claimant in [
        "bundle 'review' from owner/first",
        "plugin 'review' from owner/second",
    ] {
        assert!(row.why.contains(claimant), "{}", row.why);
    }
    assert_eq!(resolution.groups, Vec::new());

    let target = destination(&project, "into-clash");
    let Scope::Project { root } = &target else {
        unreachable!("built as a project scope")
    };
    let before = snapshot(root);
    let refused = install(
        &project.env,
        &clash,
        &target,
        Some(vec![HarnessId::Claude]),
        None,
    );
    let Err(CoreError::TemplateMemberUnavailable { why, .. }) = refused else {
        panic!("a contested name should refuse the install: {refused:?}");
    };
    assert!(why.contains("declares one package under a name"), "{why}");
    assert_eq!(
        snapshot(root),
        before,
        "the refused install wrote into {}",
        root.display()
    );

    // Under two names the pair is two sets of one group, and both land.
    fs::write(
        project.catalog.join("kendex.toml"),
        "[marketplace]\nname = \"cat\"\nlicense = \"MIT\"\n\
         [bundles.review]\nskills = [\"gh\"]\n\
         [bundles.other]\ncommands = [\"note\"]\n",
    )
    .unwrap();
    let repo = crate::paths::slashed(&project.catalog);
    let apart = create_from_selection(
        &project.env,
        "Apart",
        vec![
            market(MemberKind::Bundle, "review", &repo),
            market(MemberKind::Plugin, "other", &repo),
        ],
    )
    .unwrap();
    let resolution = resolve(&project.env, &apart).unwrap();
    assert_eq!(resolution.missing, Vec::new());
    assert_eq!(resolution.groups.len(), 1, "{:?}", resolution.groups);
    assert_eq!(
        resolution.groups[0].bundles.len(),
        2,
        "{:?}",
        resolution.groups
    );
    let landed = install(
        &project.env,
        &apart,
        &destination(&project, "into-apart"),
        Some(vec![HarnessId::Claude]),
        None,
    )
    .unwrap();
    assert_eq!(landed.stopped, None);
    for wanted in ["bundle review", "plugin other"] {
        assert!(
            landed.declared.contains(&wanted.to_owned()),
            "{:?}",
            landed.declared
        );
    }
}

/// A plugin is its registry's own curated set, so it installs whole the
/// way a bundle does — and the resolved row keeps saying it is a plugin,
/// so a reference built from that row reaches the member rather than
/// naming one the template does not hold.
#[test]
#[allow(clippy::unwrap_used)]
fn a_plugin_resolves_as_a_set_that_still_says_which_kind_it_is() {
    let project = seeded();
    let repo = crate::paths::slashed(&project.catalog);
    let template = create_from_selection(
        &project.env,
        "Plugged",
        vec![Member {
            kind: MemberKind::Plugin,
            name: "review".to_owned(),
            enabled: true,
            source: MemberSource::Marketplace {
                repo: repo.clone(),
                rev: None,
            },
        }],
    )
    .unwrap();

    let resolution = resolve(&project.env, &template).unwrap();
    assert_eq!(resolution.groups.len(), 1, "{:?}", resolution.groups);
    let sets = &resolution.groups[0].bundles;
    assert_eq!(sets.len(), 1, "{sets:?}");
    assert_eq!(
        (sets[0].name.as_str(), sets[0].kind),
        ("review", MemberKind::Plugin)
    );

    // The reference a surface builds out of that row reaches the member.
    let after = remove_members(
        &project.env,
        "Plugged",
        &[MemberRef {
            kind: sets[0].kind,
            name: sets[0].name.clone(),
            which: MemberWhich::Marketplace { repo },
        }],
    )
    .unwrap();
    assert_eq!(after.members, Vec::new());
}

/// A refusal in the rendering after the copies are on disk is a refusal:
/// no package went in, so the run does not answer as one that stopped
/// part-way.
///
/// The copy and its declaration commit in one plan and the rendering is a
/// second one. A copy in the local slot is what the member needs before
/// it can be installed, not the member installed, and an account that
/// counted it would tell a person some of the template is in a place
/// that holds none of it.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_render_that_refuses_after_the_copy_committed_is_a_refusal() {
    use std::os::unix::fs::PermissionsExt;
    let project = seeded();
    // Copies only: a marketplace group writes before them, and its own
    // account would answer for the run before this refusal was reached.
    let template = create_from_project(
        &project.env,
        &project.root,
        &Chosen {
            name: "Local only".to_owned(),
            locals: vec!["skill:stray".to_owned()],
            fingerprint: draft_from_project(&project.env, &project.root)
                .unwrap()
                .fingerprint,
            ..Chosen::default()
        },
    )
    .unwrap();
    let target = destination(&project, "unrenderable");
    let Scope::Project { root } = &target else {
        unreachable!("built as a project scope")
    };
    // The slot the render writes into, refusing writes. The harness root
    // above it stays writable: a harness root nothing can write to is read
    // as a scope that holds no skills at all, and then no render is
    // planned and there is no refusal to observe.
    let slot = root.join(".claude/skills");
    fs::create_dir_all(&slot).unwrap();
    fs::set_permissions(&slot, fs::Permissions::from_mode(0o555)).unwrap();
    // Root writes into a directory whatever its mode, so there the
    // refusal under test does not exist and the install simply finishes.
    let denied = !rustix::process::geteuid().is_root();
    let landed = install(
        &project.env,
        &template,
        &target,
        Some(vec![HarnessId::Claude]),
        None,
    );
    fs::set_permissions(&slot, fs::Permissions::from_mode(0o755)).unwrap();

    match denied {
        true => {
            let refused = landed.unwrap_err();
            assert!(
                matches!(refused, CoreError::RolledBack { .. }),
                "{refused:?}"
            );
            // The copy stays where the committed plan put it, and the
            // refusal, not an account, is what says nothing was rendered.
            let copied = root
                .join(crate::source::LOCAL_SOURCE_DIR)
                .join("skills/stray/SKILL.md");
            assert!(copied.is_file(), "{}", copied.display());
        }
        false => assert!(landed.is_ok(), "{landed:?}"),
    }
}

/// A subscription the run made is a write outside the destination, and a
/// refusal after it answers as a run that stopped part-way, naming it:
/// the personal manifest now holds a marketplace the person did not
/// subscribe to by hand, and a bare error would leave that invisible.
///
/// The template names a marketplace nothing subscribes to yet, so the
/// run subscribes personally before the add; the add then refuses in the
/// rendering. No package went in, and the account says so — `declared`
/// stays empty — while `subscribed` carries the repository.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_render_that_refuses_after_the_subscription_committed_reports_the_subscription() {
    use std::os::unix::fs::PermissionsExt;
    let project = seeded();
    // Marketplace members only: a copy would commit its own plan before
    // the add, and this case is about the subscription alone.
    let template = create_from_project(
        &project.env,
        &project.root,
        &Chosen {
            name: "Marketplace only".to_owned(),
            members: vec!["skill:gh".to_owned()],
            fingerprint: draft_from_project(&project.env, &project.root)
                .unwrap()
                .fingerprint,
            ..Chosen::default()
        },
    )
    .unwrap();
    let resolution = resolve(&project.env, &template).unwrap();
    assert_eq!(resolution.groups.len(), 1, "{:?}", resolution.groups);
    assert_eq!(resolution.groups[0].source, None, "{:?}", resolution.groups);
    let target = destination(&project, "unrenderable");
    let Scope::Project { root } = &target else {
        unreachable!("built as a project scope")
    };
    // The slot the render writes into, refusing writes; the harness root
    // above it stays writable so a render is planned at all.
    let slot = root.join(".claude/skills");
    fs::create_dir_all(&slot).unwrap();
    fs::set_permissions(&slot, fs::Permissions::from_mode(0o555)).unwrap();
    // Root writes into a directory whatever its mode, so there the
    // refusal under test does not exist and the install simply finishes.
    let denied = !rustix::process::geteuid().is_root();
    let landed = install(
        &project.env,
        &template,
        &target,
        Some(vec![HarnessId::Claude]),
        None,
    );
    fs::set_permissions(&slot, fs::Permissions::from_mode(0o755)).unwrap();

    let landed = landed.unwrap();
    assert_eq!(landed.subscribed, ["cat"].map(|_| project_repo(&project)));
    match denied {
        true => {
            assert!(landed.stopped.is_some(), "{landed:?}");
            assert_eq!(landed.declared, Vec::<String>::new(), "{landed:?}");
        }
        false => assert!(landed.stopped.is_none(), "{landed:?}"),
    }
    // The write the account names is on disk: the personal manifest holds
    // a subscription at the repository the run reported.
    let personal = crate::manifest::load_current(&crate::manifest::manifest_path(
        &project.env,
        &Scope::Global,
    ))
    .unwrap()
    .unwrap();
    let repo = project_repo(&project);
    assert!(
        personal
            .sources
            .values()
            .any(|decl| decl.path.as_deref() == Some(repo.as_str())),
        "{:?}",
        personal.sources
    );
}

/// A notice belongs to the copy that required it. Taking the last copy
/// from a licensed marketplace out takes its terms with it, so the
/// template stops listing them and an install of what is left carries no
/// licence file for content the template no longer holds.
#[test]
#[allow(clippy::unwrap_used)]
fn removing_the_last_licensed_copy_takes_its_notices_with_it() {
    let project = seeded();
    // The installed copy drifts from the marketplace's bytes, so the
    // project's own copy of it can be taken — which is what needs the
    // marketplace's terms to travel along.
    super::skill(
        &project.root.join(".claude/skills"),
        "gh",
        "edited here, not upstream",
    );
    let template = create_from_project(
        &project.env,
        &project.root,
        &Chosen {
            name: "Licensed".to_owned(),
            members: vec!["skill:gh".to_owned()],
            fingerprint: draft_from_project(&project.env, &project.root)
                .unwrap()
                .fingerprint,
            sides: std::collections::BTreeMap::from([(
                "skill:gh".to_owned(),
                Side::Copy {
                    license: LicenseAnswer {
                        confirmed: true,
                        basis: None,
                    },
                },
            )]),
            locals: vec!["skill:stray".to_owned()],
            ..Chosen::default()
        },
    )
    .unwrap();
    let listed = |template: &Template| -> Vec<String> {
        stored_files(&project.env, template)
            .unwrap()
            .into_iter()
            .map(|file| file.path)
            .filter(|path| path.starts_with("NOTICES/"))
            .collect()
    };
    assert!(!listed(&template).is_empty(), "{:?}", listed(&template));
    // The inverse, so the rows below cannot pass over a set that is always
    // empty: while the template holds the copy, its terms travel with it
    // into the project the template is installed into.
    let carried_in = |name: &str, template: &Template| -> std::path::PathBuf {
        let target = destination(&project, name);
        install(&project.env, template, &target, None, None).unwrap();
        let Scope::Project { root } = &target else {
            unreachable!("built as a project scope")
        };
        root.join(crate::source::LOCAL_SOURCE_DIR)
            .join(crate::author::import::NOTICES_DIR)
            .join("cat/LICENSE")
    };
    let licensed = carried_in("licensed", &template);
    assert!(licensed.is_file(), "{}", licensed.display());

    let after = remove_members(
        &project.env,
        "Licensed",
        &[MemberRef {
            kind: MemberKind::Skill,
            name: "gh".to_owned(),
            which: MemberWhich::Copy,
        }],
    )
    .unwrap();
    assert_eq!(listed(&after), Vec::<String>::new());

    let stale = carried_in("unlicensed", &after);
    assert!(!stale.exists(), "{}", stale.display());
}

/// A marketplace that dropped a package after the template was saved makes
/// that member unavailable, and an install refuses before it writes
/// anything.
///
/// A template records identities, so upstream change is ordinary: without
/// the check the page went on offering the member, and an install wrote
/// whatever resolved before the add refused on the one that had gone.
#[test]
#[allow(clippy::unwrap_used)]
fn a_member_the_marketplace_no_longer_offers_is_reported_before_any_write() {
    let project = seeded();
    let template = template_of(&project, "Rust service");
    // The first install subscribes personally, which is what gives this
    // machine the marketplace to read at all.
    let first = destination(&project, "fresh");
    install(&project.env, &template, &first, None, None).unwrap();

    // Ordinary upstream change: the marketplace stops offering a package
    // the template names.
    fs::remove_dir_all(project.catalog.join("skills/gh")).unwrap();

    let resolution = resolve(&project.env, &template).unwrap();
    let missing: Vec<&str> = resolution
        .missing
        .iter()
        .map(|member| member.name.as_str())
        .collect();
    assert_eq!(missing, ["gh"], "{:?}", resolution.missing);
    // And it is not offered as installable beside being unavailable: one
    // row, one claim.
    let offered: Vec<&str> = resolution
        .groups
        .iter()
        .flat_map(|group| group.items.iter())
        .map(|item| item.name.as_str())
        .collect();
    assert_eq!(offered, ["note"], "{offered:?}");
    // The rest of the template still resolves, so the refusal below is
    // about the member and not about a template nothing can read.
    assert!(resolution.copies.len() > 1, "{:?}", resolution.copies);

    let target = destination(&project, "second");
    let Scope::Project { root } = &target else {
        unreachable!("built as a project scope")
    };
    let before = snapshot(root);
    assert!(matches!(
        install(&project.env, &template, &target, None, None),
        Err(CoreError::TemplateMemberUnavailable { .. })
    ));
    assert_eq!(snapshot(root), before, "the refusal wrote into the project");
}

/// Terms already at the destination answer the same rule the store does:
/// the same bytes are reused, different bytes refuse rather than being
/// skipped. Skipping left this template's copies sitting beside licence
/// text that is not theirs.
#[test]
#[allow(clippy::unwrap_used)]
fn a_destination_holding_different_terms_refuses_rather_than_skipping() {
    let project = seeded();
    super::skill(
        &project.root.join(".claude/skills"),
        "gh",
        "edited here, not upstream",
    );
    let template = create_from_project(
        &project.env,
        &project.root,
        &Chosen {
            name: "Licensed".to_owned(),
            members: vec!["skill:gh".to_owned()],
            fingerprint: draft_from_project(&project.env, &project.root)
                .unwrap()
                .fingerprint,
            sides: std::collections::BTreeMap::from([(
                "skill:gh".to_owned(),
                Side::Copy {
                    license: LicenseAnswer {
                        confirmed: true,
                        basis: None,
                    },
                },
            )]),
            ..Chosen::default()
        },
    )
    .unwrap();

    let target = destination(&project, "opinionated");
    let Scope::Project { root } = &target else {
        unreachable!("built as a project scope")
    };
    // The destination already holds terms of its own under that name.
    let held = root
        .join(crate::source::LOCAL_SOURCE_DIR)
        .join(crate::author::import::NOTICES_DIR)
        .join("cat/LICENSE");
    fs::create_dir_all(held.parent().unwrap()).unwrap();
    fs::write(&held, "Someone else's terms\n").unwrap();

    let refused = install(&project.env, &template, &target, None, None);
    let Err(CoreError::TemplateMemberUnavailable { why, .. }) = refused else {
        panic!("differing terms should refuse: {refused:?}");
    };
    assert!(why.contains("already holds different terms"), "{why}");
    assert_eq!(
        fs::read_to_string(&held).unwrap(),
        "Someone else's terms\n",
        "the refusal wrote over the terms it refused"
    );

    // The inverse: the same terms are the same terms, and the install goes
    // through — so the row above cannot pass over a path that always
    // refuses.
    fs::write(&held, "MIT License\n").unwrap();
    install(&project.env, &template, &target, None, None).unwrap();
}

/// A subscription state this machine already knows is reported before the
/// first write, not by the add that meets it after a group has landed.
///
/// Each of these is answerable with no network read, and each used to be
/// left to the add — which runs after an earlier group is committed, so a
/// run wrote half a template before naming a state it could have named
/// first. The reason names the subscription rather than the member,
/// because the package may well still be there.
#[test]
#[allow(clippy::unwrap_used)]
fn a_subscription_state_this_machine_knows_is_reported_before_any_write() {
    let project = seeded();
    let template = template_of(&project, "Rust service");
    let personal = crate::manifest::manifest_path(&project.env, &Scope::Global);

    // Nothing subscribes to the marketplace yet, and that arm is
    // deliberate: installing a template may create the subscription, which
    // is the ordinary path for one saved before subscribing.
    let first = destination(&project, "fresh");
    let landed = install(&project.env, &template, &first, None, None).unwrap();
    assert_eq!(landed.subscribed.len(), 1, "{landed:?}");
    assert!(landed.stopped.is_none(), "{landed:?}");

    // Switched off in the personal setup: the marketplace is there and
    // will serve nothing. Written through the manifest's own writer, so
    // the fixture cannot put the flag in a table it did not mean.
    let switched_off = |off: bool| {
        let mut manifest = crate::manifest::load_current(&personal).unwrap().unwrap();
        for decl in manifest.sources.values_mut() {
            decl.enabled = off;
        }
        crate::manifest::save(&personal, &manifest).unwrap();
    };
    switched_off(false);

    let target = destination(&project, "second");
    let Scope::Project { root } = &target else {
        unreachable!("built as a project scope")
    };
    let before = snapshot(root);
    let resolution = resolve(&project.env, &template).unwrap();
    let why = &resolution
        .missing
        .first()
        .unwrap_or_else(|| {
            panic!("the switched-off marketplace should be reported: {resolution:?}")
        })
        .why;
    assert!(why.contains("switched off"), "{why}");
    assert!(
        matches!(
            install(&project.env, &template, &target, None, None),
            Err(CoreError::TemplateMemberUnavailable { .. })
        ),
        "a switched-off marketplace must refuse before it writes"
    );
    assert_eq!(snapshot(root), before, "the refusal wrote into the project");

    // A catalog kendex cannot read as a marketplace is the same class of
    // answer, and says so rather than calling every member absent.
    switched_off(true);
    fs::write(project.catalog.join("kendex.toml"), "not = [valid toml\n").unwrap();
    let unusable = resolve(&project.env, &template).unwrap();
    let why = &unusable
        .missing
        .first()
        .unwrap_or_else(|| panic!("an unreadable marketplace should be reported: {unusable:?}"))
        .why;
    assert!(why.contains("cannot read it as a marketplace"), "{why}");
    assert!(
        matches!(
            install(&project.env, &template, &target, None, None),
            Err(CoreError::TemplateMemberUnavailable { .. })
        ),
        "an unreadable marketplace must refuse before it writes"
    );
    assert_eq!(snapshot(root), before, "the refusal wrote into the project");
}

/// A marketplace member no tool on this machine can take is refused in the
/// judging of its add, and the personal subscription the run would have
/// made for it is never written: the subscription is planned first, the
/// add judged against it, and both written only then. The same template
/// on a machine with a tool subscribes and installs.
#[test]
#[allow(clippy::unwrap_used)]
fn a_member_no_tool_can_take_leaves_the_personal_scope_unsubscribed() {
    for tool in [false, true] {
        let project = seeded();
        if !tool {
            fs::remove_dir_all(project.home.join(".claude")).unwrap();
        }
        // Marketplace members only, so the subscription is the one write
        // in question.
        let template = create_from_project(
            &project.env,
            &project.root,
            &Chosen {
                name: "Marketplace only".to_owned(),
                members: vec!["skill:gh".to_owned()],
                fingerprint: draft_from_project(&project.env, &project.root)
                    .unwrap()
                    .fingerprint,
                ..Chosen::default()
            },
        )
        .unwrap();
        let target = destination(&project, "fresh");
        let Scope::Project { root } = &target else {
            unreachable!("built as a project scope")
        };
        let personal = crate::manifest::manifest_path(&project.env, &Scope::Global);
        let repo = project_repo(&project);

        let landed = install(&project.env, &template, &target, None, None);

        match tool {
            false => {
                assert!(
                    matches!(landed, Err(CoreError::InstallsNowhere { .. })),
                    "{landed:?}"
                );
                assert!(
                    !personal.exists(),
                    "the refused install subscribed the personal scope"
                );
                assert!(
                    !root.join("kendex.toml").exists(),
                    "the refused install wrote the destination's manifest"
                );
            }
            true => {
                let landed = landed.unwrap();
                assert_eq!(landed.subscribed, std::slice::from_ref(&repo), "{landed:?}");
                assert_eq!(landed.declared, ["skill gh"], "{landed:?}");
                assert!(landed.stopped.is_none(), "{landed:?}");
                let written = crate::manifest::load_current(&personal).unwrap().unwrap();
                assert!(
                    written
                        .sources
                        .values()
                        .any(|decl| decl.path.as_deref() == Some(repo.as_str())),
                    "{:?}",
                    written.sources
                );
            }
        }
    }
}

/// A copy no tool on this machine can take is refused in the judging of
/// the add that renders it, and the copy plan that add had to read — the
/// bytes in the local slot and their declarations — is rolled back with
/// the refusal. The same template on a machine with a tool copies and
/// installs.
#[test]
#[allow(clippy::unwrap_used)]
fn a_copy_no_tool_can_take_is_rolled_back_with_the_refusal() {
    for tool in [false, true] {
        let project = seeded();
        if !tool {
            fs::remove_dir_all(project.home.join(".claude")).unwrap();
        }
        // Copies only, so the held plan is the one write in question.
        let template = create_from_project(
            &project.env,
            &project.root,
            &Chosen {
                name: "Local only".to_owned(),
                locals: vec!["skill:stray".to_owned()],
                fingerprint: draft_from_project(&project.env, &project.root)
                    .unwrap()
                    .fingerprint,
                ..Chosen::default()
            },
        )
        .unwrap();
        let target = destination(&project, "fresh");
        let Scope::Project { root } = &target else {
            unreachable!("built as a project scope")
        };
        let copied = root
            .join(crate::source::LOCAL_SOURCE_DIR)
            .join("skills/stray/SKILL.md");
        let manifest = root.join("kendex.toml");

        let landed = install(&project.env, &template, &target, None, None);

        match tool {
            false => {
                assert!(
                    matches!(landed, Err(CoreError::InstallsNowhere { .. })),
                    "{landed:?}"
                );
                assert!(!copied.exists(), "the refused install left its copy behind");
                assert!(
                    !manifest.exists(),
                    "the refused install left its declaration behind"
                );
                // A scope with a held plan taken back is one nothing is
                // pending on: the next apply recovers nothing.
                assert!(!crate::apply::recover(&project.env, &target).unwrap());
            }
            true => {
                let landed = landed.unwrap();
                assert_eq!(landed.copied, ["skill stray"], "{landed:?}");
                assert_eq!(landed.declared, ["skill stray"], "{landed:?}");
                assert!(copied.is_file(), "{}", copied.display());
                assert!(root.join(".claude/skills/stray/SKILL.md").is_file());
            }
        }
    }
}

/// A refusal whose held copy plan cannot be taken back still answers with
/// the refusal, the rollback failure beside it: the scope lock another
/// writer holds refuses the abort, and the held writes stay pending for
/// the next recovery, which takes them back once the lock is free.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refusal_whose_rollback_fails_still_names_the_refusal() {
    let project = seeded();
    let target = destination(&project, "fresh");
    let Scope::Project { root } = &target else {
        unreachable!("built as a project scope")
    };
    let written = root.join(crate::source::LOCAL_SOURCE_DIR).join("held.md");
    let plan = crate::apply::Plan::landed(
        target.clone(),
        vec![crate::apply::PlannedOp {
            description: "a copy a later step reads".into(),
            op: crate::apply::Op::WriteFile {
                pre: crate::apply::Pre::Absent,
                path: written.clone(),
                bytes: b"held".to_vec(),
            },
        }],
    )
    .unwrap();
    let held = crate::apply::execute_held(&project.env, &plan).unwrap();
    assert!(written.is_file());
    let busy = crate::apply::lock_scope(&project.env, &target).unwrap();

    let refused = super::super::install::refused_held(
        &project.env,
        held,
        CoreError::InstallsNowhere {
            reason: "no tool".to_owned(),
        },
    );

    match refused {
        CoreError::RollbackFailed { refused, cause } => {
            assert!(
                matches!(*refused, CoreError::InstallsNowhere { .. }),
                "{refused:?}"
            );
            assert!(matches!(*cause, CoreError::ScopeBusy { .. }), "{cause:?}");
        }
        other => panic!("the refusal was replaced: {other:?}"),
    }
    // The writes are still there, pending; the next recovery takes them
    // back.
    assert!(written.is_file());
    drop(busy);
    assert!(crate::apply::recover(&project.env, &target).unwrap());
    assert!(!written.exists());
}
