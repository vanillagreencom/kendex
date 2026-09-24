#![cfg(unix)]

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

use crate::test_util;
use test_util::rooted;

#[allow(clippy::unwrap_used)]
fn run(home: &Path, project: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(project)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", std::env::var_os("PATH").unwrap())
        .output()
        .unwrap()
}

fn said(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

#[allow(clippy::unwrap_used)]
fn assert_linked_settings(settings: &Path, target: &Path) {
    assert!(
        settings
            .symlink_metadata()
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert_eq!(fs::read_link(settings).unwrap(), target);
    let value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(settings).unwrap()).unwrap();
    assert_eq!(value["theme"], "dark");
    let packages = value["packages"].as_array().unwrap();
    assert!(packages.iter().any(|entry| entry == "./packages/pi-other"));
    assert_eq!(
        packages
            .iter()
            .filter(|entry| *entry == "./packages/pi-widgets")
            .count(),
        1
    );
}

/// A refresh settles an unedited copy whose source moved, and leaves every
/// other defect's installed bytes as they stand. True when it settled.
fn refreshed(
    defect: &str,
    refresh: &Output,
    before: Option<Vec<u8>>,
    source: &Path,
    installed: &Path,
) -> bool {
    let settled = defect == "source";
    let printed = said(refresh);
    assert_eq!(refresh.status.success(), settled, "{defect}: {printed}");
    let updated = printed.contains("updated pi-widgets -> 1.0.0");
    assert_eq!(updated, settled, "{defect}: {printed}");
    let expected = match settled {
        true => fs::read(source.join("index.js")).ok(),
        false => before,
    };
    assert_eq!(
        fs::read(installed.join("index.js")).ok(),
        expected,
        "{defect}"
    );
    settled
}

#[test]
fn pi_reports_agree_and_the_printed_remedy_restores_packages() {
    for (defect, global) in ["missing", "partial", "source", "unrecorded"]
        .into_iter()
        .flat_map(|defect| [(defect, false), (defect, true)])
    {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = home.join("project");
        let env = kendex_core::env::Env::host_rooted(&home);
        let scope = if global {
            kendex_core::model::Scope::Global
        } else {
            kendex_core::model::Scope::Project {
                root: project.clone(),
            }
        };
        let scope_name = if global { "global" } else { "project" };
        let manifest = kendex_core::manifest::manifest_path(&env, &scope);
        let source = if global { &home } else { &project }.join("catalog/pi-extensions/pi-widgets");
        fs::create_dir_all(&source).unwrap();
        fs::create_dir_all(manifest.parent().unwrap()).unwrap();
        fs::create_dir_all(project.join(".agents")).unwrap();
        fs::write(manifest, "schema = 6\n[sources.cat]\npath = 'catalog'\n[pi-extensions.pi-widgets]\nsource = 'cat'\n").unwrap();
        fs::write(
            source.join("package.json"),
            r#"{"name":"pi-widgets","version":"1.0.0","pi":{"extensions":["index.js"]}}"#,
        )
        .unwrap();
        fs::write(source.join("index.js"), "export const version = 1;\n").unwrap();
        if defect != "unrecorded" {
            let installed = run(&home, &project, &["update-pi", "--scope", scope_name]);
            assert!(installed.status.success(), "{}", said(&installed));
        }
        let destination = kendex_core::pi_ext::scope_root(&env, &scope)
            .unwrap()
            .join("packages/pi-widgets");
        match defect {
            "missing" => fs::remove_dir_all(&destination).unwrap(),
            "partial" => fs::remove_file(destination.join("index.js")).unwrap(),
            "source" => fs::write(source.join("index.js"), "export const version = 2;\n").unwrap(),
            "unrecorded" => {}
            _ => unreachable!(),
        }
        if defect != "source" {
            let check = run(&home, &project, &["check", "--scope", scope_name]);
            assert_eq!(check.status.code(), Some(1), "{defect}: {}", said(&check));
        }
        let updates = run(&home, &project, &["updates", "--scope", scope_name]);
        assert!(updates.status.success(), "{}", said(&updates));
        assert!(
            said(&updates).contains("pi-extension pi-widgets"),
            "{defect}: {}",
            said(&updates)
        );
        if defect != "unrecorded" {
            let before = fs::read(destination.join("index.js")).ok();
            let refresh = run(
                &home,
                &project,
                &["refresh", "--scope", scope_name, "--yes"],
            );
            if refreshed(defect, &refresh, before, &source, &destination) {
                continue;
            }
        }
        let check = run(&home, &project, &["check", "--scope", scope_name]);
        assert_eq!(check.status.code(), Some(1), "{defect}: {}", said(&check));
        assert!(
            said(&check).contains(&format!("kendex update-pi --scope {scope_name}")),
            "{defect}: {}",
            said(&check)
        );
        let preview = run(
            &home,
            &project,
            &["update-pi", "--scope", scope_name, "--check"],
        );
        assert!(
            said(&preview).contains("1 package(s) can be updated"),
            "{}",
            said(&preview)
        );
        let fixed = run(&home, &project, &["update-pi", "--scope", scope_name]);
        assert!(fixed.status.success(), "{}", said(&fixed));
        assert_eq!(
            fs::read(source.join("index.js")).unwrap(),
            fs::read(destination.join("index.js")).unwrap()
        );
        let check = run(&home, &project, &["check", "--scope", scope_name]);
        assert_eq!(check.status.code(), Some(0), "{defect}: {}", said(&check));
        let refresh = run(
            &home,
            &project,
            &["refresh", "--scope", scope_name, "--yes"],
        );
        assert!(refresh.status.success(), "{}", said(&refresh));
    }
}

#[test]
fn refresh_restores_a_missing_global_registration_through_a_linked_settings_file() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("project");
    let env = kendex_core::env::Env::host_rooted(&home);
    let scope = kendex_core::model::Scope::Global;
    let manifest = kendex_core::manifest::manifest_path(&env, &scope);
    let source = home.join("catalog/pi-extensions/pi-widgets");
    fs::create_dir_all(&source).unwrap();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::create_dir_all(project.join(".agents")).unwrap();
    fs::write(
        manifest,
        "schema = 6\n[sources.cat]\npath = 'catalog'\n[pi-extensions.pi-widgets]\nsource = 'cat'\n",
    )
    .unwrap();
    fs::write(
        source.join("package.json"),
        r#"{"name":"pi-widgets","version":"1.0.0","pi":{"extensions":["index.js"]}}"#,
    )
    .unwrap();
    fs::write(source.join("index.js"), "export const version = 1;\n").unwrap();

    let pi_root = kendex_core::pi_ext::scope_root(&env, &scope).unwrap();
    let settings = pi_root.join("settings.json");
    let private_settings = home.join("private/pi-settings.json");
    fs::create_dir_all(settings.parent().unwrap()).unwrap();
    fs::create_dir_all(private_settings.parent().unwrap()).unwrap();
    fs::write(
        &private_settings,
        r#"{"theme":"dark","packages":["./packages/pi-other"]}"#,
    )
    .unwrap();
    std::os::unix::fs::symlink(&private_settings, &settings).unwrap();

    let installed = run(&home, &project, &["update-pi", "--scope", "global"]);
    assert!(installed.status.success(), "{}", said(&installed));
    assert_linked_settings(&settings, &private_settings);

    let replacement = private_settings.with_extension("replacement");
    fs::write(
        &replacement,
        r#"{"theme":"dark","packages":["./packages/pi-other"]}"#,
    )
    .unwrap();
    fs::rename(replacement, &private_settings).unwrap();
    assert!(
        !fs::read_to_string(&settings)
            .unwrap()
            .contains("pi-widgets")
    );

    let preview = run(
        &home,
        &project,
        &["update-pi", "--scope", "global", "--check"],
    );
    let preview_text = said(&preview);
    assert!(preview.status.success(), "{preview_text}");
    assert!(
        preview_text.contains("stale (package or install record differs)"),
        "{preview_text}"
    );
    assert!(
        preview_text.contains("1 package(s) can be updated"),
        "{preview_text}"
    );

    for _ in 0..2 {
        let refresh = run(&home, &project, &["refresh", "--global", "--yes"]);
        assert!(refresh.status.success(), "{}", said(&refresh));
        assert_linked_settings(&settings, &private_settings);

        let update = run(&home, &project, &["update-pi", "--scope", "global"]);
        assert!(update.status.success(), "{}", said(&update));
        assert_linked_settings(&settings, &private_settings);

        let refresh = run(&home, &project, &["refresh", "--global", "--yes"]);
        assert!(refresh.status.success(), "{}", said(&refresh));
        assert_linked_settings(&settings, &private_settings);
    }
}

