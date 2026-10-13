use serde::Serialize;
use specta::Type;

mod repos;
pub use repos::{
    RepoSubscription, Subscription, declared_identity, repo_subscriptions, subscriptions,
};

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
    let manifest = crate::engine::ops::manifest_for_reading(env, scope)?;
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
    let manifest = crate::engine::ops::manifest_for_reading(env, scope)?;
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

/// Write a source change to the manifest and plan the scope around it,
/// held at the record: the change names a source, and every package of
/// another source stays at the commit its lock entries record.
pub(crate) fn persist_and_plan(
    env: &Env,
    scope: &Scope,
    manifest: Manifest,
) -> Result<EngineReport> {
    persist_and_plan_with(env, scope, manifest, &PlanOptions::locked())
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
        crate::engine::ops::insert_manifest_save(env, scope, &mut report.plan, manifest, None)?;
    }
    Ok(report)
}

/// Declare a source under an explicit alias — the low-level verb behind
/// `kendex source add`. The reference parses through
/// [`crate::source_ref::parse_typed`]: `owner/repo[@rev]`, a full remote
/// URL, a local path, a GitHub tree URL, or a skills.sh package URL.
pub fn add_source(env: &Env, scope: &Scope, name: &str, reference: &str) -> Result<EngineReport> {
    prepare_source_change(env, scope, SourceChange::Add { name, reference })?.plan(env)
}

mod collection;
mod subscribe;
pub use collection::{
    CollectionStep, PreparedCollection, SourceAction, collection_steps, prepare_collection,
};
pub use subscribe::{
    Subscribed, install_from, install_project_carrying, install_project_from_personal, subscribe,
    subscribe_and_install, subscribe_project_to,
};

pub fn remove_source(env: &Env, scope: &Scope, name: &str) -> Result<EngineReport> {
    prepare_source_change(env, scope, SourceChange::Remove { name })?.plan(env)
}

/// Disabling deactivates the source's installations in place; re-enabling
/// restores them. Other packages hold at their recorded commit.
pub fn toggle_source(env: &Env, scope: &Scope, name: &str, enabled: bool) -> Result<EngineReport> {
    prepare_source_change(env, scope, SourceChange::SetEnabled { name, enabled })?.plan(env)
}

/// The requested subscription edit, prepared in memory before a
/// multi-scope command checks the catalogs its resulting manifests select.
#[derive(Clone, Copy)]
pub enum SourceChange<'a> {
    Add { name: &'a str, reference: &'a str },
    Remove { name: &'a str },
    SetEnabled { name: &'a str, enabled: bool },
}

/// A validated subscription change that has not rendered or written.
pub struct PreparedSourceChange {
    scope: Scope,
    manifest: Manifest,
    subscription: Option<(String, manifest::SourceDecl)>,
}

impl PreparedSourceChange {
    /// Check the post-change reading, including surviving recorded pins.
    /// Disabling or removing a source does not select its former catalog.
    pub fn check_catalog_compatibility(&self, env: &Env) -> Result<()> {
        crate::engine::check_catalog_compatibility_for(
            env,
            &self.scope,
            &self.manifest,
            &PlanOptions::locked(),
        )
    }

    pub fn plan(self, env: &Env) -> Result<EngineReport> {
        let mut report = persist_and_plan(env, &self.scope, self.manifest)?;
        if let Some((name, decl)) = self.subscription {
            subscribe::announce_subscriptions(
                env,
                &mut report,
                &self.scope,
                [(name.as_str(), &decl)],
            );
        }
        Ok(report)
    }
}

pub fn prepare_source_change(
    env: &Env,
    scope: &Scope,
    change: SourceChange<'_>,
) -> Result<PreparedSourceChange> {
    if let SourceChange::Add { name, reference } = change {
        let subscribe::Declared {
            mut manifest,
            name,
            decl,
            ..
        } = subscribe::declared(env, scope, reference, Some(name))?;
        manifest.sources.insert(name.clone(), decl.clone());
        return Ok(PreparedSourceChange {
            scope: scope.clone(),
            manifest,
            subscription: Some((name, decl)),
        });
    }
    let mut manifest = crate::engine::ops::manifest_for_mutation(env, scope)?;
    let name = match change {
        SourceChange::Remove { name } | SourceChange::SetEnabled { name, .. } => name,
        SourceChange::Add { .. } => unreachable!("handled before the manifest load"),
    };
    if !manifest.sources.contains_key(name) {
        return Err(CoreError::UnknownSource {
            name: name.to_owned(),
        });
    }
    match change {
        SourceChange::Remove { name } => {
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
        }
        SourceChange::SetEnabled { name, enabled } => {
            let Some(decl) = manifest.sources.get_mut(name) else {
                unreachable!("source checked above");
            };
            decl.enabled = enabled;
        }
        SourceChange::Add { .. } => unreachable!("handled before the manifest load"),
    }
    Ok(PreparedSourceChange {
        scope: scope.clone(),
        manifest,
        subscription: None,
    })
}

#[cfg(test)]
mod tests;
