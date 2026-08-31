use std::collections::BTreeSet;

use crate::apply::{Op, PlannedOp, Pre};

use super::{EngineReport, PlanOptions, plan_scope};
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, Reason, lock_path};
use crate::manifest::{self, Manifest};
use crate::model::{HarnessId, ItemKind, Scope};

mod add;
pub use add::{AddRequest, add, add_seeded, requested_kinds, targets_for};

/// Every kind a manifest declares by name. Plugins are excluded: they carry
/// only an enabled flag, in their own table.
const DECLARED_KINDS: [ItemKind; 6] = [
    ItemKind::Agent,
    ItemKind::Skill,
    ItemKind::Hook,
    ItemKind::Command,
    ItemKind::McpServer,
    ItemKind::PiExtension,
];

/// The tools on this machine a fresh manifest should install to — a tool
/// kendex can only read is detected and listed, never seeded as a target
/// whose every install would silently do nothing.
pub fn detected_harnesses(env: &Env) -> Vec<HarnessId> {
    crate::harness::all_adapters()
        .iter()
        .filter_map(|a| {
            a.detect(env, &a.default_global_root(env))
                .map(|found| found.harness)
        })
        .filter(|harness| crate::harness::installable(*harness))
        .collect()
}

/// Bring a manifest's install targets up to date with the machine, and say
/// which tools that added. Detection is re-read at install time rather than
/// trusted from the manifest seed: a tool installed after the scope was set
/// up would otherwise never receive anything, and nothing would say why.
///
/// Only additive. A tool the list already names keeps whatever it has, even
/// if its directory has since gone — narrowing here would leave installed
/// files with nothing declaring them.
pub(crate) fn adopt_detected(env: &Env, manifest: &mut Manifest) -> Option<String> {
    let gained: Vec<HarnessId> = detected_harnesses(env)
        .into_iter()
        .filter(|harness| !manifest.install.harnesses.contains(harness))
        .collect();
    if gained.is_empty() {
        return None;
    }
    manifest.install.harnesses.extend(gained.iter().copied());
    Some(
        gained
            .iter()
            .map(|harness| harness.display_name().to_owned())
            .collect::<Vec<_>>()
            .join(", "),
    )
}

/// Load the scope's manifest for mutation, seeding a fresh one (with the
/// default source) when none exists. Legacy files are a hard error.
pub fn manifest_for_mutation(env: &Env, scope: &Scope) -> Result<Manifest> {
    let path = manifest::manifest_path(env, scope);
    match manifest::load_for_mutation(&path)? {
        Some(manifest) => Ok(manifest),
        None => Ok(manifest::seed(&detected_harnesses(env))),
    }
}

/// Drop declarations and plan the removal of exactly those items. A removal
/// is durable: an item something else still requires is written down as
/// suppressed rather than re-derived on the next plan, and every item that
/// requires it says so in the audit instead of quietly getting it back.
/// `sweep` also removes what nothing needs anymore — the dependencies whose
/// last dependent is going away.
///
/// A name that is an installed bundle removes the set: its members go with
/// it, except the ones the user also asked for, that a surviving item needs,
/// or that another installed bundle carries too.
/// Remove by name. `kind` narrows the removal to one declaration — the
/// page that knows what it is looking at passes it, so a skill and an
/// agent sharing a name never go down together. `None` keeps the CLI's
/// bare-name semantics: the name goes wherever it is declared.
pub fn remove(
    env: &Env,
    scope: &Scope,
    names: &[String],
    kind: Option<ItemKind>,
    sweep: bool,
) -> Result<EngineReport> {
    removal(env, scope, names, kind, sweep, true)
}

/// Take these items' installations away and keep their declarations. The
/// files come off disk and the record forgets them, exactly as `remove`
/// would, but kendex.toml is not touched — the next refresh installs them
/// again from their source. This is the remedy for an install that went
/// wrong, and what the manifest says is what makes it a remedy rather than
/// a removal. Never a sweep: what these items pull in is wanted again the
/// moment they are.
pub fn uninstall(env: &Env, scope: &Scope, names: &[String]) -> Result<EngineReport> {
    removal(env, scope, names, None, false, false)
}

