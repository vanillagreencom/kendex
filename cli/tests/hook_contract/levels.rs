//! What `vstack list` and `vstack check` REPORT about an installed hook: the
//! per-harness enforcement level, and every fact that downgrades it — a
//! deleted artifact, a registration under another slot, a carrier package
//! that is not there, a `harnesses:` allowlist that excludes the harness, and
//! a harness configured not to run what is fully installed.
//!
//! The execution contract itself — that a registered command fires, and what
//! each install writes — is the parent module's.

use super::*;

#[test]
fn list_and_check_label_every_harness_with_its_enforcement_level() {
    let sandbox = Sandbox::new("level-labels");
    assert_success(
        sandbox.add(&[
            "--hook",
            "probe",
            "--harness",
            "claude-code",
            "--harness",
            "cursor",
            "--copy",
            "-y",
        ]),
        "vstack add",
    );

    let list = sandbox
        .vstack()
        .args(["list", "--scope", "project"])
        .output()
        .unwrap();
    assert_success(list.clone(), "vstack list");
    let list_text = String::from_utf8_lossy(&list.stderr).to_string();
    assert!(
        list_text.contains("claude-code: enforced"),
        "list does not label Claude enforcement:\n{list_text}"
    );
    assert!(
        list_text.contains("cursor: advisory"),
        "list does not label Cursor as advisory:\n{list_text}"
    );

    let check = sandbox
        .vstack()
        .args(["check", "--scope", "project"])
        .output()
        .unwrap();
    let check_text = String::from_utf8_lossy(&check.stderr).to_string();
    assert!(
        check_text.contains("claude-code: enforced") && check_text.contains("cursor: advisory"),
        "check does not label enforcement per harness:\n{check_text}"
    );
}

/// The three commands that report on one hook cannot disagree about it. A
/// harness switch is the fact `list` used to skip: with `disableAllHooks` on,
/// or a rule edited to `alwaysApply: false`, `check` and `verify` called the
/// install disabled while `list` still called it enforced. Both outputs are
/// asserted here, against ONE note, so they cannot drift apart again.
#[test]
fn list_and_check_agree_when_the_harness_switch_is_off() {
    let sandbox = Sandbox::new("switch-agreement");
    assert_success(
        sandbox.add(&[
            "--hook",
            "probe",
            "--harness",
            "claude-code",
            "--harness",
            "cursor",
            "--copy",
            "-y",
        ]),
        "vstack add",
    );
    let list_text = |sandbox: &Sandbox| {
        let output = sandbox
            .vstack()
            .args(["list", "--scope", "project"])
            .output()
            .unwrap();
        assert_success(output.clone(), "vstack list");
        String::from_utf8_lossy(&output.stderr).to_string()
    };
    let check_text = |sandbox: &Sandbox| {
        let output = sandbox
            .vstack()
            .args(["check", "--scope", "project"])
            .output()
            .unwrap();
        String::from_utf8_lossy(&output.stderr).to_string()
    };

    // Control: switches on, and every reader says so.
    let (before_list, before_check) = (list_text(&sandbox), check_text(&sandbox));
    for text in [&before_list, &before_check] {
        assert!(
            text.contains("claude-code: enforced") && text.contains("cursor: advisory"),
            "a fully enabled install does not read as enforced:\n{text}"
        );
    }

    // Claude's switch: one setting stops every hook it registers.
    let settings_path = sandbox.project.join(".claude/settings.json");
    let mut settings = read_json(&settings_path);
    settings
        .as_object_mut()
        .expect("settings object")
        .insert("disableAllHooks".into(), serde_json::Value::Bool(true));
    fs::write(
        &settings_path,
        serde_json::to_string_pretty(&settings).unwrap(),
    )
    .unwrap();
    let claude_note = format!("disableAllHooks is true in {}", settings_path.display());
    let (list_off, check_off) = (list_text(&sandbox), check_text(&sandbox));
    assert!(
        list_off.contains(&format!(
            "claude-code: unsupported (switched off — {claude_note})"
        )),
        "list still claims enforcement with claude's hooks disabled:\n{list_off}"
    );
    assert!(
        check_off.contains(&format!("claude-code: switched off — {claude_note}")),
        "check does not name the switch that stopped the hook:\n{check_off}"
    );
    assert!(
        !list_off.contains("claude-code: enforced") && !check_off.contains("claude-code: enforced"),
        "a disabled harness still reads as enforced:\n{list_off}\n{check_off}"
    );

    // Cursor's switch is the rule's own frontmatter, and reads the same way.
    settings
        .as_object_mut()
        .expect("settings object")
        .insert("disableAllHooks".into(), serde_json::Value::Bool(false));
    fs::write(
        &settings_path,
        serde_json::to_string_pretty(&settings).unwrap(),
    )
    .unwrap();
    let rule_path = sandbox.project.join(".cursor/rules/safety-probe.mdc");
    let rule = fs::read_to_string(&rule_path).unwrap();
    assert!(rule.contains("alwaysApply: true"), "{rule}");
    fs::write(
        &rule_path,
        rule.replace("alwaysApply: true", "alwaysApply: false"),
    )
    .unwrap();
    let cursor_note = format!("alwaysApply is not true in {}", rule_path.display());
    let (list_rule, check_rule) = (list_text(&sandbox), check_text(&sandbox));
    assert!(
        list_rule.contains(&format!(
            "cursor: unsupported (switched off — {cursor_note})"
        )),
        "list still calls a rule advisory that cursor never applies:\n{list_rule}"
    );
    assert!(
        check_rule.contains(&format!("cursor: switched off — {cursor_note}")),
        "check does not name the setting that stopped the rule:\n{check_rule}"
    );
    assert!(
        !list_rule.contains("cursor: advisory") && !check_rule.contains("cursor: advisory"),
        "a rule cursor will not apply still reads as advisory:\n{list_rule}\n{check_rule}"
    );
    // …and claude, switched back on, reads exactly as it did at the start.
    assert!(
        list_rule.contains("claude-code: enforced"),
        "restoring the switch did not restore the level:\n{list_rule}"
    );
}

