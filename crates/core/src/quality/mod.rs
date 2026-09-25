//! What content says about itself, read before it is installed and again
//! after. Two independent scores, never averaged: safety answers "is this
//! dangerous", quality answers "is this well made". Both are advisory —
//! nothing here holds an install back.
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

mod allowance;
pub mod dimensions;
mod finding;
mod homoglyph;
pub mod observe;
mod phrase;
pub mod rules;
#[cfg(test)]
pub(crate) mod sample;
mod score;
mod secret;
mod text;

pub use allowance::{Accepted, AcceptedFile, Allowance, Package as AllowedPackage, Publisher};
pub use dimensions::{AntiPattern, DimensionScore, QualityScore};
pub use finding::Finding;
pub use score::{Deduction, SafetyScore, safety};
pub use secret::{fingerprint_secret, redact};
pub use text::{Line, Normalization, Quotation, Span, Standing};

/// How much of a hash stands in for the thing it names, wherever that name
/// reaches a finding's message. Sixteen hexadecimal characters is
/// sixty-four bits: two different values a project can choose never print
/// alike.
pub(crate) const DIGEST_CHARS: usize = 16;

/// A short, stable name for content a message cannot print — too long, or
/// not in hand at all. Never an identity on its own: it goes beside
/// what *is* printed, so the sentence still says what the rule fired on and
/// the digest only tells apart what the printing left out.
fn digest(material: &str) -> String {
    crate::hash::hash_bytes(material.as_bytes())
        .chars()
        .take(DIGEST_CHARS)
        .collect()
}

/// The rule set findings were produced by. Cached scores are keyed by it,
/// so any change to what a finding *is* must bump this — a further rule, a
/// widened pattern, a re-calibrated severity, and equally a change to how a
/// finding is identified.
pub const RULESET_VERSION: u32 = 6;

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
    /// Relative to the tree's root, and `/`-spelled wherever it becomes
    /// text: the links it is compared against are written that way.
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
        // OpenCode keys the executable and its arguments as one `command`
        // array and the environment as `environment`; read either shape,
        // so a server kendex wrote there is scored like every other.
        let (command, args) = match value.get("command").and_then(|v| v.as_array()) {
            Some(argv) => {
                let mut argv = argv
                    .iter()
                    .filter_map(|item| item.as_str().map(str::to_owned));
                (argv.next(), argv.collect())
            }
            None => (string("command"), strings("args")),
        };
        let mut env = map("env");
        env.extend(map("environment"));
        McpEntry {
            command,
            args,
            env,
            headers: map("headers"),
            // Antigravity keys the endpoint `serverUrl` and Gemini's
            // streamable-HTTP one is `httpUrl`; the secret scan reads all.
            url: string("url")
                .or_else(|| string("serverUrl"))
                .or_else(|| string("httpUrl")),
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
        /// The values a hook read out of a shared config file stores beside
        /// its command and uses as they are: every string under its `env`
        /// and `headers` maps, one per line, read as one document of stored
        /// values ([`DocRole::Values`]); `None` when it stores none. A
        /// credential in one is used at run time whether or not the command
        /// spells it, while a command-looking value in one is not something
        /// the hook runs. Keys, matcher, cwd, url and event are the entry's
        /// shape, not text, and reach no rule.
        values: Option<String>,
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
    /// The artifact's path, or the config file holding the entry, `/`-spelled
    /// so a finding from the plan and one from disk name the same place.
    pub location: String,
    /// Whose catalog the bytes came from, read off the item's recorded
    /// source; only kendex's own is eligible for the [`Allowance`].
    pub publisher: Publisher,
    pub content: Content,
}

/// What a document is to the rules.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DocRole {
    /// Text the harness executes or the model reads: a command line, a
    /// script, an authored file. Every content rule reads it.
    Text,
    /// A value the harness stores and uses without executing or reading
    /// it as instructions: one of a hook entry's env or header values.
    /// Only the rules about stored values — a credential sitting in one —
    /// read it: `mkfs` inside an environment value is not a command the
    /// hook runs, and scoring it as one would be the false attribution the
    /// narrowed hook reading exists to remove.
    Values,
}

/// One document's normalized lines, ready for the content rules.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Doc {
    pub location: String,
    pub role: DocRole,
    pub lines: Vec<Line>,
    /// [`crate::hash::hash_bytes`] of the text as the input carried it,
    /// before deobfuscation: what an edit to the file changes, and what
    /// the [`Allowance`] names a file by.
    pub digest: String,
}

/// Where `location` stands inside `root`, kept with the separator that
/// joins it back on: `/SKILL.md` for a file in a tree, ` (command)` or
/// ` (entry)` for the labelled documents beside a hook's script, empty
/// where the location is the root itself. `None` where the location is
/// not inside this root, which the separator decides: `/a/bc.md` starts
/// with the root `/a/b` and is not in it.
pub fn place_within<'a>(location: &'a str, root: &str) -> Option<&'a str> {
    let rest = location.strip_prefix(root)?;
    (rest.is_empty() || rest.starts_with(['/', ' '])).then_some(rest)
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

