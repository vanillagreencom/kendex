//! Strict parsing and version comparison for the public release feed, and
//! the pinned key the desktop app download is verified under.

use std::collections::BTreeMap;

use base64::Engine;
use minisign_verify::{PublicKey, Signature};
use serde::{Deserialize, Serialize};

use crate::error::{CoreError, Result};
use crate::release_digests::MAX_TARGET_BYTES;

mod version;
use version::parse_version;
pub use version::{VersionRelation, precedence};

pub const FEED_SCHEMA: u32 = 1;
pub const MAX_FEED_BYTES: usize = 64 * 1024;
/// The minisign public key every kendex release is signed under, in the
/// base64 shape `crates/app/tauri.conf.json` pins for the app's own
/// updater. `crates/app/tests/tauri_config.rs` holds the two to one string,
/// so the CLI and the app cannot end up trusting different keys.
pub const UPDATER_PUBLIC_KEY: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IEJENUIwQjkxMUFGNTJFOTIKUldTU0x2VWFrUXRidmJFQnhKSi9iU3pwTVVJVlhrY3JHbVoyV1BjVmJSdDYzZ2VjVnZzSjlEMDkK";
const MAX_VERSION_BYTES: usize = 128;
const MAX_ASSETS: usize = 32;
const MAX_URL_BYTES: usize = 2 * 1024;

/// One additive generation of the release feed. Unknown fields remain
/// readable within a schema version so publishers can add data without
/// breaking older clients.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReleaseFeed {
    /// An absent value is the pre-versioned schema 1 shape.
    #[serde(default = "default_feed_schema")]
    pub schema: u32,
    pub version: String,
    pub assets: BTreeMap<String, String>,
}

fn default_feed_schema() -> u32 {
    FEED_SCHEMA
}

impl ReleaseFeed {
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        if bytes.len() > MAX_FEED_BYTES {
            return malformed(format!(
                "the body is {} bytes; the limit is {MAX_FEED_BYTES}",
                bytes.len()
            ));
        }
        let feed: ReleaseFeed =
            serde_json::from_slice(bytes).map_err(|error| CoreError::UpdateFeedMalformed {
                why: error.to_string(),
            })?;
        feed.validate()?;
        Ok(feed)
    }

    pub fn relation_to(&self, current: &str) -> Result<VersionRelation> {
        precedence("feed", &self.version, "running build", current)
            .map_err(|why| CoreError::UpdateFeedMalformed { why })
    }

    pub fn asset_for(&self, target: &str) -> Option<&str> {
        self.assets.get(target).map(String::as_str)
    }

    fn validate(&self) -> Result<()> {
        if self.schema != FEED_SCHEMA {
            return malformed(format!(
                "schema {} is not supported; this build reads schema {FEED_SCHEMA}",
                self.schema
            ));
        }
        if self.version.len() > MAX_VERSION_BYTES {
            return malformed(format!(
                "version is {} bytes; the limit is {MAX_VERSION_BYTES}",
                self.version.len()
            ));
        }
        parse_version("feed", &self.version)?;
        if self.assets.len() > MAX_ASSETS {
            return malformed(format!(
                "assets has {} entries; the limit is {MAX_ASSETS}",
                self.assets.len()
            ));
        }
        for (target, url) in &self.assets {
            if target.is_empty() || target.len() > MAX_TARGET_BYTES {
                return malformed(format!(
                    "an asset target has {} bytes; the range is 1..={MAX_TARGET_BYTES}",
                    target.len()
                ));
            }
            if url.is_empty() || url.len() > MAX_URL_BYTES {
                return malformed(format!(
                    "asset '{target}' has a URL of {} bytes; the range is 1..={MAX_URL_BYTES}",
                    url.len()
                ));
            }
            if !url.starts_with("https://") && !url.starts_with("file://") {
                return malformed(format!(
                    "asset '{target}' URL must start with https:// or file://"
                ));
            }
        }
        Ok(())
    }
}

pub fn release_notes_url(version: &str) -> Result<String> {
    parse_version("feed", version)?;
    Ok(format!(
        "https://github.com/vanillagreencom/kendex/releases/tag/v{version}"
    ))
}

/// The release download for the Linux desktop AppImage, named the way
/// `install.sh` names it. Both halves come from values this build owns: a
/// version that parsed as SemVer, and a target triple the release builds.
/// Targets without an AppImage have none.
pub fn app_image_url(version: &str, target: &str) -> Result<Option<String>> {
    parse_version("feed", version)?;
    // Tauri names AppImages with Debian arch words, not the Rust triple.
    let arch = match target {
        "x86_64-unknown-linux-gnu" => "amd64",
        "aarch64-unknown-linux-gnu" => "aarch64",
        _ => return Ok(None),
    };
    Ok(Some(format!(
        "https://github.com/vanillagreencom/kendex/releases/download/v{version}/kendex_{version}_{arch}.AppImage"
    )))
}

/// The minisign signature published beside a release artifact. The release
/// job publishes each `<artifact>.sig`, so the name is the artifact's own
/// with the suffix appended; both halves of an update find theirs this way.
pub fn signature_url(artifact_url: &str) -> String {
    format!("{artifact_url}.sig")
}

