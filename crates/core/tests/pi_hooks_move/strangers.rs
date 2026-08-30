//! What kendex may not take out of the directory Pi reserved: a file it
//! did not write, a directory it has nothing left in, and a registry
//! holding somebody's own hook.

use crate::test_util::source_path;

use std::fs;
use std::os::unix::fs::PermissionsExt;

use kendex_core::engine::audit;
use kendex_core::model::Scope;

use super::{about, apply, notes, regressed, world, world_without_hooks};

#[test]
#[allow(clippy::unwrap_used)]
fn a_file_kendex_did_not_write_keeps_the_reserved_directory_alive() {
    let w = regressed();
    let stranger = w.dot().join("hooks/theirs.sh");
    fs::write(&stranger, "#!/bin/sh\nexit 0\n").unwrap();

    assert_eq!(about(&notes(&w), "theirs.sh").len(), 1);
    apply(&w);

    assert!(stranger.is_file(), "a stranger's file is never taken");
    assert!(!w.dot().join("hooks/guard.sh").exists());
    assert!(w.dot().join("kendex/hooks/guard.sh").is_file());
}

/// The shell an unfinished move left behind is still pi's warning, and an
/// empty directory holds nothing anyone can lose — but the registry
/// beside it is a file kendex removed nothing from.
#[test]
#[allow(clippy::unwrap_used)]
fn an_empty_reserved_directory_left_behind_is_retired() {
    let w = world();
    apply(&w);
    super::forget_the_move(&w.project.join(".kendex-lock.json"));
    fs::create_dir_all(w.dot().join("hooks")).unwrap();
    fs::write(w.dot().join("hooks.json"), "{\"hooks\":{}}\n").unwrap();

    apply(&w);
    assert!(!w.dot().join("hooks").exists());
    assert_eq!(
        fs::read_to_string(w.dot().join("hooks.json")).unwrap(),
        "{\"hooks\":{}}\n",
        "a file kendex has nothing to remove from is not even reformatted"
    );
}

/// The same empty directory where kendex holds no pi hook at all is
/// somebody else's, and stays.
#[test]
#[allow(clippy::unwrap_used)]
fn an_empty_reserved_directory_nobody_claimed_survives() {
    let w = world_without_hooks();
    apply(&w);
    fs::create_dir_all(w.dot().join("hooks")).unwrap();

    apply(&w);
    assert!(w.dot().join("hooks").is_dir());
}

/// The registry is the one file kendex shares: a hook somebody wrote by
/// hand keeps its entry, and the file keeps its place.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_written_registry_entry_survives_the_move() {
    let w = regressed();
    let registry = w.dot().join("hooks.json");
    let mut value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&registry).unwrap()).unwrap();
    value["hooks"]["turn_end"] = serde_json::json!([{
        "hooks": [{ "type": "command", "command": "echo theirs" }]
    }]);
    fs::write(&registry, serde_json::to_string_pretty(&value).unwrap()).unwrap();

    apply(&w);

    let text = fs::read_to_string(&registry).unwrap();
    assert!(text.contains("echo theirs"), "{text}");
    assert!(
        !text.contains(".pi/hooks/guard.sh"),
        "only kendex's own entry comes out: {text}"
    );
}

/// The same promise at the global scope, where the reserved names sit
/// beside `~/.pi/agent`.
#[test]
#[allow(clippy::unwrap_used)]
fn a_global_registry_kendex_never_wrote_to_is_left_alone() {
    let w = world();
    let agent = w.home.join(".pi/agent");
    fs::create_dir_all(agent.join("hooks")).unwrap();
    fs::write(agent.join("hooks/theirs.sh"), "#!/bin/sh\n").unwrap();
    fs::write(
        agent.join("hooks.json"),
        "{\"hooks\":{\"turn_end\":[{\"hooks\":[{\"command\":\"echo theirs\"}]}]}}\n",
    )
    .unwrap();
    let manifest = w.env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::write(
        &manifest,
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"pi\"]\n\n[hooks.guard]\nsource = \"cat\"\n",
            source_path(&w.catalog)
        ),
    )
    .unwrap();

    // Twice: the first apply is what writes the lock the move reads.
    for _ in 0..2 {
        let report = audit(&w.env, &Scope::Global).unwrap();
        kendex_core::apply::execute(&w.env, &report.plan).unwrap();
    }

    assert!(agent.join("hooks/theirs.sh").is_file());
    assert!(
        fs::read_to_string(agent.join("hooks.json"))
            .unwrap()
            .contains("echo theirs")
    );
    assert!(agent.join("kendex/hooks/guard.sh").is_file());
}

