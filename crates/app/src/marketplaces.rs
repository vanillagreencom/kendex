//! The Marketplaces pages' commands: every subscription with what its
//! catalog says about itself, one catalog's packages and curated sets, a
//! package's preview beside its safety score, installing, subscribing, and
//! the Library's From column — thin shells over core, like every other
//! command here. Reads take a [`Catalog`]: a subscription, or a repository
//! opened from the Community tab before subscribing.

use kendex_core::env::Env;
use kendex_core::library::{self, ProvenanceRow};
use kendex_core::manifest::{Manifest, manifest_path};
use kendex_core::model::{ItemKind, Scope};
use kendex_core::source::browse::{
    self, AvailablePackage, BundleDetail, Catalog, CatalogSummary, PackagePreview, PackageSafety,
};
use kendex_core::source::{CatalogFinding, CatalogMode, MarketplaceMeta, SourceConfig};
use kendex_core::source_ops;
use kendex_core::source_read::SealedSource;
use serde::Serialize;
use specta::Type;

pub mod install;

use crate::scopes::{all as all_scopes, env};

fn manifest_for_reading(env: &Env, scope: &Scope) -> Result<Manifest, String> {
    Ok(
        kendex_core::manifest::load_current(&manifest_path(env, scope))
            .map_err(|e| e.to_string())?
            .unwrap_or_default(),
    )
}

/// One subscription's catalog opened for reading, or the error that says
/// why its content is unreachable right now.
fn open_catalog(
    env: &Env,
    scope: &Scope,
    source: &str,
) -> Result<(SealedSource, SourceConfig), String> {
    let manifest = manifest_for_reading(env, scope)?;
    let ready = kendex_core::source::require_ready(env, scope, source, &manifest)
        .map_err(|e| e.to_string())?;
    let sealed = SealedSource::open(&ready.root).map_err(|e| e.to_string())?;
    let config = kendex_core::source::source_config(
        &sealed,
        kendex_core::source::repo_leaf(&ready.provenance),
    )
    .map_err(|e| e.to_string())?;
    Ok((sealed, config))
}

/// One subscription as the Marketplaces page lists it: what it points at,
/// how many packages it offers per kind, and what the catalog states about
/// itself where its bytes are readable.
#[derive(Debug, Clone, PartialEq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct MarketplaceRow {
    pub scope: Scope,
    pub name: String,
    pub repo: Option<String>,
    /// The canonical `owner/repo` a GitHub declaration folds to — what a
    /// directory row is matched against, however the subscription spells it.
    pub repo_key: Option<String>,
    /// One string per repository on any host, from
    /// [`kendex_core::source_ref::repo_identity`] — the same value
    /// subscription dedup and update grouping compare. `repo_key` answers
    /// only for GitHub, so it cannot tell two marketplaces apart anywhere
    /// else; this is what a surface folding declarations into one
    /// marketplace has to key on.
    pub repo_identity: Option<String>,
    pub path: Option<String>,
    pub rev: Option<String>,
    /// The commit the subscription reads right now, when the cache holds one.
    pub commit: Option<String>,
    pub enabled: bool,
    /// Packages offered, by kind name — absent until the catalog has been
    /// fetched and can be read.
    pub counts: Option<std::collections::BTreeMap<String, u32>>,
    /// `[marketplace]` from the catalog's kendex.toml, where readable.
    pub meta: Option<MarketplaceMeta>,
    /// How the catalog's items were decided, where readable.
    pub mode: Option<CatalogMode>,
    /// This row's scope has no readable lock, so every installed state it
    /// alone would settle reads Unknown. Carried on the row rather than
    /// joined from the updates read: the Packages tab says so above its
    /// table, and a fact that arrives with the rows it describes is
    /// refreshed by the same read instead of by another surface's clock.
    pub records_unreadable: bool,
}

