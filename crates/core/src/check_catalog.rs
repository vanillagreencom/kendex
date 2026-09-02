//! Authoring validation over a catalog directory: what a maintainer can
//! know about their own content before anyone installs it.
//!
//! Three passes over every item. The structural pass asks whether each
//! harness's loader could hold this item at all — a name it will not
//! accept, a SKILL.md that disagrees with its own directory. The settings
//! pass reads a settings template against the grammar the shell loaders
//! read a consumer's settings file with. The safety pass runs the same
//! rules an install runs, so a catalog finds out in its own CI rather than
//! in somebody else's plan preview.
//!
//! Every pass only reports what an author can act on. Anything rendering
//! resolves on its own is not a problem this can help with, and naming it
//! would send people to fix something that is not broken.
//!
//! This lives in core because the CLI's `check --catalog`, the indexer's
//! per-package scores, and authoring preflight all ask the same questions
//! of the same bytes — one implementation, one answer.

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::error::Result;
use crate::model::{HarnessId, ItemKind};
use crate::quality::{self, AuditInput, Content};
use crate::render::validate;
use crate::source::{CatalogMode, SourceConfig};
use crate::source_read::SealedSource;

mod settings;
pub use settings::SETTINGS_PASS;

/// The versioned envelope `check --catalog --json` and `marketplace mine
/// --json` wrap their reports in. Schema 3 counts safety findings as
/// `safety_findings`, carries no per-finding token, and `ok` answers what
/// fails the run — breakage, plus advisories under `--strict` — never a
/// safety finding. Schema 2 spelled a finding's line into `file`; schema 3
/// keeps `file` a path and puts the line in `line`, which is a change of
/// meaning in a field that was already there, not an addition.
pub const CHECK_SCHEMA: u32 = 3;

/// The `pass` a safety finding carries; a structural finding carries the
/// harness whose loader complained, and a settings finding
/// [`SETTINGS_PASS`].
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
    /// The file this is about, as a path within the catalog: joined to the
    /// catalog's path it is something a viewer opens, which is what the
    /// Mine row's Open does with it. A line goes in `line`, never here. Two
    /// values are not paths and cannot be: an item listed that cannot be
    /// read names what was listed, and the safety pass writes a
    /// sub-location — `PATH (command)`, `PATH (entry)`, `PATH (env KEY)`,
    /// `PATH (header KEY)` — for the parts of a hook or MCP entry that are
    /// no file at all. Those are the only shapes, nothing parses them back,
    /// and there is no path in them to find.
    pub file: String,
    /// The 1-based line within `file`, where the finding has one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    pub kind: &'static str,
    pub name: String,
    /// The harness whose loader complains, [`SETTINGS_PASS`], or [`SAFETY_PASS`].
    pub pass: String,
    /// `error`/`warning` for structural and settings findings; the safety
    /// severity (`low`..`critical`) for safety findings.
    pub severity: &'static str,
    /// The safety rule that fired; `None` otherwise.
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

/// One item, every pass run over it.
///
/// `advisory` sits under its own key rather than flattened because nothing
/// serializes this struct: it derives neither `Serialize` nor `Type`.
/// Whatever first gives it a serialized form flattens it there, so its
/// fields read at the top-level paths `ItemSafety` and `PackageSafety`
/// already serve, and leaves `structural` under its own key — it and the
/// safety payload answer different questions a reader has to tell apart.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckedItem {
    pub kind: ItemKind,
    pub name: String,
    /// The item's own path within the catalog.
    pub file: String,
    /// Would each harness's loader accept this item, and does its settings
    /// template read as the shell loaders read it?
    pub structural: Vec<CheckFinding>,
    /// The safety pass, the same payload every other score surface embeds.
    pub advisory: quality::AuditResult,
}

impl CheckedItem {
    /// Every finding as a report row: `structural` first, then safety. The
    /// one adapter from the advisory payload to the report shape — a safety
    /// finding's `remediation` becomes `fix`, and its location and line
    /// carry across as the two values they already are.
    pub fn rows(&self) -> impl Iterator<Item = CheckFinding> + '_ {
        self.structural
            .iter()
            .cloned()
            .chain(self.advisory.findings.iter().map(|finding| CheckFinding {
                file: finding.location.clone(),
                line: finding.line,
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

    /// How many problems fail the run: breakage always, advisories only
    /// under `strict`. Safety findings fail nothing — the score is
    /// advisory end to end, in a catalog's own CI included.
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
            line: None,
            kind: CATALOG_PASS,
            name: display.to_owned(),
            pass: CATALOG_PASS.to_owned(),
            // A set whose body will not read installs nothing, which is what
            // this check exits non-zero for. The catalog around it is usable,
            // so its mode cannot say so and the finding carries it instead.
            severity: match config.mode == CatalogMode::Unusable || finding.breakage {
                true => "error",
                false => "warning",
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
                    line: None,
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
    let file = crate::paths::slashed(path.strip_prefix(sealed.root()).unwrap_or(path));
    let mut structural = structural(kind, name, &file, &content);
    structural.extend(settings::findings(sealed, kind, name, &file, path)?);
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
    let leaf = crate::names::leaf(name);
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
            line: None,
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
