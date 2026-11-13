//! `kendex project settings` reports a difference, each value as the
//! loaders read it, and writes nothing in any project it reads.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::test_util::{fixture_env, rooted, source_path};
use kendex_core::env::Env;
use kendex_core::settings::AppSettings;

const TEMPLATE: &str = "[env]\n# How deep.\nDEPTH = \"2\"\n";

/// Every file under `root` and its bytes, by path.
#[allow(clippy::expect_used, reason = "fixture preconditions")]
fn snapshot(root: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    let mut out = BTreeMap::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        for entry in fs::read_dir(&dir).expect("project folder reads") {
            let path = entry.expect("project entry reads").path();
            match path.is_dir() {
                true => pending.push(path),
                false => {
                    let bytes = fs::read(&path).expect("project file reads");
                    out.insert(path, bytes);
                }
            }
        }
    }
    out
}

/// Two values that differ only in their inner spaces. The report is the
/// command's result, so each value is shown spelled as the loaders read
/// it, in either rendering.
#[test]
fn a_difference_is_reported_and_no_project_file_changes() {
    for look in ["plain", "pretty"] {
        report_in(look);
    }
}

#[allow(clippy::expect_used, reason = "fixture preconditions")]
fn report_in(look: &str) {
    let tmp = tempfile::tempdir().expect("fixture home");
    let home = rooted(&tmp);
    let env = Env::host_rooted(&home);
    let catalog = home.join("catalog");
    let skill = catalog.join("skills/review");
    fs::create_dir_all(&skill).expect("skill folder");
    fs::write(
        skill.join("SKILL.md"),
        "---\nname: review\ndescription: review changes\n---\nBody.\n",
    )
    .expect("skill");
    fs::write(skill.join("kendex.settings.toml.example"), TEMPLATE).expect("template");
    let mut projects = Vec::new();
    for (name, depth) in [("app", "a  b"), ("api", "a b")] {
        let project = home.join(name);
        fs::create_dir_all(project.join(".claude")).expect("project folder");
        fs::write(
            project.join("kendex.toml"),
            format!(
                "schema = 8\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.review]\nsource = \"cat\"\n",
                source_path(&catalog)
            ),
        )
        .expect("manifest");
        fs::write(
            project.join("kendex.settings.toml"),
            format!("[env]\n# How deep.\nDEPTH = \"{depth}\"\n"),
        )
        .expect("settings");
        fs::write(project.join(".env.local"), "OTHER='x'\n").expect("private file");
        projects.push(project);
    }
    fs::create_dir_all(env.settings_file().parent().expect("settings parent"))
        .expect("settings directory");
    fs::write(
        env.settings_file(),
        toml::to_string(&AppSettings {
            projects: projects.clone(),
            ..Default::default()
        })
        .expect("settings serialize"),
    )
    .expect("registry");
    let before: Vec<_> = projects.iter().map(|project| snapshot(project)).collect();

    let output = Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(["project", "settings"])
        .current_dir(&home)
        .env_clear()
        .envs(fixture_env(&home))
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("KENDEX_UI", look)
        .output()
        .expect("kendex runs");

    assert!(output.status.success(), "{look}: {output:?}");
    let shown = console::strip_ansi_codes(&String::from_utf8_lossy(&output.stderr)).into_owned();
    for value in ["\"a  b\"", "\"a b\""] {
        assert!(
            shown.lines().any(|line| line.contains(value)),
            "{look}: {value} is not shown in {shown}"
        );
    }
    let after: Vec<_> = projects.iter().map(|project| snapshot(project)).collect();
    assert_eq!(before, after, "{look}");
}
