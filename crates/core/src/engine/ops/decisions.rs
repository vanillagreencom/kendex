//! Making, listing and taking back safety decisions.
//!
//! Every mutation here is one journaled manifest write for one scope and
//! nothing else — the item's files never move on a decision. A dismissal is
//! checked against what is on disk *now*, not against whatever view the
//! caller last saw: the review data a page renders can be a minute old, so
//! the token it sends is re-read against a fresh audit and refused unless
//! the content and the finding are still exactly what it names. A batch
//! with one bad token writes nothing.

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::engine::decisions::DecisionToken;
use crate::engine::{ItemSafety, observed_rows};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{self, Manifest};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::quality::Finding;
use crate::quality::overrides::{OverrideState, fingerprints};
use crate::quality::reviews::{
    DismissReason, Dismissal, DismissalState, SafetyReview, dismissal_state,
};

use super::manifest_for_mutation;

/// Record that these findings are not problems, for the reason given, on
/// exactly the content each token names. Refuses — writing nothing — if any
/// token names content that has changed, a finding that is no longer there,
/// or an item whose findings are already settled by an acceptance or still
/// held back: a dismissal on a held-back item would look like a decision
/// and decide nothing.
pub fn dismiss(
    env: &Env,
    scope: &Scope,
    tokens: &[DecisionToken],
    reason: DismissReason,
) -> Result<Plan> {
    let mut manifest = manifest_for_mutation(env, scope)?;
    let rows = observed_rows(env, scope)?;
    let now = crate::clock::timestamp();
    for token in tokens {
        if !token.in_scope(scope) {
            return Err(stale(token, "it was issued for another scope's manifest"));
        }
        let row = installed(&rows, &token.key)?;
        let Some(review_hash) = row.review_hash.as_deref() else {
            return Err(stale(token, "its content cannot be read here"));
        };
        if !token.names(review_hash) {
            return Err(stale(
                token,
                "the content changed since the finding was read",
            ));
        }
        if !fingerprints(&row.findings).contains(&token.fingerprint) {
            // A token carries the bytes it was minted against but not the
            // rule set, so a token from an older printed output can name a
            // finding that is still there under a new identity. Say both,
            // rather than telling somebody a finding they can see is gone.
            return Err(stale(
                token,
                "the finding is no longer there, or an upgrade changed how it is identified — re-run `kendex findings` for the token it prints now",
            ));
        }
        if row.override_state.unblocks() {
            return Err(stale(
                token,
                "every finding on this item is already accepted",
            ));
        }
        if row.blocked() {
            return Err(stale(
                token,
                "the item is held back — accept its findings or remove it instead",
            ));
        }
        let source = match reason {
            DismissReason::TrustedSource => Some(row.provenance.clone().ok_or_else(|| {
                stale(token, "kendex did not install it from a source it resolved, so there is no source to trust")
            })?),
            _ => None,
        };
        // A snapshot of other content is stale as a whole: what it says was
        // reviewed is gone. This decision starts a fresh one. The record is
        // keyed by the installation's own spelling, not the token's — a
        // hand-typed alias for a tool would otherwise land under a key
        // nothing reads back.
        let review = manifest
            .safety_reviews
            .entry(row.key())
            .and_modify(|review| {
                if review.stale_why(Some(review_hash)).is_some() {
                    *review = SafetyReview::of(review_hash);
                }
            })
            .or_insert_with(|| SafetyReview::of(review_hash));
        review.dismissed.insert(
            token.fingerprint.clone(),
            Dismissal {
                reason,
                dismissed_at: now.clone(),
                source,
            },
        );
    }
    let what = match tokens.len() {
        1 => "dismiss a safety finding".to_owned(),
        n => format!("dismiss {n} safety findings"),
    };
    manifest_write(env, scope, manifest, what)
}

/// Take a dismissal back. `dismissed_at` pins the exact record: an undo
/// from a toast must never delete a newer dismissal that replaced the one
/// the toast was about, so an undo passes the timestamp it was given and is
/// refused if the record has moved on. A caller acting on the live list
/// passes what the list showed. The pin is as fine as the clock — whole
/// seconds — so two decisions on one finding inside a single second read as
/// one record; the window is the width of a click, not of a stale toast.
pub fn revoke_dismissal(
    env: &Env,
    scope: &Scope,
    key: &str,
    fingerprint: &str,
    dismissed_at: Option<&str>,
) -> Result<Plan> {
    let mut manifest = manifest_for_mutation(env, scope)?;
    let missing = || CoreError::DismissalNotFound {
        key: key.to_owned(),
        fingerprint: fingerprint.to_owned(),
    };
    let review = manifest.safety_reviews.get_mut(key).ok_or_else(missing)?;
    let recorded = review.dismissed.get(fingerprint).ok_or_else(missing)?;
    if let Some(expected) = dismissed_at
        && recorded.dismissed_at != expected
    {
        return Err(CoreError::DecisionReplaced {
            key: key.to_owned(),
            fingerprint: fingerprint.to_owned(),
        });
    }
    review.dismissed.remove(fingerprint);
    if review.dismissed.is_empty() {
        manifest.safety_reviews.remove(key);
    }
    manifest_write(
        env,
        scope,
        manifest,
        format!("take back the dismissal of a finding on {key}"),
    )
}

/// Withdraw a recorded safety review. The override leaves the manifest by
/// a planned, journaled write and nothing else moves: the next previewed
/// apply is where the item goes back to being held and its installed copy
/// goes to the trash — a revoke from a settings page must not carry a
/// scope's unrelated pending changes with it.
pub fn revoke_override(env: &Env, scope: &Scope, key: &str) -> Result<Plan> {
    let mut manifest = manifest_for_mutation(env, scope)?;
    if manifest.safety_overrides.remove(key).is_none() {
        return Err(CoreError::OverrideNotFound {
            key: key.to_owned(),
        });
    }
    manifest_write(
        env,
        scope,
        manifest,
        format!("withdraw the accepted safety findings recorded under {key}"),
    )
}

