//! A Pi extension a project's manifest declares that the global manifest
//! declares too. Pi reads the two scopes' package lists together at
//! startup and will not start with one package registered twice, so the
//! pair of declarations is the conflict on its own: `kendex check` names
//! it from the manifests alone and says which declaration stays.

#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::path::{Path, PathBuf};
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

/// A manifest declaring one Pi extension from a catalog beside it.
fn manifest(name: &str) -> String {
    format!(
        "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.\"{name}\"]\nsource = \"cat\"\n"
    )
}

#[allow(clippy::unwrap_used)]
fn global_manifest_file(home: &Path) -> PathBuf {
    kendex_core::env::Env::host_rooted(home).global_manifest_file()
}

/// A home whose global manifest declares `global`, and a project under it
/// whose own manifest declares `project`. Nothing is installed anywhere:
/// the declarations alone are what the check reads.
#[allow(clippy::unwrap_used)]
fn fixture(global: Option<&str>, project: &str) -> (tempfile::TempDir, PathBuf, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let root = home.join("dev/app");
    fs::create_dir_all(root.join(".pi")).unwrap();
    write(&root.join("kendex.toml"), &manifest(project));
    if let Some(global) = global {
        write(&global_manifest_file(&home), &manifest(global));
    }
    (tmp, home, root)
}

/// One package under any pair of its spellings is one registration to Pi,
/// since Pi de-duplicates by package identity and a rename leaves the same
/// package under two names. Each pair is one row: it opens on the stable
/// key, names the global manifest's spelling, says what a Pi session
/// loses, and says which declaration stays.
#[test]
fn a_project_declaration_the_global_manifest_also_holds_is_named_with_the_copy_to_keep() {
    let rows = [
        ("both under the current name", "pi-widgets", "pi-widgets"),
        (
            "the project under an earlier name",
            "@vanillagreen/pi-hooks",
            "pi-hooks",
        ),
        (
            "the global under an earlier name",
            "pi-hooks",
            "@vanillagreen/pi-hooks",
        ),
    ];
    for (case, global, project) in rows {
        let (_tmp, home, root) = fixture(Some(global), project);
        // The conflict is the pair of declarations: no scope has the
        // package on disk, and the row still lands.
        assert!(
            !root.join(".pi/packages").exists(),
            "{case}: the fixture installs nothing"
        );

        let check = kendex(&home, &root, &["check", "--scope", "project"]);
        assert_eq!(check.status.code(), Some(1), "{case}: {}", said(&check));
        let text = said(&check);
        assert!(text.contains("declared at both scopes:"), "{case}: {text}");
        assert!(
            text.contains(&format!(
                "pi-declared-twice={project}: the global manifest declares '{global}' too"
            )),
            "{case}: {text}"
        );
        assert!(
            text.contains("will not start with one package registered twice"),
            "{case}: {text}"
        );
        assert!(
            text.contains(&format!(
                "keep the global declaration, which reaches every project, and drop this one \
                 — fix: kendex remove {project}"
            )),
            "{case}: {text}"
        );
    }
}

/// No second registration, no row: a global manifest that is not there and
/// one that declares a different package both leave the project's
/// declaration alone.
#[test]
fn a_project_declaration_the_global_manifest_does_not_hold_gets_no_row() {
    let rows = [
        ("no global manifest at all", None),
        (
            "a global manifest declaring another package",
            Some("@vanillagreen/pi-qol"),
        ),
    ];
    for (case, global) in rows {
        let (_tmp, home, root) = fixture(global, "pi-widgets");
        let text = said(&kendex(&home, &root, &["check", "--scope", "project"]));
        assert!(!text.contains("pi-declared-twice"), "{case}: {text}");
        assert!(!text.contains("declared at both scopes"), "{case}: {text}");
    }
}

/// The global declaration is the copy that stays, so the global scope is
/// never told to drop it.
#[test]
fn the_global_scope_is_not_told_to_drop_its_own_declaration() {
    let (_tmp, home, root) = fixture(Some("pi-widgets"), "pi-widgets");
    let text = said(&kendex(&home, &root, &["check", "--scope", "global"]));
    assert!(!text.contains("pi-declared-twice"), "{text}");
}

/// A global manifest that will not parse leaves the duplication unjudged.
/// That is a could-not-check line and exit 2, never a project reported
/// free of a conflict nothing looked for.
#[test]
fn an_unreadable_global_manifest_is_reported_rather_than_read_as_no_duplicate() {
    let (_tmp, home, root) = fixture(Some("pi-widgets"), "pi-widgets");
    write(&global_manifest_file(&home), "schema = 6\n[pi-extensions\n");

    let check = kendex(&home, &root, &["check", "--scope", "project"]);
    assert_eq!(check.status.code(), Some(2), "{}", said(&check));
    let text = said(&check);
    assert!(text.contains("could not check:"), "{text}");
    assert!(text.contains("global manifest: "), "{text}");
    assert!(!text.contains("pi-declared-twice"), "{text}");
}
