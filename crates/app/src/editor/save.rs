//! The Customize tab's reads and its one write.
//!
//! Every other write in the app is a targeted operation that loads,
//! changes and saves in one breath. This one hands a person the whole
//! manifest and the settings their skills declare, waits while they work,
//! and writes it all back — so it is the write that can put an older file
//! over a newer one, and the one that carries the base of each file its
//! copy came from to stop that.
//!
//! Both halves go down as one plan. Saving the manifest re-plans the
//! scope, and that plan is what writes the settings file: an edited key is
//! checked against the templates the saved manifest declares, and the
//! assignment it needs to land on is inserted by the same pass that sets
//! the value. So settings edits are an input to the plan rather than a
//! write that follows it. A second write would bind to bytes the first one
//! had already replaced.

use kendex_core::apply::{Op, PlannedOp, Pre};
use kendex_core::base::Base;
use kendex_core::engine::{self, PlanOptions, ops};
use kendex_core::env::Env;
use kendex_core::lock::{load as load_lock, lock_path};
use kendex_core::manifest::{self, Finding, Manifest};
use kendex_core::model::Scope;
use kendex_core::settings_file::{SettingsDraft as CoreSettingsDraft, SettingsEdit};
use kendex_core::settings_view::ScopeSettings;
use serde::{Deserialize, Serialize};
use specta::Type;

use super::env;
use crate::audit::{AuditView, view};
use crate::repo_effects::ExecuteError;
use crate::whole_file::{WriteRefused, refusal, stale_at};

/// A place's manifest and what the file it came from was at that moment.
/// One value, because a copy without its base cannot be written back
/// safely, and the two read apart could describe different files.
#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ManifestRead {
    /// Absent where the place has no manifest yet — the editor still
    /// opens, on an empty one.
    pub manifest: Option<Manifest>,
    /// The file these bytes came from, read with them and never apart.
    pub base: Base,
}

#[tauri::command(async)]
#[specta::specta]
pub fn get_manifest(scope: Scope) -> Result<ManifestRead, String> {
    let env = env()?;
    let (manifest, base) = manifest::read_for_mutation(&manifest::manifest_path(&env, &scope))
        .map_err(|e| e.to_string())?;
    Ok(ManifestRead { manifest, base })
}

/// Validate an edited manifest the way a hand-written file is validated, so
/// the editor rejects exactly the same things — fix strings included.
fn check(manifest: &Manifest) -> Result<(), String> {
    let text = toml::to_string_pretty(manifest).map_err(|e| e.to_string())?;
    let table: toml::Table = text.parse().map_err(|e: toml::de::Error| e.to_string())?;
    let findings = manifest::validate(&table);
    if findings.is_empty() {
        return Ok(());
    }
    Err(findings
        .iter()
        .map(Finding::to_string)
        .collect::<Vec<_>>()
        .join("\n"))
}

/// The editor can create the first manifest for a scope, and first creation
/// is where the default source is seeded — skipping it here would drop it
/// for good, since later reconciliation never re-adds it.
fn on_first_creation(mut manifest: Manifest, seed: Manifest) -> Manifest {
    if manifest.sources.is_empty() {
        manifest.sources = seed.sources;
        if manifest.install.harnesses.is_empty() {
            manifest.install.harnesses = seed.install.harnesses;
        }
    }
    manifest
}

/// The Customize tab's settings half: what every installed skill declares
/// and where this place's file stands on each key.
#[tauri::command(async)]
#[specta::specta]
pub fn get_scope_settings(scope: Scope) -> Result<ScopeSettings, String> {
    kendex_core::settings_view::scope_settings(&env()?, &scope).map_err(|e| e.to_string())
}

/// An edited manifest and what the file it came from was at that moment.
#[derive(Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ManifestDraft {
    pub manifest: Manifest,
    pub base: Option<String>,
}

/// Edited settings values and what the settings file was when they were
/// read. Each edit names the skill whose template declares its key, which
/// is what core checks it against.
#[derive(Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SettingsDraft {
    pub edits: Vec<SettingsEdit>,
    pub base: Option<String>,
}

/// Save the Customize tab and reconcile the scope to it.
///
/// Either draft may be absent: a settings-only save carries no manifest,
/// and a manifest-only save carries no edits. Both are one transaction.
/// Saving the manifest re-plans the scope, and that plan is where the
/// edits land, read against the templates the saved manifest declares; a
/// second write would bind to bytes the first one had already replaced.
///
/// Each base is what its file was when this copy was read. A whole
/// manifest goes back with every save, so a copy read before something
/// else wrote the file would put that back — and the caller cannot be
/// relied on to notice. Refusing here needs no caller to remember
/// anything.
#[tauri::command(async)]
#[specta::specta]
pub fn save_customize(
    scope: Scope,
    manifest: Option<ManifestDraft>,
    settings: Option<SettingsDraft>,
) -> Result<AuditView, WriteRefused> {
    // The bytes behind each base were read in the editor, so they arrive
    // as claims and are only ever compared, never believed.
    write_customize(
        &env()?,
        scope,
        manifest.map(|draft| (draft.manifest, Base::claimed(draft.base))),
        settings.map(|draft| CoreSettingsDraft {
            edits: draft.edits,
            base: Base::claimed(draft.base),
        }),
    )
}

