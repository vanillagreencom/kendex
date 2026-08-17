//! Hook execution contract: registered commands resolve and fire from any
//! working directory, in git and non-git projects, and advisory installs say
//! so in the artifact they write.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

fn unique_temp_dir(name: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_nanos();
    std::env::temp_dir().join(format!("vstack-{name}-{}-{nanos}", std::process::id()))
}

/// A hook whose only job is to prove it ran: it appends to the file named by
/// `VSTACK_PROBE_MARKER`, so a command string that never resolves leaves no
/// marker behind.
fn write_probe_hook(source: &Path, name: &str, event: &str) {
    fs::create_dir_all(source.join("hooks")).unwrap();
    fs::write(
        source.join("hooks").join(format!("{name}.sh")),
        format!(
            r#"#!/usr/bin/env bash
# ---
# name: {name}
# event: {event}
# matcher: Bash
# description: {name} probe
# safety: Keep the probe honest.
# ---

set -euo pipefail
cat > /dev/null
printf 'fired\n' >> "${{VSTACK_PROBE_MARKER}}"
exit 0
"#
        ),
    )
    .unwrap();
}

fn write_source(source: &Path) {
    fs::create_dir_all(source.join("agents")).unwrap();
    fs::create_dir_all(source.join("hooks")).unwrap();
    fs::write(
        source.join("vstack.toml"),
        "[hook-events]\n\"PreToolUse:Bash\" = \"all\"\n",
    )
    .unwrap();
    fs::write(
        source.join("agents/rust.md"),
        "---\nname: rust\ndescription: Rust agent\nmodel: sonnet\nrole: engineer\n---\n# Rust\n\nBody.\n",
    )
    .unwrap();
    write_probe_hook(source, "probe", "PreToolUse");
}

struct Sandbox {
    root: PathBuf,
    source: PathBuf,
    project: PathBuf,
    home: PathBuf,
    xdg: PathBuf,
    pi_dir: PathBuf,
}

impl Sandbox {
    fn new(name: &str) -> Self {
        let root = unique_temp_dir(name);
        let source = root.join("source");
        let project = root.join("project");
        let home = root.join("home");
        let xdg = root.join("xdg");
        let pi_dir = root.join("pi");
        for dir in [&source, &project, &home, &xdg, &pi_dir] {
            fs::create_dir_all(dir).unwrap();
        }
        // A nested directory the hook command is invoked from: a command that
        // resolves only relative to the session cwd fails here.
        fs::create_dir_all(project.join("nested/deeper")).unwrap();
        write_source(&source);
        Self {
            root,
            source,
            project,
            home,
            xdg,
            pi_dir,
        }
    }

    fn init_git(&self) {
        let output = Command::new("git")
            .arg("-C")
            .arg(&self.project)
            .arg("init")
            .output()
            .expect("git init");
        assert!(output.status.success(), "git init failed");
    }

    fn vstack(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_vstack"));
        command
            .current_dir(&self.project)
            .env("HOME", &self.home)
            .env("XDG_CONFIG_HOME", &self.xdg)
            .env("PI_CODING_AGENT_DIR", &self.pi_dir);
        command
    }

    fn add(&self, args: &[&str]) -> std::process::Output {
        self.vstack()
            .arg("add")
            .arg(&self.source)
            .args(args)
            .output()
            .unwrap()
    }

