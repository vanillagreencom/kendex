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
/// would turn away — and two identical pins are still the wrong pin if
/// nothing names the key, which is how a pin whose private half exists
/// nowhere shipped. So the key id parsed out of the key file's payload —
/// the half minisign verifies with, not the comment above it — is held to
/// the key id the release is signed with as well.
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

/// The app bundle and the CLI carry their versions in different files, and
/// the release is held to one of them: the publish job reads the version
/// back out of the built CLI and refuses a tag that names another. Left to
/// drift, a tag matching the CLI would ship an app bundle of some other
/// version, which the updater then reads as already current or as older
/// than a release it cannot find.
#[test]
fn the_app_and_the_cli_ship_one_version() {
    assert_eq!(
        config()["version"].as_str(),
        Some(env!("CARGO_PKG_VERSION"))
    );
}

/// The plugin needs a configured endpoint, and the install hands it core's
/// choice on top. The configured one is the release channel, so an install
/// that ever stopped overriding it falls back to full releases rather than
/// to whatever a stale edit left here — and a build that is not a release
/// candidate finds the two already equal.
#[test]
fn the_configured_endpoint_is_the_release_channel() {
    assert_eq!(
        config()["plugins"]["updater"]["endpoints"][0].as_str(),
        Some(kendex_core::update_channel::RELEASE_MANIFEST_URL)
    );
    assert_eq!(
        config()["plugins"]["updater"]["endpoints"]
            .as_array()
            .map(Vec::len),
        Some(1),
        "a second endpoint the install does not choose is one nothing holds to a channel"
    );
}
