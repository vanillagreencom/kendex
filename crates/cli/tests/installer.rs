//! `install.sh` on Linux, driven end to end with the network stubbed out.
//! What the installer writes into the desktop environment is invisible until
//! someone opens their launcher, so it is asserted here instead.
#![cfg(target_os = "linux")]

use std::path::{Path, PathBuf};
use std::process::Command;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repo root")
}

/// Every icon the app ships, and the theme slot the installer owes it to.
const ICONS: [(&str, &str); 4] = [
    ("32x32", "32x32.png"),
    ("128x128", "128x128.png"),
    ("256x256", "128x128@2x.png"),
    ("512x512", "icon.png"),
];

fn set_mode(path: &Path, mode: u32) {
    let mut permissions = std::fs::metadata(path).expect("metadata").permissions();
    std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, mode);
    std::fs::set_permissions(path, permissions).expect("set mode");
}

fn write_stub(dir: &Path, name: &str, script: &str) {
    let path = dir.join(name);
    std::fs::write(&path, script).expect("write stub");
    set_mode(&path, 0o755);
}

/// Stand in for the network, down to the details that matter. The release
/// lookup answers with a tag; a raw file URL is served out of this working
/// tree, and a missing path fails the way `curl -f` fails — empty file
/// created, exit 22 — so neither a mistyped asset nor the leftover it
/// leaves can pass unnoticed. Anything else is a release download and gets
/// a runnable placeholder.
const CURL: &str = r#"#!/usr/bin/env bash
out=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *api.github.com*) echo '{"tag_name": "v9.9.9"}' ;;
  *raw.githubusercontent.com/*)
    path="${url#*raw.githubusercontent.com/}"
    path="${path#*/}"; path="${path#*/}"; path="${path#*/}"
    # curl opens the output file before it knows the request failed, and
    # leaves the empty one behind on -f; the installer has to cope with that.
    : > "$out"
    [ -f "__ROOT__/$path" ] || exit 22
    cp "__ROOT__/$path" "$out" ;;
  *) printf '#!/bin/sh\necho stub\n' > "$out" ;;
esac
"#;

/// The installer branches on the machine it is running on, and the Linux
/// path is the one under test whatever built the runner.
const UNAME: &str = r#"#!/bin/sh
case "$1" in
  -m) echo x86_64 ;;
  *) echo Linux ;;
esac
"#;

/// A test that reaches for sudo is about to write outside its temp dir, so
/// it fails here instead.
const SUDO: &str = "#!/bin/sh\necho 'installer test tried to escalate' >&2\nexit 1\n";

fn run_installer() -> tempfile::TempDir {
    run_installer_serving(&repo_root())
}

/// `source_root` is what the stubbed network serves raw file URLs out of;
/// an empty directory stands in for assets that cannot be fetched.
fn run_installer_serving(source_root: &Path) -> tempfile::TempDir {
    run_installer_over(source_root, |_| {})
}

