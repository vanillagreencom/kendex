//! Codex hook presence. Codex runs what `hooks.json` registers while
//! `[features] hooks` is on, and carries the events it has no equivalent for
//! as prose inside its agent TOMLs — so each half is its own artifact to
//! demand, and each config its own file to name when it cannot be read.

use super::super::*;
use super::{codex_hook_lock, install_codex_hook, phantom_note, unverifiable_note};

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

/// Codex's half of the same ordering: a missing script prescribes `vstack
/// add`, and that command refuses both `hooks.json` and `config.toml` when it
/// cannot parse them. Reading them only when the script was there hid the
/// repair the reinstall waits on.
#[test]
fn a_missing_codex_script_beside_an_unparseable_config_names_the_file_first() {
    with_sandbox("codex-missing-script-and-config", |project, source| {
        write_hook(source, "guard");
        install_codex_hook(source, "guard");
        let lock = codex_hook_lock(source, "guard");
        let codex = project.join(".codex");
        let script = codex.join("hooks").join("guard.sh");
        let hook = crate::hook::Hook::from_file(&source.join("hooks").join("guard.sh")).unwrap();

        // Control: a missing script beside READABLE config files is the
        // missing-install report and nothing else — the registration that
        // survives it says nothing the one `vstack add` would not repair.
        std::fs::remove_file(&script).unwrap();
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert_eq!(names(&report.phantom), vec!["guard"], "control: {report:?}");
        assert!(report.unverifiable.is_empty(), "control: {report:?}");
        assert_eq!(
            phantom_note(&report),
            "codex: script missing",
            "control: the surviving registration is not a second line: {report:?}"
        );

        for (path, malformed, failure) in [
            (
                codex.join("hooks.json"),
                "{\n  \"hooks\": {\n",
                "not valid JSON",
            ),
            (
                codex.join("config.toml"),
                "[features\nhooks = true\n",
                "not valid TOML",
            ),
        ] {
            let original = std::fs::read_to_string(&path).unwrap();
            std::fs::write(&path, malformed).unwrap();
            // The refused install below writes the script before it reaches
            // the file it refuses, so each case starts from a scope that has
            // lost it again.
            let _ = std::fs::remove_file(&script);
            let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
            assert!(
                report.phantom.is_empty(),
                "{}: the blocked remedy must not be the headline: {report:?}",
                path.display()
            );
            assert_eq!(names(&report.unverifiable), vec!["guard"], "{report:?}");
            let note = unverifiable_note(&report);
            assert!(
                note.contains(&path.display().to_string()) && note.contains(failure),
                "the note names the file to repair and the failure: {note}"
            );
            assert!(
                note.contains("script missing"),
                "…and the second fault: {note}"
            );

            // The remedy the missing script alone would have prescribed.
            let err =
                crate::installer::install_hook(&hook, crate::harness::Harness::Codex, false, &[])
                    .expect_err("install must refuse a codex config it cannot parse");
            assert!(
                format!("{err:#}").contains(&path.display().to_string()),
                "the refusal names the file: {err:#}"
            );
            assert_eq!(
                std::fs::read_to_string(&path).unwrap(),
                malformed,
                "{} must be byte-identical after a refusal",
                path.display()
            );
            std::fs::write(&path, original).unwrap();
        }

        // Control: with both files readable again the install completes and
        // the scope is clean.
        crate::installer::install_hook(&hook, crate::harness::Harness::Codex, false, &[]).unwrap();
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
