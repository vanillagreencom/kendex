//! Pre-install safety on catalog bytes: the same rules an install runs,
//! scored once per resolved commit and cached beside the store receipt.
//!
//! The cache holds findings and scores only. The warn/block verdict is
//! derived from the current thresholds at read time — thresholds in the key
//! would re-score on every settings change and imply a different analysis
//! where only the judgment moved. A cached entry is verified before reuse:
//! the item's content hash is recomputed from the catalog bytes, so a
//! parser change that moves bytes between items re-scores, and so does any
//! bump of the rule set, the discovery table, or the record format below.
//! Browse is a preview of the same verdict, never a second gate — a
//! held-back item still installs through the normal gate. That means it
//! reads the publisher's committed review the same way the gate does: the
//! cache holds what the rules found, and both the thresholds and the
//! publisher's record are applied at read time, so a review recorded after
//! the score was cached takes effect without re-scoring anything.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::ItemKind;
use crate::quality::author::{AuthorDismissal, AuthorReview};
use crate::quality::{
    AuditInput, Content, Finding, QualityScore, RULESET_VERSION, SafetyScore, SkippedRule,
    TreeFile, Verdict,
};
use crate::source::DISCOVERY_VERSION;

use super::{Browsed, Catalog};

/// The shape of one cached record — the scanner/parser half of the cache
/// key, beside the rule-set and discovery-table versions. Bump it when what
/// the record holds, or how the input is read into it, changes.
const CACHE_FORMAT: u32 = 1;

/// What one scoring pass produced, exactly as it is cached: everything but
/// the verdict, which is a judgment the thresholds pass at read time.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CachedScore {
    format: u32,
    content_hash: String,
    ruleset: u32,
    discovery: u32,
    findings: Vec<Finding>,
    safety: SafetyScore,
    quality: Option<QualityScore>,
    skipped: Vec<SkippedRule>,
}

/// One offered package's scores and the verdict today's thresholds give
/// them — the dot in the Packages table and the findings on the
/// available-package page.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct PackageSafety {
    pub kind: ItemKind,
    pub name: String,
    /// Every finding, each carrying whatever has already been decided about
    /// it. One row, not two arrays a reader has to keep in step by index.
    pub findings: Vec<PackageFinding>,
    pub safety: SafetyScore,
    /// Advisory, never blocking.
    pub quality: Option<QualityScore>,
    pub skipped: Vec<SkippedRule>,
    pub verdict: Verdict,
    pub reasons: Vec<String>,
    pub content_hash: String,
    pub ruleset: u32,
    /// Whether a verified cache entry answered instead of a fresh score.
    pub from_cache: bool,
    /// Who recorded the settled findings, when this package carries any.
    pub publisher: Option<String>,
}

/// One finding on an offered package, with the publisher's record about it
/// when they have one. A settled finding is reported here and does not
/// count toward the score or the verdict — the same answer the install
/// gate gives, which is the only reason this preview is worth showing.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct PackageFinding {
    #[serde(flatten)]
    pub finding: Finding,
    pub settled: Option<AuthorDismissal>,
}

pub fn package_safety(
    env: &Env,
    catalog: &Catalog,
    kind: ItemKind,
    name: &str,
) -> Result<PackageSafety> {
    let browsed = super::open(env, catalog)?;
    let item = item(&browsed, kind, name)?;
    let (score, from_cache) = scored(env, &browsed, kind, name, &item)?;
    let read = published(&browsed, kind, name, &item);
    let review = read.review;
    let judged = judge(env, &score, review.as_ref())?;
    let findings = score
        .findings
        .into_iter()
        .zip(judged.settled)
        .map(|(finding, settled)| PackageFinding {
            settled: settled
                .and_then(|fingerprint| review.as_ref()?.dismissed.get(&fingerprint).cloned()),
            finding,
        })
        .collect();
    let mut reasons = judged.reasons;
    // The preview reads the catalog, and this project adds its own text to
    // what installs. Nobody has scored that combination yet, so the page
    // says what it did not read rather than letting the number it shows be
    // read as the one the install will give.
    if let Some(why) = &read.stale {
        reasons.push(crate::names::shown(&format!(
            "this catalog reviewed {name}, but that review no longer applies — {why}"
        )));
    }
    if injected_here(&browsed.manifest, kind, name) {
        reasons.push(format!(
            "this project adds its own instructions to {name}; they are not in this preview and are scored when it installs"
        ));
    }
    if let Some(problem) = &browsed.reviews_unreadable {
        reasons.push(format!(
            "{} could not be read, so nothing this catalog reviewed counts as reviewed — {problem}",
            crate::check_catalog::dismissals::REVIEWS_FILE
        ));
    }
    Ok(PackageSafety {
        kind,
        name: name.to_owned(),
        findings,
        safety: judged.safety,
        quality: score.quality,
        skipped: score.skipped,
        verdict: judged.verdict,
        reasons,
        content_hash: score.content_hash,
        ruleset: score.ruleset,
        from_cache,
        publisher: review.map(|review| review.publisher),
    })
}

