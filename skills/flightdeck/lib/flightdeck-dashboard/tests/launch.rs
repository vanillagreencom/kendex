use std::error::Error;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;
use sha2::{Digest, Sha256};

mod common;

use common::{
    dashboard_bin, launch_command_without_daemon, make_executable, path_with_bin,
    read_dashboard_entry, write_capturing_flightdeck_session, write_fake_tmux,
    write_state_with_target, SESSION,
};

const SESSION_KEY: &str = "s42";

fn write_settings(project: &Path, store_root: &Path, contents: &str) -> Result<(), Box<dyn Error>> {
    let root_hash = hex_sha256(&project.display().to_string());
    let identity_hash = hex_sha256(&root_hash);
    let suffix = &identity_hash[..16];
    let path = store_root
        .join("projects")
        .join(format!("project-{suffix}"))
        .join("settings.toml");
    std::fs::create_dir_all(path.parent().expect("settings parent"))?;
    std::fs::write(&path, contents)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

fn hex_sha256(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    format!("{:x}", hasher.finalize())
}

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
fn focus_or_launch_without_tmux_returns_blocked_json() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let output = Command::new(dashboard_bin())
        .args(["focus-or-launch", "--json"])
        .env_remove("TMUX")
        .env("FD_STATE_DIR", temp.path().join("runtime"))
        .env("FLIGHTDECK_STATE_DIR", temp.path().join("state"))
        .env("FLIGHTDECK_DASHBOARD", "1")
        .output()?;

    assert!(!output.status.success());
    let report: Value = serde_json::from_slice(&output.stdout)?;
    assert_eq!(report["status"], "blocked");
    assert!(report["reason"]
        .as_str()
        .expect("reason")
        .contains("not in tmux"));
    Ok(())
}

#[test]
fn focus_or_launch_focuses_existing_tracked_dashboard() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(project.join("tmp"))?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let state_file = project.join("tmp/flightdeck-state-test-fd.json");
    write_state_with_target(&state_file, "%99", "@99")?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    let select_log = temp.path().join("tmux-select-log");
    write_fake_tmux_with_select_log(&bin_dir, &windows_file, &select_log)?;
    let capture = temp.path().join("session-args");
    let flightdeck_session = bin_dir.join("flightdeck-session");
    write_capturing_flightdeck_session(&flightdeck_session, &capture)?;
    let path = path_with_bin(&bin_dir);

    let output = Command::new(dashboard_bin())
        .current_dir(&project)
        .args(["focus-or-launch", "--session", SESSION, "--json"])
        .env("PATH", path)
        .env("TMUX", "/tmp/fake-tmux")
        .env("FD_STATE_DIR", temp.path().join("runtime"))
        .env("FLIGHTDECK_DASHBOARD", "1")
        .env("FLIGHTDECK_SESSION_BIN", &flightdeck_session)
        .output()?;

    assert!(
        output.status.success(),
        "focus failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let report: Value = serde_json::from_slice(&output.stdout)?;
    assert_eq!(report["status"], "focused");
    assert_eq!(report["pane"], "%99");
    assert_eq!(report["window"], "@99");
    let log = std::fs::read_to_string(select_log)?;
    assert!(
        log.contains("select-window -t @99"),
        "missing window focus: {log}"
    );
    assert!(
        log.contains("select-pane -t %99"),
        "missing pane focus: {log}"
    );
    assert!(!capture.exists(), "existing dashboard must not relaunch");
    Ok(())
}

