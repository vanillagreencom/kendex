//! The pass is paid for once per state: its verdicts are memoized under
//! the inputs they were measured from, a check inside the session hook's
//! budget gives the plan up rather than outrunning the hook, and the
//! background refresh finishes what the budget cut short.

use std::fs;
use std::time::Duration;

use kendex_core::apply;
use kendex_core::drift;
use kendex_core::drift::copies;
use kendex_core::engine::audit;

use super::{report, world, write_at};

/// A second check on the same state reads the memo, never the plan: the
/// verdict is whatever the memo says. The file is edited between the two
/// checks, and the second prints the edit — a check that planned again
/// would print what the plan measured.
#[test]
#[allow(clippy::unwrap_used)]
fn the_same_state_is_judged_once_and_read_after() {
    let w = world();
    write_at(
        w.home.join("app/.claude/skills/deploy/SKILL.md"),
        "the tool that came before",
    );
    let text = report(&w);
    assert!(text.contains(": 1 file differs from"), "{text}");
    let memo = copies::memo_path(&w.env, &w.scope);
    let written = fs::read_to_string(&memo).unwrap();
    assert!(written.contains("\"files\": 1"), "{written}");
    fs::write(&memo, written.replace("\"files\": 1", "\"files\": 7")).unwrap();

    let text = report(&w);
    assert!(
        text.contains(": 7 files differ from"),
        "the verdict is read, not measured again: {text}"
    );
    assert!(
        !drift::report::wants_background_refresh(&w.env, std::slice::from_ref(&w.scope)),
        "a state the memo answers for sends nothing to the background"
    );

    // The copy moves: the memo no longer answers for it, and the next
    // check measures again.
    write_at(
        w.home.join("app/.claude/skills/deploy/SKILL.md"),
        "the tool that came before, edited",
    );
    let text = report(&w);
    assert!(text.contains(": 1 file differs from"), "{text}");
}

/// A plan the budget cuts short is a line the check could not produce,
/// naming the budget, with every copy left as the stat found it — never a
/// hook the harness kills with the whole report inside it. The check then
/// wants the background refresh, whose pass writes the memo the next
/// check reads.
#[test]
#[allow(clippy::unwrap_used)]
fn a_pass_past_the_budget_is_given_up_and_finished_in_the_background() {
    let w = world();
    write_at(
        w.home.join("app/.claude/skills/deploy/SKILL.md"),
        "the tool that came before",
    );
    let checked =
        drift::report::check_within(&w.env, std::slice::from_ref(&w.scope), Duration::ZERO);
    let text = drift::report::render_plain(&checked);
    assert_eq!(
        checked.status,
        drift::report::CheckStatus::Unknown,
        "{text}"
    );
    assert!(
        text.contains(
            "could not be compared with their source inside the 0 s the session hook allows"
        ),
        "{text}"
    );
    assert!(
        text.contains("kendex.toml asks for skill 'deploy' for Claude Code")
            && !text.contains("--replace-unmanaged"),
        "nothing judged prescribes no exit: {text}"
    );
    assert!(
        drift::report::wants_background_refresh(&w.env, std::slice::from_ref(&w.scope)),
        "a pass given up is the background refresh's to finish"
    );

    copies::derive(&w.env, &w.scope).unwrap();
    assert!(copies::memo_path(&w.env, &w.scope).is_file());
    let text = drift::report::render_plain(&drift::report::check_within(
        &w.env,
        std::slice::from_ref(&w.scope),
        Duration::ZERO,
    ));
    assert!(
        text.contains("unmanaged copy of skill 'deploy' for Claude Code: 1 file differs from"),
        "the next check reads what the background pass measured: {text}"
    );
}

/// A record that cannot be written leaves every copy it would have
/// recorded where the stat found it — blocked, with the plan to see — and
/// the reason under `could not check`, so the report says it is
/// incomplete rather than clean.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_that_will_not_write_is_could_not_check() {
    use std::os::unix::fs::PermissionsExt;
    let w = world();
    let planned = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &planned.plan).unwrap();
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    fs::remove_file(&lock_path).unwrap();
    let project = w.home.join("app");
    fs::set_permissions(&project, fs::Permissions::from_mode(0o500)).unwrap();
    let restore = || fs::set_permissions(&project, fs::Permissions::from_mode(0o755)).unwrap();

    let checked = drift::report::check(&w.env, std::slice::from_ref(&w.scope));
    let text = drift::report::render_plain(&checked);
    restore();
    assert_eq!(
        checked.status,
        drift::report::CheckStatus::Unknown,
        "{text}"
    );
    assert!(
        text.contains("files matching their source could not be recorded as installed: "),
        "{text}"
    );
    assert!(
        text.contains("kendex.toml asks for skill 'deploy' for Claude Code")
            && text.contains("see: kendex apply --plan"),
        "an unrecorded copy stands as the stat found it: {text}"
    );
    assert!(!lock_path.exists(), "nothing was recorded");
    assert_eq!(
        report(&w),
        "",
        "with the directory writable again the next check records it"
    );
    assert!(lock_path.is_file());
}
