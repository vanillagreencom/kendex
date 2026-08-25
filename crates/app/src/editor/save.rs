//! The Customize tab's whole-manifest read and write.
//!
//! Every other write in the app is a targeted operation that loads,
//! changes and saves in one breath. This one hands a person the whole
//! file, waits while they type, and writes all of it back — so it is the
//! one write that can put an older file over a newer one, and the only
//! one that carries the base of the file its copy came from to stop that.

use kendex_core::apply::{self, Op, PlannedOp, Pre};
use kendex_core::base::Base;
use kendex_core::engine::{self, PlanOptions, ops};
use kendex_core::env::Env;
use kendex_core::lock::{load as load_lock, lock_path};
use kendex_core::manifest::{self, Finding, Manifest};
use kendex_core::model::Scope;
use serde::Serialize;
use specta::Type;

use super::env;
use crate::audit::{AuditView, view};
use crate::whole_file::{WriteRefused, stale_at};

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

/// Write an edited manifest and reconcile the scope to it.
///
/// `base` is what the file was when this copy was read. A whole manifest
/// goes back with every save, so a copy read before something else wrote
/// the file would put that back — and the caller cannot be relied on to
/// notice. Refusing here needs no caller to remember anything.
#[tauri::command(async)]
#[specta::specta]
pub fn update_manifest(
    scope: Scope,
    manifest: Manifest,
    base: Option<String>,
) -> Result<AuditView, WriteRefused> {
    // The bytes behind this base were read in the editor, so it arrives
    // as a claim and is only ever compared, never believed.
    write_manifest(&env()?, scope, manifest, Base::claimed(base))
}

/// The write itself, against a given environment — which is what makes it
/// reachable from a test. The command above only finds the environment.
fn write_manifest(
    env: &Env,
    scope: Scope,
    manifest: Manifest,
    claimed: Base,
) -> Result<AuditView, WriteRefused> {
    let path = manifest::manifest_path(env, &scope);
    // One read answers both questions: whether the file is still the one
    // the copy came from, and whether there is a file at all — the moment
    // first-creation seeding happens. A file that cannot be read is a
    // failure to say out loud, not a stale copy: the reload cannot fix a
    // permission or an encoding, and offering it would hide what did.
    let (current, now) = manifest::read_for_mutation(&path).map_err(|e| e.to_string())?;
    if now != claimed {
        return Err(WriteRefused::Stale);
    }
    let mut manifest = match current {
        Some(_) => manifest,
        None => on_first_creation(
            manifest,
            ops::manifest_for_mutation(env, &scope).map_err(|e| e.to_string())?,
        ),
    };
    // A custom hook's name is its identity everywhere downstream; saving is
    // when a derived one stops being derived.
    kendex_core::hook::name_custom_hooks(&mut manifest);
    check(&manifest)?;
    let lock = load_lock(&lock_path(env, &scope)).map_err(|e| e.to_string())?;
    // The plan binds its own manifest write to the file this copy came
    // from, so a writer landing after the check above is refused by the
    // apply rather than overwritten.
    let options = PlanOptions {
        manifest_base: Some(claimed.clone()),
        ..PlanOptions::default()
    };
    let mut report =
        engine::plan_scope(env, &scope, &manifest, &lock, &options).map_err(|e| e.to_string())?;
    // Where this write ends up, which is not always where it was aimed: a
    // rename generation retargets every write planned against the old name,
    // and a refusal from one of those names the file it was retargeted to.
    // Core names both, so this cannot drift from how the retargeting works.
    let targets = manifest::manifest_paths(env, &scope);
    let persisted = engine::persists_manifest(&report.plan.ops);
    if !persisted {
        // After any rename-generation prefix, at the name the prefix
        // leaves the file under. Planned before the rename this write
        // would change the old file and stale the rename's own source
        // precondition; planned at the old name after it, it would
        // recreate the old file. The base still holds across the move —
        // a rename preserves bytes, so the file at the new name is the
        // one the copy was read from.
        let index = kendex_core::rename::rename_prefix_len(&report.plan.ops);
        let write_path = match index {
            0 => path.clone(),
            _ => targets[0].clone(),
        };
        report.plan.ops.insert(
            index,
            PlannedOp {
                description: "Save kendex.toml".into(),
                op: Op::WriteManifest {
                    pre: Pre::from(&claimed),
                    path: write_path,
                    manifest: Box::new(manifest),
                },
            },
        );
    }
    // The bound precondition refuses a file that moved between the check
    // above and the write itself, and that refusal is the same answer the
    // check gives — so it reaches the editor as the same choice.
    apply::execute(env, &report.plan, None).map_err(|error| match stale_at(&error, &targets) {
        true => WriteRefused::Stale,
        false => WriteRefused::Failed {
            message: error.to_string(),
        },
    })?;
    Ok(view(env, &scope))
}

#[cfg(test)]
mod tests;
