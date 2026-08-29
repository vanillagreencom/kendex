//! Which release channel a build follows, and where that channel's two
//! manifests are served from. Reading the feed is `update_feed`'s job;
//! this module only decides which one to read.

use semver::Version;

pub const RELEASE_FEED_URL: &str =
    "https://github.com/vanillagreencom/kendex/releases/latest/download/feed.json";
/// The manifest the app's updater installs a full release from. `latest`
/// is GitHub's own word for the newest release that is neither a draft nor
/// a pre-release, so both release-channel URLs move on their own when a tag
/// is published and neither can ever resolve to a release candidate.
pub const RELEASE_MANIFEST_URL: &str =
    "https://github.com/vanillagreencom/kendex/releases/latest/download/latest.json";
/// The pre-release channel is one fixed release whose two manifests the
/// tag job overwrites every time a pre-release is published. A release
/// candidate has no other way to reach the next one: GitHub resolves
/// `latest` past every pre-release, so the URL above would tell rc1 it is
/// current while rc2 sits published beside it.
pub const PRERELEASE_FEED_URL: &str =
    "https://github.com/vanillagreencom/kendex/releases/download/prerelease/feed.json";
pub const PRERELEASE_MANIFEST_URL: &str =
    "https://github.com/vanillagreencom/kendex/releases/download/prerelease/latest.json";
/// Whether a build takes its updates from the pre-release channel. The
/// running version is the whole answer: a version carrying a SemVer
/// pre-release identifier is itself a release candidate and follows the
/// candidates, and every other version follows full releases. A version
/// this build cannot parse follows full releases too, which is the answer
/// that can only ever offer someone less than they asked for.
///
/// So a shipped 1.0.0 is never offered 1.1.0-rc1, and nothing has to be
/// set on the machine for a candidate to find its successor — which is
/// what makes the release-build test of the update path possible at all.
fn on_prerelease_channel(current_version: &str) -> bool {
    Version::parse(current_version).is_ok_and(|version| !version.pre.is_empty())
}

/// The discovery feed `current_version` reads. Both shells call this with
/// their own baked version rather than deciding for themselves, so the app
/// and `kendex update` cannot end up on different channels.
pub fn feed_url_for(current_version: &str) -> &'static str {
    match on_prerelease_channel(current_version) {
        true => PRERELEASE_FEED_URL,
        false => RELEASE_FEED_URL,
    }
}

/// The signed manifest `current_version` installs the desktop app from,
/// chosen by the same rule as the feed above.
pub fn manifest_url_for(current_version: &str) -> &'static str {
    match on_prerelease_channel(current_version) {
        true => PRERELEASE_MANIFEST_URL,
        false => RELEASE_MANIFEST_URL,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The rule the whole pre-release test path rests on, read from both
    /// ends: a candidate follows candidates, and a shipped release never
    /// does. Getting the second half wrong ships 1.0.0 taking 1.1.0-rc1,
    /// which is the one outcome this channel must not have.
    #[test]
    fn a_candidate_follows_candidates_and_a_full_release_never_does() {
        for candidate in ["1.0.0-rc1", "1.0.0-rc2", "5.1.0-beta.1", "1.0.0-rc1+build"] {
            assert_eq!(feed_url_for(candidate), PRERELEASE_FEED_URL, "{candidate}");
            assert_eq!(
                manifest_url_for(candidate),
                PRERELEASE_MANIFEST_URL,
                "{candidate}"
            );
        }
        // The last two are versions no build carries; a value that is not
        // SemVer resolves to the release channel rather than to nothing.
        for full in ["1.0.0", "5.0.1", "5.0.1+feed", "", "not a version"] {
            assert_eq!(feed_url_for(full), RELEASE_FEED_URL, "{full}");
            assert_eq!(manifest_url_for(full), RELEASE_MANIFEST_URL, "{full}");
        }
    }

    /// A candidate reaches its successor only because the two channels are
    /// served from different places: the release channel's `latest` is
    /// resolved by GitHub past every pre-release, so a candidate pointed at
    /// it would read the last full release and call itself current.
    #[test]
    fn the_two_channels_are_not_the_same_url() {
        assert_ne!(RELEASE_FEED_URL, PRERELEASE_FEED_URL);
        assert_ne!(RELEASE_MANIFEST_URL, PRERELEASE_MANIFEST_URL);
        for url in [PRERELEASE_FEED_URL, PRERELEASE_MANIFEST_URL] {
            assert!(!url.contains("/releases/latest/"), "{url}");
        }
    }
}
