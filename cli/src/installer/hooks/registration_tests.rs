//! Registration matching: which recorded command counts as "the harness will
//! RUN our script". A false clean here is invisible — the hook silently never
//! fires — so every case that cannot be proven to execute the script must
//! read as drift.

use super::codex::CodexNativeGap;
use super::tests::tmpdir;
use super::*;

/// A global codex scope carrying `hooks/foo.sh` (plus a same-named decoy
/// `hooks/pre-foo.sh`), the hooks feature on, and one `PreToolUse` handler
/// running `command`. Returns the scope dir and the gaps reported for `foo`.
fn codex_gaps_for_registered_command(
    label: &str,
    command: impl FnOnce(&Path) -> String,
) -> (PathBuf, Vec<CodexNativeGap>) {
    let dir = tmpdir(label);
    let hooks_dir = dir.join("hooks");
    std::fs::create_dir_all(&hooks_dir).unwrap();
    std::fs::write(hooks_dir.join("foo.sh"), "#!/usr/bin/env bash\n").unwrap();
    std::fs::write(hooks_dir.join("pre-foo.sh"), "#!/usr/bin/env bash\n").unwrap();
    std::fs::write(dir.join("config.toml"), "[features]\nhooks = true\n").unwrap();
    let doc = serde_json::json!({
        "hooks": {
            "PreToolUse": [{
                "matcher": "Bash",
                "hooks": [{"type": "command", "command": command(&dir)}]
            }]
        }
    });
    std::fs::write(
        dir.join("hooks.json"),
        serde_json::to_string_pretty(&doc).unwrap(),
    )
    .unwrap();

    let gaps = crate::test_util::with_codex_home(&dir, || {
        codex_native_hook_gaps(
            true,
            "foo",
            RegistrationSlot {
                event: "PreToolUse",
                matcher: Some("Bash"),
            },
        )
    });
    (dir, gaps)
}

