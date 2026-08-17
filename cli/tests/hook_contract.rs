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
