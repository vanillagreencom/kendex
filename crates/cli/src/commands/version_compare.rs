//! Where one version stands against another under SemVer precedence.
//!
//! Release tooling's read of the ordering: `tools/release-channel-point`
//! decides whether the pre-release channel already carries something newer
//! than the tag being published, and that decision moves every candidate
//! machine. It runs this verb on the binary the release built rather than
//! ordering the two strings itself, so the channel is ordered by the parser
//! the candidates read their feed with — `sort -V` puts `1.0.0-rc10` past
//! `1.0.0-rc2`, where SemVer puts rc10 first, and a channel ordered that
//! way rolls every candidate backwards with nothing on it saying so.

use clap::Args;

use kendex_core::update_feed::{VersionRelation, precedence};

use super::{CliResult, answer};

#[derive(Args)]
pub struct VersionCompareArgs {
    /// The version being placed
    left: String,
    /// The version it is placed against
    right: String,
}

pub fn run(args: VersionCompareArgs) -> CliResult {
    // Named by their side rather than by a role, because neither is the
    // running build: a refusal has to say which of the two strings was not
    // a version.
    let word = match precedence("first", &args.left, "second", &args.right)? {
        VersionRelation::Newer => "newer",
        VersionRelation::Current => "same",
        VersionRelation::Older => "older",
    };
    answer(word);
    Ok(())
}
