//! Hook presence: an installed hook counts only when the harness will
//! actually RUN it, which is a different artifact set per harness.

use super::*;

mod codex;
mod opencode;

/// Install a hook exactly as `vstack add` does, so presence is checked
/// against the artifacts the installer really writes.
pub(super) fn install_hook_for(source: &Path, name: &str, harness: crate::harness::Harness) {
    let hook =
        crate::hook::Hook::from_file(&source.join("hooks").join(format!("{name}.sh"))).unwrap();
    crate::installer::install_hook(&hook, harness, false, &[]).unwrap();
}

pub(super) fn install_claude_hook(source: &Path, name: &str) {
    install_hook_for(source, name, crate::harness::Harness::ClaudeCode);
}

pub(super) fn install_codex_hook(source: &Path, name: &str) {
    install_hook_for(source, name, crate::harness::Harness::Codex);
}

pub(super) fn codex_hook_lock(source: &Path, name: &str) -> LockFile {
    let mut entry = locked(source, ItemKind::Hook, name);
    entry.harnesses = vec!["codex".into()];
    let mut lock = LockFile::default();
    lock.add(entry);
    lock
}

pub(super) fn phantom_note(report: &ScopeReport) -> String {
    notes(&report.phantom)
}

pub(super) fn unverifiable_note(report: &ScopeReport) -> String {
    notes(&report.unverifiable)
}

pub(super) fn notes(items: &[Item]) -> String {
    items
        .iter()
        .filter_map(|item| item.detail.clone())
        .collect::<Vec<_>>()
        .join("; ")
}

pub(super) fn claude_hook_lock(source: &Path, name: &str) -> LockFile {
    let mut entry = locked(source, ItemKind::Hook, name);
    entry.harnesses = vec!["claude-code".into()];
    let mut lock = LockFile::default();
    lock.add(entry);
    lock
}

/// Rewrite the installed registration, refusing a pattern that matched
/// nothing — a mutation that silently no-ops turns its assertion vacuous.
pub(super) fn rewrite(path: &Path, source: &str, from: &str, to: &str) {
    let mutated = source.replace(from, to);
    assert_ne!(mutated, source, "pattern {from:?} matched nothing");
    std::fs::write(path, mutated).unwrap();
}

/// Claude gets the same standard as codex: a hook is present only when the
/// harness will RUN it. A script whose `settings.json` entry was deleted is a
/// hook claude never runs — `session-drift-check` included, which could then
/// no longer report its own absence.
#[test]
fn a_claude_hook_needs_its_settings_registration_not_just_its_script() {
    with_sandbox("claude-registration", |project, source| {
        write_hook(source, "guard");
        install_claude_hook(source, "guard");
        let lock = claude_hook_lock(source, "guard");

        // Control: the full install is clean.
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.phantom.is_empty(), "control: {report:?}");

        // Only the registration goes; the script stays.
        let settings = project.join(".claude").join("settings.json");
        assert!(settings.exists(), "installer must register the hook");
        let registered = std::fs::read_to_string(&settings).unwrap();
        std::fs::write(&settings, "{}").unwrap();
        assert!(
            project
                .join(".claude")
                .join("hooks")
                .join("guard.sh")
                .exists(),
            "the script must survive, or this proves nothing"
        );
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.phantom), vec!["guard"], "{report:?}");
        assert!(
            phantom_note(&report).contains("script present but not registered"),
            "{report:?}"
        );
        assert!(report.has_drift());

        // A registration under the WRONG event is not this hook's: claude
        // reads it only under the event the hook declares.
        rewrite(&settings, &registered, "PreToolUse", "UserPromptSubmit");
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            phantom_note(&report).contains("script present but not registered"),
            "{report:?}"
        );

        // Restoring the real registration clears it again.
        std::fs::write(&settings, &registered).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.phantom.is_empty(), "{report:?}");
    });
}

