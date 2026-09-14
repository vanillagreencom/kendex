//! Which release channel a build follows and how rolling-main identities
//! are ordered.

use semver::Version;
use serde::{Deserialize, Serialize};

pub const RELEASE_FEED_URL: &str =
    "https://github.com/vanillagreencom/kendex/releases/latest/download/feed.json";
pub const RELEASE_MANIFEST_URL: &str =
    "https://github.com/vanillagreencom/kendex/releases/latest/download/latest.json";
pub const PRERELEASE_FEED_URL: &str =
    "https://github.com/vanillagreencom/kendex/releases/download/prerelease/feed.json";
pub const PRERELEASE_MANIFEST_URL: &str =
    "https://github.com/vanillagreencom/kendex/releases/download/prerelease/latest.json";
/// The Git tag behind the rolling pre-release named `main`. It differs from
/// the branch name so Git never has to resolve an ambiguous `main` ref.
pub const MAIN_RELEASE_TAG: &str = "rolling-main";
pub const MAIN_FEED_URL: &str =
    "https://github.com/vanillagreencom/kendex/releases/download/rolling-main/feed.json";
pub const MAIN_MANIFEST_URL: &str =
    "https://github.com/vanillagreencom/kendex/releases/download/rolling-main/latest.json";

/// The update stream selected by a build or by an explicit CLI request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum UpdateChannel {
    Release,
    Prerelease,
    Main,
}

impl UpdateChannel {
    /// Select the stream a displayed build version belongs to.
    pub fn for_version(version: &str) -> Self {
        if main_version_identity(version).is_some() {
            Self::Main
        } else if Version::parse(version).is_ok_and(|parsed| !parsed.pre.is_empty()) {
            Self::Prerelease
        } else {
            Self::Release
        }
    }

    /// Select the stream for a CLI update. `--git` is the explicit main
    /// exception for a tagged build.
    pub fn for_request(version: &str, git: bool) -> Self {
        if git {
            Self::Main
        } else {
            Self::for_version(version)
        }
    }

    pub fn feed_url(self) -> &'static str {
        match self {
            Self::Release => RELEASE_FEED_URL,
            Self::Prerelease => PRERELEASE_FEED_URL,
            Self::Main => MAIN_FEED_URL,
        }
    }

    pub fn manifest_url(self) -> &'static str {
        match self {
            Self::Release => RELEASE_MANIFEST_URL,
            Self::Prerelease => PRERELEASE_MANIFEST_URL,
            Self::Main => MAIN_MANIFEST_URL,
        }
    }

    pub fn release_notes_url(self, version: &str) -> crate::error::Result<String> {
        match self {
            Self::Main => Ok(format!(
                "https://github.com/vanillagreencom/kendex/releases/tag/{MAIN_RELEASE_TAG}"
            )),
            Self::Release | Self::Prerelease => crate::update_feed::release_notes_url(version),
        }
    }

    pub fn record_name(self) -> &'static str {
        match self {
            Self::Release => "release",
            Self::Prerelease => "prerelease",
            Self::Main => "main",
        }
    }

    pub fn from_record_name(name: &str) -> Option<Self> {
        match name {
            "release" => Some(Self::Release),
            "prerelease" => Some(Self::Prerelease),
            "main" => Some(Self::Main),
            _ => None,
        }
    }
}

/// One rolling build identity. GitHub's workflow run number orders builds;
/// the commit identifies the exact source used for that build.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MainIdentity<'a> {
    pub build: u64,
    pub commit: &'a str,
}

/// Parse the identity suffix from a rolling build version. Package build
/// metadata can precede the suffix, so a package version that already has
/// metadata remains valid SemVer.
pub fn main_version_identity(version: &str) -> Option<MainIdentity<'_>> {
    Version::parse(version).ok()?;
    let (_, metadata) = version.split_once('+')?;
    let (prefix, commit) = metadata.rsplit_once('.')?;
    let (prefix, build) = prefix.rsplit_once('.')?;
    if prefix != "main" && !prefix.ends_with(".main") {
        return None;
    }
    let build = build.parse().ok()?;
    valid_commit(commit).then_some(MainIdentity { build, commit })
}

