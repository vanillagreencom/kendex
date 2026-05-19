use std::error::Error;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;

const SESSION: &str = "test-fd";
const SESSION_KEY: &str = "s42";

#[test]
fn launch_without_tmux_skips() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let output = Command::new(dashboard_bin())
        .args(["launch", "--session", SESSION, "--no-daemon"])
        .env_remove("TMUX")
        .env("FD_STATE_DIR", temp.path().join("runtime"))
        .env("FLIGHTDECK_STATE_DIR", temp.path().join("state"))
        .env("FLIGHTDECK_DASHBOARD", "1")
        .output()?;

    assert!(output.status.success());
    assert_eq!(String::from_utf8_lossy(&output.stdout), "");
    assert!(String::from_utf8_lossy(&output.stderr)
        .contains("flightdeck-dashboard: not in tmux; skipping launch"));
    assert!(!temp.path().join("state").exists());
    Ok(())
}

#[test]
fn launch_disabled_exits_silently() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let output = Command::new(dashboard_bin())
        .args(["launch", "--session", SESSION])
        .env_remove("TMUX")
        .env("FD_STATE_DIR", temp.path().join("runtime"))
        .env("FLIGHTDECK_STATE_DIR", temp.path().join("state"))
        .env("FLIGHTDECK_DASHBOARD", "0")
        .output()?;

    assert!(output.status.success());
    assert_eq!(String::from_utf8_lossy(&output.stdout), "");
    assert_eq!(String::from_utf8_lossy(&output.stderr), "");
    assert!(!temp.path().join("state").exists());
    Ok(())
}

#[test]
fn startup_override_file_can_disable_dashboard_launch() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(project.join("tmp"))?;
    std::fs::write(project.join("vstack.toml"), "")?;
    std::fs::write(
        project.join("tmp/flightdeck-settings.toml"),
        "FLIGHTDECK_DASHBOARD = \"0\"\n",
    )?;

    let output = Command::new(dashboard_bin())
        .current_dir(&project)
        .args(["launch", "--session", SESSION])
        .env_remove("TMUX")
        .env("FD_STATE_DIR", temp.path().join("runtime"))
        .env("FLIGHTDECK_DASHBOARD", "1")
        .output()?;

    assert!(output.status.success());
    assert_eq!(String::from_utf8_lossy(&output.stdout), "");
    assert_eq!(String::from_utf8_lossy(&output.stderr), "");
    Ok(())
}

#[test]
fn startup_override_file_forwards_theme_and_motion() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(project.join("tmp"))?;
    std::fs::write(project.join("vstack.toml"), "")?;
    std::fs::write(
        project.join("tmp/flightdeck-settings.toml"),
        "FLIGHTDECK_DASHBOARD_THEME = \"pantera\"\nFLIGHTDECK_DASHBOARD_MOTION = \"off\"\n",
    )?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    write_fake_tmux(&bin_dir, &windows_file)?;
    let capture = temp.path().join("session-args");
    write_capturing_flightdeck_session(&bin_dir.join("flightdeck-session"), &capture)?;
    let path = path_with_bin(&bin_dir);

    let output =
        launch_command_without_daemon(&path, &temp.path().join("runtime"), &project).output()?;

    assert!(
        output.status.success(),
        "launch failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let cmd = captured_cmd_arg(&capture)?;
    assert!(cmd.contains("--theme pantera"), "missing theme in {cmd}");
    assert!(cmd.contains("--motion off"), "missing motion in {cmd}");
    Ok(())
}

#[test]
fn malformed_settings_file_surfaces_for_non_tty_tui() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(project.join("tmp"))?;
    std::fs::write(project.join("vstack.toml"), "")?;
    std::fs::write(
        project.join("tmp/flightdeck-settings.toml"),
        "FLIGHTDECK_DASHBOARD_COST_POLL_SECS = \"0.5\"\n",
    )?;

    let output = Command::new(dashboard_bin())
        .current_dir(&project)
        .args(["tui", "--demo"])
        .env("FD_STATE_DIR", temp.path().join("runtime"))
        .output()?;

    assert!(output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("settings override ignored")
            && stderr.contains("FLIGHTDECK_DASHBOARD_COST_POLL_SECS"),
        "stderr missing settings warning: {stderr}"
    );
    Ok(())
}