/// Claude merges hooks from `settings.local.json` too, so a registration a
/// user keeps there IS run. Calling it missing would prescribe a second
/// registration and fire the hook twice.
#[test]
fn a_registration_claude_still_runs_from_settings_local_counts() {
    with_sandbox("claude-settings-local", |project, source| {
        write_hook(source, "guard");
        install_claude_hook(source, "guard");
        let lock = claude_hook_lock(source, "guard");

        let claude = project.join(".claude");
        let registered = std::fs::read_to_string(claude.join("settings.json")).unwrap();
        std::fs::write(claude.join("settings.json"), "{}").unwrap();
        // Control: with the entry nowhere, this is drift.
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            phantom_note(&report).contains("script present but not registered"),
            "{report:?}"
        );

        std::fs::write(claude.join("settings.local.json"), &registered).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.phantom.is_empty(), "{report:?}");
    });
}

/// Claude's local settings tier is PROJECT-only: it reads
/// `~/.claude/settings.json` and never `~/.claude/settings.local.json`. A
/// stale or hand-made global one let a deleted global registration read as
/// installed — the same fail-open the registration check exists to close,
/// applied to the one scope where the file is not in claude's load order.
#[test]
fn a_global_settings_local_json_answers_for_nothing() {
    with_sandbox("claude-global-settings-local", |_project, source| {
        write_hook(source, "guard");
        let hook = crate::hook::Hook::from_file(&source.join("hooks").join("guard.sh")).unwrap();
        crate::installer::install_hook(&hook, crate::harness::Harness::ClaudeCode, true, &[])
            .unwrap();
        let lock = claude_hook_lock(source, "guard");

        // Control: the real global registration is clean.
        let report = check_scope(true, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "control: {report:?}");

        let claude = config::claude_global_dir();
        let registered = std::fs::read_to_string(claude.join("settings.json")).unwrap();
        std::fs::write(claude.join("settings.json"), "{}").unwrap();
        std::fs::write(claude.join("settings.local.json"), &registered).unwrap();
        let report = check_scope(true, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.phantom), vec!["guard"], "{report:?}");
        assert!(
            phantom_note(&report).contains("script present but not registered"),
            "{report:?}"
        );

        // Control: put it back where claude actually reads it and it is clean.
        std::fs::write(claude.join("settings.json"), &registered).unwrap();
        let report = check_scope(true, &lock, CheckOptions::default()).unwrap();
        assert!(report.phantom.is_empty(), "{report:?}");
    });
}

/// A handler pointing at a same-named script somewhere else is somebody
/// else's; letting it answer would mask the deleted managed entry.
#[test]
fn a_claude_registration_naming_another_script_is_not_this_hook() {
    with_sandbox("claude-other-script", |project, source| {
        write_hook(source, "guard");
        install_claude_hook(source, "guard");
        let lock = claude_hook_lock(source, "guard");
        let settings = project.join(".claude").join("settings.json");
        let registered = std::fs::read_to_string(&settings).unwrap();

        // Same name, another path.
        let elsewhere = project.join("vendor").join("hooks");
        std::fs::create_dir_all(&elsewhere).unwrap();
        std::fs::write(elsewhere.join("guard.sh"), "exit 0\n").unwrap();
        rewrite(
            &settings,
            &registered,
            "$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh",
            &elsewhere.join("guard.sh").to_string_lossy(),
        );
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            phantom_note(&report).contains("script present but not registered"),
            "{report:?}"
        );

        // `pre-guard.sh` must not answer for `guard.sh` either: the JSON is
        // parsed and paths compared, never substring-matched.
        rewrite(&settings, &registered, "guard.sh", "pre-guard.sh");
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            phantom_note(&report).contains("script present but not registered"),
            "{report:?}"
        );

        // Control: a command the user reshaped around OUR script still counts.
        rewrite(
            &settings,
            &registered,
            "bash \\\"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\\\"",
            "timeout 30 bash \\\"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\\\" --strict",
        );
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.phantom.is_empty(), "{report:?}");
    });
}