pub fn valid_commit(commit: &str) -> bool {
    commit.len() == 40
        && commit
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// The feed a run reads. Debug builds may replace the URL with a fixture;
/// release builds always use the selected channel.
pub fn selected_feed(channel: UpdateChannel, override_url: Option<String>, debug: bool) -> String {
    match (debug, override_url) {
        (true, Some(url)) => url,
        (true, None) | (false, _) => channel.feed_url().to_owned(),
    }
}

pub fn feed_url(channel: UpdateChannel) -> String {
    #[cfg(debug_assertions)]
    {
        selected_feed(channel, std::env::var("KENDEX_UPDATE_FEED").ok(), true)
    }
    #[cfg(not(debug_assertions))]
    {
        selected_feed(channel, None, false)
    }
}

/// Whether an offered rolling build is newer than the running build.
pub fn main_update_is_newer(running: MainIdentity<'_>, offered_version: &str) -> bool {
    main_version_identity(offered_version).is_some_and(|offered| offered.build > running.build)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_debug_builds_accept_a_feed_override() {
        let fixture = "file:///fixtures/feed.json".to_owned();
        assert_eq!(
            selected_feed(UpdateChannel::Release, Some(fixture.clone()), true),
            fixture
        );
        assert_eq!(
            selected_feed(UpdateChannel::Release, Some(fixture.clone()), false),
            RELEASE_FEED_URL
        );
        assert_eq!(
            selected_feed(UpdateChannel::Prerelease, Some(fixture.clone()), false),
            PRERELEASE_FEED_URL
        );
        assert_eq!(
            selected_feed(UpdateChannel::Main, Some(fixture), false),
            MAIN_FEED_URL
        );
    }

    #[test]
    fn versions_select_one_channel() {
        for candidate in ["1.0.0-rc1", "1.0.0-rc2", "5.1.0-beta.1"] {
            assert_eq!(
                UpdateChannel::for_version(candidate),
                UpdateChannel::Prerelease
            );
        }
        for full in ["1.0.0", "5.0.1+feed", "", "not a version"] {
            assert_eq!(UpdateChannel::for_version(full), UpdateChannel::Release);
        }
        assert_eq!(
            UpdateChannel::for_version(
                "5.0.1+vendor.7.main.12.0123456789abcdef0123456789abcdef01234567"
            ),
            UpdateChannel::Main
        );
        assert_eq!(
            UpdateChannel::for_request("5.0.1", true),
            UpdateChannel::Main
        );
    }

    #[test]
    fn a_main_identity_is_ordered_by_its_monotonic_build() {
        let commit = "0123456789abcdef0123456789abcdef01234567";
        let running = MainIdentity { build: 12, commit };
        assert!(!main_update_is_newer(
            running,
            &format!("5.0.1+main.11.{commit}")
        ));
        assert!(!main_update_is_newer(
            running,
            &format!("5.0.1+main.12.{commit}")
        ));
        assert!(main_update_is_newer(
            running,
            "5.0.1+main.13.89abcdef0123456789abcdef0123456789abcdef"
        ));
    }

    #[test]
    fn existing_build_metadata_stays_part_of_a_main_identity() {
        let commit = "0123456789abcdef0123456789abcdef01234567";
        assert_eq!(
            main_version_identity(&format!("5.0.1+vendor.7.main.12.{commit}")),
            Some(MainIdentity { build: 12, commit })
        );
        for version in [
            "5.0.1",
            "5.0.1+main.12.short",
            "5.0.1+other.12.0123456789abcdef0123456789abcdef01234567",
        ] {
            assert_eq!(main_version_identity(version), None, "{version}");
        }
    }
}
