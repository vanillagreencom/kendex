use serde::Serialize;
use specta::Type;

mod repos;
pub use repos::{RepoSubscription, repo_subscriptions};

use crate::engine::{EngineReport, PlanOptions, plan_scope};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::lock::{load as load_lock, lock_path};
use crate::manifest::{self, Manifest};
use crate::model::Scope;

/// Everything the Sources page shows for one declared source in one scope.
#[derive(Debug, Clone, PartialEq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SourceRow {
    pub scope: Scope,
    pub name: String,
    pub reference: String,
    pub is_remote: bool,
    pub enabled: bool,
    /// Cache HEAD for remotes — freshness display.
    pub head: Option<String>,
    pub declared_items: Vec<String>,
}

fn referents(manifest: &Manifest, source: &str) -> Vec<String> {
    let mut names = Vec::new();
    for (table, items) in [
        ("agents", &manifest.agents),
        ("skills", &manifest.skills),
        ("hooks", &manifest.hooks),
        ("commands", &manifest.commands),
        ("mcp-servers", &manifest.mcp_servers),
        ("pi-extensions", &manifest.pi_extensions),
        ("bundles", &manifest.bundles),
    ] {
        for (name, decl) in items {
            if decl.source == source {
                names.push(format!("{table}.{name}"));
            }
        }
    }
    names
}

pub fn list_sources(env: &Env, scope: &Scope) -> Result<Vec<SourceRow>> {
    let Some(manifest) = manifest::load_current(&manifest::manifest_path(env, scope))? else {
        return Ok(Vec::new());
    };
    Ok(manifest
        .sources
        .iter()
        .map(|(name, decl)| SourceRow {
            scope: scope.clone(),
            name: name.clone(),
            reference: decl
                .repo
                .clone()
                .or_else(|| decl.path.clone())
                .unwrap_or_default(),
            is_remote: decl.repo.is_some(),
            enabled: decl.enabled,
            head: decl
                .repo
                .as_deref()
                .and_then(|repo| crate::remote::cache_head(env, repo, decl.rev.as_deref())),
            declared_items: referents(&manifest, name),
        })
        .collect())
}

/// One subscription as `kendex marketplace list` shows it: what it points
/// at, and how many packages it offers per kind once fetched.
#[derive(Debug, Clone, PartialEq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SubscriptionRow {
    pub scope: Scope,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rev: Option<String>,
    /// The commit the subscription reads right now, when the cache holds
    /// one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    pub enabled: bool,
    /// Packages offered, by kind name — absent until the catalog has been
    /// fetched and can be read.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub counts: Option<std::collections::BTreeMap<String, usize>>,
}

/// Every subscription a scope declares, with package counts where the
/// catalog is readable — a catalog not fetched yet reports no counts
/// rather than zero, because "nothing here" and "not counted yet" are
/// different sentences.
pub fn list_subscriptions(env: &Env, scope: &Scope) -> Result<Vec<SubscriptionRow>> {
    let Some(manifest) = manifest::load_current(&manifest::manifest_path(env, scope))? else {
        return Ok(Vec::new());
    };
    let mut rows = Vec::new();
    for (name, decl) in &manifest.sources {
        let mut commit = None;
        let counts = match crate::source::resolve(env, scope, name, &manifest) {
            Ok(crate::source::SourceState::Ready(ready)) => {
                commit = ready.commit.clone();
                crate::source_read::SealedSource::open(&ready.root)
                    .ok()
                    .and_then(|sealed| {
                        let display = decl
                            .repo
                            .as_deref()
                            .or(decl.path.as_deref())
                            .map(crate::source::repo_leaf)
                            .unwrap_or(name);
                        let config = crate::source::source_config(&sealed, display).ok()?;
                        Some(
                            crate::model::ItemKind::ALL
                                .iter()
                                .filter_map(|kind| {
                                    let offered =
                                        crate::source::list_items(&sealed, &config, *kind).len();
                                    (offered > 0).then(|| (kind.name().to_owned(), offered))
                                })
                                .collect(),
                        )
                    })
            }
            _ => None,
        };
        rows.push(SubscriptionRow {
            scope: scope.clone(),
            name: name.clone(),
            repo: decl.repo.clone(),
            path: decl.path.clone(),
            rev: decl.rev.clone(),
            commit,
            enabled: decl.enabled,
            counts,
        });
    }
    Ok(rows)
}

/// One curated set a catalog offers, as the Catalogs page lists it.
#[derive(Debug, Clone, PartialEq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct BundleRow {
    pub scope: Scope,
    pub source: String,
    pub name: String,
    pub description: Option<String>,
    pub version: Option<String>,
    pub category: Option<String>,
    /// What it carries, each as the kind and name it installs under.
    pub members: Vec<String>,
    pub installed: bool,
}

