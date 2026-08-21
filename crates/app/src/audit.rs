use kendex_core::engine::{self, DriftRow, ItemSafety, ItemWarning, PlanOptions, ops};
use kendex_core::env::Env;
use kendex_core::error::CoreError;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::{apply, manifest};
use serde::Serialize;
use specta::Type;

fn env() -> Result<Env, String> {
    Env::detect().map_err(|e| e.to_string())
}

/// Why a scope couldn't be audited: a kind the UI can act on (retry, remove
/// the project, show the file) plus the plain-words message underneath it.
#[derive(Serialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum ScopeErrorKind {
    /// The lock exists but isn't readable as JSON, or as this build's lock
    /// shape — damaged, not merely old.
    LockCorrupt,
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
    /// What the safety rules found in the content installed here. Each row
    /// carries two scores that are never combined: safety, which can hold an
    /// install back, and quality, which only ever informs.
    pub safety: Vec<ItemSafety>,
    /// The kinds "keep these files" can be offered for. Adoption needs
    /// somewhere in the local source to put the content, and only these
    /// kinds have one — read from core so the page never offers an action
    /// that would error, and never keeps its own copy of the list.
    pub adoptable: Vec<ItemKind>,
    /// Installations the plan would write but the safety gate holds back.
    /// Kept apart from `safety` (which scores what is on disk) because the
    /// two describe different bytes: an accept has to name the hash of what
    /// apply would write, and only these rows carry it.
    pub held_back: Vec<ItemSafety>,
    /// Installations the plan would write that install with findings. The
    /// same bytes as `safety` where an item is already installed unchanged;
    /// for content that is new or changing, the findings that will need a
    /// decision after apply — said before the write, since a dismissal is
    /// about installed bytes and cannot be made on a plan.
    pub queued: Vec<ItemSafety>,
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
            held_back: Vec::new(),
            queued: Vec::new(),
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
    let safety = match engine::observed_safety(env, scope) {
        Ok(safety) => safety,
        Err(e) => return AuditView::failed(scope, &e),
    };
    let (held_back, queued): (Vec<ItemSafety>, Vec<ItemSafety>) =
        report.safety.into_iter().partition(ItemSafety::blocked);
    AuditView {
        scope: scope.clone(),
        drift: report.drift,
        plan: report
            .plan
            .ops
            .iter()
            .map(|op| op.description.clone())
            .collect(),
        notes: report.notes,
        warnings: report.warnings,
        safety,
        adoptable: adoptable(),
        held_back,
        queued: queued
            .into_iter()
            .filter(|row| !row.findings.is_empty())
            .collect(),
        error: None,
    }
}

#[tauri::command(async)]
#[specta::specta]
pub fn audit_all() -> Result<Vec<AuditView>, String> {
    let env = env()?;
    let settings = kendex_core::settings::load(&env).map_err(|e| e.to_string())?;
    let mut scopes = vec![Scope::Global];
    scopes.extend(
        settings
            .projects
            .iter()
            .cloned()
            .map(|root| Scope::Project { root }),
    );
    // One scope's unreadable lock or manifest must not blank the rest of the
    // audit — each scope's failure is carried as data on its own view.
    Ok(scopes.iter().map(|scope| view(&env, scope)).collect())
}

