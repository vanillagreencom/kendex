//! Subscribing a scope to a marketplace: reference parsing, one repo per
//! scope, the project-from-personal duplication, and what the preview
//! announces.

use crate::engine::EngineReport;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{self, Manifest, SourceDecl};
use crate::model::Scope;

use super::persist_and_plan;

/// What subscribing declared: the alias, what it points at, and the
/// package a tree or skills.sh URL was leading to — a lead is where the
/// app opens next, never an identity (the package is re-found by
/// kendex's own discovery).
#[derive(Debug)]
pub struct Subscribed {
    pub report: EngineReport,
    pub name: String,
    /// The declared repository or path.
    pub reference: String,
    pub rev: Option<String>,
    /// The repository-relative package path (tree URL) or package name
    /// (skills.sh URL) the reference was pointing at.
    pub lead: Option<String>,
}

/// Subscribe a scope to a marketplace. `alias` names the subscription;
/// without one the last path segment of the reference is used,
/// uniquified. Exactly one repository per scope: a repo already
/// subscribed under another alias is refused naming it, whatever
/// spelling either declaration used.
pub fn subscribe(
    env: &Env,
    scope: &Scope,
    reference: &str,
    alias: Option<&str>,
) -> Result<Subscribed> {
    let (decl, lead) = match crate::source_ref::parse_typed(reference)? {
        crate::source_ref::SourceRef::Remote { repo, rev } => (
            SourceDecl {
                repo: Some(repo),
                path: None,
                rev,
                enabled: true,
            },
            None,
        ),
        crate::source_ref::SourceRef::Path { path } => (
            SourceDecl {
                repo: None,
                path: Some(path),
                rev: None,
                enabled: true,
            },
            None,
        ),
        crate::source_ref::SourceRef::Collection { .. } => {
            return Err(CoreError::SourceRefInvalid {
                reference: reference.to_owned(),
                reason: "a collection link is a set across repositories — install it with `kendex add <link>`"
                    .to_owned(),
            });
        }
        crate::source_ref::SourceRef::SkillsSh { repo, package } => (
            SourceDecl {
                repo: Some(repo),
                path: None,
                rev: None,
                enabled: true,
            },
            Some(package),
        ),
        crate::source_ref::SourceRef::Tree { repo, ref_and_path } => {
            let split = normalize_tree(env, reference, &repo, &ref_and_path)?;
            (
                SourceDecl {
                    repo: Some(repo),
                    path: None,
                    rev: Some(split.reference),
                    enabled: true,
                },
                split.path,
            )
        }
    };
    let mut manifest = crate::engine::ops::manifest_for_mutation(env, scope)?;
    check_subscription(&manifest, alias, &decl, reference)?;
    let name = match alias {
        Some(name) => name.to_owned(),
        None => auto_alias(&manifest, decl.repo.as_deref().unwrap_or(reference)),
    };
    let reference = decl
        .repo
        .clone()
        .or_else(|| decl.path.clone())
        .unwrap_or_default();
    let rev = decl.rev.clone();
    manifest.sources.insert(name.clone(), decl.clone());
    let mut report = persist_and_plan(env, scope, manifest)?;
    announce_subscription(env, &mut report, scope, &name, &decl);
    Ok(Subscribed {
        report,
        name,
        reference,
        rev,
        lead,
    })
}