/// What a rule that ran has to say: the findings it scores, and the
/// mentions it read past.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Found {
    pub findings: Vec<Finding>,
    /// A hit standing where the file names it rather than runs it
    /// ([`Standing::Named`]): the same shape as a finding, at no cost to
    /// the score, so a verbose reading can show what the precision
    /// skipped.
    pub mentions: Vec<Finding>,
}

impl Found {
    /// File a hit under where it stands.
    pub fn push(&mut self, standing: Standing, finding: Finding) {
        match standing {
            Standing::Code => self.findings.push(finding),
            Standing::Named => self.mentions.push(finding),
        }
    }
}

impl From<Vec<Finding>> for Found {
    fn from(findings: Vec<Finding>) -> Found {
        Found {
            findings,
            mentions: Vec::new(),
        }
    }
}

/// What one rule did with one input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// The rule read this input. An empty list is a pass it earned.
    Ran(Found),
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

/// The advisory payload, exactly as one audit produced it. Every surface
/// that shows a score embeds this whole — `engine::ItemSafety` and
/// `browse::PackageSafety` flatten it into their serialized rows,
/// `check_catalog::CheckedItem` carries it beside the structural pass — so
/// a field of this struct reaches all of them without another hand-copy.
///
/// A flattened field lands in its embedder's own key space and nothing
/// catches a clash at compile time, so every field here must avoid the
/// keys those embedders already occupy: `kind`, `name`, `targets`, `scope`,
/// `notes`, `contentHash`, `fromCache`, `format` and
/// `discovery`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct AuditResult {
    pub findings: Vec<Finding>,
    /// Hits the rules read as the file naming a switch, not using it: a
    /// markdown code span, a shell comment, a string a script prints.
    /// They cost the score nothing and print only on a verbose reading.
    pub mentions: Vec<Finding>,
    /// Findings kendex accepted in a package it publishes ([`Allowance`]):
    /// the same shape, at no cost to the score, printed only on a verbose
    /// reading. Any edit to the file holding one puts it back among
    /// `findings`.
    pub accepted: Vec<Finding>,
    pub skipped: Vec<SkippedRule>,
    /// What every finding here costs — the advisory number every surface
    /// shows.
    pub safety: SafetyScore,
    /// Advisory, never blocking, and `None` for kinds that carry no
    /// authored prose to judge — a settings toggle has no writing in it.
    pub quality: Option<QualityScore>,
    pub ruleset: u32,
}

/// Deobfuscate, then run every rule, then score. The same call serves every
/// path: what a plan would write, what a scan found on disk, what a catalog
/// offers. Findings kendex's own table accepts in kendex's own item are set
/// aside before the score is taken.
pub fn audit(input: AuditInput) -> AuditResult {
    audit_with(input, Allowance::builtin())
}

/// What every rule said about one prepared input, before any of it is
/// accepted or scored.
struct Ran {
    findings: Vec<Finding>,
    mentions: Vec<Finding>,
    skipped: Vec<SkippedRule>,
}

fn run_rules(prepared: &Prepared) -> Ran {
    let mut ran = Ran {
        findings: Vec::new(),
        mentions: Vec::new(),
        skipped: Vec::new(),
    };
    for rule in rules::registry() {
        match rule.check(prepared) {
            Outcome::Ran(mut found) => {
                ran.findings.append(&mut found.findings);
                ran.mentions.append(&mut found.mentions);
            }
            Outcome::OutOfScope => {}
            Outcome::NotApplicable(reason) => ran.skipped.push(SkippedRule {
                rule: rule.id().to_owned(),
                reason: reason.to_owned(),
            }),
        }
    }
    ran
}

/// [`audit`] under a given table of accepted findings rather than the
/// compiled-in one.
pub fn audit_with(input: AuditInput, allowance: &Allowance) -> AuditResult {
    let prepared = text::prepare(input);
    let Ran {
        findings,
        mut mentions,
        skipped,
    } = run_rules(&prepared);
    let (mut findings, mut accepted) = allowance.accept(&prepared, findings);
    // Worst first, then by place. The line is part of the place and so
    // part of the order: while it lived inside `location` it sorted as
    // text, which put line 10 before line 2, and taking it out of the key
    // entirely would leave two findings from one rule in one file with
    // nothing to tell them apart.
    let by_place = |a: &Finding, b: &Finding| {
        b.severity
            .cmp(&a.severity)
            .then_with(|| a.location.cmp(&b.location))
            .then_with(|| a.line.cmp(&b.line))
            .then_with(|| a.rule.cmp(&b.rule))
    };
    findings.sort_by(by_place);
    mentions.sort_by(by_place);
    accepted.sort_by(by_place);
    let safety = score::safety(&findings);
    let quality = dimensions::quality(&prepared);
    AuditResult {
        findings,
        mentions,
        accepted,
        skipped,
        safety,
        quality,
        ruleset: RULESET_VERSION,
    }
}