    /// Run a registered hook command exactly as the config carries it, from a
    /// nested working directory, and report whether the hook body ran.
    fn fire(&self, command: &str, extra_env: &[(&str, &Path)]) -> (bool, String) {
        let marker = self.root.join(format!(
            "marker-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut child = Command::new("bash");
        child
            .arg("-c")
            .arg(command)
            .current_dir(self.project.join("nested/deeper"))
            .env("HOME", &self.home)
            .env("XDG_CONFIG_HOME", &self.xdg)
            .env("VSTACK_PROBE_MARKER", &marker)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for (key, value) in extra_env {
            child.env(key, value);
        }
        let mut spawned = child.spawn().unwrap();
        use std::io::Write;
        spawned
            .stdin
            .as_mut()
            .unwrap()
            .write_all(br#"{"tool_input":{"command":"ls"}}"#)
            .unwrap();
        let output = spawned.wait_with_output().unwrap();
        let detail = format!(
            "command: {command}\nstatus: {}\nstdout:\n{}\nstderr:\n{}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        (output.status.success() && marker.exists(), detail)
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn assert_success(output: std::process::Output, context: &str) {
    assert!(
        output.status.success(),
        "{context} failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn read_json(path: &Path) -> serde_json::Value {
    let content = fs::read_to_string(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&content).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

fn registered_command(config: &serde_json::Value, event: &str) -> String {
    config
        .pointer(&format!("/hooks/{event}/0/hooks/0/command"))
        .and_then(|value| value.as_str())
        .unwrap_or_else(|| panic!("no registered command for {event} in {config}"))
        .to_string()
}

// --- Deliverable 2: anchors hold in git and non-git projects ---------------

#[test]
fn codex_project_hook_command_fires_in_a_non_git_project() {
    let sandbox = Sandbox::new("codex-anchor-nongit");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "codex", "--copy", "-y"]),
        "vstack add",
    );
    assert!(
        !sandbox.project.join(".git").exists(),
        "fixture project must not be a git repository"
    );
    let config = read_json(&sandbox.project.join(".codex/hooks.json"));
    let command = registered_command(&config, "PreToolUse");
    let (fired, detail) = sandbox.fire(&command, &[]);
    assert!(fired, "registered Codex command did not fire\n{detail}");
}

#[test]
fn codex_project_hook_command_fires_in_a_git_project() {
    let sandbox = Sandbox::new("codex-anchor-git");
    sandbox.init_git();
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "codex", "--copy", "-y"]),
        "vstack add",
    );
    let config = read_json(&sandbox.project.join(".codex/hooks.json"));
    let command = registered_command(&config, "PreToolUse");
    let (fired, detail) = sandbox.fire(&command, &[]);
    assert!(fired, "registered Codex command did not fire\n{detail}");
}

#[test]
fn codex_global_hook_command_fires() {
    let sandbox = Sandbox::new("codex-anchor-global");
    assert_success(
        sandbox.add(&[
            "--hook",
            "probe",
            "--harness",
            "codex",
            "--copy",
            "-g",
            "-y",
        ]),
        "vstack add -g",
    );
    let config = read_json(&sandbox.home.join(".codex/hooks.json"));
    let command = registered_command(&config, "PreToolUse");
    let (fired, detail) = sandbox.fire(&command, &[]);
    assert!(
        fired,
        "registered Codex global command did not fire\n{detail}"
    );
}

#[test]
fn a_codex_reinstall_replaces_a_git_anchored_registration() {
    let sandbox = Sandbox::new("codex-anchor-replace");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "codex", "--copy", "-y"]),
        "vstack add",
    );
    let hooks_json = sandbox.project.join(".codex/hooks.json");
    // The shape earlier installs registered. A reinstall owns it: it must be
    // replaced, not joined by a second handler for the same hook.
    fs::write(
        &hooks_json,
        serde_json::to_string_pretty(&serde_json::json!({
            "hooks": {
                "PreToolUse": [{
                    "matcher": "Bash",
                    "hooks": [{
                        "type": "command",
                        "command": "bash \"$(git rev-parse --show-toplevel)/.codex/hooks/probe.sh\""
                    }]
                }]
            }
        }))
        .unwrap(),
    )
    .unwrap();
    assert_success(
        sandbox
            .vstack()
            .args(["refresh", "--scope", "project"])
            .output()
            .unwrap(),
        "vstack refresh",
    );
    let config = read_json(&hooks_json);
    let handlers = config
        .pointer("/hooks/PreToolUse")
        .and_then(|value| value.as_array())
        .expect("PreToolUse array");
    assert_eq!(
        handlers.len(),
        1,
        "reinstall duplicated the registration: {config:#}"
    );
    let (fired, detail) = sandbox.fire(&registered_command(&config, "PreToolUse"), &[]);
    assert!(fired, "replaced Codex command did not fire\n{detail}");
}