/// §4.1's install-into-project support: the destination project gains the
/// personal (global) subscription it lacks, so an install into the
/// project can resolve there. Exactly one scope is mutated — the project;
/// the personal manifest is read-only input whose declaration is copied,
/// and the download cache is shared by construction (the store is keyed
/// by repository, never by scope).
pub fn subscribe_project_to(
    env: &Env,
    project_root: &std::path::Path,
    source_name: &str,
) -> Result<EngineReport> {
    let personal = match manifest::load(&manifest::manifest_path(env, &Scope::Global))? {
        manifest::ManifestFile::Current(manifest) => *manifest,
        _ => {
            return Err(CoreError::UnknownSource {
                name: source_name.to_owned(),
            });
        }
    };
    let Some(decl) = personal.sources.get(source_name) else {
        return Err(CoreError::UnknownSource {
            name: source_name.to_owned(),
        });
    };
    let scope = Scope::Project {
        root: project_root.to_path_buf(),
    };
    let mut manifest = crate::engine::ops::manifest_for_mutation(env, &scope)?;
    let reference = decl
        .repo
        .clone()
        .or_else(|| decl.path.clone())
        .unwrap_or_default();
    check_subscription(&manifest, Some(source_name), decl, &reference)?;
    manifest
        .sources
        .insert(source_name.to_owned(), decl.clone());
    let mut report = persist_and_plan(env, &scope, manifest)?;
    announce_subscription(env, &mut report, &scope, source_name, decl);
    Ok(report)
}

/// Install into a project from a personal subscription as one plan: the
/// project gains the subscription and the packages in a single write, so a
/// refused install (a name collision, a held-back item, an unreachable
/// source) leaves the project's manifest byte-identical — never subscribed to
/// a marketplace it installed nothing from. The subscription is validated
/// against the project's own before the plan is built.
pub fn install_project_from_personal(
    env: &Env,
    project_root: &std::path::Path,
    source_name: &str,
    request: &crate::engine::ops::AddRequest,
) -> Result<EngineReport> {
    let personal = match manifest::load(&manifest::manifest_path(env, &Scope::Global))? {
        manifest::ManifestFile::Current(manifest) => *manifest,
        _ => {
            return Err(CoreError::UnknownSource {
                name: source_name.to_owned(),
            });
        }
    };
    let Some(decl) = personal.sources.get(source_name).cloned() else {
        return Err(CoreError::UnknownSource {
            name: source_name.to_owned(),
        });
    };
    let scope = Scope::Project {
        root: project_root.to_path_buf(),
    };
    let project = crate::engine::ops::manifest_for_mutation(env, &scope)?;
    // Redeclaring the same subscription the project already holds is fine; a
    // different repo under a taken alias, or the same repo under a new one, is
    // refused before anything is planned.
    if !project.sources.contains_key(source_name) {
        let reference = decl
            .repo
            .clone()
            .or_else(|| decl.path.clone())
            .unwrap_or_default();
        check_subscription(&project, Some(source_name), &decl, &reference)?;
    }
    // The install reads from this subscription and no other: the context is
    // the subscription itself, so a bare name never wanders to another source.
    let request = crate::engine::ops::AddRequest {
        source: Some(source_name.to_owned()),
        ..request.clone()
    };
    let mut report = crate::engine::ops::add_seeded(
        env,
        &scope,
        &request,
        Some((source_name.to_owned(), decl.clone())),
    )?;
    announce_subscription(env, &mut report, &scope, source_name, &decl);
    Ok(report)
}

/// One repository per scope, whatever the spelling: a repo already
/// subscribed under another alias is refused naming the existing
/// subscription, and an alias already pointing somewhere else is refused
/// rather than silently rebound — rebinding would move every item
/// declared from it. The same alias pointing at the same repository may
/// re-declare (that is how a tracked revision changes).
fn check_subscription(
    manifest: &Manifest,
    alias: Option<&str>,
    decl: &SourceDecl,
    reference: &str,
) -> Result<()> {
    if let Some(repo) = &decl.repo {
        let identity = crate::source_ref::repo_identity(repo);
        for (existing_name, existing) in &manifest.sources {
            let Some(existing_repo) = &existing.repo else {
                continue;
            };
            if crate::source_ref::repo_identity(existing_repo) == identity
                && alias != Some(existing_name.as_str())
            {
                return Err(CoreError::DuplicateSourceRepo {
                    reference: reference.to_owned(),
                    name: existing_name.clone(),
                    repo: existing_repo.clone(),
                });
            }
        }
    }
    if let Some(alias) = alias
        && let Some(existing) = manifest.sources.get(alias)
    {
        let same = match (&decl.repo, &existing.repo, &decl.path, &existing.path) {
            (Some(new), Some(old), _, _) => {
                crate::source_ref::repo_identity(new) == crate::source_ref::repo_identity(old)
            }
            (None, None, Some(new), Some(old)) => new == old,
            _ => false,
        };
        if !same {
            let points_at = existing
                .repo
                .clone()
                .or_else(|| existing.path.clone())
                .unwrap_or_default();
            return Err(CoreError::SourceRefInvalid {
                reference: reference.to_owned(),
                reason: format!(
                    "'{alias}' already points at {points_at} — remove that subscription first, or pick another name"
                ),
            });
        }
    }
    Ok(())
}

