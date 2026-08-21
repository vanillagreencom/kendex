//! What content says about itself, read before it is installed and again
//! after. Two independent scores, never averaged: safety answers "is this
//! dangerous", quality answers "is this well made". Only safety can block.
//!
//! Every rule reads a *typed* input. There is no "content" field that means
//! a different thing per kind: a skill carries its tree and its byte
//! budgets, a hook carries the registration and the script it registers, an
//! MCP server carries command, args, env and headers, a plugin carries its
//! manifest and its lifecycle scripts. A rule that needs bytes an input
//! does not carry reports itself as not applicable — silence would read as
//! a pass, and a pass nobody earned is how a gate stops meaning anything.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::model::{HarnessId, ItemKind};

pub mod dimensions;
mod finding;
mod homoglyph;
pub mod observe;
pub mod overrides;
mod phrase;
pub mod reviews;
mod rules;
mod score;
mod secret;
mod text;

pub use dimensions::{AntiPattern, DimensionScore, QualityScore};
pub use finding::Finding;
pub use score::{Deduction, SafetyScore, Thresholds, Verdict, safety, verdict};
pub use secret::{fingerprint_secret, redact};
pub use text::{Line, Normalization};

/// The rule set findings were produced by. An override binds to it, so any
/// change to what the rules catch — a new rule, a widened pattern, a
/// re-calibrated severity — must bump this and stale every override that
/// was granted against the old behaviour.
pub const RULESET_VERSION: u32 = 2;

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, Type, Hash,
)]
#[serde(rename_all = "kebab-case")]
pub enum Severity {
    Low,
    Medium,
    High,
    Critical,
}

impl Severity {
    /// What one finding at this severity costs the safety score.
    pub fn deduction(self) -> u32 {
        match self {
            Severity::Critical => 25,
            Severity::High => 15,
            Severity::Medium => 8,
            Severity::Low => 3,
        }
    }

    /// One step down — what a hit costs on a line that is quoting rather
    /// than instructing: a blockquote, or any line of a supporting file. It
    /// is still scanned and still reported; it just weighs less than the
    /// same words in the file a harness actually loads. Low is the floor: a
    /// lowered Low finding still says what it found.
    pub fn lowered(self) -> Severity {
        match self {
            Severity::Critical => Severity::High,
            Severity::High => Severity::Medium,
            Severity::Medium | Severity::Low => Severity::Low,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Severity::Critical => "critical",
            Severity::High => "high",
            Severity::Medium => "medium",
            Severity::Low => "low",
        }
    }
}

/// One file inside a tree, with the budget it occupies.
///
/// `text` is `None` only for the binary assets a skill legitimately ships —
/// an image, a font, an archive. Everything else is decoded *lossily*: a
/// file that is text with one bad byte in it is still read, and the bytes
/// that had to be replaced are reported by `undecodable-content`. Refusing
/// to read such a file would mean one appended byte turns a payload
/// invisible to every rule, which is a pass nobody earned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TreeFile {
    pub path: PathBuf,
    pub bytes: usize,
    pub text: Option<String>,
}

/// Extensions whose contents are not text and are not read as instructions
/// by any harness. Anything not on this list is decoded and scanned.
const BINARY_ASSETS: &[&str] = &[
    "png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "ico", "icns", "pdf", "zip", "gz", "tgz",
    "bz2", "xz", "zst", "tar", "7z", "woff", "woff2", "ttf", "otf", "eot", "mp3", "mp4", "wav",
    "ogg", "webm", "mov", "wasm", "so", "dylib", "dll", "exe", "bin", "class", "jar", "pyc", "o",
    "a",
];

impl TreeFile {
    pub fn read(path: PathBuf, bytes: &[u8]) -> TreeFile {
        let binary = path
            .extension()
            .and_then(|e| e.to_str())
            .map(str::to_ascii_lowercase)
            .is_some_and(|e| BINARY_ASSETS.contains(&e.as_str()));
        TreeFile {
            bytes: bytes.len(),
            text: (!binary).then(|| String::from_utf8_lossy(bytes).into_owned()),
            path,
        }
    }
}

/// One MCP server as a harness records it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct McpEntry {
    pub command: Option<String>,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub headers: BTreeMap<String, String>,
    pub url: Option<String>,
}

impl McpEntry {
    /// The entry as it sits in a harness's config, read the same way whether
    /// a plan is about to write it or a scan just found it — the two paths
    /// must agree about what a server is, or they cannot agree about whether
    /// it is safe.
    pub fn from_json(value: &serde_json::Value) -> McpEntry {
        let strings = |key: &str| -> Vec<String> {
            value
                .get(key)
                .and_then(|v| v.as_array())
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| item.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default()
        };
        let map = |key: &str| -> BTreeMap<String, String> {
            value
                .get(key)
                .and_then(|v| v.as_object())
                .map(|table| {
                    table
                        .iter()
                        .filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_owned())))
                        .collect()
                })
                .unwrap_or_default()
        };
        let string = |key: &str| value.get(key).and_then(|v| v.as_str()).map(str::to_owned);
        McpEntry {
            command: string("command"),
            args: strings("args"),
            env: map("env"),
            headers: map("headers"),
            url: string("url"),
        }
    }
}

