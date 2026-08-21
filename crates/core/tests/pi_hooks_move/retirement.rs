//! The three answers to "is a replacement coming". A hook nobody declares
//! any more is retired outright — leaving it would keep a removed hook
//! firing and pi warning forever. A hook switched off is retired and
//! deregistered. Only a declaration this pass could not resolve waits, and
//! it completes as soon as the source is back.

use std::fs;

use kendex_core::engine::{PlanOptions, audit, plan_apply};

use super::{World, apply, regressed};

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
