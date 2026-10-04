//! Response-style installation, shared-file ownership, and drift at both scopes.

use crate::test_util::{rooted, source_path};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::{apply, engine, lock, manifest};
use std::fs;
use std::path::PathBuf;

const STYLE: &str = "---\nname: STE\ndescription: Short technical sentences\nkeep-coding-instructions: true\n---\nWrite short sentences.\n";

struct Fixture {
    _temp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    source: PathBuf,
}

#[allow(clippy::unwrap_used, reason = "fixture setup")]
fn fixture(global: bool, harnesses: &[HarnessId]) -> Fixture {
    let temp = tempfile::tempdir().unwrap();
    let home = rooted(&temp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("project");
    let scope = if global {
        Scope::Global
    } else {
        Scope::Project {
            root: project.clone(),
        }
    };
    let source = home.join("catalog");
    fs::create_dir_all(source.join("output-styles")).unwrap();
    fs::write(source.join("output-styles/STE.md"), STYLE).unwrap();
    fs::write(source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(project.join(".pi")).unwrap();
    fs::create_dir_all(home.join(".claude")).unwrap();
    fs::create_dir_all(home.join(".pi/agent")).unwrap();
    let path = manifest::manifest_path(&env, &scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, format!("schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [{}]\nmethod = \"copy\"\n[output-styles.STE]\nsource = \"cat\"\n", source_path(&source), harnesses.iter().map(|h| format!("\"{}\"", h.name())).collect::<Vec<_>>().join(", "))).unwrap();
    Fixture {
        _temp: temp,
        env,
        scope,
        project,
        source,
    }
}

fn paths(f: &Fixture) -> (PathBuf, PathBuf, PathBuf) {
    let claude = match &f.scope {
        Scope::Global => f.env.home.join(".claude"),
        Scope::Project { root } => root.join(".claude"),
    };
    (
        claude.join("output-styles/STE.md"),
        claude.join("settings.json"),
        kendex_core::harness::pi::scope_root(&f.env, &f.scope).join("APPEND_SYSTEM.md"),
    )
}

#[allow(clippy::unwrap_used, reason = "fixture installation")]
fn install(f: &Fixture) {
    let report = engine::audit(&f.env, &f.scope).unwrap();
    assert_eq!(
        report
            .drift
            .iter()
            .filter(|row| row.state == engine::DriftState::Conflict)
            .count(),
        0,
        "installation conflict count"
    );
    apply::execute(&f.env, &report.plan).unwrap();
}

#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
fn project_append_keeps_global_instructions_under_merged_settings() {
    use kendex_core::configedit::{marker_block, upsert_marker_block};
    use kendex_core::pi_ext;
    use serde_json::json;

    for (global_setting, project_setting, included) in [
        (None, None, true),
        (Some(json!(false)), None, false),
        (Some(json!(true)), Some(json!(false)), false),
        (Some(json!(false)), Some(json!(true)), true),
        (Some(json!(false)), Some(json!(null)), true),
    ] {
        let f = fixture(false, &[HarnessId::Pi]);
        let global = pi_ext::scope_root(&f.env, &Scope::Global).unwrap();
        let project = f.project.join(".pi");
        for (name, text, root, enabled) in [
            ("always", "Global tools.", &global, true),
            ("configured", "Configured tools.", &global, true),
            ("native-off", "Disabled tools.", &global, false),
            ("local", "Project tools.", &project, true),
        ] {
            let source = f.source.join("pi-extensions").join(name);
            fs::create_dir_all(&source).unwrap();
            fs::write(
                source.join("package.json"),
                json!({"name": name, "pi": {"appendSystem": "system.md"}}).to_string(),
            )
            .unwrap();
            fs::write(source.join("system.md"), text).unwrap();
            pi_ext::install(&f.env, root, &source, enabled).unwrap();
        }
        assert!(
            fs::read_to_string(pi_ext::append_system_path(&project))
                .unwrap()
                .contains("Global tools.")
        );
        for (root, setting) in [(&global, global_setting), (&project, project_setting)] {
            let path = pi_ext::settings_path(root);
            let mut value: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
            if let Some(setting) = setting {
                value["kendex"] =
                    json!({"extensionManager": {"config": {"configured": {"enabled": setting}}}});
            }
            fs::write(path, value.to_string()).unwrap();
        }
        let global_append = pi_ext::append_system_path(&global);
        let global_text = fs::read_to_string(&global_append).unwrap();
        fs::write(
            &global_append,
            upsert_marker_block(&global_text, "output-style-global", "Global style."),
        )
        .unwrap();
        let (_, _, append) = paths(&f);
        let local = fs::read_to_string(&append).unwrap();
        fs::write(&append, format!("Personal instructions.\n{local}")).unwrap();
        let global_before = fs::read(&global_append).unwrap();
        install(&f);
        let text = fs::read_to_string(&append).unwrap();
        assert!(text.starts_with("Personal instructions.\n"));
        assert!(text.contains("Global tools."));
        assert_eq!(text.contains("Configured tools."), included);
        assert!(!text.contains("Disabled tools."));
        assert!(text.contains("Project tools."));
        assert!(text.contains("Global style."));
        assert!(
            marker_block(&text, "output-style-STE")
                .unwrap()
                .contains("Write short sentences.")
        );
        assert_eq!(fs::read(&global_append).unwrap(), global_before);
        install(&f);
        assert_eq!(fs::read_to_string(&append).unwrap(), text);
        // A project without a local output style still needs inheritance.
        let path = manifest::manifest_path(&f.env, &f.scope);
        let mut declared = manifest::load_current(&path).unwrap().unwrap();
        declared.output_styles.clear();
        fs::write(&path, toml::to_string(&declared).unwrap()).unwrap();
        install(&f);
        assert!(
            fs::read_to_string(&append)
                .unwrap()
                .contains("Global tools.")
        );
        pi_ext::remove(&f.env, &global, "always").unwrap();
        fs::write(&global_append, "").unwrap();
        install(&f);
        let text = fs::read_to_string(&append).unwrap();
        assert!(!text.contains("Global tools."));
        assert!(!text.contains("Global style."));
        assert!(text.contains("Project tools."));
    }
}

#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
fn a_new_project_output_style_keeps_global_instructions() {
    let f = fixture(false, &[HarnessId::Pi]);
    let global = kendex_core::pi_ext::scope_root(&f.env, &Scope::Global).unwrap();
    let source = f.source.join("pi-extensions/global");
    fs::create_dir_all(&source).unwrap();
    fs::write(
        source.join("package.json"),
        r#"{"name":"global","pi":{"appendSystem":"system.md"}}"#,
    )
    .unwrap();
    fs::write(source.join("system.md"), "Global tools.").unwrap();
    kendex_core::pi_ext::install(&f.env, &global, &source, true).unwrap();
    let (_, _, append) = paths(&f);
    assert!(!append.exists());
    install(&f);
    let text = fs::read_to_string(&append).unwrap();
    assert!(text.contains("Global tools."));
    assert!(text.contains("Write short sentences."));
}

#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
fn routes_reapply_and_record_only_owned_content() {
    for global in [false, true] {
        let f = fixture(global, &[HarnessId::Claude, HarnessId::Pi]);
        let (style, settings, append) = paths(&f);
        fs::write(&append, "Personal instructions.\r\n").unwrap();
        fs::write(&settings, "{\"model\":\"opus\"}\n").unwrap();
        install(&f);
        assert_eq!(fs::read_to_string(&style).unwrap(), STYLE);
        let selection: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
        assert_eq!(selection["outputStyle"], "STE");
        assert_eq!(selection["model"], "opus");
        let block = fs::read_to_string(&append).unwrap();
        assert!(block.starts_with("Personal instructions.\r\n"));
        assert!(block.contains("<!-- kendex:append-system output-style-STE begin -->"));
        assert_eq!(kendex_core::configedit::style_blocks(&block), vec!["STE"]);
        assert_eq!(
            kendex_core::configedit::remove_marker_block(&block, "output-style-STE"),
            "Personal instructions.\r\n"
        );
        let report = engine::audit(&f.env, &f.scope).unwrap();
        assert_eq!(report.drift.len(), 0, "reapply drift count");
        let record = lock::load(&lock::lock_path(&f.env, &f.scope)).unwrap();
        for harness in [HarnessId::Claude, HarnessId::Pi] {
            let entry = &record.entries[&lock::entry_key(ItemKind::OutputStyle, "STE", harness)];
            assert!(entry.output_style.is_some());
            assert_eq!(
                entry.machine.as_ref().unwrap().method,
                manifest::Method::Copy
            );
            assert_eq!(entry.emitted.is_some(), harness == HarnessId::Claude);
        }
        let observed = kendex_core::scan::scan_scopes(
            &f.env,
            &std::collections::BTreeMap::new(),
            std::slice::from_ref(&f.scope),
        );
        for harness in [HarnessId::Claude, HarnessId::Pi] {
            assert_eq!(
                observed
                    .items
                    .iter()
                    .filter(|item| item.kind == ItemKind::OutputStyle
                        && item.name == "STE"
                        && item.harness == harness)
                    .count(),
                1,
                "observed style count for {harness:?}"
            );
        }
        assert!(!f.project.join("AGENTS.md").exists());
    }
}

#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
fn existing_selections_and_local_settings_remain_user_owned() {
    for global in [false, true] {
        for owner in ["kendex", "settings", "local"] {
            let f = fixture(global, &[HarnessId::Claude, HarnessId::Pi]);
            let (style, settings, append) = paths(&f);
            let selected = if owner == "local" {
                settings.with_file_name("settings.local.json")
            } else {
                settings.clone()
            };
            let original = if owner == "kendex" {
                "{\"model\":\"opus\"}\n"
            } else {
                "{\"outputStyle\":\"Explanatory\",\"model\":\"opus\"}\n"
            };
            fs::write(&selected, original).unwrap();
            fs::write(&append, "Personal instructions.\n").unwrap();
            let before = fs::read(&selected).unwrap();
            install(&f);
            if owner != "kendex" {
                assert_eq!(fs::read(&selected).unwrap(), before);
            }
            let record = lock::load(&lock::lock_path(&f.env, &f.scope)).unwrap();
            assert_eq!(
                record.entries["output-style:STE:claude"].output_style,
                Some(lock::OutputStyleRecord::Claude {
                    path: settings.clone(),
                    selection: (owner == "kendex").then(|| "STE".into()),
                })
            );
            assert!(engine::audit(&f.env, &f.scope).unwrap().drift.is_empty());
            let report = engine::ops::remove(
                &f.env,
                &f.scope,
                &["STE".into()],
                Some(ItemKind::OutputStyle),
                false,
            )
            .unwrap();
            apply::execute(&f.env, &report.plan).unwrap();
            assert!(!style.exists(), "{owner}");
            assert_eq!(
                fs::read_to_string(&append).unwrap(),
                "Personal instructions.\n"
            );
            if owner == "kendex" {
                let remaining: serde_json::Value =
                    serde_json::from_slice(&fs::read(&selected).unwrap()).unwrap();
                assert_eq!(remaining, serde_json::json!({"model":"opus"}));
            } else {
                assert_eq!(fs::read(&selected).unwrap(), before);
            }
            assert!(
                lock::load(&lock::lock_path(&f.env, &f.scope))
                    .unwrap()
                    .entries
                    .is_empty()
            );
        }
    }
}

#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
#[allow(
    clippy::too_many_lines,
    reason = "keeps lifecycle and ownership rows in one table"
)]
fn selection_acquisition_follows_enable_and_composed_replacement() {
    for global in [false, true] {
        for transition in [
            "first-disabled",
            "disable-enable",
            "replace",
            "replace-kept",
        ] {
            for owner in ["kendex", "settings", "local", "removed"] {
                let f = fixture(global, &[HarnessId::Claude, HarnessId::Pi]);
                let (style, settings, append) = paths(&f);
                let selected = if owner == "local" {
                    settings.with_file_name("settings.local.json")
                } else {
                    settings.clone()
                };
                let user = "{\"outputStyle\":\"Learning\",\"model\":\"opus\"}\n";
                if owner != "kendex" {
                    fs::write(&selected, user).unwrap();
                } else {
                    fs::write(&selected, "{\"model\":\"opus\"}\n").unwrap();
                }
                let manifest_path = manifest::manifest_path(&f.env, &f.scope);
                let original = fs::read_to_string(&manifest_path).unwrap();
                if transition != "first-disabled" {
                    install(&f);
                }
                let name = if transition.starts_with("replace") {
                    fs::write(
                        f.source.join("output-styles/Other.md"),
                        STYLE.replace("name: STE", "name: Other"),
                    )
                    .unwrap();
                    fs::write(
                        &manifest_path,
                        original.replace("output-styles.STE", "output-styles.Other"),
                    )
                    .unwrap();
                    "Other"
                } else {
                    fs::write(&manifest_path, format!("{original}enabled = false\n")).unwrap();
                    install(&f);
                    assert!(!style.exists());
                    assert!(style.with_file_name("STE.md.disabled").exists());
                    assert!(
                        kendex_core::configedit::style_blocks(
                            &fs::read_to_string(&append).unwrap_or_default()
                        )
                        .is_empty()
                    );
                    let record = lock::load(&lock::lock_path(&f.env, &f.scope)).unwrap();
                    if transition == "first-disabled" && owner == "kendex" {
                        assert_eq!(record.entries["output-style:STE:claude"].output_style, None);
                    }
                    fs::write(&manifest_path, &original).unwrap();
                    "STE"
                };
                if owner == "removed" {
                    fs::write(&selected, "{\"model\":\"opus\"}\n").unwrap();
                }
                if transition == "replace-kept" {
                    install(&f);
                    if owner == "kendex" {
                        let record = lock::load(&lock::lock_path(&f.env, &f.scope)).unwrap();
                        assert_eq!(
                            record.entries["output-style:Other:claude"].output_style,
                            None
                        );
                    }
                }
                let manifest = manifest::load_current(&manifest_path).unwrap().unwrap();
                let record = lock::load(&lock::lock_path(&f.env, &f.scope)).unwrap();
                let report = engine::plan_scope(
                    &f.env,
                    &f.scope,
                    &manifest,
                    &record,
                    &engine::PlanOptions {
                        remove_orphans: true,
                        ..Default::default()
                    },
                )
                .unwrap();
                assert_eq!(
                    report
                        .drift
                        .iter()
                        .filter(|row| row.state == engine::DriftState::Conflict)
                        .count(),
                    0,
                    "{transition}/{owner}: conflict count"
                );
                apply::execute(&f.env, &report.plan).unwrap();
                let record = lock::load(&lock::lock_path(&f.env, &f.scope)).unwrap();
                assert_eq!(
                    record.entries[&format!("output-style:{name}:claude")].output_style,
                    Some(lock::OutputStyleRecord::Claude {
                        path: settings.clone(),
                        selection: (owner == "kendex").then(|| name.into()),
                    }),
                    "{transition}/{owner}"
                );
                let selection: serde_json::Value =
                    serde_json::from_slice(&fs::read(&selected).unwrap()).unwrap();
                let expected = match owner {
                    "kendex" => serde_json::json!(name),
                    "removed" => serde_json::Value::Null,
                    "settings" | "local" => serde_json::json!("Learning"),
                    _ => unreachable!(),
                };
                assert_eq!(selection["outputStyle"], expected);
                assert_eq!(selection["model"], "opus");
                if owner != "kendex" {
                    assert_eq!(
                        fs::read_to_string(&selected).unwrap(),
                        if owner == "removed" {
                            "{\"model\":\"opus\"}\n"
                        } else {
                            user
                        }
                    );
                }
                assert!(style.with_file_name(format!("{name}.md")).exists());
                assert!(!style.with_file_name("STE.md.disabled").exists());
                assert_eq!(
                    kendex_core::configedit::style_blocks(&fs::read_to_string(&append).unwrap()),
                    vec![name]
                );
                assert!(engine::audit(&f.env, &f.scope).unwrap().drift.is_empty());
                // Ownership must still detect the user's deletion after either acquisition.
                if owner == "kendex" {
                    fs::write(&settings, "{\"model\":\"opus\"}\n").unwrap();
                    assert!(
                        engine::audit(&f.env, &f.scope)
                            .unwrap()
                            .drift
                            .iter()
                            .any(|row| row.harness == HarnessId::Claude
                                && row.state == engine::DriftState::Conflict)
                    );
                }
            }
        }
    }
}

