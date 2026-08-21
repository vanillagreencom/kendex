//! What a record that cannot name the old entry is worth.
//!
//! A lock written before kendex kept a registration, or before it kept a
//! matcher, says less than a later one. Read as "there was nothing", the
//! entry that is really there stays behind and a second one goes in
//! beside it; read honestly, the document is asked instead, and what it
//! says is what comes out.
#![cfg(unix)]

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
    catalog: PathBuf,
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
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n{declarations}",
            catalog.display()
        ),
    )
    .unwrap();

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        catalog,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();
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

/// A lock from before kendex recorded what it registered, upgraded in the
/// same refresh that moves the hook. Read as "nothing was registered",
/// the entry that is really there stays and the new one goes in beside
/// it: the hook fires twice, and no later pass can find the old one,
/// because the record it writes describes only the new.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_that_names_no_registration_still_retires_the_entry_it_left() {
    let f = fixture("[hooks.guard]\nsource = \"cat\"\n");
    apply_now(&f);
    assert_eq!(groups(&f), vec![("Bash".to_owned(), 1)]);
    as_written_by(&f, "hook:guard:claude", &[]);

    fs::write(
        f.catalog.join("hooks/guard.sh"),
        GUARD.replace("# event: PreToolUse", "# event: Stop"),
    )
    .unwrap();
    apply_now(&f);

    assert!(
        groups(&f).is_empty(),
        "what it left under the old event comes out: {}",
        settings(&f)
    );
    assert_eq!(
        settings(&f)["hooks"]["Stop"].as_array().unwrap().len(),
        1,
        "and one entry stands where the catalog now asks"
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
    apply::execute(&f.env, &second.plan, None).unwrap();
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

/// The other side of the same question: a record that names an entry is
/// not proof the entry is still there. Moved by hand with its command
/// unchanged, the record still matches what this pass means to render, so
/// nothing is retired and the upsert puts a second one in beside theirs.
#[test]
#[allow(clippy::unwrap_used)]
fn a_recorded_entry_moved_by_hand_is_never_doubled() {
    let f = fixture(MINE);
    apply_now(&f);
    assert_eq!(groups(&f), vec![("Bash".to_owned(), 1)]);

    let mut value = settings(&f);
    let group = value["hooks"]["PreToolUse"][0].clone();
    value["hooks"] = serde_json::json!({ "Stop": [group] });
    let theirs = serde_json::to_string_pretty(&value).unwrap();
    fs::write(f.project.join(".claude/settings.json"), &theirs).unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.name == "mine" && row.detail.contains("no longer runs")),
        "the person is told what is in the way: {:?}",
        report.drift
    );
    apply::execute(&f.env, &report.plan, None).unwrap();

    assert_eq!(
        fs::read_to_string(f.project.join(".claude/settings.json")).unwrap(),
        theirs,
        "and nothing is registered beside what they moved"
    );
}
