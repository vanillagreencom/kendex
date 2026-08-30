//! What a record that cannot name the old entry is worth.
//!
//! A lock written before kendex kept a registration, or before it kept a
//! matcher, says less than a later one — and retires no more than it can
//! name. Only an entry the record identifies unambiguously comes out;
//! anything less settles, registers under its own identity, and leaves
//! the person's entries to them. Outside pi, a refresh never wedges on
//! what the document holds.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

const GUARD: &str = "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: check shell commands\n# ---\nexit 0\n";

const MINE: &str = "[[custom-hooks]]\nname = \"mine\"\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"./scripts/mine.sh\"\nagents = \"all\"\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture(declarations: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    fs::write(catalog.join("hooks/guard.sh"), GUARD).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n{declarations}",
            source_path(&catalog)
        ),
    )
    .unwrap();

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn settings(f: &Fixture) -> serde_json::Value {
    serde_json::from_str(&fs::read_to_string(f.project.join(".claude/settings.json")).unwrap())
        .unwrap()
}

/// Every group under the one event these fixtures use, by its matcher and
/// how many handlers it carries.
#[allow(clippy::unwrap_used)]
fn groups(f: &Fixture) -> Vec<(String, usize)> {
    settings(f)["hooks"]["PreToolUse"]
        .as_array()
        .unwrap_or(&Vec::new())
        .iter()
        .map(|group| {
            (
                group["matcher"].as_str().unwrap_or_default().to_owned(),
                group["hooks"].as_array().map_or(0, Vec::len),
            )
        })
        .collect()
}

/// Rewrite the lock the way a version that kept less would have: `keep`
/// names the fields of the registration record that version had.
#[allow(clippy::unwrap_used)]
fn as_written_by(f: &Fixture, key: &str, keep: &[&str]) {
    let path = f.project.join(".kendex-lock.json");
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    let entry = lock["entries"][key].as_object_mut().unwrap();
    match keep.is_empty() {
        true => {
            entry.remove("registration");
        }
        false => {
            let registration = entry["registration"].as_object_mut().unwrap();
            registration.retain(|field, _| keep.contains(&field.as_str()));
        }
    }
    fs::write(&path, serde_json::to_string_pretty(&lock).unwrap()).unwrap();
}

/// A record that names no registration leaves the document alone. The
/// command is all such a record could look an entry up by, and the
/// person's own registration of the same command answers that search
/// too: read as kendex's leftovers, their entry put the hook in conflict
/// on every refresh, with nothing to settle it. Only pi's reserved-name
/// move searches by command, because only it deletes what it finds.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_that_names_no_registration_leaves_their_duplicate_alone() {
    let f = fixture("[hooks.guard]\nsource = \"cat\"\n");
    apply_now(&f);
    assert_eq!(groups(&f), vec![("Bash".to_owned(), 1)]);
    as_written_by(&f, "hook:guard:claude", &[]);

    // Theirs, running the same command under an event of their own.
    let mut value = settings(&f);
    let command = value["hooks"]["PreToolUse"][0]["hooks"][0]["command"].clone();
    value["hooks"]["Stop"] = serde_json::json!([{
        "matcher": "Edit",
        "hooks": [{ "type": "command", "command": command }]
    }]);
    fs::write(
        f.project.join(".claude/settings.json"),
        serde_json::to_string_pretty(&value).unwrap(),
    )
    .unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .all(|row| !row.detail.contains("more than once")),
        "their duplicate is not kendex's to wonder about: {:?}",
        report.drift
    );
    apply::execute(&f.env, &report.plan).unwrap();

    assert_eq!(
        groups(&f),
        vec![("Bash".to_owned(), 1)],
        "kendex's entry stands where it was: {}",
        settings(&f)
    );
    assert_eq!(
        settings(&f)["hooks"]["Stop"].as_array().unwrap().len(),
        1,
        "and theirs where they put it"
    );
    let settled = audit(&f.env, &f.scope).unwrap();
    assert!(settled.plan.ops.is_empty(), "{:?}", settled.plan.ops);
}

/// The same record one field better: it names the event and the command
/// but was kept before matchers were. Read as "no matcher, so no
/// difference", a matcher the catalog changed is never retired and the
/// upsert adds a second registration under the new one.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_that_names_no_matcher_still_retires_the_entry_it_left() {
    let f = fixture(MINE);
    apply_now(&f);
    assert_eq!(groups(&f), vec![("Bash".to_owned(), 1)]);
    as_written_by(&f, "hook:mine:claude", &["event", "command"]);

    let manifest = f.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace("matcher = \"Bash\"", "matcher = \"Write\""),
    )
    .unwrap();
    apply_now(&f);

    assert_eq!(
        groups(&f),
        vec![("Write".to_owned(), 1)],
        "one entry, under the matcher now asked for: {}",
        settings(&f)
    );
    let settled = audit(&f.env, &f.scope).unwrap();
    assert!(settled.plan.ops.is_empty(), "{:?}", settled.plan.ops);
}

