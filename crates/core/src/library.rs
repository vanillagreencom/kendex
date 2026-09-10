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
    /// What tells this observation from another the scan saw under the
    /// same scope, kind, name and tool — because it does see two: a tool
    /// reads both a shared skill root and one of its own, and one registry
    /// file holds every hook entry a tool runs.
    ///
    /// For an artifact of its own that is where it sits. For an entry
    /// inside a shared file it is that file and the action the entry runs,
    /// since the file is every entry's. Compared, never parsed: it is one
    /// opaque spelling of "which observation is this", and `None` on a row
    /// a record seeded for an installation the scan did not see.
    pub at: Option<String>,
    pub origin: Origin,
    /// What the author says this package does, written for a person
    /// browsing — the one field every surface showing an installed
    /// package's own words reads.
    ///
    /// The words the package's own declaration writes, and the
    /// observation's own header where no declaration answers: a file a
    /// tool holds is what that tool loads, not what the author wrote
    /// about the package — an entry in a config file records how to reach
    /// a server, an agent's frontmatter carries the line its harness
    /// selects on, and a generated wrapper carries kendex's own. `None`
    /// says the author wrote nothing reachable, and that is a supported
    /// state — a command, a URL, a path, a script body or a line kendex
    /// built is never promoted into a sentence about the package.
    ///
    /// Author text, so it arrives shown-safe: a control, invisible or
    /// direction-flipping character is here as its escape, never as
    /// itself.
    pub summary: Option<String>,
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
type RowKey = (Scope, ItemKind, String, HarnessId, Option<String>);

/// What is known about one such installation: where it came from, which
/// package it is when the records establish one, and what that package
/// says about itself.
struct RowFacts {
    origin: Origin,
    package: Option<PackageRef>,
    summary: Option<String>,
}

