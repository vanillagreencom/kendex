//! Safety decisions from the app: dismissing a finding, and the registry of
//! every decision recorded so far.

use kendex_core::engine::decisions::DecisionToken;
use kendex_core::engine::ops::{self, RecordedDecision};
use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::quality::reviews::DismissReason;
use kendex_core::{apply, manifest};
use serde::Serialize;
use specta::Type;

use crate::audit::{AuditView, ScopeError, view};

fn env() -> Result<Env, String> {
    Env::detect().map_err(|e| e.to_string())
}

fn every_scope(env: &Env) -> Result<Vec<Scope>, String> {
    let settings = kendex_core::settings::load(env).map_err(|e| e.to_string())?;
    let mut scopes = vec![Scope::Global];
    scopes.extend(
        settings
            .projects
            .iter()
            .cloned()
            .map(|root| Scope::Project { root }),
    );
    Ok(scopes)
}

/// A scope whose decisions could not be read, carried as data beside the
/// ones that could. A view promising every decision must say which
/// scopes it is not speaking for, never silently skip them.
#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DecisionsScopeError {
    pub scope: Scope,
    pub error: ScopeError,
}

#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DecisionsView {
    pub decisions: Vec<RecordedDecision>,
    pub errors: Vec<DecisionsScopeError>,
}

/// Every recorded decision across every scope, each read against what is
/// installed there now.
#[tauri::command(async)]
#[specta::specta]
pub fn list_decisions() -> Result<DecisionsView, String> {
    decisions_view(&env()?)
}

pub fn decisions_view(env: &Env) -> Result<DecisionsView, String> {
    let mut decisions = Vec::new();
    let mut errors = Vec::new();
    for scope in every_scope(env)? {
        match ops::list_decisions(env, &scope) {
            Ok(mut listed) => decisions.append(&mut listed),
            Err(error) => errors.push(DecisionsScopeError {
                scope,
                error: ScopeError::from(&error),
            }),
        }
    }
    Ok(DecisionsView { decisions, errors })
}

/// One record a dismissal wrote, as an undo names it: the same key and
/// fingerprint the registry uses, and the timestamp that pins this exact
/// record so an old undo cannot delete a newer decision at the same key.
#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DismissedRecord {
    pub key: String,
    pub fingerprint: String,
    pub dismissed_at: String,
}

/// What a dismissal came back with: the scope's fresh view, and exactly
/// what was written.
#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Dismissed {
    pub view: AuditView,
    pub records: Vec<DismissedRecord>,
}

/// Why a dismissal did not come back with its records — and, since the
/// write happens before they are read, whether the file changed anyway.
///
/// A string cannot carry that, and the caller cannot infer it: told only
/// that this failed, it says nothing was changed and leaves the editor
/// holding a copy of a file that moved under it. Both of those are wrong
/// in exactly the case the write landed.
#[derive(Serialize, Type)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum DismissFailed {
    /// Nothing was written. The decision is still there to make.
    Untouched { message: String },
    /// The decisions were written, and then the file could not be read
    /// back to say what an undo would need. What is on disk changed.
    Written { message: String },
}

impl DismissFailed {
    fn untouched(error: impl ToString) -> Self {
        Self::Untouched {
            message: error.to_string(),
        }
    }
}

/// Dismiss the findings these tokens name, for one reason, in one scope.
/// The tokens are re-read against a fresh audit before anything is written;
/// one that no longer names what is installed stops the whole call.
#[tauri::command(async)]
#[specta::specta]
pub fn dismiss_findings(
    scope: Scope,
    tokens: Vec<String>,
    reason: DismissReason,
) -> Result<Dismissed, DismissFailed> {
    let env = env().map_err(DismissFailed::untouched)?;
    let tokens = tokens
        .iter()
        .map(|token| DecisionToken::parse(token))
        .collect::<Result<Vec<_>, _>>()
        .map_err(DismissFailed::untouched)?;
    let plan = ops::dismiss(&env, &scope, &tokens, reason).map_err(DismissFailed::untouched)?;
    apply::execute(&env, &plan, None).map_err(DismissFailed::untouched)?;
    // Past here the decisions are on disk. Everything that can still go
    // wrong is a failure to describe what was written, never a failure to
    // write it, and it is told apart from the others for that reason.
    let records =
        written(&env, &scope, &tokens).map_err(|message| DismissFailed::Written { message })?;
    Ok(Dismissed {
        view: view(&env, &scope),
        records,
    })
}

/// The records as the write left them — read back from the manifest, so an
/// undo carries what is on disk rather than what the caller thinks the
/// clock said.
fn written(
    env: &Env,
    scope: &Scope,
    tokens: &[DecisionToken],
) -> Result<Vec<DismissedRecord>, String> {
    let path = manifest::manifest_path(env, scope);
    let manifest::ManifestFile::Current(manifest) =
        manifest::load(&path).map_err(|e| e.to_string())?
    else {
        return Err("the manifest could not be read back after the write".to_owned());
    };
    tokens
        .iter()
        .map(|token| {
            manifest
                .safety_reviews
                .get(&token.key)
                .and_then(|review| review.dismissed.get(&token.fingerprint))
                .map(|dismissal| DismissedRecord {
                    key: token.key.clone(),
                    fingerprint: token.fingerprint.clone(),
                    dismissed_at: dismissal.dismissed_at.clone(),
                })
                .ok_or_else(|| "the dismissal was not found after the write".to_owned())
        })
        .collect()
}

/// Take a dismissal back. `dismissed_at` pins the exact record: a stale undo
/// finding a newer dismissal at the same key refuses rather than deleting
/// somebody's later decision.
#[tauri::command(async)]
#[specta::specta]
pub fn revoke_dismissal(
    scope: Scope,
    key: String,
    fingerprint: String,
    dismissed_at: String,
) -> Result<AuditView, String> {
    let env = env()?;
    let plan = ops::revoke_dismissal(&env, &scope, &key, &fingerprint, Some(&dismissed_at))
        .map_err(|e| e.to_string())?;
    apply::execute(&env, &plan, None).map_err(|e| e.to_string())?;
    Ok(view(&env, &scope))
}

#[tauri::command(async)]
#[specta::specta]
pub fn revoke_safety_override(scope: Scope, key: String) -> Result<AuditView, String> {
    let env = env()?;
    let plan = ops::revoke_override(&env, &scope, &key).map_err(|e| e.to_string())?;
    apply::execute(&env, &plan, None).map_err(|e| e.to_string())?;
    Ok(view(&env, &scope))
}
