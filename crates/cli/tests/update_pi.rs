#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Output};

use kendex_core::process::Hardened;

// Integration-test helpers sit outside #[test] fns, so clippy's
// allow-unwrap-in-tests does not reach them.
#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    let mut paths = vec![home.join("bin")];
    paths.extend(std::env::split_paths(
        &std::env::var_os("PATH").unwrap_or_default(),
    ));
    let path = std::env::join_paths(paths).expect("fixture PATH joins");
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env(
            "KENDEX_GIT_BASE",
            format!("file://{}", home.join("git").display()),
        )
        .env("PATH", path)
        .output()
        .expect("kendex binary runs")
}

#[allow(clippy::unwrap_used)]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(dir)).run().unwrap();
    assert!(output.status.success(), "git {args:?}");
}

#[allow(clippy::unwrap_used)]
fn commit(dir: &Path, message: &str) -> String {
    git(dir, &["add", "-A"]);
    git(
        dir,
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "--quiet",
            "-m",
            message,
        ],
    );
    let output = Hardened::git(&["rev-parse", "HEAD"], Some(dir))
        .run()
        .unwrap();
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

/// A project that declares one pi extension from a local catalog and already
/// has an older copy of it installed under `.pi/packages/`.
#[allow(clippy::unwrap_used)]
fn fixture() -> tempfile::TempDir {
    let tmp = tempfile::tempdir().unwrap();
    let project = tmp.path().join("dev/app");
    write(
        &project.join("kendex.toml"),
        "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n",
    );
    let package = "{\n  \"name\": \"pi-widgets\",\n  \"version\": \"2.0.0\",\n  \"pi\": { \"extensions\": [\"index.js\"] }\n}\n";
    write(
        &project.join("catalog/pi-extensions/pi-widgets/package.json"),
        package,
    );
    write(
        &project.join("catalog/pi-extensions/pi-widgets/index.js"),
        "export const version = 2;\n",
    );

    write(
        &project.join(".pi/packages/pi-widgets/package.json"),
        package,
    );
    write(
        &project.join(".pi/packages/pi-widgets/index.js"),
        "export const version = 1;\n",
    );
    write(
        &project.join(".pi/settings.json"),
        "{\"packages\": [\"./packages/pi-widgets\"]}\n",
    );
    tmp
}

#[test]
fn check_reports_stale_packages_without_touching_them() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    let installed = project.join(".pi/packages/pi-widgets/index.js");

    let output = kendex(tmp.path(), &project, &["update-pi", "--check"]);

    assert!(output.status.success());
    let plan = String::from_utf8_lossy(&output.stdout);
    assert!(plan.contains("pi-widgets"), "{plan}");
    assert!(plan.contains("stale"), "{plan}");
    let summary = String::from_utf8_lossy(&output.stderr);
    assert!(summary.contains("1 package(s) can be updated"), "{summary}");
    assert_eq!(
        fs::read_to_string(&installed).unwrap(),
        "export const version = 1;\n"
    );
}

/// A local untracked package keeps its exact source identity. Changing only
/// CRLF to LF is still a source edit, so refresh settles the installed copy
/// instead of accepting its portable rendered identity as current source.
#[test]
#[allow(clippy::unwrap_used)]
fn refresh_settles_a_line_ending_edit_in_an_untracked_local_source() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let project = root.join("dev/app");
    write(
        &project.join("kendex.toml"),
        "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n",
    );
    let source = project.join("catalog/pi-extensions/pi-widgets");
    write(
        &source.join("package.json"),
        "{\r\n  \"name\": \"pi-widgets\",\r\n  \"version\": \"1.0.0\",\r\n  \"pi\": { \"extensions\": [\"index.js\"] }\r\n}\r\n",
    );
    write(&source.join("index.js"), "export const version = 1;\r\n");
    git(&project, &["init", "-q", "-b", "main"]);
    git(&project, &["config", "core.autocrlf", "true"]);

    let installed = kendex(&root, &project, &["update-pi", "--scope", "project"]);
    assert!(installed.status.success(), "{installed:?}");
    let destination = project.join(".pi/packages/pi-widgets/index.js");
    assert!(fs::read(&destination).unwrap().contains(&b'\r'));

    write(&source.join("index.js"), "export const version = 1;\n");
    let package = fs::read_to_string(source.join("package.json"))
        .unwrap()
        .replace("\r\n", "\n");
    write(&source.join("package.json"), &package);
    let refreshed = kendex(
        &root,
        &project,
        &["refresh", "--scope", "project", "--yes", "--leave"],
    );

    assert!(refreshed.status.success(), "{refreshed:?}");
    assert!(!fs::read(&destination).unwrap().contains(&b'\r'));
}

