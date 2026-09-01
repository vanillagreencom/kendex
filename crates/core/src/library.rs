//! Where each installation came from — one lock+manifest join the Library
//! table reads for its From column.
//!
//! The lock is the durable provenance record (invariant 4), so it decides:
//! an entry from a reserved source — `local`, or `in-place` for a project
//! skill adopted where it sits — is the user's own content, forked when
//! `[forks]` says what it replaced, and any other entry names the
//! subscription it installed from. What the scanner observes and the
//! lock cannot account for is unmanaged, reported and never touched.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::Result;
use crate::lock::LockFile;
use crate::manifest::{INPLACE_SOURCE_NAME, LOCAL_SOURCE_NAME, Manifest};
use crate::model::{HarnessId, ItemKind, Scope};

/// Where one installation came from.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(
    tag = "origin",
    rename_all = "kebab-case",
    rename_all_fields = "camelCase"
)]
pub enum Origin {
    /// Installed from a subscription: its declared alias and its repository
    /// (or path) as the lock recorded them.
    Marketplace { source: String, repo: String },
    /// The user's own content — adopted or forked (`forked_from` names what
    /// a fork replaced), with `source` naming the reserved source that holds
    /// it: `local` for a capture, `in-place` for a tree read where it sits.
    Own {
        forked_from: Option<String>,
        source: String,
    },
    /// On disk and observed, managed by nothing.
    Unmanaged,
}

/// One installation's origin, keyed the way the Library table joins it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ProvenanceRow {
    pub scope: Scope,
    pub kind: ItemKind,
    pub name: String,
    pub harness: HarnessId,
    pub origin: Origin,
}

/// Every installation's origin across the given scopes — one row per
/// (scope, kind, name, harness), lock records outranking observation.
pub fn provenance(env: &Env, scopes: &[Scope]) -> Result<Vec<ProvenanceRow>> {
    let scopes: Vec<Scope> = scopes.iter().map(Scope::canonical).collect();
    let mut rows: BTreeMap<(Scope, ItemKind, String, HarnessId), Origin> = BTreeMap::new();
    for scope in &scopes {
        let manifest = crate::manifest::load_current(&crate::manifest::manifest_path(env, scope))?
            .unwrap_or_default();
        let LockFile::Current(lock) = crate::lock::load_file(&crate::lock::lock_path(env, scope))?
        else {
            continue;
        };
        for entry in lock.entries.values() {
            rows.insert(
                (scope.clone(), entry.kind, entry.name.clone(), entry.harness),
                origin_of(&manifest, entry),
            );
        }
    }
    let settings = crate::settings::load(env)?;
    let observed = crate::scan::scan_scopes(env, &settings.harness_roots, &scopes);
    for item in observed.items {
        // Vendor-shipped content belongs to the tool, is already labelled
        // with who ships it, and is nobody's to manage — calling it
        // unmanaged would offer an adoption nobody should take.
        if item.vendor.is_some() {
            continue;
        }
        rows.entry((item.scope, item.kind, item.name, item.harness))
            .or_insert(Origin::Unmanaged);
    }
    Ok(rows
        .into_iter()
        .map(|((scope, kind, name, harness), origin)| ProvenanceRow {
            scope,
            kind,
            name,
            harness,
            origin,
        })
        .collect())
}

fn origin_of(manifest: &Manifest, entry: &crate::lock::LockEntry) -> Origin {
    if entry.source == LOCAL_SOURCE_NAME || entry.source == INPLACE_SOURCE_NAME {
        return Origin::Own {
            source: entry.source.clone(),
            forked_from: manifest
                .forks
                .get(&entry.kind)
                .and_then(|forks| forks.get(&entry.name))
                .map(|fork| fork.repo.clone().unwrap_or_else(|| fork.source.clone())),
        };
    }
    Origin::Marketplace {
        source: entry.source.clone(),
        repo: entry.source_repo.clone(),
    }
}

#[cfg(test)]
mod tests;
