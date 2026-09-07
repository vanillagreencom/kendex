//! What `tauri.conf.json` has to say for the window to open the way the app
//! expects — load-bearing settings that never show up in a compile error
//! when they go missing.

use base64::Engine;
use std::path::Path;

#[allow(clippy::expect_used)]
fn config() -> serde_json::Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tauri.conf.json");
    serde_json::from_str(&std::fs::read_to_string(path).expect("tauri.conf.json"))
        .expect("tauri.conf.json parses")
}

/// The settings the window and the release path lean on, one row per JSON
/// pointer, each held to the value the code expects (a constant the app or
/// core owns wherever there is one).
///
/// - `visible: false`: the saved zoom is applied in `setup`, after the window
///   is built; a window visible by then shows one frame at full size.
/// - `label: "main"`: the label the reveal looks up; left to tauri's default,
///   a hidden window would never be shown if that default changed.
/// - the deep-link schemes: the plugin registers only what this file
///   declares and drops a link in any other scheme before the app sees it.
/// - `version`: the publish job reads the version out of the built CLI and
///   refuses a tag naming another; left to drift, the updater reads the app
///   bundle as current or as older than a release it cannot find.
/// - the updater endpoints: exactly one, the release channel, so an install
///   that stopped overriding it falls back to full releases; a second
///   endpoint the install does not choose is one nothing holds to a channel.
#[test]
fn the_settings_the_window_and_the_release_path_lean_on() {
    let config = config();
    let rows = [
        ("/app/windows/0/visible", serde_json::Value::from(false)),
        ("/app/windows/0/label", serde_json::Value::from("main")),
        (
            "/plugins/deep-link/desktop/schemes",
            serde_json::Value::from(vec![kendex_app::deep_link::SCHEME]),
        ),
        (
            "/version",
            serde_json::Value::from(env!("CARGO_PKG_VERSION")),
        ),
        (
            "/plugins/updater/endpoints",
            serde_json::Value::from(vec![kendex_core::update_channel::RELEASE_MANIFEST_URL]),
        ),
    ];
    for (pointer, expected) in rows {
        assert_eq!(config.pointer(pointer), Some(&expected), "{pointer}");
    }
}

/// The app's updater reads its key from this file at build time, so the
/// copy core holds for `kendex update` can only be kept honest by an
/// assertion. Two keys means one delivery path trusting what the other
/// would turn away — and two identical pins are still the wrong pin if
/// nothing names the key: a pin whose private half exists nowhere would
/// ship with both checks green. So the key id parsed out of the key file's
/// payload — the half minisign verifies with, not the comment above it —
/// is held to the key id the release is signed with as well.
#[test]
#[allow(clippy::expect_used)]
fn the_app_and_the_cli_pin_one_updater_key() {
    assert_eq!(
        config()["plugins"]["updater"]["pubkey"].as_str(),
        Some(kendex_core::update_feed::UPDATER_PUBLIC_KEY)
    );
    let key_file = base64::engine::general_purpose::STANDARD
        .decode(kendex_core::update_feed::UPDATER_PUBLIC_KEY)
        .expect("the pinned key is base64");
    let key_file = String::from_utf8(key_file).expect("the pinned key file is text");
    // Line one is the untrusted comment, which minisign never reads. Line
    // two is the key: two bytes of algorithm, eight of key id little-endian,
    // then the thirty-two a signature is checked against.
    let payload = base64::engine::general_purpose::STANDARD
        .decode(
            key_file
                .lines()
                .nth(1)
                .expect("the pinned key file carries a payload line")
                .trim(),
        )
        .expect("the payload line is base64");
    assert_eq!(payload.len(), 42, "a minisign public key is 42 bytes");
    let key_id: String = payload[2..10]
        .iter()
        .rev()
        .map(|b| format!("{b:02X}"))
        .collect();
    assert_eq!(
        key_id, "C922C89178B7C6CC",
        "the pin carries a key id the release signing key does not"
    );
}
