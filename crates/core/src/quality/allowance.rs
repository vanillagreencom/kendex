//! Findings kendex accepts in the packages it publishes itself.
//!
//! A guard that really hands `--dangerously-skip-permissions` to the lane
//! it launches, and a reference page that documents a download piped into
//! a shell, are findings by the rule's own definition, and the rule is
//! right to say so. What they need is not a quieter rule but a record
//! that somebody read the finding and accepted it, for those bytes and no
//! others.
//!
//! The record is `allowance.toml` beside this file, compiled into the
//! binary: only kendex's own table is ever honoured, and no catalog can
//! carry one. Each row names a package, a file inside it by the hash of
//! its text, and the finding by rule, line and message. A finding is
//! accepted where the file the rules read has exactly the recorded text,
//! so an edited copy is flagged again and a real finding in a consumer's
//! edited copy stays visible; and only under the rule set the rows were
//! accepted for, so a rule change re-asks the question. The table is
//! regenerated from the catalog, and `crates/core/tests/allowance.rs`
//! holds it current.

use std::sync::LazyLock;

use serde::{Deserialize, Serialize};

use crate::error::Result;
use crate::model::ItemKind;
use crate::source::SourceConfig;
use crate::source_read::SealedSource;

use super::{AuditInput, Finding, Prepared, RULESET_VERSION, place_within};

/// The compiled-in table, as text: the cache key reads its digest.
pub const ALLOWANCE_TEXT: &str = include_str!("allowance.toml");

/// The header every regeneration writes above the table.
const HEADER: &str = "\
# Findings kendex accepts in its own packages, one row per finding, keyed
# on the text of the file holding it. Generated from the catalog by
# `cargo test -p kendex-core -- --ignored regenerate_allowance`, and
# `crates/core/tests/allowance.rs` fails while it is stale. Read by
# `crates/core/src/quality/allowance.rs`.

";

/// Every accepted finding, under the rule set it was accepted for.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
pub struct Allowance {
    /// The rule set the rows were accepted under. Another set is no
    /// acceptance: what a finding is may have changed.
    pub ruleset: u32,
    #[serde(default, rename = "package", skip_serializing_if = "Vec::is_empty")]
    pub packages: Vec<Package>,
}

/// One package's accepted findings.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
pub struct Package {
    pub kind: ItemKind,
    pub name: String,
    /// The catalog's hash of the package these rows were accepted against
    /// ([`SealedSource::catalog_hash`]). Not read when a finding is judged,
    /// which the file's own hash decides; regeneration rewrites it on any
    /// change to the package, so the diff that carries it is where the
    /// rows are read again as a whole.
    pub source_hash: String,
    #[serde(rename = "file")]
    pub files: Vec<AcceptedFile>,
}

/// One file of a package, by the text the rules read, and the findings
/// accepted in it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
pub struct AcceptedFile {
    /// Inside the package: a tree file's `/`-spelled path, empty for a
    /// package that is one file, a hook's ` (command)` label for the
    /// command line beside its script.
    pub path: String,
    /// [`super::Doc::digest`] of the text, as every reading computes it.
    pub hash: String,
    #[serde(rename = "finding")]
    pub accepted: Vec<Accepted>,
}

/// One accepted finding, by everything that identifies it in a file of
/// known text. The line is exact for that text; the message says what the
/// rule matched, so the row reads on its own.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
pub struct Accepted {
    pub rule: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    pub message: String,
}

/// A table this build cannot read accepts nothing: every finding stays
/// visible, and `crates/core/tests/allowance.rs` holds the committed
/// table readable, so a release never ships one.
static BUILTIN: LazyLock<Option<Allowance>> =
    LazyLock::new(|| Allowance::parse(ALLOWANCE_TEXT).ok());

static BUILTIN_DIGEST: LazyLock<String> =
    LazyLock::new(|| crate::hash::hash_bytes(ALLOWANCE_TEXT.as_bytes()));

