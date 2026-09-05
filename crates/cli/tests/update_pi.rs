#![cfg(unix)]

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

// Integration-test helpers sit outside #[test] fns, so clippy's
// allow-unwrap-in-tests does not reach them.
#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

#[allow(clippy::unwrap_used)]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
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

#[test]
fn generic_orphan_cleanup_keeps_pi_payload_and_registration_together() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    assert!(
        kendex(tmp.path(), &project, &["update-pi"])
            .status
            .success()
    );
    let settings = fs::read(project.join(".pi/settings.json")).unwrap();
    fs::write(project.join("kendex.toml"), "schema = 6\n").unwrap();
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
    assert!(project.join(".pi/packages/pi-widgets/index.js").is_file());
    assert_eq!(
        fs::read(project.join(".pi/settings.json")).unwrap(),
        settings
    );
    let lock = kendex_core::lock::load(&project.join(".kendex-lock.json")).unwrap();
    assert!(
        lock.entries
            .values()
            .any(|entry| entry.name == "pi-widgets")
    );
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

#[test]
#[allow(clippy::unwrap_used)]
fn a_legacy_named_package_at_the_other_scope_blocks_the_scoped_name() {
    let tmp = tempfile::tempdir().unwrap();
    let project = tmp.path().join("dev/app");
    write(
        &project.join("kendex.toml"),
        "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.\"@vanillagreen/pi-hooks\"]\nsource = \"cat\"\n",
    );
    write(
        &project.join("catalog/pi-extensions/@vanillagreen/pi-hooks/package.json"),
        "{\"name\": \"@vanillagreen/pi-hooks\", \"version\": \"1.0.0\"}\n",
    );
    fs::create_dir_all(project.join(".pi")).unwrap();
    // The unscoped compatibility name still sits at the global scope; it
    // registers the same resources as the scoped package.
    write(
        &tmp.path().join(".pi/agent/packages/pi-hooks/package.json"),
        "{\"name\": \"pi-hooks\", \"version\": \"0.9.0\"}\n",
    );

    let output = kendex(tmp.path(), &project, &["update-pi"]);
    assert!(output.status.success());
    let plan = String::from_utf8_lossy(&output.stdout);
    assert!(plan.contains("blocked"), "{plan}");
    assert!(plan.contains("pi-hooks is installed at"), "{plan}");
    assert!(!project.join(".pi/packages/@vanillagreen").exists());
}

#[test]
fn a_package_no_source_declares_is_reported_not_updated() {
    let tmp = fixture();
    let project = tmp.path().join("dev/app");
    fs::remove_dir_all(project.join("catalog/pi-extensions/pi-widgets")).unwrap();

    let output = kendex(tmp.path(), &project, &["update-pi"]);

    assert!(output.status.success());
    let plan = String::from_utf8_lossy(&output.stdout);
    assert!(plan.contains("no declared source"), "{plan}");
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
    assert!(!plan.contains("no declared source"), "{plan}");
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