/// The signature published beside that AppImage.
pub fn app_image_signature_url(version: &str, target: &str) -> Result<Option<String>> {
    Ok(app_image_url(version, target)?.map(|url| signature_url(&url)))
}

/// Refuse a download that `signature` does not cover under
/// `public_key_base64`. Both are base64 over a minisign file, the shape
/// `tauri.conf.json` pins its key in and the release job publishes each
/// `<artifact>.sig` in. Callers installing a release pass
/// `UPDATER_PUBLIC_KEY`; the key is an argument so a test can hold a
/// signature it made itself.
pub fn verify_signature(public_key_base64: &str, data: &[u8], signature: &[u8]) -> Result<()> {
    let key_text = decode_base64("the public key", public_key_base64.as_bytes())?;
    let key = PublicKey::decode(&key_text)
        .map_err(|error| refused(format!("the public key is not minisign: {error}")))?;
    let signature_text = decode_base64("the signature", signature)?;
    let signature = Signature::decode(&signature_text)
        .map_err(|error| refused(format!("the signature is not minisign: {error}")))?;
    // Legacy signatures are accepted because the app's updater accepts them
    // under this same key: tauri-plugin-updater 2.10.1 src/updater.rs:1461
    // passes true here. A narrower rule would put one artifact behind two
    // bars again, which is what sharing the key avoids.
    key.verify(data, &signature, true)
        .map_err(|error| refused(error.to_string()))
}

fn decode_base64(what: &str, value: &[u8]) -> Result<String> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(value)
        .map_err(|error| refused(format!("{what} is not base64: {error}")))?;
    String::from_utf8(bytes).map_err(|error| refused(format!("{what} is not text: {error}")))
}

fn refused(why: String) -> CoreError {
    CoreError::UpdateSignatureRefused { why }
}