#[test]
fn claude_project_hook_command_fires_in_a_non_git_project() {
    let sandbox = Sandbox::new("claude-anchor-nongit");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "claude", "--copy", "-y"]),
        "vstack add",
    );
    let settings = read_json(&sandbox.project.join(".claude/settings.json"));
    let command = registered_command(&settings, "PreToolUse");
    let project = sandbox.project.clone();
    let (fired, detail) = sandbox.fire(&command, &[("CLAUDE_PROJECT_DIR", &project)]);
    assert!(fired, "registered Claude command did not fire\n{detail}");
}

#[test]
fn claude_global_agent_frontmatter_command_fires() {
    let sandbox = Sandbox::new("claude-anchor-global-agent");
    assert_success(
        sandbox.add(&[
            "--agent",
            "rust",
            "--hook",
            "probe",
            "--harness",
            "claude",
            "--copy",
            "-g",
            "-y",
        ]),
        "vstack add -g",
    );
    let agent = fs::read_to_string(sandbox.home.join(".claude/agents/rust.md")).unwrap();
    let frontmatter = agent
        .strip_prefix("---\n")
        .and_then(|rest| rest.split_once("\n---\n"))
        .map(|(fm, _)| fm)
        .expect("agent frontmatter");
    let parsed: serde_json::Value =
        serde_yaml::from_str(frontmatter).expect("valid Claude YAML frontmatter");
    let command = parsed
        .pointer("/hooks/PreToolUse/0/hooks/0/command")
        .and_then(|value| value.as_str())
        .unwrap_or_else(|| panic!("no agent hook command:\n{agent}"))
        .to_string();
    // A global agent has no project layer to resolve against.
    let (fired, detail) = sandbox.fire(&command, &[]);
    assert!(
        fired,
        "global Claude agent hook command did not fire\n{detail}"
    );
}

// --- Deliverable 3: the level is stated, in the CLI and in the artifact ----

fn write_hook_with(source: &Path, name: &str, event: &str, extra_header: &str) {
    fs::create_dir_all(source.join("hooks")).unwrap();
    fs::write(
        source.join("hooks").join(format!("{name}.sh")),
        format!(
            r#"#!/usr/bin/env bash
# ---
# name: {name}
# event: {event}
# matcher: Bash
# description: {name} probe
{extra_header}# safety: Keep the probe honest.
# ---

exit 0
"#
        ),
    )
    .unwrap();
}

const BANNER: &str = "advisory — this harness cannot execute hooks";

#[test]
fn cursor_and_opencode_artifacts_open_with_the_advisory_banner() {
    let sandbox = Sandbox::new("advisory-banner");
    assert_success(
        sandbox.add(&[
            "--hook",
            "probe",
            "--harness",
            "cursor",
            "--harness",
            "opencode",
            "--copy",
            "-y",
        ]),
        "vstack add",
    );

    let rule = fs::read_to_string(sandbox.project.join(".cursor/rules/safety-probe.mdc")).unwrap();
    let body = rule
        .strip_prefix("---\n")
        .and_then(|rest| rest.split_once("\n---\n"))
        .map(|(_, body)| body.trim_start())
        .expect("cursor rule frontmatter");
    assert!(
        body.starts_with(BANNER),
        "cursor rule does not open with the advisory banner:\n{rule}"
    );

    let instruction = fs::read_to_string(
        sandbox
            .project
            .join(".opencode/instructions/vstack-hook-probe.md"),
    )
    .unwrap();
    assert!(
        instruction.starts_with(BANNER),
        "OpenCode instruction does not open with the advisory banner:\n{instruction}"
    );
}