/// An alias derived from the reference's last path segment, uniquified
/// against what the scope already declares.
fn auto_alias(manifest: &Manifest, reference: &str) -> String {
    let trimmed = reference.trim_end_matches('/');
    let trimmed = trimmed.strip_suffix(".git").unwrap_or(trimmed);
    let base = trimmed
        .rsplit(['/', ':'])
        .next()
        .filter(|segment| !segment.is_empty())
        .unwrap_or("source")
        .to_owned();
    let mut name = base.clone();
    let mut counter = 2;
    while manifest.sources.contains_key(&name) {
        name = format!("{base}-{counter}");
        counter += 1;
    }
    name
}

/// A tree URL's `<ref>/<path>` split needs the repository's refs, so this
/// is the one subscribe path that touches the network before planning —
/// and it runs before any write: offline with nothing cached, the URL is
/// refused rather than guessed (invariant 11), and the manifest stays
/// byte-identical.
fn normalize_tree(
    env: &Env,
    reference: &str,
    repo: &str,
    ref_and_path: &str,
) -> Result<crate::source_ref::TreeSplit> {
    let url = crate::remote::clone_url(env, repo);
    let key = crate::remote::cache_key(env, repo);
    let mirror = crate::remote::store::mirror_dir(env, &key);
    let _guard = crate::remote::store::lock_repo(env, &key)?;
    // Best-effort fetch: a mirror already downloaded answers offline.
    let fetched = crate::remote::store::ensure_mirror(&mirror, &url)
        .and_then(|()| crate::remote::store::fetch(&mirror));
    let refs: Vec<crate::source_ref::MirrorRef> = crate::remote::store::ref_names(&mirror)
        .unwrap_or_default()
        .iter()
        .filter_map(|full| crate::source_ref::MirrorRef::from_full(full))
        .collect();
    if refs.is_empty() {
        return Err(match fetched {
            Err(error) => error,
            Ok(()) => CoreError::SourceRefInvalid {
                reference: reference.to_owned(),
                reason: "the repository has no branches or tags to resolve the tree URL against"
                    .to_owned(),
            },
        });
    }
    crate::source_ref::split_tree_ref(reference, &refs, ref_and_path)
}

/// The §4.1 preview line: every subscribe names its destination scope,
/// manifest path, and the source's alias, repo, and revision — which
/// scope a click mutates is never inferred from the page being looked at.
fn announce_subscription(
    env: &Env,
    report: &mut EngineReport,
    scope: &Scope,
    name: &str,
    decl: &SourceDecl,
) {
    let what = match (&decl.repo, &decl.rev) {
        (Some(repo), Some(rev)) => format!("{repo} @ {rev}"),
        (Some(repo), None) => repo.clone(),
        (None, _) => decl.path.clone().unwrap_or_default(),
    };
    let line = format!(
        "Subscribes {} to '{name}' ({what}) — {}",
        scope.label(),
        manifest::manifest_path(env, scope).display()
    );
    for op in &mut report.plan.ops {
        if let crate::apply::Op::WriteManifest { .. } = &op.op {
            op.description = line.clone();
        }
    }
    report.notes.push(line);
}
