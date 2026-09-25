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
//! carry one. Each row names a package, a file inside it by the hash of
//! its text, and the finding by rule, line and message. A finding is
//! accepted only for an item whose source is kendex's own catalog
//! ([`Publisher::Kendex`]), where the file the rules read has exactly the
//! recorded text, under the rule set the rows were accepted for. The same
//! bytes from another catalog, an edited copy, a hand-placed copy and a
//! rule change all leave the finding where it is. The table is refreshed
//! from the catalog, never widened by it, and
//! `crates/core/tests/allowance.rs` holds it current.

use std::sync::LazyLock;

use serde::{Deserialize, Serialize};

use crate::error::{CoreError, Result};
use crate::model::ItemKind;
use crate::source::SourceConfig;
use crate::source_read::SealedSource;

use super::{Finding, Prepared, RULESET_VERSION, place_within};

/// The compiled-in table, as text: the cache key reads its digest.
pub const ALLOWANCE_TEXT: &str = include_str!("allowance.toml");

/// The header every refresh writes above the table.
const HEADER: &str = "\
# Findings kendex accepts in its own packages, one row per finding, keyed
# on the text of the file holding it. A row is added by hand and reviewed
# with the finding it accepts; `cargo test -p kendex-core -- --ignored
# regenerate_allowance` refreshes the hash, line and message of the rows
# already here and refuses a row whose finding is gone, and
# `crates/core/tests/allowance.rs` fails while the table is stale. Read by
# `crates/core/src/quality/allowance.rs`.

";

/// Whose bytes an input is, as far as the table is concerned: kendex's
/// own catalog, or anyone else's. Decided once from the item's recorded
/// source by [`Publisher::of`]; an item with no recorded source (a
/// hand-placed copy, a catalog checked by directory name) is
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
    /// nothing else: the one answer every reader of a local catalog (the
    /// authoring check, the directory index, the Mine row) gives, so a
    /// checkout of kendex's own repository reads as kendex's in each and a
    /// folder with no git, no repository or no `origin` is nobody's.
    pub fn of_checkout(root: &std::path::Path) -> Publisher {
        crate::author::status::origin_url(root).map_or(Publisher::Other, |url| Publisher::of(&url))
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

/// One file of a package, by the text the rules read, and the findings
/// accepted in it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
pub struct AcceptedFile {
    /// The file's `/`-spelled path inside the package's tree, the one
    /// spelling a row carries: a package that is one file, and the
    /// labelled documents beside a hook's script, are never accepted.
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
    /// kendex's own item every acceptance is by exact text: the file the
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
        let honoured =
            prepared.input.publisher == Publisher::Kendex && self.ruleset == RULESET_VERSION;
        let (Some(package), true) = (package, honoured) else {
            return (findings, Vec::new());
        };
        findings
            .into_iter()
            .partition(|finding| !package.accepts(prepared, finding))
    }

    /// This table with every row read again off the catalog at `sealed`:
    /// each file's hash, and each row's line and message, as the finding
    /// stands there now, the rows of a file in line order. A row is never
    /// added; a listed file whose findings under a row's rule are not one
    /// per row is refused by name, since a finding that is gone is a row
    /// nobody should still carry, and one that appeared is a row nobody
    /// accepted.
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

impl AcceptedFile {
    /// This file's rows read again off the prepared package: the text's
    /// digest, and per rule the findings in line order, one per row.
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
        let Some(digest) = prepared.docs.iter().find_map(|doc| {
            (located(prepared, &doc.location)?.0 == self.path).then(|| doc.digest.clone())
        }) else {
            return Err(refuse(
                "which the package does not hold as a text file".to_owned(),
            ));
        };
        // Every rule the rows name, once each, in whatever order the rows
        // were written: a hand-written table may interleave them.
        let mut rules: Vec<&str> = self.accepted.iter().map(|row| row.rule.as_str()).collect();
        rules.sort_unstable();
        rules.dedup();
        let mut accepted = Vec::with_capacity(self.accepted.len());
        for rule in rules {
            let listed = self.accepted.iter().filter(|row| row.rule == rule).count();
            let found: Vec<&Finding> = findings
                .iter()
                .filter(|finding| {
                    finding.rule == rule
                        && located(prepared, &finding.location)
                            .is_some_and(|(at, _)| at == self.path)
                })
                .collect();
            if found.len() != listed {
                return Err(refuse(format!(
                    "with {listed} accepted {rule} finding(s), and the file now holds {}",
                    found.len()
                )));
            }
            accepted.extend(found.into_iter().map(|finding| Accepted {
                rule: finding.rule.clone(),
                line: finding.line,
                message: finding.message.clone(),
            }));
        }
        // Rows in the order the file holds them, whatever the table had.
        accepted.sort_by(|a, b| a.line.cmp(&b.line).then_with(|| a.rule.cmp(&b.rule)));
        Ok(AcceptedFile {
            path: self.path.clone(),
            hash: digest,
            accepted,
        })
    }
}

/// The tree file a finding fired in, as the table names it: its path
/// inside the package and the digest of its text. `None` for a finding
/// outside a tree: a package that is one file, a hook's command line or
/// stored values, a config entry.
fn located<'a>(prepared: &'a Prepared, location: &str) -> Option<(&'a str, &'a str)> {
    let doc = prepared.docs.iter().find(|doc| doc.location == location)?;
    let inside = place_within(&doc.location, &prepared.input.location)?.strip_prefix('/')?;
    Some((inside, doc.digest.as_str()))
}