impl Allowance {
    /// The table compiled into this build, or `None` where it will not
    /// read.
    pub fn builtin() -> Option<&'static Allowance> {
        BUILTIN.as_ref()
    }

    /// What tells one build's table from another's, for a cache keyed by
    /// what a score was computed under.
    pub fn builtin_digest() -> &'static str {
        &BUILTIN_DIGEST
    }

    pub fn parse(text: &str) -> std::result::Result<Allowance, toml::de::Error> {
        toml::from_str(text)
    }

    /// The table as the file holds it, header included.
    pub fn to_toml(&self) -> std::result::Result<String, toml::ser::Error> {
        Ok(format!("{HEADER}{}", toml::to_string_pretty(self)?))
    }

    /// Split what the rules found into what stays a finding and what this
    /// table accepts. Every acceptance is by exact text: the file the
    /// finding fired in has the recorded hash, and the finding is one of
    /// the rows recorded for that file.
    pub(super) fn accept(
        &self,
        prepared: &Prepared,
        findings: Vec<Finding>,
    ) -> (Vec<Finding>, Vec<Finding>) {
        let package = self.packages.iter().find(|package| {
            package.kind == prepared.input.kind && package.name == prepared.input.name
        });
        let (Some(package), true) = (package, self.ruleset == RULESET_VERSION) else {
            return (findings, Vec::new());
        };
        findings
            .into_iter()
            .partition(|finding| !package.accepts(prepared, finding))
    }

    /// The table the catalog at `sealed` warrants right now: every finding
    /// the rules raise over what it offers, accepted as it stands. Diffing
    /// this against the committed table is the review of a change to what
    /// is accepted.
    pub fn regenerate(sealed: &SealedSource, config: &SourceConfig) -> Result<Allowance> {
        let mut packages = Vec::new();
        for kind in crate::check_catalog::CHECKED_KINDS {
            let mut names = crate::source::list_items(sealed, config, kind);
            names.sort();
            names.dedup();
            for name in names {
                // A listed name no lookup reads is the check's own finding,
                // not content anyone can accept a finding in.
                let Some(path) = crate::source::find_item(sealed, config, kind, &name) else {
                    continue;
                };
                let prepared = super::text::prepare(AuditInput {
                    kind,
                    name: name.clone(),
                    harness: None,
                    location: sealed.catalog_path(&path),
                    content: crate::check_catalog::content(sealed, kind, &path)?,
                });
                let files = accepted_files(&prepared, super::run_rules(&prepared).findings);
                if files.is_empty() {
                    continue;
                }
                packages.push(Package {
                    kind,
                    name,
                    source_hash: sealed.catalog_hash(&path)?,
                    files,
                });
            }
        }
        Ok(Allowance {
            ruleset: RULESET_VERSION,
            packages,
        })
    }
}

impl Package {
    fn accepts(&self, prepared: &Prepared, finding: &Finding) -> bool {
        let Some((path, digest)) = located(prepared, &finding.location) else {
            return false;
        };
        self.files
            .iter()
            .filter(|file| file.path == path && file.hash == digest)
            .any(|file| {
                file.accepted.iter().any(|row| {
                    row.rule == finding.rule
                        && row.line == finding.line
                        && row.message == finding.message
                })
            })
    }
}

/// The document a finding fired in, as the table names it: its path inside
/// the package and the digest of its text. `None` for a finding no
/// document backs, which a rule over a config entry raises at the entry.
fn located<'a>(prepared: &'a Prepared, location: &str) -> Option<(&'a str, &'a str)> {
    let doc = prepared.docs.iter().find(|doc| doc.location == location)?;
    let path = place_within(&doc.location, &prepared.input.location)?;
    Some((path.trim_start_matches('/'), doc.digest.as_str()))
}

/// Every finding filed under the file it fired in, in the order the
/// findings came.
fn accepted_files(prepared: &Prepared, findings: Vec<Finding>) -> Vec<AcceptedFile> {
    let mut files: Vec<AcceptedFile> = Vec::new();
    for finding in findings {
        let Some((path, digest)) = located(prepared, &finding.location) else {
            continue;
        };
        let row = Accepted {
            rule: finding.rule,
            line: finding.line,
            message: finding.message,
        };
        match files.iter_mut().find(|file| file.path == path) {
            Some(file) => file.accepted.push(row),
            None => files.push(AcceptedFile {
                path: path.to_owned(),
                hash: digest.to_owned(),
                accepted: vec![row],
            }),
        }
    }
    files
}
