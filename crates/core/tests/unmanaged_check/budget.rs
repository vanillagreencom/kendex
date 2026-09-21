//! The deadline the deep read gives up at is one instant for the whole
//! check, whatever it covers: the session hook's check reads the project
//! and the global scope in one run, and a budget spent once per scope
//! would put two occupied scopes past the hook's own timeout. That the
//! instant is one per check is `check_within`'s by construction — set
//! once before its scope loop, and the pass takes only an instant — and
//! no fixture input controls how long a plan takes, so no case here can
//! redden on a per-scope instant; what these cases hold is that the pass
//! gives up at the instant it is handed, that every read it makes runs
//! against it, and what one check over two scopes reports.

use std::collections::BTreeMap;
use std::fs;
use std::time::{Duration, Instant};

use kendex_core::drift;
use kendex_core::drift::copies;
use kendex_core::engine::Occupied;

use super::{declare, report, world, write_at};

/// What the check hands the pass: the manifest, the record as read, and
/// the occupied installations the stat found.
#[allow(clippy::unwrap_used)]
fn occupied(w: &super::World) -> (kendex_core::manifest::Manifest, BTreeMap<String, Occupied>) {
    let manifest = kendex_core::manifest::load_current(&kendex_core::manifest::manifest_path(
        &w.env, &w.scope,
    ))
    .unwrap()
    .unwrap();
    let occupied = kendex_core::engine::declared_over_existing_files(
        &w.env,
        &w.scope,
        &manifest,
        &kendex_core::lock::Lock::default(),
    );
    (manifest, occupied)
}

/// The pass honours the instant it is handed, not a budget of its own: a
/// deadline already past plans nothing and memoizes nothing, and names
/// the budget the check set it from.
#[test]
#[allow(clippy::unwrap_used)]
fn the_pass_gives_up_at_the_instant_it_is_handed() {
    let w = world();
    write_at(
        w.home.join("app/.claude/skills/deploy/SKILL.md"),
        "the tool that came before",
    );
    let (manifest, occupied) = occupied(&w);
    let settled = copies::settle(
        &w.env,
        &w.scope,
        &manifest,
        &kendex_core::lock::Lock::default(),
        &occupied,
        Instant::now() - Duration::from_secs(1),
        Duration::from_secs(8),
    );
    assert!(
        matches!(settled, copies::Settled::Overrun { budget } if budget == Duration::from_secs(8)),
        "{settled:?}"
    );
    assert!(
        !copies::memo_path(&w.env, &w.scope).exists(),
        "nothing was planned, so nothing is memoized"
    );

    let settled = copies::settle(
        &w.env,
        &w.scope,
        &manifest,
        &kendex_core::lock::Lock::default(),
        &occupied,
        Instant::now() + Duration::from_secs(60),
        Duration::from_secs(60),
    );
    assert!(
        matches!(settled, copies::Settled::Judged { .. }),
        "the control: an instant still ahead plans: {settled:?}"
    );
}

/// A memo the check can read is a read like the plan: the keys that find
/// it hash every position, and the record write binds to every proven
/// file's hash. Past the deadline none of it starts, the memo included,
/// and the copies the record would have recorded stand as the stat found
/// them. A binding alone that runs out, with the verdicts already in
/// hand, is `copies::tests` (the memo's verdicts stay the lines, and the
/// could-not-check line names the binding).
#[test]
#[allow(clippy::unwrap_used)]
fn nothing_is_read_past_the_deadline_the_memo_included() {
    let w = world();
    let planned = kendex_core::engine::audit(&w.env, &w.scope).unwrap();
    kendex_core::apply::execute(&w.env, &planned.plan).unwrap();
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    fs::remove_file(&lock_path).unwrap();
    copies::derive(&w.env, &w.scope).unwrap();
    let memo = fs::read_to_string(copies::memo_path(&w.env, &w.scope)).unwrap();
    assert!(memo.contains("\"measured\": \"proven\""), "{memo}");

    let checked =
        drift::report::check_within(&w.env, std::slice::from_ref(&w.scope), Duration::ZERO);
    let text = drift::report::render_plain(&checked);
    assert_eq!(
        checked.status,
        drift::report::CheckStatus::Unknown,
        "{text}"
    );
    assert!(
        text.contains("could not be compared with their source inside the 0 s")
            && text.contains("kendex.toml asks for skill 'deploy' for Claude Code"),
        "{text}"
    );
    assert!(
        !lock_path.exists(),
        "nothing was recorded past the deadline"
    );
    assert_eq!(
        report(&w),
        "",
        "with time to read, the memo's verdicts record the copies"
    );
    assert!(lock_path.is_file());
}

/// One check over two occupied scopes reports both as owed under one
/// budget, and the report carries that the pass is owed once for the
/// caller's spawn decision.
#[test]
#[allow(clippy::unwrap_used)]
fn one_check_over_two_scopes_reports_the_pass_owed_once() {
    let w = world();
    write_at(
        w.home.join("app/.claude/skills/deploy/SKILL.md"),
        "the tool that came before",
    );
    // The global scope declares the same catalog's skill over a copy of
    // its own.
    fs::create_dir_all(w.home.join(".kendex")).unwrap();
    let global_manifest =
        kendex_core::manifest::manifest_path(&w.env, &kendex_core::model::Scope::Global);
    fs::create_dir_all(global_manifest.parent().unwrap()).unwrap();
    fs::write(
        &global_manifest,
        fs::read_to_string(w.home.join("app/kendex.toml")).unwrap(),
    )
    .unwrap();
    declare(
        &w,
        "copy",
        "[\"claude\"]",
        "[skills.deploy]\nsource = \"cat\"\n",
    );
    write_at(
        w.home.join(".claude/skills/deploy/SKILL.md"),
        "the tool that came before",
    );
    let scopes = [w.scope.clone(), kendex_core::model::Scope::Global];

    let checked = drift::report::check_within(&w.env, &scopes, Duration::ZERO);
    let text = drift::report::render_plain(&checked);
    assert_eq!(
        text.matches("inside the 0 s the session hook allows")
            .count(),
        2,
        "each scope says the one budget ran out: {text}"
    );
    assert!(checked.deep_pass_owed, "{text}");

    let checked = drift::report::check_within(&w.env, &scopes, Duration::from_secs(60));
    let text = drift::report::render_plain(&checked);
    assert_eq!(
        text.matches("unmanaged copy of skill 'deploy' for Claude Code")
            .count(),
        2,
        "the control: a deadline still ahead judges both: {text}"
    );
    assert!(!checked.deep_pass_owed, "{text}");
}
