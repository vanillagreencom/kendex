//! The third question every harness answers: given everything that can
//! switch it off, will it RUN what is fully installed? A registration claude
//! ignores, a codex feature flag that is not on, a cursor rule that is no
//! longer always applied — all whole installs, none of them running, and none
//! of them a reinstall away from working.

use super::hooks::{claude_hook_lock, codex_hook_lock, install_hook_for, notes, rewrite};
use super::*;

fn install_codex_hook(source: &Path, name: &str) {
    install_hook_for(source, name, crate::harness::Harness::Codex);
}

fn install_claude_hook(source: &Path, name: &str) {
    install_hook_for(source, name, crate::harness::Harness::ClaudeCode);
}

fn unverifiable_note(report: &ScopeReport) -> String {
    notes(&report.unverifiable)
}

fn disabled_note(report: &ScopeReport) -> String {
    notes(&report.disabled)
}

/// Set `disableAllHooks` on a settings file beside its real registration, so
/// the switch is exercised against the document the installer actually wrote
/// rather than a hand-built stub. `value` is spelled as JSON, because a type
/// claude would not honor is one of the states under test.
fn set_disable_all_hooks(path: &Path, registered: &str, value: &str) {
    let body = registered.trim_end().trim_end_matches('}').trim_end();
    let separator = if body.ends_with('{') { "" } else { "," };
    std::fs::write(
        path,
        format!("{body}{separator}\n  \"disableAllHooks\": {value}\n}}\n"),
    )
    .unwrap();
    let written = std::fs::read_to_string(path).unwrap();
    let doc: serde_json::Value = serde_json::from_str(&written)
        .unwrap_or_else(|err| panic!("the fixture must stay valid JSON: {err}\n{written}"));
    assert!(
        doc.get("disableAllHooks").is_some(),
        "the switch must land at the document root: {written}"
    );
}

/// `disableAllHooks` makes claude run NO hook — including
/// `session-drift-check`, the one that exists to report exactly this. The
/// registration is complete, so it is neither missing nor unreadable: it is
/// reported where the remedy is the setting, naming the file that holds it.
#[test]
fn claude_hooks_switched_off_are_reported_as_disabled_not_missing() {
    with_sandbox("claude-disable-all-hooks", |project, source| {
        write_hook(source, "guard");
        install_claude_hook(source, "guard");
        let lock = claude_hook_lock(source, "guard");
        let settings = project.join(".claude").join("settings.json");
        let registered = std::fs::read_to_string(&settings).unwrap();

        // Control: the key absent is clean.
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "control: {report:?}");

        let with_switch = |value: &str| set_disable_all_hooks(&settings, &registered, value);

        with_switch("true");
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.disabled), vec!["guard"], "{report:?}");
        assert!(report.phantom.is_empty(), "not a reinstall: {report:?}");
        assert!(report.unverifiable.is_empty(), "it parsed fine: {report:?}");
        let note = disabled_note(&report);
        assert!(note.contains("disableAllHooks is true"), "{note}");
        assert!(
            note.contains(&settings.display().to_string()),
            "the note names the file holding the switch: {note}"
        );
        assert!(report.has_drift(), "{report:?}");

        // Control: the same file with the key explicitly off is clean.
        with_switch("false");
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "control: {report:?}");

        // A value of a type claude would not honor is a deviation like every
        // other on vstack's read path: unreadable naming the file, never
        // waved through as "hooks are on".
        with_switch("\"true\"");
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.unverifiable), vec!["guard"], "{report:?}");
        assert!(report.disabled.is_empty(), "{report:?}");
        assert!(
            unverifiable_note(&report).contains(&settings.display().to_string()),
            "{report:?}"
        );
    });
}