/// A managed project where kendex holds no pi hook at all: the reserved
/// names beside its root are entirely somebody else's.
#[test]
#[allow(clippy::unwrap_used)]
fn a_reserved_directory_kendex_never_wrote_to_is_left_alone() {
    let w = world_without_hooks();
    apply(&w);
    fs::create_dir_all(w.dot().join("hooks")).unwrap();
    fs::write(w.dot().join("hooks/theirs.sh"), "#!/bin/sh\nexit 0\n").unwrap();
    fs::write(
        w.dot().join("hooks.json"),
        "{\"hooks\":{\"turn_end\":[{\"hooks\":[{\"command\":\"echo theirs\"}]}]}}\n",
    )
    .unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    assert!(report.notes.is_empty(), "{:?}", report.notes);
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();

    assert!(w.dot().join("hooks/theirs.sh").is_file());
    assert!(
        fs::read_to_string(w.dot().join("hooks.json"))
            .unwrap()
            .contains("echo theirs")
    );
}

/// A registry kendex removed nothing from is never taken, however empty
/// the shape it happens to be in: the removal edit's own pruning would
/// otherwise collapse a stranger's structurally-empty document to `{}`
/// and read that as "kendex emptied it".
#[test]
#[allow(clippy::unwrap_used)]
fn a_structurally_empty_registry_kendex_removed_nothing_from_survives() {
    for shape in [
        "{\"hooks\":{\"tool_call\":[]}}\n",
        "{\"hooks\":{\"tool_call\":[{\"hooks\":[]}]}}\n",
    ] {
        let w = world();
        apply(&w);
        fs::write(w.dot().join("hooks.json"), shape).unwrap();

        apply(&w);

        assert_eq!(
            fs::read_to_string(w.dot().join("hooks.json")).unwrap(),
            shape,
            "kendex removed nothing from it, so it is neither rewritten nor taken"
        );
    }
}

/// A registry holding kendex's own entry that the edit cannot re-parse
/// blocks the whole retirement: taking the script while its registration
/// has to stay would leave that registration naming nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn a_registration_that_cannot_be_taken_out_holds_its_script() {
    let w = regressed();
    let registry = w.dot().join("hooks.json");
    let text = fs::read_to_string(&registry).unwrap();
    let jsonc = format!("// mine\n{text}");
    fs::write(&registry, &jsonc).unwrap();

    let said = audit(&w.env, &w.scope()).unwrap().notes;
    assert!(
        said.iter().any(|note| note.contains("hooks.json")
            && note.contains("registration and the script it names have to go together")),
        "{said:?}"
    );
    apply(&w);

    assert_eq!(fs::read_to_string(&registry).unwrap(), jsonc);
    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "the script stays with the registration that names it"
    );
    assert!(
        !w.dot().join("kendex/hooks/guard.sh").exists(),
        "and nothing was installed beside it"
    );
}

/// One the reader itself cannot make sense of is the same promise, said
/// in its own cause.
#[test]
#[allow(clippy::unwrap_used)]
fn a_registry_that_does_not_parse_is_left_alone_with_a_line() {
    let w = regressed();
    let registry = w.dot().join("hooks.json");
    fs::write(&registry, "not json at all\n").unwrap();

    let said = audit(&w.env, &w.scope()).unwrap().notes;
    assert!(
        said.iter()
            .any(|note| note.contains("could not be read") && note.contains("hooks.json")),
        "{said:?}"
    );
    apply(&w);
    assert_eq!(fs::read_to_string(&registry).unwrap(), "not json at all\n");
}

/// A registry the reader tolerates but the edit could not re-parse is
/// left alone even when kendex has nothing in it to remove — the
/// short-circuit before the rewrite is what keeps it from being read as
/// a document kendex emptied.
#[test]
#[allow(clippy::unwrap_used)]
fn a_jsonc_registry_kendex_has_nothing_in_is_left_alone() {
    let w = world();
    apply(&w);
    let registry = w.dot().join("hooks.json");
    let theirs =
        "// theirs\n{\"hooks\":{\"turn_end\":[{\"hooks\":[{\"command\":\"echo theirs\"}]}]}}\n";
    fs::write(&registry, theirs).unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    assert!(report.notes.is_empty(), "{:?}", report.notes);
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();

    assert_eq!(fs::read_to_string(&registry).unwrap(), theirs);
}

