//! What kendex holds back rather than move: bytes it cannot prove or
//! cannot read, links it did not make, and a hook whose replacement this
//! plan did not write.

use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};

use kendex_core::engine::audit;

use super::{
    about, apply, declare_second_hook, forget_rendered_hash, notes, regress, regressed, world,
};

#[test]
#[allow(clippy::unwrap_used)]
fn an_edited_script_stays_put_and_earns_exactly_one_line() {
    let w = regressed();
    let edited = w.dot().join("hooks/guard.sh");
    fs::write(&edited, "#!/bin/sh\n# mine\nexit 0\n").unwrap();

    let said = about(&notes(&w), "guard.sh");
    assert_eq!(said.len(), 1, "one file, one line: {said:?}");
    assert!(said[0].contains("was edited on disk"), "{said:?}");
    apply(&w);

    assert_eq!(
        fs::read_to_string(&edited).unwrap(),
        "#!/bin/sh\n# mine\nexit 0\n",
        "edited bytes are never an automatic casualty of a move"
    );
}

/// With a sibling still taken, the directory survives — and the held file
/// must not be named twice: once as edited and once as a stranger's.
#[test]
#[allow(clippy::unwrap_used)]
fn a_held_file_is_never_also_called_a_file_kendex_did_not_write() {
    let w = world();
    declare_second_hook(&w);
    apply(&w);
    regress(&w, "guard.sh");
    regress(&w, "other.sh");
    let edited = w.dot().join("hooks/guard.sh");
    fs::write(&edited, "#!/bin/sh\n# mine\nexit 0\n").unwrap();

    let said = about(&notes(&w), "guard.sh");
    assert_eq!(said.len(), 1, "one file, one line: {said:?}");
    assert!(said[0].contains("was edited on disk"), "{said:?}");
    apply(&w);

    assert!(edited.is_file(), "the edited file stays");
    assert!(
        !w.dot().join("hooks/other.sh").exists(),
        "its sibling still moves"
    );
}

/// A record from before `rendered_hash` existed proves nothing, so the
/// file it describes is not kendex's to take — the reading
/// `removal::edit_holds` takes of the same evidence.
#[test]
#[allow(clippy::unwrap_used)]
fn a_script_older_than_the_byte_record_stays_put_and_says_so() {
    let w = regressed();
    forget_rendered_hash(&w);

    let said = about(&notes(&w), "guard.sh");
    assert_eq!(said.len(), 1, "{said:?}");
    assert!(said[0].contains("predates the record"), "{said:?}");
    apply(&w);
    assert!(w.dot().join("hooks/guard.sh").is_file());
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
}

/// A declaration whose source cannot be resolved plans no write, so the
/// old copy is all that is running — and it stays running.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_with_no_replacement_this_pass_keeps_its_old_copy() {
    let w = regressed();
    fs::remove_file(w.catalog.join("hooks/guard.sh")).unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("was not written at")),
        "{:?}",
        report.notes
    );
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "a working hook is never retired before its replacement exists"
    );
    assert!(
        fs::read_to_string(w.dot().join("hooks.json"))
            .unwrap()
            .contains(".pi/hooks/guard.sh"),
        "and it keeps its registration"
    );
}

/// A file at the new path is not proof unless it is this hook's own
/// rendering: a link there is a conflict the plan reports, not a
/// replacement that licenses taking the working copy away.
#[test]
#[allow(clippy::unwrap_used)]
fn a_link_at_the_new_path_is_not_this_hooks_replacement() {
    let w = regressed();
    let elsewhere = w.home.join("someone-elses.sh");
    fs::write(&elsewhere, "#!/bin/sh\nexit 0\n").unwrap();
    fs::create_dir_all(w.dot().join("kendex/hooks")).unwrap();
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

/// One hook's registry edit says nothing about another hook's move.
#[test]
#[allow(clippy::unwrap_used)]
fn a_sibling_hooks_registry_edit_is_not_this_hooks_replacement() {
    let w = world();
    declare_second_hook(&w);
    apply(&w);
    regress(&w, "guard.sh");
    regress(&w, "other.sh");
    fs::remove_dir_all(w.dot().join("kendex")).unwrap();
    // `guard` alone loses its source, so only `other` renders this pass.
    fs::remove_file(w.catalog.join("hooks/guard.sh")).unwrap();

    apply(&w);

    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "the sibling's write and registry edit are not this hook's replacement"
    );
    assert!(
        fs::read_to_string(w.dot().join("hooks.json"))
            .unwrap()
            .contains(".pi/hooks/guard.sh"),
        "and guard keeps its old registration"
    );
    assert!(!w.dot().join("hooks/other.sh").exists());
}

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
        report
            .notes
            .iter()
            .any(|note| note.contains("could not read") && note.contains("hooks")),
        "{:?}",
        report.notes
    );
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

    assert!(dir.is_dir(), "nothing under it was retired");
    assert!(
        fs::read_to_string(w.dot().join("hooks.json"))
            .unwrap()
            .contains(".pi/hooks/guard.sh"),
        "nor was its registration"
    );
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
}

/// An interrupted toggle can leave both names. Neither is a stranger's,
/// and the one whose bytes prove out still moves.
#[test]
#[allow(clippy::unwrap_used)]
fn a_leftover_twin_is_not_reported_as_a_strangers_file() {
    let w = regressed();
    let twin = w.dot().join("hooks/guard.sh.disabled");
    fs::write(&twin, "#!/bin/sh\n# stale\nexit 0\n").unwrap();

    let said = notes(&w);
    assert!(
        !said.iter().any(|note| note.contains("did not write")),
        "kendex wrote both names: {said:?}"
    );
    apply(&w);
    assert!(
        !w.dot().join("hooks/guard.sh").exists(),
        "the proven copy still moves"
    );
}
