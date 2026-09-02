//! Declaring a curated set: the one-bundle-per-name rule, and the
//! individual declarations a set now accounts for.

use super::AddRequest;
use crate::error::{CoreError, Result};
use crate::manifest::{ItemDecl, Manifest};
use crate::model::ItemKind;
use crate::source::CatalogBundle;

/// Declare one curated set, carried the way the request asked. Asking for
/// the set is asking for all of it: a member held back by an earlier
/// removal comes with it, the same way asking for an item again outranks
/// the removal that took it away.
pub(super) fn declare_bundle(
    manifest: &mut Manifest,
    bundle: &crate::source::CatalogBundle,
    source_name: &str,
    request: &AddRequest,
    hold_at: Option<&str>,
) -> ItemDecl {
    let decl = manifest
        .bundles
        .entry(bundle.name.clone())
        .or_insert_with(|| ItemDecl::from_source(source_name));
    decl.source = source_name.to_owned();
    if let Some(harnesses) = &request.harnesses {
        decl.harnesses = Some(harnesses.clone());
    }
    if let Some(method) = request.method {
        decl.method = Some(method);
    }
    if let Some(commit) = hold_at {
        decl.rev = Some(commit.to_owned());
    }
    let declared = decl.clone();
    for member in &bundle.members {
        if let Some(held) = manifest.suppressed.get_mut(&member.kind) {
            held.retain(|suppressed| suppressed != &member.name);
        }
    }
    manifest.suppressed.retain(|_, held| !held.is_empty());
    declared
}

// Install-all subsumption, and the one-bundle-per-name rule.
//
// Declaring a bundle removes, in the same plan, the individual
// declarations the bundle now subsumes — otherwise those members keep a
// `requested` edge and survive a later bundle uninstall as "also
// requested". Subsumption only claims a declaration whose effective
// options equal what the bundle derives for that member; one the user
// shaped — its own harness list, method, hold, enabled flag or
// frontmatter override — is kept, and the preview says why.

/// Invariant 4 for bundles: `[bundles.<name>]` is keyed by bare name, so a
/// second marketplace's same-named bundle is refused naming the first —
/// with installing the members individually as the way out.
pub(super) fn require_free(manifest: &Manifest, name: &str, source_name: &str) -> Result<()> {
    let Some(existing) = manifest.bundles.get(name) else {
        return Ok(());
    };
    if existing.source == source_name {
        return Ok(());
    }
    Err(CoreError::BundleCollision {
        name: name.to_owned(),
        existing: canonical(manifest, &existing.source),
        requested: canonical(manifest, source_name),
    })
}

/// The subscription's canonical repository (or path) beside its alias —
/// an alias is a local label, not an identity.
pub(super) fn canonical(manifest: &Manifest, alias: &str) -> String {
    match manifest
        .sources
        .get(alias)
        .and_then(|decl| decl.repo.as_deref().or(decl.path.as_deref()))
    {
        Some(repo) => format!("{alias} ({repo})"),
        None => alias.to_owned(),
    }
}

/// Drop the individual declarations this bundle now accounts for, and say
/// so — "N packages now come with the bundle". A member whose declaration
/// differs from what the bundle would derive is kept, with the note naming
/// what the user changed.
pub(super) fn subsume(
    manifest: &mut Manifest,
    bundle: &CatalogBundle,
    bundle_decl: &ItemDecl,
    notes: &mut Vec<String>,
) {
    let mut taken = 0usize;
    for member in &bundle.members {
        let Some(decl) = manifest.declared(member.kind).get(&member.name) else {
            continue;
        };
        if decl.source != bundle_decl.source {
            continue;
        }
        match shaped_by_user(manifest, member.kind, &member.name, decl, bundle_decl) {
            None => {
                manifest.declared_mut(member.kind).remove(&member.name);
                taken += 1;
            }
            Some(why) => notes.push(format!("'{}' stays your own install — {why}", member.name)),
        }
    }
    match taken {
        0 => {}
        1 => notes.push(format!(
            "1 package now comes with the {} bundle",
            bundle.name
        )),
        n => notes.push(format!(
            "{n} packages now come with the {} bundle",
            bundle.name
        )),
    }
}

/// Why a member's own declaration is not the bundle's — `None` when the
/// two are effectively equal and the bundle can speak for it.
pub(super) fn shaped_by_user(
    manifest: &Manifest,
    kind: ItemKind,
    name: &str,
    decl: &ItemDecl,
    bundle_decl: &ItemDecl,
) -> Option<String> {
    if decl.harnesses != bundle_decl.harnesses {
        return Some("it has its own harness list".to_owned());
    }
    if decl.method != bundle_decl.method {
        return Some("it has its own install method".to_owned());
    }
    if decl.rev != bundle_decl.rev {
        return Some("it is held at its own version".to_owned());
    }
    if decl.enabled != bundle_decl.enabled {
        return Some("you toggled it yourself".to_owned());
    }
    if kind == ItemKind::Agent
        && manifest
            .agent_frontmatter
            .values()
            .any(|agents| agents.contains_key(name))
    {
        return Some("it carries your frontmatter overrides".to_owned());
    }
    None
}

/// The sets one request names, as the catalog offers them. A name it does
/// not offer is refused, and so is a set it offers and can hand nothing
/// over for: what a set installs derives at plan time, so declaring one
/// would record the set, plan nothing, and report a successful install of
/// no files — the shape a member list nothing backs leaves behind.
pub(super) fn resolve_sets(
    sealed: &crate::source_read::SealedSource,
    config: &crate::source::SourceConfig,
    source_name: &str,
    wanted: &[String],
) -> Result<Vec<CatalogBundle>> {
    let mut sets = Vec::new();
    for name in wanted {
        let Some(bundle) = crate::source::bundles::find(sealed, config, name)? else {
            return Err(CoreError::NoSuchBundle {
                name: name.clone(),
                source_name: source_name.to_owned(),
            });
        };
        if !bundle.members.iter().any(|member| {
            crate::source::find_item(sealed, config, member.kind, &member.name).is_some()
        }) {
            return Err(CoreError::BundleInstallsNothing {
                name: name.clone(),
                source_name: source_name.to_owned(),
                members: bundle
                    .members
                    .iter()
                    .map(|member| crate::names::shown(&member.name))
                    .collect(),
            });
        }
        sets.push(bundle);
    }
    Ok(sets)
}