/// The write itself, against a given environment — which is what makes it
/// reachable from a test. The command above only finds the environment.
fn write_customize(
    env: &Env,
    scope: Scope,
    draft: Option<(Manifest, Base)>,
    settings: Option<CoreSettingsDraft>,
) -> Result<AuditView, WriteRefused> {
    let path = manifest::manifest_path(env, &scope);
    // One read answers both questions: whether the file is still the one
    // the copy came from, and whether there is a file at all — the moment
    // first-creation seeding happens. A file that cannot be read is a
    // failure to say out loud, not a stale copy: the reload cannot fix a
    // permission or an encoding, and offering it would hide what did.
    let (current, now) = manifest::read_for_mutation(&path).map_err(|e| e.to_string())?;
    let mut options = PlanOptions::default();
    let mut targets = Vec::new();
    // The manifest half. Without one, the scope is reconciled to the file
    // as it sits and no manifest write is added.
    let edited = match draft {
        None => None,
        Some((draft, claimed)) => {
            if now != claimed {
                // Before anything ran: the copy is refused on the base
                // check, so there is no account to carry.
                return Err(WriteRefused::Stale { undone: Vec::new() });
            }
            let mut manifest = match current.is_some() {
                true => draft,
                false => on_first_creation(
                    draft,
                    ops::manifest_for_mutation(env, &scope).map_err(|e| e.to_string())?,
                ),
            };
            // A custom hook's name is its identity everywhere downstream;
            // saving is when a derived one stops being derived.
            kendex_core::hook::name_custom_hooks(&mut manifest);
            check(&manifest)?;
            targets.push(path.clone());
            // The plan binds its own manifest write to the file this copy
            // came from, so a writer landing after the check above is
            // refused by the apply rather than overwritten.
            options.manifest_base = Some(claimed.clone());
            Some((manifest, claimed))
        }
    };
    // The settings half, bound the same way. The base is verified up front
    // for the same reason the manifest's is: a refusal before anything is
    // planned costs the person nothing, and the op's own precondition
    // catches a writer that lands after it.
    if let Some(settings) = settings {
        if let Some(root) = settings_root(&scope) {
            let file = kendex_core::settings_seed::settings_file_path(&root);
            settings.base.verify(&file).map_err(refusal)?;
            targets.push(file);
        }
        options.settings_draft = Some(settings);
    }
    let planned = match &edited {
        Some((manifest, _)) => manifest.clone(),
        // Nothing here is editing the manifest, so the scope reconciles to
        // what is on disk — an absent one reads as empty, which is what
        // every other read-only pass does with it.
        None => current.clone().unwrap_or_default(),
    };
    let lock = load_lock(&lock_path(env, &scope)).map_err(|e| e.to_string())?;
    let mut report =
        engine::plan_scope(env, &scope, &planned, &lock, &options).map_err(|e| e.to_string())?;
    if let Some((manifest, claimed)) = edited
        && !engine::persists_manifest(&report.plan.ops)
    {
        // Leading the plan: every later op was planned against the manifest
        // this write makes durable, and the base still holds — the file is
        // the one the copy on screen was read from.
        report
            .plan
            .insert(
                0,
                PlannedOp {
                    description: "Save kendex.toml".into(),
                    op: Op::WriteManifest {
                        pre: Pre::from(&claimed),
                        path: path.clone(),
                        manifest: Box::new(manifest),
                    },
                },
            )
            .map_err(|error| WriteRefused::Failed {
                message: error.to_string(),
            })?;
    }
    // The bound preconditions refuse a file that moved between the checks
    // above and the write itself, and that refusal is the same answer the
    // checks give — so it reaches the editor as the same choice.
    // Through the one executor: a manifest saved with a package deleted out
    // of it takes that package away, and its declared uninstaller has to run
    // while its scripts are still on disk.
    //
    // A stale precondition still reads as the same refusal, and it takes
    // the account with it. The uninstaller ran before the plan wrote
    // anything, so this is a refusal with a disarmed repository behind it —
    // the one shape where "nothing happened, reload" is a lie. Which is
    // also why nothing here reasons about whether this route can remove:
    // it can, through a refused rendering, whatever the planning options
    // say about orphans.
    let undone = crate::repo_effects::execute(env, &report)
        .map_err(|refused| refused_write(refused, &targets))?;
    Ok(AuditView {
        undone,
        ..view(env, &scope)
    })
}

/// How a write the executor refused reaches the page.
///
/// A precondition that moved is the reload choice the editor already
/// draws, and it carries whatever the write had already done: the
/// uninstaller of a leaving package runs before the plan writes anything,
/// so a refusal landing after that point is a refusal with a disarmed
/// repository behind it. A bare reload notice there says nothing happened,
/// which is the one thing that is not true.
///
/// Named rather than inlined so the mapping can be driven with a real
/// stale error rather than inferred from the branch.
pub(super) fn refused_write(refused: ExecuteError, targets: &[std::path::PathBuf]) -> WriteRefused {
    match refused {
        ExecuteError::Apply { said, error } if stale_at(&error, targets) => {
            WriteRefused::Stale { undone: said }
        }
        other => WriteRefused::Failed {
            message: other.to_string(),
        },
    }
}

/// The project root a settings file would sit in. Global has none: skills
/// seed on a project install alone, and core refuses an edit there by the
/// key it names.
fn settings_root(scope: &Scope) -> Option<std::path::PathBuf> {
    match scope.canonical() {
        Scope::Project { root } => Some(root),
        Scope::Global => None,
    }
}

#[cfg(test)]
mod tests;