/// Every subscription across every scope — the Marketplaces page's one
/// query.
#[tauri::command(async)]
#[specta::specta]
pub fn marketplaces_overview() -> Result<Vec<MarketplaceRow>, String> {
    let env = env()?;
    rows(&env, &all_scopes(&env)?)
}

/// Every subscription in the scopes given, each row carrying its scope's
/// own record standing. Separate from the command so the join above — a
/// row's `records_unreadable` against the scope it came from — is reachable
/// from a test, the way [`crate::update_check::overview`] is.
pub fn rows(env: &Env, scopes: &[Scope]) -> Result<Vec<MarketplaceRow>, String> {
    let mut rows = Vec::new();
    for scope in scopes {
        let records_unreadable = browse::records_unreadable(env, scope);
        for row in source_ops::list_subscriptions(env, scope).map_err(|e| e.to_string())? {
            let config = open_catalog(env, scope, &row.name).ok().map(|(_, c)| c);
            rows.push(MarketplaceRow {
                scope: row.scope,
                name: row.name,
                repo_key: row
                    .repo
                    .as_deref()
                    .and_then(kendex_core::source_ref::owner_repo),
                repo_identity: row
                    .repo
                    .as_deref()
                    .map(kendex_core::source_ref::repo_identity),
                repo: row.repo,
                path: row.path,
                rev: row.rev,
                commit: row.commit,
                enabled: row.enabled,
                counts: row.counts.map(|counts| {
                    counts
                        .into_iter()
                        .map(|(kind, count)| (kind, count.min(u32::MAX as usize) as u32))
                        .collect()
                }),
                meta: config.as_ref().and_then(|c| c.marketplace.clone()),
                mode: config.as_ref().map(|c| c.mode),
                records_unreadable,
            });
        }
    }
    Ok(rows)
}

/// Every package one catalog offers, across kinds, with installed state
/// joined in.
#[tauri::command(async)]
#[specta::specta]
pub fn marketplace_packages(catalog: Catalog) -> Result<Vec<AvailablePackage>, String> {
    let env = env()?;
    browse::packages(&env, &catalog).map_err(|e| e.to_string())
}

/// What a catalog says about itself, fetched fresh for a repository nobody
/// subscribes to — the marketplace page's header, and the subscription to
/// carry on as when this machine already holds one.
#[tauri::command(async)]
#[specta::specta]
pub fn marketplace_summary(catalog: Catalog) -> Result<CatalogSummary, String> {
    let env = env()?;
    browse::summary(&env, &catalog).map_err(|e| e.to_string())
}

/// Every curated set a catalog declares, with per-member installed state —
/// what the marketplace page's Bundles tab lists.
#[tauri::command(async)]
#[specta::specta]
pub fn marketplace_bundles(catalog: Catalog) -> Result<Vec<BundleDetail>, String> {
    let env = env()?;
    browse::bundles(&env, &catalog).map_err(|e| e.to_string())
}

/// One curated set with per-member installed state.
#[tauri::command(async)]
#[specta::specta]
pub fn marketplace_bundle(catalog: Catalog, name: String) -> Result<BundleDetail, String> {
    let env = env()?;
    browse::bundle(&env, &catalog, &name).map_err(|e| e.to_string())
}

/// The available-package page's one payload: the preview beside the safety
/// score the same content would earn at install.
#[derive(Debug, Clone, PartialEq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct PackageView {
    pub preview: PackagePreview,
    pub safety: PackageSafety,
}

#[tauri::command(async)]
#[specta::specta]
pub fn marketplace_package_preview(
    catalog: Catalog,
    kind: ItemKind,
    name: String,
    destination: Option<Scope>,
) -> Result<PackageView, String> {
    let env = env()?;
    let preview = browse::package_preview(&env, &catalog, kind, &name, destination.as_ref())
        .map_err(|e| e.to_string())?;
    let safety = browse::package_safety(&env, &catalog, kind, &name).map_err(|e| e.to_string())?;
    Ok(PackageView { preview, safety })
}

