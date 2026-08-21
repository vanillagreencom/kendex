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
/// must not be named twice: once for its own cause and once as a
/// stranger's. Every hold cause has to satisfy that, not just the edited
/// one.
#[test]
#[allow(clippy::unwrap_used)]
fn a_held_file_is_never_also_called_a_file_kendex_did_not_write() {
    #[allow(clippy::type_complexity)]
    let causes: [(&str, &dyn Fn(&super::World, &std::path::Path)); 4] = [
        ("was edited on disk", &|_, path| {
            fs::write(path, "#!/bin/sh\n# mine\nexit 0\n").unwrap()
        }),
        ("predates the record", &|w, _| forget_rendered_hash(w)),
        ("is a link kendex did not create", &|w, path| {
            let elsewhere = w.home.join("linked-guard.sh");
            fs::rename(path, &elsewhere).unwrap();
            symlink(&elsewhere, path).unwrap();
        }),
        ("could not read", &|_, path| {
            fs::set_permissions(path, fs::Permissions::from_mode(0o000)).unwrap()
        }),
    ];
    for (cause, spoil) in causes {
        let w = world();
        declare_second_hook(&w);
        apply(&w);
        regress(&w, "guard.sh");
        regress(&w, "other.sh");
        fs::remove_dir_all(w.dot().join("kendex")).unwrap();
        let held = w.dot().join("hooks/guard.sh");
        spoil(&w, &held);

        let said = about(&notes(&w), "guard.sh");
        assert_eq!(said.len(), 1, "{cause}: one file, one line: {said:?}");
        assert!(said[0].contains(cause), "{said:?}");
        apply(&w);

        assert!(
            w.dot().join("hooks/guard.sh").exists(),
            "{cause}: the held file stays"
        );
        // Holding the bytes and rerouting what runs them is not holding
        // anything: the old registration is still the live one, and no
        // fresh rendering was put in its place.
        assert!(
            fs::read_to_string(w.dot().join("hooks.json"))
                .unwrap()
                .contains(".pi/hooks/guard.sh"),
            "{cause}: the held copy keeps what runs it"
        );
        let new = fs::read_to_string(w.dot().join("kendex/hooks.json")).unwrap();
        assert!(
            !new.contains("guard.sh"),
            "{cause}: and nothing took over from it: {new}"
        );
        assert!(
            !w.dot().join("kendex/hooks/guard.sh").exists(),
            "{cause}: no replacement was written behind the hold"
        );
        assert!(
            !w.dot().join("hooks/other.sh").exists(),
            "{cause}: its sibling still moves"
        );
        let _ = fs::set_permissions(&held, fs::Permissions::from_mode(0o644));
    }
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

/// A declaration this pass could not resolve keeps its old copy while
/// the sibling that did resolve moves out from beside it. (The narrower
/// question `registration_ready` asks — this hook's own edit rather than
/// any edit to the same file — has no fixture of its own: no reachable
/// state has one hook's edit queued for a registry while another's is
/// neither queued nor satisfied.)
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_that_did_not_resolve_keeps_its_copy_while_its_sibling_moves() {
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
    assert_eq!(
        said.iter()
            .filter(|note| note.contains("guard.sh.disabled"))
            .count(),
        1,
        "{said:?}"
    );
    apply(&w);
    assert!(
        twin.is_file(),
        "the twin kendex cannot prove is not kendex's to take"
    );
    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "and its sibling name holds with it: one installation, one answer"
    );
    assert!(
        fs::read_to_string(w.dot().join("hooks.json"))
            .unwrap()
            .contains(".pi/hooks/guard.sh"),
        "so what runs it is left alone too"
    );
}

/// Both of a hook's names, both provably kendex's, both taken — beside a
/// stranger's file that keeps the directory. Claiming only the first
/// would leave the other sitting in the reserved name forever.
#[test]
#[allow(clippy::unwrap_used)]
fn both_of_a_hooks_names_are_taken_when_both_prove_out() {
    let w = regressed();
    let dir = w.dot().join("hooks");
    fs::copy(dir.join("guard.sh"), dir.join("guard.sh.disabled")).unwrap();
    fs::write(dir.join("theirs.sh"), "#!/bin/sh\n").unwrap();

    apply(&w);

    assert!(!dir.join("guard.sh").exists(), "the enabled name goes");
    assert!(
        !dir.join("guard.sh.disabled").exists(),
        "and so does the name it keeps its bytes under when it is off"
    );
    assert!(dir.join("theirs.sh").is_file());
}
