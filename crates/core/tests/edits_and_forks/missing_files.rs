//! A file kendex wrote that is gone from disk: the planner already holds
//! the write that puts it back, and the update row has to say so — a
//! registered hook whose script was deleted is otherwise run by the tool
//! and reported healthy by kendex.

use std::fs;

use super::*;

const GUARD: &str = "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: check shell commands\n# ---\nexit 0\n";

#[allow(clippy::unwrap_used)]
fn row(w: &World, kind: ItemKind, name: &str) -> kendex_core::package::updates::UpdateRow {
    kendex_core::package::updates::updates(&w.env, &w.scope)
        .unwrap()
        .rows
        .iter()
        .find(|row| row.kind == kind && row.name == name)
        .cloned()
        .unwrap()
}

/// A catalog offering the `guard` hook, declared into the fixture project.
/// Executable kinds are offered only by a source that declares kendex's
/// layout, so the catalog says so.
#[allow(clippy::unwrap_used)]
fn declare_guard(w: &World) {
    fs::write(w.upstream.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::create_dir_all(w.upstream.join("hooks")).unwrap();
    fs::write(w.upstream.join("hooks/guard.sh"), GUARD).unwrap();
    commit(&w.upstream, "one");
    declare(w, "[hooks.guard]\nsource = \"cat\"\n");
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_registered_hook_whose_script_is_gone_reads_as_missing_until_the_apply_puts_it_back() {
    let w = world();
    declare_guard(&w);
    sync_and_apply(&w);
    let script = w.home.join("app/.claude/hooks/guard.sh");
    assert!(script.is_file(), "{}", script.display());

    // The control: with the script where the apply put it, nothing is
    // missing.
    let present = row(&w, ItemKind::Hook, "guard");
    assert!(!present.files_missing, "{present:?}");

    fs::remove_file(&script).unwrap();
    let gone = row(&w, ItemKind::Hook, "guard");
    assert!(gone.files_missing, "{gone:?}");
    assert!(
        !gone.blocked_by_local_edit,
        "an absent file is not an edit: {gone:?}"
    );
    // The registration still names the script, so the tool runs a file
    // that is not there.
    let settings = fs::read_to_string(w.home.join("app/.claude/settings.json")).unwrap();
    assert!(settings.contains("guard.sh"), "{settings}");

    // The repair is the single-package update the row offers everywhere:
    // its plan holds the write that puts the script back.
    let report =
        kendex_core::package::update_one(&w.env, &w.scope, ItemKind::Hook, "guard").unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    assert_eq!(fs::read_to_string(&script).unwrap(), GUARD);
    let repaired = row(&w, ItemKind::Hook, "guard");
    assert!(!repaired.files_missing, "{repaired:?}");
}

// A place held at a revision whose source has moved on: the repair puts
// the held revision's file back and leaves the hold where it was. The
// update is the thing that moves a hold, and a repair is not an update.
#[test]
#[allow(clippy::unwrap_used)]
fn a_repair_at_a_held_revision_restores_that_revision_and_keeps_the_hold() {
    let w = world();
    write_agent(&w.upstream, "rev", "Held body.");
    commit(&w.upstream, "one");
    let one = head_commit(&w.upstream);
    declare(
        &w,
        &format!("[agents.rev]\nsource = \"cat\"\nrev = \"{one}\"\n"),
    );
    sync_and_apply(&w);
    let rendering = w.home.join("app/.claude/agents/rev.md");
    let held = fs::read_to_string(&rendering).unwrap();
    assert!(held.contains("Held body."), "{held}");

    write_agent(&w.upstream, "rev", "Newer body.");
    commit(&w.upstream, "two");
    fs::remove_file(&rendering).unwrap();
    let loaded = manifest_of(&w);
    remote::sync_sources(&w.env, &loaded).unwrap();
    let gone = row(&w, ItemKind::Agent, "rev");
    assert!(
        gone.files_missing && gone.pinned && gone.update_available,
        "{gone:?}"
    );

    let report =
        kendex_core::package::update_one(&w.env, &w.scope, ItemKind::Agent, "rev").unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    assert_eq!(fs::read_to_string(&rendering).unwrap(), held);
    assert_eq!(
        manifest_of(&w).agents.get("rev").unwrap().rev.as_deref(),
        Some(one.as_str()),
        "the hold moved"
    );
}

// A declaration that has never been installed is missing on disk too,
// and is not news: nothing kendex wrote has gone. The row is told apart
// by the lock, which records a rendering only once one was written.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_never_installed_is_not_missing_a_file() {
    let w = world();
    declare_guard(&w);
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();
    assert!(!w.home.join("app/.claude/hooks/guard.sh").exists());

    let declared = row(&w, ItemKind::Hook, "guard");
    assert!(!declared.files_missing, "{declared:?}");
}

// A rendering the layout moved is not gone: the record carries the position
// it wrote, still on disk, while this pass wants another one and reports it
// absent. Calling that a deletion offers a repair for an intact package.
#[test]
#[allow(clippy::unwrap_used)]
fn a_rendering_the_layout_moved_is_not_missing() {
    let w = world();
    write_skill(&w.upstream, "gh", "Body.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    let link = w.home.join("app/.claude/skills/gh");
    let old = w.home.join("app/.claude/skills/gh-old");
    fs::rename(&link, &old).unwrap();
    let path = lock_path(&w.env, &w.scope);
    let mut lock = load_lock(&path).unwrap();
    let key = kendex_core::lock::entry_key(ItemKind::Skill, "gh", HarnessId::Claude);
    let emitted = lock
        .entries
        .get_mut(&key)
        .unwrap()
        .emitted
        .as_mut()
        .unwrap();
    *emitted.paths.iter_mut().find(|p| **p == link).unwrap() = old;
    kendex_core::lock::save(&path, &lock).unwrap();

    assert!(!row(&w, ItemKind::Skill, "gh").files_missing);
}
