//! Who still asks for a hook, and how the move learns it. A manifest key
//! is one way in; a declaration this pass resolved is the other, and it
//! is how everything the manifest never keys arrives — a bundle member, a
//! dependency, a custom hook. A declaration the expansion drops has been
//! answered rather than deferred.

use std::fs;

use kendex_core::engine::audit;

use super::{apply, regress, regressed, world};

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
