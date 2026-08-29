//! The Homebrew cask is the default macOS install, and its `app` stanza puts
//! a symlink at `/Applications/kendex.app` pointing into the Caskroom, so
//! every launch from there carries a symlinked ancestor. Two halves have to
//! hold on that layout: kendex judges the bundle behind the link, and tauri
//! stops refusing to name a binary reached through one.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::path::{Path, PathBuf};

use kendex_core::install_channel::{AppInstall, Host, InstallChannel, for_app};

/// Tells the child process which half of the probe it is. The parent sets
/// it; the child answers rather than launching another child.
const PROBE_VAR: &str = "KENDEX_CASK_SYMLINK_PROBE";

/// What a child prints once it has named its own binary. The parent needs
/// this in the output, so a filter that matches no test fails rather than
/// passing on an empty run.
const PROBE_OK: &str = "cask-symlink probe named ";

/// The probe's own name, as the harness filter spells it.
const PROBE_TEST: &str = "a_symlinked_launch_path_names_its_own_binary";

/// The tauri feature that turns the refusal off.
const SYMLINK_FEATURE: &str = "process-relaunch-dangerous-allow-symlink-macos";

/// A cask's shape under `root`: the versioned bundle in the Caskroom, and
/// `Applications/kendex.app` linked at it. Returns the path a launch from
/// `/Applications` is handed, then the bundle really holding those bytes.
#[allow(clippy::unwrap_used)]
fn cask_layout(root: &Path) -> (PathBuf, PathBuf) {
    let bundle = root.join("Caskroom/kendex/5.0.1/kendex.app");
    std::fs::create_dir_all(bundle.join("Contents/MacOS")).unwrap();
    std::fs::write(bundle.join("Contents/MacOS/kendex"), b"").unwrap();
    let applications = root.join("Applications");
    std::fs::create_dir_all(&applications).unwrap();
    std::os::unix::fs::symlink(&bundle, applications.join("kendex.app")).unwrap();
    (
        applications.join("kendex.app/Contents/MacOS/kendex"),
        bundle,
    )
}

/// The path the process is handed is the link. What `for_app` approves, and
/// what `app_update_install` then hands the updater, is the Caskroom copy
/// that the replacement actually overwrites — never the `/Applications`
/// name it was reached by.
#[test]
#[allow(clippy::unwrap_used)]
fn a_cask_launch_path_is_judged_at_the_bundle_behind_the_link() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let (launch, bundle) = cask_layout(&root);

    let install = AppInstall::mac_bundle(&Host, &launch);
    let judged = install.judged_path().expect("a mac bundle carries a path");
    assert_eq!(
        judged,
        bundle.join("Contents/MacOS/kendex"),
        "the link was judged instead of the bundle behind it"
    );
    assert_eq!(
        for_app(&install, &Host),
        InstallChannel::Direct,
        "a writable cask bundle is ours to replace"
    );

    // The updater climbs from the path it is handed to the unit it removes
    // and replaces. Nothing it lands on may escape the approved bundle.
    let derived = tauri_plugin_updater::extract_path_from_executable(judged).unwrap();
    assert!(
        derived.starts_with(&bundle),
        "the updater derived {} from {}, outside the approved {}",
        derived.display(),
        judged.display(),
        bundle.display()
    );
    assert!(
        !derived.starts_with(root.join("Applications")),
        "the updater would replace the link at {}",
        derived.display()
    );
}

/// tauri's own refusal, run from a real symlinked launch path.
///
/// It is computed before `main` from the path the process was exec'd with,
/// so nothing inside one process can stand in for it: this launches the test
/// binary again through a symlinked directory and asks the child. Both
/// refusal sites are named — the updater resolves its target with
/// `tauri::utils::platform::current_exe`, and the relaunch after a
/// successful replace goes through `tauri::process::current_binary`. On
/// Linux the check does not apply and the child answers trivially; on macOS
/// it is the difference between an Update button that works and one that
/// reports a symlink policy.
#[test]
#[allow(clippy::unwrap_used)]
fn a_symlinked_launch_path_names_its_own_binary() {
    if std::env::var_os(PROBE_VAR).is_some() {
        let updater = tauri::utils::platform::current_exe()
            .expect("the updater's path resolution refused a symlinked launch path");
        let relaunch = tauri::process::current_binary(&tauri::Env::default())
            .expect("the relaunch after an update refused a symlinked launch path");
        assert_eq!(updater, relaunch);
        println!("{PROBE_OK}{}", updater.display());
        return;
    }

    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let exe = std::env::current_exe().unwrap();
    // The cask's shape without copying the binary: a symlinked directory in
    // the middle of the launch path, real bytes behind it.
    let bundle = root.join("kendex.app");
    std::fs::create_dir_all(bundle.join("Contents")).unwrap();
    std::os::unix::fs::symlink(exe.parent().unwrap(), bundle.join("Contents/MacOS")).unwrap();
    let launch = bundle.join("Contents/MacOS").join(exe.file_name().unwrap());

    let child = std::process::Command::new(&launch)
        .args(["--exact", PROBE_TEST, "--nocapture", "--test-threads=1"])
        .env(PROBE_VAR, "1")
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&child.stdout);
    assert!(
        child.status.success() && stdout.contains(PROBE_OK),
        "launched through {}: {}\n{stdout}{}",
        launch.display(),
        child.status,
        String::from_utf8_lossy(&child.stderr)
    );
}

/// The refusal is macOS-only and no CI lane runs this crate's tests there,
/// so the probe above would stay green on every machine that could notice
/// the feature going missing. This notices.
#[test]
#[allow(clippy::unwrap_used)]
fn the_manifest_still_turns_the_refusal_off() {
    let manifest =
        std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml")).unwrap();
    let features = manifest.parse::<toml::Table>().unwrap()["dependencies"]["tauri"]["features"]
        .as_array()
        .expect("the tauri dependency names the features it turns on")
        .clone();
    assert!(
        features
            .iter()
            .any(|name| name.as_str() == Some(SYMLINK_FEATURE)),
        "crates/app/Cargo.toml no longer enables {SYMLINK_FEATURE}, so a cask \
         install's Update button refuses its own launch path again"
    );
}
