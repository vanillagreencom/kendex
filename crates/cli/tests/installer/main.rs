//! `install.sh` on Linux, driven end to end with the network stubbed out.
//! What the installer writes into the desktop environment is invisible until
//! someone opens their launcher, so it is asserted here instead.
#![cfg(target_os = "linux")]

mod desktop;
mod icons;

use std::path::{Path, PathBuf};
use std::process::Command;

#[allow(clippy::unwrap_used, clippy::expect_used)]
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

#[allow(clippy::unwrap_used, clippy::expect_used)]
fn set_mode(path: &Path, mode: u32) {
    let mut permissions = std::fs::metadata(path).expect("metadata").permissions();
    std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, mode);
    std::fs::set_permissions(path, permissions).expect("set mode");
}

/// Read off a file this process just made, rather than through a new
/// dependency: its owner is whoever this process is.
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn running_as_root() -> bool {
    let probe = tempfile::NamedTempFile::new().expect("probe file");
    let made = probe.as_file().metadata().expect("probe metadata");
    std::os::unix::fs::MetadataExt::uid(&made) == 0
}

/// Hands the modes back however the test ends. A directory left unwritable
/// by a failing assertion is one `TempDir` cannot clean up, so the run that
/// most needs a tidy machine would be the one to litter it.
struct Unlocked(Vec<PathBuf>);

impl Drop for Unlocked {
    fn drop(&mut self) {
        for dir in &self.0 {
            if std::fs::metadata(dir).is_ok() {
                set_mode(dir, 0o755);
            }
        }
    }
}

#[allow(clippy::unwrap_used, clippy::expect_used)]
fn write_stub(dir: &Path, name: &str, script: &str) {
    let path = dir.join(name);
    std::fs::write(&path, script).expect("write stub");
    set_mode(&path, 0o755);
}

/// Stand in for the network, down to the details that matter. The release
/// lookup answers with a tag; a raw file URL is served out of this working
/// tree, and a missing path fails the way the worst `curl -f` ever did —
/// empty file created, exit 22 — so neither a mistyped asset nor a leftover
/// husk can pass unnoticed. Anything else is a release download and gets a
/// runnable placeholder.
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
    # Deliberate pessimism, not a description of curl 8.x, which leaves an
    # existing file untouched on -f and creates none where there was none.
    # Older curl did leave an empty file behind, and an installer that
    # cannot cope with that is one bad enough curl away from planting a
    # broken icon in a slot a launcher prefers.
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

/// A network that cannot answer the release lookup. That lookup is the one
/// pipeline in the installer, and the reason the script does not lean on
/// `pipefail` to notice a failure inside it.
const CURL_WITHOUT_RELEASES: &str = r#"#!/bin/sh
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *api.github.com*) exit 22 ;;
  *) : > "$out" ;;
esac
"#;

/// The shell the published command uses: `curl … | sh`, which is dash on
/// Debian and Ubuntu. Where dash is installed it is preferred, because
/// `/bin/sh` is bash on some distributions and a bashism would then sail
/// straight through the check meant to catch it.
fn posix_shell() -> &'static str {
    let runs = |shell: &str| {
        Command::new(shell)
            .args(["-c", "exit 0"])
            .output()
            .is_ok_and(|probe| probe.status.success())
    };
    if runs("dash") { "dash" } else { "sh" }
}

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
    let (tmp, output) = installer_output(source_root, CURL, DATA_DIR, prepare);
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

/// Where the installer is told to put the app and its icons. Named here
/// because one test hands it a directory with a space in its name.
const DATA_DIR: &str = "share";

/// The installer run against a stubbed network, and whatever it said.
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn installer_output(
    source_root: &Path,
    curl: &str,
    data_dir: &str,
    prepare: impl FnOnce(&Path),
) -> (tempfile::TempDir, std::process::Output) {
    let tmp = tempfile::tempdir().expect("tempdir");
    let stubs = tmp.path().join("stub-bin");
    std::fs::create_dir_all(&stubs).expect("stub bin dir");
    write_stub(
        &stubs,
        "curl",
        &curl.replace("__ROOT__", &source_root.display().to_string()),
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
    let output = Command::new(posix_shell())
        .arg(repo_root().join("install.sh"))
        .env("PATH", path)
        .env("HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path().join(data_dir))
        .output()
        .expect("install.sh runs");
    (tmp, output)
}

/// `set -o pipefail` is not in the shell the published command runs, so the
/// release lookup cannot lean on it. A lookup that answers with nothing has
/// to stop the install and say so, rather than carrying an empty version
/// into every download URL.
#[test]
fn a_release_lookup_that_answers_with_nothing_stops_the_install() {
    let (tmp, output) = installer_output(&repo_root(), CURL_WITHOUT_RELEASES, DATA_DIR, |_| {});
    assert!(!output.status.success(), "the install carried on");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("could not resolve the latest release"),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        !tmp.path().join(".local/bin/kendex").exists(),
        "a version it could not resolve still installed something"
    );
}

#[allow(clippy::unwrap_used, clippy::expect_used)]
fn desktop_entry(tmp: &tempfile::TempDir) -> String {
    std::fs::read_to_string(tmp.path().join("share/applications/kendex.desktop"))
        .expect("desktop entry")
}

fn icon_slot(home: &Path, size: &str) -> PathBuf {
    home.join(format!("share/icons/hicolor/{size}/apps/kendex.png"))
}

/// The name tauri gives the app binary, which is what a Linux launcher
/// matches the running window against.
#[allow(clippy::unwrap_used, clippy::expect_used)]
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
