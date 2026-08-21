//! What removal leaves behind, when the registration is no longer where
//! kendex put it. A script and the entry that runs it go together or not
//! at all: an entry outliving its script points at a path with nothing at
//! it, and the tool runs it anyway.
#![cfg(unix)]

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::{PlanOptions, audit, ops, plan_apply};
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
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[hooks.guard]\nsource = \"cat\"\n",
            source.display()
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
    apply::execute(&f.env, &report.plan, None).unwrap();
}

/// The person moves the registration kendex wrote to another event, and
/// leaves the script where it is.
#[allow(clippy::unwrap_used)]
fn move_the_registration(f: &Fixture) -> PathBuf {
    let settings = f.project.join(".claude/settings.json");
    let text = fs::read_to_string(&settings).unwrap();
    let moved = text.replace("PreToolUse", "Stop");
    assert_ne!(moved, text, "the fixture has to move the event");
    fs::write(&settings, moved).unwrap();
    settings
}

/// Removal takes the registration wherever it has got to, because the
/// script goes with it. Named by the event the record kept, the edit
/// would find nothing and leave the entry running a file that is no
/// longer there.
#[test]
#[allow(clippy::unwrap_used)]
fn a_moved_registration_comes_out_with_the_script_it_names() {
    for asked in ["by name", "by nothing wanting it"] {
        let f = fixture();
        apply_now(&f);
        let script = f.project.join(".claude/hooks/guard.sh");
        assert!(script.is_file());
        let settings = move_the_registration(&f);

        let report = match asked {
            "by name" => ops::remove(&f.env, &f.scope, &["guard".to_owned()], None, false).unwrap(),
            _ => {
                let manifest = f.project.join("kendex.toml");
                let text = fs::read_to_string(&manifest).unwrap();
                let kept: String = text
                    .split_inclusive("\n\n")
                    .filter(|block| !block.starts_with("[hooks."))
                    .collect();
                fs::write(&manifest, kept).unwrap();
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
        };
        apply::execute(&f.env, &report.plan, None).unwrap();

        assert!(!script.exists(), "{asked}: the script goes");
        let after = fs::read_to_string(&settings).unwrap();
        assert!(
            !after.contains("guard.sh"),
            "{asked}: and nothing is left registered to run it: {after}"
        );
    }
}

/// Switching a hook off is a removal of the entry that is there — which
/// is not always the entry this pass would write. Change the event in the
/// same refresh that switches it off and the two part company: the
/// rendered removal names where the entry would go now, and what is
/// actually registered keeps running with nothing left naming it, since
/// the record is overwritten in the same breath.
///
/// Neither half shows this on its own, which is why it was invisible: a
/// disable alone and an event change alone both reconcile.
#[test]
#[allow(clippy::unwrap_used)]
fn switching_off_a_hook_whose_event_changed_leaves_nothing_registered() {
    let f = fixture();
    apply_now(&f);
    let settings = f.project.join(".claude/settings.json");
    assert!(
        fs::read_to_string(&settings)
            .unwrap()
            .contains("PreToolUse"),
        "it went in under the event the catalog then asked for"
    );

    // One refresh carrying both: the catalog moves the hook, and the
    // person switches it off.
    let source = f
        .project
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("catalog");
    fs::write(
        source.join("hooks/guard.sh"),
        GUARD.replace("# event: PreToolUse", "# event: Stop"),
    )
    .unwrap();
    let manifest = f.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace(
            "[hooks.guard]\nsource = \"cat\"\n",
            "[hooks.guard]\nsource = \"cat\"\nenabled = false\n",
        ),
    )
    .unwrap();

    apply_now(&f);

    let after = fs::read_to_string(&settings).unwrap();
    assert!(
        !after.contains("guard.sh"),
        "a hook switched off runs from nowhere: {after}"
    );
    assert!(
        f.project.join(".claude/hooks/guard.sh.disabled").is_file(),
        "its bytes are kept under the disabled name"
    );

    // And what is done is done.
    let settled = audit(&f.env, &f.scope).unwrap();
    assert!(settled.plan.ops.is_empty(), "{:?}", settled.plan.ops);
    assert!(settled.drift.is_empty(), "{:?}", settled.drift);
}