/// `prepare` runs against the temp home before the installer does, for the
/// cases that are about what the installer finds already there.
fn run_installer_over(source_root: &Path, prepare: impl FnOnce(&Path)) -> tempfile::TempDir {
    let tmp = tempfile::tempdir().expect("tempdir");
    let stubs = tmp.path().join("stub-bin");
    std::fs::create_dir_all(&stubs).expect("stub bin dir");
    write_stub(
        &stubs,
        "curl",
        &CURL.replace("__ROOT__", &source_root.display().to_string()),
    );
    write_stub(&stubs, "uname", UNAME);
    write_stub(&stubs, "sudo", SUDO);

    prepare(tmp.path());

    // The installer puts the command in the first of its candidate
    // directories that is already on PATH; naming the temp one keeps every
    // write inside the temp dir.
    let path = format!(
        "{}:{}/.local/bin:{}",
        stubs.display(),
        tmp.path().display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let output = Command::new("bash")
        .arg(repo_root().join("install.sh"))
        .env("PATH", path)
        .env("HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path().join("share"))
        .output()
        .expect("install.sh runs");
    assert!(
        output.status.success(),
        "install.sh failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        tmp.path().join(".local/bin/kendex").is_file(),
        "the installer wrote the command outside its temp home"
    );
    tmp
}

fn desktop_entry(tmp: &tempfile::TempDir) -> String {
    std::fs::read_to_string(tmp.path().join("share/applications/kendex.desktop"))
        .expect("desktop entry")
}

/// The name tauri gives the app binary, which is what a Linux launcher
/// matches the running window against.
fn app_binary_name() -> String {
    let manifest = std::fs::read_to_string(repo_root().join("crates/app/Cargo.toml"))
        .expect("crates/app/Cargo.toml");
    manifest
        .lines()
        .skip_while(|line| line.trim() != "[package]")
        .skip(1)
        .take_while(|line| !line.trim_start().starts_with('['))
        .find_map(|line| line.trim().strip_prefix("name = "))
        .map(|name| name.trim().trim_matches('"').to_owned())
        .expect("crates/app/Cargo.toml names the package")
}

/// Without this, a launcher shows the running app as a second entry with no
/// name and no icon, because it cannot tell the window belongs to kendex.
#[test]
fn the_desktop_entry_names_the_window_class() {
    let tmp = run_installer();
    let expected = format!("\nStartupWMClass={}\n", app_binary_name());
    assert!(desktop_entry(&tmp).contains(&expected), "{expected:?}");
}

/// A launcher filling a HiDPI slot from the 128px icon upscales it, and the
/// result looks soft beside every other app on the machine.
#[test]
fn every_icon_the_app_ships_lands_in_its_own_slot() {
    let tmp = run_installer();
    for (size, source) in ICONS {
        let installed = tmp
            .path()
            .join(format!("share/icons/hicolor/{size}/apps/kendex.png"));
        let installed = std::fs::read(&installed)
            .unwrap_or_else(|error| panic!("{size}: {} ({error})", installed.display()));
        let expected = std::fs::read(repo_root().join("crates/app/icons").join(source))
            .expect("the app ships this icon");
        assert_eq!(installed, expected, "the {size} slot must carry {source}");
    }
}

/// curl creates the output file before the transfer, so a fetch that fails
/// leaves an empty one behind — in the very slot a HiDPI launcher prefers,
/// where it would shadow the size that did install.
#[test]
fn an_icon_that_cannot_be_fetched_leaves_nothing_behind() {
    let nothing = tempfile::tempdir().expect("tempdir");
    let tmp = run_installer_serving(nothing.path());
    for (size, _) in ICONS {
        let slot = tmp
            .path()
            .join(format!("share/icons/hicolor/{size}/apps/kendex.png"));
        assert!(!slot.exists(), "{size}: {}", slot.display());
    }
}

fn icon_slot(home: &Path, size: &str) -> PathBuf {
    home.join(format!("share/icons/hicolor/{size}/apps/kendex.png"))
}

/// This script is the upgrade path too, and the icon fetches go to a host
/// that rate-limits. Taking away the icon a previous run installed, because
/// this run could not fetch it, leaves the person worse off than not having
/// run the installer at all.
#[test]
fn a_fetch_that_fails_keeps_the_icon_an_earlier_run_installed() {
    let nothing = tempfile::tempdir().expect("tempdir");
    let earlier = b"an icon a previous run installed".as_slice();
    let tmp = run_installer_over(nothing.path(), |home| {
        for (size, _) in ICONS {
            let slot = icon_slot(home, size);
            std::fs::create_dir_all(slot.parent().expect("slot dir")).expect("slot");
            std::fs::write(&slot, earlier).expect("earlier icon");
        }
    });

    for (size, _) in ICONS {
        let slot = icon_slot(tmp.path(), size);
        assert_eq!(
            std::fs::read(&slot).expect("earlier icon"),
            earlier,
            "{size}"
        );
    }
}

/// Icons someone once installed under sudo: the file cannot be overwritten
/// and the directory cannot be written either, so neither replacing the icon
/// nor removing it can succeed. An icon is not worth failing an install over
/// — the app is already copied by then, and the launcher entry is not
/// written yet.
#[test]
fn icons_it_can_neither_replace_nor_remove_do_not_stop_the_install() {
    let earlier = b"an icon a previous run installed".as_slice();
    let tmp = run_installer_over(&repo_root(), |home| {
        for (size, _) in ICONS {
            let slot = icon_slot(home, size);
            let dir = slot.parent().expect("slot dir");
            std::fs::create_dir_all(dir).expect("slot");
            std::fs::write(&slot, earlier).expect("earlier icon");
            set_mode(&slot, 0o444);
            set_mode(dir, 0o555);
        }
    });

    assert!(desktop_entry(&tmp).contains("StartupWMClass="));
    for (size, _) in ICONS {
        let slot = icon_slot(tmp.path(), size);
        assert_eq!(
            std::fs::read(&slot).expect("earlier icon"),
            earlier,
            "{size}"
        );
        // Handed back so the temp directory can be cleaned up.
        set_mode(slot.parent().expect("slot dir"), 0o755);
    }
}

/// Two files write a kendex desktop entry — this installer and the Arch
/// package — and a launcher reads whichever one is installed, so a fix to
/// one that misses the other fixes the app for half its Linux users.
#[test]
fn the_arch_package_installs_what_the_installer_installs() {
    let tmp = run_installer();
    let pkgbuild = std::fs::read_to_string(repo_root().join("packaging/arch/kendex-bin/PKGBUILD"))
        .expect("the kendex-bin PKGBUILD");
    let packaged = pkgbuild
        .split_once("<<'DESKTOP'\n")
        .and_then(|(_, rest)| rest.split_once("\nDESKTOP"))
        .map(|(entry, _)| entry.to_owned())
        .expect("the PKGBUILD writes a desktop entry");

    // Exec is the one field that differs: an AppImage under the user's data
    // directory here, one under /usr/lib there.
    let fields = |entry: &str| {
        let mut lines: Vec<String> = entry
            .lines()
            .filter(|line| !line.starts_with("Exec="))
            .map(str::to_owned)
            .collect();
        lines.sort();
        lines
    };
    assert_eq!(fields(&packaged), fields(desktop_entry(&tmp).trim()));

    // Where the package really installs icons, read off the install lines a
    // build would run rather than the text of the file: a path inside a
    // comment ships nothing.
    let installed: Vec<String> = pkgbuild
        .lines()
        .map(str::trim)
        .filter(|line| !line.starts_with('#'))
        .filter_map(|line| line.split_once("\"$pkgdir/"))
        .filter_map(|(_, dest)| dest.split_once('"'))
        .map(|(dest, _)| dest.to_owned())
        .filter(|dest| dest.contains("icons/hicolor/"))
        .collect();
    let expected: Vec<String> = ICONS
        .iter()
        .map(|(size, _)| format!("usr/share/icons/hicolor/{size}/apps/kendex.png"))
        .collect();
    assert_eq!(installed, expected);
}