#[test]
fn update_reinstalls_from_the_declared_source() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    let installed = project.join(".pi/packages/pi-widgets/index.js");

    let output = kendex(tmp.path(), &project, &["update-pi"]);

    assert!(output.status.success());
    let progress = String::from_utf8_lossy(&output.stdout);
    assert!(
        progress.contains("updated pi-widgets -> 2.0.0"),
        "{progress}"
    );
    assert_eq!(
        fs::read_to_string(&installed).unwrap(),
        "export const version = 2;\n"
    );

    // A second run has nothing left to do.
    let output = kendex(tmp.path(), &project, &["update-pi"]);
    assert!(output.status.success());
    let summary = String::from_utf8_lossy(&output.stderr);
    assert!(summary.contains("all pi packages up to date"), "{summary}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_npm_failure_records_only_the_sibling_whose_install_completed() {
    for failure in ["first", "upgrade", "missing"] {
        let upgrade = failure != "first";
        let tmp = tempfile::tempdir().unwrap();
        let root = rooted(&tmp);
        let project = root.join("dev/app");
        write(
            &project.join("kendex.toml"),
            "schema = 6\n[sources.cat]\npath = \"catalog\"\n[pi-extensions.bad]\nsource = \"cat\"\n[pi-extensions.good]\nsource = \"cat\"\n",
        );
        write(
            &project.join("catalog/pi-extensions/good/package.json"),
            r#"{"name":"good","version":"1.0.0"}"#,
        );
        write(
            &project.join("catalog/pi-extensions/good/index.js"),
            "export const good = true;\n",
        );
        write(
            &project.join("catalog/pi-extensions/bad/package.json"),
            r#"{"name":"bad","version":"1.0.0","dependencies":{"dep":"1.0.0"}}"#,
        );
        let source = project.join("catalog/pi-extensions/bad/index.js");
        write(&source, "export const version = 1;\n");
        let npm = root.join("bin/npm");
        write(&npm, "#!/bin/sh\nexit 0\n");
        fs::set_permissions(&npm, fs::Permissions::from_mode(0o755)).unwrap();
        fs::create_dir_all(project.join(".pi")).unwrap();
        let lock_path = project.join(".kendex-lock.json");
        let key = kendex_core::lock::entry_key(
            kendex_core::model::ItemKind::PiExtension,
            "bad",
            kendex_core::model::HarnessId::Pi,
        );
        let mut completed = if upgrade {
            assert!(
                kendex(&root, &project, &["update-pi", "--scope", "project"])
                    .status
                    .success()
            );
            kendex_core::lock::load(&lock_path)
                .unwrap()
                .entries
                .get(&key)
                .cloned()
        } else {
            None
        };
        if failure == "missing" {
            fs::remove_dir_all(project.join(".pi/packages/bad")).unwrap();
        } else {
            write(&source, "export const version = 2;\n");
        }
        if let Some(entry) = &mut completed {
            entry.rendered_hash = None;
        }
        write(&npm, "#!/bin/sh\nexit 1\n");
        for _ in 0..2 {
            let output = kendex(&root, &project, &["update-pi", "--scope", "project"]);
            assert!(!output.status.success(), "upgrade={upgrade}: {output:?}");
            assert_eq!(
                fs::read(project.join(".pi/packages/bad/index.js")).unwrap(),
                fs::read(&source).unwrap(),
                "npm fails after source files are copied"
            );
            let check = kendex(&root, &project, &["check", "--scope", "project"]);
            assert_eq!(check.status.code(), Some(1), "{check:?}");
            assert!(
                String::from_utf8_lossy(&check.stdout).contains("kendex update-pi --scope project"),
                "{check:?}"
            );
            let updates = kendex(&root, &project, &["updates"]);
            assert!(
                String::from_utf8_lossy(&updates.stderr).contains("pi-extension bad"),
                "{updates:?}"
            );
            let refresh = kendex(&root, &project, &["refresh", "--scope", "project", "--yes"]);
            assert!(!refresh.status.success(), "{refresh:?}");
            assert_eq!(
                kendex_core::lock::load(&lock_path)
                    .unwrap()
                    .entries
                    .get(&key),
                completed.as_ref(),
                "failed installs preserve provenance without completion"
            );
            let check = kendex(&root, &project, &["check", "--scope", "project"]);
            assert_eq!(check.status.code(), Some(1), "{check:?}");
            let verify = kendex(&root, &project, &["verify", "--scope", "project"]);
            assert!(!verify.status.success(), "{verify:?}");
        }
        let settings = fs::read_to_string(project.join(".pi/settings.json")).unwrap();
        assert!(settings.contains("./packages/good"), "{settings}");
        assert_eq!(settings.contains("./packages/bad"), upgrade, "{settings}");
        write(&npm, "#!/bin/sh\nexit 0\n");
        let repaired = kendex(&root, &project, &["update-pi", "--scope", "project"]);
        assert!(repaired.status.success(), "{repaired:?}");
        assert_npm_repaired(&root, &project);
    }
}