/// Every set the readable catalogs in this scope offer. A catalog that cannot
/// be read right now offers nothing here — the Catalogs page already says why
/// that source is unreachable, and repeating it per set would say it twice.
pub fn list_bundles(env: &Env, scope: &Scope) -> Result<Vec<BundleRow>> {
    let Some(manifest) = manifest::load_current(&manifest::manifest_path(env, scope))? else {
        return Ok(Vec::new());
    };
    let mut rows = Vec::new();
    for source in manifest.sources.keys() {
        let Ok(crate::source::SourceState::Ready(ready)) =
            crate::source::resolve(env, scope, source, &manifest)
        else {
            continue;
        };
        let Ok(sealed) = crate::source_read::SealedSource::open(&ready.root) else {
            continue;
        };
        let Ok(config) =
            crate::source::source_config(&sealed, crate::source::repo_leaf(&ready.provenance))
        else {
            continue;
        };
        let Ok(offered) = crate::source::bundles::offered(&sealed, &config) else {
            continue;
        };
        for bundle in offered {
            rows.push(BundleRow {
                scope: scope.clone(),
                source: source.clone(),
                installed: manifest
                    .bundles
                    .get(&bundle.name)
                    .is_some_and(|decl| &decl.source == source),
                name: bundle.name,
                description: bundle.description,
                version: bundle.version,
                category: bundle.category,
                members: bundle
                    .members
                    .into_iter()
                    .map(|member| format!("{} {}", member.kind.name(), member.name))
                    .collect(),
            });
        }
    }
    Ok(rows)
}

pub(crate) fn persist_and_plan(
    env: &Env,
    scope: &Scope,
    manifest: Manifest,
) -> Result<EngineReport> {
    persist_and_plan_with(env, scope, manifest, &PlanOptions::default())
}

/// `persist_and_plan` with the caller's plan options — for a manifest
/// change that must land in the same apply as, say, discarding an edit.
pub(crate) fn persist_and_plan_with(
    env: &Env,
    scope: &Scope,
    manifest: Manifest,
    options: &PlanOptions,
) -> Result<EngineReport> {
    let lock = load_lock(&lock_path(env, scope))?;
    let mut report = plan_scope(env, scope, &manifest, &lock, options)?;
    let has_write = crate::engine::persists_manifest(&report.plan.ops);
    if !has_write {
        crate::engine::ops::insert_manifest_save(env, scope, &mut report.plan, manifest)?;
    }
    Ok(report)
}

/// Declare a source under an explicit alias — the low-level verb behind
/// `kendex source add`. The reference parses through
/// [`crate::source_ref::parse_typed`]: `owner/repo[@rev]`, a full remote
/// URL, a local path, a GitHub tree URL, or a skills.sh package URL.
pub fn add_source(env: &Env, scope: &Scope, name: &str, reference: &str) -> Result<EngineReport> {
    Ok(subscribe(env, scope, reference, Some(name))?.report)
}

mod collection;
mod subscribe;
pub use collection::{CollectionStep, SourceAction, collection_steps};
pub use subscribe::{Subscribed, install_project_from_personal, subscribe, subscribe_project_to};

pub fn remove_source(env: &Env, scope: &Scope, name: &str) -> Result<EngineReport> {
    let mut manifest = crate::engine::ops::manifest_for_mutation(env, scope)?;
    if !manifest.sources.contains_key(name) {
        return Err(CoreError::UnknownSource {
            name: name.to_owned(),
        });
    }
    let used_by = referents(&manifest, name);
    if !used_by.is_empty() {
        return Err(CoreError::ManifestInvalid {
            path: manifest::manifest_path(env, scope),
            findings: vec![manifest::Finding {
                location: format!("sources.{name}"),
                problem: format!("still referenced by {}", used_by.join(", ")),
                fix: "remove those items first, or disable the source instead".to_owned(),
            }],
        });
    }
    manifest.sources.remove(name);
    persist_and_plan(env, scope, manifest)
}

/// Disabling deactivates the source's installations in place; re-enabling
/// restores them (they stay declared throughout — not drift).
pub fn toggle_source(env: &Env, scope: &Scope, name: &str, enabled: bool) -> Result<EngineReport> {
    let mut manifest = crate::engine::ops::manifest_for_mutation(env, scope)?;
    let Some(decl) = manifest.sources.get_mut(name) else {
        return Err(CoreError::UnknownSource {
            name: name.to_owned(),
        });
    };
    decl.enabled = enabled;
    persist_and_plan(env, scope, manifest)
}

#[cfg(test)]
mod tests;