/// The module holds back rather than fails: a legacy registry it cannot
/// read must not take the whole audit down with it.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_registry_is_a_note_not_a_failed_audit() {
    let w = regressed();
    let registry = w.dot().join("hooks.json");
    fs::set_permissions(&registry, fs::Permissions::from_mode(0o000)).unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("could not read") && note.contains("hooks.json")),
        "{:?}",
        report.notes
    );
    fs::set_permissions(&registry, fs::Permissions::from_mode(0o644)).unwrap();
}

/// The preview says what the op does: this arm fires precisely because
/// there are no hooks left in the directory, so it cannot claim a move.
#[test]
#[allow(clippy::unwrap_used)]
fn the_empty_directory_op_says_what_it_does() {
    let w = world();
    apply(&w);
    super::forget_the_move(&w.project.join(".kendex-lock.json"));
    fs::create_dir_all(w.dot().join("hooks")).unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    let said: Vec<String> = report.plan.ops.iter().map(|op| op.line()).collect();
    assert!(
        said.iter().any(|line| line.starts_with("Remove the empty")),
        "{said:?}"
    );
    assert!(
        !said.iter().any(|line| line.starts_with("Move pi hooks")),
        "nothing is being moved: {said:?}"
    );
    assert!(
        report.notes.iter().any(|note| note.contains("is empty")),
        "{:?}",
        report.notes
    );
}

/// Ownership is proven at plan time and the deletion binds to exactly
/// that state: a file dropped into the reserved directory between the
/// preview and the apply fails the precondition instead of going to the
/// trash along with everything else.
#[test]
#[allow(clippy::unwrap_used)]
fn a_directory_that_changed_since_the_preview_is_not_taken() {
    let w = regressed();
    let report = audit(&w.env, &w.scope()).unwrap();
    fs::write(w.dot().join("hooks/appeared.sh"), "#!/bin/sh\n").unwrap();

    let outcome = kendex_core::apply::execute(&w.env, &report.plan);

    assert!(outcome.is_err(), "a stale plan must not take the directory");
    assert!(w.dot().join("hooks/appeared.sh").is_file());
    assert!(w.dot().join("hooks/guard.sh").is_file());
}

/// Everything left under the reserved name gets its line, including when
/// nothing moved this pass: fixing the edit is not enough while a
/// stranger's file is keeping pi's warning alive, and only this line
/// says so.
#[test]
#[allow(clippy::unwrap_used)]
fn a_held_file_and_a_stranger_are_both_reported() {
    let w = regressed();
    fs::write(
        w.dot().join("hooks/guard.sh"),
        "#!/bin/sh\n# mine\nexit 0\n",
    )
    .unwrap();
    fs::write(w.dot().join("hooks/theirs.sh"), "#!/bin/sh\n").unwrap();

    let said = audit(&w.env, &w.scope()).unwrap().notes;

    assert!(
        said.iter().any(|note| note.contains("was edited on disk")),
        "{said:?}"
    );
    assert!(
        said.iter()
            .any(|note| note.contains("did not write") && note.contains("theirs.sh")),
        "the stranger keeping the warning alive has to be said too: {said:?}"
    );
}

/// The edit that retires a registration takes out every handler carrying
/// the command, so a second entry wearing it — a matcher somebody added
/// by hand — cannot be told from kendex's own. Ambiguous means held.
#[test]
#[allow(clippy::unwrap_used)]
fn a_command_registered_twice_holds_rather_than_guessing() {
    let w = regressed();
    let registry = w.dot().join("hooks.json");
    let mut value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&registry).unwrap()).unwrap();
    let command = value["hooks"]["tool_call"][0]["hooks"][0]["command"].clone();
    value["hooks"]["tool_call"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::json!({
            "matcher": "edit",
            "hooks": [{ "type": "command", "command": command }]
        }));
    let theirs = serde_json::to_string_pretty(&value).unwrap();
    fs::write(&registry, &theirs).unwrap();

    let said = audit(&w.env, &w.scope()).unwrap().notes;
    assert!(
        said.iter()
            .any(|note| note.contains("more than once") && note.contains("hooks.json")),
        "{said:?}"
    );
    apply(&w);

    assert_eq!(
        fs::read_to_string(&registry).unwrap(),
        theirs,
        "the hand-added handler keeps its place, and so does the file"
    );
    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "and the script it might name stays with it"
    );
}
