//! The per-marketplace summary the community directory consumes — what
//! `kendex index --json` emits and the site's indexer POSTs onward.
//!
//! Everything here reads through the same core the app and the engine use:
//! [`super::list_items`] decides what is offered, [`crate::check_catalog`]
//! decides the verdicts, [`super::about()`] says what was found where. That
//! is the invariant the directory rests on — what the site says a
//! marketplace offers is exactly what subscribing finds. Every string is
//! catalog text: capped and control-char-safe before it leaves this module.

use serde::Serialize;

use crate::check_catalog;
use crate::error::Result;
use crate::model::ItemKind;
use crate::quality::Verdict;
use crate::source_read::SealedSource;
use crate::tags::Tag;

use super::bundles;
use super::meta::safe_text;

pub const INDEX_SCHEMA: u32 = 1;

const MAX_TEXT: usize = 200;
const MAX_DESCRIPTION: usize = 500;

/// The whole summary. Field order is the JSON field order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MarketplaceIndex {
    pub schema: u32,
    pub name: String,
    pub description: Option<String>,
    pub author: Option<String>,
    pub license: Option<String>,
    pub homepage: Option<String>,
    pub tags: Vec<String>,
    pub counts: IndexCounts,
    pub checked: IndexChecked,
    pub packages: Vec<IndexPackage>,
    pub bundles: Vec<IndexBundle>,
    pub found: Vec<IndexFound>,
    pub findings: Vec<IndexFinding>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub struct IndexCounts {
    pub packages: usize,
    pub bundles: usize,
}

/// The check verdicts over everything offered, the numbers a directory row
/// shows beside the counts.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub struct IndexChecked {
    pub breakage: usize,
    pub held_back: usize,
    pub warned: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct IndexPackage {
    pub kind: &'static str,
    pub name: String,
    pub description: Option<String>,
    pub tags: Vec<Tag>,
    pub safety: IndexSafety,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct IndexSafety {
    pub score: u32,
    pub verdict: Verdict,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct IndexBundle {
    pub name: String,
    pub description: Option<String>,
    pub version: Option<String>,
    pub members: Vec<IndexMember>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct IndexMember {
    pub kind: &'static str,
    pub name: String,
}

/// One About row: what was found under one root.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct IndexFound {
    pub root: String,
    pub kind: &'static str,
    pub count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct IndexFinding {
    pub location: String,
    pub problem: String,
    pub fix: String,
}

/// Summarize one marketplace directory. `display` names the repository the
/// way [`super::source_config`] wants it — the repo leaf.
///
/// The item set, the findings and the counts all come from one
/// [`check_catalog::check_with`] run — the same answer `kendex check`
/// gives, so the directory can never call clean what the check fails.
pub fn index(sealed: &SealedSource, display: &str) -> Result<MarketplaceIndex> {
    let config = super::source_config(sealed, display)?;
    let about = super::about(sealed, &config);
    let report = check_catalog::check_with(sealed, &config, display)?;
    let findings: Vec<IndexFinding> = report
        .catalog
        .iter()
        .map(|finding| IndexFinding {
            location: safe_text(&finding.file, MAX_TEXT),
            problem: safe_text(&finding.message, MAX_DESCRIPTION),
            fix: safe_text(&finding.fix, MAX_DESCRIPTION),
        })
        .collect();
    let tally = report.tally();
    let checked = IndexChecked {
        breakage: tally.breakage,
        held_back: tally.held_back,
        warned: tally.warned,
    };
    let mut packages = Vec::new();
    for item in &report.items {
        let path = sealed.root().join(&item.file);
        let (description, tags) = describe(sealed, item.kind, &path)?;
        packages.push(IndexPackage {
            kind: item.kind.name(),
            name: safe_text(&item.name, MAX_TEXT),
            description,
            tags,
            safety: IndexSafety {
                score: item.score,
                verdict: item.verdict,
            },
        });
    }
    let bundles = bundle_rows(sealed, &config)?;
    let meta = config.marketplace.clone().unwrap_or_default();
    Ok(MarketplaceIndex {
        schema: INDEX_SCHEMA,
        name: meta.name.unwrap_or_else(|| safe_text(display, MAX_TEXT)),
        description: meta.description,
        author: meta.author,
        license: meta.license,
        homepage: meta.homepage,
        tags: meta.tags,
        counts: IndexCounts {
            packages: packages.len(),
            bundles: bundles.len(),
        },
        checked,
        packages,
        bundles,
        found: about
            .found
            .iter()
            .map(|row| IndexFound {
                root: safe_text(&row.root, MAX_TEXT),
                kind: row.kind.name(),
                count: row.count,
            })
            .collect(),
        findings,
    })
}

fn bundle_rows(sealed: &SealedSource, config: &super::SourceConfig) -> Result<Vec<IndexBundle>> {
    Ok(bundles::offered(sealed, config)?
        .into_iter()
        .map(|bundle| IndexBundle {
            name: safe_text(&bundle.name, MAX_TEXT),
            description: bundle
                .description
                .map(|text| safe_text(&text, MAX_DESCRIPTION)),
            version: bundle.version.map(|text| safe_text(&text, MAX_TEXT)),
            members: bundle
                .members
                .into_iter()
                .map(|member| IndexMember {
                    kind: member.kind.name(),
                    name: safe_text(&member.name, MAX_TEXT),
                })
                .collect(),
        })
        .collect())
}

/// What the item says about itself: a description and the tags its header
/// carries. Read through the sealed source, decoded lossily — a header is
/// worth reading even beside one bad byte, and the safety pass has already
/// reported that byte.
fn describe(
    sealed: &SealedSource,
    kind: ItemKind,
    path: &std::path::Path,
) -> Result<(Option<String>, Vec<Tag>)> {
    let file = match kind {
        ItemKind::Skill => path.join("SKILL.md"),
        ItemKind::Agent | ItemKind::Command | ItemKind::McpServer => path.to_path_buf(),
        _ => return Ok((None, Vec::new())),
    };
    if !sealed.is_file(&file) {
        return Ok((None, Vec::new()));
    }
    let text = String::from_utf8_lossy(&sealed.read(&file)?).into_owned();
    let meta = match kind {
        ItemKind::McpServer => crate::scan::metadata::from_toml(&text),
        _ => crate::scan::metadata::from_markdown(&text),
    };
    Ok((
        meta.description
            .map(|text| safe_text(&text, MAX_DESCRIPTION)),
        meta.tags,
    ))
}
