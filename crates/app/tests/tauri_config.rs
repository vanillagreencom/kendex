//! What `tauri.conf.json` has to say for the window to open the way the app
//! expects — load-bearing settings that never show up in a compile error
//! when they go missing.

use std::path::Path;

#[allow(clippy::expect_used)]
fn config() -> serde_json::Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tauri.conf.json");
    serde_json::from_str(&std::fs::read_to_string(path).expect("tauri.conf.json"))
        .expect("tauri.conf.json parses")
}

/// The saved zoom is applied in `setup`, which runs after the window is
/// built. A window that is visible by then shows one frame at full size and
/// re-lays out the whole app in front of the person.
#[test]
fn the_window_opens_hidden_so_the_saved_zoom_lands_first() {
    let window = &config()["app"]["windows"][0];
    assert_eq!(window["visible"].as_bool(), Some(false));
    // The label the reveal looks up. Left to tauri's default, a hidden
    // window would simply never be shown if that default ever changed.
    assert_eq!(window["label"].as_str(), Some("main"));
}

/// The app's updater reads its key from this file at build time, so the
/// copy core holds for `kendex update` can only be kept honest by an
/// assertion. Two keys means one delivery path trusting what the other
/// would turn away.
#[test]
fn the_app_and_the_cli_pin_one_updater_key() {
    assert_eq!(
        config()["plugins"]["updater"]["pubkey"].as_str(),
        Some(kendex_core::update_feed::UPDATER_PUBLIC_KEY)
    );
}
