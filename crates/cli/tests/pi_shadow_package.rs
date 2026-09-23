//! A declared Pi package with a second copy under an `extensions/`
//! directory Pi loads with the scope, the scope's own or the global
//! root's, as a package directory or a loose module file: Pi loads that
//! copy beside the managed one, so both verbs that read the scope name it,
//! and neither touches it.

#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

fn said(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

#[allow(clippy::unwrap_used)]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

fn package_json(version: &str) -> String {
    format!(
        "{{\n  \"name\": \"pi-widgets\",\n  \"version\": \"{version}\",\n  \"pi\": {{ \"extensions\": [\"index.js\"] }}\n}}\n"
    )
}

/// A project declaring one pi extension from a local catalog, with the
/// managed copy installed and recorded by update-pi itself.
#[allow(clippy::unwrap_used)]
fn fixture() -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("dev/app");
    write(
        &project.join("kendex.toml"),
        "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n",
    );
    write(
        &project.join("catalog/pi-extensions/pi-widgets/package.json"),
        &package_json("2.0.0"),
    );
    write(
        &project.join("catalog/pi-extensions/pi-widgets/index.js"),
        "export const version = 2;\n",
    );
    let installed = kendex(&home, &project, &["update-pi", "--scope", "project"]);
    assert!(installed.status.success(), "{}", said(&installed));
    (tmp, home, project)
}

/// The stale copy an earlier installer left under `extensions/`: the
/// package directory `pi-widgets/` with its manifest, or its one entry
/// module as a loose `pi-widgets.js`.
enum Copy {
    Package,
    File,
}

/// Plant one copy under `extensions`, answering its path and the version
/// text the report gives it.
#[allow(clippy::unwrap_used)]
fn plant(copy: &Copy, extensions: &Path) -> (std::path::PathBuf, &'static str) {
    match copy {
        Copy::Package => {
            let shadow = extensions.join("pi-widgets");
            write(&shadow.join("package.json"), &package_json("1.0.0"));
            write(&shadow.join("index.js"), "export const version = 1;\n");
            (shadow, "version 1.0.0")
        }
        Copy::File => {
            let shadow = extensions.join("pi-widgets.js");
            write(&shadow, "export const version = 1;\n");
            (shadow, "no version")
        }
    }
}

/// The same fixture with the package copy under the project's
/// `.pi/extensions`.
fn fixture_with_shadow() -> (
    tempfile::TempDir,
    std::path::PathBuf,
    std::path::PathBuf,
    std::path::PathBuf,
) {
    let (tmp, home, project) = fixture();
    let (shadow, _) = plant(&Copy::Package, &project.join(".pi/extensions"));
    (tmp, home, project, shadow)
}

/// Every place and shape Pi loads a copy from: under the scope's own root
/// or the global one it pairs with, as a package directory or a loose
/// module file. Both verbs open on the key, name both copies with their
/// versions, and name the entry to move and the directory to move it out
/// of.
#[test]
fn a_second_copy_under_any_paired_root_is_named_by_update_pi_and_check() {
    let rows = [
        (
            "package under the project root",
            Copy::Package,
            ".pi/extensions",
        ),
        ("file under the project root", Copy::File, ".pi/extensions"),
        (
            "package under the global root",
            Copy::Package,
            ".pi/agent/extensions",
        ),
        (
            "file under the global root",
            Copy::File,
            ".pi/agent/extensions",
        ),
    ];
    for (case, copy, extensions) in rows {
        let (_tmp, home, project) = fixture();
        let managed = project.join(".pi/packages/pi-widgets");
        let extensions = match extensions.starts_with(".pi/agent") {
            true => home.join(extensions),
            false => project.join(extensions),
        };
        let (shadow, version) = plant(&copy, &extensions);
        let expect = |verb: &str, text: &str| {
            assert!(
                text.contains("pi-shadow-package=pi-widgets"),
                "{case}, {verb}: {text}"
            );
            assert!(
                text.contains(&format!("{} (version 2.0.0)", managed.display())),
                "{case}, {verb}: {text}"
            );
            assert!(
                text.contains(&format!("{} ({version})", shadow.display())),
                "{case}, {verb}: {text}"
            );
            assert!(
                text.contains(&format!(
                    "move {} out of {}",
                    shadow.file_name().unwrap().to_string_lossy(),
                    extensions.display()
                )),
                "{case}, {verb}: {text}"
            );
        };

        let preview = kendex(
            &home,
            &project,
            &["update-pi", "--scope", "project", "--check"],
        );
        assert!(preview.status.success(), "{case}: {}", said(&preview));
        expect("update-pi --check", &said(&preview));

        let check = kendex(&home, &project, &["check", "--scope", "project"]);
        assert_eq!(check.status.code(), Some(1), "{case}: {}", said(&check));
        let check_text = said(&check);
        expect("check", &check_text);
        let move_command = format!(
            "fix: mv -i {} {}",
            kendex_core::names::quoted(&shadow.display().to_string()),
            kendex_core::names::quoted(&extensions.parent().unwrap().display().to_string())
        );
        assert!(
            check_text.contains(&move_command),
            "{case}, check: {check_text}"
        );
        let quiet = kendex(&home, &project, &["check", "--scope", "project", "--quiet"]);
        assert_eq!(quiet.status.code(), Some(1), "{case}: {}", said(&quiet));
        let stdout = String::from_utf8_lossy(&quiet.stdout);
        assert!(stdout.contains("loaded twice by pi:"), "{case}: {stdout}");
        expect("check --quiet", &stdout);
        assert!(
            stdout.contains(&move_command),
            "{case}, check --quiet: {stdout}"
        );
    }
}