#[test]
fn skill_dir_from_env() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(&project)?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    write_fake_tmux(&bin_dir, &windows_file)?;
    let skill_dir = temp.path().join("env-skill");
    let env_capture = temp.path().join("env-session-args");
    write_capturing_flightdeck_session(
        &skill_dir.join("scripts/flightdeck-session"),
        &env_capture,
    )?;
    let path_capture = temp.path().join("path-session-args");
    write_capturing_flightdeck_session(&bin_dir.join("flightdeck-session"), &path_capture)?;
    let path = path_with_bin(&bin_dir);

    let output = launch_command_without_daemon(&path, &temp.path().join("runtime"), &project)
        .env("FLIGHTDECK_SKILL_DIR", &skill_dir)
        .output()?;

    assert!(
        output.status.success(),
        "launch failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(env_capture.exists(), "FLIGHTDECK_SKILL_DIR script used");
    assert!(!path_capture.exists(), "PATH fallback skipped");
    Ok(())
}

#[test]
fn skill_dir_from_dot_agents() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(&project)?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    write_fake_tmux(&bin_dir, &windows_file)?;
    let capture = temp.path().join("dot-agents-session-args");
    write_capturing_flightdeck_session(
        &project.join(".agents/skills/flightdeck/scripts/flightdeck-session"),
        &capture,
    )?;
    let path = path_with_bin(&bin_dir);

    let output =
        launch_command_without_daemon(&path, &temp.path().join("runtime"), &project).output()?;

    assert!(
        output.status.success(),
        "launch failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(capture.exists(), ".agents flightdeck-session script used");
    assert!(
        !project.join("skills").exists(),
        "source-tree skills absent"
    );
    Ok(())
}

#[test]
fn no_motion_forwards_motion_off() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(&project)?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    write_fake_tmux(&bin_dir, &windows_file)?;
    let capture = temp.path().join("session-args");
    let flightdeck_session = bin_dir.join("flightdeck-session");
    write_capturing_flightdeck_session(&flightdeck_session, &capture)?;
    let path = path_with_bin(&bin_dir);

    let output = launch_command_without_daemon(&path, &temp.path().join("runtime"), &project)
        .env("FLIGHTDECK_SESSION_BIN", &flightdeck_session)
        .env("FLIGHTDECK_DASHBOARD_MOTION", "full")
        .env("NO_MOTION", "1")
        .output()?;

    assert!(
        output.status.success(),
        "launch failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let cmd = captured_cmd_arg(&capture)?;
    assert!(
        cmd.contains("--motion off"),
        "expected --motion off in child command: {cmd}"
    );
    Ok(())
}

#[test]
fn launch_against_missing_state_file_requires_registered_entry() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(&project)?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    write_fake_tmux(&bin_dir, &windows_file)?;
    let capture = temp.path().join("session-args");
    let flightdeck_session = bin_dir.join("flightdeck-session");
    write_capturing_flightdeck_session(&flightdeck_session, &capture)?;
    let missing_state = project.join("tmp/flightdeck-state-test-fd.json");
    let path = path_with_bin(&bin_dir);

    let output = Command::new(dashboard_bin())
        .current_dir(&project)
        .args([
            "launch",
            "--session",
            SESSION,
            "--state-file",
            missing_state.to_str().expect("state path utf-8"),
            "--window-name",
            "flightdeck-test",
        ])
        .env("PATH", path)
        .env("TMUX", "/tmp/fake-tmux")
        .env("FD_STATE_DIR", temp.path().join("runtime"))
        .env("FLIGHTDECK_SESSION_BIN", &flightdeck_session)
        .env("FLIGHTDECK_DAEMON_RUST", "1")
        .env("FLIGHTDECK_DASHBOARD", "1")
        .output()?;

    assert!(
        output.status.success(),
        "launch failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        capture.exists(),
        "dashboard window launch writes through flightdeck-session"
    );
    assert!(
        missing_state.exists(),
        "dashboard launch must verify the registered master-state entry"
    );
    Ok(())
}

#[test]
fn probe_failure_warns_and_attempts_launch() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(&project)?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    write_failing_probe_tmux(&bin_dir)?;
    let capture = temp.path().join("session-args");
    let flightdeck_session = bin_dir.join("flightdeck-session");
    write_capturing_flightdeck_session(&flightdeck_session, &capture)?;
    let path = path_with_bin(&bin_dir);

    let output = launch_command_without_daemon(&path, &temp.path().join("runtime"), &project)
        .env("FLIGHTDECK_SESSION_BIN", &flightdeck_session)
        .output()?;

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("tmux window probe failed; attempting dashboard launch anyway"),
        "stderr missing window-probe warning: {stderr}"
    );
    assert!(stderr.contains("tmux list-windows failed"));
    assert!(stderr.contains("tmux list-panes failed"));
    assert!(
        capture.exists(),
        "flightdeck-session attempted despite probe failure"
    );
    Ok(())
}