#[allow(clippy::unwrap_used)]
fn assert_npm_repaired(home: &Path, project: &Path) {
    let check = kendex(home, project, &["check", "--scope", "project"]);
    assert_eq!(check.status.code(), Some(0), "{check:?}");
    assert!(
        fs::read_to_string(project.join(".pi/settings.json"))
            .unwrap()
            .contains("./packages/bad")
    );
    let verify = kendex(home, project, &["verify", "--scope", "project"]);
    assert!(verify.status.success(), "{verify:?}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_pinned_pi_extension_installs_and_verifies_against_its_revision() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let project = root.join("dev/app");
    let upstream = root.join("git/owner/catalog");
    write(
        &upstream.join("pi-extensions/pi-widgets/package.json"),
        "{\"name\":\"pi-widgets\",\"version\":\"1.0.0\"}\n",
    );
    write(
        &upstream.join("pi-extensions/pi-widgets/index.js"),
        "export const version = 1;\n",
    );
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    let pinned = commit(&upstream, "one");
    write(
        &upstream.join("pi-extensions/pi-widgets/package.json"),
        "{\"name\":\"pi-widgets\",\"version\":\"2.0.0\"}\n",
    );
    write(
        &upstream.join("pi-extensions/pi-widgets/index.js"),
        "export const version = 2;\n",
    );
    commit(&upstream, "two");
    write(
        &project.join("kendex.toml"),
        &format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"owner/catalog\"\n\n[pi-extensions.pi-widgets]\nsource = \"cat\"\nrev = \"{pinned}\"\n"
        ),
    );
    fs::create_dir_all(project.join(".pi")).unwrap();
    let refresh = kendex(&root, &project, &["refresh", "--scope", "project", "--yes"]);
    assert!(
        refresh.status.success(),
        "{}",
        String::from_utf8_lossy(&refresh.stderr)
    );
    assert_eq!(
        fs::read_to_string(project.join(".pi/packages/pi-widgets/index.js")).unwrap(),
        "export const version = 1;\n"
    );
    let lock = kendex_core::lock::load(&project.join(".kendex-lock.json")).unwrap();
    let recorded = lock
        .entries
        .values()
        .find(|entry| entry.name == "pi-widgets")
        .unwrap();
    assert_eq!(recorded.source_commit.as_deref(), Some(pinned.as_str()));
    let verify = kendex(&root, &project, &["verify", "--scope", "project"]);
    assert!(
        verify.status.success(),
        "{}",
        String::from_utf8_lossy(&verify.stderr)
    );
    let updates = kendex(&root, &project, &["updates"]);
    assert!(updates.status.success());
    let text = String::from_utf8_lossy(&updates.stderr);
    assert!(
        text.contains("pi-extension pi-widgets") && text.contains("[held]"),
        "{text}"
    );
    let preview = kendex(
        &root,
        &project,
        &["update-pi", "--check", "--scope", "project"],
    );
    let text = String::from_utf8_lossy(&preview.stdout);
    assert!(
        preview.status.success() && text.contains("up to date"),
        "{preview:?}"
    );
    assert_eq!(
        fs::read_to_string(project.join(".pi/packages/pi-widgets/index.js")).unwrap(),
        "export const version = 1;\n"
    );
    let checked = kendex(&root, &project, &["check", "--scope", "project"]);
    assert_eq!(checked.status.code(), Some(0), "{checked:?}");
}