/// The install still lands the managed copy and moves nothing, saying the
/// copy again as it does.
#[test]
#[allow(clippy::unwrap_used)]
fn update_pi_installs_the_managed_copy_and_leaves_the_second_one() {
    let (_tmp, home, project, shadow) = fixture_with_shadow();
    let managed = project.join(".pi/packages/pi-widgets");

    fs::write(managed.join("index.js"), "export const version = 1;\n").unwrap();
    let updated = kendex(&home, &project, &["update-pi", "--scope", "project"]);
    assert!(updated.status.success(), "{}", said(&updated));
    assert!(
        said(&updated).contains("pi-shadow-package=pi-widgets"),
        "{}",
        said(&updated)
    );
    assert_eq!(
        fs::read_to_string(managed.join("index.js")).unwrap(),
        "export const version = 2;\n"
    );
    assert_eq!(
        fs::read_to_string(shadow.join("index.js")).unwrap(),
        "export const version = 1;\n"
    );
    assert!(shadow.join("package.json").is_file());
}

/// The package declared globally from a catalog under home, with the
/// managed copy installed by update-pi run from `project`, a directory
/// that is a project by its `.pi` and registered nowhere.
#[allow(clippy::unwrap_used)]
fn global_fixture() -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".pi")).unwrap();
    let manifest = kendex_core::env::Env::host_rooted(&home).global_manifest_file();
    write(
        &manifest,
        "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n",
    );
    write(
        &home.join("catalog/pi-extensions/pi-widgets/package.json"),
        &package_json("2.0.0"),
    );
    write(
        &home.join("catalog/pi-extensions/pi-widgets/index.js"),
        "export const version = 2;\n",
    );
    let installed = kendex(&home, &project, &["update-pi", "--scope", "global"]);
    assert!(installed.status.success(), "{}", said(&installed));
    (tmp, home, project)
}

/// Pi loads the global root with the project the session runs in,
/// registered or not: a copy under that project's `.pi/extensions` is
/// named by both verbs run there with no scope flag, the session hook's
/// invocation among them.
#[test]
fn a_copy_under_the_unregistered_current_project_is_named_for_a_global_package() {
    let (_tmp, home, project) = global_fixture();
    let (shadow, _) = plant(&Copy::File, &project.join(".pi/extensions"));

    let check = kendex(&home, &project, &["check"]);
    assert_eq!(check.status.code(), Some(1), "{}", said(&check));
    assert!(
        said(&check).contains(&format!(
            "pi-shadow-package=pi-widgets: managed copy {} (version 2.0.0); shadow copy {} (no version)",
            home.join(".pi/agent/packages/pi-widgets").display(),
            shadow.display()
        )),
        "{}",
        said(&check)
    );
    let preview = kendex(&home, &project, &["update-pi", "--check"]);
    assert!(preview.status.success(), "{}", said(&preview));
    assert!(
        said(&preview).contains("pi-shadow-package=pi-widgets"),
        "{}",
        said(&preview)
    );
}

