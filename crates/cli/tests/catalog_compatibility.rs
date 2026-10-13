//! Consumer refresh automation reads the keyed compatibility refusal and
//! nonzero exit. A refused selected revision cannot leave another scope installed.
#![cfg(unix)]

use std::fs;

use kendex_core::env::Env;

use crate::deps_cli::tree;
use crate::test_util::{rooted, source_path};
use crate::verify_records::{commit, git, kendex, repository, said, write};

const FUTURE: &str = "999999.0.0";

#[test]
#[allow(clippy::unwrap_used)]
fn malformed_minima_emit_one_machine_read_refusal() {
    for (key, min, reason) in [
        ("min_kendex = true", "boolean", "expected-string"),
        (
            "min_kendex = \"bad\\nvalue engine=forged\"",
            "bad\\nvalue\\u{20}engine=forged",
            "invalid-semver",
        ),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let catalog = home.join("catalog");
        write(&catalog.join("kendex.toml"), key);
        let output = kendex(
            &home,
            &home,
            &["check", "--catalog", catalog.to_str().unwrap()],
        );
        assert_eq!(output.status.code(), Some(1), "{}", said(&output));
        let expected = format!(
            "Error: catalog-min-invalid min={min} engine={} reason={reason}",
            env!("CARGO_PKG_VERSION")
        );
        assert_eq!(
            String::from_utf8_lossy(&output.stderr)
                .lines()
                .filter(|line| line.contains("catalog-min-invalid"))
                .collect::<Vec<_>>(),
            [expected]
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn incompatible_scope_stops_the_selected_command_before_any_install_write() {
    for args in [
        &["apply", "--scope", "all", "-y", "--leave"][..],
        &["refresh", "--scope", "all", "-y", "--leave"],
        &["disable", "good", "--scope", "all", "-y", "--leave"],
        &["remove", "good", "--scope", "all", "--leave"],
        &["verify", "--scope", "all"],
        &["update-pi", "--scope", "all"],
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = Env::host_rooted(&home);
        let project = home.join("consumer");
        fs::create_dir_all(project.join(".claude")).unwrap();
        for (scope, name, min) in [
            (project.join("kendex.toml"), "good", "0.0.0"),
            (env.global_manifest_file(), "gated", FUTURE),
        ] {
            let catalog = home.join(name);
            write(
                &catalog.join("kendex.toml"),
                &format!("min_kendex = '{min}'\n"),
            );
            write(
                &catalog.join(format!("skills/{name}/SKILL.md")),
                &format!("---\nname: {name}\ndescription: fixture\n---\nBody.\n"),
            );
            write(
                &scope,
                &format!(
                    "schema = 7\n[sources.cat]\n{}\n[install]\nharnesses = ['claude']\nmethod = 'copy'\n[skills.{name}]\nsource = 'cat'\n",
                    source_path(&catalog)
                ),
            );
        }
        let before = tree(&home);
        let output = kendex(&home, &project, args);
        assert_eq!(output.status.code(), Some(1), "{}", said(&output));
        // The machine-read line consumer refresh automation records must name both versions.
        let expected = format!(
            "Error: catalog-needs-engine min={FUTURE} engine={}",
            env!("CARGO_PKG_VERSION")
        );
        assert_eq!(
            String::from_utf8_lossy(&output.stderr)
                .lines()
                .filter(|line| line.contains("catalog-needs-engine"))
                .collect::<Vec<_>>(),
            [expected]
        );
        // Executable registration is CLI bootstrap. Every other file and
        // directory must stay identical, including package and project state.
        let bootstrap = env.installed_command_file();
        let mut expected = before;
        expected.push((
            format!("file:{}", bootstrap.strip_prefix(&home).unwrap().display()),
            fs::read(&bootstrap).unwrap(),
        ));
        let mut parent = bootstrap.parent().unwrap();
        while parent != home {
            let key = format!("dir:{}", parent.strip_prefix(&home).unwrap().display());
            if !expected.iter().any(|(path, _)| path == &key) {
                expected.push((key, Vec::new()));
            }
            parent = parent.parent().unwrap();
        }
        expected.sort();
        assert_eq!(
            tree(&home),
            expected,
            "{} changed installed package or project state",
            args[0]
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn compatible_subscription_tip_does_not_hide_an_incompatible_item_or_bundle_pin() {
    for bundle in [false, true] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = home.join("consumer");
        let catalog = home.join("catalog");
        fs::create_dir_all(project.join(".claude")).unwrap();
        write(
            &catalog.join("skills/gated/SKILL.md"),
            "---\nname: gated\ndescription: fixture\n---\nBody.\n",
        );
        write(
            &catalog.join("kendex.toml"),
            &format!("min_kendex = '{FUTURE}'\n[bundles.starter]\nskills = ['gated']\n"),
        );
        repository(&catalog);
        git(&catalog, &["config", "gc.auto", "0"]);
        git(&catalog, &["config", "maintenance.auto", "false"]);
        commit(&catalog, "incompatible revision");
        let pin = git(&catalog, &["rev-parse", "HEAD"]).trim().to_owned();
        write(
            &catalog.join("kendex.toml"),
            "min_kendex = '0.0.0'\n[bundles.starter]\nskills = ['gated']\n",
        );
        commit(&catalog, "compatible tip");
        let table = if bundle {
            "[bundles.starter]"
        } else {
            "[skills.gated]"
        };
        write(
            &project.join("kendex.toml"),
            &format!(
                "schema = 7\n[sources.cat]\nrepo = 'file://{}'\n[install]\nharnesses = ['claude']\nmethod = 'copy'\n{table}\nsource = 'cat'\nrev = '{pin}'\n",
                catalog.display()
            ),
        );
        let before = tree(&project);
        let output = kendex(&home, &project, &["refresh", "-y", "--leave"]);
        assert_eq!(output.status.code(), Some(1), "{}", said(&output));
        assert!(
            said(&output).contains(&format!(
                "catalog-needs-engine min={FUTURE} engine={}",
                env!("CARGO_PKG_VERSION")
            )),
            "{}",
            said(&output)
        );
        assert_eq!(tree(&project), before);
        assert!(!Env::host_rooted(&home).global_lock_file().exists());
    }
}