#[test]
fn verification_and_record_recovery_compare_pi_bytes() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    assert!(
        kendex(tmp.path(), &project, &["update-pi"])
            .status
            .success()
    );
    assert!(
        kendex(tmp.path(), &project, &["verify", "--scope", "project"])
            .status
            .success()
    );
    fs::remove_file(project.join(".kendex-lock.json")).unwrap();
    let recovered = kendex(
        tmp.path(),
        &project,
        &["apply", "--record-existing", "--yes"],
    );
    assert!(recovered.status.success(), "{recovered:?}");
    assert!(
        kendex(tmp.path(), &project, &["verify", "--scope", "project"])
            .status
            .success()
    );
    let installed = project.join(".pi/packages/pi-widgets/index.js");
    fs::write(&installed, "export const version = 9;\n").unwrap();
    assert!(
        !kendex(tmp.path(), &project, &["verify", "--scope", "project"])
            .status
            .success()
    );
    fs::remove_file(project.join(".kendex-lock.json")).unwrap();
    assert!(
        !kendex(
            tmp.path(),
            &project,
            &["apply", "--record-existing", "--yes"]
        )
        .status
        .success()
    );
    let refresh = kendex(
        tmp.path(),
        &project,
        &["refresh", "--scope", "project", "--yes"],
    );
    assert!(!refresh.status.success(), "{refresh:?}");
    assert_eq!(
        fs::read_to_string(&installed).unwrap(),
        "export const version = 9;\n"
    );
    // The refresh wrote the scope's record for what it planned; the edited
    // package is not in it, and the recovery below starts lockless again.
    let lock = kendex_core::lock::load(&project.join(".kendex-lock.json")).unwrap();
    assert!(
        !lock
            .entries
            .values()
            .any(|entry| entry.name == "pi-widgets")
    );
    fs::remove_file(project.join(".kendex-lock.json")).unwrap();
    fs::remove_dir_all(project.join(".pi/packages/pi-widgets")).unwrap();
    assert!(
        !kendex(
            tmp.path(),
            &project,
            &["apply", "--record-existing", "--yes"]
        )
        .status
        .success()
    );
    assert!(!project.join(".kendex-lock.json").exists());
}

#[test]
fn a_busy_scope_refuses_pi_mutation() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    let env = kendex_core::env::Env::host_rooted(tmp.path());
    let scope = kendex_core::model::Scope::Project {
        root: project.clone(),
    };
    let guard = kendex_core::apply::lock_scope(&env, &scope).unwrap();
    let output = kendex(tmp.path(), &project, &["update-pi"]);
    assert!(!output.status.success(), "{output:?}");
    assert_eq!(
        fs::read_to_string(project.join(".pi/packages/pi-widgets/index.js")).unwrap(),
        "export const version = 1;\n"
    );
    drop(guard);
    assert!(
        kendex(tmp.path(), &project, &["update-pi"])
            .status
            .success()
    );
}

#[test]
fn changing_pi_source_refuses_before_package_mutation() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    assert!(
        kendex(tmp.path(), &project, &["update-pi"])
            .status
            .success()
    );
    let lock = fs::read(project.join(".kendex-lock.json")).unwrap();
    fs::rename(project.join("catalog"), project.join("other-catalog")).unwrap();
    let manifest = project.join("kendex.toml");
    fs::write(
        &manifest,
        fs::read_to_string(&manifest)
            .unwrap()
            .replace("\"catalog\"", "\"other-catalog\""),
    )
    .unwrap();
    fs::write(
        project.join("other-catalog/pi-extensions/pi-widgets/index.js"),
        "export const version = 3;\n",
    )
    .unwrap();
    let preview = kendex(tmp.path(), &project, &["update-pi", "--check"]);
    assert!(!preview.status.success(), "{preview:?}");
    assert!(!String::from_utf8_lossy(&preview.stderr).contains("run without --check"));
    assert!(
        !kendex(tmp.path(), &project, &["update-pi"])
            .status
            .success()
    );
    assert_eq!(fs::read(project.join(".kendex-lock.json")).unwrap(), lock);
    assert_eq!(
        fs::read_to_string(project.join(".pi/packages/pi-widgets/index.js")).unwrap(),
        "export const version = 2;\n"
    );
}

