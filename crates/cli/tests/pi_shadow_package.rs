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
                    shadow.display(),
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
        expect("check", &said(&check));
        let quiet = kendex(&home, &project, &["check", "--scope", "project", "--quiet"]);
        assert_eq!(quiet.status.code(), Some(1), "{case}: {}", said(&quiet));
        let stdout = String::from_utf8_lossy(&quiet.stdout);
        assert!(stdout.contains("loaded twice by pi:"), "{case}: {stdout}");
        expect("check --quiet", &stdout);
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
