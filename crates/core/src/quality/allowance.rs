//! Findings kendex accepts in the packages it publishes itself.
//!
//! A guard that really hands `--dangerously-skip-permissions` to the lane
//! it launches, a reference page that really pipes a download into a
//! shell, and a workflow template that really emits that line are
//! findings by the rule's own definition, and the rule is right to say
//! so. What they need is not a quieter rule but a record that somebody
//! read the finding and accepted it, for those bytes and no others.
//!
//! The record is `allowance.toml` beside this file, compiled into the
//! binary: only kendex's own table is ever honoured, and no catalog can
//! carry one. Each row names a package, a file inside it by path, and the
//! finding by rule, the hash of the line it fired on, and message. A
//! finding is accepted only for an item whose source is kendex's own
//! catalog ([`Publisher::Kendex`]), where the line the finding fired on
//! has exactly the recorded text, under the rule set the rows were
//! accepted for, and one row accepts one finding. The same bytes from
//! another catalog, an edit to the line, a hand-placed copy and a rule
//! change all leave the finding where it is; an edit elsewhere in the
//! file, which moves the line or not, leaves the acceptance standing. The
//! table is refreshed from the catalog, never widened by it, and
//! `crates/core/tests/allowance.rs` holds it current.

use std::sync::LazyLock;

use serde::{Deserialize, Serialize};

use crate::error::{CoreError, Result};
use crate::model::ItemKind;
use crate::source::SourceConfig;
use crate::source_read::SealedSource;

use super::{Doc, Finding, Prepared, RULESET_VERSION, place_within};

/// The compiled-in table, as text: the cache key reads its digest.
pub const ALLOWANCE_TEXT: &str = include_str!("allowance.toml");

/// The header every refresh writes above the table.
const HEADER: &str = "\
# Findings kendex accepts in its own packages, one row per finding, keyed
# on the text of the line the finding fired on. A row is added by hand and
# reviewed with the finding it accepts; `cargo test -p kendex-core --
# --ignored regenerate_allowance` refreshes the line hash and message of
# the rows already here and refuses a file whose findings no longer match
# its rows one per row (`AcceptedFile::refreshed` states when), and
# `crates/core/tests/allowance.rs` fails while the table is stale. Read by
# `crates/core/src/quality/allowance.rs`.

";

/// Whose bytes an input is, as far as the table is concerned: kendex's
/// own catalog, or anyone else's. Decided once, by [`Publisher::of`] over
/// an item's recorded source or by [`Publisher::of_checkout`] over a local
/// catalog's `origin` remote; an item with no recorded source (a
/// hand-placed copy) and a folder with no `origin` are
/// [`Publisher::Other`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Publisher {
    Kendex,
    Other,
}

impl Publisher {
    /// Read off a source's provenance as the lock and the plan record it:
    /// `owner/repo` or a URL for a remote, a path identity, or a reserved
    /// name. Only a reference that names kendex's own repository, in any
    /// spelling [`crate::source_ref::repo_identity`] folds, is
    /// [`Publisher::Kendex`].
    pub fn of(provenance: &str) -> Publisher {
        static KENDEX: LazyLock<String> = LazyLock::new(|| {
            crate::source_ref::repo_identity(crate::manifest::DEFAULT_SOURCE_REPO)
        });
        match crate::source_ref::repo_identity(provenance) == *KENDEX {
            true => Publisher::Kendex,
            false => Publisher::Other,
        }
    }

    /// Whose checkout the catalog at `root` is, by its `origin` remote and
    /// nothing else: the answer the authoring check, the directory index
    /// and the Mine row share through `check_catalog::check_with`, so a
    /// checkout of kendex's own repository reads as kendex's in each and a
    /// folder with no git, no repository or no `origin` is nobody's.
    pub fn of_checkout(root: &std::path::Path) -> Publisher {
        crate::process::origin_url(root).map_or(Publisher::Other, |url| Publisher::of(&url))
    }
}

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
    #[serde(rename = "file")]
    pub files: Vec<AcceptedFile>,
}

