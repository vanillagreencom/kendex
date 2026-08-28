//! Strict parsing and version comparison for the public release feed.

use std::cmp::Ordering;
use std::collections::BTreeMap;

use semver::Version;
use serde::{Deserialize, Serialize};

use crate::error::{CoreError, Result};

pub const FEED_SCHEMA: u32 = 1;
pub const MAX_FEED_BYTES: usize = 64 * 1024;
pub const RELEASE_FEED_URL: &str =
    "https://github.com/vanillagreencom/kendex/releases/latest/download/feed.json";
const MAX_VERSION_BYTES: usize = 128;
const MAX_ASSETS: usize = 32;
const MAX_TARGET_BYTES: usize = 128;
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

/// How a feed version relates to the running build under SemVer precedence.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VersionRelation {
    Older,
    Current,
    Newer,
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
        let latest = parse_version("feed", &self.version)?;
        let current = parse_version("running build", current)?;
        Ok(match latest.cmp_precedence(&current) {
            Ordering::Less => VersionRelation::Older,
            Ordering::Equal => VersionRelation::Current,
            Ordering::Greater => VersionRelation::Newer,
        })
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

fn parse_version(source: &str, value: &str) -> Result<Version> {
    Version::parse(value).map_err(|error| CoreError::UpdateFeedMalformed {
        why: format!("{source} version '{value}' is not SemVer: {error}"),
    })
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

    #[test]
    fn compares_semver_precedence_not_text_or_build_metadata() {
        assert_eq!(
            ReleaseFeed::parse(&feed("5.10.0"))
                .unwrap()
                .relation_to("5.9.0")
                .unwrap(),
            VersionRelation::Newer
        );
        assert_eq!(
            ReleaseFeed::parse(&feed("5.0.1+feed"))
                .unwrap()
                .relation_to("5.0.1+local")
                .unwrap(),
            VersionRelation::Current
        );
        assert_eq!(
            ReleaseFeed::parse(&feed("5.0.0"))
                .unwrap()
                .relation_to("5.0.1")
                .unwrap(),
            VersionRelation::Older
        );
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
