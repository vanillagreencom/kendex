use kendex_core::engine::{self, DriftRow, ItemSafety, ItemWarning, PlanOptions, ops};
use kendex_core::env::Env;
use kendex_core::error::CoreError;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::{apply, manifest};
use serde::Serialize;
use specta::Type;

use crate::scopes::env;

/// Why a scope couldn't be audited: a kind the UI can act on (retry, remove
/// the project, show the file) plus the plain-words message underneath it.
#[derive(Serialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum ScopeErrorKind {
    /// The lock is not readable as this build's lock: damaged JSON, or a
    /// record an older kendex wrote. Nothing converts either, and the way
    /// out is the same — move it aside and apply again.
    LockCorrupt,
    /// The manifest was written by an older kendex: it parses, but not
    /// into a shape this build reads, and nothing converts it. Kept
    /// apart from a damaged lock because the file is intact and the
    /// person's own — moving it aside loses what they wrote in it.
    ManifestOutdated,
    /// The manifest or lock was written by a newer kendex than this one.
    SchemaTooNew,
    /// The manifest parses but fails validation.
    ManifestInvalid,
    Other,
}

#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ScopeError {
    pub kind: ScopeErrorKind,
    pub message: String,
}

/// What the Audit page renders: drift rows plus the human-readable plan
/// that would fix them.
#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct AuditView {
    pub scope: Scope,
    pub drift: Vec<DriftRow>,
    pub plan: Vec<String>,
    pub notes: Vec<String>,
    pub warnings: Vec<ItemWarning>,
    /// Every installation here, scored — the clean ones included, so a
    /// package with nothing found still has a score to show. Each row
    /// carries two scores that are never combined: safety and quality.
    /// Advisory both — nothing acts on either.
    pub safety: Vec<ItemSafety>,
    /// The kinds "Manage these files" can be offered for. Adoption needs
    /// somewhere in the local source to put the content, and only these
    /// kinds have one — read from core so the page never offers an action
    /// that would error, and never keeps its own copy of the list.
    pub adoptable: Vec<ItemKind>,
    /// Which ways out each blocked installation actually has, answered by
    /// core per row like the kinds above. The page groups and draws these;
    /// it never works them out from the cause, which is how one surface
    /// ends up offering an action the plan rejects.
    pub exits: Vec<engine::exits::RowExits>,
    /// What a removal in this action did about the repository effects of
    /// the packages that left with it: the same lines the terminal prints,
    /// so the window says what ran rather than leaving a repository armed
    /// against scripts that are gone. Empty on a plain read and on every
    /// action that took no declaring package away — and left off the wire
    /// entirely when it is empty, which is almost every read.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub undone: Vec<String>,
    /// Set when this one scope couldn't be read at all — a corrupt or
    /// future-version lock or manifest. Carried as data so one scope's
    /// failure never blanks every other scope's audit (drift/plan/notes/
    /// warnings/safety are empty alongside it).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ScopeError>,
}

impl From<&CoreError> for ScopeError {
    fn from(error: &CoreError) -> Self {
        let kind = match error {
            CoreError::LockCorrupt { .. } => ScopeErrorKind::LockCorrupt,
            CoreError::LegacyManifest { .. } => ScopeErrorKind::ManifestOutdated,
            CoreError::SchemaTooNew { .. } => ScopeErrorKind::SchemaTooNew,
            CoreError::ManifestInvalid { .. } => ScopeErrorKind::ManifestInvalid,
            _ => ScopeErrorKind::Other,
        };
        ScopeError {
            kind,
            message: error.to_string(),
        }
    }
}

impl AuditView {
    fn failed(scope: &Scope, error: &CoreError) -> Self {
        AuditView {
            scope: scope.clone(),
            drift: Vec::new(),
            plan: Vec::new(),
            notes: Vec::new(),
            warnings: Vec::new(),
            safety: Vec::new(),
            adoptable: adoptable(),
            exits: Vec::new(),
            undone: Vec::new(),
            error: Some(ScopeError::from(error)),
        }
    }
}

fn adoptable() -> Vec<ItemKind> {
    ItemKind::ALL
        .iter()
        .copied()
        .filter(|kind| engine::adopt::supports(*kind))
        .collect()
}

pub fn view(env: &Env, scope: &Scope) -> AuditView {
    let report = match engine::audit(env, scope) {
        Ok(report) => report,
        Err(e) => return AuditView::failed(scope, &e),
    };
    let safety = match engine::observed_rows(env, scope) {
        Ok(safety) => safety,
        Err(e) => return AuditView::failed(scope, &e),
    };
    AuditView {
        scope: scope.clone(),
        exits: engine::exits::for_rows(env, scope, &report.drift),
        drift: report.drift,
        plan: report.plan.ops.iter().map(apply::PlannedOp::line).collect(),
        notes: report.notes,
        warnings: report.warnings,
        safety,
        adoptable: adoptable(),
        undone: Vec::new(),
        error: None,
    }
}

/// Execute a report and answer with the scope's standing beside what the
/// removal did about any repository effect leaving with it — the one way a
/// command here writes a report it holds.
pub(crate) fn settle_report(
    env: &Env,
    scope: &Scope,
    report: &engine::EngineReport,
) -> Result<AuditView, String> {
    let undone = crate::repo_effects::write(env, report)?;
    Ok(AuditView {
        undone,
        ..view(env, scope)
    })
}

