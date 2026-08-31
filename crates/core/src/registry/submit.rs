//! The submissions client: submit a repository to the community directory
//! and read back the caller's rows. Authentication, refresh rotation, and
//! the dead-grant sign-out rules belong to [`crate::registry::client`].

use serde::Deserialize;

use crate::error::{CoreError, Result};
use crate::registry::client::{server_message, with_access};
use crate::registry::credentials::CredentialStore;
use crate::registry::{Fetch, FetchResponse, base_url};

/// What POST /api/v1/submissions answered.
#[derive(Debug, Clone, Deserialize)]
pub struct Submitted {
    pub repo: String,
    /// `pending`, `listed`, `needs-changes`, `delisted`.
    pub status: String,
}

/// One row of GET /api/v1/submissions — what a Mine row polls.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, serde::Serialize, specta::Type)]
pub struct SubmissionRow {
    pub repo: String,
    pub status: String,
    pub status_reason: Option<String>,
    pub head_commit: Option<String>,
    pub indexed_at: Option<String>,
}

#[derive(Deserialize)]
struct WireSubmissions {
    submissions: Vec<SubmissionRow>,
}

pub fn submit(fetch: &dyn Fetch, store: &dyn CredentialStore, repo: &str) -> Result<Submitted> {
    let body = serde_json::json!({ "repo": repo }).to_string();
    let url = format!("{}/api/v1/submissions", base_url());
    let response = with_access(fetch, store, |access| {
        fetch.post_json_auth(&url, &body, Some(access))
    })?;
    if response.status == 201 {
        return serde_json::from_slice(&response.body).map_err(|error| {
            CoreError::RegistryMalformed {
                why: error.to_string(),
            }
        });
    }
    Err(server_said(&response))
}

pub fn submissions(fetch: &dyn Fetch, store: &dyn CredentialStore) -> Result<Vec<SubmissionRow>> {
    let url = format!("{}/api/v1/submissions", base_url());
    let response = with_access(fetch, store, |access| {
        fetch.get_auth(&url, None, Some(access))
    })?;
    if response.status == 200 {
        let wire: WireSubmissions = serde_json::from_slice(&response.body).map_err(|error| {
            CoreError::RegistryMalformed {
                why: error.to_string(),
            }
        })?;
        return Ok(wire.submissions);
    }
    Err(server_said(&response))
}

fn server_said(response: &FetchResponse) -> CoreError {
    CoreError::Authoring {
        message: server_message(response),
    }
}