#[test]
fn stale_same_name_window_does_not_satisfy_launch() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(&project)?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    std::fs::write(&windows_file, "flightdeck-test\n")?;
    write_fake_tmux(&bin_dir, &windows_file)?;
    let capture = temp.path().join("session-args");
    let flightdeck_session = bin_dir.join("flightdeck-session");
    write_capturing_flightdeck_session(&flightdeck_session, &capture)?;
    let path = path_with_bin(&bin_dir);

    let output = launch_command_without_daemon(&path, &temp.path().join("runtime"), &project)
        .env("FLIGHTDECK_SESSION_BIN", &flightdeck_session)
        .output()?;

    assert!(
        output.status.success(),
        "launch failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("exists but no live tracked dashboard entry was verified"),
        "stderr missing stale-window warning: {stderr}"
    );
    assert!(
        capture.exists(),
        "stale same-name window did not skip launch"
    );
    Ok(())
}

#[test]
fn stale_tracked_dashboard_entry_does_not_satisfy_launch() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(project.join("tmp"))?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let state_file = project.join("tmp/flightdeck-state-test-fd.json");
    write_state_with_pane(&state_file, "%dead")?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    std::fs::write(&windows_file, "flightdeck-test\n")?;
    write_fake_tmux(&bin_dir, &windows_file)?;
    let capture = temp.path().join("session-args");
    let flightdeck_session = bin_dir.join("flightdeck-session");
    write_capturing_flightdeck_session(&flightdeck_session, &capture)?;
    let path = path_with_bin(&bin_dir);

    let output = launch_command_without_daemon(&path, &temp.path().join("runtime"), &project)
        .env("FLIGHTDECK_SESSION_BIN", &flightdeck_session)
        .output()?;

    assert!(
        output.status.success(),
        "launch failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("exists but no live tracked dashboard entry was verified"),
        "stderr missing stale tracked-entry warning: {stderr}"
    );
    let entry = read_dashboard_entry(&state_file)?;
    assert_eq!(entry["pane_id"], "%99");
    assert!(capture.exists(), "stale tracked entry did not skip launch");
    Ok(())
}

#[test]
fn launch_starts_rust_daemon_registers_window_and_is_idempotent() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let state_file = temp.path().join("flightdeck-state-test-fd.json");
    let runtime_dir = temp.path().join("runtime");
    let count_file = temp.path().join("session-count");
    let windows_file = temp.path().join("tmux-windows");
    write_state(&state_file, false)?;
    let tmux = write_fake_tmux(&bin_dir, &windows_file)?;
    let flightdeck_session =
        write_fake_flightdeck_session(&bin_dir, &state_file, &count_file, &windows_file)?;
    let path = format!(
        "{}:{}",
        bin_dir.display(),
        std::env::var("PATH").unwrap_or_default()
    );

    let first = launch_command(&path, &runtime_dir, &state_file, &flightdeck_session).output()?;
    assert!(
        first.status.success(),
        "first launch failed: {}",
        String::from_utf8_lossy(&first.stderr)
    );
    let pid_path = runtime_dir.join(format!("dashboard-{SESSION_KEY}.pid"));
    let socket_path = runtime_dir.join(format!("dashboard-{SESSION_KEY}.sock"));
    assert!(pid_path.exists(), "daemon pid file created");
    assert!(socket_path.exists(), "daemon socket created");
    let first_pid = std::fs::read_to_string(&pid_path)?;
    assert_eq!(std::fs::read_to_string(&count_file)?.trim(), "1");
    let entry = read_dashboard_entry(&state_file)?;
    assert_eq!(entry["kind"], "workflow");
    assert_eq!(entry["pane_id"], "%99");

    let second = launch_command(&path, &runtime_dir, &state_file, &flightdeck_session).output()?;
    assert!(
        second.status.success(),
        "second launch failed: {}",
        String::from_utf8_lossy(&second.stderr)
    );
    assert_eq!(std::fs::read_to_string(&count_file)?.trim(), "1");
    assert_eq!(std::fs::read_to_string(&pid_path)?, first_pid);

    let stop = Command::new(dashboard_bin())
        .args(["daemon", "stop", "--session", SESSION])
        .env("PATH", path)
        .env("TMUX", "/tmp/fake-tmux")
        .env("FD_STATE_DIR", &runtime_dir)
        .output()?;
    assert!(
        stop.status.success(),
        "daemon stop failed: {}",
        String::from_utf8_lossy(&stop.stderr)
    );
    assert!(tmux.exists(), "fake tmux installed");
    Ok(())
}