#[test]
fn the_codex_prose_fallback_carries_the_advisory_banner() {
    let sandbox = Sandbox::new("advisory-banner-codex");
    write_hook_with(&sandbox.source, "finish", "TaskCompleted", "");
    assert_success(
        sandbox.add(&[
            "--agent",
            "rust",
            "--hook",
            "finish",
            "--harness",
            "codex",
            "--copy",
            "-y",
        ]),
        "vstack add",
    );
    let toml = fs::read_to_string(sandbox.project.join(".codex/agents/rust.toml")).unwrap();
    assert!(
        toml.contains("## Safety: finish"),
        "codex agent has no prose fallback:\n{toml}"
    );
    assert!(
        toml.contains(BANNER),
        "codex prose fallback is not labelled advisory:\n{toml}"
    );
    assert!(
        !sandbox.project.join(".codex/hooks/finish.sh").exists(),
        "TaskCompleted must not register as a native Codex hook"
    );
}

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

// --- The contract refuses what it cannot describe -------------------------

#[test]
fn an_event_outside_the_contract_is_refused_at_install() {
    let sandbox = Sandbox::new("uncovered-event");
    write_hook_with(&sandbox.source, "notify", "Notification", "");
    let output = sandbox.add(&["--hook", "notify", "--harness", "claude", "--copy", "-y"]);
    assert!(
        !output.status.success(),
        "install accepted an event the contract does not cover\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(
        stderr.contains("Notification") && stderr.contains("PreToolUse"),
        "refusal does not name the event and the supported set:\n{stderr}"
    );
    assert!(
        !sandbox.project.join(".claude/hooks/notify.sh").exists(),
        "refused hook was installed anyway"
    );
}

// --- Ownership survives a moved project; refusals leave nothing behind -----

#[test]
fn a_moved_project_does_not_accumulate_stale_codex_registrations() {
    let sandbox = Sandbox::new("codex-moved-project");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "codex", "--copy", "-y"]),
        "vstack add",
    );
    let hooks_json = sandbox.project.join(".codex/hooks.json");
    // The registration a previous location wrote. It names this hook's script
    // under this project's own `.codex/hooks/`, so it is vstack's to replace —
    // and it points at a path that no longer exists.
    fs::write(
        &hooks_json,
        serde_json::to_string_pretty(&serde_json::json!({
            "hooks": {
                "PreToolUse": [{
                    "matcher": "Bash",
                    "hooks": [{
                        "type": "command",
                        "command": "bash /somewhere/else/.codex/hooks/probe.sh"
                    }]
                }]
            }
        }))
        .unwrap(),
    )
    .unwrap();
    assert_success(
        sandbox
            .vstack()
            .args(["refresh", "--scope", "project"])
            .output()
            .unwrap(),
        "vstack refresh",
    );
    let config = read_json(&hooks_json);
    let handlers = config
        .pointer("/hooks/PreToolUse")
        .and_then(|value| value.as_array())
        .expect("PreToolUse array");
    assert_eq!(
        handlers.len(),
        1,
        "a registration from the project's old location survived: {config:#}"
    );
    let (fired, detail) = sandbox.fire(&registered_command(&config, "PreToolUse"), &[]);
    assert!(fired, "the surviving Codex command did not fire\n{detail}");
}

#[test]
fn a_user_authored_codex_handler_elsewhere_is_left_alone() {
    let sandbox = Sandbox::new("codex-foreign-handler");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "codex", "--copy", "-y"]),
        "vstack add",
    );
    let hooks_json = sandbox.project.join(".codex/hooks.json");
    let mut config = read_json(&hooks_json);
    config
        .pointer_mut("/hooks/PreToolUse")
        .and_then(|value| value.as_array_mut())
        .expect("PreToolUse array")
        .push(serde_json::json!({
            "matcher": "Bash",
            "hooks": [{"type": "command", "command": "bash /opt/mine/probe.sh"}]
        }));
    fs::write(&hooks_json, serde_json::to_string_pretty(&config).unwrap()).unwrap();
    assert_success(
        sandbox
            .vstack()
            .args(["refresh", "--scope", "project"])
            .output()
            .unwrap(),
        "vstack refresh",
    );
    let after = fs::read_to_string(&hooks_json).unwrap();
    assert!(
        after.contains("bash /opt/mine/probe.sh"),
        "a same-named handler outside .codex/hooks was pruned:\n{after}"
    );
}