#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
#[allow(
    clippy::too_many_lines,
    reason = "keeps edit protection and discard rows in one table"
)]
fn content_and_selection_edits_are_drift_and_are_not_overwritten() {
    for global in [false, true] {
        for route in [
            "claude-file",
            "pi-block",
            "claude-setting",
            "missing-setting",
        ] {
            let f = fixture(global, &[HarnessId::Claude, HarnessId::Pi]);
            install(&f);
            let (style, settings, append) = paths(&f);
            let edited = match route {
                "claude-file" => {
                    fs::write(&style, "My style.\n").unwrap();
                    style
                }
                "pi-block" => {
                    let current = fs::read_to_string(&append).unwrap();
                    fs::write(
                        &append,
                        current.replace("Write short sentences.", "My style."),
                    )
                    .unwrap();
                    append
                }
                "claude-setting" => {
                    fs::write(&settings, "{\"outputStyle\":\"Learning\"}\n").unwrap();
                    settings
                }
                "missing-setting" => {
                    fs::write(&settings, "{}\n").unwrap();
                    settings
                }
                _ => unreachable!(),
            };
            let before = fs::read(&edited).unwrap();
            let report = engine::audit(&f.env, &f.scope).unwrap();
            assert!(
                report
                    .drift
                    .iter()
                    .any(|row| row.kind == ItemKind::OutputStyle
                        && row.state == engine::DriftState::Conflict),
                "{route}: output-style conflict missing"
            );
            apply::execute(&f.env, &report.plan).unwrap();
            assert_eq!(fs::read(&edited).unwrap(), before);
            let manifest = manifest::load_current(&manifest::manifest_path(&f.env, &f.scope))
                .unwrap()
                .unwrap();
            let record = lock::load(&lock::lock_path(&f.env, &f.scope)).unwrap();
            for name in ["unrelated", "STE"] {
                let report = engine::plan_scope(
                    &f.env,
                    &f.scope,
                    &manifest,
                    &record,
                    &engine::PlanOptions {
                        overwrite_edited_names: Some(vec![(ItemKind::OutputStyle, name.into())]),
                        ..Default::default()
                    },
                )
                .unwrap();
                let repair = name == "STE" && matches!(route, "claude-file" | "pi-block");
                assert_eq!(
                    report
                        .drift
                        .iter()
                        .any(|row| row.state == engine::DriftState::Conflict),
                    !repair,
                    "{route}/{name}: conflict state"
                );
                apply::execute(&f.env, &report.plan).unwrap();
                if repair {
                    if route == "claude-file" {
                        assert_eq!(fs::read_to_string(&edited).unwrap(), STYLE);
                    } else {
                        assert_eq!(
                            kendex_core::configedit::marker_block(
                                &fs::read_to_string(&edited).unwrap(),
                                "output-style-STE"
                            ),
                            Some(
                                "<!-- kendex:append-system output-style-STE begin -->\nWrite short sentences.\n<!-- kendex:append-system output-style-STE end -->\n"
                            )
                        );
                    }
                    assert!(engine::audit(&f.env, &f.scope).unwrap().drift.is_empty());
                } else {
                    assert_eq!(fs::read(&edited).unwrap(), before);
                }
            }
        }
    }
}