/// A matcher can be written empty, and a registry spells that the same way
/// it spells none at all. Spelled one way going in and another coming
/// back, the entry already there is never recognised and every refresh
/// adds one more, for ever.
#[test]
#[allow(clippy::unwrap_used)]
fn an_empty_matcher_registers_once_and_stays_once() {
    let f = fixture(&MINE.replace("matcher = \"Bash\"", "matcher = \"\""));
    apply_now(&f);
    let first = settings(&f);
    assert_eq!(
        groups(&f).len(),
        1,
        "one entry after the first pass: {first}"
    );

    let second = audit(&f.env, &f.scope).unwrap();
    assert!(
        second.plan.ops.is_empty(),
        "and nothing left to do: {:?}",
        second.plan.ops
    );
    apply::execute(&f.env, &second.plan).unwrap();
    assert_eq!(settings(&f), first, "so the file does not grow");
}

/// A hook going in for the first time has no past of its own. Its command
/// is the person's own words in `[[custom-hooks]]`, so they may well have
/// registered it themselves already — and looking through the file for
/// "the entry kendex left" would find theirs and take it on the way in.
#[test]
#[allow(clippy::unwrap_used)]
fn a_first_install_takes_nothing_that_was_already_there() {
    let f = fixture(MINE);
    // Theirs, running the same command under an event of their own.
    fs::write(
        f.project.join(".claude/settings.json"),
        r#"{"hooks":{"Stop":[{"matcher":"Edit","hooks":[{"type":"command","command":"./scripts/mine.sh"}]}]}}"#,
    )
    .unwrap();

    apply_now(&f);

    let value = settings(&f);
    assert_eq!(
        value["hooks"]["Stop"][0]["hooks"][0]["command"], "./scripts/mine.sh",
        "what they registered is untouched: {value}"
    );
    assert_eq!(
        groups(&f),
        vec![("Bash".to_owned(), 1)],
        "and kendex's goes in beside it: {value}"
    );
}

/// The same record, and the one entry it could have matched by command
/// has been moved to another event. A search by command alone would call
/// the moved entry kendex's and take it; a record that names no
/// registration takes nothing — the refresh registers under the identity
/// it renders, the moved entry stays where the person put it, and the
/// record written this pass settles every refresh after.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_that_names_no_registration_leaves_a_moved_entry_alone() {
    let f = fixture("[hooks.guard]\nsource = \"cat\"\n");
    apply_now(&f);
    assert_eq!(groups(&f), vec![("Bash".to_owned(), 1)]);
    as_written_by(&f, "hook:guard:claude", &[]);

    let mut value = settings(&f);
    let group = value["hooks"]["PreToolUse"][0].clone();
    value["hooks"] = serde_json::json!({ "Stop": [group] });
    fs::write(
        f.project.join(".claude/settings.json"),
        serde_json::to_string_pretty(&value).unwrap(),
    )
    .unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .all(|row| !row.detail.contains("no longer runs")),
        "the moved entry is not kendex's to wonder about: {:?}",
        report.drift
    );
    apply::execute(&f.env, &report.plan).unwrap();

    assert_eq!(
        groups(&f),
        vec![("Bash".to_owned(), 1)],
        "kendex registers under the identity it renders: {}",
        settings(&f)
    );
    assert_eq!(
        settings(&f)["hooks"]["Stop"].as_array().unwrap().len(),
        1,
        "and the moved entry stays where they put it"
    );
    let settled = audit(&f.env, &f.scope).unwrap();
    assert!(settled.plan.ops.is_empty(), "{:?}", settled.plan.ops);
}