#[test]
fn an_uncovered_event_is_refused_before_anything_is_written() {
    let sandbox = Sandbox::new("uncovered-event-atomic");
    write_hook_with(&sandbox.source, "notify", "Notification", "");
    let output = sandbox.add(&[
        "--agent",
        "rust",
        "--hook",
        "notify",
        "--harness",
        "claude",
        "--copy",
        "-y",
    ]);
    assert!(
        !output.status.success(),
        "install accepted an event the contract does not cover"
    );
    for leftover in [
        ".vstack-lock.json",
        ".claude/agents/rust.md",
        ".claude/settings.json",
        ".claude/hooks/notify.sh",
        "vstack.toml",
    ] {
        assert!(
            !sandbox.project.join(leftover).exists(),
            "refused install left {leftover} behind\nstderr:\n{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
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
        text.contains("claude-code: unsupported (artifact missing)"),
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
        text.contains("claude-code: unsupported (artifact missing)"),
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
fn a_reinstall_does_not_corrupt_feature_examples_inside_strings() {
    let sandbox = Sandbox::new("codex-feature-writer-decoy");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "codex", "--copy", "-y"]),
        "vstack add",
    );
    // A user config whose real flag is off and whose profile carries the same
    // lines as inert text: a reinstall may flip the real flag only.
    let config_toml = sandbox.project.join(".codex/config.toml");
    let embedded = "developer_instructions = \"\"\"\n[features]\nhooks = true\n\"\"\"";
    fs::write(
        &config_toml,
        format!("[features]\nhooks = false\n\n[profile.example]\n{embedded}\n"),
    )
    .unwrap();
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "codex", "--copy", "-y"]),
        "vstack add (reinstall)",
    );
    let after = fs::read_to_string(&config_toml).unwrap();
    assert!(
        after.contains(embedded),
        "the reinstall rewrote text inside a multiline string:\n{after}"
    );
    let doc: toml::Value = after.parse().expect("config.toml still parses");
    assert_eq!(
        doc.get("features")
            .and_then(|f| f.get("hooks"))
            .and_then(|v| v.as_bool()),
        Some(true),
        "the reinstall did not enable the real flag:\n{after}"
    );
}

#[test]
fn a_comment_showing_a_delimiter_does_not_derail_the_feature_writer() {
    let sandbox = Sandbox::new("codex-feature-comment-decoy");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "codex", "--copy", "-y"]),
        "vstack add",
    );
    // A comment documenting multiline syntax is inert text: the reinstall
    // must still see the real structure below it.
    let config_toml = sandbox.project.join(".codex/config.toml");
    fs::write(
        &config_toml,
        "# example: open a multiline value with \"\"\" on its own line\n[features]\nhooks = false\n",
    )
    .unwrap();
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "codex", "--copy", "-y"]),
        "vstack add (reinstall)",
    );
    let after = fs::read_to_string(&config_toml).unwrap();
    let doc: toml::Value = after.parse().expect("config.toml still parses");
    assert_eq!(
        doc.get("features")
            .and_then(|f| f.get("hooks"))
            .and_then(|v| v.as_bool()),
        Some(true),
        "the reinstall lost the real features table behind a comment decoy:\n{after}"
    );
}

