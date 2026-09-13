//! A fresh clone of a consumer refreshes in one run.
//!
//! The install record is machine-local and gitignored, so every clone
//! starts without one while the tracked tree already carries the rendered
//! skills, the inventory and the Pi packages the manifest declares. One
//! `refresh` has to settle those packages itself and leave the tree it
//! cloned: a remote lane, a CI job and a new machine all start here, and
//! each of them scripts that one command. It settles after its one yes,
//! and never by running a process: a package whose install runs npm is
//! the person's to install through `update-pi`.

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use kendex_core::process::Hardened;

/// The binary with the fixture's `bin/` ahead of the host's `PATH`, where a
/// case that needs to see npm called puts its own.
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
        .env("PATH", path)
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

/// An `npm` that records every call at `marker` and does nothing else: the
/// instrument for "no process ran", firing on any install that reaches
/// npm whatever the package's own scripts would do.
#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn npm_that_marks(home: &Path, marker: &Path) {
    let npm = home.join("bin/npm");
    write(
        &npm,
        &format!("#!/bin/sh\ntouch '{}'\nexit 0\n", marker.display()),
    );
    fs::set_permissions(&npm, fs::Permissions::from_mode(0o755)).unwrap();
}

const NO_DEPENDENCIES: &str = "{\n  \"name\": \"pi-widgets\",\n  \"version\": \"1.0.0\",\n  \"pi\": { \"extensions\": [\"index.js\"] }\n}\n";
const WITH_A_DEPENDENCY: &str = "{\n  \"name\": \"pi-widgets\",\n  \"version\": \"1.0.0\",\n  \"dependencies\": { \"dep\": \"1.0.0\" },\n  \"scripts\": { \"postinstall\": \"touch postinstall-ran\" },\n  \"pi\": { \"extensions\": [\"index.js\"] }\n}\n";

/// A consumer repository the way one is committed: a skill and a Pi
/// package declared from a catalog inside the checkout, rendered and
/// installed once, every render and the package tracked, the install
/// record ignored.
#[allow(clippy::unwrap_used)]
fn committed_consumer(home: &Path, package: &str) -> PathBuf {
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
        package,
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

/// The consumer cloned into a directory nothing named before, carrying
/// no install record.
#[allow(clippy::unwrap_used)]
fn fresh_clone(home: &Path, origin: &Path) -> PathBuf {
    let clone = home.join("elsewhere/clone");
    fs::create_dir_all(clone.parent().unwrap()).unwrap();
    git(
        home,
        origin,
        &["clone", "--quiet", ".", &clone.display().to_string()],
    );
    assert!(!clone.join(".kendex-lock.json").exists());
    clone
}

/// Not on Windows: the committed renders include symlinks, and a Windows
/// checkout materialises each as a regular file holding its target's path,
/// so the tree the clone starts from is not the tree the refresh writes;
/// `crates/core/src/engine/generated_paths/own_inventory.rs` states the
/// same for the inventory.
#[cfg(not(windows))]
#[test]
#[allow(clippy::unwrap_used)]
fn a_fresh_clone_refreshes_in_one_run_and_stays_clean() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let origin = committed_consumer(&home, NO_DEPENDENCIES);
    let clone = fresh_clone(&home, &origin);

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
    // The settle added nothing beyond the record, so the one yes covered it.
    assert!(
        !said(&refreshed).contains("settling added"),
        "{}",
        said(&refreshed)
    );
    let lock = kendex_core::lock::load(&clone.join(".kendex-lock.json")).unwrap();
    let recorded = lock
        .entries
        .values()
        .find(|entry| entry.name == "pi-widgets")
        .unwrap();
    assert_eq!(recorded.kind, kendex_core::model::ItemKind::PiExtension);
    assert_eq!(recorded.rendered_hash, Some(recorded.source_hash.clone()));
}