#[test]
fn pi_reports_unsupported_until_its_carrier_package_is_installed() {
    let sandbox = Sandbox::new("pi-carrier");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "pi", "--copy", "-y"]),
        "vstack add",
    );
    let before = sandbox
        .vstack()
        .args(["list", "--scope", "project"])
        .output()
        .unwrap();
    let before_text = String::from_utf8_lossy(&before.stderr).to_string();
    assert!(
        before_text.contains("pi: unsupported (pi-hooks not installed)"),
        "Pi claimed enforcement without its carrier package:\n{before_text}"
    );

    // The carrier package is what actually runs hook behavior on Pi.
    let package = sandbox.source.join("pi-extensions/pi-hooks");
    fs::create_dir_all(package.join("extensions")).unwrap();
    fs::write(
        package.join("package.json"),
        r#"{"name":"@vanillagreen/pi-hooks","version":"1.0.0","description":"probe carrier","keywords":["pi-package"],"pi":{"extensions":["./extensions/hooks.js"]}}"#,
    )
    .unwrap();
    fs::write(package.join("extensions/hooks.js"), "export default {};\n").unwrap();
    assert_success(
        sandbox.add(&["--pi-extension", "pi-hooks", "--harness", "pi", "-y"]),
        "vstack add --pi-extension",
    );

    let after = sandbox
        .vstack()
        .args(["list", "--scope", "project"])
        .output()
        .unwrap();
    let after_text = String::from_utf8_lossy(&after.stderr).to_string();
    assert!(
        after_text.contains("pi: enforced"),
        "Pi did not report enforcement with its carrier package installed:\n{after_text}"
    );
}

