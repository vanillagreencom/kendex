//! The three answers to "is a replacement coming". A hook nobody declares
//! any more is retired outright — leaving it would keep a removed hook
//! firing and pi warning forever. A hook switched off is retired and
//! deregistered. Only a declaration this pass could not resolve waits, and
//! it completes as soon as the source is back.

use std::fs;

use kendex_core::engine::{PlanOptions, audit, plan_apply};

use super::{World, about, apply, notes, regress, regressed, world};

#[allow(clippy::unwrap_used)]
fn undeclare(w: &World) {
    let manifest = w.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    let kept: String = text
        .split_inclusive("\n\n")
        .filter(|block| !block.starts_with("[hooks."))
        .collect();
    fs::write(&manifest, kept).unwrap();
}

#[allow(clippy::unwrap_used)]
fn apply_with(w: &World, options: &PlanOptions) {
    let report = plan_apply(&w.env, &w.scope(), options).unwrap();
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();
}

/// What `kendex refresh` runs.
fn refresh() -> PlanOptions {
    PlanOptions {
        sweep_unneeded: true,
        ..PlanOptions::default()
    }
}

/// What `kendex apply` and the app run.
fn reconcile() -> PlanOptions {
    PlanOptions {
        remove_orphans: true,
        sweep_unneeded: true,
        ..PlanOptions::default()
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_nobody_declares_takes_its_old_copy_with_it_on_refresh() {
    let w = regressed();
    undeclare(&w);
    // With the catalog gone too, nothing can say why it was ever here —
    // and it was asked for by name, so that is answer enough.
    fs::remove_dir_all(&w.catalog).unwrap();

    apply_with(&w, &refresh());

    assert!(
        !w.dot().join("hooks").exists(),
        "a removed hook must not keep the reserved directory alive"
    );
    assert!(
        !w.dot().join("hooks.json").exists(),
        "nor its registration: the hook the user removed would keep firing"
    );
    assert!(
        !w.dot().join("kendex/hooks/guard.sh").exists(),
        "and nothing was rendered at the new path either — it is undeclared"
    );
}

/// The orphan sweep drops the lock entry in the same pass, so this is the
/// last plan that could ever claim the old files.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_nobody_declares_takes_its_old_copy_with_it_on_reconcile() {
    let w = regressed();
    undeclare(&w);

    apply_with(&w, &reconcile());

    assert!(!w.dot().join("hooks").exists());
    assert!(!w.dot().join("hooks.json").exists());
    assert!(!w.dot().join("kendex/hooks/guard.sh").exists());
    let lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(w.project.join(".kendex-lock.json")).unwrap())
            .unwrap();
    assert!(
        lock["entries"].get("hook:guard:pi").is_none(),
        "the record goes with the files, not before them: {lock}"
    );
}

/// Switching a hook off registers nothing, so nothing at the new path
/// proves the move — but the old registration must still come out, or the
/// hook the user switched off keeps running.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_switched_off_is_deregistered_from_the_old_registry() {
    let w = regressed();
    let manifest = w.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace("[hooks.guard]\n", "[hooks.guard]\nenabled = false\n"),
    )
    .unwrap();

    apply(&w);

    assert!(
        !w.dot().join("hooks").exists(),
        "the reserved directory goes with the hook that was in it"
    );
    assert!(!w.dot().join("hooks.json").exists());
    assert!(w.dot().join("kendex/hooks/guard.sh.disabled").is_file());
}

/// The hold is repair, not abandonment: the move completes the moment the
/// declaration can be rendered again.
#[test]
#[allow(clippy::unwrap_used)]
fn a_held_move_completes_once_the_source_is_back() {
    let w = regressed();
    let script = w.catalog.join("hooks/guard.sh");
    let body = fs::read_to_string(&script).unwrap();
    fs::remove_file(&script).unwrap();

    apply(&w);
    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "an unrenderable declaration keeps the hook it is still running"
    );

    fs::write(&script, body).unwrap();
    apply(&w);

    assert!(!w.dot().join("hooks").exists());
    assert!(!w.dot().join("hooks.json").exists());
    assert!(w.dot().join("kendex/hooks/guard.sh").is_file());
    assert!(audit(&w.env, &w.scope()).unwrap().notes.is_empty());
}

/// A declaration that resolves and answers "pi gets nothing" — upstream
/// dropped pi from the hook's harnesses — has said all it is going to
/// say, so the old copy goes with it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_upstream_stopped_offering_for_pi_takes_its_old_copy_with_it() {
    let w = regressed();
    let script = w.catalog.join("hooks/guard.sh");
    let body = fs::read_to_string(&script).unwrap();
    fs::write(
        &script,
        body.replace("harnesses: [pi]", "harnesses: [claude]"),
    )
    .unwrap();

    apply(&w);

    assert!(
        !w.dot().join("hooks").exists(),
        "the declaration resolved: nothing more is coming for pi"
    );
    assert!(!w.dot().join("hooks.json").exists());
}

