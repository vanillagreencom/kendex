//! The shared config files registrations land in are the user's — and
//! another tool's — as much as ours: a link is followed, its key order is
//! kept, and one kendex cannot read blocks one registration, not a scope.

use std::fs;

use kendex_core::engine::{DriftState, audit};
use serde_json::Value;

use super::{apply_now, fixture, is_clean, json, settings};

/// Dotfile setups keep settings.json elsewhere and link to it. The edit
/// lands through the link — link kept, target updated — never a stale plan.
#[test]
fn a_symlinked_settings_file_is_edited_through_the_link() {
    let f = fixture("[hooks.guard]\nsource = \"cat\"\n");
    let real = f.project.join("../dotfiles/settings.json");
    fs::create_dir_all(real.parent().unwrap()).unwrap();
    fs::write(&real, "{\n  \"model\": \"opus\"\n}\n").unwrap();
    std::os::unix::fs::symlink(&real, settings(&f)).unwrap();
    apply_now(&f);

    assert!(settings(&f).is_symlink());
    let registered = json(&real);
    assert_eq!(registered["model"], "opus");
    assert_eq!(registered["hooks"]["PreToolUse"][0]["matcher"], "Bash");
    assert!(is_clean(&f));
}

/// The harness writes this file too, in its own key order, and appends
/// keys of its own. Neither is drift, and an apply never reshuffles them.
#[test]
fn another_writers_key_order_is_kept_and_is_not_drift() {
    let f = fixture("[hooks.guard]\nsource = \"cat\"\n");
    fs::write(
        settings(&f),
        "{\n  \"model\": \"opus\",\n  \"cleanupPeriodDays\": 30\n}\n",
    )
    .unwrap();
    apply_now(&f);
    let mut written = json(&settings(&f));
    let keys: Vec<&String> = written.as_object().unwrap().keys().collect();
    assert_eq!(keys, ["model", "cleanupPeriodDays", "hooks"]);

    written["alwaysThinkingEnabled"] = Value::Bool(true);
    fs::write(
        settings(&f),
        serde_json::to_string_pretty(&written).unwrap() + "\n",
    )
    .unwrap();
    assert!(is_clean(&f), "a key another tool appended is not drift");
}

/// The instructions rows under kendex's render directory are the current
/// render set, no more: a row left by a render nothing records — an older
/// naming, a dropped lock — leaves with its file, while the person's own
/// rows ride through untouched.
#[test]
fn stale_instruction_rows_leave_with_the_files_nothing_renders() {
    let f = fixture("[hooks.audit]\nsource = \"cat\"\nharnesses = [\"opencode\"]\n");
    apply_now(&f);

    let config = f.project.join("opencode.json");
    let mut doc = json(&config);
    let rows = doc["instructions"].as_array_mut().unwrap();
    rows.push(".opencode/instructions/vstack-hook-old.md".into());
    rows.push("AGENTS.md".into());
    fs::write(&config, serde_json::to_string_pretty(&doc).unwrap() + "\n").unwrap();

    apply_now(&f);
    let refreshed = json(&config);
    assert_eq!(
        refreshed["instructions"],
        serde_json::json!([".opencode/instructions/kendex-hook-audit.md", "AGENTS.md"]),
        "the stale row goes with its file; the person's row stays"
    );
    assert!(is_clean(&f));
}

/// A settings file kendex cannot read back blocks that registration alone
/// — named, with the file — while the rest of the scope still plans.
#[test]
fn an_unreadable_settings_file_is_one_conflict_not_a_scope_error() {
    let f = fixture("[hooks.guard]\nsource = \"cat\"\n\n[commands.ship]\nsource = \"cat\"\n");
    fs::write(settings(&f), "{ // my note\n  \"model\": \"opus\"\n}\n").unwrap();
    let report = audit(&f.env, &f.scope).unwrap();
    let conflict = report
        .drift
        .iter()
        .find(|row| row.name == "guard")
        .expect("the hook is reported");
    assert_eq!(conflict.state, DriftState::Conflict);
    assert!(
        conflict.detail.contains("settings.json"),
        "{}",
        conflict.detail
    );
    assert!(
        report
            .plan
            .ops
            .iter()
            .any(|op| op.description.contains("ship"))
    );
    assert!(
        !report
            .plan
            .ops
            .iter()
            .any(|op| op.description.contains("guard")),
        "a hook that cannot register does not half-install"
    );
}