#[test]
fn a_harness_dropped_from_the_allowlist_reports_as_excluded() {
    let sandbox = Sandbox::new("excluded-harness");
    assert_success(
        sandbox.add(&[
            "--hook",
            "probe",
            "--harness",
            "claude-code",
            "--harness",
            "cursor",
            "--copy",
            "-y",
        ]),
        "vstack add",
    );
    write_probe_hook(&sandbox.source, "probe", "PreToolUse");
    // Narrow the hook's allowlist without reinstalling: the lock still records
    // Cursor, and the label has to say the hook no longer applies there.
    let path = sandbox.source.join("hooks/probe.sh");
    let script = fs::read_to_string(&path).unwrap();
    fs::write(
        &path,
        script.replace("# safety:", "# harnesses: [claude-code]\n# safety:"),
    )
    .unwrap();

    let list = sandbox
        .vstack()
        .args(["list", "--scope", "project"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&list.stderr).to_string();
    assert!(
        text.contains("cursor: unsupported (excluded by harnesses:)"),
        "an excluded harness still reads as installed:\n{text}"
    );
}

#[test]
fn a_deregistered_hook_stops_reading_as_enforced() {
    let sandbox = Sandbox::new("deregistered-hook");
    assert_success(
        sandbox.add(&[
            "--hook",
            "probe",
            "--harness",
            "claude-code",
            "--copy",
            "-y",
        ]),
        "vstack add",
    );
    // The script survives but the settings.json handler is gone: nothing
    // invokes it, so it must not read as enforced.
    fs::write(sandbox.project.join(".claude/settings.json"), "{}\n").unwrap();
    let list = sandbox
        .vstack()
        .args(["list", "--scope", "project"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&list.stderr).to_string();
    assert!(
        text.contains("claude-code: unsupported (script present but not registered)"),
        "a hook with no settings.json registration still reads as enforced:\n{text}"
    );
}

#[test]
fn a_registration_with_a_stale_matcher_stops_reading_as_enforced() {
    let sandbox = Sandbox::new("stale-matcher");
    assert_success(
        sandbox.add(&[
            "--hook",
            "probe",
            "--harness",
            "claude-code",
            "--copy",
            "-y",
        ]),
        "vstack add",
    );
    // The registration fires for a different tool set than the definition
    // declares: what runs is not what the contract row claims.
    let settings_path = sandbox.project.join(".claude/settings.json");
    let settings = fs::read_to_string(&settings_path).unwrap();
    fs::write(
        &settings_path,
        settings.replace("\"matcher\": \"Bash\"", "\"matcher\": \"Edit\""),
    )
    .unwrap();
    let list = sandbox
        .vstack()
        .args(["list", "--scope", "project"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&list.stderr).to_string();
    assert!(
        text.contains("claude-code: unsupported (script present but not registered)"),
        "a registration with a different matcher still reads as enforced:\n{text}"
    );
}

#[cfg(unix)]
#[test]
fn a_broken_pi_package_symlink_stops_reading_as_enforced() {
    let sandbox = Sandbox::new("pi-broken-symlink");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "pi", "--copy", "-y"]),
        "vstack add",
    );
    let package = sandbox.source.join("pi-extensions/pi-hooks");
    fs::create_dir_all(package.join("extensions")).unwrap();
    fs::write(
        package.join("package.json"),
        r#"{"name":"@vanillagreen/pi-hooks","version":"1.0.0","description":"probe carrier","keywords":["pi-package"],"pi":{"extensions":["./extensions/hooks.js"]}}"#,
    )
    .unwrap();
    fs::write(package.join("extensions/hooks.js"), "export default {};\n").unwrap();
    assert_success(
        sandbox.add(&["--pi-extension", "pi-hooks", "--harness", "pi", "-y"]),
        "vstack add --pi-extension",
    );
    // The deployed directory becomes a symlink whose target is gone: Pi
    // cannot load it, and a link that dangles must not read as deployed.
    let deployed = sandbox.project.join(".pi/packages/@vanillagreen/pi-hooks");
    fs::remove_dir_all(&deployed).unwrap();
    std::os::unix::fs::symlink(sandbox.root.join("no-such-target"), &deployed).unwrap();
    let list = sandbox
        .vstack()
        .args(["list", "--scope", "project"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&list.stderr).to_string();
    assert!(
        text.contains("pi: unsupported (pi-hooks not installed)"),
        "a broken package symlink still reads as enforced:\n{text}"
    );
}

#[test]
fn a_globally_installed_pi_carrier_backs_a_project_hook() {
    let sandbox = Sandbox::new("pi-global-carrier");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "pi", "--copy", "-y"]),
        "vstack add",
    );
    let package = sandbox.source.join("pi-extensions/pi-hooks");
    fs::create_dir_all(package.join("extensions")).unwrap();
    fs::write(
        package.join("package.json"),
        r#"{"name":"@vanillagreen/pi-hooks","version":"1.0.0","description":"probe carrier","keywords":["pi-package"],"pi":{"extensions":["./extensions/hooks.js"]}}"#,
    )
    .unwrap();
    fs::write(package.join("extensions/hooks.js"), "export default {};\n").unwrap();
    // Pi loads packages from both scopes: a globally installed carrier
    // enforces for a project-scope hook too.
    assert_success(
        sandbox.add(&["--pi-extension", "pi-hooks", "--harness", "pi", "-g", "-y"]),
        "vstack add --pi-extension -g",
    );
    let list = sandbox
        .vstack()
        .args(["list", "--scope", "project"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&list.stderr).to_string();
    assert!(
        text.contains("pi: enforced"),
        "a globally loaded carrier does not back the project hook:\n{text}"
    );
}

