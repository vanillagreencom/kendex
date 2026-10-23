//! The session hook's check, `CheckMode::ReportOnly`: it writes no
//! project's committed install record on any branch, and reports each
//! render the record has no row for, the ones a stat cannot see included,
//! with its path and both hashes, or a registration by its settings
//! file. The global scope's record is not committed and is settled as a
//! check run by hand settles it.

use std::fs;

use kendex_core::apply;
use kendex_core::drift::{self, copies::CheckMode};
use kendex_core::engine::audit;

use super::world;

fn report(w: &super::World, mode: CheckMode) -> String {
    drift::report::render_plain(
        &drift::report::check(&w.env, std::slice::from_ref(&w.scope), mode),
        kendex_core::drift::report::Verbosity::Verbose,
    )
}

/// A clone carrying renders and no record, in a project outside Git,
/// where a check run by hand settles it: the report-only check records
/// nothing and names every missing row, the hook the stat never sees
/// among them, against the hash the apply recorded, and a plugin, which
/// writes no file, by the settings file it is registered in. The control
/// is the same state checked by hand, which records every row.
#[test]
#[allow(clippy::unwrap_used)]
fn a_report_only_check_names_every_missing_row_and_records_none() {
    let w = world();
    super::declare(
        &w,
        "copy",
        "[\"claude\"]",
        "[skills.deploy]\nsource = \"cat\"\n\n[agents.scout]\nsource = \"cat\"\n\n[commands.ship]\nsource = \"cat\"\n\n[hooks.guard]\nsource = \"cat\"\n\n[plugins.\"plug@market\"]\nenabled = true\n",
    );
    let planned = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &planned.plan).unwrap();
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    let applied = kendex_core::lock::load(&lock_path).unwrap();
    fs::remove_file(&lock_path).unwrap();

    let text = report(&w, CheckMode::ReportOnly);
    assert!(!lock_path.exists(), "the record was written: {text}");
    assert!(text.starts_with("not in the install record: 5\n"), "{text}");
    for (kind, name, path) in [
        ("skill", "deploy", ".claude/skills/deploy"),
        ("agent", "scout", ".claude/agents/scout.md"),
        ("command", "ship", ".claude/commands/ship.md"),
        ("hook", "guard", ".claude/hooks/guard.sh"),
    ] {
        let entry = applied
            .entries
            .values()
            .find(|entry| entry.name == name)
            .unwrap();
        let line = format!(
            "{kind} '{name}' for Claude Code has no row in the install record: {path}, recorded hash none, rendered hash {}; the session check leaves the record as this checkout holds it",
            entry.rendered_hash.as_deref().unwrap()
        );
        assert!(text.contains(&line), "{name}: {text}");
    }
    assert!(
        applied.entries.contains_key("plugin:plug@market:claude"),
        "the fixture records the plugin: {:?}",
        applied.entries.keys()
    );
    assert!(
        text.contains("plugin 'plug@market' for Claude Code has no row in the install record: registered in .claude/settings.json; the session check leaves the record as this checkout holds it"),
        "{text}"
    );

    assert_eq!(report(&w, CheckMode::Settle), "", "the control records");
    assert_eq!(
        kendex_core::lock::load(&lock_path)
            .unwrap()
            .entries
            .keys()
            .collect::<Vec<_>>(),
        applied.entries.keys().collect::<Vec<_>>()
    );
}

/// The global record lives under kendex's own directory, which no
/// repository tracks, so the report-only check settles it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_report_only_check_still_settles_the_global_record() {
    let w = super::memo::global_world();
    let planned = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &planned.plan).unwrap();
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    let applied = kendex_core::lock::load(&lock_path).unwrap();
    fs::remove_file(&lock_path).unwrap();

    let text = report(&w, CheckMode::ReportOnly);
    assert!(!text.contains("not in the install record"), "{text}");
    assert_eq!(
        kendex_core::lock::load(&lock_path)
            .unwrap()
            .entries
            .keys()
            .collect::<Vec<_>>(),
        applied.entries.keys().collect::<Vec<_>>()
    );
}

/// A proven entry no stat keys (an agent whose file went, a hook whose
/// registration was taken out) can move after the background pass
/// memoized it, while a differing command keeps the memo answering. A
/// check that withholds the record still holds that memoized proof to
/// disk: the check that reads it refuses the proof and retires the memo,
/// and neither it nor the check after lists the moved entry as a matching
/// render awaiting a record. Rows cover the session hook's report-only
/// check and a check run by hand off the default branch.
#[test]
#[allow(clippy::unwrap_used)]
fn a_memoized_proof_that_moved_is_not_reported_as_a_matching_render() {
    type Move = fn(&std::path::Path);
    let moves: [(&str, Move); 2] = [
        ("agent 'scout'", |app| {
            fs::remove_file(app.join(".claude/agents/scout.md")).unwrap()
        }),
        ("hook 'guard'", |app| {
            fs::write(app.join(".claude/settings.json"), "{}\n").unwrap()
        }),
    ];
    for (gone, moved) in moves {
        for (mode, branch) in [(CheckMode::ReportOnly, false), (CheckMode::Settle, true)] {
            let row = format!("{gone}, {mode:?}");
            let w = world();
            let app = w.home.join("app");
            if branch {
                git(&app, &["init", "--quiet", "-b", "main"]);
                git(&app, &["symbolic-ref", "HEAD", "refs/heads/lane"]);
            }
            let planned = audit(&w.env, &w.scope).unwrap();
            apply::execute(&w.env, &planned.plan).unwrap();
            let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
            fs::remove_file(&lock_path).unwrap();
            fs::write(
                app.join(".claude/commands/ship.md"),
                "the tool that came before",
            )
            .unwrap();
            drift::copies::derive(&w.env, &w.scope).unwrap();
            let listed = format!("{gone} for Claude Code has no row in the install record");
            let fresh = report(&w, mode);
            assert!(
                fresh.contains(&listed),
                "{row}: the fixture proves it: {fresh}"
            );
            moved(&app);

            let refused = report(&w, mode);
            assert!(
                refused.contains("could not be recorded as installed"),
                "{row}: {refused}"
            );
            assert!(!refused.contains(&listed), "{row}: {refused}");
            let replanned = report(&w, mode);
            assert!(!replanned.contains(&listed), "{row}: {replanned}");
            assert!(
                replanned.contains("skill 'deploy' for Claude Code has no row"),
                "{row}: what still proves itself is still listed: {replanned}"
            );
            assert!(!lock_path.exists(), "{row}: the record was written");
        }
    }
}

#[allow(clippy::unwrap_used)]
fn git(dir: &std::path::Path, args: &[&str]) {
    let output = kendex_core::process::Hardened::git(args, Some(dir))
        .run()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}
