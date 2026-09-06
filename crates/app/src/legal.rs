//! The terms step: what the first-run screen asks, and the record it
//! leaves behind.
//!
//! The rule lives in `kendex_core::legal`, which the command line obeys
//! from its own first run against the same settings file. Nothing is
//! decided here, and nothing is decided in the UI either: a screen that
//! worked out for itself whether to ask would be a second copy of that
//! rule, and the two would disagree the first time a version moved.

use kendex_core::legal::TermsAcceptance;
use kendex_core::settings::AppSettings;
use serde::Serialize;
use specta::Type;

use crate::scopes::env;

/// Whether to ask, and what is on record — from one read, because the
/// first-run screen and the About row would otherwise hold two answers
/// taken at different moments, and only one of them would be right after
/// an accept.
#[derive(Debug, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct TermsState {
    pub ask: bool,
    pub accepted: Option<TermsAcceptance>,
}

impl From<AppSettings> for TermsState {
    fn from(settings: AppSettings) -> TermsState {
        TermsState {
            ask: kendex_core::legal::asks_again(settings.terms.as_ref()),
            accepted: settings.terms,
        }
    }
}

#[tauri::command(async)]
#[specta::specta]
pub fn terms_state() -> Result<TermsState, String> {
    kendex_core::settings::load(&env()?)
        .map(TermsState::from)
        .map_err(|error| error.to_string())
}

/// Record that the person accepted the documents this build asks about.
///
/// Its own targeted write rather than the whole-file settings path:
/// acceptance is one field settled by one click, and sending the whole
/// object back would let a copy read before the screen opened put an older
/// file over whatever else has been saved since.
#[tauri::command(async)]
#[specta::specta]
pub fn accept_terms() -> Result<TermsState, String> {
    kendex_core::legal::accept(&env()?)
        .map(|(settings, _)| TermsState::from(settings))
        .map_err(|error| error.to_string())
}
