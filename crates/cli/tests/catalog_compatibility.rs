//! Consumer refresh automation reads the keyed compatibility refusal and
//! nonzero exit. A refused selected revision cannot leave another scope installed.
#![cfg(unix)]

use std::fs;

use kendex_core::env::Env;

use crate::deps_cli::tree;
use crate::test_util::{rooted, source_path};
use crate::verify_records::{commit, git, kendex, repository, said, write};

const FUTURE: &str = "999999.0.0";

#[allow(clippy::unwrap_used)]
fn assert_refusal(output: &std::process::Output) {
    assert_eq!(output.status.code(), Some(1), "{}", said(output));
    // Consumer refresh automation reads this line and records both versions.
    assert_eq!(
        String::from_utf8_lossy(&output.stderr)
            .lines()
            .filter(|line| line.contains("catalog-needs-engine"))
            .collect::<Vec<_>>(),
        [format!(
            "Error: catalog-needs-engine min={FUTURE} engine={}",
            env!("CARGO_PKG_VERSION")
        )]
    );
}

/// Executable registration is CLI bootstrap. Every other file and
/// directory stays identical, including package and project state.
#[allow(clippy::unwrap_used)]
fn with_command_bootstrap(
    env: &Env,
    root: &std::path::Path,
    mut expected: Vec<(String, Vec<u8>)>,
) -> Vec<(String, Vec<u8>)> {
    let bootstrap = env.installed_command_file();
    let Ok(relative) = bootstrap.strip_prefix(root) else {
        return expected;
    };
    let key = format!("file:{}", relative.display());
    if !expected.iter().any(|(path, _)| path == &key) {
        expected.push((key, fs::read(&bootstrap).unwrap()));
    }
    let mut parent = bootstrap.parent().unwrap();
    while parent != root {
        let key = format!("dir:{}", parent.strip_prefix(root).unwrap().display());
        if !expected.iter().any(|(path, _)| path == &key) {
            expected.push((key, Vec::new()));
        }
        parent = parent.parent().unwrap();
    }
    expected.sort();
    expected
}

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
        assert_eq!(
            tree(&home),
            with_command_bootstrap(&env, &home, before),
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

/// Older readers can install a catalog without checking its minimum. Keep
/// the real add-produced record, but date one surviving entry to that
/// historical commit. Its source and rendered bytes are otherwise identical.
/// A removed historical item is not selected; a surviving one still is.
#[test]
#[allow(clippy::unwrap_used)]
fn held_revisions_are_checked_before_removal_or_recorded_verification_of_any_scope() {
    for (case, args, recorded_verify, allowed, declared_after) in [
        (
            "surviving revision",
            &["remove", "good", "--scope", "all", "--leave"][..],
            false,
            false,
            true,
        ),
        (
            "recorded verification",
            &["verify", "--at-record", "--scope", "all"][..],
            true,
            false,
            true,
        ),
        (
            "removed revision",
            &["remove", "surviving", "--scope", "all", "--leave"][..],
            false,
            true,
            false,
        ),
        (
            "uninstalled revision",
            &[
                "remove",
                "surviving",
                "--keep-declaration",
                "--scope",
                "all",
                "--leave",
            ][..],
            false,
            true,
            true,
        ),
        (
            "removed revision with sweep",
            &[
                "remove",
                "surviving",
                "--sweep",
                "--scope",
                "all",
                "--leave",
            ][..],
            false,
            true,
            false,
        ),
    ] {
        check_held_removal_case(case, args, recorded_verify, allowed, declared_after);
    }
}

#[allow(clippy::unwrap_used)]
fn held_removal_world(
    recorded_verify: bool,
) -> (
    tempfile::TempDir,
    std::path::PathBuf,
    std::path::PathBuf,
    Env,
) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::host_rooted(&home);
    let project = home.join("consumer");
    let catalog = home.join("catalog");
    fs::create_dir_all(project.join(".claude")).unwrap();
    for name in ["good", "surviving"] {
        write(
            &catalog.join(format!("skills/{name}/SKILL.md")),
            &format!("---\nname: {name}\ndescription: fixture\n---\nBody.\n"),
        );
    }
    write(
        &catalog.join("kendex.toml"),
        &format!("min_kendex = '{FUTURE}'\n"),
    );
    repository(&catalog);
    commit(&catalog, "historical minimum");
    let historical = git(&catalog, &["rev-parse", "HEAD"]).trim().to_owned();
    write(&catalog.join("kendex.toml"), "min_kendex = '0.0.0'\n");
    commit(&catalog, "compatible tip");
    let tip = git(&catalog, &["rev-parse", "HEAD"]).trim().to_owned();
    let repo = format!("file://{}", catalog.display());
    for path in [project.join("kendex.toml"), env.global_manifest_file()] {
        write(
            &path,
            &format!(
                "schema = 7\n[sources.cat]\nrepo = '{repo}'\nrev = '{tip}'\n[install]\nharnesses = ['claude']\nmethod = 'copy'\n[skills.good]\nsource = 'cat'\n[skills.surviving]\nsource = 'cat'\n"
            ),
        );
    }
    for args in [
        &["source", "refresh", "--scope", "all"][..],
        &[
            "add",
            "--skill",
            "good",
            "--skill",
            "surviving",
            "cat",
            "--throwaway",
            "-y",
            "--leave",
        ],
        &[
            "add",
            "--skill",
            "good",
            "--skill",
            "surviving",
            "cat",
            "-g",
            "-y",
            "--leave",
        ],
    ] {
        let output = kendex(&home, &project, args);
        assert!(output.status.success(), "{}", said(&output));
    }
    kendex_core::remote::sync(&env, &repo, Some(&historical)).unwrap();
    let mut lock = kendex_core::lock::load(&env.global_lock_file()).unwrap();
    let key = kendex_core::lock::entry_key(
        kendex_core::model::ItemKind::Skill,
        "surviving",
        kendex_core::model::HarnessId::Claude,
    );
    let entry = lock.entries.get_mut(&key).unwrap();
    assert_eq!(entry.source_commit.as_deref(), Some(tip.as_str()));
    entry.source_commit = Some(historical);
    kendex_core::lock::save(&env.global_lock_file(), &lock).unwrap();
    if recorded_verify {
        let path = env.global_manifest_file();
        write(
            &path,
            &fs::read_to_string(&path)
                .unwrap()
                .replace(&format!("rev = '{tip}'"), "rev = 'main'"),
        );
        kendex_core::remote::sync(&env, &repo, Some("main")).unwrap();
    }
    (tmp, home, project, env)
}