/// The verdict alone, for the installed-state join.
pub(super) fn verdict_for(
    env: &Env,
    browsed: &Browsed,
    kind: ItemKind,
    name: &str,
) -> Result<Verdict> {
    let item = item(browsed, kind, name)?;
    let (score, _) = scored(env, browsed, kind, name, &item)?;
    let review = published(browsed, kind, name, &item).review;
    Ok(judge(env, &score, review.as_ref())?.verdict)
}

/// What today's thresholds and the publisher's record make of a scored
/// package. The one derivation the gate, the audit and the authoring check
/// use, so browse cannot preview a verdict the install will not give.
struct Judged {
    verdict: Verdict,
    reasons: Vec<String>,
    safety: SafetyScore,
    /// The fingerprint that settled each finding, in `findings` order.
    settled: Vec<Option<String>>,
}

fn judge(env: &Env, score: &CachedScore, review: Option<&AuthorReview>) -> Result<Judged> {
    let thresholds = crate::settings::load(env)?.safety;
    // Nothing has been added to these bytes yet — no project instructions,
    // no split — so every occurrence in them is the publisher's own and
    // their record speaks for all of them, exactly as it does in the
    // catalog's own check.
    let budget = review.map(AuthorReview::whole_budget).unwrap_or_default();
    // Nothing settled means nothing to re-derive: the cached score is what
    // the rules found, and it stays the record that answers. Re-deriving it
    // here would make the cache a set of findings the score is recomputed
    // from, which is not what the record vouches for.
    if budget.is_empty() {
        let (verdict, reasons) =
            crate::quality::verdict(&score.findings, &score.safety, thresholds);
        return Ok(Judged {
            verdict,
            reasons,
            safety: score.safety.clone(),
            settled: vec![None; score.findings.len()],
        });
    }
    let scored = crate::quality::author::score(&score.findings, &budget);
    let (verdict, reasons) = crate::quality::verdict(&scored.counted, &scored.safety, thresholds);
    let settled = score
        .findings
        .iter()
        .zip(&scored.settled)
        .map(|(finding, settled)| settled.then(|| finding.fingerprint()))
        .collect();
    Ok(Judged {
        verdict,
        reasons,
        safety: scored.safety,
        settled,
    })
}

/// Whether this project contributes text to this item's rendering. The
/// same tables `gate::input::authored_for` classifies kinds by, read from
/// the other side: browse scores catalog bytes, which carry none of it.
fn injected_here(manifest: &crate::manifest::Manifest, kind: ItemKind, name: &str) -> bool {
    let named = |table: &std::collections::BTreeMap<String, String>| {
        [name, "all", "*"]
            .iter()
            .any(|key| table.contains_key(*key))
    };
    match kind {
        ItemKind::Skill => named(&manifest.skill_instructions),
        ItemKind::Agent => {
            named(&manifest.agent_launch_instructions)
                || named(&manifest.agent_additional_instructions)
        }
        ItemKind::Command
        | ItemKind::Hook
        | ItemKind::McpServer
        | ItemKind::Plugin
        | ItemKind::PiExtension => false,
    }
}

/// The publisher's record for this package, re-checked against the catalog
/// bytes in front of us — the same read the plan does.
fn published(
    browsed: &Browsed,
    kind: ItemKind,
    name: &str,
    item: &Item,
) -> crate::quality::author::Read {
    crate::quality::author::for_item_read(
        &browsed.reviews,
        kind,
        name,
        crate::quality::author::content_hash_of(&browsed.sealed, &item.path, item.tree.as_deref()),
        &browsed.source.provenance,
    )
}

