//! A file kendex wrote that is gone from disk: the planner already holds
//! the write that puts it back, and the update row has to say so — a
//! registered hook whose script was deleted is otherwise run by the tool
//! and reported healthy by kendex.

use std::fs;

use super::*;

const GUARD: &str = "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: check shell commands\n# ---\nexit 0\n";

#[allow(clippy::unwrap_used)]
fn row(w: &World) -> kendex_core::package::updates::UpdateRow {
    kendex_core::package::updates::updates(&w.env, &w.scope)
        .unwrap()
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Hook && row.name == "guard")
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
    let settings = fs::read_to_string(w.home.join("app/.claude/settings.json")).unwrap();
    assert!(settings.contains("guard.sh"), "{settings}");

    // The control: with the script where the apply put it, nothing is
    // missing.
    let present = row(&w);
    assert!(!present.files_missing, "{present:?}");

    fs::remove_file(&script).unwrap();
    let gone = row(&w);
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
    let repaired = row(&w);
    assert!(!repaired.files_missing, "{repaired:?}");
}

// An agent has no registration that keeps it observed once its rendering
// is deleted: the lock is all that says a file stood there, and the row
// has to say so the same way it does for a hook.
#[test]
#[allow(clippy::unwrap_used)]
fn a_deleted_agent_rendering_reads_as_missing() {
    let w = world();
    write_agent(&w.upstream, "rev", "Agent body.");
    commit(&w.upstream, "one");
    declare(&w, "[agents.rev]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    let rendering = w.home.join("app/.claude/agents/rev.md");
    assert!(rendering.is_file(), "{}", rendering.display());
    let row = |w: &World| {
        kendex_core::package::updates::updates(&w.env, &w.scope)
            .unwrap()
            .rows
            .iter()
            .find(|row| row.kind == ItemKind::Agent && row.name == "rev")
            .cloned()
            .unwrap()
    };
    assert!(!row(&w).files_missing);

    fs::remove_file(&rendering).unwrap();
    let gone = row(&w);
    assert!(gone.files_missing, "{gone:?}");
    assert!(!gone.blocked_by_local_edit, "{gone:?}");
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

    let declared = row(&w);
    assert!(!declared.files_missing, "{declared:?}");
}