#[allow(clippy::unwrap_used)]
fn check_held_removal_case(
    case: &str,
    args: &[&str],
    recorded_verify: bool,
    allowed: bool,
    declared_after: bool,
) {
    let (_tmp, home, project, env) = held_removal_world(recorded_verify);
    let before = tree(&home);
    let good_paths = [
        project.join(".claude/skills/good/SKILL.md"),
        home.join(".claude/skills/good/SKILL.md"),
    ];
    let good_before = good_paths.each_ref().map(|path| fs::read(path).unwrap());
    let manifests = [project.join("kendex.toml"), env.global_manifest_file()];
    let manifest_before = manifests.each_ref().map(|path| fs::read(path).unwrap());
    let output = kendex(&home, &project, args);
    if allowed {
        assert!(output.status.success(), "{case}: {}", said(&output));
        for (path, lock_path, installed) in [
            (
                &manifests[0],
                project.join(".kendex-lock.json"),
                project.join(".claude/skills/surviving/SKILL.md"),
            ),
            (
                &manifests[1],
                env.global_lock_file(),
                home.join(".claude/skills/surviving/SKILL.md"),
            ),
        ] {
            let manifest = kendex_core::manifest::load_current(path).unwrap().unwrap();
            assert_eq!(
                manifest.skills.contains_key("surviving"),
                declared_after,
                "{case}"
            );
            let lock = kendex_core::lock::load(&lock_path).unwrap();
            assert!(
                !lock.entries.values().any(|entry| entry.name == "surviving"),
                "{case}"
            );
            assert!(!installed.exists(), "{case}");
        }
        assert_eq!(
            good_paths.each_ref().map(|path| fs::read(path).unwrap()),
            good_before,
            "{case}"
        );
        if declared_after {
            assert_eq!(
                manifests.each_ref().map(|path| fs::read(path).unwrap()),
                manifest_before,
                "{case}"
            );
        }
    } else {
        assert_refusal(&output);
        assert_eq!(tree(&home), before, "{case}: {}", said(&output));
    }
    if recorded_verify {
        assert!(
            output.stdout.is_empty(),
            "an earlier scope emitted verification rows: {}",
            said(&output)
        );
    }
}

/// Source edits plan from their resulting manifests. All selected scopes
/// must pass, and a source the request disables or removes is not selected.
#[test]
#[allow(clippy::unwrap_used)]
fn source_changes_check_every_post_change_scope_before_install_writes() {
    for (action, removes_gate) in [
        ("add", false),
        ("enable", false),
        ("disable", false),
        ("remove", false),
        ("disable", true),
        ("remove", true),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = Env::host_rooted(&home);
        let project = home.join("consumer");
        let compatible = home.join("compatible");
        let gated = home.join("gated");
        fs::create_dir_all(project.join(".claude")).unwrap();
        write(&compatible.join("kendex.toml"), "min_kendex = '0.0.0'\n");
        write(
            &gated.join("kendex.toml"),
            &format!("min_kendex = '{FUTURE}'\n"),
        );
        for (path, catalog) in [
            (project.join("kendex.toml"), &compatible),
            (env.global_manifest_file(), &gated),
        ] {
            write(
                &path,
                &format!(
                    "schema = 7\n[sources.cat]\n{}\n[sources.spare]\n{}\nenabled = {}\n[install]\nharnesses = ['claude']\nmethod = 'copy'\n",
                    source_path(catalog),
                    source_path(&compatible),
                    action != "enable"
                ),
            );
        }
        let before_project = tree(&project);
        let global_root = env.global_manifest_file().parent().unwrap().to_path_buf();
        let before_global = tree(&global_root);
        let target = if removes_gate {
            "cat"
        } else if action == "add" {
            "new"
        } else {
            "spare"
        };
        let mut args = vec!["source", action, target];
        let reference = compatible.to_str().unwrap();
        if action == "add" {
            args.push(reference);
        }
        args.extend(["--scope", "all", "--leave"]);
        let output = kendex(&home, &project, &args);
        if removes_gate {
            assert!(output.status.success(), "{}", said(&output));
            for path in [project.join("kendex.toml"), env.global_manifest_file()] {
                let manifest = kendex_core::manifest::load_current(&path).unwrap().unwrap();
                if action == "disable" {
                    assert!(!manifest.sources["cat"].enabled);
                } else {
                    assert!(!manifest.sources.contains_key("cat"));
                }
            }
        } else {
            assert_refusal(&output);
            assert_eq!(tree(&project), before_project);
            assert_eq!(
                tree(&global_root),
                with_command_bootstrap(&env, &global_root, before_global)
            );
        }
    }
}
