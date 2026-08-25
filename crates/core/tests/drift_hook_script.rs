//! The session-start hook script's contract, exercised against /bin/sh:
//! every failure path emits exactly one line, resumed and compacted
//! sessions stay silent, and the hook never exits non-zero.
#![cfg(unix)]

use std::fs;
use std::path::Path;

use kendex_core::drift;

/// The hook script's contract, exercised against /bin/sh with a stub
/// `kendex` on PATH: every failure path emits exactly one line, and the
/// hook never exits non-zero.
#[allow(clippy::unwrap_used)]
fn run_hook(dir: &Path, stdin: &str, env: &[(&str, &str)], stub: Option<&str>) -> (String, i32) {
    use std::io::Write;
    let script = dir.join("hook.sh");
    fs::write(&script, drift::hook::HOOK_SCRIPT).unwrap();
    let bin = dir.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let stub_path = bin.join("kendex");
    let _ = fs::remove_file(&stub_path);
    if let Some(stub) = stub {
        fs::write(&stub_path, stub).unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&stub_path, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let mut child = std::process::Command::new("/bin/sh")
        .arg(&script)
        .env_clear()
        // The stub dir shadows the real PATH; the standard tools the hook
        // itself uses (cat) stay reachable, as they are under a harness.
        .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
        .envs(env.iter().copied())
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    // A hook that exits before reading stdin closes the pipe early; that
    // is the script's business, not a harness failure — the contract under
    // test is the output and exit code.
    match child.stdin.take().unwrap().write_all(stdin.as_bytes()) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::BrokenPipe => {}
        Err(error) => panic!("writing hook stdin: {error}"),
    }
    let output = child.wait_with_output().unwrap();
    (
        String::from_utf8_lossy(&output.stdout).into_owned(),
        output.status.code().unwrap_or(-1),
    )
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_hook_script_honors_its_contract() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();

    // Kill switch: silent, exit 0.
    let (out, code) = run_hook(dir, "{}", &[("KENDEX_DRIFT_HOOK", "off")], None);
    assert_eq!((out.as_str(), code), ("", 0));

    // Resumed and compacted sessions are skipped.
    let (out, code) = run_hook(
        dir,
        r#"{"source":"resume"}"#,
        &[],
        Some("#!/bin/sh\necho drift\nexit 1\n"),
    );
    assert_eq!((out.as_str(), code), ("", 0));
    let (out, code) = run_hook(
        dir,
        r#"{"source":"compact"}"#,
        &[],
        Some("#!/bin/sh\necho drift\nexit 1\n"),
    );
    assert_eq!((out.as_str(), code), ("", 0));
    // Pi's carrier re-runs extensions in place on reload — an already
    // delivered report must not repeat.
    let (out, code) = run_hook(
        dir,
        r#"{"source":"reload"}"#,
        &[],
        Some("#!/bin/sh\necho drift\nexit 1\n"),
    );
    assert_eq!((out.as_str(), code), ("", 0));

    // Missing binary: exactly one "skipped" line, exit 0.
    let (out, code) = run_hook(dir, "{}", &[], None);
    assert_eq!(out.lines().count(), 1, "{out}");
    assert!(out.contains("skipped"), "{out}");
    assert_eq!(code, 0);

    // A check that cannot run: exactly one "drift status unknown" line.
    let (out, code) = run_hook(dir, "{}", &[], Some("#!/bin/sh\nexit 2\n"));
    assert_eq!(out.lines().count(), 1, "{out}");
    assert!(out.contains("drift status unknown"), "{out}");
    assert_eq!(code, 0);

    // Drift: the report passes through, exit stays 0.
    let (out, code) = run_hook(
        dir,
        r#"{"source":"startup"}"#,
        &[],
        Some("#!/bin/sh\necho 'stale:'\nexit 1\n"),
    );
    assert_eq!((out.as_str(), code), ("stale:\n", 0));

    // Clean: silent.
    let (out, code) = run_hook(dir, "{}", &[], Some("#!/bin/sh\nexit 0\n"));
    assert_eq!((out.as_str(), code), ("", 0));
}