#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
#[allow(
    clippy::too_many_lines,
    reason = "keeps live-ownership transitions in one table"
)]
fn explicit_discard_does_not_authorize_unrecorded_blocks_or_non_files() {
    for global in [false, true] {
        for transition in [
            "first-enabled",
            "first-disabled",
            "disable-enable",
            "disabled-repeat",
            "historical-disabled",
        ] {
            for obstacle in ["unrecorded-block", "matching-block", "directory"] {
                let f = fixture(global, &[HarnessId::Pi]);
                let (_, _, append) = paths(&f);
                let manifest_path = manifest::manifest_path(&f.env, &f.scope);
                let original = fs::read_to_string(&manifest_path).unwrap();
                let mut historical = None;
                if matches!(
                    transition,
                    "disable-enable" | "disabled-repeat" | "historical-disabled"
                ) {
                    install(&f);
                    historical = Some(lock::load(&lock::lock_path(&f.env, &f.scope)).unwrap());
                    fs::write(&manifest_path, format!("{original}enabled = false\n")).unwrap();
                    install(&f);
                    let disabled = lock::load(&lock::lock_path(&f.env, &f.scope)).unwrap();
                    assert!(!disabled.entries["output-style:STE:pi"].enabled);
                    assert_eq!(disabled.entries["output-style:STE:pi"].output_style, None);
                    if transition == "disable-enable" {
                        fs::write(&manifest_path, &original).unwrap();
                    }
                } else if transition == "first-disabled" {
                    fs::write(&manifest_path, format!("{original}enabled = false\n")).unwrap();
                }
                // The normal disable/apply lifecycle releases the position before
                // the user supplies a complete same-marker block.
                let body = if obstacle == "matching-block" {
                    "Write short sentences."
                } else {
                    "User style."
                };
                let user = format!(
                    "Personal text.\n<!-- kendex:append-system output-style-STE begin -->\n{body}\n<!-- kendex:append-system output-style-STE end -->\n"
                );
                // Disabling the last style retires the append file, and in a
                // project the emptied `.pi` directory goes with it.
                fs::create_dir_all(append.parent().unwrap()).unwrap();
                if obstacle == "directory" {
                    if append.exists() {
                        fs::remove_file(&append).unwrap();
                    }
                    fs::create_dir(&append).unwrap();
                } else {
                    fs::write(&append, &user).unwrap();
                }
                let manifest = manifest::load_current(&manifest_path).unwrap().unwrap();
                let mut record = lock::load(&lock::lock_path(&f.env, &f.scope)).unwrap();
                if transition == "historical-disabled" {
                    // A disabled lock can retain the hash of the block it removed.
                    record = historical.as_ref().unwrap().clone();
                    record
                        .entries
                        .get_mut("output-style:STE:pi")
                        .unwrap()
                        .enabled = false;
                }
                for discard in ["none", "all", "named"] {
                    let report = engine::plan_scope(
                        &f.env,
                        &f.scope,
                        &manifest,
                        &record,
                        &engine::PlanOptions {
                            overwrite_edited: discard == "all",
                            overwrite_edited_names: (discard == "named")
                                .then(|| vec![(ItemKind::OutputStyle, "STE".into())]),
                            ..Default::default()
                        },
                    )
                    .unwrap();
                    assert_eq!(
                        report
                            .drift
                            .iter()
                            .filter(|row| row.state == engine::DriftState::Conflict)
                            .count(),
                        1,
                        "{transition}/{obstacle}/{discard}: conflict count"
                    );
                    apply::execute(&f.env, &report.plan).unwrap();
                    if obstacle == "directory" {
                        assert!(append.is_dir());
                    } else {
                        assert_eq!(fs::read_to_string(&append).unwrap(), user);
                    }
                    assert_eq!(
                        lock::load(&lock::lock_path(&f.env, &f.scope))
                            .unwrap()
                            .entries
                            .contains_key("output-style:STE:pi"),
                        historical.is_some(),
                        "{transition}/{discard}: installation retained"
                    );
                }
                if transition == "historical-disabled" && obstacle != "directory" {
                    // Named removal reloads the fixture lock, not the planner's record.
                    let lock_path = lock::lock_path(&f.env, &f.scope);
                    lock::save(&lock_path, &record).unwrap();
                    let saved = lock::load(&lock_path).unwrap();
                    let entry = &saved.entries["output-style:STE:pi"];
                    assert!(!entry.enabled);
                    assert!(matches!(
                        entry.output_style,
                        Some(lock::OutputStyleRecord::Block { .. })
                    ));
                    let report = engine::ops::remove(
                        &f.env,
                        &f.scope,
                        &["STE".into()],
                        Some(ItemKind::OutputStyle),
                        false,
                    )
                    .unwrap();
                    apply::execute(&f.env, &report.plan).unwrap();
                    assert_eq!(fs::read_to_string(&append).unwrap(), user);
                    assert!(
                        lock::load(&lock::lock_path(&f.env, &f.scope))
                            .unwrap()
                            .entries
                            .is_empty()
                    );
                }
            }
        }
    }
}

