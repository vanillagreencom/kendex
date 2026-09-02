//! One safety problem as a thing that can be named and printed.

use serde::{Deserialize, Serialize};
use specta::Type;

use super::Severity;

/// One safety problem, where it is, and what to do about it. The message
/// never holds a matched secret — only its fingerprint (invariant of
/// `secret::fingerprint_secret`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Finding {
    pub rule: String,
    pub severity: Severity,
    /// The file this fired in, or the config key that holds the entry.
    /// Never a line: composing one in would make this a display string, and
    /// a display string is something every reader has to parse back — which
    /// no reader can do correctly for a file whose own name ends in a colon
    /// and digits.
    pub location: String,
    /// The 1-based line within `location`, for a rule that reads lines.
    /// Part of a finding's identity, not decoration: one rule fires at many
    /// lines of one file, and anything that orders, keys or folds findings
    /// has to read this as well as `location` or it shows one problem where
    /// there are several.
    pub line: Option<u32>,
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
