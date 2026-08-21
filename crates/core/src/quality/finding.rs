//! One safety problem as a thing that can be named, printed and decided on.

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

impl Finding {
    /// This exact finding's identity. An override binds to a set of these,
    /// so a review of one problem can never wave through a different one
    /// that appears later at the same place.
    /// `root` is the item's own location, stripped from the finding's so
    /// the print names the file *within* the item. The gate reads a skill
    /// at its canonical tree and the audit reads it back through the
    /// harness-native link — same bytes, two spellings of the path — and a
    /// print that kept the absolute path would call every accepted
    /// symlink-method install a different set of findings.
    ///
    /// The line number is left out on purpose. A catalog author reviews the
    /// source and a consumer scores the render, and rendering moves lines —
    /// so a positional identity is one an author's decision can never carry
    /// across the boundary. What is left names the rule, the file and the
    /// sentence, which is the same question wherever in the file it is
    /// asked; a decision on it covers every line of that file saying it.
    /// Nothing widens past the file, because a decision binds to the whole
    /// content anyway: add a line and the snapshot it sits under is stale.
    pub fn fingerprint(&self, root: &str) -> String {
        let location = match self.location.strip_prefix(root) {
            Some(rest) => rest.trim_start_matches('/'),
            None => self.location.as_str(),
        };
        let material = format!(
            "{}|{}|{}|{}",
            self.rule,
            self.severity.name(),
            within_item(location),
            self.message
        );
        crate::hash::hash_bytes(material.as_bytes())
            .chars()
            .take(16)
            .collect()
    }
}

/// Where in the item a finding is, in the one spelling every reading of
/// that item agrees on: no line number, and the body under one name.
///
/// A harness decides for itself what shape an item takes. Codex renders a
/// command as a skill tree, so the same authored document is the item's
/// whole file in the catalog and `SKILL.md` once installed — one body, two
/// spellings, and a decision about it has to survive the trip.
fn within_item(location: &str) -> &str {
    match strip_line(location) {
        "SKILL.md" => "",
        rest => rest,
    }
}

/// A location with its `:line` suffix removed. A config-key location
/// (`mcpServers.foo`) has none, and a Windows-style `C:\...` never ends in
/// digits after a colon, so only the suffix a rule appended is taken.
fn strip_line(location: &str) -> &str {
    match location.rsplit_once(':') {
        Some((file, line)) if !line.is_empty() && line.bytes().all(|b| b.is_ascii_digit()) => file,
        _ => location,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn finding(location: &str) -> Finding {
        Finding {
            rule: "safety-bypass".to_owned(),
            severity: Severity::Critical,
            location: location.to_owned(),
            message: "`--no-verify` skips the checks a commit runs".to_owned(),
            remediation: "leave the check in place".to_owned(),
        }
    }

    /// The whole point of the identity: the catalog reads the source and a
    /// consumer reads the render, and rendering moves lines. Same rule,
    /// same file, same sentence — same decision, wherever the line landed.
    #[test]
    fn a_moved_line_is_the_same_finding() {
        let source = finding("skills/g/SKILL.md:69").fingerprint("skills/g");
        let rendered = finding("/home/u/p/.agents/skills/g/SKILL.md:68")
            .fingerprint("/home/u/p/.agents/skills/g");
        assert_eq!(source, rendered);
    }

    /// And nothing beyond the line is waved through: another file, another
    /// sentence, another rule are all different questions.
    #[test]
    fn everything_but_the_line_still_separates_findings() {
        let base = finding("skills/g/SKILL.md:69").fingerprint("skills/g");
        assert_ne!(
            base,
            finding("skills/g/README.md:69").fingerprint("skills/g")
        );
        let mut other = finding("skills/g/SKILL.md:69");
        other.message = "something else entirely".to_owned();
        assert_ne!(base, other.fingerprint("skills/g"));
        let mut louder = finding("skills/g/SKILL.md:69");
        louder.severity = Severity::High;
        assert_ne!(base, louder.fingerprint("skills/g"));
    }

    /// A location that is a config key, not a file, keeps every character.
    #[test]
    fn a_key_location_is_not_trimmed() {
        assert_eq!(strip_line("mcpServers.deploy"), "mcpServers.deploy");
        assert_eq!(strip_line("skills/g/SKILL.md:69"), "skills/g/SKILL.md");
        assert_eq!(strip_line("skills/g/SKILL.md:"), "skills/g/SKILL.md:");
    }

    /// Codex renders a command as a skill tree. The catalog reads the
    /// authored document as the item itself, the install reads it as
    /// `SKILL.md`, and one decision has to cover both.
    #[test]
    fn the_item_body_fingerprints_the_same_under_either_spelling() {
        let document = finding("commands/ship.md:12").fingerprint("commands/ship.md");
        let rendered = finding("/home/u/p/.agents/skills/ship/SKILL.md:14")
            .fingerprint("/home/u/p/.agents/skills/ship");
        assert_eq!(document, rendered);
        // A supporting file is still its own question.
        assert_ne!(
            document,
            finding("/home/u/p/.agents/skills/ship/references/a.md:14")
                .fingerprint("/home/u/p/.agents/skills/ship")
        );
    }
}