/// Nothing of the package is left behind: no settings entry, no package
/// directory, no record.
#[allow(clippy::unwrap_used)]
fn assert_pi_widgets_gone(project: &Path) {
    assert!(!project.join(".pi/packages/pi-widgets").exists());
    let settings = fs::read_to_string(project.join(".pi/settings.json")).unwrap();
    assert!(!settings.contains("pi-widgets"), "{settings}");
    let lock = kendex_core::lock::load(&project.join(".kendex-lock.json")).unwrap();
    assert!(
        !lock
            .entries
            .values()
            .any(|entry| entry.name == "pi-widgets")
    );
}

#[test]
fn orphan_cleanup_takes_the_pi_package_its_registration_and_its_record_together() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    assert!(
        kendex(tmp.path(), &project, &["update-pi"])
            .status
            .success()
    );
    fs::write(project.join("kendex.toml"), "schema = 6\n").unwrap();
    // Undeclared, the package is an orphan the refresh keeps and reports
    // like any other; it no longer refuses the scope over it.
    let refresh = kendex(
        tmp.path(),
        &project,
        &["refresh", "--scope", "project", "--yes", "--leave"],
    );
    assert!(refresh.status.success(), "{refresh:?}");
    let env = kendex_core::env::Env::host_rooted(tmp.path());
    let scope = kendex_core::model::Scope::Project {
        root: project.clone(),
    };
    let options = kendex_core::engine::PlanOptions {
        remove_orphans: true,
        ..Default::default()
    };
    let report = kendex_core::engine::plan_apply(&env, &scope, &options).unwrap();
    kendex_core::apply::execute(&env, &report.plan).unwrap();
    assert_pi_widgets_gone(&project);
}

#[test]
fn remove_takes_a_declared_pi_extension_with_its_declaration() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    assert!(
        kendex(tmp.path(), &project, &["update-pi"])
            .status
            .success()
    );
    let output = kendex(
        tmp.path(),
        &project,
        &[
            "remove",
            "pi-widgets",
            "--scope",
            "project",
            "--no-sweep",
            "--leave",
        ],
    );
    assert!(output.status.success(), "{output:?}");
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(!manifest.contains("pi-widgets"), "{manifest}");
    assert_pi_widgets_gone(&project);
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_lock_refuses_before_a_package_changes() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    let installed = project.join(".pi/packages/pi-widgets/index.js");
    fs::write(project.join(".kendex-lock.json"), "{\"version\":5}\n").unwrap();

    let output = kendex(tmp.path(), &project, &["update-pi"]);

    assert!(!output.status.success());
    assert_eq!(
        fs::read_to_string(installed).unwrap(),
        "export const version = 1;\n"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_declared_package_not_yet_installed_installs_fresh() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    fs::remove_dir_all(project.join(".pi/packages/pi-widgets")).unwrap();
    fs::write(project.join(".pi/settings.json"), "{}\n").unwrap();

    let check = kendex(tmp.path(), &project, &["update-pi", "--check"]);
    assert!(check.status.success());
    let plan = String::from_utf8_lossy(&check.stdout);
    assert!(plan.contains("not installed yet"), "{plan}");

    let output = kendex(tmp.path(), &project, &["update-pi"]);
    assert!(output.status.success());
    let progress = String::from_utf8_lossy(&output.stdout);
    assert!(
        progress.contains("installed pi-widgets -> 2.0.0"),
        "{progress}"
    );
    assert!(
        project
            .join(".pi/packages/pi-widgets/package.json")
            .is_file()
    );
    let settings = fs::read_to_string(project.join(".pi/settings.json")).unwrap();
    assert!(settings.contains("./packages/pi-widgets"), "{settings}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_package_installed_at_the_other_scope_blocks_the_install() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    fs::remove_dir_all(project.join(".pi/packages/pi-widgets")).unwrap();
    fs::write(project.join(".pi/settings.json"), "{}\n").unwrap();
    // The same package already lives at the global scope: Pi would load
    // both copies and crash at startup.
    write(
        &tmp.path()
            .join(".pi/agent/packages/pi-widgets/package.json"),
        "{\"name\": \"pi-widgets\", \"version\": \"1.0.0\"}\n",
    );

    let output = kendex(tmp.path(), &project, &["update-pi"]);
    assert!(output.status.success());
    let plan = String::from_utf8_lossy(&output.stdout);
    assert!(plan.contains("blocked"), "{plan}");
    assert!(plan.contains("register twice"), "{plan}");
    assert!(!project.join(".pi/packages/pi-widgets").exists());
}

/// The other direction: the project the command runs in holds the package
/// and is registered nowhere, the way a fresh clone is, and the global
/// scope declares it. Pi loads that project's packages beside the global
/// ones all the same.
#[test]
#[allow(clippy::unwrap_used)]
fn a_package_in_the_unregistered_current_project_blocks_the_global_install() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    let env = kendex_core::env::Env::host_rooted(tmp.path());
    write(
        &env.global_manifest_file(),
        &format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n",
            test_util::source_path(&project.join("catalog"))
        ),
    );

    let output = kendex(tmp.path(), &project, &["update-pi", "--scope", "global"]);
    assert!(output.status.success(), "{output:?}");
    let plan = String::from_utf8_lossy(&output.stdout);
    assert!(plan.contains("register twice"), "{plan}");
    assert!(!tmp.path().join(".pi/agent/packages/pi-widgets").exists());
}

