use std::path::PathBuf;
use std::time::Duration;

use kendex_core::process::Hardened;

use super::{CliResult, out, say};

/// The release feed: `{"version": "1.2.3", "assets": {"<target>": "<url>"}}`.
/// `KENDEX_UPDATE_FEED` overrides the URL so compat tests run against a
/// local fixture instead of the network.
fn feed_url() -> String {
    std::env::var("KENDEX_UPDATE_FEED").unwrap_or_else(|_| {
        "https://github.com/vanillagreencom/kendex/releases/latest/download/feed.json".to_owned()
    })
}

/// The feed keys its assets by the build target, one per lane in
/// `.github/workflows/release.yml`; `build.rs` bakes it in from Cargo.
fn target_triple() -> &'static str {
    env!("KENDEX_TARGET")
}

fn fetch(url: &str) -> Result<Vec<u8>, String> {
    // This fetches release binaries as well as the small feed, so it needs
    // room for a slow download.
    let output = Hardened::curl(&["-fsSL", url])
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

pub fn run(force: bool) -> CliResult {
    let feed_bytes = fetch(&feed_url())?;
    let feed: serde_json::Value =
        serde_json::from_slice(&feed_bytes).map_err(|e| format!("invalid release feed: {e}"))?;
    let latest = feed
        .get("version")
        .and_then(|v| v.as_str())
        .ok_or("release feed has no version")?;
    let current = env!("CARGO_PKG_VERSION");
    if latest == current && !force {
        out(&format!("already up to date ({current})"));
        return Ok(());
    }
    let target = target_triple();
    let asset = feed
        .get("assets")
        .and_then(|a| a.get(target))
        .and_then(|u| u.as_str())
        .ok_or_else(|| format!("release {latest} has no asset for {target}"))?;

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
