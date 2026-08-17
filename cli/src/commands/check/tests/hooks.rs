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
    notes(&report.phantom)
}

fn unverifiable_note(report: &ScopeReport) -> String {
    notes(&report.unverifiable)
}

fn notes(items: &[Item]) -> String {
    items
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

/// Codex's `hooks.json` and `config.toml` answer the same question and get the
/// same treatment: unparseable is unverifiable, and no install rewrites one.
#[test]
fn an_unparseable_codex_config_is_unverifiable_and_never_rewritten() {
    with_sandbox("codex-config-unparseable", |project, source| {
        write_hook(source, "guard");
        install_codex_hook(source, "guard");
        let lock = codex_hook_lock(source, "guard");
        let hooks_json = project.join(".codex").join("hooks.json");
        let config = project.join(".codex").join("config.toml");

        // Control: the full native install is clean.
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "control: {report:?}");

        for (path, malformed, failure) in [
            (&hooks_json, "{\n  \"hooks\": {\n", "not valid JSON"),
            (&config, "[features\nhooks = true\n", "not valid TOML"),
        ] {
            let original = std::fs::read_to_string(path).unwrap();
            std::fs::write(path, malformed).unwrap();
            let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
            assert!(
                report.phantom.is_empty(),
                "{}: not a missing hook: {report:?}",
                path.display()
            );
            assert_eq!(names(&report.unverifiable), vec!["guard"], "{report:?}");
            let note = unverifiable_note(&report);
            assert!(
                note.contains(&path.display().to_string()) && note.contains(failure),
                "the note names the file and the failure: {note}"
            );

            let hook =
                crate::hook::Hook::from_file(&source.join("hooks").join("guard.sh")).unwrap();
            let err =
                crate::installer::install_hook(&hook, crate::harness::Harness::Codex, false, &[])
                    .expect_err("install must refuse a codex config it cannot parse");
            assert!(
                format!("{err:#}").contains(&path.display().to_string()),
                "the refusal names the file: {err:#}"
            );
            assert_eq!(
                std::fs::read_to_string(path).unwrap(),
                malformed,
                "{} must be byte-identical after a refusal",
                path.display()
            );
            std::fs::write(path, original).unwrap();
        }

        // Control: with both files restored the scope is clean again.
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "control: {report:?}");
    });
}

/// The prose fallback counts only while it still carries its action line.
/// A `## Safety:` heading whose body was deleted is a hook codex no longer
/// carries, and reporting it installed left it permanently ineffective.
#[test]
fn a_codex_prose_section_without_its_action_line_is_drift() {
    with_sandbox("codex-prose-body", |project, source| {
        write_hook_for_event(source, "guard", "TaskCompleted");
        let toml = project.join(".codex").join("agents").join("rust.toml");
        std::fs::create_dir_all(toml.parent().unwrap()).unwrap();
        std::fs::write(
            &toml,
            "name = \"rust\"\ndeveloper_instructions = '''\nBody\n'''\n",
        )
        .unwrap();
        let hook = crate::hook::Hook::from_file(&source.join("hooks").join("guard.sh")).unwrap();
        let agents = [crate::agent::Agent {
            name: "rust".into(),
            description: "rust".into(),
            model: "sonnet".into(),
            role: crate::agent::AgentRole::Engineer,
            color: None,
            effort: None,
            body: "Body\n".into(),
            source_path: PathBuf::new(),
        }];
        crate::installer::install_hook(&hook, crate::harness::Harness::Codex, false, &agents)
            .unwrap();
        let lock = codex_hook_lock(source, "guard");

        // Control: the installed block is clean.
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "control: {report:?}");

        // The heading survives; its body does not.
        let installed = std::fs::read_to_string(&toml).unwrap();
        let action_line = crate::config::generated_safety_action_line(&hook).unwrap();
        let gutted = installed.replace(&format!("\n{action_line}"), "");
        assert_ne!(gutted, installed, "the fixture must gut the body");
        std::fs::write(&toml, &gutted).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.phantom), vec!["guard"], "{report:?}");
        assert!(
            phantom_note(&report).contains("no script and no prose"),
            "{report:?}"
        );

        // Control: no section at all reports the same way.
        std::fs::write(
            &toml,
            "name = \"rust\"\ndeveloper_instructions = '''\nBody\n'''\n",
        )
        .unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.phantom), vec!["guard"], "{report:?}");

        // …and a reinstall repairs the gutted section rather than skipping it.
        std::fs::write(&toml, &gutted).unwrap();
        crate::installer::install_hook(&hook, crate::harness::Harness::Codex, false, &agents)
            .unwrap();
        assert_eq!(
            std::fs::read_to_string(&toml).unwrap(),
            installed,
            "the repair restores the whole block"
        );
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "{report:?}");
    });
}