fn scored(
    env: &Env,
    browsed: &Browsed,
    kind: ItemKind,
    name: &str,
    item: &Item,
) -> Result<(CachedScore, bool)> {
    let input = input_for(browsed, kind, name, item)?;
    let content_hash = crate::engine::content_hash(&input);
    let cache = cache_path(env, browsed, kind, name);
    if let Some(path) = &cache
        && let Some(hit) = verified(path, &content_hash)
    {
        return Ok((hit, true));
    }
    let result = crate::quality::audit(input);
    let fresh = CachedScore {
        format: CACHE_FORMAT,
        content_hash,
        ruleset: result.ruleset,
        discovery: DISCOVERY_VERSION,
        findings: result.findings,
        safety: result.safety,
        quality: result.quality,
        skipped: result.skipped,
    };
    if let Some(path) = &cache {
        // Best-effort: an unwritable cache costs the next call a re-score,
        // never the answer.
        if let Ok(text) = serde_json::to_string(&fresh) {
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let _ = crate::fs::atomic_write(path, &text);
        }
    }
    Ok((fresh, false))
}

/// A cached record, only if every part of its key still holds. Anything
/// less — unparsable text, an older format, moved content — reads as a
/// miss, and the re-score overwrites it.
fn verified(path: &std::path::Path, content_hash: &str) -> Option<CachedScore> {
    let text = std::fs::read_to_string(path).ok()?;
    let hit: CachedScore = serde_json::from_str(&text).ok()?;
    (hit.format == CACHE_FORMAT
        && hit.ruleset == RULESET_VERSION
        && hit.discovery == DISCOVERY_VERSION
        && hit.content_hash == content_hash)
        .then_some(hit)
}

/// Where this item's record lives — beside the commit's receipt in the
/// store. `None` where there is nothing immutable to key by: a path source
/// can change under the same identity, so it is scored fresh each time.
/// Only a remote resolves to a commit, and its provenance is the repository
/// the store keys by, so a repository browsed before subscribing and the
/// subscription that follows share one record per commit.
fn cache_path(env: &Env, browsed: &Browsed, kind: ItemKind, name: &str) -> Option<PathBuf> {
    let commit = browsed.source.commit.as_ref()?;
    let key = crate::remote::cache_key(env, &browsed.source.provenance);
    // The name is flattened for the filesystem; the hash keeps two names
    // one filesystem would fold together from sharing a record.
    Some(
        crate::remote::store::safety_cache_dir(env, &key, commit)
            .join(kind.name())
            .join(format!(
                "{}-{}.json",
                name.replace('/', "__"),
                crate::hash::fnv1a_hex(name.as_bytes())
            )),
    )
}

/// This item's own path in the catalog, and its whole tree where it has
/// one. Read once per call and handed to everything that needs those bytes:
/// scoring, the cache key, and the hash a publisher's record binds to all
/// answer for the same read.
struct Item {
    path: PathBuf,
    tree: Option<Vec<(PathBuf, Vec<u8>)>>,
}

fn item(browsed: &Browsed, kind: ItemKind, name: &str) -> Result<Item> {
    let Some(path) = crate::source::find_item(&browsed.sealed, &browsed.config, kind, name) else {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: browsed.source.name.clone(),
        });
    };
    let tree = match kind == ItemKind::Skill {
        true => Some(browsed.sealed.collect_skill_tree(&path)?),
        false => None,
    };
    Ok(Item { path, tree })
}

/// The same typed input `check --catalog` audits: a skill's whole tree,
/// one document for every file-per-item kind.
fn input_for(browsed: &Browsed, kind: ItemKind, name: &str, item: &Item) -> Result<AuditInput> {
    let path = &item.path;
    let location = path
        .strip_prefix(browsed.sealed.root())
        .unwrap_or(path)
        .display()
        .to_string();
    let content = match kind {
        ItemKind::Skill => Content::SkillTree {
            files: item
                .tree
                .iter()
                .flatten()
                .map(|(rel, bytes)| TreeFile::read(rel.clone(), bytes))
                .collect(),
        },
        // A hook's script is what the harness runs; browse scores it as a hook
        // so the rules that read event/command/script fire here too, not only
        // at the install gate. The MCP declaration and command bodies read as
        // their file text; the install gate stays the authoritative verdict.
        ItemKind::Hook => Content::Hook {
            event: String::new(),
            matcher: None,
            command: location.clone(),
            script: Some(browsed.sealed.read_to_string(path)?),
        },
        _ => Content::Document {
            text: browsed.sealed.read_to_string(path)?,
        },
    };
    Ok(AuditInput {
        kind,
        name: name.to_owned(),
        harness: None,
        location,
        content,
    })
}
