//! Bringing a package current, and moving where it is held. Both write
//! through a plan scoped to the packages they name, so a place's Update
//! never moves that scope's other followers, and both answer with what
//! the plan wrote and what it refused rather than the view alone.

use kendex_core::engine;
use kendex_core::env::Env;
use kendex_core::model::{ItemKind, Scope};
use kendex_core::package;

use crate::audit::{AuditView, settle_report};

use super::env;

/// What a single-package apply did to the package it named, beside the
/// scope's view afterwards. The plan holds a rendering back rather than
/// writing over a copy somebody changed, and the view alone cannot say
/// which of the two happened — a caller reading only the view says
/// "Updated" over a package that never moved. Every command that applies
/// a single package answers with this, the version switch included: a
/// hold that moves in the manifest is refused on disk for the same
/// reasons an update is. A batch says the same three things per package
/// it named, in [`PackageOutcome`].
#[derive(serde::Serialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct PackageUpdate {
    pub view: AuditView,
    /// Renderings the plan refused to write over and left exactly as they
    /// are. Empty when the package moved everywhere it is installed.
    pub held_back: Vec<engine::DriftRow>,
    /// Renderings the plan took to the trash with nothing written back —
    /// refused, and with nothing of the person's in the files to keep.
    pub removed: Vec<engine::DriftRow>,
    /// Renderings this apply wrote. Non-empty beside `held_back` is the
    /// partial case: current in one tool, held in another.
    pub moved: Vec<engine::DriftRow>,
}

/// Bring one package current and apply — the Updates page's per-package
/// and per-place Update, and the package page's. The scope's other
/// followers stay at the commits their lock records, except one the lock
/// cannot place, which resolves fresh the way a whole-scope apply gives it
/// anyway. `kendex refresh` and the whole-scope apply are the plans that
/// bring a whole place current; `Update all` names every row a place has
/// in one call to [`package_update_many`].
#[tauri::command(async)]
#[specta::specta]
pub fn package_update(scope: Scope, kind: ItemKind, name: String) -> Result<PackageUpdate, String> {
    // A kind the engine never derives plans nothing, and an empty plan
    // reads as "already current" on the page that asked. The row the page
    // read carries this same refusal, so the button is not offered — this
    // is the floor under a caller that asks anyway.
    if !engine::plans_per_package(kind) {
        return Err(format!(
            "{} '{name}': {}",
            kind.name(),
            engine::NO_PER_PACKAGE_UPDATE
        ));
    }
    let env = env()?;
    let report = package::update_one(&env, &scope, kind, &name).map_err(|e| e.to_string())?;
    settle_package(&env, &scope, kind, &name, &report)
}

/// What a batched apply did to one of the packages it named. The same
/// three dispositions [`PackageUpdate`] carries, said per package because
/// a batch settles several at once, with the kind and name the caller
/// matches them back to its rows by.
#[derive(serde::Serialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct PackageOutcome {
    pub kind: ItemKind,
    pub name: String,
    pub held_back: Vec<engine::DriftRow>,
    pub removed: Vec<engine::DriftRow>,
    pub moved: Vec<engine::DriftRow>,
}

/// What a batched apply did: the scope's standing afterwards once, and
/// what became of each package the caller named. One view, because the
/// packages came current in one pass and there is only one standing to
/// read.
#[derive(serde::Serialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct PackagesUpdate {
    pub view: AuditView,
    /// One entry per target, in the order they were given.
    pub packages: Vec<PackageOutcome>,
}

/// What a plan does to one package, read off the report before the apply
/// runs — that is the record naming which renderings the plan writes and
/// which it refuses.
fn package_outcome(report: &engine::EngineReport, kind: ItemKind, name: &str) -> PackageOutcome {
    PackageOutcome {
        kind,
        name: name.to_owned(),
        held_back: package::held_back(report, kind, name)
            .into_iter()
            .cloned()
            .collect(),
        removed: package::removed(report, kind, name)
            .into_iter()
            .cloned()
            .collect(),
        moved: package::moving(report, kind, name)
            .into_iter()
            .cloned()
            .collect(),
    }
}

/// Apply one package-scoped plan and answer with what it did to that
/// package beside the standing it leaves.
fn settle_package(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    report: &engine::EngineReport,
) -> Result<PackageUpdate, String> {
    let one = package_outcome(report, kind, name);
    Ok(PackageUpdate {
        view: settle_report(env, scope, report)?,
        held_back: one.held_back,
        removed: one.removed,
        moved: one.moved,
    })
}

/// Bring several of a place's packages current in one pass — what
/// `Update all` asks each scope for, having grouped its rows by the place
/// they live in. The scope reconciles, journals and applies once; every
/// follower the caller did not name stays at the commit its lock records,
/// exactly as it does under the single-package update.
///
/// A target carrying a `hold` is a held place whose Update moves the hold,
/// the batched shape of [`package_set_rev`]; one without follows its
/// source. Both land in the same plan, so a place with some of each is
/// still one apply.
#[tauri::command(async)]
#[specta::specta]
pub fn package_update_many(
    scope: Scope,
    targets: Vec<package::UpdateTarget>,
) -> Result<PackagesUpdate, String> {
    // Named rows are what this command is for. Asked about none it would
    // exempt nothing, hold every declaration, and report an update over a
    // pass that moved no version.
    if targets.is_empty() {
        return Err("no packages were named to update".to_owned());
    }
    // The same refusal the single-package command makes, and made for
    // every target before any of them is planned: a kind the engine never
    // derives plans nothing, and one such target would otherwise leave the
    // rest of the batch reporting an update that never happened.
    for target in &targets {
        if !engine::plans_per_package(target.kind) {
            return Err(format!(
                "{} '{}': {}",
                target.kind.name(),
                target.name,
                engine::NO_PER_PACKAGE_UPDATE
            ));
        }
    }
    let env = env()?;
    let report = package::update_many(&env, &scope, &targets).map_err(|e| e.to_string())?;
    let packages = targets
        .iter()
        .map(|target| package_outcome(&report, target.kind, &target.name))
        .collect();
    Ok(PackagesUpdate {
        view: settle_report(&env, &scope, &report)?,
        packages,
    })
}

/// Hold a package at a version (or let it follow again) and apply the
/// change, scoped to the package: every other follower in the scope reads
/// the commit its lock records, so moving one hold does not bring the
/// neighbours current. The exception is a follower the lock cannot place
/// — never installed, or installations disagreeing — which resolves fresh
/// here as it would under a whole-scope apply.
///
/// The answer is the same `PackageUpdate` the update command gives, and
/// for the same reason: the manifest takes the new hold either way, while
/// a rendering somebody edited is held back on disk, so a caller reading
/// the view alone would report a switch that never reached the files.
#[tauri::command(async)]
#[specta::specta]
pub fn package_set_rev(
    scope: Scope,
    kind: ItemKind,
    name: String,
    rev: Option<String>,
) -> Result<PackageUpdate, String> {
    let env = env()?;
    let report = package::set_rev_with(
        &env,
        &scope,
        kind,
        &name,
        rev.as_deref(),
        &engine::PlanOptions::for_package(kind, &name),
    )
    .map_err(|e| e.to_string())?;
    settle_package(&env, &scope, kind, &name, &report)
}