/// A registration file that EXISTS and cannot be parsed is its own state.
/// Read as an absent registration it was reported as a missing hook, whose
/// printed remedy is `vstack add` — and the installer parsed the same file as
/// `{}` and rewrote it, so following the report discarded every unrelated
/// setting and every other hook registration in it.
#[test]
fn an_unparseable_claude_settings_file_is_unverifiable_and_never_rewritten() {
    with_sandbox("claude-settings-unparseable", |project, source| {
        write_hook(source, "guard");
        install_claude_hook(source, "guard");
        let lock = claude_hook_lock(source, "guard");
        let settings = project.join(".claude").join("settings.json");

        // Control: a valid, complete install is clean.
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "control: {report:?}");

        // Control: a valid file that simply lost the entry is still the
        // missing-registration report, remedied by `vstack add`.
        let registered = std::fs::read_to_string(&settings).unwrap();
        std::fs::write(&settings, "{}").unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.phantom), vec!["guard"], "control: {report:?}");
        assert!(report.unverifiable.is_empty(), "control: {report:?}");

        // The script survives; the settings file no longer parses.
        let malformed = format!("{{\n  \"env\": {{\"KEEP\": \"me\"}},\n{registered}");
        std::fs::write(&settings, &malformed).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            report.phantom.is_empty(),
            "an unreadable file is not a missing hook: {report:?}"
        );
        assert_eq!(names(&report.unverifiable), vec!["guard"], "{report:?}");
        assert!(report.has_drift(), "and it is not clean either: {report:?}");
        let note = unverifiable_note(&report);
        assert!(
            note.contains(&settings.display().to_string()),
            "the note names the file to repair: {note}"
        );
        assert!(
            note.contains("not valid JSON"),
            "…and the parse failure: {note}"
        );

        // The destructive half: neither install nor removal may rewrite a
        // file it could not parse.
        let hook = crate::hook::Hook::from_file(&source.join("hooks").join("guard.sh")).unwrap();
        let err =
            crate::installer::install_hook(&hook, crate::harness::Harness::ClaudeCode, false, &[])
                .expect_err("install must refuse a settings file it cannot parse");
        assert!(
            format!("{err:#}").contains(&settings.display().to_string()),
            "the refusal names the file: {err:#}"
        );
        assert_eq!(
            std::fs::read_to_string(&settings).unwrap(),
            malformed,
            "the user's settings must be byte-identical after a refusal"
        );

        let err = crate::installer::remove_hook_install(
            "guard",
            crate::harness::Harness::ClaudeCode,
            false,
        )
        .expect_err("removal must refuse it too");
        assert!(
            format!("{err:#}").contains(&settings.display().to_string()),
            "{err:#}"
        );
        assert_eq!(
            std::fs::read_to_string(&settings).unwrap(),
            malformed,
            "removal must not rewrite it either"
        );
    });
}

