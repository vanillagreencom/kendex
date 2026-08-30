//! What kendex cannot read. "I could not look" is never absence: an
//! unreadable copy, an unreadable directory, an unreadable scope root —
//! none of them licenses retiring anything, none of them is settled by
//! discarding edits, and each says which path and why.

use std::fs;
use std::os::unix::fs::PermissionsExt;

use kendex_core::engine::{PlanOptions, audit, plan_apply};

use super::{about, apply, notes, regressed};

/// "I could not look" is not absence. A reserved directory kendex cannot
/// stat through must retire neither the file nor its registration.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_reserved_directory_retires_nothing() {
    let w = regressed();
    let dir = w.dot().join("hooks");
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o000)).unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    assert!(
        !w.dot().join("kendex/hooks/guard.sh").exists(),
        "nothing is installed beside a copy kendex cannot read"
    );
    // Two causes, two lines: the file that could not be stat-ed, and the
    // directory that could not be listed.
    for said in [
        format!("could not read {}", dir.join("guard.sh").display()),
        format!("could not list {}", dir.display()),
    ] {
        assert!(
            report.notes.iter().any(|note| note.contains(&said)),
            "no line saying {said}: {:?}",
            report.notes
        );
    }
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();

    assert!(dir.is_dir(), "nothing under it was retired");
    assert!(
        fs::read_to_string(w.dot().join("hooks.json"))
            .unwrap()
            .contains(".pi/hooks/guard.sh"),
        "nor was its registration"
    );
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
}

/// A scope root nothing else touched this pass — no pi hook desired, so
/// no registration to read — reaches the move with an ordinary
/// permission failure. Held back and said, never a panic.
#[test]
#[allow(clippy::unwrap_used)]
fn a_scope_root_that_cannot_be_stat_ed_through_is_a_note() {
    let w = regressed();
    let manifest = w.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace("[hooks.guard]\nsource = \"cat\"\n", ""),
    )
    .unwrap();
    let dot = w.dot();
    fs::set_permissions(&dot, fs::Permissions::from_mode(0o600)).unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    let said = report.notes.clone();
    fs::set_permissions(&dot, fs::Permissions::from_mode(0o755)).unwrap();

    assert!(
        said.iter()
            .any(|note| note.contains(&format!("could not read {} (", dot.join("hooks").display()))),
        "the line has to name the directory itself, not a child: {said:?}"
    );
    assert!(dot.join("hooks/guard.sh").is_file(), "nothing was retired");
}

/// An undeclared hook whose copy kendex cannot read keeps its
/// registration: taking that out would leave a file nobody can account
/// for and nothing saying what it was.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_copy_of_an_undeclared_hook_keeps_its_registration() {
    let w = regressed();
    let manifest = w.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace("[hooks.guard]\nsource = \"cat\"\n", ""),
    )
    .unwrap();
    let script = w.dot().join("hooks/guard.sh");
    fs::set_permissions(&script, fs::Permissions::from_mode(0o000)).unwrap();

    apply(&w);

    assert!(
        fs::read_to_string(w.dot().join("hooks.json"))
            .unwrap()
            .contains(".pi/hooks/guard.sh"),
        "a file kendex cannot read keeps what names it"
    );
    fs::set_permissions(&script, fs::Permissions::from_mode(0o644)).unwrap();
}

/// A discard settles a difference kendex can see. A file it cannot read
/// at all is not one of those, so the installation still holds rather
/// than installing a second live copy beside it.
#[test]
#[allow(clippy::unwrap_used)]
fn discarding_edits_does_not_cover_a_file_that_cannot_be_read() {
    let w = regressed();
    let script = w.dot().join("hooks/guard.sh");
    fs::set_permissions(&script, fs::Permissions::from_mode(0o000)).unwrap();

    let report = plan_apply(
        &w.env,
        &w.scope(),
        &PlanOptions {
            overwrite_edited: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();

    assert!(
        !w.dot().join("kendex/hooks/guard.sh").exists(),
        "nothing is installed beside a copy kendex cannot read"
    );
    fs::set_permissions(&script, fs::Permissions::from_mode(0o644)).unwrap();
}

/// A file kendex cannot read is never reported as one somebody edited.
#[test]
#[allow(clippy::unwrap_used)]
fn a_script_that_cannot_be_read_is_named_for_that_and_not_for_an_edit() {
    let w = regressed();
    let script = w.dot().join("hooks/guard.sh");
    fs::set_permissions(&script, fs::Permissions::from_mode(0o000)).unwrap();

    let said = about(&notes(&w), "guard.sh");
    assert_eq!(said.len(), 1, "{said:?}");
    assert!(said[0].contains("could not read"), "{said:?}");
    assert!(!said[0].contains("edited"), "{said:?}");
    apply(&w);
    assert!(script.is_file());
    fs::set_permissions(&script, fs::Permissions::from_mode(0o644)).unwrap();
}

/// The same directory, for a hook nobody declares any more: kendex still
/// cannot look inside, so it still takes nothing — the registration
/// included, which is all that says what the file it cannot read was.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_directory_holding_an_undeclared_hook_retires_nothing() {
    let w = regressed();
    let manifest = w.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace("[hooks.guard]\nsource = \"cat\"\n", ""),
    )
    .unwrap();
    let dir = w.dot().join("hooks");
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o000)).unwrap();

    apply(&w);
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();

    assert!(
        fs::read_to_string(w.dot().join("hooks.json"))
            .unwrap()
            .contains(".pi/hooks/guard.sh"),
        "nothing is retired for a copy kendex could not even stat"
    );
    assert!(dir.join("guard.sh").is_file());
}