/// The prose fallback's third answer. An agent file the read could not open
/// says nothing about whether the block is there — reported as a missing
/// block it prescribed a reinstall, which opens the same file and fails, so
/// the drift could not be cleared by the command that was printed for it.
#[test]
fn a_codex_agent_file_that_cannot_be_read_is_unverifiable_not_missing_prose() {
    with_sandbox("codex-prose-unreadable", |project, source| {
        write_hook_for_event(source, "guard", "TaskCompleted");
        let agents_dir = project.join(".codex").join("agents");
        std::fs::create_dir_all(&agents_dir).unwrap();
        let toml = agents_dir.join("rust.toml");
        let other = agents_dir.join("scout.toml");
        let blank = "name = \"a\"\ndeveloper_instructions = '''\nBody\n'''\n";
        std::fs::write(&toml, blank).unwrap();
        std::fs::write(&other, blank).unwrap();
        let hook = crate::hook::Hook::from_file(&source.join("hooks").join("guard.sh")).unwrap();
        let agent = |name: &str| crate::agent::Agent {
            name: name.into(),
            description: name.into(),
            model: "sonnet".into(),
            role: crate::agent::AgentRole::Engineer,
            color: None,
            effort: None,
            body: "Body\n".into(),
            source_path: PathBuf::new(),
        };
        let agents = [agent("rust"), agent("scout")];
        crate::installer::install_hook(&hook, crate::harness::Harness::Codex, false, &agents)
            .unwrap();
        let lock = codex_hook_lock(source, "guard");

        // Control: both agents carry the block, so the scope is clean.
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(!report.has_drift(), "control: {report:?}");

        // Control: one unreadable agent beside one that carries the block is
        // still clean — a block that IS there answers for the scope.
        std::fs::write(&toml, [b'n', b'a', 0xff, b'm', b'e']).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            !report.has_drift(),
            "an agent that carries it answers for the scope: {report:?}"
        );

        // With no readable agent carrying it, the answer is unknowable — not
        // a missing block.
        std::fs::write(&other, blank).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            report.phantom.is_empty(),
            "a file nothing could read is not missing prose: {report:?}"
        );
        assert_eq!(names(&report.unverifiable), vec!["guard"], "{report:?}");
        let note = unverifiable_note(&report);
        assert!(
            note.contains(&toml.display().to_string()),
            "the note names the file to repair: {note}"
        );

        // Control: readable agents that simply lack the block are the
        // missing-prose report the remedy really fits.
        std::fs::write(&toml, blank).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.unverifiable.is_empty(), "control: {report:?}");
        assert!(
            phantom_note(&report).contains("no script and no prose"),
            "control: {report:?}"
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

fn opencode_hook_lock(source: &Path, name: &str) -> LockFile {
    let mut entry = locked(source, ItemKind::Hook, name);
    entry.harnesses = vec!["opencode".into()];
    let mut lock = LockFile::default();
    lock.add(entry);
    lock
}

/// OpenCode loads the instruction files its `opencode.json` names. The file
/// alone is prose no agent ever sees, so presence has to demand the entry too
/// — the same two-artifact question the Claude and Codex checks ask, on the
/// one harness that was still answering it from the file alone.
#[test]
fn an_opencode_hook_needs_its_instruction_entry_not_just_its_file() {
    with_sandbox("opencode-registration", |project, source| {
        write_hook(source, "guard");
        install_hook_for(source, "guard", crate::harness::Harness::OpenCode);
        let lock = opencode_hook_lock(source, "guard");

        // Control: the full install is clean.
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(report.phantom.is_empty(), "control: {report:?}");

        let config_path = project.join("opencode.json");
        let installed = std::fs::read_to_string(&config_path).unwrap();
        assert!(
            installed.contains("vstack-hook-guard.md"),
            "installer must reference the instruction file: {installed}"
        );

        // Control: a differently spelled path to the same file still counts.
        std::fs::write(
            &config_path,
            installed.replace(
                ".opencode/instructions/vstack-hook-guard.md",
                "./.opencode/./instructions/vstack-hook-guard.md",
            ),
        )
        .unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            report.phantom.is_empty(),
            "an equivalent path is the same registration: {report:?}"
        );

        // The file survives, the reference does not — opencode will never
        // load this hook, so it is drift.
        std::fs::write(
            &config_path,
            installed.replace(
                ".opencode/instructions/vstack-hook-guard.md",
                ".opencode/instructions/somebody-elses.md",
            ),
        )
        .unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.phantom), vec!["guard"], "{report:?}");
        assert!(
            phantom_note(&report).contains("instruction present but not referenced"),
            "{report:?}"
        );
        assert!(report.has_drift());

        // A config nothing can parse is not a missing registration: nothing
        // can say, and reinstalling repairs no unparseable file.
        std::fs::write(&config_path, "{\"instructions\": [\n").unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.unverifiable), vec!["guard"], "{report:?}");
        assert!(
            unverifiable_note(&report).contains("registration unverifiable"),
            "{report:?}"
        );
    });
}
