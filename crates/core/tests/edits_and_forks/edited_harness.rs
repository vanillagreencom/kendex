//! Which rendering an edit lives in: a fork captures one tool's bytes, so
//! the update row has to name the tool whose copy was changed.

use std::fs;

use kendex_core::package::updates::HoldOwner;

use super::*;

#[test]
#[allow(clippy::unwrap_used)]
fn an_edited_agent_names_the_rendering_that_was_edited() {
    let w = world();
    let dir = w.upstream.join("agents");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("rev.md"),
        "---\nname: rev\ndescription: agent rev\n---\nAgent body.\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    fs::create_dir_all(w.home.join("app/.opencode")).unwrap();
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\", \"opencode\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    let claude = w.home.join("app/.claude/agents/rev.md");
    let opencode = w.home.join("app/.opencode/agents/rev.md");
    assert!(claude.is_file() && opencode.is_file());

    let opencode_rendered = fs::read(&opencode).unwrap();
    fs::write(&opencode, "my opencode edit").unwrap();
    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Agent && row.name == "rev")
        .unwrap();
    assert!(row.blocked_by_local_edit);
    assert_eq!(
        row.edited_harnesses,
        vec![HarnessId::Opencode],
        "the fork must capture the rendering that was edited, not the first one"
    );
    assert_eq!(
        row.forkable_harness, None,
        "an opencode agent cannot be read back as source, so nothing is offered"
    );
    assert_eq!(
        row.repo_identity,
        kendex_core::source_ref::repo_identity(&row.repo)
    );

    // Edit Claude's copy too: a fork would keep one rendering and drop
    // the other edit, so with two edited tools nothing is offered.
    fs::write(&claude, "my claude edit").unwrap();
    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Agent && row.name == "rev")
        .unwrap();
    assert_eq!(row.edited_harnesses.len(), 2);
    assert_eq!(row.forkable_harness, None);
    assert!(row.can_discard);
    assert!(row.can_take_latest);

    // Only Claude's copy edited: that one round-trips, so it is the fork.
    fs::write(&opencode, &opencode_rendered).unwrap();
    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Agent && row.name == "rev")
        .unwrap();
    assert_eq!(row.edited_harnesses, vec![HarnessId::Claude]);
    assert_eq!(row.forkable_harness, Some(HarnessId::Claude));
}

/// "Discard edits" on a held, edited place: the hold moves to the new
/// commit and the edits go in the same apply — two steps would restore
/// the old held copy first and leave the update pending.
#[test]
#[allow(clippy::unwrap_used)]
fn discarding_edits_can_move_a_hold_in_the_same_apply() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    let one = head_commit(&w.upstream);
    declare(
        &w,
        &format!("[skills.gh]\nsource = \"cat\"\nrev = \"{one}\"\n"),
    );
    sync_and_apply(&w);
    write_skill(&w.upstream, "gh", "Two.");
    commit(&w.upstream, "two");
    fs::write(skill_file(&w), "my edited version").unwrap();
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    let report = kendex_core::package::set_rev_with(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        Some("main"),
        &PlanOptions {
            overwrite_edited_names: Some(vec![(ItemKind::Skill, "gh".to_owned())]),
            ..Default::default()
        },
    )
    .unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(fs::read_to_string(skill_file(&w)).unwrap().contains("Two."));
    assert!(audit(&w.env, &w.scope).unwrap().drift.is_empty());
}

/// A bundle member has no declaration of its own, so a fork has nothing to
/// turn local and the engine would refuse it; the row says so up front.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edited_bundle_member_is_not_offered_a_fork() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.starter]\ndescription = \"the set\"\nskills = [\"gh\"]\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    declare(&w, "[bundles.starter]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    assert!(skill_file(&w).is_file());

    fs::write(skill_file(&w), "my edited version").unwrap();
    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Skill && row.name == "gh")
        .unwrap();
    assert!(row.derived);
    assert!(row.blocked_by_local_edit);
    assert_eq!(row.edited_harnesses, vec![HarnessId::Claude]);
    assert_eq!(row.forkable_harness, None);
    assert!(row.can_discard);
}