/// A registered project the session does not run in is not loaded by
/// Pi in this session, so a copy under it is no second copy here and
/// neither verb names it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_copy_under_a_registered_project_elsewhere_is_named_by_neither_verb() {
    let (_tmp, home, project) = global_fixture();
    let elsewhere = home.join("dev/other");
    plant(&Copy::Package, &elsewhere.join(".pi/extensions"));
    write(
        &kendex_core::env::Env::host_rooted(&home).settings_file(),
        &format!("schema = 1\nprojects = [\"{}\"]\n", elsewhere.display()),
    );

    let check = kendex(&home, &project, &["check"]);
    assert_eq!(check.status.code(), Some(0), "{}", said(&check));
    let preview = kendex(&home, &project, &["update-pi", "--check"]);
    assert!(preview.status.success(), "{}", said(&preview));
    for text in [said(&check), said(&preview)] {
        assert!(!text.contains("pi-shadow-package"), "{text}");
    }
}

/// A scope declaring no Pi package reads no `extensions/` at all, so one
/// that will not read costs it nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn a_scope_declaring_no_pi_package_reads_no_extensions_directory() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("dev/app");
    write(&project.join("kendex.toml"), "schema = 6\n");
    write(&project.join(".pi/extensions"), "not a directory\n");

    let check = kendex(&home, &project, &["check", "--scope", "project"]);
    assert_eq!(check.status.code(), Some(0), "{}", said(&check));
}

/// The other root's `extensions` will not read: that is one could-not-check
/// line naming it, and the copy under the scope's own root is still named
/// by both verbs.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_other_root_is_reported_beside_the_copy_found() {
    let (_tmp, home, project, shadow) = fixture_with_shadow();
    let global_extensions = home.join(".pi/agent/extensions");
    write(&global_extensions, "not a directory\n");

    let check = kendex(&home, &project, &["check", "--scope", "project"]);
    assert_eq!(check.status.code(), Some(2), "{}", said(&check));
    let text = said(&check);
    assert!(
        text.contains(&format!("shadow copy {} (version 1.0.0)", shadow.display())),
        "{text}"
    );
    assert!(
        text.contains(&format!("pi-extensions: {}: ", global_extensions.display())),
        "{text}"
    );

    let preview = kendex(
        &home,
        &project,
        &["update-pi", "--scope", "project", "--check"],
    );
    assert!(preview.status.success(), "{}", said(&preview));
    let text = said(&preview);
    assert!(
        text.contains(&format!("shadow copy {} (version 1.0.0)", shadow.display())),
        "{text}"
    );
    assert!(
        text.contains(&format!(
            "could not check for a second copy — {}: ",
            global_extensions.display()
        )),
        "{text}"
    );
}

/// The project fixture with the same package declared globally too, so
/// both scopes scan the same two roots.
fn fixture_declared_at_both_scopes() -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf)
{
    let (tmp, home, project) = fixture();
    write(
        &kendex_core::env::Env::host_rooted(&home).global_manifest_file(),
        "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n",
    );
    (tmp, home, project)
}

/// Both scopes declare the package and one copy sits under the global
/// root, which both scopes read: each verb names the copy once per run.
#[test]
fn a_copy_of_a_package_declared_at_both_scopes_is_named_once_by_each_verb() {
    let (_tmp, home, project) = fixture_declared_at_both_scopes();
    plant(&Copy::Package, &home.join(".pi/agent/extensions"));

    let preview = kendex(&home, &project, &["update-pi", "--check"]);
    assert!(preview.status.success(), "{}", said(&preview));
    assert_eq!(
        said(&preview)
            .matches("pi-shadow-package=pi-widgets")
            .count(),
        1,
        "{}",
        said(&preview)
    );
    let check = kendex(&home, &project, &["check"]);
    assert_eq!(check.status.code(), Some(1), "{}", said(&check));
    assert_eq!(
        said(&check).matches("pi-shadow-package=pi-widgets").count(),
        1,
        "{}",
        said(&check)
    );
}

/// Both scopes declare the package and the global root's `extensions`
/// will not read: each verb reports that failure once per run.
#[test]
fn a_root_that_will_not_read_is_reported_once_by_each_verb() {
    let (_tmp, home, project) = fixture_declared_at_both_scopes();
    let global_extensions = home.join(".pi/agent/extensions");
    write(&global_extensions, "not a directory\n");

    let check = kendex(&home, &project, &["check"]);
    assert_eq!(check.status.code(), Some(2), "{}", said(&check));
    let failure = format!("pi-extensions: {}: ", global_extensions.display());
    assert_eq!(
        said(&check).matches(&failure).count(),
        1,
        "{}",
        said(&check)
    );
    let preview = kendex(&home, &project, &["update-pi", "--check"]);
    assert!(preview.status.success(), "{}", said(&preview));
    let note = format!(
        "could not check for a second copy — {}: ",
        global_extensions.display()
    );
    assert_eq!(
        said(&preview).matches(&note).count(),
        1,
        "{}",
        said(&preview)
    );
}