/// Every case runs against the real presence path, so what the check accepts
/// and what codex would execute stay one answer.
fn assert_registration(label: &str, registered: bool, command: impl FnOnce(&Path) -> String) {
    let (dir, gaps) = codex_gaps_for_registered_command(label, command);
    assert_eq!(
        !gaps.contains(&CodexNativeGap::NotRegistered),
        registered,
        "{label}: expected registered={registered}, got {gaps:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

fn managed_script(dir: &Path) -> PathBuf {
    dir.join("hooks").join("foo.sh")
}

#[test]
fn codex_registration_requires_the_managed_script_path() {
    // Control: exactly what vstack renders.
    assert_registration("codex_reg_owned", true, |dir| {
        format!("bash {}", managed_script(dir).display())
    });

    // A command reshaped by hand around OUR script still counts.
    assert_registration("codex_reg_reshaped", true, |dir| {
        format!(
            "env VSTACK=1 bash \"{}\" --verbose",
            managed_script(dir).display()
        )
    });

    // Somebody else's same-named script must not answer for ours.
    assert_registration("codex_reg_foreign", false, |_| {
        "bash /somewhere/else/foo.sh".to_string()
    });

    // Existing control: a differently named neighbour never answers.
    assert_registration("codex_reg_prefixed", false, |dir| {
        format!("bash {}", dir.join("hooks").join("pre-foo.sh").display())
    });
}

/// The path has to sit where the shell would EXECUTE it. A corrupted handler
/// that merely passes our path to some other program never runs the hook, and
/// reading that as a registration is the fail-open this check exists to close.
#[test]
fn codex_registration_requires_an_executable_position() {
    // The path as another program's argument is data, not a registration.
    assert_registration("codex_pos_echo", false, |dir| {
        format!("echo {}", managed_script(dir).display())
    });
    assert_registration("codex_pos_cat", false, |dir| {
        format!("cat \"{}\" >/dev/null", managed_script(dir).display())
    });
    // Our script named as an ARGUMENT of a shell running something else.
    assert_registration("codex_pos_other_script", false, |dir| {
        format!(
            "bash {} {}",
            dir.join("hooks").join("pre-foo.sh").display(),
            managed_script(dir).display()
        )
    });
    // `-c` makes the operand a command string and `-s` reads the script from
    // stdin: neither proves our script runs.
    assert_registration("codex_pos_dash_c", false, |dir| {
        format!("bash -c '{}'", managed_script(dir).display())
    });
    assert_registration("codex_pos_dash_s", false, |dir| {
        format!("bash -s {}", managed_script(dir).display())
    });

    // Forms that really exec the script stay registered.
    assert_registration("codex_pos_bare", true, |dir| {
        format!("{} --strict", managed_script(dir).display())
    });
    assert_registration("codex_pos_env_prefix", true, |dir| {
        format!("env -i FOO=1 sh -e -- {}", managed_script(dir).display())
    });
    assert_registration("codex_pos_assignment", true, |dir| {
        format!("VSTACK=1 /bin/bash -x {}", managed_script(dir).display())
    });
    assert_registration("codex_pos_timeout", true, |dir| {
        format!("timeout 30 bash \"{}\"", managed_script(dir).display())
    });
    assert_registration("codex_pos_nohup", true, |dir| {
        format!("nohup {}", managed_script(dir).display())
    });
}

/// A global codex scope carrying `hooks/foo.sh` and the hooks feature on, with
/// `entry` registered under `SessionStart`. Returns the scope dir and the gaps
/// reported for `foo` in the slot `slot_matcher` names.
fn codex_gaps_for_entry(
    label: &str,
    entry: impl FnOnce(&Path) -> serde_json::Value,
    slot_matcher: Option<&str>,
) -> (PathBuf, Vec<CodexNativeGap>) {
    let dir = tmpdir(label);
    let hooks_dir = dir.join("hooks");
    std::fs::create_dir_all(&hooks_dir).unwrap();
    std::fs::write(hooks_dir.join("foo.sh"), "#!/usr/bin/env bash\n").unwrap();
    std::fs::write(dir.join("config.toml"), "[features]\nhooks = true\n").unwrap();
    let doc = serde_json::json!({ "hooks": { "SessionStart": [entry(&dir)] } });
    std::fs::write(
        dir.join("hooks.json"),
        serde_json::to_string_pretty(&doc).unwrap(),
    )
    .unwrap();

    let gaps = crate::test_util::with_codex_home(&dir, || {
        codex_native_hook_gaps(
            true,
            "foo",
            RegistrationSlot {
                event: "SessionStart",
                matcher: slot_matcher,
            },
        )
    });
    (dir, gaps)
}

/// `matcher` decides WHICH entry answers for a hook, so the schema has to hold
/// it to a string. Read as `Any`, a value neither harness can deserialize came
/// back as `None` — "no matcher" — which is precisely the shape a MATCHERLESS
/// hook's slot accepts, so `session-drift-check` read as registered while codex
/// dropped the whole `hooks.json` and never ran it.
///
/// The controls beside it are the other half of the rule: the shapes vstack
/// only PRESERVES have to keep reading, or the fix has traded a fail-open for
/// a config nobody can install into.
#[test]
fn a_matcher_the_harness_cannot_read_is_unverifiable_not_registered() {
    let handler = |dir: &Path| {
        serde_json::json!([{
            "type": "command",
            "command": format!("bash {}", dir.join("hooks").join("foo.sh").display()),
        }])
    };

    // Control: an absent matcher is a matcherless registration, as today.
    let (dir, gaps) = codex_gaps_for_entry(
        "codex_matcher_absent",
        |d| serde_json::json!({ "hooks": handler(d) }),
        None,
    );
    assert!(gaps.is_empty(), "an absent matcher registers: {gaps:?}");
    let _ = std::fs::remove_dir_all(&dir);

    // Control: a string matcher answers for the slot carrying it, as today.
    let (dir, gaps) = codex_gaps_for_entry(
        "codex_matcher_string",
        |d| serde_json::json!({ "matcher": "Bash", "hooks": handler(d) }),
        Some("Bash"),
    );
    assert!(gaps.is_empty(), "a string matcher registers: {gaps:?}");
    let _ = std::fs::remove_dir_all(&dir);

    // Control: fields vstack only preserves stay accepted at any type — the
    // `Any` declarations in `json_config` are still doing their job.
    let (dir, gaps) = codex_gaps_for_entry(
        "codex_matcher_foreign_fields",
        |d| serde_json::json!({ "hooks": handler(d), "notes": 42, "when": {"any": ["shape"]} }),
        None,
    );
    assert!(
        gaps.is_empty(),
        "a field vstack never interprets is preserved, not refused: {gaps:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);

    // The fail-open: a matcher that is not a string is not "no matcher".
    let (dir, gaps) = codex_gaps_for_entry(
        "codex_matcher_number",
        |d| serde_json::json!({ "matcher": 42, "hooks": handler(d) }),
        None,
    );
    let note = gaps
        .iter()
        .find(|gap| gap.is_unreadable())
        .unwrap_or_else(|| panic!("a non-string matcher must be unverifiable: {gaps:?}"))
        .describe();
    assert!(
        note.contains("hooks.json"),
        "the report names the file: {note}"
    );
    assert!(
        note.contains("hooks.SessionStart[0].matcher"),
        "…and the field: {note}"
    );
    assert!(
        note.contains("expected a string"),
        "…and what it had to be: {note}"
    );
    assert!(
        !gaps.contains(&CodexNativeGap::NotRegistered),
        "unverifiable is its own answer, not a plain absence: {gaps:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// The registration a claude project install writes, read back from a project
/// whose path carries shell syntax. `$CLAUDE_PROJECT_DIR` is expanded by the
/// harness at run time, where a quoted expansion's result is text — so a
/// checkout under `…/$weird`root` runs its hooks fine, and reporting it
/// unregistered was drift with no user action that could clear it: reinstalling
/// wrote the identical registration back.
#[test]
fn claude_registration_holds_when_the_project_path_looks_like_shell_syntax() {
    let dir = tmpdir("claude_reg_$weird`root");
    let hook = super::tests::hook_fixture("guard", "PreToolUse", Some("Bash"));
    let slot = RegistrationSlot {
        event: "PreToolUse",
        matcher: Some("Bash"),
    };
    let settings_path = dir.join(".claude").join("settings.json");

    let registration = |command: Option<&str>| {
        crate::test_util::with_project_root(&dir, || {
            if let Some(command) = command {
                let body = std::fs::read_to_string(&settings_path).unwrap();
                let mut doc: serde_json::Value = serde_json::from_str(&body).unwrap();
                *doc.pointer_mut("/hooks/PreToolUse/0/hooks/0/command")
                    .expect("the install wrote one PreToolUse handler") =
                    serde_json::Value::String(command.to_string());
                std::fs::write(&settings_path, serde_json::to_string_pretty(&doc).unwrap())
                    .unwrap();
            }
            claude_hook_registration(false, "guard", Some(slot))
        })
    };

    crate::test_util::with_project_root(&dir, || install_hook_claude(&hook, false).unwrap());
    // Control: the command vstack itself wrote round-trips.
    assert_eq!(registration(None), HookRegistration::Registered);
    // The same registration reshaped by hand — the shape no exact-command
    // match answers for, so only reading the command settles it.
    assert_eq!(
        registration(Some(
            "timeout 30 bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\" --strict"
        )),
        HookRegistration::Registered
    );
    // Control: a neighbour script under the same root is not this hook.
    assert_eq!(
        registration(Some("bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/other.sh\"")),
        HookRegistration::Absent
    );
    // Control: a command nothing can parse stays unregistered.
    assert_eq!(
        registration(Some("bash \"$SOMEWHERE/.claude/hooks/guard.sh\" | tee log")),
        HookRegistration::Absent
    );

    let _ = std::fs::remove_dir_all(&dir);
}
