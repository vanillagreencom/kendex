//! Scope filenames in plans, report lines, remedies and source labels.
//! KEN-1711 requires these message assertions and ordinary-project controls.

#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use kendex_core::apply::{self, Op, Plan};
use kendex_core::drift;
use kendex_core::engine::{self, PlanOptions, audit, fork, ops, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::manifest;
use kendex_core::model::{HarnessId, ItemKind, Scope};

use crate::test_util::{rooted, source_path};

const SCOPES: [(bool, &str); 2] = [(true, "kendex-local.toml"), (false, "kendex.toml")];

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    source: PathBuf,
    file: &'static str,
}

#[allow(clippy::unwrap_used)]
fn write(root: &Path, path: &str, text: &str) {
    let path = root.join(path);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

#[allow(clippy::unwrap_used)]
fn world(catalog: bool, file: &'static str, body: &str) -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let source = home.join("catalog");
    write(&source, "kendex.toml", "is_source_catalog = true\n");
    write(
        &source,
        "skills/deploy/SKILL.md",
        "---\nname: deploy\ndescription: deploys\n---\nDeploy.\n",
    );
    write(
        &source,
        "skills/dev/SKILL.md",
        "---\nname: dev\ndescription: develops\ndependencies:\n  required: [deploy]\n---\nDevelop.\n",
    );
    write(
        &source,
        "hooks/guard.sh",
        "#!/bin/sh\n# ---\n# name: guard\n# event: SessionStart\n# description: checks\n# harnesses: [claude]\n# ---\ntrue\n",
    );
    if catalog {
        write(&project, "kendex.toml", "is_source_catalog = true\n");
    }
    let w = World {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        source,
        file,
        _tmp: tmp,
    };
    declare(&w, "", body);
    w
}

fn declare(w: &World, source_extra: &str, body: &str) {
    write(
        &w.project,
        w.file,
        &format!(
            "schema = 6\n[sources.cat]\n{}\n{source_extra}\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n{body}",
            source_path(&w.source),
        ),
    );
}

fn assert_message(text: &str, expected: &str, file: &str) {
    assert!(text.contains(expected), "expected {expected:?}: {text}");
    if file == "kendex-local.toml" {
        assert!(
            !text.contains("kendex.toml"),
            "wrong declaring file: {text}"
        );
    }
}

#[allow(clippy::unwrap_used)]
fn manifest_description(plan: &Plan) -> String {
    let op = plan
        .ops
        .iter()
        .find(|op| matches!(op.op, Op::WriteManifest { .. }))
        .unwrap();
    op.line()
}

#[test]
#[allow(clippy::unwrap_used)]
fn drift_hook_plan_names_the_file_it_writes() {
    let states = [
        ("", "declare the drift hook in"),
        (
            "[hooks.kendex-drift]\nsource = \"local\"\nenabled = false\n",
            "switch the drift hook back on in",
        ),
        (
            "[hooks.kendex-drift]\nsource = \"local\"\nharnesses = [\"claude\"]\n",
            "register the drift hook for every tool it runs in, in",
        ),
    ];
    for (catalog, file) in SCOPES {
        for (body, description) in states {
            let w = world(catalog, file, body);
            let plan = drift::hook::install_plan(&w.env, &w.scope).unwrap();
            assert_eq!(manifest_description(&plan), format!("{description} {file}"));
            let write = plan
                .ops
                .iter()
                .find_map(|op| match &op.op {
                    Op::WriteManifest { path, .. } => Some(path),
                    _ => None,
                })
                .unwrap();
            assert_eq!(write, &w.project.join(file));
            apply::execute(&w.env, &plan).unwrap();
            let manifest = manifest::load_current(&w.project.join(file))
                .unwrap()
                .unwrap();
            assert!(manifest.hooks["kendex-drift"].enabled);
            if catalog {
                assert_eq!(
                    fs::read_to_string(w.project.join("kendex.toml")).unwrap(),
                    "is_source_catalog = true\n"
                );
            }
        }
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn drift_report_names_the_declaring_file_for_an_occupied_position() {
    for (catalog, file) in SCOPES {
        let w = world(catalog, file, "[skills.deploy]\nsource = \"cat\"\n");
        write(
            &w.project,
            ".claude/skills/deploy/SKILL.md",
            "an unmanaged copy\n",
        );
        let report = drift::report::check_within(
            &w.env,
            std::slice::from_ref(&w.scope),
            Duration::ZERO,
            drift::copies::CheckMode::ReportOnly,
        );
        let text = drift::report::render_plain(&report, drift::report::Verbosity::Verbose);
        assert_message(
            &text,
            &format!(
                "{file} asks for skill 'deploy' for Claude Code, and files are already where it would go"
            ),
            file,
        );
        assert_message(
            &text,
            &format!(
                "files already where {file} installs could not be compared with their source inside the 0 s the session hook allows"
            ),
            file,
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn disabled_source_remedy_names_the_declaring_file() {
    for (catalog, file) in SCOPES {
        let w = world(catalog, file, "[skills.dev]\nsource = \"cat\"\n");
        let installed = audit(&w.env, &w.scope).unwrap();
        apply::execute(&w.env, &installed.plan).unwrap();
        declare(&w, "enabled = false", "");
        let report = plan_apply(
            &w.env,
            &w.scope,
            &PlanOptions {
                remove_orphans: true,
                ..PlanOptions::current()
            },
        )
        .unwrap();
        assert_message(
            &report.notes.join("\n"),
            &format!("switch it back on in {file}, or remove what it installed by name"),
            file,
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn dependency_remedies_name_the_declaring_file() {
    for (catalog, file) in SCOPES {
        let w = world(
            catalog,
            file,
            "[skills.dev]\nsource = \"cat\"\n[skills.deploy]\nsource = \"cat\"\nenabled = false\n[optional-dependencies]\ndev = [\"missing\"]\n",
        );
        let report = audit(&w.env, &w.scope).unwrap();
        let remedies: Vec<&str> = report
            .warnings
            .iter()
            .filter_map(|warning| warning.remediation.as_deref())
            .collect();
        let text = remedies.join("\n");
        assert_message(
            &text,
            &format!(
                "set enabled = true on deploy's declaration in {file}, or drop it from dev's dependencies"
            ),
            file,
        );
        assert_message(
            &text,
            &format!("remove missing from optional-dependencies.dev in {file}"),
            file,
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn fork_and_rename_plans_name_the_declaring_file() {
    for (catalog, file) in SCOPES {
        let w = world(catalog, file, "[skills.deploy]\nsource = \"cat\"\n");
        let report = audit(&w.env, &w.scope).unwrap();
        apply::execute(&w.env, &report.plan).unwrap();
        write(
            &w.project,
            ".claude/skills/deploy/SKILL.md",
            "---\nname: deploy\ndescription: deploys\n---\nMy edit.\n",
        );
        let beside = fork::fork_beside(
            &w.env,
            &w.scope,
            ItemKind::Skill,
            "deploy",
            HarnessId::Claude,
            "mine",
            None,
        )
        .unwrap();
        assert_eq!(
            manifest_description(&beside),
            format!("record the fork of deploy as mine in {file}")
        );
        let plan = fork::fork(
            &w.env,
            &w.scope,
            ItemKind::Skill,
            "deploy",
            HarnessId::Claude,
        )
        .unwrap();
        assert_eq!(
            manifest_description(&plan),
            format!("record the fork of deploy in {file}")
        );
        apply::execute(&w.env, &plan).unwrap();
        let report = audit(&w.env, &w.scope).unwrap();
        apply::execute(&w.env, &report.plan).unwrap();
        let renamed =
            fork::rename_fork(&w.env, &w.scope, ItemKind::Skill, "deploy", "mine").unwrap();
        assert_eq!(
            manifest_description(&renamed),
            format!("record the rename to mine in {file}")
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn other_edit_remedies_name_the_declaring_file() {
    for (catalog, file) in SCOPES {
        let w = world(
            catalog,
            file,
            "[skills.deploy]\nsource = \"cat\"\n[hooks.guard]\nsource = \"cat\"\nharnesses = [\"codex\"]\n[suppressed]\nskill = [\"deploy\"]\n",
        );
        let report = plan_apply(
            &w.env,
            &w.scope,
            &PlanOptions {
                judge_pins: true,
                ..PlanOptions::current()
            },
        )
        .unwrap();
        let text = report.notes.join("\n");
        assert_message(
            &text,
            &format!("drop it from [suppressed] in {file} to settle it"),
            file,
        );
        assert_message(
            &text,
            &format!("{file} lists codex in this hook's harnesses"),
            file,
        );
        assert_message(
            &text,
            &format!("take it off the hook's harnesses in {file}"),
            file,
        );
        let refused = ops::add(
            &w.env,
            &w.scope,
            &ops::AddRequest {
                pi_extensions: vec!["@example/checks".to_owned()],
                ..ops::AddRequest::default()
            },
        )
        .unwrap_err();
        assert_message(
            &refused.to_string(),
            &format!(
                "declare it under [pi-extensions] in the scope's {file}, then the update-pi verb installs it"
            ),
            file,
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn adopt_and_detach_plans_name_the_declaring_file() {
    for (catalog, file) in SCOPES {
        let w = world(catalog, file, "");
        write(
            &w.project,
            ".claude/skills/mine/SKILL.md",
            "---\nname: mine\ndescription: my skill\n---\nMine.\n",
        );
        let adopted = engine::adopt::adopt(
            &w.env,
            &w.scope,
            ItemKind::Skill,
            "mine",
            &[HarnessId::Claude],
        )
        .unwrap();
        assert_eq!(
            manifest_description(&adopted),
            format!("declare the adopted item in {file}")
        );
        declare(&w, "", "[skills.deploy]\nsource = \"cat\"\n");
        let report = audit(&w.env, &w.scope).unwrap();
        apply::execute(&w.env, &report.plan).unwrap();
        let detached = engine::detach::source(&w.env, &w.scope, "cat").unwrap();
        assert_eq!(
            manifest_description(&detached),
            format!("keep cat's packages as your own in {file}")
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn custom_hook_refresh_preserves_shipped_ownership() {
    for (catalog, file) in SCOPES {
        for action in ["unchanged", "command", "disabled", "harness removed"] {
            let w = world(
                catalog,
                file,
                "[[custom-hooks]]\nname = \"custom\"\nevent = \"SessionStart\"\ncommand = \"./check.sh\"\nagents = \"all\"\n",
            );
            let report = audit(&w.env, &w.scope).unwrap();
            apply::execute(&w.env, &report.plan).unwrap();
            let mut lock =
                kendex_core::lock::load(&kendex_core::lock::lock_path(&w.env, &w.scope)).unwrap();
            let key = "hook:custom:claude";
            // The identity already shipped, independently of the scope's display name.
            lock.entries.get_mut(key).unwrap().source_repo =
                "kendex.toml [[custom-hooks]]".to_owned();
            let mut declared = manifest::load_current(&w.project.join(file))
                .unwrap()
                .unwrap();
            match action {
                "unchanged" => {}
                "command" => declared.custom_hooks[0].command = "./new-check.sh".to_owned(),
                "disabled" => declared.custom_hooks[0].enabled = false,
                "harness removed" => {
                    declared.custom_hooks[0].harnesses = Some(vec!["copilot".to_owned()])
                }
                _ => unreachable!(),
            }
            let report = engine::plan_scope(
                &w.env,
                &w.scope,
                &declared,
                &lock,
                &PlanOptions {
                    remove_orphans: true,
                    ..PlanOptions::current()
                },
            )
            .unwrap();
            assert!(
                !report
                    .drift
                    .iter()
                    .any(|row| row.name == "custom" && row.state == engine::DriftState::Conflict),
                "{catalog} {action}"
            );
            apply::execute(&w.env, &report.plan).unwrap();
            let installed = fs::read_to_string(w.project.join(".claude/settings.json"))
                .unwrap_or_else(|error| {
                    assert_eq!(error.kind(), std::io::ErrorKind::NotFound);
                    "{}".to_owned()
                });
            let settings: serde_json::Value = serde_json::from_str(&installed).unwrap();
            let registrations = settings["hooks"]["SessionStart"]
                .as_array()
                .map(Vec::as_slice)
                .unwrap_or_default();
            match action {
                "unchanged" | "command" => {
                    assert_eq!(
                        registrations[0]["hooks"][0]["command"],
                        if action == "command" {
                            "./new-check.sh"
                        } else {
                            "./check.sh"
                        }
                    );
                    let after =
                        kendex_core::lock::load(&kendex_core::lock::lock_path(&w.env, &w.scope))
                            .unwrap();
                    assert_eq!(
                        after.entries[key].source_repo,
                        "kendex.toml [[custom-hooks]]"
                    );
                }
                "disabled" | "harness removed" => {
                    assert!(registrations.is_empty(), "{catalog} {action}")
                }
                _ => unreachable!(),
            }
        }
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn custom_hook_source_conflict_names_the_declaring_file() {
    for (catalog, file) in SCOPES {
        for withheld in [false, true] {
            let w = world(
                catalog,
                file,
                "[[custom-hooks]]\nname = \"custom\"\nevent = \"SessionStart\"\ncommand = \"./check.sh\"\nagents = \"all\"\n",
            );
            let report = audit(&w.env, &w.scope).unwrap();
            apply::execute(&w.env, &report.plan).unwrap();
            let lock =
                kendex_core::lock::load(&kendex_core::lock::lock_path(&w.env, &w.scope)).unwrap();
            write(
                &w.source,
                "hooks/custom.sh",
                "#!/bin/sh\n# ---\n# name: custom\n# event: SessionStart\n# description: checks\n# harnesses: [claude]\n# ---\ntrue\n",
            );
            let refused = ops::add(
                &w.env,
                &w.scope,
                &ops::AddRequest {
                    source: Some("cat".to_owned()),
                    hooks: vec!["custom".to_owned()],
                    ..Default::default()
                },
            )
            .unwrap_err();
            match refused {
                kendex_core::error::CoreError::SourceCollision { existing, .. } => {
                    assert_message(&existing, &format!("{file} [[custom-hooks]]"), file);
                }
                other => panic!("expected source collision: {other}"),
            }
            declare(
                &w,
                "",
                &format!(
                    "[hooks.custom]\nsource = \"cat\"\nharnesses = [\"{}\"]\n",
                    if withheld { "copilot" } else { "claude" }
                ),
            );
            let declared = manifest::load_current(&w.project.join(file))
                .unwrap()
                .unwrap();
            let report =
                engine::plan_scope(&w.env, &w.scope, &declared, &lock, &PlanOptions::current())
                    .unwrap();
            let conflict = report
                .drift
                .iter()
                .find(|row| row.name == "custom" && row.state == engine::DriftState::Conflict)
                .unwrap();
            assert_message(
                &conflict.detail,
                &format!("installed from {file} [[custom-hooks]]"),
                file,
            );
            apply::execute(&w.env, &report.plan).unwrap();
            let kept =
                kendex_core::lock::load(&kendex_core::lock::lock_path(&w.env, &w.scope)).unwrap();
            assert_eq!(
                kept.entries["hook:custom:claude"].source_repo,
                "kendex.toml [[custom-hooks]]"
            );
        }
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn bundle_remedy_names_the_declaring_file() {
    for (catalog, file) in SCOPES {
        let w = world(
            catalog,
            file,
            "[bundles.alpha]\nsource = \"cat\"\nmethod = \"copy\"\n[bundles.zulu]\nsource = \"cat\"\nmethod = \"symlink\"\n",
        );
        write(
            &w.source,
            "kendex.toml",
            "is_source_catalog = true\n[bundles.alpha]\ndescription = \"alpha\"\nskills = [\"deploy\"]\n[bundles.zulu]\ndescription = \"zulu\"\nskills = [\"deploy\"]\n",
        );
        let report = audit(&w.env, &w.scope).unwrap();
        let text = report
            .warnings
            .iter()
            .filter_map(|warning| warning.remediation.as_deref())
            .collect::<Vec<_>>()
            .join("\n");
        assert_message(
            &text,
            &format!("declare the skill deploy in {file} to say how it should install"),
            file,
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn install_default_notice_names_the_declaring_file() {
    for (catalog, file) in SCOPES {
        let w = world(catalog, file, "");
        let home = w.project.parent().unwrap();
        fs::create_dir_all(home.join(".claude")).unwrap();
        fs::create_dir_all(home.join(".codex")).unwrap();
        let report = ops::add(
            &w.env,
            &w.scope,
            &ops::AddRequest {
                source: Some("cat".to_owned()),
                skills: vec!["deploy".to_owned()],
                ..ops::AddRequest::default()
            },
        )
        .unwrap();
        assert_message(
            &report.notes.join("\n"),
            &format!(
                "Codex is on this machine and not in [install].harnesses; name it with --harness or add it to {file}"
            ),
            file,
        );
    }
}
