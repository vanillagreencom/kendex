use std::path::PathBuf;
use std::time::Duration;

use kendex_core::process::Hardened;
use kendex_core::update_feed::{RELEASE_FEED_URL, ReleaseFeed, VersionRelation, release_notes_url};

use super::{CliResult, out, say};

/// The release feed is parsed by core so the CLI and app accept one schema.
/// `KENDEX_UPDATE_FEED` overrides the URL so compat tests run against a
/// local fixture instead of the network.
fn feed_url() -> String {
    std::env::var("KENDEX_UPDATE_FEED").unwrap_or_else(|_| RELEASE_FEED_URL.to_owned())
}

/// The feed keys its assets by the build target, one per lane in
/// `.github/workflows/release.yml`; `build.rs` bakes it in from Cargo.
fn target_triple() -> &'static str {
    env!("KENDEX_TARGET")
}

fn fetch(url: &str) -> Result<Vec<u8>, String> {
    // This fetches release binaries as well as the small feed, so it needs
    // room for a slow download.
    let output = Hardened::curl(&curl_args(url))
        .timeout(Duration::from_secs(600))
        .run()
        .map_err(|e| format!("curl unavailable: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "fetching {url} failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(output.stdout)
}

fn curl_args(url: &str) -> [&str; 3] {
    ["-fsSL", "--", url]
}

pub fn run(force: bool) -> CliResult {
    let feed_bytes = fetch(&feed_url())?;
    let feed = ReleaseFeed::parse(&feed_bytes)?;
    let latest = feed.version.as_str();
    let current = env!("CARGO_PKG_VERSION");
    match feed.relation_to(current)? {
        VersionRelation::Current if !force => {
            out(&format!("already up to date ({current})"));
            return Ok(());
        }
        VersionRelation::Older if !force => {
            return Err(format!(
                "release feed offers {latest}, older than installed {current}; use --force to downgrade"
            )
            .into());
        }
        VersionRelation::Older | VersionRelation::Current | VersionRelation::Newer => {}
    }
    let target = target_triple();
    let Some(asset) = feed.asset_for(target) else {
        out(&format!(
            "release {latest} is available: {}",
            release_notes_url(latest)?
        ));
        return Ok(());
    };

    say(&format!("updating {current} → {latest}"));
    let binary = fetch(asset)?;
    let current_exe = std::env::current_exe()?;
    let staged = staged_path(&current_exe);
    std::fs::write(&staged, &binary)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755))?;
    }
    // Replacing a running executable works via rename on every target OS.
    std::fs::rename(&staged, &current_exe)?;
    out(&format!("updated to {latest}"));
    Ok(())
}

fn staged_path(current: &std::path::Path) -> PathBuf {
    let mut name = current
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "kendex".to_owned());
    name.push_str(".update");
    current.with_file_name(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fetched_urls_are_always_positional_arguments() {
        assert_eq!(
            curl_args("--output=/tmp/owned"),
            ["-fsSL", "--", "--output=/tmp/owned"]
        );
    }
}