#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
#[allow(
    clippy::too_many_lines,
    reason = "keeps cleanup and edit-hold rows in one table"
)]
fn orphan_cleanup_removes_owned_content_and_holds_each_edited_route() {
    for global in [false, true] {
        for edit in [
            "clean",
            "claude-file",
            "pi-block",
            "claude-setting",
            "missing-setting",
            "disabled",
            "disabled-user-block",
        ] {
            let f = fixture(global, &[HarnessId::Claude, HarnessId::Pi]);
            let (style, settings, append) = paths(&f);
            fs::write(&settings, "{\"model\":\"opus\"}\n").unwrap();
            fs::write(&append, "Before.\n").unwrap();
            install(&f);
            let current = fs::read_to_string(&append).unwrap();
            fs::write(&append, format!("{current}After.\n")).unwrap();
            let manifest_path = manifest::manifest_path(&f.env, &f.scope);
            let original = fs::read_to_string(&manifest_path).unwrap();
            match edit {
                "claude-file" => fs::write(&style, "User document.\n").unwrap(),
                "pi-block" => fs::write(
                    &append,
                    fs::read_to_string(&append)
                        .unwrap()
                        .replace("Write short sentences.", "User block."),
                )
                .unwrap(),
                "claude-setting" => fs::write(
                    &settings,
                    "{\"outputStyle\":\"Learning\",\"model\":\"opus\"}\n",
                )
                .unwrap(),
                "missing-setting" => fs::write(&settings, "{\"model\":\"opus\"}\n").unwrap(),
                "disabled" | "disabled-user-block" => {
                    fs::write(&manifest_path, format!("{original}enabled = false\n")).unwrap();
                    install(&f);
                    if edit == "disabled-user-block" {
                        fs::write(&append, "Before.\n<!-- kendex:append-system output-style-STE begin -->\nUser block.\n<!-- kendex:append-system output-style-STE end -->\nAfter.\n").unwrap();
                    }
                }
                "clean" => {}
                _ => unreachable!(),
            }
            let before_append = fs::read(&append).unwrap();
            let before_settings = fs::read(&settings).unwrap();
            let before_style = fs::read(&style).ok();
            fs::write(
                &manifest_path,
                original.split("[output-styles.STE]").next().unwrap(),
            )
            .unwrap();
            let manifest = manifest::load_current(&manifest_path).unwrap().unwrap();
            let record = lock::load(&lock::lock_path(&f.env, &f.scope)).unwrap();
            let report = engine::plan_scope(
                &f.env,
                &f.scope,
                &manifest,
                &record,
                &engine::PlanOptions {
                    remove_orphans: true,
                    ..Default::default()
                },
            )
            .unwrap();
            let hold_claude = matches!(edit, "claude-file" | "claude-setting" | "missing-setting");
            let hold_pi = edit == "pi-block";
            assert_eq!(
                report
                    .drift
                    .iter()
                    .filter(|row| row.state == engine::DriftState::Conflict)
                    .count(),
                usize::from(hold_claude) + usize::from(hold_pi),
                "{edit}: conflict count"
            );
            apply::execute(&f.env, &report.plan).unwrap();
            let record = lock::load(&lock::lock_path(&f.env, &f.scope)).unwrap();
            assert_eq!(
                record.entries.contains_key("output-style:STE:claude"),
                hold_claude,
                "{edit}"
            );
            assert_eq!(
                record.entries.contains_key("output-style:STE:pi"),
                hold_pi,
                "{edit}"
            );
            if hold_claude {
                assert_eq!(fs::read(&style).ok(), before_style);
                assert_eq!(fs::read(&settings).unwrap(), before_settings);
            } else {
                assert!(!style.exists());
                assert!(!style.with_file_name("STE.md.disabled").exists());
                assert_eq!(
                    serde_json::from_slice::<serde_json::Value>(&fs::read(&settings).unwrap())
                        .unwrap(),
                    serde_json::json!({"model":"opus"})
                );
            }
            if hold_pi || edit == "disabled-user-block" {
                assert_eq!(fs::read(&append).unwrap(), before_append);
            } else {
                assert_eq!(fs::read_to_string(&append).unwrap(), "Before.\n\nAfter.\n");
            }
        }
    }
}

