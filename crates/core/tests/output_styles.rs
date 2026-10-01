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
    assert!(
        report
            .drift
            .iter()
            .all(|row| row.state != engine::DriftState::Conflict),
        "{report:?}"
    );
    apply::execute(&f.env, &report.plan).unwrap();
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
        assert!(report.drift.is_empty(), "{report:?}");
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
                "{observed:?}"
            );
        }
        assert!(!f.project.join("AGENTS.md").exists());
    }
}

#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
fn existing_selections_and_local_settings_remain_user_owned() {
    for global in [false, true] {
        for local in [false, true] {
            let f = fixture(global, &[HarnessId::Claude]);
            let (_, settings, _) = paths(&f);
            let selected = if local {
                settings.with_file_name("settings.local.json")
            } else {
                settings.clone()
            };
            fs::write(
                &selected,
                "{\"outputStyle\":\"Explanatory\",\"model\":\"opus\"}\n",
            )
            .unwrap();
            let before = fs::read(&selected).unwrap();
            install(&f);
            assert_eq!(fs::read(&selected).unwrap(), before);
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
            assert_eq!(fs::read(&selected).unwrap(), before);
        }
    }
}

#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
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
                "{route}: {report:?}"
            );
            apply::execute(&f.env, &report.plan).unwrap();
            assert_eq!(fs::read(&edited).unwrap(), before);
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
            "{harness:?}: {:?}",
            report.notes
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
