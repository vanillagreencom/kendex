//! Pre-install safety on catalog bytes: the same rules an install runs,
//! scored once per resolved commit and cached beside the store receipt.
//!
//! A cached entry is verified before reuse: the item's content hash is
//! recomputed from the catalog bytes, so a parser change that moves bytes
//! between items re-scores, and so does any bump of the rule set, the
//! discovery table, or the record format below. Advisory like every other
//! reading of the score — a preview, never a gate.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::ItemKind;
use crate::quality::{Finding, QualityScore, RULESET_VERSION, SafetyScore, SkippedRule};
use crate::source::DISCOVERY_VERSION;

use super::{Browsed, Catalog};

mod input;
use input::input_for;

/// The shape of one cached record — the scanner/parser half of the cache
/// key, beside the rule-set and discovery-table versions. Bump it when what
/// the record holds, or how the input is read into it, changes.
const CACHE_FORMAT: u32 = 3;

/// What one scoring pass produced, exactly as it is cached.
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

/// One offered package's advisory scores — the number in the Packages
/// table and the findings on the available-package page.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct PackageSafety {
    pub kind: ItemKind,
    pub name: String,
    pub findings: Vec<Finding>,
    pub safety: SafetyScore,
    /// Advisory like the safety score, and absent for kinds with no
    /// authored prose.
    pub quality: Option<QualityScore>,
    pub skipped: Vec<SkippedRule>,
    /// What this preview did not read — the number an install would give
    /// can differ, and the page says why rather than letting its own be
    /// read as that one.
    pub notes: Vec<String>,
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
    let item = item(&browsed, kind, name)?;
    let (score, from_cache) = scored(env, &browsed, kind, name, &item)?;
    // The preview reads the catalog, and this project adds its own text to
    // what installs. Nobody has scored that combination yet, so the page
    // says what it did not read.
    let mut notes = Vec::new();
    if injected_here(&browsed.manifest, kind, name) {
        notes.push(format!(
            "this project adds its own instructions to {name}; they are not in this preview and are scored when it installs"
        ));
    }
    Ok(PackageSafety {
        kind,
        name: name.to_owned(),
        findings: score.findings,
        safety: score.safety,
        quality: score.quality,
        skipped: score.skipped,
        notes,
        content_hash: score.content_hash,
        ruleset: score.ruleset,
        from_cache,
    })
}

/// Whether this project contributes anything to this item's rendering.
///
/// Asked of the same enumeration the rendering subtracts by, never of a
/// second transcription of it: two lists of one thing is how both ended up
/// missing the same entries. Browse scores catalog bytes, which carry none
/// of this, so the page says what it did not read rather than showing a
/// number the install will not give.
fn injected_here(manifest: &crate::manifest::Manifest, kind: ItemKind, name: &str) -> bool {
    match kind {
        ItemKind::Skill => [name, "all", "*"]
            .iter()
            .any(|key| manifest.skill_instructions.contains_key(*key)),
        // Any harness: the preview is not for one of them, and a project
        // that overrides frontmatter for a single tool still makes this
        // reading incomplete.
        ItemKind::Agent => crate::model::HarnessId::ALL
            .into_iter()
            .any(|harness| crate::engine::contributes_to_agent(manifest, harness, name)),
        ItemKind::Command
        | ItemKind::Hook
        | ItemKind::McpServer
        | ItemKind::Plugin
        | ItemKind::PiExtension => false,
    }
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

/// This item's own path in the catalog.
struct Item {
    path: PathBuf,
}

fn item(browsed: &Browsed, kind: ItemKind, name: &str) -> Result<Item> {
    let Some(path) = crate::source::find_item(&browsed.sealed, &browsed.config, kind, name) else {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: browsed.source.name.clone(),
        });
    };
    Ok(Item { path })
}
