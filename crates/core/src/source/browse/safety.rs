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
//! held-back item still installs through the normal gate.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::ItemKind;
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
    pub findings: Vec<Finding>,
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
}

pub fn package_safety(
    env: &Env,
    catalog: &Catalog,
    kind: ItemKind,
    name: &str,
) -> Result<PackageSafety> {
    let browsed = super::open(env, catalog)?;
    let (score, from_cache) = scored(env, &browsed, kind, name)?;
    let thresholds = crate::settings::load(env)?.safety;
    let (verdict, reasons) = crate::quality::verdict(&score.findings, &score.safety, thresholds);
    Ok(PackageSafety {
        kind,
        name: name.to_owned(),
        findings: score.findings,
        safety: score.safety,
        quality: score.quality,
        skipped: score.skipped,
        verdict,
        reasons,
        content_hash: score.content_hash,
        ruleset: score.ruleset,
        from_cache,
    })
}

/// The verdict alone, for the installed-state join.
pub(super) fn verdict_for(
    env: &Env,
    browsed: &Browsed,
    kind: ItemKind,
    name: &str,
) -> Result<Verdict> {
    let (score, _) = scored(env, browsed, kind, name)?;
    let thresholds = crate::settings::load(env)?.safety;
    Ok(crate::quality::verdict(&score.findings, &score.safety, thresholds).0)
}

fn scored(env: &Env, browsed: &Browsed, kind: ItemKind, name: &str) -> Result<(CachedScore, bool)> {
    let input = input_for(browsed, kind, name)?;
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

/// The same typed input `check --catalog` audits: a skill's whole tree,
/// one document for every file-per-item kind.
fn input_for(browsed: &Browsed, kind: ItemKind, name: &str) -> Result<AuditInput> {
    let Some(path) = crate::source::find_item(&browsed.sealed, &browsed.config, kind, name) else {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: browsed.source.name.clone(),
        });
    };
    let location = path
        .strip_prefix(browsed.sealed.root())
        .unwrap_or(&path)
        .display()
        .to_string();
    let content = match kind {
        ItemKind::Skill => Content::SkillTree {
            files: browsed
                .sealed
                .collect_skill_tree(&path)?
                .into_iter()
                .map(|(rel, bytes)| TreeFile::read(rel, &bytes))
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
            script: Some(browsed.sealed.read_to_string(&path)?),
        },
        _ => Content::Document {
            text: browsed.sealed.read_to_string(&path)?,
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
