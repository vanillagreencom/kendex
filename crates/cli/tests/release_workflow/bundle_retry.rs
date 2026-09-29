//! The bundle step's one retry. Tauri's bundle_dmg.sh fails intermittently
//! on GitHub's macOS runners after the app is built, and a lane lost there
//! skips the main-channel publish. The step bundles a second time only when
//! tauri reports the failure as `error running bundle_dmg.sh`. Release.yml never runs on a pull
//! request, so here the real step runs against a stand-in `tauri` that
//! fails the way this test tells it to.

#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use super::{LANES, expand, run_script, step, workflow};
use crate::test_util::rooted;

/// Each call takes the next word of `$TAURI_PLAN` as its outcome: `ok`
/// writes a DMG, `dmg` leaves bundle_dmg.sh's scratch image behind and
/// fails the way tauri reports it, `sign` gets past bundle_dmg.sh and then
/// fails the way updater signing does, `compile` fails the way a Rust error
/// does. It runs from `crates/app`, as the real one does.
const STUB: &str = r#"#!/bin/sh
calls=$(cat "$TAURI_CALLS" 2>/dev/null || echo 0)
calls=$((calls + 1))
echo "$calls" > "$TAURI_CALLS"
echo "$PWD $*" >> "$TAURI_ARGS"
outcome=$(echo "$TAURI_PLAN" | cut -d' ' -f"$calls")
bundle="../../target/$TAURI_TARGET/release/bundle"
case "$outcome" in
  ok)
    mkdir -p "$bundle/dmg"
    echo "attempt $calls" > "$bundle/dmg/kendex.dmg"
    ;;
  dmg)
    mkdir -p "$bundle/macos"
    echo scratch > "$bundle/macos/rw.4242.kendex.dmg"
    echo "        Running bundle_dmg.sh (attempt $calls)"
    echo "failed to bundle project: error running bundle_dmg.sh" >&2
    exit 1
    ;;
  sign)
    mkdir -p "$bundle/dmg"
    echo "attempt $calls" > "$bundle/dmg/kendex.dmg"
    echo "        Running bundle_dmg.sh"
    echo "failed to bundle project: failed to sign updater archive (attempt $calls)" >&2
    exit 1
    ;;
  compile)
    echo "error[E0425]: cannot find value (attempt $calls)" >&2
    exit 101
    ;;
esac
"#;

struct Bundled {
    code: i32,
    calls: usize,
    said: String,
    bundle: Vec<String>,
}

/// Every file under `dir`, relative to it, sorted.
#[allow(clippy::unwrap_used)]
fn files_under(dir: &Path) -> Vec<String> {
    let mut found = Vec::new();
    let mut pending: Vec<PathBuf> = vec![dir.to_path_buf()];
    while let Some(next) = pending.pop() {
        let Ok(entries) = fs::read_dir(&next) else {
            continue;
        };
        for entry in entries {
            let path = entry.unwrap().path();
            if path.is_dir() {
                pending.push(path);
            } else {
                found.push(
                    path.strip_prefix(dir)
                        .unwrap()
                        .to_string_lossy()
                        .into_owned(),
                );
            }
        }
    }
    found.sort();
    found
}