/// Two faults at once, and the report has to name the one whose repair comes
/// FIRST.
///
/// A missing script prescribes `vstack add`; an unparseable `settings.json` is
/// precisely what that command refuses to touch. Reading the registration only
/// when the script was there stopped the report at the fault whose remedy
/// cannot run, and said nothing about the file blocking it.
#[test]
fn a_missing_script_beside_an_unparseable_settings_file_names_the_file_first() {
    with_sandbox("claude-missing-script-and-settings", |project, source| {
        write_hook(source, "guard");
        install_claude_hook(source, "guard");
        let lock = claude_hook_lock(source, "guard");
        let claude = project.join(".claude");
        let settings = claude.join("settings.json");
        let script = claude.join("hooks").join("guard.sh");
        let registered = std::fs::read_to_string(&settings).unwrap();

        // Control: both artifacts healthy is clean.
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "control: {report:?}");

        // Control: a missing script beside a VALID settings file is the
        // missing-install report, exactly as it was.
        std::fs::remove_file(&script).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.phantom), vec!["guard"], "control: {report:?}");
        assert!(report.unverifiable.is_empty(), "control: {report:?}");
        assert!(
            phantom_note(&report).contains("script missing"),
            "control: {report:?}"
        );

        // Both faults: the file that blocks the reinstall is the headline, and
        // the missing script rides along so the next round is not a second
        // surprise.
        let malformed = format!("{{\n  \"env\": {{\"KEEP\": \"me\"}},\n{registered}");
        std::fs::write(&settings, &malformed).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            report.phantom.is_empty(),
            "the remedy that cannot run must not be the headline: {report:?}"
        );
        assert_eq!(names(&report.unverifiable), vec!["guard"], "{report:?}");
        let note = unverifiable_note(&report);
        assert!(
            note.contains(&settings.display().to_string()) && note.contains("not valid JSON"),
            "the note names the file to repair and the parse failure: {note}"
        );
        assert!(
            note.contains("script missing"),
            "…and the second fault, so the user is not sent back twice: {note}"
        );

        // Why the order matters: the reinstall the missing-script report would
        // have prescribed refuses this file, so following it could never have
        // cleared the report.
        let hook = crate::hook::Hook::from_file(&source.join("hooks").join("guard.sh")).unwrap();
        let err =
            crate::installer::install_hook(&hook, crate::harness::Harness::ClaudeCode, false, &[])
                .expect_err("install must refuse a settings file it cannot parse");
        assert!(
            format!("{err:#}").contains(&settings.display().to_string()),
            "the refusal names the file: {err:#}"
        );
        assert_eq!(
            std::fs::read_to_string(&settings).unwrap(),
            malformed,
            "the user's settings must be byte-identical after a refusal"
        );
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(
            names(&report.unverifiable),
            vec!["guard"],
            "the drift the printed remedy was for is still there: {report:?}"
        );

        // Control: repair the named file and the install is whole again — the
        // refused run had already restored the script it could write.
        std::fs::write(&settings, &registered).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(script.exists(), "{report:?}");
        assert!(!report.has_drift(), "control: {report:?}");
    });
}

/// Every registration shape vstack READS, deviating one at a time — a
/// syntactically valid file whose nested shape is not the one the code
/// depends on. Validating only the outer `hooks` object passed all of these:
/// the registration then read as ABSENT, `check` prescribed `vstack add`, and
/// the install replaced the offending value with an empty array — discarding
/// whatever the user had registered under that event.
///
/// The same table runs against claude's `settings.json` and codex's
/// `hooks.json` because they are one document shape read through one
/// validation; a deviation either harness could hold must not depend on which
/// harness happened to hold it.
fn assert_shape_is_unverifiable_and_never_replaced(
    label: &str,
    harness: crate::harness::Harness,
    config: &Path,
    lock: &LockFile,
    source: &Path,
) {
    let hook = crate::hook::Hook::from_file(&source.join("hooks").join("guard.sh")).unwrap();
    for (case, malformed) in [
        // The event value is an object where an array is required.
        (
            "event value is an object",
            r#"{"hooks": {"PreToolUse": {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash keep.sh"}]}}}"#,
        ),
        // An entry of the wrong shape…
        (
            "entry is a string",
            r#"{"hooks": {"PreToolUse": ["bash keep.sh"]}}"#,
        ),
        // …its handler list…
        (
            "handler list is an object",
            r#"{"hooks": {"PreToolUse": [{"hooks": {"type": "command", "command": "bash keep.sh"}}]}}"#,
        ),
        // …a handler itself…
        (
            "handler is a string",
            r#"{"hooks": {"PreToolUse": [{"hooks": ["bash keep.sh"]}]}}"#,
        ),
        // …and the command the whole answer is read out of.
        (
            "command is an array",
            r#"{"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": ["bash", "keep.sh"]}]}]}}"#,
        ),
    ] {
        let case = format!("{label}/{case}");
        std::fs::write(config, malformed).unwrap();
        let report = check_scope(false, lock, CheckOptions::default()).unwrap();
        assert!(
            report.phantom.is_empty(),
            "{case}: a shape nothing understood is not a missing hook: {report:?}"
        );
        assert_eq!(
            names(&report.unverifiable),
            vec!["guard"],
            "{case}: {report:?}"
        );
        let note = unverifiable_note(&report);
        assert!(
            note.contains(&config.display().to_string()),
            "{case}: the note names the file to repair: {note}"
        );
        assert!(
            report.has_drift(),
            "{case}: and it is not clean either: {report:?}"
        );

        let err = crate::installer::install_hook(&hook, harness, false, &[])
            .expect_err("install must refuse a registration shape it cannot read");
        assert!(
            format!("{err:#}").contains(&config.display().to_string()),
            "{case}: the refusal names the file: {err:#}"
        );
        assert_eq!(
            std::fs::read_to_string(config).unwrap(),
            malformed,
            "{case}: the user's file must be byte-identical after a refusal"
        );

        let err = crate::installer::remove_hook_install("guard", harness, false)
            .expect_err("removal must refuse it too");
        assert!(
            format!("{err:#}").contains(&config.display().to_string()),
            "{case}: {err:#}"
        );
        assert_eq!(
            std::fs::read_to_string(config).unwrap(),
            malformed,
            "{case}: removal must not rewrite it either"
        );
    }
}

