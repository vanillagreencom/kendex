#![cfg(unix)]

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

#[path = "../../test_util.rs"]
mod test_util;
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
        let refresh = run(
            &home,
            &project,
            &["refresh", "--scope", scope_name, "--yes"],
        );
        assert!(!refresh.status.success(), "{defect}: {}", said(&refresh));
        assert!(said(&refresh).contains("update-pi"), "{}", said(&refresh));
        let repeated = run(
            &home,
            &project,
            &["refresh", "--scope", scope_name, "--yes"],
        );
        assert!(!repeated.status.success(), "{defect}: {}", said(&repeated));
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
