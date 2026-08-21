//! The rule registry: eleven safety rules ported from HarnessKit's auditor,
//! plus the one this codebase adds — the report that deobfuscation had to
//! change something to read the content plainly.
//!
//! | Rule | Reads | Severity |
//! |---|---|---|
//! | `prompt-injection` | authored text | Critical |
//! | `rce` | authored text | Critical |
//! | `credential-theft` | authored text | Critical, High when it only reads |
//! | `plaintext-secrets` | authored text, MCP env and headers | Critical |
//! | `safety-bypass` | authored text | Critical, High for confirm-skipping flags |
//! | `dangerous-commands` | authored text | High on hooks, Medium elsewhere |
//! | `mcp-command-injection` | MCP command and args | High |
//! | `broad-permissions` | MCP command and args | High |
//! | `supply-chain` | MCP command and args | Medium |
//! | `plugin-source-trust` | plugin manifests and origin | Medium, Low without a manifest |
//! | `plugin-lifecycle-scripts` | plugin package.json | Medium, Low for a quiet script |
//! | `obfuscated-content` | what deobfuscation changed | Low |
//! | `undecodable-content` | bytes that would not decode as text | Medium |
//!
//! HarnessKit exempted fenced code and blockquotes from all six content
//! rules, which is a bypass: the model reads a payload wrapped in backticks
//! exactly as it reads one that is not, and a fenced `sh` block in a
//! SKILL.md is not an example of the instruction, it *is* the instruction.
//! So the file a harness loads is scanned at full weight whatever it puts
//! inside a fence. What weighs one severity less is content that is plainly
//! quoting rather than instructing: a blockquote, and every line of a
//! skill's supporting files. The one exception is `plaintext-secrets`: a
//! credential in a code block is exactly as leaked as one in prose, so it
//! never downgrades anywhere.
//!
//! Every message says what the rule fired *on*, never where it was found.
//! A finding's identity is its rule and its sentence
//! ([`crate::quality::Finding::fingerprint`]), so a sentence that describes
//! only the kind of problem makes two different problems one decision — and
//! the surfaces show one of them, so a person settles the other having
//! never seen it. Where it was found is the finding's location, which is
//! deliberately not in the identity: rendering moves content between files
//! and an identity that moved with it would stop being the finding a
//! decision was made about.

use crate::model::ItemKind;

use super::{AuditRule, Content, Doc, Finding, Line, Outcome, Prepared, Severity};

mod content;
mod mcp;
mod plugin;
mod secrets;
mod shell;

pub(super) fn registry() -> Vec<Box<dyn AuditRule>> {
    let mut rules: Vec<Box<dyn AuditRule>> =
        vec![Box::new(ObfuscatedContent), Box::new(UndecodableContent)];
    rules.extend(content::rules());
    rules.extend(shell::rules());
    rules.extend(secrets::rules());
    rules.extend(mcp::rules());
    rules.extend(plugin::rules());
    rules
}

/// Every rule's id. The one list of what the registry holds, so a test that
/// has to cover all of them cannot quietly stop covering one: a rule added
/// without a case in `every_rule_says_what_it_fired_on` fails that test
/// rather than shipping an identity nothing checked.
pub fn ids() -> Vec<&'static str> {
    registry().into_iter().map(|rule| rule.id()).collect()
}

/// Kinds that carry authored text the content rules read.
pub(super) const AUTHORED: &[ItemKind] = &[
    ItemKind::Agent,
    ItemKind::Skill,
    ItemKind::Hook,
    ItemKind::Command,
    ItemKind::Plugin,
    ItemKind::PiExtension,
];

pub(super) fn at(doc: &Doc, line: &Line) -> String {
    format!("{}:{}", doc.location, line.number)
}

/// Run a line check over every document this input carries. A kind the rule
/// is not about gets no verdict either way; a kind it *is* about whose bytes
/// are not in this input says so rather than passing.
pub(super) fn scan_docs(
    prepared: &Prepared,
    kinds: &[ItemKind],
    mut check: impl FnMut(&Doc, &Line, &mut Vec<Finding>),
) -> Outcome {
    if !kinds.contains(&prepared.input.kind) {
        return Outcome::OutOfScope;
    }
    if let Content::Unread { why } = &prepared.input.content {
        return Outcome::NotApplicable(why);
    }
    let mut findings = Vec::new();
    for doc in &prepared.docs {
        for line in &doc.lines {
            check(doc, line, &mut findings);
        }
    }
    Outcome::Ran(findings)
}

