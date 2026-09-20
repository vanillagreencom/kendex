//! A declared Pi package with a second copy under the scope's
//! `extensions/`: Pi loads that copy beside the managed one, so both
//! verbs that read the scope name it, and neither touches it.

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

/// The same fixture with the stale copy an earlier installer left under
/// `.pi/extensions/pi-widgets`.
#[allow(clippy::unwrap_used)]
fn fixture_with_shadow() -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf) {
    let (tmp, home, project) = fixture();
    write(
        &project.join(".pi/extensions/pi-widgets/package.json"),
        &package_json("1.0.0"),
    );
    write(
        &project.join(".pi/extensions/pi-widgets/index.js"),
        "export const version = 1;\n",
    );
    (tmp, home, project)
}

/// Both verbs open on the key, name both copies with their versions, and
/// name the directory to move; the managed copy alone gives neither verb
/// anything to say.
#[test]
#[allow(clippy::unwrap_used)]
fn a_second_copy_under_extensions_is_named_by_update_pi_and_check() {
    let (_tmp, home, project) = fixture_with_shadow();
    let managed = project.join(".pi/packages/pi-widgets");
    let shadow = project.join(".pi/extensions/pi-widgets");
    let expect = |verb: &str, text: &str| {
        assert!(
            text.contains("pi-shadow-package=pi-widgets"),
            "{verb}: {text}"
        );
        assert!(
            text.contains(&format!("{} (version 2.0.0)", managed.display())),
            "{verb}: {text}"
        );
        assert!(
            text.contains(&format!("{} (version 1.0.0)", shadow.display())),
            "{verb}: {text}"
        );
        assert!(
            text.contains(&format!(
                "move {} out of {}",
                shadow.display(),
                project.join(".pi/extensions").display()
            )),
            "{verb}: {text}"
        );
    };

    let preview = kendex(
        &home,
        &project,
        &["update-pi", "--scope", "project", "--check"],
    );
    assert!(preview.status.success(), "{}", said(&preview));
    expect("update-pi --check", &said(&preview));

    let check = kendex(&home, &project, &["check", "--scope", "project"]);
    assert_eq!(check.status.code(), Some(1), "{}", said(&check));
    expect("check", &said(&check));
    let quiet = kendex(&home, &project, &["check", "--scope", "project", "--quiet"]);
    assert_eq!(quiet.status.code(), Some(1), "{}", said(&quiet));
    let stdout = String::from_utf8_lossy(&quiet.stdout);
    assert!(stdout.contains("loaded twice by pi:"), "{stdout}");
    expect("check --quiet", &stdout);

    // The install still lands the managed copy and moves nothing.
    fs::write(managed.join("index.js"), "export const version = 1;\n").unwrap();
    let updated = kendex(&home, &project, &["update-pi", "--scope", "project"]);
    assert!(updated.status.success(), "{}", said(&updated));
    expect("update-pi", &said(&updated));
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
