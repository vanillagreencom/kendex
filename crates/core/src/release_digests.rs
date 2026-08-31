//! What a release published for one target, as a statement the release key
//! covers.
//!
//! A signature over a download proves the bytes and nothing else: not the
//! version they are, not the target they were built for, not the asset they
//! were named as. Nothing signs the feed that names them, so a feed that
//! can be served or altered can advertise the current release while
//! pointing this target at an older, legitimately signed kendex binary, or
//! at another platform's. Both verify, because both signatures are real.
//!
//! Each release lane therefore publishes `digests-<target>.json` beside its
//! manifests and signs it under the same key: the version, the target, and
//! the SHA-256 of each download built for it, in one document
//! (`tools/release-digests`). An update reads it from the channel it read
//! the feed from, holds it to the release and target it asked for, and
//! installs nothing whose hash is not the one named there. A genuine
//! signature over the wrong artifact no longer passes.

use sha2::{Digest, Sha256};

use crate::error::{CoreError, Result};
use crate::hash::hex;
use crate::update_feed::verify_signature;

pub const DIGESTS_SCHEMA: u32 = 1;
/// Five fixed fields; anything near this is not a document a lane wrote.
pub const MAX_DIGESTS_BYTES: usize = 4 * 1024;
/// SHA-256 in lowercase hex, the shape `sha256sum` prints.
const DIGEST_CHARS: usize = 64;
/// A target triple is the widest name a lane carries; nothing longer is one.
/// The feed's asset keys are the same names, and read it from here.
pub(crate) const MAX_TARGET_BYTES: usize = 128;

/// One release lane's signed statement. Unknown fields stay readable within
/// a schema version, the way the feed's do, so a lane can add data without
/// breaking clients already in the field.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ReleaseDigests {
    /// An absent value is the pre-versioned schema 1 shape.
    #[serde(default = "default_schema")]
    pub schema: u32,
    pub version: String,
    pub target: String,
    /// The kendex command binary this lane staged.
    pub command: String,
    /// The app download this lane bundled: the AppImage on Linux, the app
    /// archive on macOS, the installer on Windows.
    pub app: String,
}

fn default_schema() -> u32 {
    DIGESTS_SCHEMA
}

impl ReleaseDigests {
    /// The statement `version` published for `target`, read only once
    /// `signature` covers `bytes` under `public_key_base64` and the
    /// document says it is that release and that target.
    ///
    /// Both halves matter. The signature makes the document the release's
    /// own; the two comparisons make it *this* release's, so replaying an
    /// older release's genuinely signed statement — or another target's —
    /// is refused rather than silently answering for the one asked for.
    /// The key is an argument for the same reason `verify_signature`'s is:
    /// a test holds a signature it made itself.
    pub fn for_release(
        public_key_base64: &str,
        bytes: &[u8],
        signature: &[u8],
        version: &str,
        target: &str,
    ) -> Result<Self> {
        if bytes.len() > MAX_DIGESTS_BYTES {
            return malformed(format!(
                "the release digests are {} bytes; the limit is {MAX_DIGESTS_BYTES}",
                bytes.len()
            ));
        }
        verify_signature(public_key_base64, bytes, signature)?;
        let digests: Self =
            serde_json::from_slice(bytes).map_err(|error| CoreError::UpdateFeedMalformed {
                why: format!("the release digests are not readable: {error}"),
            })?;
        digests.validate()?;
        if digests.version != version {
            return malformed(format!(
                "the feed offers {version} and the digests served for it are {}'s",
                digests.version
            ));
        }
        if digests.target != target {
            return malformed(format!(
                "the release digests for {target} were served the ones for {}",
                digests.target
            ));
        }
        Ok(digests)
    }

    /// Refuse a command binary the release did not publish for this target.
    pub fn verify_command(&self, bytes: &[u8]) -> Result<()> {
        verify_digest("the kendex command", &self.command, bytes)
    }

    /// Refuse an app download the release did not publish for this target.
    pub fn verify_app(&self, bytes: &[u8]) -> Result<()> {
        verify_digest("the desktop app download", &self.app, bytes)
    }

    fn validate(&self) -> Result<()> {
        if self.schema != DIGESTS_SCHEMA {
            return malformed(format!(
                "release digests schema {} is not supported; this build reads schema {DIGESTS_SCHEMA}",
                self.schema
            ));
        }
        if self.target.is_empty() || self.target.len() > MAX_TARGET_BYTES {
            return malformed(format!(
                "the release digests name a target of {} bytes; the range is 1..={MAX_TARGET_BYTES}",
                self.target.len()
            ));
        }
        // A field that is not a digest could never equal one, so it would
        // refuse every download rather than admit a wrong one. It is still
        // a malformed document and says so here, instead of arriving later
        // as a mismatch against bytes that were fine.
        for (what, digest) in [("command", &self.command), ("app", &self.app)] {
            if digest.len() != DIGEST_CHARS || !digest.bytes().all(|b| b.is_ascii_hexdigit()) {
                return malformed(format!(
                    "the release digest for the {what} is not {DIGEST_CHARS} hex characters"
                ));
            }
        }
        Ok(())
    }
}

/// Where a channel publishes the digests for `target`: beside the manifest
/// that channel serves, under the name only that target's lane writes.
/// Derived from the manifest URL rather than taken from the manifest, so
/// the document that judges what a feed offers is never named by it.
pub fn release_digests_url(manifest_url: &str, target: &str) -> Result<String> {
    if target.is_empty()
        || target.len() > MAX_TARGET_BYTES
        || !target
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return malformed(format!(
            "'{target}' is not a build target this release names"
        ));
    }
    let Some((directory, _)) = manifest_url.rsplit_once('/') else {
        return malformed(format!(
            "the URL '{manifest_url}' names no directory to read the release digests from"
        ));
    };
    Ok(format!("{directory}/digests-{target}.json"))
}

/// Refuse `bytes` that are not the artifact `expected` names. `what` opens
/// the sentence, so a refusal says which half of an update was turned away.
fn verify_digest(what: &str, expected: &str, bytes: &[u8]) -> Result<()> {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let found = hex(&hasher.finalize());
    match found.eq_ignore_ascii_case(expected) {
        true => Ok(()),
        false => Err(CoreError::UpdateSignatureRefused {
            why: format!("{what} hashes to {found}, and this release published {expected} for it"),
        }),
    }
}

fn malformed<T>(why: String) -> Result<T> {
    Err(CoreError::UpdateFeedMalformed { why })
}

#[cfg(test)]
mod tests;
