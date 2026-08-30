//! A plugin declaration names the tool it belongs to. More than one harness
//! reads an `enabledPlugins` map of its own, and a plugin someone installed
//! for one of them is not a plugin the others have — switching it on
//! everywhere would be a claim about software the user never installed.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;
use serde_json::Value;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
}

#[allow(clippy::unwrap_used)]
fn fixture(plugins: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    for root in [".claude", ".copilot"] {
        fs::create_dir_all(home.join(root)).unwrap();
    }
    let manifest = env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::write(
        &manifest,
        format!("schema = 6\n\n[install]\nharnesses = [\"claude\", \"copilot\"]\n\n{plugins}"),
    )
    .unwrap();
    Fixture { env, _tmp: tmp }
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) -> kendex_core::engine::EngineReport {
    let report = audit(&f.env, &Scope::Global).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    report
}

fn claude_settings(f: &Fixture) -> PathBuf {
    f.env.home.join(".claude/settings.json")
}

fn copilot_settings(f: &Fixture) -> PathBuf {
    f.env.home.join(".copilot/settings.json")
}

#[allow(clippy::unwrap_used)]
fn json(path: &Path) -> Value {
    serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_copilot_plugin_lands_in_copilots_settings_and_nowhere_else() {
    let f = fixture("[plugins.\"fmt@copilot-plugins\"]\nenabled = true\nharness = \"copilot\"\n");
    apply_now(&f);

    assert_eq!(
        json(&copilot_settings(&f))["enabledPlugins"]["fmt@copilot-plugins"],
        true
    );
    assert!(
        !claude_settings(&f).exists(),
        "a copilot plugin never writes Claude Code's settings"
    );
    assert!(audit(&f.env, &Scope::Global).unwrap().drift.is_empty());
}

/// A declaration written before the harness was part of it belongs to Claude
/// Code: the only tool whose plugin switch kendex ever wrote.
#[test]
#[allow(clippy::unwrap_used)]
fn a_declaration_with_no_harness_stays_claude_codes() {
    let f = fixture("[plugins.\"fmt@marketplace\"]\nenabled = true\n");
    apply_now(&f);

    assert_eq!(
        json(&claude_settings(&f))["enabledPlugins"]["fmt@marketplace"],
        true
    );
    assert!(!copilot_settings(&f).exists());

    // The next write records what was read, so the file stops relying on the
    // default the moment anything touches it.
    let manifest = kendex_core::engine::ops::manifest_for_mutation(&f.env, &Scope::Global).unwrap();
    assert_eq!(
        manifest.plugins["fmt@marketplace"].harness,
        kendex_core::model::HarnessId::Claude
    );
}

/// Both tools read a map with the same name, so the two declarations have to
/// stay in the two files rather than meeting in one.
#[test]
#[allow(clippy::unwrap_used)]
fn each_tools_plugins_stay_in_that_tools_file() {
    let f = fixture(
        "[plugins.\"fmt@copilot-plugins\"]\nenabled = true\nharness = \"copilot\"\n\n[plugins.\"lint@marketplace\"]\nenabled = false\nharness = \"claude\"\n",
    );
    apply_now(&f);

    let copilot = json(&copilot_settings(&f))["enabledPlugins"].clone();
    let claude = json(&claude_settings(&f))["enabledPlugins"].clone();
    assert_eq!(copilot["fmt@copilot-plugins"], true);
    assert!(copilot.get("lint@marketplace").is_none());
    assert_eq!(claude["lint@marketplace"], false);
    assert!(claude.get("fmt@copilot-plugins").is_none());
}

/// A machine that never ran the newer Copilot CLI keeps its settings
/// somewhere else entirely, and a toggle written to the current file would
/// be one nothing reads.
#[test]
#[allow(clippy::unwrap_used)]
fn a_machine_on_copilots_older_settings_file_is_told_rather_than_written_to() {
    let f = fixture("[plugins.\"fmt@copilot-plugins\"]\nenabled = true\nharness = \"copilot\"\n");
    fs::write(f.env.home.join(".copilot/config.json"), "{}").unwrap();

    let report = apply_now(&f);
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("older config.json") && note.contains("nothing was switched")),
        "{:?}",
        report.notes
    );
    assert!(!copilot_settings(&f).exists());
}
