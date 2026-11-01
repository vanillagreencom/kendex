//! What removal leaves behind when the registration has moved from where
//! kendex put it. A script and the entry that runs it go together or not
//! at all: an entry outliving its script points at a path with nothing at
//! it, and the tool runs it anyway.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::PathBuf;

use kendex_core::apply::{self, Op};
use kendex_core::engine::{PlanOptions, audit, ops, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::lock::{ClaudeProjectDefault, load, lock_path};
use kendex_core::model::Scope;
use serde_json::json;

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
    let home = rooted(&tmp);
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
            "schema = 7\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[hooks.guard]\nsource = \"cat\"\n",
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

#[allow(clippy::unwrap_used)]
fn change_default_preserving_user_value(f: &Fixture, change: Option<bool>) {
    let settings = f.project.join(".claude/settings.json");
    let mut value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
    match change {
        Some(flag) => value["switchModelsOnFlag"] = json!(flag),
        None => {
            value
                .as_object_mut()
                .unwrap()
                .shift_remove("switchModelsOnFlag");
        }
    }
    fs::write(
        &settings,
        format!("{}\n", serde_json::to_string_pretty(&value).unwrap()),
    )
    .unwrap();
    let changed = audit(&f.env, &f.scope).unwrap();
    assert_eq!(
        changed.record.claude_project_default,
        Some(ClaudeProjectDefault::Released)
    );
    let observed = load(&lock_path(&f.env, &f.scope)).unwrap();
    let standing = kendex_core::attest::record(
        &f.env,
        &f.scope,
        &observed,
        &changed,
        &kendex_core::attest::Floor::Open,
    )
    .unwrap()
    .unwrap();
    assert_eq!(
        standing.problems.len(),
        usize::from(observed.claude_project_default == Some(ClaudeProjectDefault::Owned))
    );
    assert!(
        changed
            .plan
            .ops
            .iter()
            .all(|op| !matches!(&op.op, Op::EditFile {path, ..} if path == &settings))
    );
    apply::execute(&f.env, &changed.plan).unwrap();
    let written: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
    assert_eq!(written, value);
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

/// Plan descriptions are the approval text both CLI preview and apply report
/// render. The hook declaration produces both states; applying the real plan
/// must leave the script and registration in the state those lines describe.
#[test]
#[allow(clippy::unwrap_used)]
fn hook_plan_and_apply_report_describe_the_declared_switch() {
    for (installed, enabled, file_actions, registration_action) in [
        (
            false,
            true,
            &["Install hook guard for Claude Code"][..],
            "register guard",
        ),
        (
            false,
            false,
            &["Install disabled hook guard for Claude Code"][..],
            "unregister guard",
        ),
        (
            true,
            false,
            &[
                "Turn guard off",
                "Install disabled hook guard for Claude Code",
            ][..],
            "unregister guard",
        ),
    ] {
        let f = fixture();
        let settings = f.project.join(".claude/settings.json");
        let user_settings = json!({"permissions": {"allow": ["Read"]}});
        fs::write(&settings, user_settings.to_string()).unwrap();
        if installed {
            apply_now(&f);
        }
        let manifest = f.project.join("kendex.toml");
        let declared = fs::read_to_string(&manifest).unwrap();
        fs::write(&manifest, format!("{declared}enabled = {enabled}\n")).unwrap();

        let preview = plan_apply(&f.env, &f.scope, &PlanOptions::current()).unwrap();
        let report = audit(&f.env, &f.scope).unwrap();
        let lines = |plan: &apply::Plan| plan.ops.iter().map(|op| op.line()).collect::<Vec<_>>();
        assert_eq!(lines(&preview.plan), lines(&report.plan));

        let script = f.project.join(".claude/hooks/guard.sh");
        let disabled = f.project.join(".claude/hooks/guard.sh.disabled");
        let file_ops: Vec<_> = preview.plan.ops.iter().filter(|planned| {
            matches!(&planned.op, Op::WriteFile { path, .. } if path == &script || path == &disabled)
                || matches!(&planned.op, Op::Rename { from, to, .. } if from == &script && to == &disabled)
        }).collect();
        assert_eq!(
            file_ops.iter().map(|op| op.line()).collect::<Vec<_>>(),
            file_actions
        );
        for planned in &file_ops {
            match &planned.op {
                Op::WriteFile { path, .. } => {
                    assert_eq!(path, if enabled { &script } else { &disabled })
                }
                Op::Rename { from, to, .. } => {
                    assert_eq!(from, &script);
                    assert_eq!(to, &disabled);
                }
                _ => panic!("only hook file writes and toggles were selected"),
            }
        }
        let registration =
            preview.plan.ops.iter().find(
                |planned| matches!(&planned.op, Op::EditFile { path, .. } if path == &settings),
            );
        assert!(
            registration
                .unwrap()
                .line()
                .contains(&format!("({registration_action}"))
        );

        apply::execute(&f.env, &report.plan).unwrap();
        assert_eq!(script.is_file(), enabled);
        assert_eq!(disabled.is_file(), !enabled);
        let written: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
        assert_eq!(written["permissions"], user_settings["permissions"]);
        assert_eq!(written["hooks"]["PreToolUse"].is_array(), enabled);
        assert!(audit(&f.env, &f.scope).unwrap().plan.is_empty());
    }
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
                        ..PlanOptions::current()
                    },
                )
                .unwrap()
            }
        };
        apply::execute(&f.env, &report.plan).unwrap();

        assert!(!script.exists(), "{asked}: the script goes");
        // The entry was all the file held, so the removal retires it.
        assert!(
            !settings.exists(),
            "{asked}: the emptied settings file goes, and nothing is left registered to run it"
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

    // The entry was all the file held, so switching it off retires it.
    assert!(
        !settings.exists(),
        "a hook switched off runs from nowhere: its emptied settings file goes"
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

/// Retiring the entry a catalog moved takes kendex's own and nothing
/// else. A matcher names one group, and the person is free to register
/// the same command under a matcher of their own: retired by command and
/// event alone, theirs would go with kendex's, and they would never be
/// told.
#[test]
#[allow(clippy::unwrap_used)]
fn a_changed_matcher_retires_kendexs_entry_and_leaves_theirs() {
    let f = fixture();
    apply_now(&f);
    let settings = f.project.join(".claude/settings.json");
    let mut value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
    let command = value["hooks"]["PreToolUse"][0]["hooks"][0]["command"].clone();
    assert_eq!(value["hooks"]["PreToolUse"][0]["matcher"], "Bash");
    // Their own, under a matcher they chose, running the same script.
    value["hooks"]["PreToolUse"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::json!({
            "matcher": "Edit",
            "hooks": [{ "type": "command", "command": command.clone() }]
        }));
    fs::write(&settings, serde_json::to_string_pretty(&value).unwrap()).unwrap();

    // And the catalog moves kendex's to another matcher.
    let source = f
        .project
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("catalog");
    fs::write(
        source.join("hooks/guard.sh"),
        GUARD.replace("# matcher: Bash", "# matcher: Write"),
    )
    .unwrap();

    apply_now(&f);

    let value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
    let groups = value["hooks"]["PreToolUse"].as_array().unwrap();
    let matchers: Vec<&str> = groups
        .iter()
        .map(|group| group["matcher"].as_str().unwrap_or_default())
        .collect();
    assert!(
        matchers.contains(&"Edit"),
        "what they registered is theirs: {value}"
    );
    assert!(
        matchers.contains(&"Write"),
        "and kendex's went where the catalog now asks: {value}"
    );
    assert!(
        !matchers.contains(&"Bash"),
        "leaving nothing behind where it was: {value}"
    );
}

/// A hook that is only a registration comes out by the identity the
/// record kept, matcher included: the same command under a matcher the
/// person chose is their registration, and removing kendex's is not
/// removing theirs. A hook whose script goes too keeps the older
/// reach — an entry left naming a deleted script is the worse thing to
/// leave behind — and this is the line between the two.
#[test]
#[allow(clippy::unwrap_used)]
fn removing_a_command_bodied_hook_leaves_their_own_matcher_alone() {
    let f = fixture();
    let manifest = f.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace(
            "[hooks.guard]\nsource = \"cat\"\n",
            "[[custom-hooks]]\nname = \"mine\"\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"./scripts/mine.sh\"\nagents = \"all\"\n",
        ),
    )
    .unwrap();
    apply_now(&f);

    let settings = f.project.join(".claude/settings.json");
    let mut value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
    assert_eq!(value["hooks"]["PreToolUse"][0]["matcher"], "Bash");
    let command = value["hooks"]["PreToolUse"][0]["hooks"][0]["command"].clone();
    // Their own, running the same command under a matcher they chose.
    value["hooks"]["PreToolUse"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::json!({
            "matcher": "Edit",
            "hooks": [{ "type": "command", "command": command }]
        }));
    fs::write(&settings, serde_json::to_string_pretty(&value).unwrap()).unwrap();

    // Nothing declares it any more, and the sweep takes what it left.
    let text = fs::read_to_string(&manifest).unwrap();
    let kept: String = text
        .split_inclusive("\n\n")
        .filter(|block| !block.starts_with("[[custom-hooks]]"))
        .collect();
    fs::write(&manifest, kept).unwrap();
    let report = plan_apply(
        &f.env,
        &f.scope,
        &PlanOptions {
            remove_orphans: true,
            sweep_unneeded: true,
            ..PlanOptions::current()
        },
    )
    .unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    let value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
    let groups = value["hooks"]["PreToolUse"].as_array().unwrap();
    let matchers: Vec<&str> = groups
        .iter()
        .map(|group| group["matcher"].as_str().unwrap_or_default())
        .collect();
    assert_eq!(
        matchers,
        vec!["Edit"],
        "kendex's own entry goes and theirs stays: {value}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn hook_removal_trashes_generated_settings_and_preserves_user_keys() {
    const RETAINED: &str = ".opencode/instructions/kendex-hook-retained.md";
    for (retained_event, user_permission) in [
        (None, None),
        (None, Some(json!("deny"))),
        (Some("Stop"), None),
        (Some("PreToolUse"), None),
    ] {
        let f = fixture();
        let root = &f.project;
        fs::write(f.env.home.join("catalog/hooks/retained.sh"), format!("#!/bin/sh\n# ---\n# name: retained\n# event: {}\n# matcher: Bash\n# description: check shell commands\n# ---\nexit 0\n", retained_event.unwrap_or("Stop"))).unwrap();
        fs::write(root.join("kendex.toml"), format!("schema = 7\n[sources.cat]\n{}\n[install]\nharnesses = [\"opencode\"]\n[hooks.guard]\nsource = \"cat\"\n[hooks.retained]\nsource = \"cat\"\n", source_path(&f.env.home.join("catalog")))).unwrap();
        apply_now(&f);
        let config = root.join("opencode.json");
        let mut value: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&config).unwrap()).unwrap();
        assert_eq!(value["permission"]["bash"], json!({"*": "ask"}));
        if let Some(permission) = &user_permission {
            value["permission"]["bash"] = permission.clone();
        }
        fs::write(&config, serde_json::to_string_pretty(&value).unwrap()).unwrap();
        let mut remove = vec!["guard".into()];
        if retained_event.is_none() {
            remove.push("retained".into());
        }
        let report = ops::remove(&f.env, &f.scope, &remove, None, false).unwrap();
        let empty = retained_event.is_none() && user_permission.is_none();
        let trashed = report
            .plan
            .ops
            .iter()
            .any(|op| matches!(&op.op, Op::Trash { path, .. } if path == &config));
        assert_eq!(trashed, empty);
        apply::execute(&f.env, &report.plan).unwrap();
        assert_eq!(config.exists(), !empty);
        if !empty {
            let mut expected = json!({"$schema": "https://opencode.ai/config.json"});
            if retained_event.is_some() {
                assert!(fs::read(root.join(RETAINED)).is_ok());
                expected["instructions"] = json!([RETAINED]);
            }
            let permission = user_permission
                .or_else(|| (retained_event == Some("PreToolUse")).then(|| json!({"*": "ask"})));
            if let Some(permission) = permission {
                expected["permission"] = json!({"bash": permission});
            }
            let actual: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&config).unwrap()).unwrap();
            assert_eq!(actual, expected);
        }
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn claude_default_ownership_preserves_user_values_and_deletions_through_removal() {
    use ClaudeProjectDefault::{Owned, Released};
    let user_settings = json!({
        "permissions": {"allow": ["Read"]},
        "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "user-start"}]}]}
    });
    for (initial, edits, ownership, removed_flag, reinstalled_flag) in [
        (None, &[][..], Owned, None, Some(true)),
        (Some(true), &[][..], Released, Some(true), Some(true)),
        (Some(false), &[][..], Released, Some(false), Some(false)),
        (None, &[Some(false)][..], Released, Some(false), Some(false)),
        (None, &[None][..], Released, None, None),
        (
            None,
            &[Some(false), Some(true)][..],
            Released,
            Some(true),
            Some(true),
        ),
    ] {
        let f = fixture();
        let settings = f.project.join(".claude/settings.json");
        let original_manifest = fs::read_to_string(f.project.join("kendex.toml")).unwrap();
        let mut initial_settings = user_settings.clone();
        if let Some(value) = initial {
            initial_settings["switchModelsOnFlag"] = json!(value);
        }
        fs::write(&settings, format!("{}\n", initial_settings)).unwrap();
        apply_now(&f);
        let record_path = lock_path(&f.env, &f.scope);
        assert_eq!(
            load(&record_path).unwrap().claude_project_default,
            Some(initial.map_or(Owned, |_| Released))
        );
        for change in edits {
            change_default_preserving_user_value(&f, *change);
        }
        assert_eq!(
            load(&record_path).unwrap().claude_project_default,
            Some(ownership)
        );
        let removal = ops::remove(&f.env, &f.scope, &["guard".into()], None, false).unwrap();
        apply::execute(&f.env, &removal.plan).unwrap();
        let mut expected = user_settings.clone();
        if let Some(value) = removed_flag {
            expected["switchModelsOnFlag"] = json!(value);
        }
        let remaining: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
        assert_eq!(remaining, expected);
        assert!(audit(&f.env, &f.scope).unwrap().plan.is_empty());
        fs::write(f.project.join("kendex.toml"), original_manifest).unwrap();
        apply_now(&f);
        let value: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
        assert_eq!(value["switchModelsOnFlag"].as_bool(), reinstalled_flag);
        assert_eq!(value["permissions"], user_settings["permissions"]);
        assert_eq!(
            value["hooks"]["SessionStart"],
            user_settings["hooks"]["SessionStart"]
        );
        assert!(audit(&f.env, &f.scope).unwrap().plan.is_empty());
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn claude_owned_default_stays_until_the_last_enabled_installation_leaves() {
    let f = fixture();
    let manifest = f.project.join("kendex.toml");
    let declared = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        format!(
            "{declared}\n[plugins.\"fmt@marketplace\"]\nenabled = true\nharness = \"claude\"\n"
        ),
    )
    .unwrap();
    apply_now(&f);
    let remove_hook = ops::remove(&f.env, &f.scope, &["guard".into()], None, false).unwrap();
    apply::execute(&f.env, &remove_hook.plan).unwrap();
    let settings = f.project.join(".claude/settings.json");
    let value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
    assert_eq!(
        value,
        json!({"enabledPlugins": {"fmt@marketplace": true}, "switchModelsOnFlag": true})
    );
    assert_eq!(
        load(&lock_path(&f.env, &f.scope))
            .unwrap()
            .claude_project_default,
        Some(ClaudeProjectDefault::Owned)
    );
    let last = ops::remove(&f.env, &f.scope, &["fmt@marketplace".into()], None, false).unwrap();
    assert!(
        last.plan
            .ops
            .iter()
            .any(|op| matches!(&op.op, Op::Trash {path, ..} if path == &settings))
    );
    apply::execute(&f.env, &last.plan).unwrap();
    assert!(!settings.exists());
    assert!(
        load(&lock_path(&f.env, &f.scope))
            .unwrap()
            .claude_project_default
            .is_none()
    );
    assert!(audit(&f.env, &f.scope).unwrap().plan.is_empty());
}
