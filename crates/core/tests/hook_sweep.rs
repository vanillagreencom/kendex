//! What the orphan sweep may take of a hook's installation. An anchored
//! record proves its bytes and holds an edit; a record from before the
//! anchor proves nothing and, outside pi, holds nothing — reading "no
//! anchor" as "hands off" would exempt every older install from cleanup
//! for good.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::{PlanOptions, audit, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

const GUARD: &str = "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: check shell commands\n# ---\nexit 0\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let source = home.join("catalog");
    fs::create_dir_all(source.join("hooks")).unwrap();
    fs::write(source.join("hooks/guard.sh"), GUARD).unwrap();
    fs::write(source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[hooks.guard]\nsource = \"cat\"\n",
            source_path(&source)
        ),
    )
    .unwrap();

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

/// Take the hook's declaration out of the manifest: nothing asks for it
/// any more, and its record is all that is left of it.
#[allow(clippy::unwrap_used)]
fn undeclare(f: &Fixture) {
    let manifest = f.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    let kept: String = text
        .split_inclusive("\n\n")
        .filter(|block| !block.starts_with("[hooks."))
        .collect();
    fs::write(&manifest, kept).unwrap();
}

#[allow(clippy::unwrap_used)]
fn sweep(f: &Fixture) -> kendex_core::engine::EngineReport {
    plan_apply(
        &f.env,
        &f.scope,
        &PlanOptions {
            remove_orphans: true,
            sweep_unneeded: true,
            ..PlanOptions::default()
        },
    )
    .unwrap()
}

/// An anchored record still proves its bytes before the sweep takes
/// them: an edited script is the person's work and holds as a conflict,
/// exactly as an edited skill or agent would, while an untouched one
/// goes. The anchor-less exemption below is for records that cannot
/// prove anything, never a license to take what a record disproves.
#[test]
#[allow(clippy::unwrap_used)]
fn the_sweep_proves_an_anchored_hook_before_taking_it() {
    for state in ["edited", "untouched"] {
        let f = fixture();
        apply_now(&f);
        let script = f.project.join(".claude/hooks/guard.sh");
        assert!(script.is_file());
        if state == "edited" {
            fs::write(&script, GUARD.replace("exit 0", "exit 1")).unwrap();
        }

        undeclare(&f);
        let report = sweep(&f);
        apply::execute(&f.env, &report.plan).unwrap();

        match state {
            "edited" => {
                assert!(
                    report.drift.iter().any(|row| row.detail.contains("edited")),
                    "their edit is a conflict, not a casualty: {:?}",
                    report.drift
                );
                assert!(script.is_file(), "and the edited script stays");
            }
            _ => {
                assert!(
                    report
                        .drift
                        .iter()
                        .all(|row| !row.detail.contains("edited")),
                    "untouched bytes are provably ours: {:?}",
                    report.drift
                );
                assert!(!script.exists(), "so the sweep takes them");
            }
        }
    }
}

/// A record from before hooks carried an anchor names no rendered hash
/// and no registration. The sweep still takes what that record installed:
/// only pi's reserved-name move derives paths its record never wrote and
/// so must prove every byte first, and reading "no anchor" as "hands off"
/// would quietly exempt every older hook install from cleanup for good.
#[test]
#[allow(clippy::unwrap_used)]
fn the_sweep_takes_a_hook_whose_record_has_no_anchor() {
    let f = fixture();
    apply_now(&f);
    let script = f.project.join(".claude/hooks/guard.sh");
    assert!(script.is_file());

    // The lock as an older kendex left it: the entry, minus the fields
    // later versions anchor ownership with.
    let lock_path = f.project.join(".kendex-lock.json");
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&lock_path).unwrap()).unwrap();
    let entry = lock["entries"]["hook:guard:claude"]
        .as_object_mut()
        .unwrap();
    entry.remove("renderedHash");
    entry.remove("registration");
    fs::write(&lock_path, serde_json::to_string_pretty(&lock).unwrap()).unwrap();

    undeclare(&f);
    let report = sweep(&f);
    assert!(
        report
            .drift
            .iter()
            .all(|row| !row.detail.contains("edited")),
        "an anchor-less record is not an edit: {:?}",
        report.drift
    );
    apply::execute(&f.env, &report.plan).unwrap();

    assert!(!script.exists(), "the sweep takes the script");
    let after = fs::read_to_string(f.project.join(".claude/settings.json")).unwrap();
    assert!(
        !after.contains("guard.sh"),
        "and nothing is left registered to run it: {after}"
    );
}
