//! Authoring validation over a catalog directory: what a maintainer can
//! know about their own content before anyone installs it.
//!
//! Two passes over every item. The structural pass asks whether each
//! harness's loader could hold this item at all — a name it will not
//! accept, a SKILL.md that disagrees with its own directory. The safety
//! pass runs the same rules an install runs, against the same content, so
//! a catalog finds out in its own CI rather than in somebody else's plan
//! preview.
//!
//! Both passes only report what an author can act on. Anything rendering
//! resolves on its own is not a problem this can help with, and naming it
//! would send people to fix something that is not broken.
//!
//! This lives in core because the CLI's `check --catalog`, the indexer's
//! per-package scores, and authoring preflight all ask the same two
//! questions of the same bytes — one implementation, one answer.

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::error::Result;
use crate::model::{HarnessId, ItemKind};
use crate::quality::{self, AuditInput, Content};
use crate::render::validate;
use crate::source::{CatalogMode, SourceConfig};
use crate::source_read::SealedSource;

/// The versioned envelope `check --catalog --json` and `marketplace mine
/// --json` wrap their reports in. Schema 2 counts safety findings as
/// `safety_findings`, carries no per-finding token, and `ok` answers what
/// fails the run — breakage, plus structural advisories under `--strict` —
/// never a safety finding.
pub const CHECK_SCHEMA: u32 = 2;

/// The `pass` a safety finding carries; structural findings carry the
/// harness whose loader complained.
pub const SAFETY_PASS: &str = "safety";

/// The `pass`/`kind` of a finding about the catalog itself rather than any
/// one item — a broken control file, a skipped colliding directory.
pub const CATALOG_PASS: &str = "catalog";

/// Every kind a catalog can offer, in report order.
const CHECKED_KINDS: [ItemKind; 5] = [
    ItemKind::Agent,
    ItemKind::Skill,
    ItemKind::Hook,
    ItemKind::Command,
    ItemKind::McpServer,
];

/// One problem either pass found, carrying everything a machine consumer
/// needs to place it. Field order is the JSON field order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CheckFinding {
    /// The file within the catalog — for safety findings, the rule's own
    /// location, which may name a file inside a skill tree.
    pub file: String,
    pub kind: &'static str,
    pub name: String,
    /// The harness whose loader complains, or [`SAFETY_PASS`].
    pub pass: String,
    /// `error`/`warning` for structural findings; the safety severity
    /// (`low`..`critical`) for safety findings.
    pub severity: &'static str,
    /// The safety rule that fired; `None` for structural findings.
    pub rule: Option<String>,
    pub message: String,
    pub fix: String,
}

impl CheckFinding {
    pub fn is_breakage(&self) -> bool {
        self.rule.is_none() && self.severity == "error"
    }

    /// Something the check is saying about itself rather than about the
    /// content — what it could not read, and why. There is nothing for a
    /// maintainer to fix, so it counts toward nothing and fails nothing;
    /// leaving it out entirely would be the check quietly not saying what
    /// it did not look at.
    pub fn is_note(&self) -> bool {
        self.rule.is_none() && self.severity == "note"
    }
}

/// One item with both passes run over it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckedItem {
    pub kind: ItemKind,
    pub name: String,
    /// The item's own path within the catalog.
    pub file: String,
    /// The structural pass: would each harness's loader accept this?
    pub structural: Vec<CheckFinding>,
    /// The safety pass, the same payload every other score surface embeds.
    pub advisory: quality::AuditResult,
}

impl CheckedItem {
    /// Every finding as a schema-2 row: structural first, then safety, in
    /// report order. This is the one adapter from the advisory payload to
    /// the report shape — a safety finding's `remediation` becomes `fix`,
    /// its `location` the row's `file`.
    pub fn rows(&self) -> impl Iterator<Item = CheckFinding> + '_ {
        self.structural
            .iter()
            .cloned()
            .chain(self.advisory.findings.iter().map(|finding| CheckFinding {
                file: finding.location.clone(),
                kind: self.kind.name(),
                name: self.name.clone(),
                pass: SAFETY_PASS.to_owned(),
                severity: finding.severity.name(),
                rule: Some(finding.rule.clone()),
                message: finding.message.clone(),
                fix: finding.remediation.clone(),
            }))
    }
}

/// What both passes over a whole catalog produced.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CatalogCheck {
    /// Findings about the catalog itself — its control file, its registry,
    /// its discovery — before any item is reached.
    pub catalog: Vec<CheckFinding>,
    pub items: Vec<CheckedItem>,
}

/// The counts the summary line and the exit code are made of.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CheckTally {
    pub items: usize,
    pub breakage: usize,
    pub advisory: usize,
    /// Safety findings across every item. Advisory everywhere — they fail
    /// nothing, under any flag.
    pub findings: usize,
}

impl CatalogCheck {
    pub fn tally(&self) -> CheckTally {
        let mut tally = CheckTally {
            items: self.items.len(),
            ..CheckTally::default()
        };
        for finding in &self.catalog {
            match (finding.is_note(), finding.is_breakage()) {
                (true, _) => {}
                (false, true) => tally.breakage += 1,
                (false, false) => tally.advisory += 1,
            }
        }
        for item in &self.items {
            for finding in &item.structural {
                match (finding.is_note(), finding.is_breakage()) {
                    (true, _) => {}
                    (false, true) => tally.breakage += 1,
                    (false, false) => tally.advisory += 1,
                }
            }
            tally.findings += item.advisory.findings.len();
        }
        tally
    }

    /// How many problems fail the run: breakage always, structural
    /// advisories only under `strict`. Safety findings fail nothing — the
    /// score is advisory end to end, in a catalog's own CI included.
    pub fn failing(&self, strict: bool) -> usize {
        let tally = self.tally();
        tally.breakage
            + match strict {
                true => tally.advisory,
                false => 0,
            }
    }

