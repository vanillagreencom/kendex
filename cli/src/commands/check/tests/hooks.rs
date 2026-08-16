//! Hook presence: an installed hook counts only when the harness will
//! actually RUN it, which is a different artifact set per harness.

use super::*;

/// Install a hook exactly as `vstack add` does, so presence is checked
/// against the artifacts the installer really writes.
fn install_hook_for(source: &Path, name: &str, harness: crate::harness::Harness) {
    let hook =
        crate::hook::Hook::from_file(&source.join("hooks").join(format!("{name}.sh"))).unwrap();
    crate::installer::install_hook(&hook, harness, false, &[]).unwrap();
}

fn install_codex_hook(source: &Path, name: &str) {
    install_hook_for(source, name, crate::harness::Harness::Codex);
}

pub(super) fn install_claude_hook(source: &Path, name: &str) {
    install_hook_for(source, name, crate::harness::Harness::ClaudeCode);
}

fn codex_hook_lock(source: &Path, name: &str) -> LockFile {
    let mut entry = locked(source, ItemKind::Hook, name);
    entry.harnesses = vec!["codex".into()];
    let mut lock = LockFile::default();
    lock.add(entry);
    lock
}

fn phantom_note(report: &ScopeReport) -> String {
    report
        .phantom
        .iter()
        .filter_map(|item| item.detail.clone())
        .collect::<Vec<_>>()
        .join("; ")
}

#[test]
fn a_codex_native_hook_needs_its_registration_not_just_its_script() {
    with_sandbox("codex-registration", |project, source| {
        write_hook(source, "guard");
        install_codex_hook(source, "guard");
        let lock = codex_hook_lock(source, "guard");

        // Control: the full native install is clean.
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.phantom.is_empty(), "control: {report:?}");

        // The script survives, the registration does not — codex will
        // never run this hook, so it is drift.
        let hooks_json = project.join(".codex").join("hooks.json");
        assert!(hooks_json.exists(), "installer must register the hook");
        std::fs::remove_file(&hooks_json).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.phantom), vec!["guard"], "{report:?}");
        assert!(
            phantom_note(&report).contains("script present but not registered"),
            "{report:?}"
        );
        assert!(report.has_drift());
    });
}

fn claude_hook_lock(source: &Path, name: &str) -> LockFile {
    let mut entry = locked(source, ItemKind::Hook, name);
    entry.harnesses = vec!["claude-code".into()];
    let mut lock = LockFile::default();
    lock.add(entry);
    lock
}

/// Rewrite the installed registration, refusing a pattern that matched
/// nothing — a mutation that silently no-ops turns its assertion vacuous.
fn rewrite(path: &Path, source: &str, from: &str, to: &str) {
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

#[test]
fn a_codex_hooks_json_naming_another_script_is_not_this_hook() {
    with_sandbox("codex-other-script", |project, source| {
        write_hook(source, "guard");
        install_codex_hook(source, "guard");
        let lock = codex_hook_lock(source, "guard");

        // A registration for `pre-guard.sh` must not answer for
        // `guard.sh`: presence parses the JSON and compares file names,
        // never a substring of the file body.
        let hooks_json = project.join(".codex").join("hooks.json");
        let content = std::fs::read_to_string(&hooks_json).unwrap();
        std::fs::write(&hooks_json, content.replace("guard.sh", "pre-guard.sh")).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            phantom_note(&report).contains("script present but not registered"),
            "{report:?}"
        );
    });
}

#[test]
fn a_disabled_codex_hooks_feature_is_drift() {
    with_sandbox("codex-feature-off", |project, source| {
        write_hook(source, "guard");
        install_codex_hook(source, "guard");
        let lock = codex_hook_lock(source, "guard");

        let config = project.join(".codex").join("config.toml");
        let content = std::fs::read_to_string(&config).unwrap();
        assert!(content.contains("hooks = true"), "control: {content}");
        std::fs::write(&config, content.replace("hooks = true", "hooks = false")).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.phantom), vec!["guard"], "{report:?}");
        assert!(
            phantom_note(&report).contains("hooks feature disabled"),
            "{report:?}"
        );

        // And a config file that never mentions the feature at all.
        std::fs::remove_file(&config).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            phantom_note(&report).contains("hooks feature disabled"),
            "{report:?}"
        );
    });
}
