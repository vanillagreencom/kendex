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

/// The feed a run reads, given the override it was handed. A debug build
/// honors it so a suite can point a run at a local fixture; a release build
/// takes the channel's own URL and nothing else, because the feed names the
/// bytes that replace the running install and an override would let anything
/// that can set a variable name them instead.
///
/// One definition for both shells. The rule is the same on each, and two
/// copies of it is one copy that can be relaxed on its own — the copy that
/// honours an override in a release build is the whole of the attack.
pub fn selected_feed(current_version: &str, override_url: Option<String>, debug: bool) -> String {
    match (debug, override_url) {
        (true, Some(url)) => url,
        (true, None) | (false, _) => feed_url_for(current_version).to_owned(),
    }
}

/// The feed this build reads: [`selected_feed`] with the override a debug
/// build is allowed to read off the environment, and none otherwise.
pub fn feed_url(current_version: &str) -> String {
    #[cfg(debug_assertions)]
    {
        selected_feed(
            current_version,
            std::env::var("KENDEX_UPDATE_FEED").ok(),
            true,
        )
    }
    #[cfg(not(debug_assertions))]
    {
        selected_feed(current_version, None, false)
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

    /// A release build takes the channel's own feed and nothing else: an
    /// override there names the bytes that replace a running install, and
    /// both shells read this one rule.
    #[test]
    fn only_debug_builds_accept_a_feed_override() {
        let fixture = "file:///fixtures/feed.json".to_owned();
        assert_eq!(selected_feed("1.0.0", Some(fixture.clone()), true), fixture);
        assert_eq!(
            selected_feed("1.0.0", Some(fixture.clone()), false),
            RELEASE_FEED_URL
        );
        assert_eq!(
            selected_feed("1.0.0-rc1", Some(fixture), false),
            PRERELEASE_FEED_URL
        );
    }

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
