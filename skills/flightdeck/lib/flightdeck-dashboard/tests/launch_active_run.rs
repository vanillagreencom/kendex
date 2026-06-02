use std::error::Error;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;

const SESSION: &str = "test-fd";

#[test]
fn launch_runs_state_ensure_before_dashboard_probe_to_rotate_all_dead_active_run(
) -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(project.join("tmp"))?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let state_file = project.join("tmp/flightdeck-state-test-fd.json");
    write_state_with_target(&state_file, "%dead", "@dead")?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    write_fake_tmux(&bin_dir, &windows_file)?;
    let session_capture = temp.path().join("session-args");
    let flightdeck_session = bin_dir.join("flightdeck-session");
    write_capturing_flightdeck_session(&flightdeck_session, &session_capture)?;
    let state_capture = temp.path().join("state-args");
    let flightdeck_state = bin_dir.join("flightdeck-state");
    write_state_ensure_clearing_shim(&flightdeck_state, &state_file, &state_capture)?;
    let path = path_with_bin(&bin_dir);

    let output = launch_command_without_daemon(&path, &temp.path().join("runtime"), &project)
        .env("FLIGHTDECK_SESSION_BIN", &flightdeck_session)
        .env("FLIGHTDECK_STATE_BIN", &flightdeck_state)
        .output()?;

    assert!(
        output.status.success(),
        "launch failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let state_args = std::fs::read_to_string(&state_capture)?;
    assert!(
        state_args.contains("run\nensure\n"),
        "dashboard launch did not run state ensure before probing: {state_args}"
    );
    assert!(
        state_args.contains("--project-root\n"),
        "missing project root flag: {state_args}"
    );
    assert!(
        state_args.contains(&format!("{}\n", project.display())),
        "missing project root value: {state_args}"
    );
    assert!(
        state_args.contains("--tmux-session\n"),
        "missing tmux session flag: {state_args}"
    );
    assert!(
        state_args.contains(&format!("{SESSION}\n")),
        "missing tmux session value: {state_args}"
    );
    assert!(
        session_capture.exists(),
        "fresh state after ensure should allow dashboard launch"
    );
    let entry = read_dashboard_entry(&state_file)?;
    assert_eq!(entry["pane_id"], "%99");
    Ok(())
}

#[test]
fn focus_or_launch_runs_state_ensure_before_dashboard_probe_to_rotate_all_dead_active_run(
) -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(project.join("tmp"))?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let state_file = project.join("tmp/flightdeck-state-test-fd.json");
    write_state_with_target(&state_file, "%dead", "@dead")?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    write_fake_tmux(&bin_dir, &windows_file)?;
    let session_capture = temp.path().join("session-args");
    let flightdeck_session = bin_dir.join("flightdeck-session");
    write_capturing_flightdeck_session(&flightdeck_session, &session_capture)?;
    let state_capture = temp.path().join("state-args");
    let flightdeck_state = bin_dir.join("flightdeck-state");
    write_state_ensure_clearing_shim(&flightdeck_state, &state_file, &state_capture)?;
    let path = path_with_bin(&bin_dir);

    let output = Command::new(dashboard_bin())
        .current_dir(&project)
        .args([
            "focus-or-launch",
            "--session",
            SESSION,
            "--json",
            "--no-daemon",
        ])
        .env("PATH", path)
        .env("TMUX", "/tmp/fake-tmux")
        .env("FD_STATE_DIR", temp.path().join("runtime"))
        .env("FLIGHTDECK_DASHBOARD", "1")
        .env("FLIGHTDECK_SESSION_BIN", &flightdeck_session)
        .env("FLIGHTDECK_STATE_BIN", &flightdeck_state)
        .output()?;

    assert!(
        output.status.success(),
        "focus-or-launch failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let state_args = std::fs::read_to_string(&state_capture)?;
    assert!(
        state_args.contains("run\nensure\n"),
        "focus-or-launch did not run state ensure before probing: {state_args}"
    );
    assert!(
        state_args.contains(&format!("{}\n", project.display())),
        "missing project root value: {state_args}"
    );
    assert!(
        state_args.contains(&format!("{SESSION}\n")),
        "missing tmux session value: {state_args}"
    );
    let report: Value = serde_json::from_slice(&output.stdout)?;
    assert_eq!(report["status"], "launched");
    assert!(
        session_capture.exists(),
        "fresh state after ensure should allow focus-or-launch to launch"
    );
    let entry = read_dashboard_entry(&state_file)?;
    assert_eq!(entry["pane_id"], "%99");
    Ok(())
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

fn read_dashboard_entry(path: &Path) -> Result<Value, Box<dyn Error>> {
    let value = serde_json::from_str::<Value>(&std::fs::read_to_string(path)?)?;
    Ok(value
        .pointer("/entries/flightdeck-dashboard")
        .cloned()
        .ok_or("dashboard entry missing")?)
}

fn write_state_with_target(
    path: &Path,
    pane_id: &str,
    window_id: &str,
) -> Result<(), Box<dyn Error>> {
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
      "pane_id": "{pane_id}",
      "window_id": "{window_id}"
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

fn write_state_ensure_clearing_shim(
    path: &Path,
    state_file: &Path,
    capture_file: &Path,
) -> Result<PathBuf, Box<dyn Error>> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let state_json = serde_json::to_string(&state_file.display().to_string())?;
    std::fs::write(
        path,
        format!(
            r##"#!/usr/bin/env bash
set -euo pipefail
capture={capture:?}
state={state:?}
printf '%s\n' "$@" > "$capture"
if [[ "${{1:-}}" == "run" && "${{2:-}}" == "ensure" ]]; then
  mkdir -p "$(dirname "$state")"
  cat > "$state" <<'JSON'
{{
  "session_id": "{SESSION}",
  "updated_at": "2026-05-15T00:00:00Z",
  "entries": {{}}
}}
JSON
  printf '{{"action":"created-after-stale","paths":{{"state_json":{state_json}}}}}\n'
  exit 0
fi
echo "unexpected flightdeck-state args: $*" >&2
exit 2
"##,
            capture = capture_file.display(),
            state = state_file.display(),
            state_json = state_json,
        ),
    )?;
    make_executable(path)?;
    Ok(path.to_path_buf())
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