/// A hook that arrived inside a bundle is never keyed by the manifest —
/// members derive on every plan — so "nothing declares it" has to mean
/// what the orphan sweep means by it, or a set whose catalog is offline
/// would have its running hooks retired with nothing written in their
/// place.
#[test]
#[allow(clippy::unwrap_used)]
fn a_bundle_member_whose_catalog_is_offline_keeps_its_old_copy() {
    let w = world();
    fs::write(
        w.catalog.join("kendex.toml"),
        "is_source_catalog = true\n\n[bundles.kit]\ndescription = \"a set\"\nhooks = [\"guard\"]\n",
    )
    .unwrap();
    let manifest = w.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace(
            "[hooks.guard]\nsource = \"cat\"\n",
            "[bundles.kit]\nsource = \"cat\"\n",
        ),
    )
    .unwrap();
    apply(&w);
    assert!(
        w.dot().join("kendex/hooks/guard.sh").is_file(),
        "the member installs like any other hook"
    );
    regress(&w, "guard.sh");
    fs::remove_dir_all(w.dot().join("kendex")).unwrap();
    // The catalog goes offline: what the set carries, and why this
    // installation exists at all, is unknowable this pass.
    fs::remove_dir_all(&w.catalog).unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("was not written at")),
        "the hold has to be said, not silent: {:?}",
        report.notes
    );
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "a member kendex cannot account for keeps the hook it is running"
    );
    assert!(
        fs::read_to_string(w.dot().join("hooks.json"))
            .unwrap()
            .contains(".pi/hooks/guard.sh"),
        "and what runs it"
    );
}

/// The legacy spelling of the drift hook standing beside the new one is
/// dropped before it ever resolves, so waiting for a write is waiting
/// forever: the declaration has been answered.
#[test]
#[allow(clippy::unwrap_used)]
fn a_superseded_declaration_is_answered_not_awaited() {
    let w = regressed();
    let manifest = w.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace(
            "[hooks.guard]",
            "[hooks.kendex-drift]\nsource = \"cat\"\n\n[hooks.vstack-drift]",
        ),
    )
    .unwrap();
    // The lock still holds the legacy spelling's install, under the name
    // the reserved directory carries.
    let lock = w.project.join(".kendex-lock.json");
    let text = fs::read_to_string(&lock).unwrap();
    fs::write(&lock, text.replace("\"guard\"", "\"vstack-drift\"")).unwrap();
    let path = w.dot().join("hooks");
    fs::rename(path.join("guard.sh"), path.join("vstack-drift.sh")).unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    assert!(
        !report
            .notes
            .iter()
            .any(|note| note.contains("vstack-drift") && note.contains("stays until it is")),
        "a promise nothing can keep: {:?}",
        report.notes
    );
}

/// A bundle member the manifest never keys is still a hook something asks
/// for, so the readiness gate has to run for it exactly as for a keyed
/// declaration — here its rendering is held back and the old copy stays.
#[test]
#[allow(clippy::unwrap_used)]
fn a_bundle_member_whose_rendering_is_held_keeps_its_old_copy() {
    let w = world();
    fs::write(
        w.catalog.join("kendex.toml"),
        "is_source_catalog = true\n\n[bundles.kit]\ndescription = \"a set\"\nhooks = [\"guard\"]\n",
    )
    .unwrap();
    let manifest = w.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace(
            "[hooks.guard]\nsource = \"cat\"\n",
            "[bundles.kit]\nsource = \"cat\"\n",
        ),
    )
    .unwrap();
    apply(&w);
    let registry = fs::read_to_string(w.dot().join("kendex/hooks.json")).unwrap();
    regress(&w, "guard.sh");
    fs::remove_dir_all(w.dot().join("kendex")).unwrap();
    fs::create_dir_all(w.dot().join("kendex/hooks")).unwrap();
    fs::write(w.dot().join("kendex/hooks.json"), registry).unwrap();
    fs::write(
        w.dot().join("kendex/hooks/guard.sh"),
        "#!/bin/sh\n# not what kendex renders\nexit 0\n",
    )
    .unwrap();

    apply(&w);

    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "no rendering landed for the member, so its running copy stays"
    );
    assert!(
        fs::read_to_string(w.dot().join("hooks.json"))
            .unwrap()
            .contains(".pi/hooks/guard.sh")
    );
}

/// A finished move cannot be re-opened by a stranger wearing the hook's
/// name: the installation lives at the new path now, and upstream
/// updates have to keep landing on it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_same_named_stranger_does_not_freeze_a_finished_move() {
    let w = regressed();
    apply(&w);
    assert!(!w.dot().join("hooks").exists());
    fs::create_dir_all(w.dot().join("hooks")).unwrap();
    fs::write(
        w.dot().join("hooks/guard.sh"),
        "#!/bin/sh\n# somebody else's\n",
    )
    .unwrap();
    let script = w.catalog.join("hooks/guard.sh");
    let body = fs::read_to_string(&script).unwrap();
    fs::write(&script, body.replace("exit 0", "exit 1")).unwrap();

    apply(&w);

    assert!(
        fs::read_to_string(w.dot().join("kendex/hooks/guard.sh"))
            .unwrap()
            .contains("exit 1"),
        "the update still lands on the installation that moved"
    );
    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "and the stranger's file is nobody's to take"
    );
    assert!(
        about(&notes(&w), "hooks/guard.sh").is_empty(),
        "nor is it reported as a copy of this hook: {:?}",
        notes(&w)
    );
}

/// The one line that says a hook stopped running: a refresh keeps an
/// orphan's record, so without it nothing reports the change.
#[test]
#[allow(clippy::unwrap_used)]
fn retiring_an_orphans_copy_says_the_hook_stopped_running() {
    let w = regressed();
    undeclare(&w);

    let report = plan_apply(&w.env, &w.scope(), &refresh()).unwrap();
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("nothing asks for the pi hook guard")
                && note.contains("stops running")),
        "{:?}",
        report.notes
    );
}
