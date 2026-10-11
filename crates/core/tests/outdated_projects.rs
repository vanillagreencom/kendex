//! The registry notice reads the original root schema, without migration or writes.

use std::fs;

use crate::test_util::rooted;
use kendex_core::env::{Env, FakeOs};
use kendex_core::{manifest, settings};

#[test]
#[allow(clippy::expect_used, reason = "fixture preconditions")]
fn only_a_readable_older_root_schema_is_outdated() {
    let tmp = tempfile::tempdir().expect("fixture home");
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let rows = [
        ("older", Some("schema = 6\n"), true),
        ("current", Some("schema = 7\n"), false),
        ("newer", Some("schema = 8\n"), false),
        ("no-file", None, false),
        ("unparsable", Some("schema = 6\n["), false),
        ("gone", None, false),
        ("no-schema", Some("[project]\nschema = 6\n"), false),
        ("string-schema", Some("schema = '6'\n"), false),
        ("unreadable", None, false),
    ];
    let mut projects = Vec::new();
    for (name, text, _) in rows {
        let project = home.join(name);
        if name != "gone" {
            fs::create_dir(&project).expect("project directory");
        }
        if let Some(text) = text {
            fs::write(Env::project_manifest_file(&project), text).expect("manifest fixture");
        }
        if name == "unreadable" {
            fs::create_dir(Env::project_manifest_file(&project)).expect("unreadable file path");
        }
        projects.push(project);
    }
    let preferences = settings::AppSettings {
        projects: projects.clone(),
        ..Default::default()
    };
    fs::create_dir_all(env.settings_file().parent().expect("settings parent"))
        .expect("settings directory");
    fs::write(
        env.settings_file(),
        toml::to_string(&preferences).expect("settings serialize"),
    )
    .expect("settings fixture");

    let outdated = manifest::outdated_projects(&env);
    for ((name, text, expected), project) in rows.into_iter().zip(&projects) {
        assert_eq!(outdated.contains(project), expected, "{name}");
        if let Some(text) = text {
            assert_eq!(
                fs::read_to_string(Env::project_manifest_file(project)).expect("manifest readback"),
                text,
                "{name}"
            );
        }
    }
    assert_eq!(outdated, vec![home.join("older")]);

    fs::write(home.join("older/kendex.toml"), "schema = 7\n").expect("upgraded manifest");
    assert!(manifest::outdated_projects(&env).is_empty());
    fs::write(env.settings_file(), "schema = [").expect("broken settings");
    assert!(manifest::outdated_projects(&env).is_empty());
}