    pub fn findings(&self) -> impl Iterator<Item = CheckFinding> + '_ {
        self.catalog
            .iter()
            .cloned()
            .chain(self.items.iter().flat_map(CheckedItem::rows))
    }
}

/// Both passes over everything the catalog offers. `display` names a
/// one-skill repo whose SKILL.md does not name itself — pass the directory
/// or repository leaf.
pub fn check(sealed: &SealedSource, display: &str) -> Result<CatalogCheck> {
    let config = crate::source::source_config(sealed, display)?;
    check_with(sealed, &config, display)
}

/// Both passes over the items one already-read catalog offers. The item set
/// is the same `source_config`/discovery result browsing and indexing
/// consume, so the authoring check can never pass a repo that subscribing
/// would read differently.
pub fn check_with(
    sealed: &SealedSource,
    config: &SourceConfig,
    display: &str,
) -> Result<CatalogCheck> {
    let catalog = config
        .findings()
        .map(|finding| CheckFinding {
            file: finding.location.clone(),
            kind: CATALOG_PASS,
            name: display.to_owned(),
            pass: CATALOG_PASS.to_owned(),
            severity: match config.mode {
                CatalogMode::Unusable => "error",
                _ => "warning",
            },
            rule: None,
            message: finding.problem.clone(),
            fix: finding.fix.clone(),
        })
        .collect();
    let mut report = CatalogCheck {
        catalog,
        items: Vec::new(),
    };
    for kind in CHECKED_KINDS {
        for name in crate::source::list_items(sealed, config, kind) {
            match crate::source::find_item(sealed, config, kind, &name) {
                Some(path) => report.items.push(check_item(sealed, kind, &name, &path)?),
                // A listed name every lookup refuses (an illegal spelling,
                // say) is a catalog problem, not content to score.
                None => report.catalog.push(CheckFinding {
                    file: name.clone(),
                    kind: kind.name(),
                    name,
                    pass: CATALOG_PASS.to_owned(),
                    severity: "error",
                    rule: None,
                    message: format!("this {} is listed but cannot be read", kind.name()),
                    fix: "give it a plain installable name at the path the catalog declares"
                        .to_owned(),
                }),
            }
        }
    }
    Ok(report)
}

/// Both passes over one item at its catalog path — the unit the indexer
/// scores packages with.
pub fn check_item(
    sealed: &SealedSource,
    kind: ItemKind,
    name: &str,
    path: &Path,
) -> Result<CheckedItem> {
    let content = content(sealed, kind, path)?;
    let file = path
        .strip_prefix(sealed.root())
        .unwrap_or(path)
        .display()
        .to_string();
    let structural = structural(kind, name, &file, &content);
    // The safety half of the authoring check: the same rules an install
    // runs, over the same content.
    let advisory = quality::audit(AuditInput {
        kind,
        name: name.to_owned(),
        harness: None,
        location: file.clone(),
        content,
    });
    Ok(CheckedItem {
        kind,
        name: name.to_owned(),
        file,
        structural,
        advisory,
    })
}

/// A skill's whole tree; anything else is one file. Read through the same
/// constructor every install-side reading uses, over the same whole tree,
/// so this check scores the content the install-side passes read back.
fn content(sealed: &SealedSource, kind: ItemKind, path: &Path) -> Result<Content> {
    if kind != ItemKind::Skill {
        return Ok(Content::Document {
            text: sealed.read_to_string(path)?,
        });
    }
    if !sealed.is_dir(path) {
        return Ok(Content::Unread {
            why: "a skill is a directory holding SKILL.md",
        });
    }
    Ok(quality::observe::tree_content_from_bytes(
        &sealed.collect_skill_tree(path)?,
    ))
}

/// Would each harness's loader accept this?
///
/// Only what the author controls. Names are checked against every harness,
/// because a name is carried through untouched; a plugin-registry name is
/// checked by its leaf, since the plugin segment never becomes a filename.
/// A skill tree is checked once for the things its SKILL.md must say — that
/// it exists, that it names the directory it sits in, that it has a
/// description — and it is deliberately *not* checked against the tightest
/// body cap, because rendering splits an oversized skill into `references/`
/// before it reaches the tool that has that cap. Reporting it here would
/// name a problem the renderer has already solved and send an author off to
/// fix something that is not broken.
fn structural(kind: ItemKind, name: &str, file: &str, content: &Content) -> Vec<CheckFinding> {
    let leaf = crate::names::split(name).map_or(name, |(_, leaf)| leaf);
    let mut out = Vec::new();
    for harness in HarnessId::ALL {
        if !crate::harness::capabilities(harness, kind).install.global {
            continue;
        }
        let mut findings = validate::validate_name(harness, leaf);
        if let (Content::SkillTree { files }, HarnessId::Claude) = (content, harness) {
            let files: Vec<(PathBuf, Vec<u8>)> = files
                .iter()
                .map(|file| {
                    let bytes = file.text.clone().unwrap_or_default().into_bytes();
                    (file.path.clone(), bytes)
                })
                .collect();
            // Claude has no body cap, so this pass is the tree's own shape
            // and nothing about any one tool's limits.
            findings.extend(validate::validate_skill_tree(harness, leaf, leaf, &files));
        }
        out.extend(findings.into_iter().map(|finding| CheckFinding {
            file: file.to_owned(),
            kind: kind.name(),
            name: name.to_owned(),
            pass: harness.name().to_owned(),
            severity: match finding.is_breakage() {
                true => "error",
                false => "warning",
            },
            rule: None,
            message: finding.message,
            fix: finding.remediation,
        }));
    }
    out
}
