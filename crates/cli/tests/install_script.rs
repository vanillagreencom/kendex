//! `install.sh` platform detection: every release lane's host picks its own
//! CLI binary and, on Linux, its own AppImage. Runs the real script with a
//! fake `uname` and a `curl` that records what it was asked for.

#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

#[allow(clippy::unwrap_used)]
fn write_exe(path: &Path, body: &str) {
    fs::write(path, body).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

/// Runs install.sh as `os`/`arch` and returns every URL curl was handed.
fn requested_urls(os: &str, arch: &str) -> String {
    let (output, urls) = run_install(os, arch, "");
    assert!(
        output.status.success(),
        "install.sh failed for {os} {arch}:\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    urls
}

/// Runs install.sh as `os`/`arch`; the fake curl answers any URL containing
/// `missing` with exit 22, curl's code for an HTTP error.
#[allow(clippy::unwrap_used)]
fn run_install(os: &str, arch: &str, missing: &str) -> (std::process::Output, String) {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let fake = home.join("fake-bin");
    let bindir = home.join(".local/bin");
    fs::create_dir_all(&fake).unwrap();
    fs::create_dir_all(&bindir).unwrap();
    write_exe(
        &fake.join("uname"),
        &format!("#!/bin/sh\ncase \"$1\" in -s) echo {os} ;; -m) echo {arch} ;; esac\n"),
    );
    // Logs the URL; `-o FILE` gets a runnable stand-in for the download,
    // and the release lookup gets a tag.
    let miss = if missing.is_empty() {
        String::new()
    } else {
        format!("case \"$url\" in *{missing}*) exit 22 ;; esac\n")
    };
    write_exe(
        &fake.join("curl"),
        &format!(
            "#!/bin/sh\nout=\"\"\nwhile [ $# -gt 0 ]; do case \"$1\" in -o) out=\"$2\"; shift 2 ;; *) url=\"$1\"; shift ;; esac; done\n\
             echo \"$url\" >> \"{log}\"\n{miss}\
             if [ -n \"$out\" ]; then printf '#!/bin/sh\\necho v9\\n' > \"$out\"; else echo '\"tag_name\": \"v9.9.9\"'; fi\n",
            log = home.join("urls.txt").display()
        ),
    );
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../install.sh");
    let output = Command::new("bash")
        .arg(script)
        .env_clear()
        .env("HOME", home)
        .env(
            "PATH",
            format!(
                "{}:{}:{}",
                fake.display(),
                bindir.display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        )
        .output()
        .unwrap();
    let urls = fs::read_to_string(home.join("urls.txt")).unwrap_or_default();
    (output, urls)
}

#[test]
#[allow(clippy::unwrap_used)]
fn each_release_host_downloads_its_own_binary() {
    for (os, arch, target) in [
        ("Linux", "x86_64", "x86_64-unknown-linux-gnu"),
        ("Linux", "amd64", "x86_64-unknown-linux-gnu"),
        ("Linux", "aarch64", "aarch64-unknown-linux-gnu"),
        ("Linux", "arm64", "aarch64-unknown-linux-gnu"),
        ("Darwin", "arm64", "aarch64-apple-darwin"),
        ("Darwin", "aarch64", "aarch64-apple-darwin"),
        ("Darwin", "x86_64", "x86_64-apple-darwin"),
    ] {
        let urls = requested_urls(os, arch);
        assert!(
            urls.contains(&format!("/download/v9.9.9/kendex-{target}\n")),
            "{os} {arch} fetched:\n{urls}"
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn linux_picks_the_appimage_built_for_its_architecture() {
    let urls = requested_urls("Linux", "x86_64");
    assert!(urls.contains("/kendex_9.9.9_amd64.AppImage"), "{urls}");
    let urls = requested_urls("Linux", "aarch64");
    assert!(urls.contains("/kendex_9.9.9_aarch64.AppImage"), "{urls}");
    let urls = requested_urls("Darwin", "x86_64");
    assert!(!urls.contains(".AppImage"), "{urls}");
}

/// The matrix lanes and the feed.json keys are two lists in release.yml;
/// a lane missing from either leaves that host's `kendex update` with no
/// asset to find.
#[test]
#[allow(clippy::unwrap_used)]
fn release_matrix_and_feed_name_the_same_targets() {
    let workflow = fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../.github/workflows/release.yml"),
    )
    .unwrap();
    let mut lanes: Vec<&str> = workflow
        .lines()
        .filter_map(|l| l.trim().strip_prefix("target: "))
        .collect();
    let mut feed: Vec<&str> = workflow
        .lines()
        .filter_map(|l| {
            let l = l.trim().strip_prefix('"')?;
            let (key, rest) = l.split_once("\": \"${base}/kendex-")?;
            rest.starts_with(key).then_some(key)
        })
        .collect();
    lanes.sort();
    feed.sort();
    assert!(!lanes.is_empty());
    assert_eq!(lanes, feed);
}

#[test]
fn a_release_without_this_target_says_so_instead_of_a_bare_curl_error() {
    let (output, _) = run_install("Darwin", "x86_64", "kendex-x86_64-apple-darwin");
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("could not download kendex-x86_64-apple-darwin from"),
        "{stderr}"
    );
    assert!(
        stderr.contains("release v9.9.9 may have no build for x86_64-apple-darwin"),
        "{stderr}"
    );
}