/// One offered file's content before install — the same read an installed
/// package's file gets, confined to the package inside the catalog.
#[tauri::command(async)]
#[specta::specta]
pub fn marketplace_package_file(
    catalog: Catalog,
    kind: ItemKind,
    name: String,
    path: String,
) -> Result<kendex_core::engine::ItemSource, String> {
    let env = env()?;
    browse::package_file(&env, &catalog, kind, &name, &path).map_err(|e| e.to_string())
}

/// What subscribing declared, after the plan ran.
#[derive(Debug, Clone, PartialEq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SubscribeOutcome {
    pub name: String,
    /// The declared repository or path.
    pub reference: String,
    pub rev: Option<String>,
    /// The package a tree or skills.sh URL was leading to — where the app
    /// opens next, never an identity.
    pub lead: Option<String>,
    pub notes: Vec<String>,
    /// What a package leaving with this plan had undone, if one did. Its
    /// own field rather than more notes, so the account a removal owes has
    /// one name across every command that can make one.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub undone: Vec<String>,
}

/// Subscribe a scope to a marketplace: `owner/repo[@rev]`, a git URL, a
/// GitHub tree URL, a skills.sh package URL, or a local folder.
#[tauri::command(async)]
#[specta::specta]
pub fn marketplace_subscribe(
    scope: Scope,
    reference: String,
    name: Option<String>,
) -> Result<SubscribeOutcome, String> {
    let env = env()?;
    let subscribed = source_ops::subscribe(&env, &scope, &reference, name.as_deref())
        .map_err(|e| e.to_string())?;
    // Through the one executor, like every report, precisely because no
    // path can prove its own plan takes nothing away. Orphan removal being
    // off does not settle it: a rendering the engine refuses drops the
    // package's lock entry regardless, and its uninstaller runs.
    let undone = crate::repo_effects::write(&env, &subscribed.report)?;
    let mut notes = subscribed.report.notes;
    // Fetch so counts and browsing land right away; a failure costs the
    // counts, never the subscription — the CLI verb behaves the same.
    if let Ok(Some(manifest)) =
        kendex_core::manifest::load_for_mutation(&manifest_path(&env, &scope))
        && let Some(decl) = manifest.sources.get(&subscribed.name)
        && let Some(repo) = decl.repo.clone()
        && let Err(error) = kendex_core::remote::sync(&env, &repo, decl.rev.as_deref())
    {
        notes.push(format!("not fetched yet ({error})"));
    }
    Ok(SubscribeOutcome {
        name: subscribed.name,
        reference: subscribed.reference,
        rev: subscribed.rev,
        lead: subscribed.lead,
        notes,
        undone,
    })
}

/// One About row: what was found under one root.
#[derive(Debug, Clone, PartialEq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct AboutFound {
    pub root: String,
    pub kind: ItemKind,
    pub count: u32,
}

/// The About tab's report: how the catalog's items were decided, what was
/// found where, and everything wrong with it.
#[derive(Debug, Clone, PartialEq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct AboutView {
    pub mode: CatalogMode,
    pub found: Vec<AboutFound>,
    pub findings: Vec<CatalogFinding>,
}

#[tauri::command(async)]
#[specta::specta]
pub fn marketplace_about(catalog: Catalog) -> Result<AboutView, String> {
    let env = env()?;
    let about = browse::about(&env, &catalog).map_err(|e| e.to_string())?;
    Ok(AboutView {
        mode: about.mode,
        found: about
            .found
            .into_iter()
            .map(|row| AboutFound {
                root: row.root,
                kind: row.kind,
                count: row.count.min(u32::MAX as usize) as u32,
            })
            .collect(),
        findings: about.findings,
    })
}

/// Where every installation came from, across every scope — the Library
/// table's From column in one query.
#[tauri::command(async)]
#[specta::specta]
pub fn library_provenance() -> Result<Vec<ProvenanceRow>, String> {
    let env = env()?;
    let scopes = all_scopes(&env)?;
    library::provenance(&env, &scopes).map_err(|e| e.to_string())
}