#[test]
fn refresh_retries_an_unrecorded_package_after_a_bin_conflict_is_removed() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("project");
    let env = kendex_core::env::Env::host_rooted(&home);
    let scope = kendex_core::model::Scope::Global;
    let manifest = kendex_core::manifest::manifest_path(&env, &scope);
    let source = home.join("catalog/pi-extensions/pi-widgets");
    fs::create_dir_all(&source).unwrap();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::create_dir_all(project.join(".agents")).unwrap();
    fs::write(
        manifest,
        "schema = 6\n[sources.cat]\npath = 'catalog'\n[pi-extensions.pi-widgets]\nsource = 'cat'\n",
    )
    .unwrap();
    fs::write(
        source.join("package.json"),
        r#"{"name":"pi-widgets","version":"1.0.0","bin":{"pi-widgets":"cli.js"},"pi":{"extensions":["index.js"]}}"#,
    )
    .unwrap();
    fs::write(source.join("index.js"), "export const version = 1;\n").unwrap();
    fs::write(source.join("cli.js"), "#!/usr/bin/env node\n").unwrap();

    let pi_root = kendex_core::pi_ext::scope_root(&env, &scope).unwrap();
    let bin = pi_root.join("bin/pi-widgets");
    fs::create_dir_all(bin.parent().unwrap()).unwrap();
    fs::write(&bin, "foreign\n").unwrap();

    let failed = run(&home, &project, &["refresh", "--global", "--yes"]);
    let failed_text = said(&failed);
    assert!(!failed.status.success(), "{failed_text}");
    assert!(
        failed_text.contains("exists and is not a link kendex owns"),
        "{failed_text}"
    );
    assert!(pi_root.join("packages/pi-widgets/index.js").is_file());
    assert!(
        !fs::read_to_string(pi_root.join("settings.json"))
            .unwrap_or_default()
            .contains("pi-widgets")
    );

    fs::remove_file(&bin).unwrap();
    let repaired = run(&home, &project, &["refresh", "--global", "--yes"]);
    assert!(repaired.status.success(), "{}", said(&repaired));
    assert!(bin.is_symlink());
    let settings: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(pi_root.join("settings.json")).unwrap()).unwrap();
    assert_eq!(
        settings["packages"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|entry| *entry == "./packages/pi-widgets")
            .count(),
        1
    );
    let key = kendex_core::lock::entry_key(
        kendex_core::model::ItemKind::PiExtension,
        "pi-widgets",
        kendex_core::model::HarnessId::Pi,
    );
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(&env, &scope)).unwrap();
    assert!(
        lock.entries
            .get(&key)
            .and_then(|entry| entry.rendered_hash.as_ref())
            .is_some()
    );
}