/// A bundle member held by its bundle at an older revision: discarding
/// the edit restores that held copy — offered as exactly that — while
/// moving to the newest is the owner's to do.
#[test]
#[allow(clippy::unwrap_used)]
fn a_held_bundle_member_with_newer_upstream_can_discard_but_not_move() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.starter]\ndescription = \"the set\"\nskills = [\"gh\"]\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    let one = head_commit(&w.upstream);
    declare(
        &w,
        &format!("[bundles.starter]\nsource = \"cat\"\nrev = \"{one}\"\n"),
    );
    sync_and_apply(&w);
    write_skill(&w.upstream, "gh", "Two.");
    commit(&w.upstream, "two");
    fs::write(skill_file(&w), "my edited version").unwrap();
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Skill && row.name == "gh")
        .unwrap();
    assert!(row.derived && row.pinned && row.update_available, "{row:?}");
    assert_eq!(row.hold_owner, Some(HoldOwner::Parent { name: None }));
    assert!(row.blocked_by_local_edit);
    assert!(row.can_discard, "the owner's held content can come back");
    assert!(!row.can_take_latest, "only the owner can move the hold");
}

/// Two tools symlinking one skill tree report one edit twice; that is one
/// rendering, and a fork through either tool captures the same bytes.
#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_shared_by_symlink_counts_as_one_edited_rendering() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    fs::create_dir_all(w.home.join("app/.opencode")).unwrap();
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\", \"opencode\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    // Claude Code links at the shared tree; opencode reads it directly.
    assert!(w.home.join("app/.claude/skills/gh").is_symlink());
    assert!(w.home.join("app/.agents/skills/gh").is_dir());
    assert!(!w.home.join("app/.opencode/skills/gh").exists());

    fs::write(skill_file(&w), "my edited version").unwrap();
    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Skill && row.name == "gh")
        .unwrap();
    assert!(row.blocked_by_local_edit);
    assert_eq!(row.edited_harnesses.len(), 1, "{:?}", row.edited_harnesses);
    assert!(row.forkable_harness.is_some(), "{row:?}");
}

/// The discard needs the source content, not its history: with the mirror
/// gone the row loses its version labels and keeps the way out. A package
/// the source no longer carries has nothing to put in the edits' place.
#[test]
#[allow(clippy::unwrap_used)]
fn discard_survives_an_unreadable_history_but_not_a_vanished_package() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    fs::write(skill_file(&w), "my edited version").unwrap();

    // The checkout the plan renders from stays; only the mirror's history
    // becomes unreadable.
    let mirrors = w.home.join(".cache/kendex/sources/mirrors");
    let mirror = fs::read_dir(&mirrors)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let config = fs::read_to_string(mirror.join("config")).unwrap();
    fs::write(
        mirror.join("config"),
        format!("{config}[log]\n\tdiffMerges = bogus\n"),
    )
    .unwrap();
    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Skill && row.name == "gh")
        .unwrap();
    assert!(row.blocked_by_local_edit);
    assert!(row.latest.is_none(), "{row:?}");
    assert!(row.can_discard, "{row:?}");
    assert!(!row.can_take_latest, "no newest to move to");
    assert!(
        report
            .warnings
            .iter()
            .any(|warning| warning.message.contains("history could not be read")),
        "{:?}",
        report.warnings
    );
    fs::write(mirror.join("config"), config).unwrap();

    fs::remove_dir_all(w.upstream.join("skills/gh")).unwrap();
    commit(&w.upstream, "gone");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();
    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Skill && row.name == "gh")
        .unwrap();
    assert!(row.removed_upstream, "{row:?}");
    assert!(!row.can_discard);
    assert!(!row.can_take_latest);
}

/// A source pinned as a whole holds every package it carries; the row
/// names the source as the hold's owner, since the package's own switch
/// has nothing of its own to release.
#[test]
#[allow(clippy::unwrap_used)]
fn a_source_level_hold_names_the_source_as_owner() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    let one = head_commit(&w.upstream);
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\nrev = \"{one}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);

    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Skill && row.name == "gh")
        .unwrap();
    assert!(row.pinned);
    assert_eq!(
        row.hold_owner,
        Some(HoldOwner::Source {
            name: "cat".to_owned()
        })
    );

    // A package's own hold is its own to release.
    declare(
        &w,
        &format!("[skills.gh]\nsource = \"cat\"\nrev = \"{one}\"\n"),
    );
    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    let row = report.rows.iter().find(|row| row.name == "gh").unwrap();
    assert_eq!(row.hold_owner, Some(HoldOwner::Package));
}