/// One file of a package, by path, and the findings accepted in it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
pub struct AcceptedFile {
    /// The file's `/`-spelled path inside the package's tree, the one
    /// spelling a row carries: a package that is one file, and the
    /// labelled documents beside a hook's script, are never accepted.
    pub path: String,
    #[serde(rename = "finding")]
    pub accepted: Vec<Accepted>,
}

/// One accepted finding, by everything that identifies it in a file
/// whatever the rest of that file holds: the line's own text, wherever the
/// line now stands, and the message saying what the rule matched, so the
/// row reads on its own.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
pub struct Accepted {
    pub rule: String,
    /// [`crate::hash::hash_bytes`] of the line the finding fired on, as the
    /// author wrote it ([`super::Doc::written`]): a character the rules
    /// read past is still an edit to the line.
    pub line_hash: String,
    pub message: String,
}

/// A table this build cannot read accepts nothing: every finding stays
/// visible, and `crates/core/tests/allowance.rs` holds the committed
/// table readable, so a release never ships one.
static BUILTIN: LazyLock<Allowance> =
    LazyLock::new(|| Allowance::parse(ALLOWANCE_TEXT).unwrap_or_default());

static BUILTIN_DIGEST: LazyLock<String> =
    LazyLock::new(|| crate::hash::hash_bytes(ALLOWANCE_TEXT.as_bytes()));

impl Allowance {
    /// The table compiled into this build.
    pub fn builtin() -> &'static Allowance {
        &BUILTIN
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
    /// table accepts. Nothing is accepted for anyone but kendex; for
    /// kendex's own item every acceptance is by exact text: the finding is
    /// one of the rows recorded for its file, at a line of the recorded
    /// text. Each row accepts one finding, so a second copy of an accepted
    /// line stays a finding.
    pub(super) fn accept(
        &self,
        prepared: &Prepared,
        findings: Vec<Finding>,
    ) -> (Vec<Finding>, Vec<Finding>) {
        let package = self.packages.iter().find(|package| {
            package.kind == prepared.input.kind && package.name == prepared.input.name
        });
        let honoured =
            prepared.input.publisher == Publisher::Kendex && self.ruleset == RULESET_VERSION;
        let (Some(package), true) = (package, honoured) else {
            return (findings, Vec::new());
        };
        let mut open: Vec<(&str, &Accepted)> = package
            .files
            .iter()
            .flat_map(|file| file.accepted.iter().map(|row| (file.path.as_str(), row)))
            .collect();
        findings
            .into_iter()
            .partition(|finding| !take(&mut open, prepared, finding))
    }

    /// This table with every row read again off the catalog at `sealed`:
    /// each row's line hash and message as the finding stands there now,
    /// the rows of a file in the order the file holds their lines. A row is
    /// never added. A package the catalog no longer offers is refused here;
    /// what refuses a listed file is stated once, at `AcceptedFile::refreshed`.
    pub fn refreshed(&self, sealed: &SealedSource, config: &SourceConfig) -> Result<Allowance> {
        let mut packages = Vec::with_capacity(self.packages.len());
        for package in &self.packages {
            let Some(path) = crate::source::find_item(sealed, config, package.kind, &package.name)
            else {
                return Err(CoreError::ItemNotOffered {
                    kind: package.kind,
                    name: package.name.clone(),
                });
            };
            let prepared = super::text::prepare(crate::check_catalog::audit_input(
                sealed,
                package.kind,
                &package.name,
                &path,
                Publisher::Kendex,
            )?);
            let findings = super::run_rules(&prepared).findings;
            packages.push(Package {
                kind: package.kind,
                name: package.name.clone(),
                files: package
                    .files
                    .iter()
                    .map(|file| file.refreshed(package, &prepared, &findings))
                    .collect::<Result<Vec<AcceptedFile>>>()?,
            });
        }
        Ok(Allowance {
            ruleset: RULESET_VERSION,
            packages,
        })
    }
}

/// Whether one of the `open` rows, each with its file's path, accepts
/// `finding`, closing the row that does.
fn take(open: &mut Vec<(&str, &Accepted)>, prepared: &Prepared, finding: &Finding) -> bool {
    let Some((path, doc)) = located(prepared, &finding.location) else {
        return false;
    };
    let Some(line_hash) = line_hash(doc, finding) else {
        return false;
    };
    let row = open.iter().position(|(at, row)| {
        *at == path
            && row.rule == finding.rule
            && row.line_hash == line_hash
            && row.message == finding.message
    });
    row.map(|index| open.swap_remove(index)).is_some()
}

