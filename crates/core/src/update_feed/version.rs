//! Where one version stands against another, and the one parser that
//! decides it.
//!
//! Its own file because it has two callers with nothing else in common: a
//! feed read comparing what a channel offers against the running build, and
//! the release tooling's `kendex version-compare`, which orders two strings
//! neither of which is this build. What they share is the ordering, and the
//! ordering has to be one implementation — a second one that reads
//! `1.0.0-rc10` as past `1.0.0-rc2` sends every candidate machine backwards,
//! and nothing on the channel would say the two halves had disagreed.

use std::cmp::Ordering;

use semver::Version;

use crate::error::{CoreError, Result};

/// How one version relates to another under SemVer precedence.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VersionRelation {
    Older,
    Current,
    Newer,
}

/// SemVer precedence: the numeric core, then a release ranking above the
/// pre-releases leading to it, then the pre-release identifiers, with build
/// metadata out of the comparison entirely.
///
/// Each side is named so a refusal says which string was not a version, and
/// the reason comes back as text rather than as a feed error: only one of
/// the two callers is about a feed.
pub fn precedence(
    left_source: &str,
    left: &str,
    right_source: &str,
    right: &str,
) -> std::result::Result<VersionRelation, String> {
    let left = read_version(left_source, left)?;
    let right = read_version(right_source, right)?;
    Ok(match left.cmp_precedence(&right) {
        Ordering::Less => VersionRelation::Older,
        Ordering::Equal => VersionRelation::Current,
        Ordering::Greater => VersionRelation::Newer,
    })
}

fn read_version(source: &str, value: &str) -> std::result::Result<Version, String> {
    Version::parse(value)
        .map_err(|error| format!("{source} version '{value}' is not SemVer: {error}"))
}

/// The same read, worded as the feed's own refusal for the parsing paths
/// that are about a feed.
pub(super) fn parse_version(source: &str, value: &str) -> Result<Version> {
    read_version(source, value).map_err(|why| CoreError::UpdateFeedMalformed { why })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The rule `sort -V` and every hand-written regex get wrong, and the
    /// one the pre-release channel is ordered by: an all-alphanumeric
    /// pre-release identifier compares as text, so rc10 comes before rc2,
    /// and build metadata is not part of the version at all.
    #[test]
    fn precedence_is_semver_and_not_text_or_build_metadata() {
        for (left, right, relation) in [
            ("5.10.0", "5.9.0", VersionRelation::Newer),
            ("1.0.0-rc10", "1.0.0-rc2", VersionRelation::Older),
            ("1.0.0-rc2", "1.0.0", VersionRelation::Older),
            ("1.0.0+feed", "1.0.0+local", VersionRelation::Current),
            ("1.0.0-alpha.1", "1.0.0-alpha.1", VersionRelation::Current),
        ] {
            assert_eq!(
                precedence("first", left, "second", right),
                Ok(relation),
                "{left} against {right}"
            );
        }
    }

    /// A string that is not a version has no place in the ordering, and the
    /// refusal names which of the two it was.
    #[test]
    fn a_string_that_is_not_a_version_is_not_ordered() {
        let refused = precedence("first", "01.0.0", "second", "1.0.0").unwrap_err();
        assert!(refused.starts_with("first version '01.0.0'"), "{refused}");
        let refused = precedence("first", "1.0.0", "second", "1.0").unwrap_err();
        assert!(refused.starts_with("second version '1.0'"), "{refused}");
    }
}