/// Runs the real bundle step on a macOS lane with each `tauri` call
/// answering the next outcome in `plan`.
#[allow(clippy::unwrap_used)]
fn bundle(plan: &str) -> Bundled {
    let lane = LANES.iter().find(|lane| lane.runner_os == "macOS").unwrap();
    let dir = tempfile::tempdir().unwrap();
    let root = rooted(&dir);
    fs::create_dir_all(root.join("crates/app")).unwrap();
    let bin = root.join("ui/node_modules/.bin");
    fs::create_dir_all(&bin).unwrap();
    let tauri = bin.join("tauri");
    fs::write(&tauri, STUB).unwrap();
    let mut permissions = fs::metadata(&tauri).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&tauri, permissions).unwrap();
    let runner_temp = root.join("runner-temp");
    fs::create_dir(&runner_temp).unwrap();
    let calls = root.join("calls");
    let args = root.join("args");

    let workflow = workflow();
    let script = expand(
        &run_script(&step(&workflow, "name: Bundle the desktop app")),
        lane,
    );
    // GitHub runs a `shell: bash` step as `bash -eo pipefail`.
    let run = std::process::Command::new("bash")
        .args(["--noprofile", "--norc", "-eo", "pipefail", "-c", &script])
        .current_dir(&root)
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("RUNNER_TEMP", &runner_temp)
        .env("KENDEX_BUNDLE_OVERLAY", "release/macos.json")
        .env("TAURI_PLAN", plan)
        .env("TAURI_TARGET", lane.target)
        .env("TAURI_CALLS", &calls)
        .env("TAURI_ARGS", &args)
        .output()
        .unwrap();

    let invoked = fs::read_to_string(&args).unwrap_or_default();
    for line in invoked.lines() {
        assert_eq!(
            line,
            format!(
                "{} build --target {} --config release/macos.json",
                root.join("crates/app").display(),
                lane.target
            ),
            "tauri ran from the wrong directory or with the wrong arguments"
        );
    }
    Bundled {
        code: run.status.code().unwrap_or(-1),
        calls: invoked.lines().count(),
        said: format!(
            "{}{}",
            String::from_utf8_lossy(&run.stdout),
            String::from_utf8_lossy(&run.stderr)
        ),
        bundle: files_under(&root.join("target").join(lane.target).join("release/bundle")),
    }
}

/// Each row is a `$TAURI_PLAN`, the step's exit code, how many times it ran
/// tauri, and the files left in the bundle directory.
/// - `dmg ok`: a failed bundle_dmg.sh bundles once more, the step passes,
///   the first failure stays in the log, and the scratch image the failure
///   left is gone before staging could publish it.
/// - `compile ok`: a compile error is no runner flake; the step fails on it
///   at once, with tauri's own exit code.
/// - `sign ok`: a failure after bundle_dmg.sh ran, whose log still names it
///   in the `Running bundle_dmg.sh` line, fails at once too.
/// - `dmg dmg ok`: two bundle_dmg.sh failures fail the step, as one did
///   before the retry.
/// - `ok`: a clean bundle runs tauri once.
#[test]
fn the_bundle_step_retries_only_a_bundle_dmg_failure() {
    struct Row {
        plan: &'static str,
        code: i32,
        calls: usize,
        left: &'static [&'static str],
        logged: Option<&'static str>,
    }
    let rows = [
        Row {
            plan: "dmg ok",
            code: 0,
            calls: 2,
            left: &["dmg/kendex.dmg"],
            logged: Some("failed to bundle project: error running bundle_dmg.sh"),
        },
        Row {
            plan: "compile ok",
            code: 101,
            calls: 1,
            left: &[],
            logged: None,
        },
        Row {
            plan: "sign ok",
            code: 1,
            calls: 1,
            left: &["dmg/kendex.dmg"],
            logged: None,
        },
        Row {
            plan: "dmg dmg ok",
            code: 1,
            calls: 2,
            left: &["macos/rw.4242.kendex.dmg"],
            logged: None,
        },
        Row {
            plan: "ok",
            code: 0,
            calls: 1,
            left: &["dmg/kendex.dmg"],
            logged: None,
        },
    ];
    for Row {
        plan,
        code,
        calls,
        left,
        logged,
    } in rows
    {
        let run = bundle(plan);
        let bundle: Vec<&str> = run.bundle.iter().map(String::as_str).collect();
        assert_eq!(
            (run.code, run.calls, bundle.as_slice()),
            (code, calls, left),
            "plan `{plan}`: {}",
            run.said
        );
        if let Some(line) = logged {
            assert!(
                run.said.contains(line),
                "plan `{plan}`: the first attempt's failure left the log: {}",
                run.said
            );
        }
    }
}