/// The removal both verbs share. The plan is made against a manifest
/// without the declarations either way; `disown` is whether that manifest
/// becomes the file. Kept declared, the planner is given no reason of its
/// own to write one: the upstream skill merge waits for the refresh.
fn removal(
    env: &Env,
    scope: &Scope,
    names: &[String],
    kind: Option<ItemKind>,
    sweep: bool,
    disown: bool,
) -> Result<EngineReport> {
    let mut manifest = manifest_for_mutation(env, scope)?;
    let lock = crate::lock::load(&lock_path(env, scope))?;
    let bundles: Vec<String> = names
        .iter()
        .filter(|name| kind.is_none() && manifest.bundles.contains_key(*name))
        .cloned()
        .collect();
    let mut removing = names.to_vec();
    removing.extend(super::bundles::recorded_members(&lock, &bundles));
    for name in names {
        // Plugin has no declared-items table — it lives in `plugins` and
        // is removed there, never through `declared_mut` (which panics on
        // it). A bare-name removal reaches both.
        if matches!(kind, Some(ItemKind::Plugin)) {
            manifest.plugins.remove(name);
            continue;
        }
        let kinds: Vec<ItemKind> = match kind {
            Some(kind) => vec![kind],
            None => DECLARED_KINDS.to_vec(),
        };
        if kind.is_none() {
            manifest.bundles.remove(name);
            manifest.plugins.remove(name);
        }
        for kind in &kinds {
            manifest.declared_mut(*kind).remove(name);
            if let Some(forks) = manifest.forks.get_mut(kind) {
                forks.remove(name);
            }
        }
        manifest.forks.retain(|_, forks| !forks.is_empty());
        if kinds.contains(&ItemKind::Plugin) {
            manifest.plugins.remove(name);
        }
        // A reviewer agent reads its base agent's skill list by prefix, so
        // the entry outlives the agent while the declaration is kept:
        // surviving agents render from the file that stays.
        if disown && kinds.contains(&ItemKind::Agent) {
            manifest.agent_skills.remove(name);
        }
        if kinds.contains(&ItemKind::Skill) {
            manifest.skill_instructions.remove(name);
            manifest.optional_dependencies.remove(name);
            // Taking an item away also un-takes it wherever it was chosen
            // as an optional extra: that choice is the whole reason it
            // would return.
            for taken in manifest.optional_dependencies.values_mut() {
                taken.retain(|chosen| chosen != name);
            }
        }
    }
    manifest.optional_dependencies.retain(|_, t| !t.is_empty());
    for (kind, name) in kept_removed(env, scope, &manifest, &lock, names, &removing, &bundles) {
        manifest.suppress(kind, &name);
    }
    let mut report = plan_scope(
        env,
        scope,
        &manifest,
        &lock,
        &PlanOptions {
            remove_orphans: true,
            removal_filter: Some(removing.iter().map(|name| (None, name.clone())).collect()),
            sweep_unneeded: sweep,
            uninstalled_bundles: bundles,
            hold_upstream_skills: !disown,
            ..PlanOptions::default()
        },
    )?;
    if disown {
        report
            .notes
            .extend(unreadable_origins(env, scope, &manifest, &lock, names));
        ensure_manifest_persisted(env, scope, &manifest, &mut report)?;
    }
    Ok(report)
}

/// Which of these names something that stays would pull straight back in,
/// and as what: a dependency of a skill that stays, or a member of a bundle
/// that is still installed. Those are the removals that have to be written
/// down, or the next plan would simply undo them.
///
/// Two readings answer it, and either one alone has a blind spot: the record
/// says nothing once it has been deleted, and the catalogs say nothing while
/// they cannot be read. So both are asked and anything either one names is
/// written down — over-recording a removal costs a line the next `add`
/// clears, while missing one puts back something the user took away.
#[allow(clippy::too_many_arguments)]
fn kept_removed(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    names: &[String],
    removing: &[String],
    bundles: &[String],
) -> BTreeSet<(ItemKind, String)> {
    let mut kept = recorded_edges(lock, names, removing, bundles);
    kept.extend(still_derived(env, scope, manifest, names));
    kept
}

/// What the record already says holds these installations up. Every one
/// carries the edges it was installed under, so an edge from something that
/// is not going away is exactly what would derive the item again — and
/// reading it costs no catalog, which is what makes a removal stick while a
/// source is unreadable.
fn recorded_edges(
    lock: &Lock,
    names: &[String],
    removing: &[String],
    bundles: &[String],
) -> BTreeSet<(ItemKind, String)> {
    lock.entries
        .values()
        .filter(|entry| names.contains(&entry.name))
        .filter(|entry| {
            entry.reasons.iter().any(|reason| match reason {
                Reason::Requested => false,
                Reason::RequiredBy { by } => !removing.contains(&by.name),
                Reason::MemberOf { bundle } => !bundles.contains(&bundle.name),
            })
        })
        .map(|entry| (entry.kind, entry.name.clone()))
        .collect()
}

