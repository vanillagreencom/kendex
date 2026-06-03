#![allow(dead_code)]

pub mod pi_daemon;

use std::error::Error;
use std::path::{Path, PathBuf};
use std::process::Command;

use chrono::{DateTime, TimeZone, Utc};
use flightdeck_dashboard::app::command::SnapshotSource;
use flightdeck_dashboard::app::model::{Model, Tab};
use flightdeck_dashboard::app::motion::MotionLevel;
use flightdeck_dashboard::app::theme::Theme;
use flightdeck_dashboard::app::view;
use flightdeck_dashboard::fixtures;
use ratatui::backend::TestBackend;
use ratatui::Terminal;
use serde_json::Value;

pub const SNAPSHOT_WIDTH: u16 = 200;
pub const SNAPSHOT_HEIGHT: u16 = 60;
pub const SESSION: &str = "test-fd";

pub fn fixed_now() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 5, 15, 10, 10, 0)
        .single()
        .expect("fixed timestamp is valid")
}

pub fn model_for_fixture(name: &'static str, motion: MotionLevel) -> Model {
    let snapshot = fixtures::load_demo_snapshot(name, fixed_now()).expect("fixture loads");
    let mut model = Model::new(
        snapshot,
        SnapshotSource::Demo(name),
        motion,
        Theme::Moon,
        fixed_now,
    );
    model.current_pane_id = None;
    model
}

pub fn model_for_tab(tab: Tab) -> Model {
    let mut model = model_for_fixture("mixed", MotionLevel::Off);
    model.current_tab = tab;
    model
}

pub fn render_model(model: &Model) -> String {
    render_model_with_size(model, SNAPSHOT_WIDTH, SNAPSHOT_HEIGHT)
}

pub fn render_model_with_size(model: &Model, width: u16, height: u16) -> String {
    let backend = TestBackend::new(width, height);
    let mut terminal = Terminal::new(backend).expect("test backend creates terminal");
    terminal
        .draw(|frame| view::render(frame, model))
        .expect("render succeeds");
    format!("{}", terminal.backend())
}

pub fn launch_command_without_daemon(path: &str, runtime_dir: &Path, project: &Path) -> Command {
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

pub fn path_with_bin(bin_dir: &Path) -> String {
    format!(
        "{}:{}",
        bin_dir.display(),
        std::env::var("PATH").unwrap_or_default()
    )
}

pub fn read_dashboard_entry(path: &Path) -> Result<Value, Box<dyn Error>> {
    let value = serde_json::from_str::<Value>(&std::fs::read_to_string(path)?)?;
    Ok(value
        .pointer("/entries/flightdeck-dashboard")
        .cloned()
        .ok_or("dashboard entry missing")?)
}

pub fn write_state_with_target(
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

pub fn write_fake_tmux(dir: &Path, windows_file: &Path) -> Result<PathBuf, Box<dyn Error>> {
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

pub fn write_capturing_flightdeck_session(
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

pub fn make_executable(path: &Path) -> Result<(), Box<dyn Error>> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(path)?.permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(path, perms)?;
    }
    Ok(())
}

pub fn dashboard_bin() -> &'static str {
    env!("CARGO_BIN_EXE_flightdeck-dashboard")
}
