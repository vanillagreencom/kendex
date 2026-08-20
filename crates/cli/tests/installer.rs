//! `install.sh` on Linux, driven end to end with `curl` stubbed out. What
//! the installer writes into the desktop environment is invisible until
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

fn write_stub(dir: &Path, name: &str, script: &str) {
    let path = dir.join(name);
    std::fs::write(&path, script).expect("write stub");
    let mut permissions = std::fs::metadata(&path)
        .expect("stub metadata")
        .permissions();
    std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
    std::fs::set_permissions(&path, permissions).expect("make the stub runnable");
}

/// Stand in for the network: the release lookup answers with a tag, and
/// every download writes a runnable placeholder where it was asked to.
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
  *) printf '#!/bin/sh\necho stub\n' > "$out" ;;
esac
"#;

/// A test that reaches for sudo is about to write outside its temp dir, so
/// it fails here instead.
const SUDO: &str = "#!/bin/sh\necho 'installer test tried to escalate' >&2\nexit 1\n";

fn run_installer() -> tempfile::TempDir {
    let tmp = tempfile::tempdir().expect("tempdir");
    let stubs = tmp.path().join("stub-bin");
    std::fs::create_dir_all(&stubs).expect("stub bin dir");
    write_stub(&stubs, "curl", CURL);
    write_stub(&stubs, "sudo", SUDO);

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

/// Without this, a launcher shows the running app as a second entry with no
/// name and no icon, because it cannot tell the window belongs to kendex.
#[test]
fn the_desktop_entry_names_the_window_class() {
    let tmp = run_installer();
    let entry = std::fs::read_to_string(tmp.path().join("share/applications/kendex.desktop"))
        .expect("desktop entry");
    assert!(entry.contains("\nStartupWMClass=kendex-app\n"), "{entry}");
}

/// A launcher filling a HiDPI slot from the 128px icon upscales it, and the
/// result looks soft beside every other app on the machine.
#[test]
fn every_icon_size_the_app_ships_is_installed() {
    let tmp = run_installer();
    for size in ["128x128", "256x256", "512x512"] {
        let icon = tmp
            .path()
            .join(format!("share/icons/hicolor/{size}/apps/kendex.png"));
        assert!(
            icon.is_file(),
            "missing the {size} icon at {}",
            icon.display()
        );
    }
}
