//! One safety problem as a thing that can be named and printed.

use serde::{Deserialize, Serialize};
use specta::Type;

use super::Severity;

/// One safety problem, where it is, and what to do about it. The message
/// never holds a matched secret — only its fingerprint (invariant of
/// `secret::fingerprint_secret`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Finding {
    pub rule: String,
    pub severity: Severity,
    /// The file and line, or the config key that holds the entry.
    pub location: String,
    pub message: String,
    pub remediation: String,
}

#[cfg(test)]
mod tests {
    /// Every digest that reaches a finding's message is `DIGEST_CHARS`
    /// wide. Each stands in for a value a project can choose and vary
    /// offline, and two different values must never print alike; the width
    /// is pinned here rather than left to whoever next thinks a shorter one
    /// reads better.
    #[test]
    fn every_digest_in_a_sentence_is_the_pinned_width() {
        assert_eq!(super::super::DIGEST_CHARS, 16);
        assert_eq!(super::super::digest("anything").len(), 16);
        let printed = super::super::redact("ghp_0123456789abcdefghijklmnopqrstuvwxyzAB");
        let (_, shown) = printed.rsplit_once('#').expect("a redacted token is named");
        assert_eq!(shown.len(), 16, "{printed}");
    }
}