/// One package under two spellings registers the same resources twice, so
/// the cross-scope guard blocks whichever spelling the manifest declares
/// against whichever the other root carries. Both directions: the guard
/// reaches the family through its current name, so neither declaration
/// need be the one the copy uses.
#[test]
#[allow(clippy::unwrap_used)]
fn a_package_at_the_other_scope_blocks_the_declared_name_under_either_spelling() {
    let rows = [
        (
            "declared scoped, installed unscoped",
            "@vanillagreen/pi-hooks",
            "pi-hooks",
        ),
        (
            "declared unscoped, installed scoped",
            "pi-hooks",
            "@vanillagreen/pi-hooks",
        ),
    ];
    for (case, declared, installed) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let root = rooted(&tmp);
        let project = root.join("dev/app");
        write(
            &project.join("kendex.toml"),
            &format!(
                "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.\"{declared}\"]\nsource = \"cat\"\n"
            ),
        );
        write(
            &project.join(format!("catalog/pi-extensions/{declared}/package.json")),
            &format!("{{\"name\": \"{declared}\", \"version\": \"1.0.0\"}}\n"),
        );
        fs::create_dir_all(project.join(".pi")).unwrap();
        // The other spelling of the same package sits at the global
        // scope, registering the same resources.
        write(
            &root.join(format!(".pi/agent/packages/{installed}/package.json")),
            &format!("{{\"name\": \"{installed}\", \"version\": \"0.9.0\"}}\n"),
        );

        let output = kendex(&root, &project, &["update-pi"]);
        assert!(output.status.success(), "{case}: {output:?}");
        let plan = String::from_utf8_lossy(&output.stdout);
        // The whole opening of the blocked line: the unscoped name is a
        // suffix of the scoped one, so a bare substring would pass while
        // the line named the other spelling.
        assert!(
            plan.contains(&format!("blocked: {installed} is installed at")),
            "{case}: {plan}"
        );
        assert!(plan.contains("would register twice"), "{case}: {plan}");
        assert!(
            !project.join(".pi/packages").join(declared).exists(),
            "{case}: the declared name landed"
        );
    }
}