#[test]
fn focus_or_launch_relaunches_stale_tracked_dashboard() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(project.join("tmp"))?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let state_file = project.join("tmp/flightdeck-state-test-fd.json");
    write_state_with_target(&state_file, "%dead", "@dead")?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    let select_log = temp.path().join("tmux-select-log");
    write_fake_tmux_stale_then_select(&bin_dir, &windows_file, &select_log)?;
    let capture = temp.path().join("session-args");
    let flightdeck_session = bin_dir.join("flightdeck-session");
    write_capturing_flightdeck_session(&flightdeck_session, &capture)?;
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
        .output()?;

    assert!(
        output.status.success(),
        "focus-or-launch failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let report: Value = serde_json::from_slice(&output.stdout)?;
    assert_eq!(report["status"], "launched");
    assert_eq!(report["pane"], "%99");
    assert!(capture.exists(), "stale dashboard should relaunch");
    let log = std::fs::read_to_string(select_log)?;
    assert!(
        log.contains("select-window -t @99"),
        "missing focus after relaunch: {log}"
    );
    Ok(())
}

#[test]
fn focus_or_launch_preserves_stale_probe_diagnostics_in_json_error() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(project.join("tmp"))?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let state_file = project.join("tmp/flightdeck-state-test-fd.json");
    write_state_with_target(&state_file, "%dead", "@dead")?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    let select_log = temp.path().join("tmux-select-log");
    write_fake_tmux_stale_then_select(&bin_dir, &windows_file, &select_log)?;
    let capture = temp.path().join("session-args");
    let flightdeck_session = bin_dir.join("flightdeck-session");
    write_failing_flightdeck_session(&flightdeck_session, &capture)?;
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
        .output()?;

    assert!(!output.status.success());
    let report: Value = serde_json::from_slice(&output.stdout)?;
    assert_eq!(report["status"], "error");
    assert!(report["reason"]
        .as_str()
        .expect("reason")
        .contains("stale tracked-entry probe"));
    assert!(report["path"]
        .as_str()
        .expect("path")
        .ends_with("flightdeck-state-test-fd.json"));
    assert!(report["command"]
        .as_str()
        .expect("command")
        .contains("tmux display-message"));
    let stderr = report["stderr"].as_str().expect("stderr");
    assert!(
        stderr.contains("stale pane is gone"),
        "missing stale stderr: {stderr}"
    );
    assert!(
        stderr.contains("session launch boom"),
        "missing launch stderr: {stderr}"
    );
    Ok(())
}

#[test]
fn focus_or_launch_preserves_stale_probe_diagnostics_in_plain_error() -> Result<(), Box<dyn Error>>
{
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(project.join("tmp"))?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let state_file = project.join("tmp/flightdeck-state-test-fd.json");
    write_state_with_target(&state_file, "%dead", "@dead")?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    let select_log = temp.path().join("tmux-select-log");
    write_fake_tmux_stale_then_select(&bin_dir, &windows_file, &select_log)?;
    let capture = temp.path().join("session-args");
    let flightdeck_session = bin_dir.join("flightdeck-session");
    write_failing_flightdeck_session(&flightdeck_session, &capture)?;
    let path = path_with_bin(&bin_dir);

    let output = Command::new(dashboard_bin())
        .current_dir(&project)
        .args(["focus-or-launch", "--session", SESSION, "--no-daemon"])
        .env("PATH", path)
        .env("TMUX", "/tmp/fake-tmux")
        .env("FD_STATE_DIR", temp.path().join("runtime"))
        .env("FLIGHTDECK_DASHBOARD", "1")
        .env("FLIGHTDECK_SESSION_BIN", &flightdeck_session)
        .output()?;

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("stale tracked-entry probe"),
        "missing stale reason: {stderr}"
    );
    assert!(
        stderr.contains("flightdeck-state-test-fd.json"),
        "missing path: {stderr}"
    );
    assert!(
        stderr.contains("tmux display-message"),
        "missing command: {stderr}"
    );
    assert!(
        stderr.contains("stale pane is gone"),
        "missing stale stderr: {stderr}"
    );
    assert!(
        stderr.contains("session launch boom"),
        "missing launch stderr: {stderr}"
    );
    Ok(())
}