/// The switch is ONE effective value over claude's precedence chain, not a
/// per-file flag: the highest-precedence file that states it decides, and what
/// it decides governs every scope's hooks, because claude runs none of them
/// either way.
#[test]
fn the_claude_hook_switch_follows_settings_precedence() {
    with_sandbox("claude-switch-precedence", |project, source| {
        write_hook(source, "guard");
        install_claude_hook(source, "guard");
        let hook = crate::hook::Hook::from_file(&source.join("hooks").join("guard.sh")).unwrap();
        crate::installer::install_hook(&hook, crate::harness::Harness::ClaudeCode, true, &[])
            .unwrap();
        let lock = claude_hook_lock(source, "guard");
        let user = config::claude_global_dir().join("settings.json");
        let user_registered = std::fs::read_to_string(&user).unwrap();
        let project_claude = project.join(".claude");

        // Control: both scopes clean before anything is switched off.
        for global in [false, true] {
            let report = check_scope(global, &lock, CheckOptions::default()).unwrap();
            assert!(!report.has_drift(), "control (global={global}): {report:?}");
        }

        // A user-level `true` stops the project's hooks too — the project
        // scope reading only its own files would call them clean while claude
        // runs none of them.
        set_disable_all_hooks(&user, &user_registered, "true");
        for global in [false, true] {
            let report = check_scope(global, &lock, CheckOptions::default()).unwrap();
            assert_eq!(
                names(&report.disabled),
                vec!["guard"],
                "global={global}: {report:?}"
            );
        }

        // …and a higher-precedence `false` overrides it, exactly as claude
        // resolves the value.
        std::fs::write(
            project_claude.join("settings.local.json"),
            "{\n  \"disableAllHooks\": false\n}\n",
        )
        .unwrap();
        for global in [false, true] {
            let report = check_scope(global, &lock, CheckOptions::default()).unwrap();
            assert!(!report.has_drift(), "global={global}: {report:?}");
        }
    });
}

/// Codex's `[features] hooks` is a switch, not a missing artifact: the script
/// and the registration are both there and codex runs neither. It is drift,
/// and it is reported where the remedy is the setting — never as a phantom
/// whose printed remedy is a reinstall of files that are already correct.
#[test]
fn a_disabled_codex_hooks_feature_is_drift() {
    with_sandbox("codex-feature-off", |project, source| {
        write_hook(source, "guard");
        install_codex_hook(source, "guard");
        let lock = codex_hook_lock(source, "guard");

        let config = project.join(".codex").join("config.toml");
        let content = std::fs::read_to_string(&config).unwrap();
        assert!(content.contains("hooks = true"), "control: {content}");
        // Control: with the feature on, the same install is clean.
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "control: {report:?}");

        std::fs::write(&config, content.replace("hooks = true", "hooks = false")).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.disabled), vec!["guard"], "{report:?}");
        assert!(report.phantom.is_empty(), "not a reinstall: {report:?}");
        let note = disabled_note(&report);
        assert!(note.contains("switched off"), "{note}");
        assert!(
            note.contains(&config.display().to_string()),
            "the note names the file holding the switch: {note}"
        );
        assert!(report.has_drift(), "{report:?}");

        // And a config file that never mentions the feature at all.
        std::fs::remove_file(&config).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.disabled), vec!["guard"], "{report:?}");
        assert!(
            disabled_note(&report).contains("switched off"),
            "{report:?}"
        );
    });
}

fn cursor_hook_lock(source: &Path, name: &str) -> LockFile {
    let mut entry = locked(source, ItemKind::Hook, name);
    entry.harnesses = vec!["cursor".into()];
    let mut lock = LockFile::default();
    lock.add(entry);
    lock
}

/// Cursor decides a rule's reach from the rule's own `alwaysApply`, so the
/// file existing was never the whole answer: with it off, cursor attaches the
/// rule when it judges the description relevant — which for a safety rule is
/// "might", not "will".
#[test]
fn a_cursor_rule_that_is_not_always_applied_is_disabled_not_installed() {
    with_sandbox("cursor-always-apply", |_project, source| {
        write_hook(source, "guard");
        install_hook_for(source, "guard", crate::harness::Harness::Cursor);
        let lock = cursor_hook_lock(source, "guard");
        let rule = crate::installer::cursor_hook_rule_path(false, "guard");

        // Control: what the installer writes is always applied.
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "control: {report:?}");
        let written = std::fs::read_to_string(&rule).unwrap();
        assert!(written.contains("alwaysApply: true"), "{written}");

        rewrite(&rule, &written, "alwaysApply: true", "alwaysApply: false");
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.disabled), vec!["guard"], "{report:?}");
        assert!(report.phantom.is_empty(), "the file is there: {report:?}");
        let note = disabled_note(&report);
        assert!(note.contains("alwaysApply is not true"), "{note}");
        assert!(
            note.contains(&rule.display().to_string()),
            "the note names the rule: {note}"
        );

        // A rule stripped of its frontmatter declares nothing, which is the
        // same "cursor does not always apply this" — not an unreadable file.
        std::fs::write(&rule, "# Safety: guard\n\nprose\n").unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.disabled), vec!["guard"], "{report:?}");
        assert!(report.unverifiable.is_empty(), "{report:?}");

        // Control: the rule gone is still the missing case, whose remedy is
        // the reinstall this section deliberately does not prescribe.
        std::fs::remove_file(&rule).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.phantom), vec!["guard"], "{report:?}");
        assert!(report.disabled.is_empty(), "{report:?}");
    });
}