fn malformed<T>(why: String) -> Result<T> {
    Err(CoreError::UpdateFeedMalformed { why })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed(version: &str) -> Vec<u8> {
        format!(
            r#"{{"schema":1,"version":"{version}","assets":{{"x86_64-unknown-linux-gnu":"https://example.test/kendex"}},"future":true}}"#
        )
        .into_bytes()
    }

    fn parse_assets(assets: BTreeMap<String, String>) -> Result<ReleaseFeed> {
        let body = serde_json::to_vec(&ReleaseFeed {
            schema: FEED_SCHEMA,
            version: "5.1.0".to_owned(),
            assets,
        })
        .unwrap();
        ReleaseFeed::parse(&body)
    }

    /// A throwaway minisign keypair signing `SIGNED_IMAGE`, generated once
    /// so the good case is a real signature rather than a stub. Both values
    /// are base64 over the key and signature files, the shape
    /// `tauri.conf.json` and a published `.sig` carry.
    const TEST_KEY: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IDk0QUI0NzI3RTVDMTVCODEKUldTQlc4SGxKMGVybEhxeFovbTJ3U1phMng4aE9VTXByV09pUVRFVFNKbFZ5aWxtUTAvVGgyWEwK";
    const TEST_SIGNATURE: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHJzaWduIHNlY3JldCBrZXkKUlVTQlc4SGxKMGVybElTMUxrbkMyQ0tBWGlnejY1S0xLekovK0tBYllNdkdJTVU0bitTSjRBSCt1RlpwWnZkRHNKcWFTSHVoeStIQkpyVDlOaVRIMmROWVVSb21mMVBVRmd3PQp0cnVzdGVkIGNvbW1lbnQ6IGtlbmRleCB0ZXN0CnpKSnpYYnBtODZYRW40eHgxSTVkeG5YdktxT0k5ZXdmSkEyMkdtZXpreGgwbUNJZysybkJ2cGowUXZ6N2c3RHA4TEZBVXVBQUVMRExuUzFuaVpsaUF3PT0K";
    const SIGNED_IMAGE: &[u8] = b"kendex AppImage bytes";

    #[test]
    fn a_signature_over_these_bytes_verifies_and_one_over_any_other_does_not() {
        assert!(verify_signature(TEST_KEY, SIGNED_IMAGE, TEST_SIGNATURE.as_bytes()).is_ok());
        assert!(
            verify_signature(TEST_KEY, b"tampered AppImage", TEST_SIGNATURE.as_bytes()).is_err()
        );
    }

    /// Everything that is not a signature file is refused too, the empty
    /// body a served error page or a missing `.sig` leaves included.
    #[test]
    fn a_signature_that_is_absent_or_malformed_is_refused() {
        for body in [b"".as_slice(), b"not base64 !!", TEST_KEY.as_bytes()] {
            assert!(verify_signature(TEST_KEY, SIGNED_IMAGE, body).is_err());
        }
    }

    /// A download is held to the pinned key and no other: a signature made
    /// under a different one is turned away for that, and not for a key
    /// this build could not read in the first place.
    #[test]
    fn the_pinned_key_is_the_one_a_download_is_held_to() {
        let error = verify_signature(UPDATER_PUBLIC_KEY, SIGNED_IMAGE, TEST_SIGNATURE.as_bytes())
            .unwrap_err()
            .to_string();
        assert!(error.contains("created with a different key"), "{error}");
    }

    #[test]
    fn parses_the_versioned_additive_shape() {
        let parsed = ReleaseFeed::parse(&feed("5.1.0")).unwrap();
        assert_eq!(parsed.schema, FEED_SCHEMA);
        assert_eq!(parsed.version, "5.1.0");
    }

    #[test]
    fn parses_the_live_legacy_shape_as_schema_one() {
        let legacy = br#"{"version":"5.0.1","assets":{"x86_64-unknown-linux-gnu":"https://example.test/kendex"}}"#;
        let parsed = ReleaseFeed::parse(legacy).unwrap();
        assert_eq!(parsed.schema, FEED_SCHEMA);
        assert_eq!(parsed.version, "5.0.1");
    }

    #[test]
    fn refuses_unknown_schema_invalid_semver_and_oversized_body() {
        let unknown = br#"{"schema":2,"version":"5.1.0","assets":{}}"#;
        assert!(ReleaseFeed::parse(unknown).is_err());
        assert!(ReleaseFeed::parse(&feed("five.one")).is_err());
        assert!(ReleaseFeed::parse(&vec![b' '; MAX_FEED_BYTES + 1]).is_err());
    }

    /// The wiring, not the ordering: which of the two strings is the feed's
    /// and which is the running build's. `version`'s own tests hold the
    /// SemVer rules — asked twice, one copy would go on passing while the
    /// sides were the wrong way round.
    #[test]
    fn the_relation_reads_the_feed_against_the_running_build() {
        for (published, running, relation) in [
            ("5.10.0", "5.9.0", VersionRelation::Newer),
            ("5.9.0", "5.10.0", VersionRelation::Older),
            ("5.9.0", "5.9.0", VersionRelation::Current),
        ] {
            assert_eq!(
                ReleaseFeed::parse(&feed(published))
                    .unwrap()
                    .relation_to(running)
                    .unwrap(),
                relation,
                "feed {published} against a running {running}"
            );
        }
        assert!(
            ReleaseFeed::parse(&feed("5.9.0"))
                .unwrap()
                .relation_to("not a version")
                .is_err()
        );
    }

    #[test]
    fn the_signature_url_is_the_app_image_url_with_the_published_suffix() {
        assert_eq!(
            app_image_signature_url("5.1.0", "x86_64-unknown-linux-gnu").unwrap(),
            Some(
                "https://github.com/vanillagreencom/kendex/releases/download/v5.1.0/kendex_5.1.0_amd64.AppImage.sig"
                    .to_owned()
            )
        );
        assert_eq!(
            app_image_signature_url("5.1.0", "aarch64-apple-darwin").unwrap(),
            None
        );
        // The command binary the feed names finds its own by the same rule.
        assert_eq!(signature_url("https://x/kendex"), "https://x/kendex.sig");
    }

    #[test]
    fn the_app_image_url_is_built_only_from_a_semver_version_and_a_known_target() {
        assert_eq!(
            app_image_url("5.1.0", "x86_64-unknown-linux-gnu").unwrap(),
            Some(
                "https://github.com/vanillagreencom/kendex/releases/download/v5.1.0/kendex_5.1.0_amd64.AppImage"
                    .to_owned()
            )
        );
        assert_eq!(
            app_image_url("5.1.0", "aarch64-apple-darwin").unwrap(),
            None
        );
        assert!(app_image_url("5.1.0 ; rm -rf /", "x86_64-unknown-linux-gnu").is_err());
    }

    #[test]
    fn asset_count_accepts_the_limit_and_refuses_one_more() {
        let assets = |count| {
            (0..count)
                .map(|n| (format!("target-{n}"), format!("https://example.test/{n}")))
                .collect()
        };
        assert!(parse_assets(assets(MAX_ASSETS)).is_ok());
        assert!(parse_assets(assets(MAX_ASSETS + 1)).is_err());
    }

    #[test]
    fn asset_target_accepts_exact_bounds_and_refuses_outside_them() {
        let one =
            |target: String| BTreeMap::from([(target, "https://example.test/kendex".to_owned())]);
        assert!(parse_assets(one("t".repeat(MAX_TARGET_BYTES))).is_ok());
        assert!(parse_assets(one(String::new())).is_err());
        assert!(parse_assets(one("t".repeat(MAX_TARGET_BYTES + 1))).is_err());
    }

    #[test]
    fn asset_url_accepts_exact_bounds_and_supported_schemes() {
        let one = |url: String| BTreeMap::from([("target".to_owned(), url)]);
        let longest = format!("https://{}", "a".repeat(MAX_URL_BYTES - "https://".len()));
        assert!(parse_assets(one(longest.clone())).is_ok());
        assert!(parse_assets(one(format!("{longest}a"))).is_err());
        assert!(parse_assets(one("file:///fixture/kendex".to_owned())).is_ok());
        for refused in ["", "--output=/tmp/x", "http://example.test/x", "ftp://x"] {
            assert!(parse_assets(one(refused.to_owned())).is_err(), "{refused}");
        }
    }
}
