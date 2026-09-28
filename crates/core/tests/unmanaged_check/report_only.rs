//! The session hook's check, `CheckMode::ReportOnly`: it writes no
//! project's committed install record on any branch, and reports each
//! render the record has no row for, the ones a stat cannot see included,
//! with its path and both hashes. The global scope's record is not
//! committed and is settled as a check run by hand settles it.

use std::fs;

use kendex_core::apply;
use kendex_core::drift::{self, copies::CheckMode};
use kendex_core::engine::audit;

use super::world;

fn report(w: &super::World, mode: CheckMode) -> String {
    drift::report::render_plain(&drift::report::check(
        &w.env,
        std::slice::from_ref(&w.scope),
        mode,
    ))
}

/// A clone carrying renders and no record, in a project outside Git,
/// where a check run by hand settles it: the report-only check records
/// nothing and names every missing row, the hook the stat never sees
/// among them, against the hash the apply recorded. The control is the
/// same state checked by hand, which records every row.
#[test]
#[allow(clippy::unwrap_used)]
fn a_report_only_check_names_every_missing_row_and_records_none() {
    let w = world();
    let planned = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &planned.plan).unwrap();
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    let applied = kendex_core::lock::load(&lock_path).unwrap();
    fs::remove_file(&lock_path).unwrap();

    let text = report(&w, CheckMode::ReportOnly);
    assert!(!lock_path.exists(), "the record was written: {text}");
    assert!(text.starts_with("not in the install record:\n"), "{text}");
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
