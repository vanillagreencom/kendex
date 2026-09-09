//! The Library origin column uses the shared read-only ownership resolver.
//! Durable records outrank declarations and installed metadata. Recovered
//! origin identifies a source; it never grants permission to overwrite files.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::Result;
use crate::manifest::{INPLACE_SOURCE_NAME, LOCAL_SOURCE_NAME, Manifest};
use crate::model::{HarnessId, ItemKind, Scope};

mod identity;
pub use identity::PackageRef;

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

/// One installation's origin and identity, keyed the way the Library table
/// joins it: by what the scan observed, which is what a reader has in hand.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ProvenanceRow {
    pub scope: Scope,
    pub kind: ItemKind,
    pub name: String,
    pub harness: HarnessId,
    pub origin: Origin,
    /// Which package this installation is, where the records establish
    /// one. `None` says they do not: the observation keeps its own
    /// identity and stays distinct from every other, because a name two
    /// things share is no evidence that either wrote the file. Nothing may
    /// read the absence as unmanaged content — that is what [`Origin`]
    /// answers.
    pub package: Option<PackageRef>,
}

/// One installation as the Library joins it: where it is, what the scan
/// called it, and which tool holds it.
type RowKey = (Scope, ItemKind, String, HarnessId);

/// What is known about one such installation: where it came from, and
/// which package it is when the records establish one.
type RowFacts = (Origin, Option<PackageRef>);

/// Every installation's origin across the given scopes — one row per
/// (scope, kind, name, harness), lock records outranking observation.
pub fn provenance(env: &Env, scopes: &[Scope]) -> Result<Vec<ProvenanceRow>> {
    let scopes: Vec<Scope> = scopes.iter().map(Scope::canonical).collect();
    let mut rows: BTreeMap<RowKey, RowFacts> = BTreeMap::new();
    let mut records_by_scope = BTreeMap::new();
    let mut index_by_scope = BTreeMap::new();
    for scope in &scopes {
        let records = crate::ownership::read(env, scope);
        recorded(scope, &records, &mut rows);
        index_by_scope.insert(scope.clone(), identity::index(env, scope, &records.lock));
        records_by_scope.insert(scope.clone(), records);
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
        let Some(records) = records_by_scope.get_mut(&item.scope) else {
            unreachable!("every observed scope was requested");
        };
        let Some(index) = index_by_scope.get(&item.scope) else {
            unreachable!("every observed scope was indexed");
        };
        let package = index.of(&item);
        let origin = observed_origin(env, records, &item, package.as_ref());
        rows.entry((item.scope, item.kind, item.name, item.harness))
            .or_insert((origin, package));
    }
    for (scope, records) in &records_by_scope {
        if let Some(problem) = &records.record_problem {
            let recovered = rows.iter().any(|((row_scope, ..), (origin, _))| {
                row_scope == scope && *origin != Origin::Unmanaged
            });
            if !recovered {
                return Err(crate::error::CoreError::LockCorrupt {
                    path: crate::lock::lock_path(env, scope),
                    message: problem.clone(),
                });
            }
        }
    }
    Ok(rows
        .into_iter()
        .map(
            |((scope, kind, name, harness), (origin, package))| ProvenanceRow {
                scope,
                kind,
                name,
                harness,
                origin,
                package,
            },
        )
        .collect())
}

/// A row for every installation this scope's record holds, under the
/// identity it was declared as. An installation the scan cannot see is
/// still one this scope installed, and the record is what says so.
fn recorded(
    scope: &Scope,
    records: &crate::ownership::Records,
    rows: &mut BTreeMap<RowKey, RowFacts>,
) {
    let empty = Manifest::default();
    let manifest = records.manifest.as_deref().unwrap_or(&empty);
    for entry in records.lock.entries.values() {
        rows.insert(
            (scope.clone(), entry.kind, entry.name.clone(), entry.harness),
            (
                origin_of(
                    manifest,
                    entry.kind,
                    &entry.name,
                    &entry.source,
                    &entry.source_repo,
                ),
                Some(PackageRef {
                    kind: entry.kind,
                    name: entry.name.clone(),
                }),
            ),
        );
    }
}

/// Where one observed installation came from.
///
/// Which package it is settles that: what a tool stores a hook or a
/// command as is its own business, and reading the origin off the stored
/// spelling is how one marketplace package comes to read as somebody's
/// unmanaged file. Only where the records establish no package does this
/// fall back to the shared resolver, which searches by the observed name.
fn observed_origin(
    env: &Env,
    records: &mut crate::ownership::Records,
    item: &crate::model::ObservedItem,
    package: Option<&PackageRef>,
) -> Origin {
    let recorded = package.and_then(|package| {
        records
            .lock
            .entries
            .get(&crate::lock::entry_key(
                package.kind,
                &package.name,
                item.harness,
            ))
            .map(|entry| {
                (
                    entry.kind,
                    entry.name.clone(),
                    entry.source.clone(),
                    entry.source_repo.clone(),
                )
            })
    });
    let empty = Manifest::default();
    if let Some((kind, name, source, repo)) = recorded {
        return origin_of(
            records.manifest.as_deref().unwrap_or(&empty),
            kind,
            &name,
            &source,
            &repo,
        );
    }
    crate::ownership::find(
        env,
        &item.scope,
        records,
        crate::ownership::Subject::Observed(item),
    )
    .map_or(Origin::Unmanaged, |evidence| {
        origin_of(
            records.manifest.as_deref().unwrap_or(&empty),
            item.kind,
            &item.name,
            &evidence.source,
            &evidence.repo,
        )
    })
}

fn origin_of(manifest: &Manifest, kind: ItemKind, name: &str, source: &str, repo: &str) -> Origin {
    if source == LOCAL_SOURCE_NAME || source == INPLACE_SOURCE_NAME {
        return Origin::Own {
            source: source.to_owned(),
            forked_from: manifest
                .forks
                .get(&kind)
                .and_then(|forks| forks.get(name))
                .map(|fork| fork.repo.clone().unwrap_or_else(|| fork.source.clone())),
        };
    }
    Origin::Marketplace {
        source: source.to_owned(),
        repo: repo.to_owned(),
    }
}

#[cfg(test)]
mod tests;