fn manifest_write(env: &Env, scope: &Scope, manifest: Manifest, what: String) -> Result<Plan> {
    let path = manifest::manifest_path(env, scope);
    Ok(Plan {
        scope: scope.clone(),
        ops: vec![PlannedOp {
            description: what,
            op: Op::WriteManifest {
                pre: Pre::observed(&path)?,
                path,
                manifest: Box::new(manifest),
            },
        }],
    })
}

/// The installed row a key names. A key that does not parse names nothing
/// that could be installed, and says so in its own words.
fn installed<'a>(rows: &'a [ItemSafety], key: &str) -> Result<&'a ItemSafety> {
    let (kind, name, harness) =
        crate::lock::parse_entry_key(key).ok_or_else(|| CoreError::DecisionKey {
            key: key.to_owned(),
        })?;
    rows.iter()
        .find(|row| row.kind == kind && row.name == name && row.harness == harness)
        .ok_or(CoreError::ItemNotFound {
            kind,
            name: name.to_owned(),
            harness,
        })
}

fn stale(token: &DecisionToken, why: &str) -> CoreError {
    CoreError::DecisionStale {
        token: token.to_string(),
        why: why.to_owned(),
    }
}

/// What one record decided.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(
    tag = "kind",
    rename_all = "kebab-case",
    rename_all_fields = "camelCase"
)]
pub enum DecisionRecord {
    /// A whole item's findings, read and accepted.
    Accepted { findings: u32, granted_at: String },
    /// One finding, judged not to be a problem. `finding` is the current
    /// text of what it dismissed, present while that finding is still there.
    Dismissed {
        fingerprint: String,
        reason: DismissReason,
        dismissed_at: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        finding: Option<Finding>,
    },
}

/// Whether a recorded decision still speaks for anything.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum RecordState {
    /// Describing exactly what is installed now.
    Active,
    /// Recorded, but what it was made against has changed since.
    Stale { why: String },
    /// The item it was about is no longer installed here.
    Obsolete,
}

/// One recorded decision, as the registry lists it. `key` is the manifest's
/// own spelling and is what revoke takes back, so even an entry a hand edit
/// mangled can still be withdrawn; the typed fields are parsed from it for
/// display and absent where it does not parse.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct RecordedDecision {
    pub scope: Scope,
    pub key: String,
    pub kind: Option<ItemKind>,
    pub name: String,
    pub harness: Option<HarnessId>,
    pub record: DecisionRecord,
    pub state: RecordState,
}

/// Every decision recorded in this scope's manifest, read against what is
/// installed there now.
pub fn list_decisions(env: &Env, scope: &Scope) -> Result<Vec<RecordedDecision>> {
    let manifest = match manifest::load(&manifest::manifest_path(env, scope))? {
        manifest::ManifestFile::Current(manifest) => *manifest,
        _ => return Ok(Vec::new()),
    };
    if manifest.safety_overrides.is_empty() && manifest.safety_reviews.is_empty() {
        return Ok(Vec::new());
    }
    let rows = observed_rows(env, scope)?;
    let mut out = Vec::new();
    for (key, recorded) in &manifest.safety_overrides {
        let (kind, name, harness) = parsed(key);
        let state = match installed(&rows, key) {
            Ok(row) => match &row.override_state {
                OverrideState::Active => RecordState::Active,
                OverrideState::Stale { why } => RecordState::Stale { why: why.clone() },
                OverrideState::Absent => RecordState::Obsolete,
            },
            Err(_) => RecordState::Obsolete,
        };
        out.push(RecordedDecision {
            scope: scope.clone(),
            key: key.clone(),
            kind,
            name,
            harness,
            record: DecisionRecord::Accepted {
                findings: u32::try_from(recorded.findings.len()).unwrap_or(u32::MAX),
                granted_at: recorded.granted_at.clone(),
            },
            state,
        });
    }
    for (key, review) in &manifest.safety_reviews {
        let (kind, name, harness) = parsed(key);
        let row = installed(&rows, key).ok();
        for (fingerprint, dismissal) in &review.dismissed {
            let (state, finding) = match row {
                None => (RecordState::Obsolete, None),
                Some(row) => {
                    let finding = row
                        .findings
                        .iter()
                        .find(|finding| finding.fingerprint() == *fingerprint)
                        .cloned();
                    let state = match dismissal_state(
                        review,
                        dismissal,
                        row.review_hash.as_deref(),
                        row.provenance.as_deref(),
                    ) {
                        DismissalState::Active if finding.is_some() => RecordState::Active,
                        DismissalState::Active => RecordState::Stale {
                            why: "the finding it dismissed is no longer reported".to_owned(),
                        },
                        DismissalState::Stale { why } => RecordState::Stale { why },
                    };
                    (state, finding)
                }
            };
            out.push(RecordedDecision {
                scope: scope.clone(),
                key: key.clone(),
                kind,
                name: name.clone(),
                harness,
                record: DecisionRecord::Dismissed {
                    fingerprint: fingerprint.clone(),
                    reason: dismissal.reason,
                    dismissed_at: dismissal.dismissed_at.clone(),
                    finding,
                },
                state,
            });
        }
    }
    Ok(out)
}

fn parsed(key: &str) -> (Option<ItemKind>, String, Option<HarnessId>) {
    match crate::lock::parse_entry_key(key) {
        Some((kind, name, harness)) => (Some(kind), name.to_owned(), Some(harness)),
        None => (None, key.to_owned(), None),
    }
}