/// A plugin's readable sources.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PluginSources {
    /// Manifest file names found beside the plugin.
    pub manifests: Vec<String>,
    pub package_json: Option<String>,
    /// Tracked git origin of the plugin's own checkout.
    pub git_origin: Option<String>,
    pub scripts: Vec<TreeFile>,
}

/// A plugin nobody can read yet: at plan time a declared plugin is one
/// switch in a settings file, and there are no files anywhere to open.
pub const UNREADABLE_PLUGIN: &str = "the plugin's own files are not readable here — a declared plugin is one switch in a settings file until it is installed";

/// An MCP server observed as a config entry, without the entry itself.
pub const UNREAD_MCP_ENTRY: &str = "this server's command line lives inside a shared config file that was not re-read for this audit";

/// What a rule reads, defined per kind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Content {
    /// One authored file: agents and commands.
    Document {
        text: String,
    },
    /// A skill's whole tree.
    SkillTree {
        files: Vec<TreeFile>,
    },
    /// A hook's registration and the script it registers.
    Hook {
        event: String,
        matcher: Option<String>,
        command: String,
        script: Option<String>,
    },
    Mcp(McpEntry),
    Plugin(PluginSources),
    /// This path has no bytes for this item. Every rule that would read
    /// them says so; none of them passes it.
    Unread {
        why: &'static str,
    },
}

/// One thing to audit, named the way the manifest and lock name it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuditInput {
    pub kind: ItemKind,
    pub name: String,
    pub harness: Option<HarnessId>,
    /// The artifact's path, or the config file holding the entry.
    pub location: String,
    pub content: Content,
}

/// One document's normalized lines, ready for the content rules.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Doc {
    pub location: String,
    pub lines: Vec<Line>,
}

/// An input after deobfuscation, with its text split into classified lines.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Prepared {
    pub input: AuditInput,
    pub docs: Vec<Doc>,
    /// What deobfuscation had to change to read this content plainly.
    pub normalized: Vec<Normalization>,
}

impl Prepared {
    /// The skill tree's own SKILL.md, whichever name it is parked under.
    pub fn skill_md(&self) -> Option<&TreeFile> {
        let Content::SkillTree { files } = &self.input.content else {
            return None;
        };
        files
            .iter()
            .find(|file| matches!(file.path.to_str(), Some("SKILL.md" | "SKILL.md.disabled")))
    }
}

/// What one rule did with one input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// The rule read this input. An empty list is a pass it earned.
    Ran(Vec<Finding>),
    /// Not what this rule is about — nothing to say either way.
    OutOfScope,
    /// The rule applies to this kind, but the bytes it reads are not in this
    /// path's input. Reported, never counted as a pass.
    NotApplicable(&'static str),
}

/// One safety rule. Severity is decided per finding, not per rule: three of
/// the ported rules already return different severities for different
/// matches, so a rule-level severity would be a claim the code contradicts.
pub trait AuditRule: Send + Sync {
    fn id(&self) -> &'static str;
    fn check(&self, prepared: &Prepared) -> Outcome;
}

/// A rule that applies here but could not run, and why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SkippedRule {
    pub rule: String,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct AuditResult {
    pub findings: Vec<Finding>,
    pub skipped: Vec<SkippedRule>,
    pub safety: SafetyScore,
    /// Advisory, never blocking, and `None` for kinds that carry no
    /// authored prose to judge — a settings toggle has no writing in it.
    pub quality: Option<QualityScore>,
    pub ruleset: u32,
}

/// Deobfuscate, then run every rule, then score. The same call serves both
/// paths: what a plan would write, and what a scan found on disk.
pub fn audit(input: AuditInput) -> AuditResult {
    let prepared = text::prepare(input);
    let mut findings = Vec::new();
    let mut skipped = Vec::new();
    for rule in rules::registry() {
        match rule.check(&prepared) {
            Outcome::Ran(mut found) => findings.append(&mut found),
            Outcome::OutOfScope => {}
            Outcome::NotApplicable(reason) => skipped.push(SkippedRule {
                rule: rule.id().to_owned(),
                reason: reason.to_owned(),
            }),
        }
    }
    findings.sort_by(|a, b| {
        b.severity
            .cmp(&a.severity)
            .then_with(|| a.location.cmp(&b.location))
            .then_with(|| a.rule.cmp(&b.rule))
    });
    let safety = score::safety(&findings);
    let quality = dimensions::quality(&prepared);
    AuditResult {
        findings,
        skipped,
        safety,
        quality,
        ruleset: RULESET_VERSION,
    }
}