#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
fn missing_content_refreshes_and_upstream_changes_update_each_route() {
    for global in [false, true] {
        let f = fixture(global, &[HarnessId::Claude, HarnessId::Pi]);
        install(&f);
        let (style, _, append) = paths(&f);
        fs::remove_file(&style).unwrap();
        fs::write(&append, "Personal text.\n").unwrap();
        let report = engine::audit(&f.env, &f.scope).unwrap();
        assert_eq!(
            report
                .drift
                .iter()
                .filter(|row| row.kind == ItemKind::OutputStyle)
                .count(),
            2
        );
        apply::execute(&f.env, &report.plan).unwrap();
        let updated = STYLE.replace("Write short sentences.", "Use active voice.");
        fs::write(f.source.join("output-styles/STE.md"), &updated).unwrap();
        install(&f);
        assert_eq!(fs::read_to_string(&style).unwrap(), updated);
        assert!(
            fs::read_to_string(&append)
                .unwrap()
                .contains("Use active voice.")
        );
        assert!(engine::audit(&f.env, &f.scope).unwrap().drift.is_empty());
    }
}

#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
fn two_styles_refuse_before_any_scope_write() {
    let f = fixture(false, &[HarnessId::Claude]);
    let path = manifest::manifest_path(&f.env, &f.scope);
    let original = fs::read_to_string(&path).unwrap();
    let input = format!("{original}\n[output-styles.other]\nsource = \"cat\"\n");
    assert!(
        matches!(manifest::parse_text(&path, &input), Err(kendex_core::error::CoreError::ManifestInvalid { findings, .. }) if findings.iter().any(|finding| finding.location == "output-styles"))
    );
    let mut typed = manifest::load_current(&path).unwrap().unwrap();
    typed
        .output_styles
        .insert("other".into(), typed.output_styles["STE"].clone());
    assert!(
        engine::plan_scope(
            &f.env,
            &f.scope,
            &typed,
            &lock::Lock::default(),
            &engine::PlanOptions::default()
        )
        .is_err()
    );
    assert_eq!(fs::read_to_string(&path).unwrap(), original);
    assert!(!paths(&f).0.exists());
}

