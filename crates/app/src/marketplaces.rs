//! The Marketplaces pages' commands: every subscription with what its
//! catalog says about itself, one catalog's packages and curated sets, a
//! package's preview beside its safety verdict, installing, subscribing, and
//! the Library's From column — thin shells over core, like every other
//! command here. Reads take a [`Catalog`]: a subscription, or a repository
//! opened from the Community tab before subscribing.

use kendex_core::apply;
use kendex_core::engine::ops::{self as engine_ops, AddRequest};
use kendex_core::env::Env;
use kendex_core::library::{self, ProvenanceRow};
use kendex_core::manifest::{Manifest, ManifestFile, manifest_path};
use kendex_core::model::{ItemKind, Scope};
use kendex_core::source::browse::{
    self, AvailablePackage, BundleDetail, Catalog, CatalogSummary, PackagePreview, PackageSafety,
};
use kendex_core::source::{CatalogFinding, CatalogMode, MarketplaceMeta, SourceConfig};
use kendex_core::source_ops;
use kendex_core::source_read::SealedSource;
use serde::{Deserialize, Serialize};
use specta::Type;

fn env() -> Result<Env, String> {
    Env::detect().map_err(|e| e.to_string())
}

fn all_scopes(env: &Env) -> Result<Vec<Scope>, String> {
    let settings = kendex_core::settings::load(env).map_err(|e| e.to_string())?;
    let mut scopes = vec![Scope::Global];
    scopes.extend(
        settings
            .projects
            .into_iter()
            .map(|root| Scope::Project { root }),
    );
    Ok(scopes)
}

/// The scope's manifest for reading. Browsing observes: an old-generation
/// manifest reads as empty rather than blocking the page.
fn manifest_for_reading(env: &Env, scope: &Scope) -> Result<Manifest, String> {
    match kendex_core::manifest::load(&manifest_path(env, scope)).map_err(|e| e.to_string())? {
        ManifestFile::Current(manifest) => Ok(*manifest),
        _ => Ok(Manifest::default()),
    }
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
}

/// Every subscription across every scope — the Marketplaces page's one
/// query.
#[tauri::command(async)]
#[specta::specta]
pub fn marketplaces_overview() -> Result<Vec<MarketplaceRow>, String> {
    let env = env()?;
    let mut rows = Vec::new();
    for scope in all_scopes(&env)? {
        for row in source_ops::list_subscriptions(&env, &scope).map_err(|e| e.to_string())? {
            let config = open_catalog(&env, &scope, &row.name).ok().map(|(_, c)| c);
            rows.push(MarketplaceRow {
                scope: row.scope,
                name: row.name,
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

/// One curated set with per-member installed state.
#[tauri::command(async)]
#[specta::specta]
pub fn marketplace_bundle(catalog: Catalog, name: String) -> Result<BundleDetail, String> {
    let env = env()?;
    browse::bundle(&env, &catalog, &name).map_err(|e| e.to_string())
}

/// The available-package page's one payload: the preview beside the safety
/// verdict the same content would face at install.
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
) -> Result<PackageView, String> {
    let env = env()?;
    let preview =
        browse::package_preview(&env, &catalog, kind, &name).map_err(|e| e.to_string())?;
    let safety = browse::package_safety(&env, &catalog, kind, &name).map_err(|e| e.to_string())?;
    Ok(PackageView { preview, safety })
}

/// One selected package, by the kind and name the catalog offers it under.
#[derive(Debug, Clone, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct InstallItem {
    pub kind: ItemKind,
    pub name: String,
}

/// Install packages or a curated set from one subscription. `destination`
/// redirects the install from the scope being browsed into a project: the
/// project gains the personal subscription first (§4.1), then the add runs
/// there — every write lands in exactly one scope.
#[tauri::command(async)]
#[specta::specta]
pub fn marketplace_install(
    scope: Scope,
    source: String,
    items: Vec<InstallItem>,
    bundle: Option<String>,
    destination: Option<Scope>,
    hold: bool,
) -> Result<Vec<AvailablePackage>, String> {
    if items.is_empty() && bundle.is_none() {
        return Err("nothing selected to install".to_owned());
    }
    let env = env()?;
    let target = destination.unwrap_or_else(|| scope.clone());
    let redirected = target != scope;
    if redirected {
        if !matches!(&target, Scope::Project { .. }) {
            return Err("an install can only be redirected into a project".to_owned());
        }
        if scope != Scope::Global {
            return Err("only a personal subscription can install into a project".to_owned());
        }
    }
    let mut request = AddRequest {
        source: Some(source.clone()),
        hold,
        ..AddRequest::default()
    };
    request.bundles.extend(bundle);
    for item in items {
        match item.kind {
            ItemKind::Agent => request.agents.push(item.name),
            ItemKind::Skill => request.skills.push(item.name),
            ItemKind::Hook => request.hooks.push(item.name),
            ItemKind::Command => request.commands.push(item.name),
            ItemKind::McpServer => request.mcp_servers.push(item.name),
            // A plugin is its registry's curated set, so it installs as one.
            ItemKind::Plugin => request.bundles.push(item.name),
            // Passed through so the engine's uniform refusal answers it.
            ItemKind::PiExtension => request.pi_extensions.push(item.name),
        }
    }
    // A whole set carries its own members; expanding agents' skills on top
    // would install beyond what the set declares.
    request.no_auto_skills = !request.bundles.is_empty();
    // Redirected into a project, the subscription and the packages are one
    // plan: a refused install leaves the project subscribed to nothing.
    let report = match &target {
        Scope::Project { root } if redirected => {
            source_ops::install_project_from_personal(&env, root, &source, &request)
        }
        _ => engine_ops::add(&env, &target, &request),
    }
    .map_err(|e| e.to_string())?;
    apply::execute(&env, &report.plan, None).map_err(|e| e.to_string())?;
    marketplace_packages(Catalog::Subscription {
        scope: target,
        source,
    })
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
    apply::execute(&env, &subscribed.report.plan, None).map_err(|e| e.to_string())?;
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