#[test]
fn a_delimiter_inside_a_single_line_string_does_not_derail_the_feature_writer() {
    let sandbox = Sandbox::new("codex-feature-inline-string-decoy");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "codex", "--copy", "-y"]),
        "vstack add",
    );
    // A delimiter inside a single-line value is content: the reinstall must
    // still see the real structure below it.
    let config_toml = sandbox.project.join(".codex/config.toml");
    fs::write(
        &config_toml,
        "example = \"uses ''' inside\"\n[features]\nhooks = false\n",
    )
    .unwrap();
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "codex", "--copy", "-y"]),
        "vstack add (reinstall)",
    );
    let after = fs::read_to_string(&config_toml).unwrap();
    let doc: toml::Value = after.parse().expect("config.toml still parses");
    assert_eq!(
        doc.get("features")
            .and_then(|f| f.get("hooks"))
            .and_then(|v| v.as_bool()),
        Some(true),
        "the reinstall lost the real features table behind a string decoy:\n{after}"
    );
}

#[test]
fn a_filtered_add_refuses_before_installing_anything() {
    let sandbox = Sandbox::new("add-atomic-uncovered");
    assert_success(
        sandbox.add(&[
            "--agent",
            "rust",
            "--hook",
            "probe",
            "--harness",
            "claude-code",
            "--copy",
            "-y",
        ]),
        "vstack add",
    );
    write_probe_hook(&sandbox.source, "probe", "Notification");
    fs::write(
        sandbox.source.join("agents/extra.md"),
        "---\nname: extra\ndescription: Extra agent\nmodel: sonnet\nrole: engineer\n---\n# Extra\n\nBody.\n",
    )
    .unwrap();
    let output = sandbox.add(&[
        "--agent",
        "extra",
        "--harness",
        "claude-code",
        "--copy",
        "-y",
    ]);
    assert!(
        !output.status.success(),
        "an add against an uncovered locked hook succeeded"
    );
    assert!(
        !sandbox.project.join(".claude/agents/extra.md").exists(),
        "the refused add installed its selected item first"
    );
    let lock = fs::read_to_string(sandbox.project.join(".vstack-lock.json")).unwrap();
    assert!(
        !lock.contains("\"extra\""),
        "the refused add wrote a lock entry first:\n{lock}"
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
        text.contains("codex: unsupported (artifact missing)"),
        "a features example inside a string enabled the hooks claim:\n{text}"
    );
}