impl ProvenanceRow {
    /// The package this row is about: the one the records establish, or
    /// what the scan saw where they establish none.
    ///
    /// What every consumer speaking about packages asks — a catalog holds
    /// a hook under the name it was declared as, never under the
    /// `safety-…` rule a tool stores it in, so looking one up by the
    /// observed spelling searches for something that was never there.
    /// Anything reading the bytes on disk wants [`ProvenanceRow::at`]
    /// instead, which is where they are.
    pub fn package_ref(&self) -> PackageRef {
        self.package.clone().unwrap_or(PackageRef {
            kind: self.kind,
            name: self.name.clone(),
        })
    }
}

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
    let mut headers = crate::source::header::DeclaredHeaders::default();
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
        let claimed = index.of(&item);
        let package = claimed.as_ref().map(|(package, _)| package.clone());
        let origin = observed_origin(env, records, &item, claimed.as_ref());
        let summary = observed_summary(env, &mut headers, records, &item, package.as_ref());
        // Keyed by which observation it is as well: a tool reads more than
        // one root and one registry file holds every entry, so two things
        // it finds under one name are two installations rather than one
        // row that has to pick an origin between them.
        let at = item.at.clone();
        rows.entry((item.scope, item.kind, item.name, item.harness, Some(at)))
            .or_insert(RowFacts {
                origin,
                package,
                summary,
            });
    }
    // A record seeded a row for every installation it holds, so that one
    // the scan cannot see is still visible. Where the scan DID see it, that
    // observation is the row — it carries the position, and the seeded one
    // would stand beside it saying the same thing about no file.
    let observed_packages: std::collections::BTreeSet<_> = rows
        .iter()
        .filter(|((.., at), _)| at.is_some())
        .filter_map(|((scope, .., harness, _), facts)| {
            facts
                .package
                .as_ref()
                .map(|package| (scope.clone(), package.clone(), *harness))
        })
        .collect();
    rows.retain(|(scope, kind, name, harness, at), _| {
        at.is_some()
            || !observed_packages.contains(&(
                scope.clone(),
                PackageRef {
                    kind: *kind,
                    name: name.clone(),
                },
                *harness,
            ))
    });
    seeded_summaries(env, &mut headers, &records_by_scope, &mut rows);
    for (scope, records) in &records_by_scope {
        if let Some(problem) = &records.record_problem {
            let recovered = rows.iter().any(|((row_scope, ..), facts)| {
                row_scope == scope && facts.origin != Origin::Unmanaged
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
        .map(|((scope, kind, name, harness, at), facts)| ProvenanceRow {
            scope,
            kind,
            name,
            harness,
            at,
            origin: facts.origin,
            // Author text, escaped once for every row here rather than at
            // each path that fills one: a control character would act on
            // the surface drawing it, and an invisible or
            // direction-flipping one would let one package's line read as
            // another's. `source::browse` escapes the same text for the
            // marketplace row, so one package version reads the same in
            // both places.
            summary: facts.summary.as_deref().map(crate::names::shown),
            package: facts.package,
        })
        .collect())
}

/// What one observed installation's package says about itself: the words
/// the declaration it belongs to writes, else the words the observation
/// itself carries.
///
/// The declaration's source is where the author wrote about the package;
/// the file on disk is what a harness loads. They are not the same text
/// and several kinds keep only the second: an MCP server is an entry in a
/// tool's config file, a plugin is a folder of somebody else's code, an
/// agent's rendered frontmatter carries the `description` its harness
/// selects on, a Codex command is a wrapper kendex generated, and a
/// Cursor hook is a rule file kendex titled. Reading the installed file
/// first would answer for one package version in as many voices as there
/// are tools holding it — and one of those voices is kendex's own.
///
/// Asked of the package the records establish and never of the observed
/// spelling — a name two packages share is no evidence that either wrote
/// this one. Where nothing declared answers — content nobody manages, an
/// observation the records tie to no package, a source this machine
/// cannot reach — the observation's own words stand.
fn observed_summary(
    env: &Env,
    headers: &mut crate::source::header::DeclaredHeaders,
    records: &crate::ownership::Records,
    item: &crate::model::ObservedItem,
    package: Option<&PackageRef>,
) -> Option<String> {
    match declared_header(env, headers, records, item, package) {
        Some(header) => header.summary_or_description().map(str::to_owned),
        None => item.summary.clone(),
    }
}

/// The header of the package one observation belongs to, out of the
/// source its scope declared it from. `None` where no declaration of it
/// can be reached, which is not the same as a declaration that says
/// nothing: an author who wrote no words leaves a blank row, and nothing
/// downstream may fill that blank from the file a tool reads.
fn declared_header(
    env: &Env,
    headers: &mut crate::source::header::DeclaredHeaders,
    records: &crate::ownership::Records,
    item: &crate::model::ObservedItem,
    package: Option<&PackageRef>,
) -> Option<crate::scan::metadata::Metadata> {
    let package = package?;
    let manifest = records.manifest.as_deref()?;
    let installed = installed_from(records, package.kind, &package.name, item.harness);
    headers.of(
        env,
        &item.scope,
        manifest,
        package.kind,
        &package.name,
        installed.as_ref(),
    )
}

/// What one installation's own record says it came from. `None` where no
/// record claims it — content nobody installed, or one this build wrote
/// before the field existed — and the current declaration answers then,
/// because it is all there is to go on.
fn installed_from(
    records: &crate::ownership::Records,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> Option<crate::source::header::InstalledFrom> {
    let entry = records
        .lock
        .entries
        .get(&crate::lock::entry_key(kind, name, harness))?;
    Some(crate::source::header::InstalledFrom {
        source: entry.source.clone(),
        repo: entry.source_repo.clone(),
        commit: entry.source_commit.clone(),
    })
}

/// The words for every row the scan could not see.
///
/// Only a seeded row, whose name IS the declared one: an observed row is
/// named however its tool stores the package, and looking a declaration up
/// under that spelling is the mistake the identity join exists to stop —
/// its own words were settled in [`observed_summary`], through the package
/// the records established. Run after the sweep that drops the seeded rows
/// the scan also saw, so a catalog is read only for a row that survived.
fn seeded_summaries(
    env: &Env,
    headers: &mut crate::source::header::DeclaredHeaders,
    records_by_scope: &BTreeMap<Scope, crate::ownership::Records>,
    rows: &mut BTreeMap<RowKey, RowFacts>,
) {
    for ((scope, kind, name, harness, at), facts) in rows {
        if at.is_some() || facts.summary.is_some() {
            continue;
        }
        let Some(records) = records_by_scope.get(scope) else {
            continue;
        };
        let Some(manifest) = records.manifest.as_deref() else {
            continue;
        };
        let installed = installed_from(records, *kind, name, *harness);
        facts.summary = headers
            .of(env, scope, manifest, *kind, name, installed.as_ref())
            .and_then(|header| header.summary_or_description().map(str::to_owned));
    }
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
            (
                scope.clone(),
                entry.kind,
                entry.name.clone(),
                entry.harness,
                None,
            ),
            RowFacts {
                origin: origin_of(
                    manifest,
                    entry.kind,
                    &entry.name,
                    &entry.source,
                    &entry.source_repo,
                ),
                package: Some(PackageRef {
                    kind: entry.kind,
                    name: entry.name.clone(),
                }),
                // Filled after the sweep below drops the seeded rows the
                // scan also saw: only an installation nothing observed
                // keeps one, and reading a catalog for the rest would pay
                // for every row twice.
                summary: None,
            },
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
    claimed: Option<&identity::Claim>,
) -> Origin {
    // The record that CLAIMED this position, not one held for the tool that
    // observed it. A shared tree is written once and read by several tools,
    // so most readers have no record of their own — asking for one would
    // call the writer's own file unmanaged everywhere but at the writer.
    let recorded = claimed.and_then(|(_, key)| {
        records.lock.entries.get(key).map(|entry| {
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
