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