#[test]
fn a_features_example_inside_a_string_does_not_enable_codex_hooks() {
    let sandbox = Sandbox::new("codex-feature-string-decoy");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "codex", "--copy", "-y"]),
        "vstack add",
    );
    // The real flag is off; a multiline string later carries the same lines
    // as inert text. Only the parsed table may decide.
    fs::write(
        sandbox.project.join(".codex/config.toml"),
        "[features]\nhooks = false\n\n[profile.example]\ndeveloper_instructions = \"\"\"\n[features]\nhooks = true\n\"\"\"\n",
    )
    .unwrap();
    let list = sandbox
        .vstack()
        .args(["list", "--scope", "project"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&list.stderr).to_string();
    assert!(
        text.contains("codex: unsupported (switched off — [features] hooks is not true in "),
        "a features example inside a string enabled the hooks claim:\n{text}"
    );
}

#[test]
fn a_registration_moved_to_another_event_stops_reading_as_enforced() {
    let sandbox = Sandbox::new("moved-event-registration");
    assert_success(
        sandbox.add(&[
            "--hook",
            "probe",
            "--harness",
            "claude-code",
            "--copy",
            "-y",
        ]),
        "vstack add",
    );
    // The command is still registered, but under a different event than the
    // hook declares: a PreToolUse guard that actually fires PostToolUse does
    // not enforce what the contract row claims.
    let settings_path = sandbox.project.join(".claude/settings.json");
    let mut settings = read_json(&settings_path);
    let hooks = settings
        .get_mut("hooks")
        .and_then(|h| h.as_object_mut())
        .expect("hooks object");
    let entry = hooks.remove("PreToolUse").expect("PreToolUse entry");
    hooks.insert("PostToolUse".into(), entry);
    fs::write(
        &settings_path,
        serde_json::to_string_pretty(&settings).unwrap(),
    )
    .unwrap();
    let list = sandbox
        .vstack()
        .args(["list", "--scope", "project"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&list.stderr).to_string();
    assert!(
        text.contains("claude-code: unsupported (script present but not registered)"),
        "a registration under the wrong event still reads as enforced:\n{text}"
    );
}

#[test]
fn an_unreferenced_opencode_instruction_stops_reading_as_advisory() {
    let sandbox = Sandbox::new("opencode-unreferenced");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "opencode", "--copy", "-y"]),
        "vstack add",
    );
    let instruction = sandbox
        .project
        .join(".opencode/instructions/vstack-hook-probe.md");
    assert!(instruction.is_file(), "instruction file was not installed");
    // The file survives but opencode.json no longer references it: OpenCode
    // loads nothing, so nothing is advisory.
    let config_path = sandbox.project.join("opencode.json");
    let mut config = read_json(&config_path);
    config
        .as_object_mut()
        .expect("config object")
        .remove("instructions");
    fs::write(&config_path, serde_json::to_string_pretty(&config).unwrap()).unwrap();
    let list = sandbox
        .vstack()
        .args(["list", "--scope", "project"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&list.stderr).to_string();
    assert!(
        text.contains("opencode: unsupported (instruction present but not referenced)"),
        "an instruction file opencode.json does not reference still reads as advisory:\n{text}"
    );
}

