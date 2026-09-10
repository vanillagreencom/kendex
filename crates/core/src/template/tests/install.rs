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
    install(&project.env, &template, &target, None, None).unwrap();

    let manifest = fs::read_to_string(root.join("kendex.toml")).unwrap();
    let declared: toml::Table = toml::from_str(&manifest).unwrap();
    let enabled = |table: &str, name: &str| -> bool {
        declared
            .get(table)
            .and_then(|kind| kind.get(name))
            .and_then(|decl| decl.get("enabled"))
            .and_then(toml::Value::as_bool)
            // Absent means enabled: that is the manifest's own default.
            .unwrap_or(true)
    };
    assert!(
        !enabled("commands", "note"),
        "a member saved switched off installed enabled: {manifest}"
    );
    assert!(
        enabled("skills", "gh"),
        "a member saved switched on should install enabled: {manifest}"
    );
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

/// A refusal in the rendering after the copies are on disk answers with
/// the copies and the reason it stopped, never as a total refusal.
///
/// The copy and its declaration commit in one plan and the rendering is a
/// second one. The account of the first belongs to the run, not to the
/// step that made it, so a step that refuses afterwards cannot take it
/// away — a person told nothing landed would go looking for bytes that
/// are in their project.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_render_that_refuses_after_the_copy_committed_reports_the_copy() {
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
        Some(vec![crate::model::HarnessId::Claude]),
        None,
    );
    fs::set_permissions(&slot, fs::Permissions::from_mode(0o755)).unwrap();

    match denied {
        true => {
            let landed = landed.unwrap();
            assert_eq!(landed.copied, ["skill stray"], "{landed:?}");
            assert!(landed.stopped.is_some(), "{landed:?}");
            // And the bytes the account names are where it says they are.
            let copied = root
                .join(crate::source::LOCAL_SOURCE_DIR)
                .join("skills/stray/SKILL.md");
            assert!(copied.is_file(), "{}", copied.display());
        }
        false => assert!(landed.is_ok(), "{landed:?}"),
    }
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