fn launch_command(
    path: &str,
    runtime_dir: &Path,
    state_file: &Path,
    flightdeck_session: &Path,
) -> Command {
    let mut command = Command::new(dashboard_bin());
    command
        .args([
            "launch",
            "--session",
            SESSION,
            "--state-file",
            state_file.to_str().expect("state path utf-8"),
            "--window-name",
            "flightdeck-test",
            "--motion",
            "off",
        ])
        .env("PATH", path)
        .env("TMUX", "/tmp/fake-tmux")
        .env("FD_STATE_DIR", runtime_dir)
        .env("FLIGHTDECK_DAEMON_RUST", "1")
        .env("FLIGHTDECK_SESSION_BIN", flightdeck_session)
        .env("FLIGHTDECK_DASHBOARD", "1");
    command
}

fn launch_command_without_daemon(path: &str, runtime_dir: &Path, project: &Path) -> Command {
    let mut command = Command::new(dashboard_bin());
    command
        .current_dir(project)
        .args([
            "launch",
            "--session",
            SESSION,
            "--window-name",
            "flightdeck-test",
            "--no-daemon",
        ])
        .env("PATH", path)
        .env("TMUX", "/tmp/fake-tmux")
        .env("FD_STATE_DIR", runtime_dir)
        .env("FLIGHTDECK_DASHBOARD", "1")
        .env_remove("FLIGHTDECK_SESSION_BIN")
        .env_remove("FLIGHTDECK_SKILL_DIR")
        .env_remove("FLIGHTDECK_DASHBOARD_MOTION")
        .env_remove("FLIGHTDECK_DAEMON_RUST")
        .env_remove("NO_MOTION")
        .env_remove("NO_COLOR");
    command
}

fn path_with_bin(bin_dir: &Path) -> String {
    format!(
        "{}:{}",
        bin_dir.display(),
        std::env::var("PATH").unwrap_or_default()
    )
}

fn captured_cmd_arg(path: &Path) -> Result<String, Box<dyn Error>> {
    let args = std::fs::read_to_string(path)?;
    let mut lines = args.lines();
    while let Some(line) = lines.next() {
        if line == "--cmd" {
            return lines
                .next()
                .map(str::to_owned)
                .ok_or_else(|| "missing --cmd value".into());
        }
    }
    Err("missing --cmd argument".into())
}

fn read_dashboard_entry(path: &Path) -> Result<Value, Box<dyn Error>> {
    let value = serde_json::from_str::<Value>(&std::fs::read_to_string(path)?)?;
    Ok(value
        .pointer("/entries/flightdeck-dashboard")
        .cloned()
        .ok_or("dashboard entry missing")?)
}

fn write_state(path: &Path, with_entry: bool) -> Result<(), Box<dyn Error>> {
    let entries = if with_entry {
        r#""flightdeck-dashboard":{"id":"flightdeck-dashboard","title":"flightdeck-test","kind":"workflow","state":"waiting","harness":"shell","pane_id":"%99"}"#
    } else {
        ""
    };
    let json = format!(
        r#"{{
  "session_id": "{SESSION}",
  "updated_at": "2026-05-15T00:00:00Z",
  "entries": {{{entries}}}
}}"#
    );
    std::fs::write(path, json)?;
    Ok(())
}

fn write_state_with_pane(path: &Path, pane_id: &str) -> Result<(), Box<dyn Error>> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let json = format!(
        r#"{{
  "session_id": "{SESSION}",
  "updated_at": "2026-05-15T00:00:00Z",
  "entries": {{
    "flightdeck-dashboard": {{
      "id": "flightdeck-dashboard",
      "title": "flightdeck-test",
      "kind": "workflow",
      "state": "waiting",
      "harness": "shell",
      "pane_id": "{pane_id}"
    }}
  }}
}}"#
    );
    std::fs::write(path, json)?;
    Ok(())
}

