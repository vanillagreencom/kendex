//! Computing the desired world: what declaration says should exist on
//! disk, resolved against every source it names.
//!
//! Computed against the manifest that will be on disk once this plan
//! applies. An upstream skill merge rewrites the manifest, and hashes and
//! renderings must reflect that rewrite — otherwise the very next audit
//! reads the merged manifest and calls a clean install stale. The merge is
//! idempotent, so recomputing against it converges in one repeat.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use crate::env::Env;
use crate::error::Result;
use crate::lock::Lock;
use crate::manifest::Manifest;
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::find_item;

use crate::engine::desired::{DesiredState, ItemCtx};
use crate::engine::desired_item::{build, no_harness_note};
use crate::engine::desired_source::{published_review, read_catalog, resolve_source};
use crate::engine::{PlanOptions, desired_kinds};

/// The desired world, computed against the manifest that will be on disk
/// once this plan applies. An upstream skill merge rewrites the manifest,
/// and hashes and renderings must reflect that rewrite — otherwise the very
/// next audit reads the merged manifest and calls a clean install stale. The
/// merge is idempotent, so recomputing against it converges in one repeat.
pub fn desired_state(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    options: &PlanOptions,
) -> Result<DesiredState> {
    let first = compute(env, scope, manifest, lock, options)?;
    let Some(merged) = first.manifest_update else {
        return Ok(first);
    };
    let mut second = compute(env, scope, &merged, lock, options)?;
    second.manifest_update = Some(merged);
    Ok(second)
}

fn compute(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    options: &PlanOptions,
) -> Result<DesiredState> {
    let mut state = DesiredState::default();
    let mut updated_manifest = manifest.clone();
    let mut manifest_changed = false;
    // Everything is planned from the closure — what was declared, what the
    // installed bundles carry, and what those skills require — while the
    // manifest keeps holding only what was chosen.
    let expansion = crate::engine::expansion::expand(env, scope, manifest, &mut state);
    // One parse of each catalog root's reviews file per pass: it is one
    // file, and every item that root carries would otherwise re-read it.
    // Keyed by root, since one declared source resolves to several when
    // its items pin different revisions.
    let mut reviews: BTreeMap<PathBuf, BTreeMap<String, crate::quality::reviews::SafetyReview>> =
        BTreeMap::new();
    state.acting = acting(options, &expansion);
    let collisions = crate::engine::catalog::Collisions::find(&expansion, &mut state);

    for kind in crate::engine::expansion::PLANNED_KINDS {
        for (name, planned) in expansion.of(kind) {
            let decl = &planned.decl;
            // Each of the three ways out below leaves this declaration
            // unrendered, so nothing downstream may read its absence from
            // the drift as proof that what is on disk is untouched.
            let Some((root, provenance, source_commit)) =
                resolve_source(env, scope, name, decl, manifest, &mut state)?
            else {
                state.unmeasured.insert((kind, name.clone()));
                continue;
            };
            let Some((sealed, config)) =
                read_catalog(&root, &provenance, name, &decl.source, &mut state)?
            else {
                state.unmeasured.insert((kind, name.clone()));
                continue;
            };
            crate::engine::catalog::notes(&config, &decl.source, &mut state);
            let Some(item_path) = find_item(&sealed, &config, kind, name) else {
                state
                    .notes
                    .push(format!("{name}: not found in source '{}'", decl.source));
                state.unmeasured.insert((kind, name.clone()));
                continue;
            };
            state.processed.insert((kind, name.clone()));
            let author_review = published_review(
                &sealed,
                &decl.source,
                &provenance,
                &config,
                kind,
                name,
                &item_path,
                &mut reviews,
                &mut state,
            )?;
            let mut harnesses = planned.harnesses.clone();
            // Every tool this is declared for is one that holds no such kind
            // here. Nothing installs, and silence would read as success.
            if harnesses.is_empty() {
                no_harness_note(kind, name, decl, manifest, &mut state);
            }
            harnesses.retain(|harness| collisions.allows(kind, name, *harness));
            let reasons = reasons_for(kind, name, &harnesses, &expansion);
            let ctx = ItemCtx {
                env,
                scope,
                manifest,
                lock,
                config: &config,
                sealed: &sealed,
                name,
                decl,
                item_path: &item_path,
                provenance: &provenance,
                source_commit: source_commit.as_deref(),
                harnesses,
                reasons: &reasons,
                author_review,
                planned: state.acts_on(kind, name),
            };
            build(
                kind,
                &ctx,
                &mut state,
                &mut updated_manifest,
                &mut manifest_changed,
            )?;
        }
    }
    desired_kinds::desired_plugins(env, scope, manifest, &mut state);
    crate::engine::desired_custom_hooks::desired_custom_hooks(env, scope, manifest, &mut state);

    if manifest_changed {
        state.manifest_update = Some(updated_manifest);
    }
    Ok(state)
}

/// Which items a restricted plan acts on: the packages it names, and
/// everything those packages require, however far down.
///
/// The literal pair is too tight the moment a package needs something. A
/// discard whose refreshed source newly declares a dependency would restore
/// the package, skip the dependency, and report success — leaving the
/// package unable to run, which is worse than doing too much, because the
/// person is told it worked.
///
/// A bundle member is not in it: a bundle carries its members, no package
/// requires them, and a command about one package has no business
/// installing what a bundle happens to bring.
fn acting(
    options: &PlanOptions,
    expansion: &crate::engine::expansion::Expansion,
) -> Option<BTreeSet<(ItemKind, String)>> {
    let mut acting: BTreeSet<(ItemKind, String)> =
        options.only_names.as_ref()?.iter().cloned().collect();
    // The graph is small and shallow; walk it until nothing new is needed.
    loop {
        let mut grew = false;
        for ((kind, name, _), reasons) in expansion.every_reason() {
            if acting.contains(&(*kind, name.clone())) {
                continue;
            }
            let needed = reasons.iter().any(|reason| match reason {
                crate::lock::Reason::RequiredBy { by } => {
                    acting.contains(&(by.kind, by.name.clone()))
                }
                _ => false,
            });
            if needed {
                acting.insert((*kind, name.clone()));
                grew = true;
            }
        }
        if !grew {
            return Some(acting);
        }
    }
}

/// Why each of an item's installations is wanted, as the closure derived it.
fn reasons_for(
    kind: ItemKind,
    name: &str,
    harnesses: &[HarnessId],
    expansion: &crate::engine::expansion::Expansion,
) -> BTreeMap<HarnessId, BTreeSet<crate::lock::Reason>> {
    harnesses
        .iter()
        .map(|harness| (*harness, expansion.reasons(kind, name, *harness)))
        .collect()
}