/// Content that had to be deobfuscated before it could be read plainly.
///
/// Severity is Low on purpose. Some legitimate writing still trips this —
/// a soft hyphen left by a word processor, a stray byte-order mark — so a
/// high severity would spend the score on false positives and teach people
/// to skip the whole report. Its job is to be visible next to whatever else
/// was found. What does *not* reach it at all is ordinary typography and
/// emoji, which `Normalization::changed` excludes by construction.
struct ObfuscatedContent;

impl AuditRule for ObfuscatedContent {
    fn id(&self) -> &'static str {
        "obfuscated-content"
    }

    fn check(&self, prepared: &Prepared) -> Outcome {
        Outcome::Ran(
            prepared
                .normalized
                .iter()
                .filter(|report| report.changed())
                .map(|report| {
                    let mut parts = Vec::new();
                    if report.invisible > 0 {
                        parts.push(format!(
                            "{} invisible character(s) removed",
                            report.invisible
                        ));
                    }
                    if report.homoglyphs > 0 {
                        parts.push(format!(
                            "{} letter(s) that only look Latin folded",
                            report.homoglyphs
                        ));
                    }
                    Finding {
                        rule: self.id().to_owned(),
                        severity: Severity::Low,
                        location: report.location.clone(),
                        // What was found, not where: the identity is the
                        // rule and the sentence, so a sentence that says
                        // only how many were found is the same sentence in
                        // every file that found that many, and a person
                        // shown one would settle the others unseen. Where
                        // is carried by the finding's location, and every
                        // location a decision covers is listed under it.
                        message: format!(
                            "this file reads differently than it looks: {} ({})",
                            parts.join(", "),
                            spelled(&report.found)
                        ),
                        remediation:
                            "check the file for hidden characters; if the text is meant to be plain, retype the affected words in plain ASCII"
                                .to_owned(),
                    }
                })
                .collect(),
        )
    }
}

/// The characters a normalization pass removed or folded, written as their
/// code points. A hidden zero-width space and a Cyrillic letter dressed as
/// a Latin one are two different questions, and the sentence has to say
/// which — never which file, since a file is something rendering moves
/// content between and an identity that moved with it would stop being the
/// finding a decision was made about.
fn spelled(found: &std::collections::BTreeSet<char>) -> String {
    const SHOWN: usize = 6;
    let point = |c: &char| format!("U+{:04X}", *c as u32);
    let mut points: Vec<String> = found.iter().take(SHOWN).map(point).collect();
    if found.len() > SHOWN {
        // The tail is named by a digest of the whole set, not left out.
        // Two files sharing their first six code points and differing
        // after would otherwise read the same sentence, and one sentence
        // is one decision — the reader would settle the second having
        // seen only the first.
        let whole: Vec<String> = found.iter().map(point).collect();
        points.push(format!(
            "and {} more, {}",
            found.len() - SHOWN,
            super::digest(&whole.join(","))
        ));
    }
    points.join(", ")
}

/// A file that is not the text it claims to be.
///
/// Bytes that will not decode are read anyway, with the bad ones replaced,
/// so a payload cannot be hidden from every rule by appending one stray
/// byte. What the replacement costs is honesty about the rest of the file:
/// some of what was scanned is a guess, and the reader deserves to know
/// which file it was. Medium, because the file still scored on everything
/// that did decode.
struct UndecodableContent;

impl AuditRule for UndecodableContent {
    fn id(&self) -> &'static str {
        "undecodable-content"
    }

    fn check(&self, prepared: &Prepared) -> Outcome {
        Outcome::Ran(
            prepared
                .normalized
                .iter()
                // Named by what would not decode, so the reading that found
                // nothing to name is the same reading that reports nothing.
                .filter_map(|report| {
                    let unreadable = report.unreadable.as_deref()?;
                    Some(Finding {
                    rule: self.id().to_owned(),
                    severity: Severity::Medium,
                    location: report.location.clone(),
                    // Which unreadable content, not which file. The count
                    // alone is the same sentence in every file that has
                    // that many, and one sentence is one decision — the
                    // reader would settle a file they were never shown.
                    message: format!(
                        "{} byte(s) of this file are not text and were read as best they could be, so part of it was scanned as a guess (unreadable content {unreadable})",
                        report.undecodable,
                    ),
                    remediation:
                        "save the file as UTF-8 text, or remove it if it was never meant to be text"
                            .to_owned(),
                    })
                })
                .collect(),
        )
    }
}