#[test]
fn a_filtered_add_refuses_to_reconcile_from_an_uncovered_event() {
    let sandbox = Sandbox::new("add-reconcile-uncovered");
    assert_success(
        sandbox.add(&[
            "--agent",
            "rust",
            "--hook",
            "probe",
            "--harness",
            "claude-code",
            "--copy",
            "-y",
        ]),
        "vstack add",
    );
    let agent_path = sandbox.project.join(".claude/agents/rust.md");
    let before = fs::read_to_string(&agent_path).unwrap();
    // An installed hook's source leaves the contract, then an unrelated item
    // is added: reconciliation regenerates every agent from every locked
    // hook, and must refuse a definition install would refuse.
    write_probe_hook(&sandbox.source, "probe", "Notification");
    fs::write(
        sandbox.source.join("agents/extra.md"),
        "---\nname: extra\ndescription: Extra agent\nmodel: sonnet\nrole: engineer\n---\n# Extra\n\nBody.\n",
    )
    .unwrap();
    let output = sandbox.add(&[
        "--agent",
        "extra",
        "--harness",
        "claude-code",
        "--copy",
        "-y",
    ]);
    assert!(
        !output.status.success(),
        "a filtered add reconciled agents from an event the contract does not cover\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let after = fs::read_to_string(&agent_path).unwrap();
    assert_eq!(
        before, after,
        "reconciliation rewrote an agent from an uncovered event before refusing"
    );
}

#[test]
fn refresh_refuses_an_uncovered_event_before_pruning_harnesses() {
    let sandbox = Sandbox::new("refresh-uncovered-before-prune");
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
    let rule = sandbox.project.join(".cursor/rules/safety-probe.mdc");
    assert!(rule.is_file(), "cursor rule was not installed");
    // The source simultaneously leaves the contract and narrows harnesses:
    // nothing — prune included — may act on a definition install refuses.
    write_probe_hook(&sandbox.source, "probe", "Notification");
    let path = sandbox.source.join("hooks/probe.sh");
    let script = fs::read_to_string(&path).unwrap();
    fs::write(
        &path,
        script.replace("# safety:", "# harnesses: [claude-code]\n# safety:"),
    )
    .unwrap();
    let output = sandbox
        .vstack()
        .args(["refresh", "--scope", "project"])
        .output()
        .unwrap();
    assert!(
        !output.status.success(),
        "refresh accepted an event the contract does not cover"
    );
    assert!(
        rule.is_file(),
        "the prune pass removed artifacts before the uncovered event was refused"
    );
}

#[test]
fn refresh_refuses_an_uncovered_event_before_touching_agents() {
    let sandbox = Sandbox::new("refresh-uncovered-event");
    assert_success(
        sandbox.add(&[
            "--agent",
            "rust",
            "--hook",
            "probe",
            "--harness",
            "claude-code",
            "--copy",
            "-y",
        ]),
        "vstack add",
    );
    let agent_path = sandbox.project.join(".claude/agents/rust.md");
    let before = fs::read_to_string(&agent_path).unwrap();
    // The source hook's event leaves the contract before the next refresh:
    // nothing may be regenerated from a definition install would refuse.
    write_probe_hook(&sandbox.source, "probe", "Notification");
    let output = sandbox
        .vstack()
        .args(["refresh", "--scope", "project"])
        .output()
        .unwrap();
    assert!(
        !output.status.success(),
        "refresh accepted an event the contract does not cover\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let after = fs::read_to_string(&agent_path).unwrap();
    assert_eq!(
        before, after,
        "refresh mutated agents before refusing the uncovered event"
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
        text.contains("claude-code: unsupported (artifact missing)"),
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
        text.contains("opencode: unsupported (artifact missing)"),
        "an instruction file opencode.json does not reference still reads as advisory:\n{text}"
    );
}

#[test]
fn a_moved_project_with_a_quoted_path_does_not_accumulate_stale_codex_registrations() {
    let sandbox = Sandbox::new("codex-moved-quoted");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "codex", "--copy", "-y"]),
        "vstack add",
    );
    let hooks_json = sandbox.project.join(".codex/hooks.json");
    // A previous location whose path needed quoting: shell_quote emits single
    // quotes, and the stale handler must still be recognized as vstack's.
    fs::write(
        &hooks_json,
        serde_json::to_string_pretty(&serde_json::json!({
            "hooks": {
                "PreToolUse": [{
                    "matcher": "Bash",
                    "hooks": [{
                        "type": "command",
                        "command": "bash '/somewhere else/.codex/hooks/probe.sh'"
                    }]
                }]
            }
        }))
        .unwrap(),
    )
    .unwrap();
    assert_success(
        sandbox
            .vstack()
            .args(["refresh", "--scope", "project"])
            .output()
            .unwrap(),
        "vstack refresh",
    );
    let config = read_json(&hooks_json);
    let handlers = config
        .pointer("/hooks/PreToolUse")
        .and_then(|value| value.as_array())
        .expect("PreToolUse array");
    assert_eq!(
        handlers.len(),
        1,
        "a single-quoted registration from the project's old location survived: {config:#}"
    );
    let (fired, detail) = sandbox.fire(&registered_command(&config, "PreToolUse"), &[]);
    assert!(fired, "the surviving Codex command did not fire\n{detail}");
}