#[test]
#[allow(clippy::unwrap_used, reason = "fixture inspection")]
fn unsupported_targets_are_reported_without_instruction_files() {
    let f = fixture(false, &HarnessId::ALL);
    install(&f);
    let report = engine::audit(&f.env, &f.scope).unwrap();
    for harness in [
        HarnessId::Codex,
        HarnessId::Copilot,
        HarnessId::Gemini,
        HarnessId::Opencode,
        HarnessId::Cursor,
        HarnessId::Antigravity,
    ] {
        assert!(
            report
                .notes
                .iter()
                .any(|note| note.contains(&format!("harness={}", harness.name()))),
            "{harness:?}: unsupported-target note missing"
        );
    }
    assert!(!f.project.join("AGENTS.md").exists());
    assert!(!f.project.join(".github/copilot-instructions.md").exists());
}

#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
fn linked_directories_land_once_and_linked_settings_refuse() {
    use std::os::unix::fs::symlink;
    let f = fixture(false, &[HarnessId::Claude, HarnessId::Pi]);
    let (_, settings, _) = paths(&f);
    let shared = f.project.join("shared-pi");
    fs::create_dir_all(&shared).unwrap();
    fs::remove_dir(f.project.join(".pi")).unwrap();
    symlink(&shared, f.project.join(".pi")).unwrap();
    let report = engine::audit(&f.env, &f.scope).unwrap();
    assert_eq!(report.plan.ops.iter().filter(|planned| matches!(&planned.op, apply::Op::EditFile { path, .. } if *path == shared.join("APPEND_SYSTEM.md"))).count(), 1);
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(engine::audit(&f.env, &f.scope).unwrap().drift.is_empty());
    let outside = f.env.home.join("user-settings.json");
    fs::rename(&settings, &outside).unwrap();
    symlink(&outside, &settings).unwrap();
    let before = fs::read(&outside).unwrap();
    let report = engine::audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.kind == ItemKind::OutputStyle
                && row.harness == HarnessId::Claude
                && row.state == engine::DriftState::Conflict)
    );
    apply::execute(&f.env, &report.plan).unwrap();
    assert_eq!(fs::read(&outside).unwrap(), before);
    for global in [false, true] {
        let f = fixture(global, &[HarnessId::Pi]);
        install(&f);
        let (_, _, append) = paths(&f);
        if !global {
            let root = kendex_core::harness::pi::scope_root(&f.env, &Scope::Global);
            fs::write(
                root.join("APPEND_SYSTEM.md"),
                kendex_core::configedit::upsert_marker_block(
                    "",
                    "output-style-global",
                    "Global style.",
                ),
            )
            .unwrap();
        }
        let outside = f.env.home.join("personal-append.md");
        fs::rename(&append, &outside).unwrap();
        symlink(&outside, &append).unwrap();
        let before = fs::read(&outside).unwrap();
        let manifest = manifest::load_current(&manifest::manifest_path(&f.env, &f.scope))
            .unwrap()
            .unwrap();
        let record = lock::load(&lock::lock_path(&f.env, &f.scope)).unwrap();
        let report = engine::plan_scope(
            &f.env,
            &f.scope,
            &manifest,
            &record,
            &engine::PlanOptions {
                overwrite_edited: true,
                ..Default::default()
            },
        )
        .unwrap();
        assert!(
            report
                .drift
                .iter()
                .any(|row| row.state == engine::DriftState::Conflict)
        );
        apply::execute(&f.env, &report.plan).unwrap();
        assert_eq!(fs::read(&outside).unwrap(), before);
        assert!(append.is_symlink());
    }
}

