use kendex_core::app_update::AppUpdateView;
use kendex_core::env::Env;
use kendex_core::registry::ReleaseFeedFetch;

const RELEASE_FEED: &str =
    "https://github.com/vanillagreencom/kendex/releases/latest/download/feed.json";

fn feed_url() -> String {
    #[cfg(debug_assertions)]
    {
        selected_feed(std::env::var("KENDEX_UPDATE_FEED").ok(), true)
    }
    #[cfg(not(debug_assertions))]
    {
        selected_feed(None, false)
    }
}

fn selected_feed(override_url: Option<String>, debug_build: bool) -> String {
    match (debug_build, override_url) {
        (true, Some(url)) => url,
        (true, None) | (false, _) => RELEASE_FEED.to_owned(),
    }
}

fn check(refresh: bool) -> Result<AppUpdateView, String> {
    let env = Env::detect().map_err(|error| error.to_string())?;
    let settings = kendex_core::settings::load(&env).map_err(|error| error.to_string())?;
    kendex_core::app_update::check(
        &env,
        &ReleaseFeedFetch,
        kendex_core::app_update::CheckRequest {
            current_version: env!("CARGO_PKG_VERSION"),
            target: env!("KENDEX_TARGET"),
            feed_url: &feed_url(),
            refresh,
            automatic_check_enabled: settings.auto_update_check,
            muted_version: settings.muted_app_notice.as_deref(),
        },
    )
    .map_err(|error| error.to_string())
}

/// Read the remembered app release status, refreshing it when requested or
/// when the six-hour automatic interval has elapsed.
#[tauri::command(async)]
#[specta::specta]
pub fn app_update_check(refresh: bool) -> Result<AppUpdateView, String> {
    check(refresh)
}

/// The launch does not wait for network or cache I/O. The first command call
/// reuses the generation this task writes instead of starting another fetch.
pub fn schedule_startup_check() {
    tauri::async_runtime::spawn_blocking(|| {
        if let Err(error) = check(false) {
            use std::io::Write;
            let _ = writeln!(std::io::stderr(), "app update check failed: {error}");
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_debug_builds_accept_a_feed_override() {
        let fixture = "file:///fixtures/feed.json".to_owned();
        assert_eq!(selected_feed(Some(fixture.clone()), true), fixture);
        assert_eq!(selected_feed(Some(fixture), false), RELEASE_FEED);
    }
}