/// The probe a settle makes at its own root asks the family's OTHER
/// spellings, never the declared one. Blocked where the root holds the
/// copy an older kendex installed under an earlier name, which no record
/// accounts for: settling the scoped name would register the package
/// twice in one root. Settled where the only copy sits under the declared
/// name itself, which is every correctly installed catalog package, all
/// of which carry a rename entry — a probe that folded the whole family
/// would answer yes for each and settle none.
#[test]
#[allow(clippy::unwrap_used)]
fn a_settle_is_blocked_by_an_earlier_named_copy_and_runs_over_the_declared_one() {
    const SOURCE: &str = "{\"name\": \"@vanillagreen/pi-hooks\", \"version\": \"1.0.0\"}\n";
    let rows = [
        (
            "an earlier-named copy the record knows nothing about",
            ".pi/packages/pi-hooks/package.json",
            "{\"name\": \"pi-hooks\", \"version\": \"0.9.0\"}\n",
            false,
        ),
        (
            "the declared name's own copy, the source's bytes",
            ".pi/packages/@vanillagreen/pi-hooks/package.json",
            SOURCE,
            true,
        ),
    ];
    for (case, installed, bytes, settles) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let root = rooted(&tmp);
        let project = root.join("dev/app");
        write(
            &project.join("kendex.toml"),
            "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.\"@vanillagreen/pi-hooks\"]\nsource = \"cat\"\n",
        );
        write(
            &project.join("catalog/pi-extensions/pi-hooks/package.json"),
            SOURCE,
        );
        write(&project.join(installed), bytes);
        // No lock entry either way: the settle is what would write one.
        assert!(
            !project.join(".kendex-lock.json").exists(),
            "{case}: the fixture records nothing"
        );

        let output = kendex(&root, &project, &["refresh", "--scope", "project", "--yes"]);
        assert_eq!(output.status.success(), settles, "{case}: {output:?}");
        let key = kendex_core::lock::entry_key(
            kendex_core::model::ItemKind::PiExtension,
            "@vanillagreen/pi-hooks",
            kendex_core::model::HarnessId::Pi,
        );
        let recorded = kendex_core::lock::load(&project.join(".kendex-lock.json"))
            .unwrap()
            .entries
            .contains_key(&key);
        assert_eq!(recorded, settles, "{case}");
        if !settles {
            assert!(
                !project.join(".pi/packages/@vanillagreen").exists(),
                "{case}"
            );
        }
    }
}

#[test]
fn a_package_no_source_declares_is_reported_not_updated() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    fs::remove_dir_all(project.join("catalog/pi-extensions/pi-widgets")).unwrap();

    let output = kendex(tmp.path(), &project, &["update-pi"]);

    assert!(output.status.success());
    let plan = String::from_utf8_lossy(&output.stdout);
    assert!(
        plan.contains("nothing this place lists supplies it"),
        "{plan}"
    );
    let notes = String::from_utf8_lossy(&output.stderr);
    assert!(notes.contains("no longer ships pi-extensions"), "{notes}");
}

/// The kendex catalog shelves scoped packages under short directories —
/// `pi-extensions/pi-hooks/` registering `@vanillagreen/pi-hooks`. The
/// declaration names the package, so the resolver falls back to the
/// package.json names when no directory matches the declared name.
#[test]
#[allow(clippy::unwrap_used)]
fn a_scoped_name_resolves_a_short_directory_by_package_name() {
    let tmp = tempfile::tempdir().unwrap();
    let project = tmp.path().join("dev/app");
    write(
        &project.join("kendex.toml"),
        "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.\"@vanillagreen/pi-hooks\"]\nsource = \"cat\"\n",
    );
    write(
        &project.join("catalog/pi-extensions/pi-hooks/package.json"),
        "{\"name\": \"@vanillagreen/pi-hooks\", \"version\": \"1.1.0\"}\n",
    );
    write(
        &project.join(".pi/packages/@vanillagreen/pi-hooks/package.json"),
        "{\"name\": \"@vanillagreen/pi-hooks\", \"version\": \"1.0.0\"}\n",
    );

    let output = kendex(tmp.path(), &project, &["update-pi", "--check"]);
    assert!(output.status.success());
    let plan = String::from_utf8_lossy(&output.stdout);
    assert!(
        !plan.contains("nothing this place lists supplies it"),
        "{plan}"
    );
    assert!(!plan.contains("no longer ships"), "{plan}");
    assert!(plan.contains("stale"), "{plan}");

    let output = kendex(tmp.path(), &project, &["update-pi"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let updated =
        fs::read_to_string(project.join(".pi/packages/@vanillagreen/pi-hooks/package.json"))
            .unwrap();
    assert!(updated.contains("1.1.0"), "{updated}");
}