#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup")]
fn a_link_leaving_the_project_refuses_the_style_write() {
    let f = fixture(false, &[HarnessId::Pi]);
    let outside = f.env.home.join("outside-pi");
    fs::create_dir_all(&outside).unwrap();
    fs::remove_dir(f.project.join(".pi")).unwrap();
    std::os::unix::fs::symlink(&outside, f.project.join(".pi")).unwrap();
    assert!(matches!(
        engine::audit(&f.env, &f.scope),
        Err(kendex_core::error::CoreError::ScopeEscape { .. })
    ));
    assert!(!outside.join("APPEND_SYSTEM.md").exists());
}

#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
fn a_same_byte_settings_link_arriving_after_preview_is_refused() {
    let f = fixture(false, &[HarnessId::Claude]);
    let (_, settings, _) = paths(&f);
    fs::write(&settings, "{\"model\":\"opus\"}\n").unwrap();
    let report = engine::audit(&f.env, &f.scope).unwrap();
    let target = f.project.join("personal-settings.json");
    fs::rename(&settings, &target).unwrap();
    std::os::unix::fs::symlink(&target, &settings).unwrap();
    let before = fs::read(&target).unwrap();
    assert!(apply::execute(&f.env, &report.plan).is_err());
    assert_eq!(fs::read(&target).unwrap(), before);
    assert!(!paths(&f).0.exists());
}
