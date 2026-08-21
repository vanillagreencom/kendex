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
                        // Named, not "this file": the identity is the rule
                        // and the sentence, so a message that only says
                        // "this file" is the same sentence in every file it
                        // fires in — and a person would settle one they
                        // were shown and one they were not.
                        message: format!(
                            "{} reads differently than it looks: {}",
                            named(&report.location),
                            parts.join(", ")
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

/// The file a location names, for a message that is about the file rather
/// than about something quoted from it. Two such findings differ only by
/// which file they are about, so the sentence has to carry it: the
/// identity a decision binds to is the rule and the message, and nothing
/// else tells them apart.
fn named(location: &str) -> String {
    let file = location.rsplit_once(':').map_or(location, |(file, line)| {
        match line.bytes().all(|b| b.is_ascii_digit()) && !line.is_empty() {
            true => file,
            false => location,
        }
    });
    match file.rsplit_once('/') {
        Some((_, leaf)) if !leaf.is_empty() => leaf.to_owned(),
        _ => file.to_owned(),
    }
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
                .filter(|report| report.undecodable > 0)
                .map(|report| Finding {
                    rule: self.id().to_owned(),
                    severity: Severity::Medium,
                    location: report.location.clone(),
                    message: format!(
                        "{} byte(s) of {} are not text and were read as best they could be, so part of it was scanned as a guess",
                        report.undecodable,
                        named(&report.location)
                    ),
                    remediation:
                        "save the file as UTF-8 text, or remove it if it was never meant to be text"
                            .to_owned(),
                })
                .collect(),
        )
    }
}