#[test]
fn focus_or_launch_rejects_reused_pane_window_mismatch() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(project.join("tmp"))?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let state_file = project.join("tmp/flightdeck-state-test-fd.json");
    write_state_with_target(&state_file, "%99", "@dead")?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    let select_log = temp.path().join("tmux-select-log");
    write_fake_tmux_with_select_log(&bin_dir, &windows_file, &select_log)?;
    let capture = temp.path().join("session-args");
    let flightdeck_session = bin_dir.join("flightdeck-session");
    write_capturing_flightdeck_session(&flightdeck_session, &capture)?;
    let path = path_with_bin(&bin_dir);

    let output = Command::new(dashboard_bin())
        .current_dir(&project)
        .args(["focus-or-launch", "--session", SESSION, "--json"])
        .env("PATH", path)
        .env("TMUX", "/tmp/fake-tmux")
        .env("FD_STATE_DIR", temp.path().join("runtime"))
        .env("FLIGHTDECK_DASHBOARD", "1")
        .env("FLIGHTDECK_SESSION_BIN", &flightdeck_session)
        .output()?;

    assert!(!output.status.success());
    let report: Value = serde_json::from_slice(&output.stdout)?;
    assert_eq!(report["status"], "error");
    assert!(report["reason"]
        .as_str()
        .expect("reason")
        .contains("window mismatch"));
    assert!(report["path"]
        .as_str()
        .expect("path")
        .ends_with("flightdeck-state-test-fd.json"));
    assert!(report["command"]
        .as_str()
        .expect("command")
        .contains("tmux display-message"));
    assert!(!capture.exists(), "identity mismatch must not relaunch");
    assert!(!select_log.exists(), "identity mismatch must not focus");
    Ok(())
}

#[test]
fn focus_or_launch_rejects_identity_mismatch_after_launch() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(project.join("tmp"))?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    write_fake_tmux_launch_identity_mismatch(&bin_dir, &windows_file)?;
    let capture = temp.path().join("session-args");
    let flightdeck_session = bin_dir.join("flightdeck-session");
    write_capturing_flightdeck_session(&flightdeck_session, &capture)?;
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
        .output()?;

    assert!(!output.status.success());
    let report: Value = serde_json::from_slice(&output.stdout)?;
    assert_eq!(report["status"], "error");
    let reason = report["reason"].as_str().expect("reason");
    assert!(
        reason.contains("identity mismatch"),
        "missing identity mismatch: {reason}"
    );
    assert!(
        reason.contains("tmux display-message"),
        "missing probe command: {reason}"
    );
    assert!(
        capture.exists(),
        "launch should have been attempted before mismatch"
    );
    Ok(())
}

#[test]
fn focus_or_launch_surfaces_malformed_state_without_launching() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(project.join("tmp"))?;
    std::fs::write(project.join("vstack.toml"), "")?;
    std::fs::write(
        project.join("tmp/flightdeck-state-test-fd.json"),
        "{not json",
    )?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    write_fake_tmux(&bin_dir, &windows_file)?;
    let capture = temp.path().join("session-args");
    let flightdeck_session = bin_dir.join("flightdeck-session");
    write_capturing_flightdeck_session(&flightdeck_session, &capture)?;
    let path = path_with_bin(&bin_dir);

    let output = Command::new(dashboard_bin())
        .current_dir(&project)
        .args(["focus-or-launch", "--session", SESSION, "--json"])
        .env("PATH", path)
        .env("TMUX", "/tmp/fake-tmux")
        .env("FD_STATE_DIR", temp.path().join("runtime"))
        .env("FLIGHTDECK_DASHBOARD", "1")
        .env("FLIGHTDECK_SESSION_BIN", &flightdeck_session)
        .output()?;

    assert!(!output.status.success());
    let report: Value = serde_json::from_slice(&output.stdout)?;
    assert_eq!(report["status"], "error");
    assert!(report["reason"]
        .as_str()
        .expect("reason")
        .contains("failed to parse dashboard state JSON"));
    assert!(report["path"]
        .as_str()
        .expect("path")
        .ends_with("flightdeck-state-test-fd.json"));
    assert!(
        !capture.exists(),
        "malformed state must not launch duplicate app"
    );
    Ok(())
}

