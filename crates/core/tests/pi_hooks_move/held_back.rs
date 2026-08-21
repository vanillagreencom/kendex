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
    let about_twin: Vec<&String> = said
        .iter()
        .filter(|note| note.contains("guard.sh.disabled"))
        .collect();
    assert_eq!(about_twin.len(), 1, "{said:?}");
    assert!(
        about_twin[0].contains(
            &w.dot()
                .join("kendex/hooks/guard.sh.disabled")
                .display()
                .to_string()
        ),
        "the line points at where those bytes belong: {about_twin:?}"
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

/// A hold is not a disappearance: the record that this hook is kendex's
/// has to survive it, or the next pass has nothing to claim the file
/// with and the person's copy becomes an unclaimable stranger forever.
#[test]
#[allow(clippy::unwrap_used)]
fn a_held_installation_keeps_its_record() {
    let w = regressed();
    fs::write(
        w.dot().join("hooks/guard.sh"),
        "#!/bin/sh\n# mine\nexit 0\n",
    )
    .unwrap();

    apply(&w);

    let lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(w.project.join(".kendex-lock.json")).unwrap())
            .unwrap();
    assert!(
        lock["entries"].get("hook:guard:pi").is_some(),
        "the record has to outlive the hold: {lock}"
    );
    // And the next pass still knows the file is kendex's.
    assert!(
        about(&notes(&w), "guard.sh")
            .iter()
            .any(|note| note.contains("was edited on disk")),
        "{:?}",
        notes(&w)
    );
}

/// A hook nobody declares any more, with both its names on disk and one
/// of them unclaimable: neither goes. Taking the provable half would
/// leave half an installation under a name pi warns about.
#[test]
#[allow(clippy::unwrap_used)]
fn an_undeclared_hook_with_an_unclaimable_twin_keeps_both_names() {
    let w = regressed();
    let dir = w.dot().join("hooks");
    fs::write(dir.join("guard.sh.disabled"), "#!/bin/sh\n# theirs\n").unwrap();
    let manifest = w.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace("[hooks.guard]\nsource = \"cat\"\n", ""),
    )
    .unwrap();

    apply(&w);

    assert!(
        dir.join("guard.sh").is_file(),
        "the provable half stays too"
    );
    assert!(dir.join("guard.sh.disabled").is_file());
}

/// The hold is a pi-hook answer: an item of another kind that happens to
/// share the name is planned exactly as it would have been.
#[test]
#[allow(clippy::unwrap_used)]
fn a_same_named_item_of_another_kind_is_not_held() {
    let w = regressed();
    let manifest = w.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        format!("{text}\n[agents.guard]\nsource = \"cat\"\n"),
    )
    .unwrap();
    fs::write(
        w.catalog.join("agents/guard.md"),
        "---\nname: guard\ndescription: a guard agent\n---\n\nGuard.\n",
    )
    .unwrap();
    fs::write(
        w.dot().join("hooks/guard.sh"),
        "#!/bin/sh\n# mine\nexit 0\n",
    )
    .unwrap();

    apply(&w);

    assert!(
        w.dot().join("agents/guard.md").is_file(),
        "the agent has nothing to do with the pi hook's hold"
    );
    assert!(w.dot().join("hooks/guard.sh").is_file());
}