impl AcceptedFile {
    /// This file's rows read again off the prepared package: per rule the
    /// findings, one per row, each keyed by its line's text. The one
    /// statement of what refuses a listed file, by name: a path the package
    /// does not hold as a text file; a rule whose findings in the file are
    /// not as many as its rows, since a finding that is gone is a row nobody
    /// should still carry and one that appeared is a row nobody accepted; or
    /// a finding under a listed rule at no line, which no row can name.
    /// Only the count is compared, so a swap is not refused: one accepted
    /// finding gone and another of its rule new in the same file. The
    /// committed-table test then fails on the new line's hash, and the
    /// refresh rewrites the row to that line, a change the reviewer of the
    /// `allowance.toml` diff sees.
    fn refreshed(
        &self,
        package: &Package,
        prepared: &Prepared,
        findings: &[Finding],
    ) -> Result<AcceptedFile> {
        let refuse = |why: String| CoreError::Authoring {
            message: format!(
                "the accepted-findings table names {} {} at {}, {why}",
                package.kind.name(),
                package.name,
                self.path
            ),
        };
        let held = prepared
            .docs
            .iter()
            .any(|doc| located(prepared, &doc.location).is_some_and(|(at, _)| at == self.path));
        if !held {
            return Err(refuse(
                "which the package does not hold as a text file".to_owned(),
            ));
        }
        // Every rule the rows name, once each, in whatever order the rows
        // were written: a hand-written table may interleave them.
        let mut rules: Vec<&str> = self.accepted.iter().map(|row| row.rule.as_str()).collect();
        rules.sort_unstable();
        rules.dedup();
        let mut accepted = Vec::with_capacity(self.accepted.len());
        for rule in rules {
            let listed = self.accepted.iter().filter(|row| row.rule == rule).count();
            let found: Vec<(&Finding, &Doc)> = findings
                .iter()
                .filter(|finding| finding.rule == rule)
                .filter_map(|finding| {
                    let (at, doc) = located(prepared, &finding.location)?;
                    (at == self.path).then_some((finding, doc))
                })
                .collect();
            if found.len() != listed {
                return Err(refuse(format!(
                    "with {listed} accepted {rule} finding(s), and the file now holds {}",
                    found.len()
                )));
            }
            for (finding, doc) in found {
                let Some(line_hash) = line_hash(doc, finding) else {
                    return Err(refuse(format!(
                        "with an accepted {rule} finding the file raises at no line, which no row can name"
                    )));
                };
                accepted.push((
                    finding.line,
                    Accepted {
                        rule: finding.rule.clone(),
                        line_hash,
                        message: finding.message.clone(),
                    },
                ));
            }
        }
        // Rows in the order the file holds their lines, whatever the table
        // had.
        accepted.sort_by(|(a_line, a), (b_line, b)| {
            a_line.cmp(b_line).then_with(|| a.rule.cmp(&b.rule))
        });
        Ok(AcceptedFile {
            path: self.path.clone(),
            accepted: accepted.into_iter().map(|(_, row)| row).collect(),
        })
    }
}

/// The tree file a finding fired in, as the table names it: its path
/// inside the package, and the document. `None` for a finding outside a
/// tree: a package that is one file, a hook's command line or stored
/// values, a config entry.
fn located<'a>(prepared: &'a Prepared, location: &str) -> Option<(&'a str, &'a Doc)> {
    let doc = prepared.docs.iter().find(|doc| doc.location == location)?;
    let inside = place_within(&doc.location, &prepared.input.location)?.strip_prefix('/')?;
    Some((inside, doc))
}

/// The key a row names `finding` by: the hash of the line it fired on, as
/// `doc` was written. `None` for a finding at no line, such as the report
/// that a file reads differently than it looks, which no row accepts.
fn line_hash(doc: &Doc, finding: &Finding) -> Option<String> {
    let index = usize::try_from(finding.line?).ok()?.checked_sub(1)?;
    let line = doc.written.lines().nth(index)?;
    Some(crate::hash::hash_bytes(line.as_bytes()))
}