/// The apply path plans through the same loader the audit view used, so
/// the listed plan is what executes — including the schema upgrade a v0.1
/// manifest is owed on its first apply. (Orphan removal is the one opt-in
/// extra; the dialog lists each left-behind item beside its checkbox.)
pub fn apply_scope(
    env: &Env,
    scope: &Scope,
    remove_orphans: bool,
    allow_unsafe: Vec<String>,
) -> Result<AuditView, String> {
    // A manifest that vanished or turned legacy since the preview must be
    // said out loud, not answered with a silent empty apply.
    let path = manifest::manifest_path(env, scope);
    match manifest::load(&path).map_err(|e| e.to_string())? {
        manifest::ManifestFile::Current(_) => {}
        manifest::ManifestFile::Absent => return Err("no manifest for this scope yet".into()),
        manifest::ManifestFile::Legacy { .. } => {
            return Err(CoreError::LegacyManifest { path }.to_string());
        }
    }
    let options = PlanOptions {
        remove_orphans,
        removal_filter: None,
        allow_unsafe,
        ..PlanOptions::default()
    };
    // This apply is one scope, so that scope's rows are the whole run.
    let report = engine::plan_apply(env, scope, &options).map_err(|e| e.to_string())?;
    let rows: Vec<&engine::ItemSafety> = report.safety.iter().collect();
    engine::refuse_unmatched_grants(&options, &rows).map_err(|e| e.to_string())?;
    // The partial grant is the other half: one harness renders an item
    // differently from another, so a flag can name the content one of them
    // would get and none of the rest. A button that says "accept and
    // install" must not install some of them and hold back the others.
    for token in &options.allow_unsafe {
        let name = token.rsplit_once('@').map_or(token.as_str(), |(n, _)| n);
        if report
            .safety
            .iter()
            .any(|row| row.name == name && row.blocked())
        {
            return Err(format!(
                "'{name}' reads differently for another tool than the content you accepted — nothing was changed; review the findings again and accept each"
            ));
        }
    }
    apply::execute(env, &report.plan, None).map_err(|e| e.to_string())?;
    Ok(view(env, scope))
}

#[tauri::command(async)]
#[specta::specta]
pub fn apply_plan(
    scope: Scope,
    remove_orphans: bool,
    allow_unsafe: Vec<String>,
) -> Result<AuditView, String> {
    apply_scope(&env()?, &scope, remove_orphans, allow_unsafe)
}

#[tauri::command(async)]
#[specta::specta]
pub fn adopt_item(
    scope: Scope,
    kind: ItemKind,
    name: String,
    harness: HarnessId,
) -> Result<AuditView, String> {
    let env = env()?;
    let move_plan =
        engine::adopt::adopt(&env, &scope, kind, &name, harness).map_err(|e| e.to_string())?;
    apply::execute(&env, &move_plan, None).map_err(|e| e.to_string())?;
    let report = engine::audit(&env, &scope).map_err(|e| e.to_string())?;
    apply::execute(&env, &report.plan, None).map_err(|e| e.to_string())?;
    Ok(view(&env, &scope))
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
    // The page this was clicked on may be a minute old. Nothing is written
    // over a choice that is no longer on offer: the apply that follows is
    // the scope's whole plan, like every apply, and it must not run because
    // a button answered a question that had already gone away.
    let blocked = engine::audit(env, scope)
        .map_err(|e| e.to_string())?
        .drift
        .into_iter()
        .any(|row| {
            row.kind == kind
                && row.name == name
                && row.cause == Some(engine::DriftCause::UnmanagedContent)
        });
    if !blocked {
        return Err(format!(
            "{name} has no files waiting on that choice any more — nothing was changed"
        ));
    }
    let manifest =
        kendex_core::manifest::load_for_mutation(&kendex_core::manifest::manifest_path(env, scope))
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "no manifest".to_owned())?;
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(env, scope))
        .map_err(|e| e.to_string())?;
    let report = engine::plan_scope(
        env,
        scope,
        &manifest,
        &lock,
        &engine::PlanOptions {
            replace_unmanaged_names: Some(vec![(kind, name)]),
            ..Default::default()
        },
    )
    .map_err(|e| e.to_string())?;
    apply::execute(env, &report.plan, None).map_err(|e| e.to_string())?;
    Ok(view(env, scope))
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
    apply::execute(&env, &report.plan, None).map_err(|e| e.to_string())?;
    Ok(view(&env, &scope))
}

#[tauri::command(async)]
#[specta::specta]
pub fn remove_item(scope: Scope, kind: ItemKind, name: String) -> Result<AuditView, String> {
    let env = env()?;
    // Removing one item never takes its unneeded leftovers with it here:
    // the page has nowhere to preview that yet, and a sweep the user did
    // not see is exactly the surprise the preview step exists to stop.
    let report = ops::remove(&env, &scope, std::slice::from_ref(&name), Some(kind), false)
        .map_err(|e| e.to_string())?;
    apply::execute(&env, &report.plan, None).map_err(|e| e.to_string())?;
    Ok(view(&env, &scope))
}