#[test]
fn a_live_foreign_codex_handler_with_the_install_shape_is_left_alone() {
    let sandbox = Sandbox::new("codex-live-foreign");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "codex", "--copy", "-y"]),
        "vstack add",
    );
    // Another still-existing checkout's install of a same-named hook: the
    // script is alive on disk, so it is that project's handler, not a stale
    // relic of this one.
    let foreign = sandbox.root.join("other/.codex/hooks");
    fs::create_dir_all(&foreign).unwrap();
    let foreign_script = foreign.join("probe.sh");
    fs::write(&foreign_script, "#!/usr/bin/env bash\nexit 0\n").unwrap();
    let foreign_command = format!("bash {}", foreign_script.display());
    let hooks_json = sandbox.project.join(".codex/hooks.json");
    let mut config = read_json(&hooks_json);
    config
        .pointer_mut("/hooks/PreToolUse")
        .and_then(|value| value.as_array_mut())
        .expect("PreToolUse array")
        .push(serde_json::json!({
            "matcher": "Bash",
            "hooks": [{"type": "command", "command": foreign_command}]
        }));
    fs::write(&hooks_json, serde_json::to_string_pretty(&config).unwrap()).unwrap();
    assert_success(
        sandbox
            .vstack()
            .args(["refresh", "--scope", "project"])
            .output()
            .unwrap(),
        "vstack refresh",
    );
    let after = fs::read_to_string(&hooks_json).unwrap();
    assert!(
        after.contains(&foreign_command),
        "a live handler owned by another checkout was pruned:\n{after}"
    );
}

#[test]
fn a_requoted_registration_for_the_same_script_is_replaced_not_duplicated() {
    let sandbox = Sandbox::new("codex-requoted");
    assert_success(
        sandbox.add(&["--hook", "probe", "--harness", "codex", "--copy", "-y"]),
        "vstack add",
    );
    let hooks_json = sandbox.project.join(".codex/hooks.json");
    // The same live script, spelled with quotes a different writer chose:
    // still this install's registration, so a refresh must replace it rather
    // than add a second handler beside it.
    let script = sandbox.project.join(".codex/hooks/probe.sh");
    fs::write(
        &hooks_json,
        serde_json::to_string_pretty(&serde_json::json!({
            "hooks": {
                "PreToolUse": [{
                    "matcher": "Bash",
                    "hooks": [{
                        "type": "command",
                        "command": format!("bash \"{}\"", script.display())
                    }]
                }]
            }
        }))
        .unwrap(),
    )
    .unwrap();
    assert_success(
        sandbox
            .vstack()
            .args(["refresh", "--scope", "project"])
            .output()
            .unwrap(),
        "vstack refresh",
    );
    let config = read_json(&hooks_json);
    let handlers = config
        .pointer("/hooks/PreToolUse")
        .and_then(|value| value.as_array())
        .expect("PreToolUse array");
    assert_eq!(
        handlers.len(),
        1,
        "a requoted registration for the live script was duplicated instead of replaced: {config:#}"
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
        text.contains("codex: unsupported (artifact missing)"),
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
fn a_narrowed_allowlist_removes_the_excluded_artifact_on_refresh() {
    let sandbox = Sandbox::new("narrowed-allowlist-removal");
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
    let rule = sandbox.project.join(".cursor/rules/safety-probe.mdc");
    assert!(rule.is_file(), "cursor rule was not installed");
    write_probe_hook(&sandbox.source, "probe", "PreToolUse");
    let path = sandbox.source.join("hooks/probe.sh");
    let script = fs::read_to_string(&path).unwrap();
    fs::write(
        &path,
        script.replace("# safety:", "# harnesses: [claude-code]\n# safety:"),
    )
    .unwrap();
    assert_success(
        sandbox
            .vstack()
            .args(["refresh", "--scope", "project"])
            .output()
            .unwrap(),
        "vstack refresh",
    );
    assert!(
        !rule.exists(),
        "the artifact of a harness the allowlist excluded survived the refresh"
    );
    assert!(
        sandbox.project.join(".claude/hooks/probe.sh").is_file(),
        "the still-allowed harness lost its artifact"
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
        text.contains("codex: unsupported (artifact missing)"),
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
        text.contains("claude-code: unsupported (artifact missing)"),
        "a hook whose script is gone still reads as enforced:\n{text}"
    );
}
