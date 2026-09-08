//! The generated hook preserves the CLI report protocol, identifies its own
//! notices by stable keys, and never blocks a session.
#![cfg(unix)]

use std::fs;
use std::path::Path;

use kendex_core::drift;

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

/// Run the actual generated script with a private CLI stub.
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

type HookCase = (
    &'static str,
    &'static str,
    &'static [(&'static str, &'static str)],
    Option<&'static str>,
    Option<&'static str>,
    &'static str,
);

const CASES: &[HookCase] = &[
    (
        "disabled",
        "{}",
        &[("KENDEX_DRIFT_HOOK", "off")],
        None,
        None,
        "",
    ),
    (
        "resume",
        r#"{"source":"resume"}"#,
        &[],
        Some("#!/bin/sh\necho drift\nexit 1\n"),
        None,
        "",
    ),
    (
        "compact",
        r#"{"source":"compact"}"#,
        &[],
        Some("#!/bin/sh\necho drift\nexit 1\n"),
        None,
        "",
    ),
    (
        "reload",
        r#"{"source":"reload"}"#,
        &[],
        Some("#!/bin/sh\necho drift\nexit 1\n"),
        None,
        "",
    ),
    (
        "unavailable",
        "{}",
        &[],
        None,
        Some("kendex-drift-unavailable: command=kendex"),
        "",
    ),
    (
        "empty failure",
        "{}",
        &[],
        Some("#!/bin/sh\nexit 2\n"),
        Some("kendex-drift-failed: exit=2"),
        "",
    ),
    (
        "CLI failure",
        "{}",
        &[],
        Some("#!/bin/sh\necho 'Error: loading lock file' >&2\nexit 2\n"),
        Some("kendex-drift-failed: exit=2"),
        "Error: loading lock file\n",
    ),
    (
        "incomplete",
        "{}",
        &[],
        Some("#!/bin/sh\nprintf 'stale:\\n  x\\ncould not check:\\n  lock: bad\\n'\nexit 2\n"),
        Some("kendex-drift-incomplete: exit=2"),
        "stale:\n  x\ncould not check:\n  lock: bad\n",
    ),
    (
        "unexpected exit",
        "{}",
        &[],
        Some("#!/bin/sh\necho fatal\nexit 3\n"),
        Some("kendex-drift-failed: exit=3"),
        "fatal\n",
    ),
    (
        "empty unexpected exit",
        "{}",
        &[],
        Some("#!/bin/sh\nexit 3\n"),
        Some("kendex-drift-failed: exit=3"),
        "",
    ),
    (
        "drift relay",
        r#"{"source":"startup"}"#,
        &[],
        Some("#!/bin/sh\necho 'stale:'\nexit 1\n"),
        None,
        "stale:\n",
    ),
    ("clean", "{}", &[], Some("#!/bin/sh\nexit 0\n"), None, ""),
    (
        "clean stderr",
        "{}",
        &[],
        Some("#!/bin/sh\necho noise >&2\nexit 0\n"),
        None,
        "",
    ),
    (
        "error inside report",
        "{}",
        &[],
        Some(
            "#!/bin/sh\nprintf 'could not check:\\n  source github.com/x/y unreachable since 2026-08-01: error: cannot lock ref\\n'\nexit 2\n",
        ),
        Some("kendex-drift-incomplete: exit=2"),
        "could not check:\n  source github.com/x/y unreachable since 2026-08-01: error: cannot lock ref\n",
    ),
];

#[test]
#[allow(clippy::unwrap_used)]
fn the_hook_script_honors_its_contract() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = rooted(&tmp);

    // A notice has a key line, an unpinned explanation line, and the CLI
    // report. Without a notice, the complete output is relayed CLI data.
    for &(name, input, env, stub, key, report) in CASES {
        let (out, code) = run_hook(&dir, input, env, stub);
        let observed = match key {
            Some(_) => {
                let (first, rest) = out.split_once('\n').unwrap();
                let (_, payload) = rest.split_once('\n').unwrap();
                (Some(first), payload, code)
            }
            None => (None, out.as_str(), code),
        };
        assert_eq!(observed, (key, report, 0), "{name}: {out}");
    }
}