/// A record that names its registration exactly, duplicated in place: two
/// entries answer to every field the record kept, and neither can be told
/// from the other. Retiring by guess would take both, and wedging is a
/// conflict the person cannot see past — so the refresh settles without
/// one, and the byte-identical handler converges back to a single entry
/// through the idempotent upsert.
#[test]
#[allow(clippy::unwrap_used)]
fn an_exact_duplicate_of_the_recorded_entry_does_not_wedge_the_refresh() {
    let f = fixture(MINE);
    apply_now(&f);
    assert_eq!(groups(&f), vec![("Bash".to_owned(), 1)]);

    let mut value = settings(&f);
    let handler = value["hooks"]["PreToolUse"][0]["hooks"][0].clone();
    value["hooks"]["PreToolUse"][0]["hooks"]
        .as_array_mut()
        .unwrap()
        .push(handler);
    fs::write(
        f.project.join(".claude/settings.json"),
        serde_json::to_string_pretty(&value).unwrap(),
    )
    .unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .all(|row| !row.detail.contains("more than once")),
        "an exact duplicate is not a wedge: {:?}",
        report.drift
    );
    apply::execute(&f.env, &report.plan).unwrap();
    assert_eq!(
        settings(&f)["hooks"]["PreToolUse"][0]["hooks"]
            .as_array()
            .unwrap()
            .len(),
        1,
        "the byte-identical handler converges to one entry"
    );
    let settled = audit(&f.env, &f.scope).unwrap();
    assert!(settled.plan.ops.is_empty(), "{:?}", settled.plan.ops);
}

/// The other side of the same question: a record that names an entry is
/// not proof the entry is still there. Moved by hand, the entry is the
/// person's own registration of their own command — the refresh registers
/// under the identity it renders and leaves the moved one to them. Held
/// instead, the hook sat in conflict on every refresh, and nothing the
/// refresh could do would ever settle it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_recorded_entry_moved_by_hand_does_not_hold_the_hook() {
    let f = fixture(MINE);
    apply_now(&f);
    assert_eq!(groups(&f), vec![("Bash".to_owned(), 1)]);

    let mut value = settings(&f);
    let group = value["hooks"]["PreToolUse"][0].clone();
    value["hooks"] = serde_json::json!({ "Stop": [group] });
    fs::write(
        f.project.join(".claude/settings.json"),
        serde_json::to_string_pretty(&value).unwrap(),
    )
    .unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .all(|row| !row.detail.contains("no longer runs")),
        "what they moved is theirs, not a conflict: {:?}",
        report.drift
    );
    apply::execute(&f.env, &report.plan).unwrap();

    assert_eq!(
        groups(&f),
        vec![("Bash".to_owned(), 1)],
        "kendex's entry is back where the record names it: {}",
        settings(&f)
    );
    assert_eq!(
        settings(&f)["hooks"]["Stop"].as_array().unwrap().len(),
        1,
        "and the one they moved stays where they put it"
    );
    let settled = audit(&f.env, &f.scope).unwrap();
    assert!(settled.plan.ops.is_empty(), "{:?}", settled.plan.ops);
}

/// A render that changes the command's spelling — the machine's own path
/// giving way to one a clone can follow — is a move like any other: the
/// entry the record names comes out, and the new spelling goes in alone.
/// Keyed on the rendered command, the upsert would find nothing to replace
/// and the hook would fire twice on the machine that installed it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_command_spelled_another_way_replaces_the_entry_it_left() {
    let f = fixture("[hooks.guard]\nsource = \"cat\"\n");
    let manifest = f.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace("harnesses = [\"claude\"]", "harnesses = [\"codex\"]"),
    )
    .unwrap();
    apply_now(&f);

    let registry = f.project.join(".codex/hooks.json");
    let commands = || -> Vec<String> {
        let value: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&registry).unwrap()).unwrap();
        value["hooks"]["PreToolUse"]
            .as_array()
            .unwrap_or(&Vec::new())
            .iter()
            .flat_map(|group| group["hooks"].as_array().cloned().unwrap_or_default())
            .map(|handler| handler["command"].as_str().unwrap().to_owned())
            .collect()
    };
    let portable = commands();
    assert_eq!(portable.len(), 1);
    assert!(portable[0].contains("git rev-parse"), "{portable:?}");

    // What an older kendex left: the machine's path, in the document and
    // in the record alike.
    let absolute = format!("bash {}", f.project.join(".codex/hooks/guard.sh").display());
    fs::write(
        &registry,
        fs::read_to_string(&registry)
            .unwrap()
            .replace(&portable[0].replace('"', "\\\""), &absolute),
    )
    .unwrap();
    assert_eq!(commands(), vec![absolute.clone()], "the rewrite took");
    let lock_path = f.project.join(".kendex-lock.json");
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&lock_path).unwrap()).unwrap();
    lock["entries"]["hook:guard:codex"]["registration"]["command"] =
        serde_json::Value::String(absolute);
    fs::write(&lock_path, serde_json::to_string_pretty(&lock).unwrap()).unwrap();
    apply_now(&f);

    assert_eq!(commands(), portable, "one entry, spelled the new way");
    let settled = audit(&f.env, &f.scope).unwrap();
    assert!(settled.plan.ops.is_empty(), "{:?}", settled.plan.ops);
}
