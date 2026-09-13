//! A fresh clone of a consumer refreshes in one run.
//!
//! The install record is machine-local and gitignored, so every clone
//! starts without one while the tracked tree already carries the rendered
//! skills, the inventory and the Pi packages the manifest declares. One
//! `refresh` has to settle those packages itself and leave the tree it
//! cloned: a remote lane, a CI job and a new machine all start here, and
//! each of them scripts that one command.

#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use kendex_core::process::Hardened;

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

/// git under the fixture home, so the developer's own configuration and
/// hooks never reach the repository being built.
#[allow(clippy::unwrap_used)]
fn git(home: &Path, dir: &Path, args: &[&str]) -> String {
    let out = Hardened::git(args, Some(dir))
        .env("HOME", home.to_str().unwrap())
        .env("KENDEX_REAL_HOME", "1")
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t")
        .run()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

#[allow(clippy::unwrap_used)]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// A consumer repository the way one is committed: a skill and a Pi
/// package declared from a catalog inside the checkout, rendered and
/// installed once, every render and the package tracked, the install
/// record ignored.
#[allow(clippy::unwrap_used)]
fn committed_consumer(home: &Path) -> PathBuf {
    let origin = home.join("dev/app");
    write(
        &origin.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\"]\n\n[sources.cat]\npath = \"catalog\"\n\n[skills.deploy]\nsource = \"cat\"\n\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n",
    );
    write(
        &origin.join("catalog/skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun the deploy.\n",
    );
    write(
        &origin.join("catalog/pi-extensions/pi-widgets/package.json"),
        "{\n  \"name\": \"pi-widgets\",\n  \"version\": \"1.0.0\",\n  \"pi\": { \"extensions\": [\"index.js\"] }\n}\n",
    );
    write(
        &origin.join("catalog/pi-extensions/pi-widgets/index.js"),
        "export const version = 1;\n",
    );
    write(&origin.join(".gitignore"), "/.kendex-lock.json\n");
    fs::create_dir_all(origin.join(".pi")).unwrap();
    git(home, &origin, &["init", "-q", "-b", "main"]);
    git(home, &origin, &["config", "commit.gpgsign", "false"]);
    git(home, &origin, &["config", "core.hooksPath", ".git/hooks"]);

    let installed = kendex(home, &origin, &["update-pi", "--scope", "project"]);
    assert!(installed.status.success(), "{}", said(&installed));
    let rendered = kendex(
        home,
        &origin,
        &["refresh", "--scope", "project", "--yes", "--leave"],
    );
    assert!(rendered.status.success(), "{}", said(&rendered));

    git(home, &origin, &["add", "-A"]);
    git(home, &origin, &["commit", "-q", "-m", "install"]);
    let tracked = git(home, &origin, &["ls-files"]);
    for path in [
        ".kendex-generated.json",
        ".pi/packages/pi-widgets/index.js",
        ".pi/settings.json",
    ] {
        assert!(
            tracked.lines().any(|line| line == path),
            "{path}: {tracked}"
        );
    }
    assert!(!tracked.contains(".kendex-lock.json"), "{tracked}");
    origin
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_fresh_clone_refreshes_in_one_run_and_stays_clean() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let origin = committed_consumer(&home);
    let clone = home.join("elsewhere/clone");
    fs::create_dir_all(clone.parent().unwrap()).unwrap();
    git(
        &home,
        &origin,
        &["clone", "--quiet", ".", &clone.display().to_string()],
    );
    assert!(!clone.join(".kendex-lock.json").exists());

    let refreshed = kendex(
        &home,
        &clone,
        &["refresh", "--scope", "project", "--yes", "--leave"],
    );

    assert_eq!(refreshed.status.code(), Some(0), "{}", said(&refreshed));
    assert_eq!(
        git(&home, &clone, &["status", "--porcelain"]),
        "",
        "{}",
        said(&refreshed)
    );
}
