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
    /// This exact finding's identity: the rule that fired and the sentence
    /// it fired with. An override binds to a set of these, so a review of
    /// one problem can never wave through a different one that appears
    /// later at the same place.
    ///
    /// What is deliberately *not* in it is everything kendex's own
    /// rendering moves. The line, because rendering shifts lines. The file,
    /// because a harness decides what shape an item takes — Codex renders a
    /// command as a skill tree, and an over-cap body is split into
    /// `references/`, so the same authored sentence is read at three
    /// different paths in three readings of one item. The severity, because
    /// a hit weighs one step less in a supporting file than in the body,
    /// and the split moves content between exactly those two. An identity
    /// carrying any of them is one a decision cannot survive.
    ///
    /// Nothing widens past the item: a fingerprint is only ever read within
    /// one item's records, a decision binds to that item's whole content,
    /// and a publisher's record is capped at the number of occurrences the
    /// content they wrote actually carried. Two occurrences of one sentence
    /// are one question, asked twice.
    pub fn fingerprint(&self) -> String {
        let material = format!("{}|{}", self.rule, self.message);
        crate::hash::hash_bytes(material.as_bytes())
            .chars()
            .take(16)
            .collect()
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

    /// The whole point of the identity: one authored sentence, read through
    /// every shape kendex's rendering gives it. The catalog reads the
    /// source, the gate reads the render, the split moves the body into
    /// `references/` and lowers what it finds there, and Codex spells a
    /// command's body `SKILL.md`. One decision, every reading.
    #[test]
    fn every_reading_of_one_sentence_is_one_finding() {
        let source = finding("skills/g/SKILL.md:69").fingerprint();
        assert_eq!(
            source,
            finding("/home/u/p/.agents/skills/g/SKILL.md:68").fingerprint()
        );
        assert_eq!(
            source,
            finding("/home/u/p/.agents/skills/g/references/details.md:14").fingerprint()
        );
        assert_eq!(source, finding("commands/ship.md:12").fingerprint());
        let lowered = Finding {
            severity: Severity::High,
            ..finding("skills/g/references/details.md:14")
        };
        assert_eq!(source, lowered.fingerprint());
    }

    /// And a different question is still a different question: another rule
    /// or another sentence is not this one.
    #[test]
    fn a_different_problem_is_a_different_finding() {
        let base = finding("skills/g/SKILL.md:69").fingerprint();
        let other_message = Finding {
            message: "`--dangerously-skip-permissions` turns off permission prompts".to_owned(),
            ..finding("skills/g/SKILL.md:69")
        };
        assert_ne!(base, other_message.fingerprint());
        let other_rule = Finding {
            rule: "rce".to_owned(),
            ..finding("skills/g/SKILL.md:69")
        };
        assert_ne!(base, other_rule.fingerprint());
    }
}
