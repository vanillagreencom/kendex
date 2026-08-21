//! Links under the reserved name and at the new one. `hash_tree` and
//! `is_file` both follow a link, and a link is never one of kendex's own
//! writes — so nothing is claimed, hashed, enumerated or handed over
//! through one, at either end of the move.

use std::fs;
use std::os::unix::fs::symlink;

use super::{about, apply, notes, regress, regressed, world};

/// A file at the new path is proof only when it is this hook's own
/// rendering. A link there is somebody else's file whatever it holds —
/// even bytes that hash the same — so it never licenses handing a live
/// hook over. The registration half is satisfied first, so the script
/// gate is the only thing left deciding.
#[test]
#[allow(clippy::unwrap_used)]
fn a_link_at_the_new_path_is_not_this_hooks_replacement() {
    let w = world();
    apply(&w);
    let rendered = fs::read_to_string(w.dot().join("kendex/hooks/guard.sh")).unwrap();
    let registry = fs::read_to_string(w.dot().join("kendex/hooks.json")).unwrap();
    regress(&w, "guard.sh");
    fs::remove_dir_all(w.dot().join("kendex")).unwrap();
    fs::create_dir_all(w.dot().join("kendex/hooks")).unwrap();
    fs::write(w.dot().join("kendex/hooks.json"), registry).unwrap();
    // Somebody else's file, holding exactly the bytes kendex renders.
    let elsewhere = w.home.join("someone-elses.sh");
    fs::write(&elsewhere, rendered).unwrap();
    symlink(&elsewhere, w.dot().join("kendex/hooks/guard.sh")).unwrap();

    apply(&w);

    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "the working copy stays while the new path is somebody else's link"
    );
    assert!(
        fs::read_to_string(w.dot().join("hooks.json"))
            .unwrap()
            .contains(".pi/hooks/guard.sh"),
        "and it keeps its registration, so the hook keeps running"
    );
    assert!(w.dot().join("kendex/hooks/guard.sh").is_symlink());
}

/// A broken link at the reserved name is what pi's own existence check
/// sees, so kendex has to see it too — and never mistake it for absence.
#[test]
#[allow(clippy::unwrap_used)]
fn a_broken_link_at_the_reserved_name_is_not_absence() {
    let w = regressed();
    let dir = w.dot().join("hooks");
    fs::remove_file(dir.join("guard.sh")).unwrap();
    fs::remove_dir(&dir).unwrap();
    symlink(w.home.join("nowhere"), &dir).unwrap();

    let said = notes(&w);
    assert!(
        said.iter()
            .any(|note| note.contains("is a link kendex did not create")),
        "{said:?}"
    );
    apply(&w);

    assert!(dir.is_symlink(), "the link stays");
    assert!(
        fs::read_to_string(w.dot().join("hooks.json"))
            .unwrap()
            .contains(".pi/hooks/guard.sh"),
        "and nothing beside it was retired either"
    );
}

/// A hash follows a link; a rename does not. A link is never kendex's own
/// write, so nothing is taken through one.
#[test]
#[allow(clippy::unwrap_used)]
fn a_linked_script_is_left_where_it_is() {
    let w = regressed();
    let script = w.dot().join("hooks/guard.sh");
    let elsewhere = w.home.join("guard.sh");
    fs::rename(&script, &elsewhere).unwrap();
    symlink(&elsewhere, &script).unwrap();

    let said = about(&notes(&w), "guard.sh");
    assert_eq!(said.len(), 1, "{said:?}");
    assert!(
        said[0].contains("is a link kendex did not create"),
        "{said:?}"
    );
    apply(&w);
    assert!(script.is_symlink(), "the link stays");
    assert!(elsewhere.is_file(), "and so does what it points at");
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_linked_registry_is_left_where_it_is() {
    let w = regressed();
    let registry = w.dot().join("hooks.json");
    let elsewhere = w.home.join("hooks.json");
    fs::rename(&registry, &elsewhere).unwrap();
    symlink(&elsewhere, &registry).unwrap();

    apply(&w);
    assert!(registry.is_symlink());
    assert!(elsewhere.is_file());
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_linked_directory_is_never_enumerated() {
    let w = regressed();
    let dir = w.dot().join("hooks");
    let elsewhere = w.home.join("hooks");
    fs::rename(&dir, &elsewhere).unwrap();
    symlink(&elsewhere, &dir).unwrap();

    apply(&w);
    assert!(dir.is_symlink(), "the link stays");
    assert!(
        elsewhere.join("guard.sh").is_file(),
        "and nothing under it was touched"
    );
    assert!(
        fs::read_to_string(w.dot().join("hooks.json"))
            .unwrap()
            .contains(".pi/hooks/guard.sh"),
        "nor was the registration of what it holds"
    );
}