/// The control the must-fail cases are measured against: a file of the RIGHT
/// shape that simply lacks vstack's handler is still the missing-registration
/// report, and installing appends to it without touching the user's own
/// handler.
fn assert_a_valid_file_without_the_handler_installs(
    label: &str,
    harness: crate::harness::Harness,
    config: &Path,
    lock: &LockFile,
    source: &Path,
) {
    let hook = crate::hook::Hook::from_file(&source.join("hooks").join("guard.sh")).unwrap();
    std::fs::write(
        config,
        r#"{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash keep.sh"}]}]}}"#,
    )
    .unwrap();
    let report = check_scope(false, lock, CheckOptions::default()).unwrap();
    assert!(
        report.unverifiable.is_empty(),
        "{label}: a readable file is not unverifiable: {report:?}"
    );
    assert_eq!(names(&report.phantom), vec!["guard"], "{label}: {report:?}");

    crate::installer::install_hook(&hook, harness, false, &[]).unwrap();
    let written = std::fs::read_to_string(config).unwrap();
    assert!(
        written.contains("bash keep.sh"),
        "{label}: the user's handler survives the append: {written}"
    );
    let report = check_scope(false, lock, CheckOptions::default()).unwrap();
    assert!(!report.has_drift(), "{label}: {report:?}");
}

#[test]
fn a_registration_of_an_unreadable_shape_is_unverifiable_and_never_replaced() {
    with_sandbox("claude-settings-shape", |project, source| {
        write_hook(source, "guard");
        install_claude_hook(source, "guard");
        let lock = claude_hook_lock(source, "guard");
        let settings = project.join(".claude").join("settings.json");

        // Control: the valid install is clean.
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "control: {report:?}");

        assert_shape_is_unverifiable_and_never_replaced(
            "claude",
            crate::harness::Harness::ClaudeCode,
            &settings,
            &lock,
            source,
        );
        assert_a_valid_file_without_the_handler_installs(
            "claude",
            crate::harness::Harness::ClaudeCode,
            &settings,
            &lock,
            source,
        );
    });

    with_sandbox("codex-hooks-shape", |project, source| {
        write_hook(source, "guard");
        install_codex_hook(source, "guard");
        let lock = codex_hook_lock(source, "guard");
        let hooks_json = project.join(".codex").join("hooks.json");

        // Control: the valid install is clean.
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "control: {report:?}");

        assert_shape_is_unverifiable_and_never_replaced(
            "codex",
            crate::harness::Harness::Codex,
            &hooks_json,
            &lock,
            source,
        );
        assert_a_valid_file_without_the_handler_installs(
            "codex",
            crate::harness::Harness::Codex,
            &hooks_json,
            &lock,
            source,
        );
    });
}
