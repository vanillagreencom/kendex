//! What the orphan sweep may take of a hook's installation. An anchored
//! record proves its bytes: an untouched script goes, an edited one holds
//! as a conflict. A record carrying no anchor proves nothing, and after
//! this build's version floor it is not an older install but a current
//! record this build cannot account for, so it holds too — on every
//! harness alike, because the rule is the anchor and not the harness.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::{DriftCause, PlanOptions, audit, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::lock::LOCK_VERSION;
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
    fixture_for(Harness::Claude)
}

/// The two harnesses whose hook layouts differ where the sweep looks: the
/// script's place, and the document its registration sits in. Pi is here
/// because it once had a rule of its own, and now has none.
#[derive(Clone, Copy)]
enum Harness {
    Claude,
    Pi,
}

impl Harness {
    fn declared(self) -> &'static str {
        match self {
            Harness::Claude => "claude",
            Harness::Pi => "pi",
        }
    }

    /// Where this harness's copy of the hook script lands, under a scope
    /// root — the path the sweep either takes or leaves.
    fn script(self, project: &std::path::Path) -> PathBuf {
        match self {
            Harness::Claude => project.join(".claude/hooks/guard.sh"),
            Harness::Pi => project.join(".pi/kendex/hooks/guard.sh"),
        }
    }

    /// The document its registration sits in.
    fn registry(self, project: &std::path::Path) -> PathBuf {
        match self {
            Harness::Claude => project.join(".claude/settings.json"),
            Harness::Pi => project.join(".pi/kendex/hooks.json"),
        }
    }

    fn lock_key(self) -> &'static str {
        match self {
            Harness::Claude => "hook:guard:claude",
            Harness::Pi => "hook:guard:pi",
        }
    }
}

#[allow(clippy::unwrap_used)]
fn fixture_for(harness: Harness) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    // Pi's hooks ride a carrier extension; without one registered the
    // install is advisory and the plan says so, which is noise here.
    fs::create_dir_all(project.join(".pi")).unwrap();
    fs::write(
        project.join(".pi/settings.json"),
        r#"{ "packages": ["./packages/@vanillagreen/pi-hooks"] }"#,
    )
    .unwrap();

    let source = home.join("catalog");
    fs::create_dir_all(source.join("hooks")).unwrap();
    fs::write(source.join("hooks/guard.sh"), GUARD).unwrap();
    fs::write(source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"{}\"]\nmethod = \"copy\"\n\n[hooks.guard]\nsource = \"cat\"\n",
            source_path(&source),
            harness.declared()
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
/// goes. This is the arm where a record can answer; the one below is
/// where it cannot.
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

/// A hook entry with no rendered hash and no registration, in a lock at
/// this build's own version. It is not an older record: the version floor
/// refuses a lock this build did not write, so one of those never reaches
/// the sweep. It is a current record that names no anchor, which proves
/// nothing about the bytes on disk — so the sweep leaves them, on pi as on
/// every other harness. A sweep that cannot prove the script is kendex's
/// must not trash it.
#[test]
#[allow(clippy::unwrap_used)]
fn the_sweep_holds_a_hook_whose_current_record_has_no_anchor() {
    for harness in [Harness::Claude, Harness::Pi] {
        let f = fixture_for(harness);
        apply_now(&f);
        let script = harness.script(&f.project);
        assert!(script.is_file(), "{}", script.display());
        // Read before the sweep, so the path below is proven to be the one
        // the registration is really in: unwrapping a wrong path to an
        // empty string would pass the after-check on nothing at all.
        let registry = harness.registry(&f.project);
        assert!(
            fs::read_to_string(&registry).unwrap().contains("guard.sh"),
            "{}",
            registry.display()
        );

        // Take the anchor out and leave the version alone. The record
        // stays one this build wrote and would read; what it no longer
        // does is say which bytes apply put on disk.
        let lock_path = f.project.join(".kendex-lock.json");
        let mut lock: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&lock_path).unwrap()).unwrap();
        let entry = lock["entries"][harness.lock_key()]
            .as_object_mut()
            .unwrap_or_else(|| panic!("no entry for {}", harness.lock_key()));
        assert!(
            entry.contains_key("renderedHash"),
            "the anchor must be there to take out: {entry:?}"
        );
        entry.remove("renderedHash");
        entry.remove("registration");
        assert_eq!(
            lock["version"],
            serde_json::json!(LOCK_VERSION),
            "this record is current, not old — an old one never reaches the sweep"
        );
        fs::write(&lock_path, serde_json::to_string_pretty(&lock).unwrap()).unwrap();

        undeclare(&f);
        let report = sweep(&f);
        assert!(
            report
                .drift
                .iter()
                .any(|row| matches!(row.cause, Some(DriftCause::LocalEdit))),
            "a record that cannot vouch for the bytes holds them: {:?}",
            report.drift
        );
        apply::execute(&f.env, &report.plan).unwrap();

        assert!(
            script.is_file(),
            "the sweep leaves the script: {}",
            script.display()
        );
        let after = fs::read_to_string(&registry).unwrap();
        assert!(
            after.contains("guard.sh"),
            "and leaves it registered to run: {after}"
        );
    }
}