#[tauri::command(async)]
#[specta::specta]
pub fn audit_all() -> Result<Vec<AuditView>, String> {
    let env = env()?;
    // The same enumeration every other surface names a project from: a
    // list assembled here could disagree with the one behind a "See
    // Problems" link, and the link would land on a page reporting nothing
    // wrong.
    let scopes = crate::scopes::all(&env)?;
    // One scope's unreadable lock or manifest must not blank the rest of the
    // audit — each scope's failure is carried as data on its own view.
    Ok(scopes.iter().map(|scope| view(&env, scope)).collect())
}

/// The apply path plans through the same loader the audit view used, so
/// the listed plan is what executes, and a manifest the view refused is
/// refused here too. (Orphan removal is the one opt-in extra; the dialog
/// lists each left-behind item beside its checkbox.)
pub fn apply_scope(env: &Env, scope: &Scope, remove_orphans: bool) -> Result<AuditView, String> {
    // A manifest that vanished since the preview must be said out loud,
    // not answered with a silent empty apply.
    let path = manifest::manifest_path(env, scope);
    match manifest::load(&path).map_err(|e| e.to_string())? {
        manifest::ManifestFile::Current(_) => {}
        manifest::ManifestFile::Absent => return Err("no manifest for this scope yet".into()),
    }
    let options = PlanOptions {
        remove_orphans,
        removal_filter: None,
        ..PlanOptions::default()
    };
    let report = engine::plan_apply(env, scope, &options).map_err(|e| e.to_string())?;
    settle_report(env, scope, &report)
}

#[tauri::command(async)]
#[specta::specta]
pub fn apply_plan(scope: Scope, remove_orphans: bool) -> Result<AuditView, String> {
    apply_scope(&env()?, &scope, remove_orphans)
}

#[tauri::command(async)]
#[specta::specta]
pub fn adopt_item(
    scope: Scope,
    kind: ItemKind,
    name: String,
    harnesses: Vec<HarnessId>,
) -> Result<AuditView, String> {
    let env = env()?;
    // Every tool the item is blocked for, in one plan: handed over one at a
    // time, each tool's copy landed on top of the last and the declaration
    // kept only the first tool, leaving the rest with files nothing manages.
    let move_plan =
        engine::adopt::adopt(&env, &scope, kind, &name, &harnesses).map_err(|e| e.to_string())?;
    apply::execute(&env, &move_plan).map_err(|e| e.to_string())?;
    let report = engine::audit(&env, &scope).map_err(|e| e.to_string())?;
    settle_report(&env, &scope, &report)
}

/// Install what the manifest declares over the files already sitting where
/// one item goes — the other direction from adopting them. Scoped to the
/// item the person clicked, so a neighbour blocked the same way keeps its
/// files until they decide about it too.
pub fn replace_unmanaged(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: String,
) -> Result<AuditView, String> {
    // The page this was clicked on may be a minute old, and the apply that
    // follows is the scope's whole plan. Planning refuses a take-over that
    // reaches nothing, or one that would settle some of an item's places
    // and leave the rest blocked — read off this same plan, so nothing can
    // change between the check and what it guards.
    //
    // Planned from the manifest as it sits on disk, like every apply: a
    // normalized copy already looks current, so planning from one would
    // slip a file past the floor the audit and every other read refuse.
    let report = engine::plan_apply(
        env,
        scope,
        &engine::PlanOptions {
            replace_unmanaged_names: Some(vec![(kind, name)]),
            ..Default::default()
        },
    )
    .map_err(|e| e.to_string())?;
    settle_report(env, scope, &report)
}

#[tauri::command(async)]
#[specta::specta]
pub fn replace_unmanaged_item(
    scope: Scope,
    kind: ItemKind,
    name: String,
) -> Result<AuditView, String> {
    replace_unmanaged(&env()?, &scope, kind, name)
}

#[tauri::command(async)]
#[specta::specta]
pub fn toggle_item(
    scope: Scope,
    kind: ItemKind,
    name: String,
    enabled: bool,
) -> Result<AuditView, String> {
    let env = env()?;
    let report = ops::toggle(
        &env,
        &scope,
        std::slice::from_ref(&name),
        Some(kind),
        enabled,
    )
    .map_err(|e| e.to_string())?;
    settle_report(&env, &scope, &report)
}

/// Take one item out of a scope, against the environment it is given.
///
/// Removing one item never takes its unneeded leftovers with it here: the
/// page has nowhere to preview that yet, and a sweep the user did not see
/// is exactly the surprise the preview step exists to stop.
pub fn remove(env: &Env, scope: &Scope, kind: ItemKind, name: &str) -> Result<AuditView, String> {
    let report = ops::remove(env, scope, &[name.to_owned()], Some(kind), false)
        .map_err(|e| e.to_string())?;
    settle_report(env, scope, &report)
}

#[tauri::command(async)]
#[specta::specta]
pub fn remove_item(scope: Scope, kind: ItemKind, name: String) -> Result<AuditView, String> {
    remove(&env()?, &scope, kind, &name)
}