#[test]
fn a_disabled_codex_hooks_feature_stops_reading_as_enforced() {
    let sandbox = Sandbox::new("codex-feature-off");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "codex", "--copy", "-y"]),
        "vstack add",
    );
    let config_toml = sandbox.project.join(".codex/config.toml");
    let content = fs::read_to_string(&config_toml).unwrap();
    fs::write(
        &config_toml,
        content.replace("hooks = true", "hooks = false"),
    )
    .unwrap();
    let list = sandbox
        .vstack()
        .args(["list", "--scope", "project"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&list.stderr).to_string();
    assert!(
        text.contains("codex: unsupported (switched off — [features] hooks is not true in "),
        "a hook Codex will not execute (features.hooks off) still reads as enforced:\n{text}"
    );
}

#[test]
fn a_stale_pi_registration_without_the_package_stops_reading_as_enforced() {
    let sandbox = Sandbox::new("pi-stale-registration");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "pi", "--copy", "-y"]),
        "vstack add",
    );
    let package = sandbox.source.join("pi-extensions/pi-hooks");
    fs::create_dir_all(package.join("extensions")).unwrap();
    fs::write(
        package.join("package.json"),
        r#"{"name":"@vanillagreen/pi-hooks","version":"1.0.0","description":"probe carrier","keywords":["pi-package"],"pi":{"extensions":["./extensions/hooks.js"]}}"#,
    )
    .unwrap();
    fs::write(package.join("extensions/hooks.js"), "export default {};\n").unwrap();
    assert_success(
        sandbox.add(&["--pi-extension", "pi-hooks", "--harness", "pi", "-y"]),
        "vstack add --pi-extension",
    );
    // The deployed package is gone; only the settings registration remains.
    // Pi cannot load what is not there, so enforcement must not be claimed.
    fs::remove_dir_all(sandbox.project.join(".pi/packages/@vanillagreen/pi-hooks")).unwrap();
    let list = sandbox
        .vstack()
        .args(["list", "--scope", "project"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&list.stderr).to_string();
    assert!(
        text.contains("pi: unsupported (pi-hooks not installed)"),
        "a stale Pi registration without its package still reads as enforced:\n{text}"
    );
}

#[test]
fn a_codex_prose_fallback_without_prose_stops_reading_as_advisory() {
    let sandbox = Sandbox::new("codex-prose-absent");
    write_hook_with(&sandbox.source, "trailer", "TaskCompleted", "");
    assert_success(
        sandbox.add(&["--hook", "trailer", "--harness", "codex", "--copy", "-y"]),
        "vstack add",
    );
    // No agent file carries the safety block, so there is no artifact to be
    // advisory about.
    let list = sandbox
        .vstack()
        .args(["list", "--scope", "project"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&list.stderr).to_string();
    assert!(
        text.contains("codex: unsupported (no codex agent carries it)"),
        "a prose fallback with no prose still reads as advisory:\n{text}"
    );
}

#[test]
fn a_deleted_hook_script_stops_reading_as_enforced() {
    let sandbox = Sandbox::new("deleted-artifact");
    assert_success(
        sandbox.add(&[
            "--hook",
            "probe",
            "--harness",
            "claude-code",
            "--copy",
            "-y",
        ]),
        "vstack add",
    );
    fs::remove_file(sandbox.project.join(".claude/hooks/probe.sh")).unwrap();
    let list = sandbox
        .vstack()
        .args(["list", "--scope", "project"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&list.stderr).to_string();
    assert!(
        text.contains("claude-code: unsupported (script missing)"),
        "a hook whose script is gone still reads as enforced:\n{text}"
    );
}