/// The updates chain read through a symlinked home: the published checkout
/// is reached under the link's spelling while the seal speaks the canonical
/// one, and the package's subtree must still resolve against the mirror —
/// a mixed spelling hands git an absolute pathspec it refuses, and the row
/// silently loses its timeline. macOS runs every test this way (`/var` →
/// `/private/var`); the link makes the same shape hold on every platform.
#[test]
#[allow(clippy::unwrap_used)]
fn updates_still_read_history_under_a_symlinked_home() {
    let w = world_via_link();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    write_skill(&w.upstream, "gh", "Two.");
    commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    assert_eq!(report.warnings, Vec::new(), "history must read cleanly");
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Skill && row.name == "gh")
        .unwrap();
    assert!(row.update_available, "{row:?}");
    assert!(row.can_take_latest, "{row:?}");
    assert!(row.latest.is_some(), "{row:?}");
}

/// The fallback that binds a package the tip no longer offers: the pin's
/// own revision still carries it, and the rel that revision yields must
/// land under the tip seal's spelling — through a symlinked home the
/// published roots and the seals disagree, and a strip against the wrong
/// one silently reads the package as removed upstream, timeline and all.
#[test]
#[allow(clippy::unwrap_used)]
fn a_pinned_package_gone_at_tip_keeps_its_timeline_under_a_symlinked_home() {
    let w = world_via_link();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    let one = head_commit(&w.upstream);
    declare(
        &w,
        &format!("[skills.gh]\nsource = \"cat\"\nrev = \"{one}\"\n"),
    );
    sync_and_apply(&w);
    fs::remove_dir_all(w.upstream.join("skills/gh")).unwrap();
    commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    assert_eq!(
        report.warnings,
        Vec::new(),
        "the fallback must bind cleanly"
    );
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Skill && row.name == "gh")
        .unwrap();
    assert!(!row.removed_upstream, "{row:?}");
    assert!(row.current.is_some(), "{row:?}");
    assert!(row.latest.is_some(), "{row:?}");
}

/// A dependency's row names every package that requires it — the line the
/// Library shows instead of the unnamed "something brought this" — and a
/// hold reaching it through a requirer that is itself derived names
/// nobody: a bundle holds `dev`, `dev` requires `gh`, and `dev` has no
/// declaration the person could open to release `gh`.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hold_through_a_derived_requirer_names_nobody() {
    let w = world();
    let dev = w.upstream.join("skills/dev");
    fs::create_dir_all(&dev).unwrap();
    fs::write(
        dev.join("SKILL.md"),
        "---\nname: dev\ndescription: about dev\ndependencies:\n  required: [gh]\n---\nDev.\n",
    )
    .unwrap();
    write_skill(&w.upstream, "gh", "One.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.starter]\ndescription = \"the set\"\nskills = [\"dev\"]\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    let one = head_commit(&w.upstream);
    declare(
        &w,
        &format!("[bundles.starter]\nsource = \"cat\"\nrev = \"{one}\"\n"),
    );
    sync_and_apply(&w);

    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Skill && row.name == "gh")
        .unwrap();
    assert!(row.derived && row.pinned, "{row:?}");
    assert_eq!(
        row.required_by,
        vec!["dev".to_owned()],
        "the Library still says which package requires it"
    );
    assert_eq!(
        row.hold_owner,
        Some(HoldOwner::Parent { name: None }),
        "dev is itself derived, so there is no declaration to send anyone to"
    );
}

/// The must-fail control beside it: with `dev` declared, the requirement is
/// what propagated the hold and `dev` is a declaration the person can open,
/// so the hold names it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hold_through_a_declared_requirer_names_it() {
    let w = world();
    let dev = w.upstream.join("skills/dev");
    fs::create_dir_all(&dev).unwrap();
    fs::write(
        dev.join("SKILL.md"),
        "---\nname: dev\ndescription: about dev\ndependencies:\n  required: [gh]\n---\nDev.\n",
    )
    .unwrap();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    let one = head_commit(&w.upstream);
    declare(
        &w,
        &format!("[skills.dev]\nsource = \"cat\"\nrev = \"{one}\"\n"),
    );
    sync_and_apply(&w);

    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Skill && row.name == "gh")
        .unwrap();
    assert_eq!(row.required_by, vec!["dev".to_owned()]);
    assert_eq!(
        row.hold_owner,
        Some(HoldOwner::Parent {
            name: Some("dev".to_owned())
        })
    );
}