/// A consumer can commit newer catalog bytes without refreshing its render.
/// The lock authorizes that update; without it, refresh skips the skill and
/// retains the committed inventory.
#[cfg(not(windows))]
#[test]
#[allow(clippy::unwrap_used)]
fn a_stale_committed_skill_keeps_its_inventory_with_or_without_a_lock() {
    for has_lock in [true, false] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        fs::create_dir_all(home.join(".claude")).unwrap();
        let origin = committed_consumer(&home, NO_DEPENDENCIES);
        let clone = fresh_clone(&home, &origin);
        let args = ["refresh", "--scope", "project", "--yes", "--leave"];
        let recovered = kendex(&home, &clone, &args);
        assert_eq!(recovered.status.code(), Some(0), "{}", said(&recovered));
        let lock = clone.join(".kendex-lock.json");
        if !has_lock {
            fs::remove_file(lock).unwrap();
        }
        write(
            &clone.join("catalog/skills/deploy/SKILL.md"),
            "---\nname: deploy\ndescription: ship the service\n---\nRun the updated deploy.\n",
        );
        git(&home, &clone, &["add", "catalog/skills/deploy/SKILL.md"]);
        git(&home, &clone, &["commit", "-q", "-m", "update source"]);
        let inventory = clone.join(".kendex-generated.json");
        let before = fs::read(&inventory).unwrap();

        let refreshed = kendex(&home, &clone, &args);
        let output = said(&refreshed);
        assert_eq!(refreshed.status.code(), Some(0), "{output}");
        assert_eq!(fs::read(&inventory).unwrap(), before, "lock={has_lock}");
        let status = git(&home, &clone, &["status", "--porcelain"]);
        if has_lock {
            assert_eq!(status, " M .agents/skills/deploy/SKILL.md\n");
            assert!(!output.contains("skipped 1 item on conflict"), "{output}");
        } else {
            assert_eq!(status, "", "{output}");
            assert!(output.contains("skipped 1 item on conflict"), "{output}");
        }
    }
}

/// A carrier the settle registers makes a declared Pi hook real, so the
/// plan derived after the settle carries a registration the plan the yes
/// covered did not: that addition is shown and asked about before it is
/// written. Read from a lockless project rather than a clone, since the
/// state under test is the missing record and the unregistered carrier.
#[test]
#[allow(clippy::unwrap_used)]
fn a_registration_the_settle_makes_real_is_shown_and_asked_about() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("dev/app");
    write(
        &project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"pi\"]\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.\"@vanillagreen/pi-hooks\"]\nsource = \"cat\"\n\n[[custom-hooks]]\nname = \"guard\"\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"exit 2\"\nagents = \"all\"\n",
    );
    write(
        &project.join("catalog/pi-extensions/pi-hooks/package.json"),
        "{\"name\": \"@vanillagreen/pi-hooks\", \"version\": \"1.0.0\"}\n",
    );
    fs::create_dir_all(project.join(".pi")).unwrap();

    let refreshed = kendex(&home, &project, &["refresh", "--scope", "project", "--yes"]);

    assert_eq!(refreshed.status.code(), Some(0), "{}", said(&refreshed));
    assert!(
        said(&refreshed).contains("settling added to what this run writes"),
        "{}",
        said(&refreshed)
    );
    assert!(project.join(".pi/kendex/hooks.json").is_file());
}

/// The settle is a write into the checkout, and a run with nobody to ask
/// refuses before its first write, naming the flag that would have
/// answered: no package copied, no record written, the clone as cloned.
#[test]
#[allow(clippy::unwrap_used)]
fn without_a_yes_a_fresh_clone_is_refused_before_anything_is_written() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let origin = committed_consumer(&home, NO_DEPENDENCIES);
    let clone = fresh_clone(&home, &origin);

    let refused = kendex(&home, &clone, &["refresh", "--scope", "project", "--leave"]);

    assert_eq!(refused.status.code(), Some(1), "{}", said(&refused));
    assert!(said(&refused).contains("--yes"), "{}", said(&refused));
    assert!(!clone.join(".kendex-lock.json").exists());
    assert_eq!(git(&home, &clone, &["status", "--porcelain"]), "");
}

/// A package declaring dependencies installs through `npm install`, and
/// with it the package's own lifecycle scripts, which arrived with the
/// fetch this refresh made. Refresh leaves that package to `update-pi`:
/// no process runs, the package stays drift, and the run fails naming the
/// verb that installs it.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_package_whose_install_runs_npm_is_left_to_update_pi() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let marker = home.join("npm-ran");
    npm_that_marks(&home, &marker);
    let origin = committed_consumer(&home, WITH_A_DEPENDENCY);
    assert!(
        marker.is_file(),
        "update-pi in the origin installs through npm"
    );
    fs::remove_file(&marker).unwrap();
    let clone = fresh_clone(&home, &origin);

    let refreshed = kendex(
        &home,
        &clone,
        &["refresh", "--scope", "project", "--yes", "--leave"],
    );

    assert_eq!(refreshed.status.code(), Some(1), "{}", said(&refreshed));
    assert!(
        said(&refreshed).contains("update-pi"),
        "{}",
        said(&refreshed)
    );
    assert!(!marker.exists(), "refresh ran npm for the clone's package");
    assert!(
        !clone
            .join(".pi/packages/pi-widgets/postinstall-ran")
            .exists()
    );
}