#[test]
fn focus_or_launch_refuses_untracked_same_name_window() -> Result<(), Box<dyn Error>> {
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

    let output = Command::new(dashboard_bin())
        .current_dir(&project)
        .args([
            "focus-or-launch",
            "--session",
            SESSION,
            "--json",
            "--window-name",
            "flightdeck-test",
        ])
        .env("PATH", path)
        .env("TMUX", "/tmp/fake-tmux")
        .env("FD_STATE_DIR", temp.path().join("runtime"))
        .env("FLIGHTDECK_DASHBOARD", "1")
        .env("FLIGHTDECK_SESSION_BIN", &flightdeck_session)
        .output()?;

    assert!(!output.status.success());
    let report: Value = serde_json::from_slice(&output.stdout)?;
    assert_eq!(report["status"], "error");
    assert!(report["reason"]
        .as_str()
        .expect("reason")
        .contains("refusing duplicate launch"));
    assert!(
        !capture.exists(),
        "untracked existing app must not duplicate"
    );
    Ok(())
}

#[test]
fn focus_or_launch_dashboard_self_launch_sets_active_run_skip_markers() -> Result<(), Box<dyn Error>>
{
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(&project)?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    write_fake_tmux(&bin_dir, &windows_file)?;
    let capture = temp.path().join("session-args");
    let active_run = temp.path().join("active-run-created");
    let flightdeck_session = bin_dir.join("flightdeck-session");
    write_lifecycle_guarding_flightdeck_session(&flightdeck_session, &capture, &active_run)?;
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
        .output()?;

    assert!(
        output.status.success(),
        "focus-or-launch failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let args = std::fs::read_to_string(&capture)?;
    assert!(
        args.contains("--no-active-run"),
        "missing no-run flag: {args}"
    );
    assert!(
        args.contains("FLIGHTDECK_DASHBOARD_LAUNCHING=1"),
        "missing dashboard launch marker: {args}"
    );
    assert!(
        args.contains("FLIGHTDECK_SKIP_ACTIVE_RUN=1"),
        "missing active-run skip marker: {args}"
    );
    assert!(
        !active_run.exists(),
        "fake lifecycle should not create active run"
    );
    Ok(())
}

#[test]
fn launch_forwards_after_window_id_to_flightdeck_session() -> Result<(), Box<dyn Error>> {
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
        .arg("--after-window-id")
        .arg("@1")
        .output()?;

    assert!(
        output.status.success(),
        "launch failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let args = std::fs::read_to_string(capture)?;
    assert!(
        args.contains("--after-window-id\n@1\n"),
        "after-window-id not forwarded: {args}"
    );
    Ok(())
}

#[test]
fn launch_uses_icon_window_title_by_default() -> Result<(), Box<dyn Error>> {
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

    let output = launch_command_default_window(&path, &temp.path().join("runtime"), &project)
        .env("FLIGHTDECK_SESSION_BIN", &flightdeck_session)
        .output()?;

    assert!(
        output.status.success(),
        "launch failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        std::fs::read_to_string(capture)?.contains("--title\n FD\n"),
        "default icon title not forwarded"
    );
    Ok(())
}

#[test]
fn launch_window_icon_zero_uses_plain_fd_default() -> Result<(), Box<dyn Error>> {
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

    let output = launch_command_default_window(&path, &temp.path().join("runtime"), &project)
        .env("FLIGHTDECK_SESSION_BIN", &flightdeck_session)
        .env("FLIGHTDECK_DASHBOARD_WINDOW_ICON", "0")
        .output()?;

    assert!(
        output.status.success(),
        "launch failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let args = std::fs::read_to_string(capture)?;
    assert!(
        args.contains("--title\nFD\n"),
        "plain FD title not forwarded: {args}"
    );
    assert!(
        !args.contains(" FD"),
        "icon title should be disabled: {args}"
    );
    Ok(())
}

#[test]
fn startup_override_file_can_disable_dashboard_launch() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(project.join("tmp"))?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let store_root = temp.path().join("store");
    write_settings(&project, &store_root, "FLIGHTDECK_DASHBOARD = \"0\"\n")?;

    let output = Command::new(dashboard_bin())
        .current_dir(&project)
        .args(["launch", "--session", SESSION])
        .env_remove("TMUX")
        .env("FD_STATE_DIR", temp.path().join("runtime"))
        .env("FLIGHTDECK_DASHBOARD", "1")
        .env("FLIGHTDECK_RUN_STORE_ROOT", &store_root)
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
    let store_root = temp.path().join("store");
    write_settings(
        &project,
        &store_root,
        "FLIGHTDECK_DASHBOARD_THEME = \"pantera\"\nFLIGHTDECK_DASHBOARD_MOTION = \"off\"\n",
    )?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    write_fake_tmux(&bin_dir, &windows_file)?;
    let capture = temp.path().join("session-args");
    write_capturing_flightdeck_session(&bin_dir.join("flightdeck-session"), &capture)?;
    let path = path_with_bin(&bin_dir);

    let output = launch_command_without_daemon(&path, &temp.path().join("runtime"), &project)
        .env("FLIGHTDECK_RUN_STORE_ROOT", &store_root)
        .output()?;

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
    let store_root = temp.path().join("store");
    write_settings(
        &project,
        &store_root,
        "FLIGHTDECK_DASHBOARD_COST_POLL_SECS = \"0.5\"\n",
    )?;

    let output = Command::new(dashboard_bin())
        .current_dir(&project)
        .args(["tui", "--demo"])
        .env("FD_STATE_DIR", temp.path().join("runtime"))
        .env("FLIGHTDECK_RUN_STORE_ROOT", &store_root)
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
        stderr.contains("tmux window probe failed"),
        "stderr missing window-probe failure: {stderr}"
    );
    assert!(stderr.contains("tmux list-windows failed"));
    assert!(
        !capture.exists(),
        "flightdeck-session must not launch after probe failure"
    );
    Ok(())
}

#[test]
fn stale_same_name_window_refuses_duplicate_launch() -> Result<(), Box<dyn Error>> {
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

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("refusing duplicate launch"),
        "stderr missing duplicate guard: {stderr}"
    );
    assert!(
        !capture.exists(),
        "stale same-name window must not spawn another dashboard"
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
    std::fs::write(&windows_file, "")?;
    let select_log = temp.path().join("tmux-select-log");
    write_fake_tmux_stale_then_select(&bin_dir, &windows_file, &select_log)?;
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

#[test]
fn concurrent_launches_share_session_lock_and_do_not_duplicate_window() -> Result<(), Box<dyn Error>>
{
    let temp = tempfile::tempdir()?;
    let project = temp.path().join("project");
    std::fs::create_dir_all(&project)?;
    std::fs::write(project.join("vstack.toml"), "")?;
    let bin_dir = temp.path().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let windows_file = temp.path().join("tmux-windows");
    std::fs::write(&windows_file, "")?;
    write_fake_tmux(&bin_dir, &windows_file)?;
    let count_file = temp.path().join("session-count");
    let flightdeck_session = bin_dir.join("flightdeck-session");
    write_slow_counting_flightdeck_session(&flightdeck_session, &count_file, &windows_file)?;
    let path = path_with_bin(&bin_dir);
    let runtime_dir = temp.path().join("runtime");

    let first = launch_command_without_daemon(&path, &runtime_dir, &project)
        .env("FLIGHTDECK_SESSION_BIN", &flightdeck_session)
        .spawn()?;
    std::thread::sleep(std::time::Duration::from_millis(50));
    let second = launch_command_without_daemon(&path, &runtime_dir, &project)
        .env("FLIGHTDECK_SESSION_BIN", &flightdeck_session)
        .spawn()?;

    let first_output = first.wait_with_output()?;
    let second_output = second.wait_with_output()?;
    assert!(
        first_output.status.success(),
        "first launch failed: {}",
        String::from_utf8_lossy(&first_output.stderr)
    );
    assert!(
        second_output.status.success(),
        "second launch failed: {}",
        String::from_utf8_lossy(&second_output.stderr)
    );
    let launches = std::fs::read_to_string(&count_file)?;
    assert_eq!(
        launches.lines().count(),
        1,
        "concurrent launches should spawn one dashboard window: {launches}"
    );
    let entry = read_dashboard_entry(&project.join("tmp/flightdeck-state-test-fd.json"))?;
    assert_eq!(entry["pane_id"], "%99");
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

fn launch_command_default_window(path: &str, runtime_dir: &Path, project: &Path) -> Command {
    let mut command = Command::new(dashboard_bin());
    command
        .current_dir(project)
        .args(["launch", "--session", SESSION, "--no-daemon"])
        .env("PATH", path)
        .env("TMUX", "/tmp/fake-tmux")
        .env("FD_STATE_DIR", runtime_dir)
        .env("FLIGHTDECK_DASHBOARD", "1")
        .env_remove("FLIGHTDECK_SESSION_BIN")
        .env_remove("FLIGHTDECK_SKILL_DIR")
        .env_remove("FLIGHTDECK_DASHBOARD_WINDOW")
        .env_remove("FLIGHTDECK_DASHBOARD_WINDOW_ICON")
        .env_remove("FLIGHTDECK_DASHBOARD_MOTION")
        .env_remove("FLIGHTDECK_DAEMON_RUST")
        .env_remove("NO_MOTION")
        .env_remove("NO_COLOR");
    command
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

fn write_fake_tmux_with_select_log(
    dir: &Path,
    windows_file: &Path,
    select_log: &Path,
) -> Result<PathBuf, Box<dyn Error>> {
    let path = dir.join("tmux");
    std::fs::write(
        &path,
        format!(
            r##"#!/usr/bin/env bash
set -euo pipefail
windows={windows:?}
select_log={select_log:?}
if [[ "${{1:-}}" == "display-message" ]]; then
  args="$*"
  if [[ "$args" == *"#{{pane_id}}"* && "$args" == *"#{{window_id}}"* ]]; then echo -e '%99\t@99'; exit 0; fi
  if [[ "$args" == *"#{{session_id}}"* ]]; then echo '$42'; exit 0; fi
  if [[ "$args" == *"#S"* ]]; then echo '{SESSION}'; exit 0; fi
  if [[ "$args" == *"#{{pane_id}}"* ]]; then echo '%99'; exit 0; fi
  if [[ "$args" == *"#{{window_id}}"* ]]; then echo '@99'; exit 0; fi
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
if [[ "${{1:-}}" == "select-window" || "${{1:-}}" == "select-pane" ]]; then
  printf '%s\n' "$*" >> "$select_log"
  exit 0
fi
exit 0
"##,
            windows = windows_file.display(),
            select_log = select_log.display()
        ),
    )?;
    make_executable(&path)?;
    Ok(path)
}

fn write_fake_tmux_stale_then_select(
    dir: &Path,
    windows_file: &Path,
    select_log: &Path,
) -> Result<PathBuf, Box<dyn Error>> {
    let path = dir.join("tmux");
    std::fs::write(
        &path,
        format!(
            r##"#!/usr/bin/env bash
set -euo pipefail
windows={windows:?}
select_log={select_log:?}
if [[ "${{1:-}}" == "display-message" ]]; then
  args="$*"
  if [[ "$args" == *"%dead"* ]]; then echo 'stale pane is gone' >&2; exit 1; fi
  if [[ "$args" == *"#{{pane_id}}"* && "$args" == *"#{{window_id}}"* ]]; then echo -e '%99\t@99'; exit 0; fi
  if [[ "$args" == *"#{{session_id}}"* ]]; then echo '$42'; exit 0; fi
  if [[ "$args" == *"#S"* ]]; then echo '{SESSION}'; exit 0; fi
  if [[ "$args" == *"#{{pane_id}}"* ]]; then echo '%99'; exit 0; fi
  if [[ "$args" == *"#{{window_id}}"* ]]; then echo '@99'; exit 0; fi
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
if [[ "${{1:-}}" == "select-window" || "${{1:-}}" == "select-pane" ]]; then
  printf '%s\n' "$*" >> "$select_log"
  exit 0
fi
exit 0
"##,
            windows = windows_file.display(),
            select_log = select_log.display()
        ),
    )?;
    make_executable(&path)?;
    Ok(path)
}

fn write_fake_tmux_launch_identity_mismatch(
    dir: &Path,
    windows_file: &Path,
) -> Result<PathBuf, Box<dyn Error>> {
    let path = dir.join("tmux");
    std::fs::write(
        &path,
        format!(
            r##"#!/usr/bin/env bash
set -euo pipefail
windows={windows:?}
if [[ "${{1:-}}" == "display-message" ]]; then
  args="$*"
  if [[ "$args" == *"%99"* ]]; then echo -e '%77\t@77\t{SESSION}\tflightdeck-test\t/tmp/wrong-dashboard'; exit 0; fi
  if [[ "$args" == *"#{{session_id}}"* ]]; then echo '$42'; exit 0; fi
  if [[ "$args" == *"#S"* ]]; then echo '{SESSION}'; exit 0; fi
  if [[ "$args" == *"#{{pane_id}}"* ]]; then echo '%99'; exit 0; fi
  if [[ "$args" == *"#{{window_id}}"* ]]; then echo '@99'; exit 0; fi
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
if [[ "${{1:-}}" == "select-window" || "${{1:-}}" == "select-pane" ]]; then
  echo 'must not focus mismatched dashboard' >&2
  exit 9
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

fn write_failing_flightdeck_session(
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
echo 'session launch boom' >&2
exit 23
"##,
            capture = capture_file.display()
        ),
    )?;
    make_executable(path)?;
    Ok(path.to_path_buf())
}

fn write_lifecycle_guarding_flightdeck_session(
    path: &Path,
    capture_file: &Path,
    active_run_file: &Path,
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
active_run={active_run:?}
{{
  printf '%s\n' "$@"
  printf 'FLIGHTDECK_DASHBOARD_LAUNCHING=%s\n' "${{FLIGHTDECK_DASHBOARD_LAUNCHING:-}}"
  printf 'FLIGHTDECK_SKIP_ACTIVE_RUN=%s\n' "${{FLIGHTDECK_SKIP_ACTIVE_RUN:-}}"
  printf 'FLIGHTDECK_NO_ACTIVE_RUN=%s\n' "${{FLIGHTDECK_NO_ACTIVE_RUN:-}}"
}} > "$capture"
args=" $* "
if [[ "${{FLIGHTDECK_SKIP_ACTIVE_RUN:-0}}" != "1" || "$args" != *" --no-active-run "* ]]; then
  printf 'created\n' > "$active_run"
fi
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
            capture = capture_file.display(),
            active_run = active_run_file.display()
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

fn write_slow_counting_flightdeck_session(
    path: &Path,
    count_file: &Path,
    windows_file: &Path,
) -> Result<PathBuf, Box<dyn Error>> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(
        path,
        format!(
            r##"#!/usr/bin/env bash
set -euo pipefail
count_file={count:?}
windows={windows:?}
printf 'launch\n' >> "$count_file"
sleep 0.25
title="flightdeck-test"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) title="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$title" >> "$windows"
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
            count = count_file.display(),
            windows = windows_file.display()
        ),
    )?;
    make_executable(path)?;
    Ok(path.to_path_buf())
}