/// What the catalogs say the manifest still implies, now that the
/// declarations are gone. This is the reading that survives a deleted
/// record, and the one that sees an edge the catalog gained since the last
/// install.
fn still_derived(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    names: &[String],
) -> BTreeSet<(ItemKind, String)> {
    let mut state = crate::engine::desired::DesiredState::default();
    let expansion = super::expansion::expand(env, scope, manifest, None, &mut state);
    let mut derived = BTreeSet::new();
    for name in names {
        for kind in super::expansion::PLANNED_KINDS {
            if expansion.contains(kind, name) {
                derived.insert((kind, name.clone()));
            }
        }
    }
    derived
}

/// The catalogs behind what is going away that cannot be read right now.
/// What else still wants an item is written in its catalog, so an unreadable
/// one means the preview cannot show the whole consequence of the removal.
/// The removal itself stands either way — the record already says what has
/// to stay removed.
fn unreadable_origins(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    names: &[String],
) -> Vec<String> {
    let mut sources: Vec<String> = lock
        .entries
        .values()
        .filter(|entry| names.contains(&entry.name))
        .map(|entry| entry.source.clone())
        .collect();
    sources.sort();
    sources.dedup();
    sources
        .into_iter()
        .filter(|source| {
            !matches!(
                crate::source::resolve(env, scope, source, manifest),
                Ok(crate::source::SourceState::Ready(_))
            )
        })
        .map(|source| {
            format!(
                "the catalog '{source}' cannot be read right now, so this preview cannot show everything that still wants what is going — the removal stands, and what has to stay removed is recorded"
            )
        })
        .collect()
}

/// Flip declarations; disabling is non-destructive (invariant 5).
/// Toggle by name; `kind` narrows to one declaration, the same way and
/// for the same reason as [`remove`].
pub fn toggle(
    env: &Env,
    scope: &Scope,
    names: &[String],
    kind: Option<ItemKind>,
    enabled: bool,
) -> Result<EngineReport> {
    let mut manifest = manifest_for_mutation(env, scope)?;
    let lock = crate::lock::load(&lock_path(env, scope))?;
    for name in names {
        let kinds: Vec<ItemKind> = match kind {
            Some(kind) => vec![kind],
            None => DECLARED_KINDS.to_vec(),
        };
        for kind in kinds {
            if kind == ItemKind::Plugin {
                if let Some(plugin) = manifest.plugins.get_mut(name) {
                    plugin.enabled = enabled;
                }
                continue;
            }
            if let Some(decl) = manifest.declared_mut(kind).get_mut(name) {
                decl.enabled = enabled;
            }
        }
        if kind.is_none()
            && let Some(plugin) = manifest.plugins.get_mut(name)
        {
            plugin.enabled = enabled;
        }
    }
    let mut report = plan_scope(env, scope, &manifest, &lock, &PlanOptions::default())?;
    ensure_manifest_persisted(env, scope, &manifest, &mut report)?;
    Ok(report)
}

/// The plan must persist the mutated manifest exactly once; plan_scope adds
/// its own write only when upstream skill merges changed it further.
fn ensure_manifest_persisted(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    report: &mut EngineReport,
) -> Result<()> {
    let already = crate::engine::persists_manifest(&report.plan.ops);
    if already {
        return Ok(());
    }
    insert_manifest_save(env, scope, &mut report.plan, manifest.clone())
}

/// Insert the "persist the manifest" write a plan is missing, bound to the
/// bytes the file holds now. It leads the plan: every later op was planned
/// against the manifest this write makes durable.
pub(crate) fn insert_manifest_save(
    env: &Env,
    scope: &Scope,
    plan: &mut crate::apply::Plan,
    manifest: Manifest,
) -> Result<()> {
    let path = crate::manifest::manifest_path(env, scope);
    let file = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.display().to_string());
    plan.insert(
        0,
        PlannedOp {
            description: format!("Save {file}").into(),
            op: Op::WriteManifest {
                pre: Pre::observed(&path)?,
                path,
                manifest: Box::new(manifest),
            },
        },
    )
}