/// A declared package whose source no longer resolves still gets the
/// second-copy check from both verbs: the copy runs whatever the source
/// says.
#[test]
#[allow(clippy::unwrap_used)]
fn a_package_whose_source_is_gone_still_has_its_second_copy_named() {
    let (_tmp, home, project, _shadow) = fixture_with_shadow();
    fs::remove_dir_all(project.join("catalog/pi-extensions/pi-widgets")).unwrap();

    let preview = kendex(
        &home,
        &project,
        &["update-pi", "--scope", "project", "--check"],
    );
    assert!(preview.status.success(), "{}", said(&preview));
    assert!(
        said(&preview).contains("pi-shadow-package=pi-widgets"),
        "{}",
        said(&preview)
    );
    let check = kendex(&home, &project, &["check", "--scope", "project"]);
    assert_eq!(check.status.code(), Some(1), "{}", said(&check));
    assert!(
        said(&check).contains("pi-shadow-package=pi-widgets"),
        "{}",
        said(&check)
    );
}

#[test]
fn the_managed_copy_alone_is_not_a_second_copy() {
    let (_tmp, home, project) = fixture();

    let preview = kendex(
        &home,
        &project,
        &["update-pi", "--scope", "project", "--check"],
    );
    assert!(preview.status.success(), "{}", said(&preview));
    assert!(
        !said(&preview).contains("pi-shadow-package"),
        "{}",
        said(&preview)
    );

    let check = kendex(&home, &project, &["check", "--scope", "project"]);
    assert_eq!(check.status.code(), Some(0), "{}", said(&check));
    assert!(
        !said(&check).contains("pi-shadow-package"),
        "{}",
        said(&check)
    );
}

/// The manifest declares the package under an earlier name and the stray
/// copy's `package.json` carries the current one. Pi de-duplicates by
/// package identity, so the two are one package and both copies load; a
/// candidate set built off the declared spelling alone holds that one
/// name and the section stays silent while update-pi installs beside the
/// copy Pi runs.
#[test]
#[allow(clippy::unwrap_used)]
fn a_copy_under_the_current_name_is_named_for_a_package_declared_under_an_earlier_one() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("dev/app");
    write(
        &project.join("kendex.toml"),
        "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.\"pi-hooks\"]\nsource = \"cat\"\n",
    );
    let manifest = |name: &str, version: &str| {
        format!(
            "{{\n  \"name\": \"{name}\",\n  \"version\": \"{version}\",\n  \"pi\": {{ \"extensions\": [\"index.js\"] }}\n}}\n"
        )
    };
    write(
        &project.join("catalog/pi-extensions/pi-hooks/package.json"),
        &manifest("pi-hooks", "2.0.0"),
    );
    write(
        &project.join("catalog/pi-extensions/pi-hooks/index.js"),
        "export const version = 2;\n",
    );
    let installed = kendex(&home, &project, &["update-pi", "--scope", "project"]);
    assert!(installed.status.success(), "{}", said(&installed));

    // Named neither for the declared spelling nor by its own directory:
    // the manifest's package name is the whole of what identifies it.
    let shadow = project.join(".pi/extensions/stray");
    write(
        &shadow.join("package.json"),
        &manifest("@vanillagreen/pi-hooks", "0.9.0"),
    );
    write(&shadow.join("index.js"), "export const version = 1;\n");

    let check = kendex(&home, &project, &["check", "--scope", "project"]);
    assert_eq!(check.status.code(), Some(1), "{}", said(&check));
    let text = said(&check);
    assert!(text.contains("loaded twice by pi:"), "{text}");
    assert!(text.contains("pi-shadow-package=pi-hooks"), "{text}");
    assert!(
        text.contains(&format!("{} (version 0.9.0)", shadow.display())),
        "{text}"
    );
    assert!(
        text.contains(&format!(
            "move stray out of {}",
            project.join(".pi/extensions").display()
        )),
        "{text}"
    );
}