fn write_fake_tmux(dir: &Path, windows_file: &Path) -> Result<PathBuf, Box<dyn Error>> {
    let path = dir.join("tmux");
    std::fs::write(
        &path,
        format!(
            r##"#!/usr/bin/env bash
set -euo pipefail
windows={windows:?}
if [[ "${{1:-}}" == "display-message" ]]; then
  args="$*"
  if [[ "$args" == *"#{{session_id}}"* ]]; then echo '$42'; exit 0; fi
  if [[ "$args" == *"#S"* ]]; then echo '{SESSION}'; exit 0; fi
  if [[ "$args" == *"#{{pane_id}}"* ]]; then echo '%99'; exit 0; fi
  exit 0
fi
if [[ "${{1:-}}" == "list-panes" ]]; then
  echo '%99'
  exit 0
fi
if [[ "${{1:-}}" == "list-windows" ]]; then
  [[ -f "$windows" ]] && cat "$windows"
  exit 0
fi
exit 0
"##,
            windows = windows_file.display()
        ),
    )?;
    make_executable(&path)?;
    Ok(path)
}

fn write_failing_probe_tmux(dir: &Path) -> Result<PathBuf, Box<dyn Error>> {
    let path = dir.join("tmux");
    std::fs::write(
        &path,
        r##"#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "display-message" ]]; then
  args="$*"
  if [[ "$args" == *"#{session_id}"* ]]; then echo '$42'; exit 0; fi
  if [[ "$args" == *"#S"* ]]; then echo 'test-fd'; exit 0; fi
  if [[ "$args" == *"#{pane_id}"* ]]; then echo '%99'; exit 0; fi
  exit 0
fi
if [[ "${1:-}" == "list-panes" ]]; then
  echo 'tmux list-panes unavailable' >&2
  exit 1
fi
if [[ "${1:-}" == "list-windows" ]]; then
  echo 'tmux list-windows unavailable' >&2
  exit 1
fi
exit 0
"##,
    )?;
    make_executable(&path)?;
    Ok(path)
}

fn write_capturing_flightdeck_session(
    path: &Path,
    capture_file: &Path,
) -> Result<PathBuf, Box<dyn Error>> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(
        path,
        format!(
            r##"#!/usr/bin/env bash
set -euo pipefail
capture={capture:?}
printf '%s\n' "$@" > "$capture"
state_dir="${{FLIGHTDECK_STATE_DIR:-tmp}}"
mkdir -p "$state_dir"
cat > "$state_dir/flightdeck-state-{SESSION}.json" <<'JSON'
{{
  "session_id": "{SESSION}",
  "updated_at": "2026-05-15T00:00:01Z",
  "entries": {{
    "flightdeck-dashboard": {{
      "id": "flightdeck-dashboard",
      "title": "flightdeck-test",
      "kind": "workflow",
      "state": "waiting",
      "harness": "shell",
      "pane_id": "%99"
    }}
  }}
}}
JSON
"##,
            capture = capture_file.display()
        ),
    )?;
    make_executable(path)?;
    Ok(path.to_path_buf())
}

fn write_fake_flightdeck_session(
    dir: &Path,
    state_file: &Path,
    count_file: &Path,
    windows_file: &Path,
) -> Result<PathBuf, Box<dyn Error>> {
    let path = dir.join("flightdeck-session");
    std::fs::write(
        &path,
        format!(
            r##"#!/usr/bin/env bash
set -euo pipefail
state={state:?}
count_file={count:?}
windows={windows:?}
count=0
if [[ -f "$count_file" ]]; then count=$(cat "$count_file"); fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
title="flightdeck-test"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) title="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$title" >> "$windows"
cat > "$state" <<'JSON'
{{
  "session_id": "{SESSION}",
  "updated_at": "2026-05-15T00:00:01Z",
  "entries": {{
    "flightdeck-dashboard": {{
      "id": "flightdeck-dashboard",
      "title": "flightdeck-test",
      "kind": "workflow",
      "state": "waiting",
      "harness": "shell",
      "pane_id": "%99"
    }}
  }}
}}
JSON
"##,
            state = state_file.display(),
            count = count_file.display(),
            windows = windows_file.display()
        ),
    )?;
    make_executable(&path)?;
    Ok(path)
}

fn make_executable(path: &Path) -> Result<(), Box<dyn Error>> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(path)?.permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(path, perms)?;
    }
    Ok(())
}

fn dashboard_bin() -> &'static str {
    env!("CARGO_BIN_EXE_flightdeck-dashboard")
}
