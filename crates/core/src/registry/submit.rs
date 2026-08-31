//! The submissions client: submit a repository to the community directory
//! and read back the caller's rows. Authentication, refresh rotation, and
//! the dead-grant sign-out rules belong to [`crate::registry::client`].

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

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

/// What is known about one marketplace's submission.
///
/// `not-submitted` is a positive answer: nothing of this marketplace is
/// listed, and the read saying so landed. `unknown` is the absence of an
/// answer: the last read failed, and what is in hand does not name this
/// repository. `submitted` carries the row the server listed it under.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, specta::Type)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum SubmissionState {
    NotSubmitted,
    Unknown,
    Submitted { row: SubmissionRow },
}

/// How the last read of the caller's submissions went.
///
/// `landed` means the rows in hand are the whole of what the server
/// lists, so a repository missing from them is not submitted. `failed`
/// means they are only what it last said, and `unread` that no read has
/// been made. Under neither is absence an answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, specta::Type)]
#[serde(rename_all = "kebab-case")]
pub enum SubmissionsRead {
    Landed,
    Failed,
    Unread,
}

/// One marketplace to answer about: where it is, and the GitHub
/// repository a submission of it would be keyed by. `repo` is absent for
/// a marketplace with no GitHub remote.
#[derive(Debug, Clone, Deserialize, specta::Type)]
pub struct SubmissionAsk {
    pub path: String,
    pub repo: Option<String>,
}

/// What each marketplace asked about reads as, keyed by its path.
///
/// A submission is keyed by the GitHub repository, so a marketplace with
/// no remote has nothing the server could have listed and is not
/// submitted whatever the read did. One the rows name is submitted under
/// the row the server gave, and stays so under a read that did not land:
/// it is what the server last said. Absence answers only where one did.
pub fn states(
    read: SubmissionsRead,
    rows: &[SubmissionRow],
    asks: &[SubmissionAsk],
) -> BTreeMap<String, SubmissionState> {
    asks.iter()
        .map(|ask| (ask.path.clone(), state_for(read, rows, ask.repo.as_deref())))
        .collect()
}

fn state_for(read: SubmissionsRead, rows: &[SubmissionRow], repo: Option<&str>) -> SubmissionState {
    let Some(repo) = repo else {
        return SubmissionState::NotSubmitted;
    };
    match rows.iter().find(|row| row.repo == repo) {
        Some(row) => SubmissionState::Submitted { row: row.clone() },
        None => match read {
            SubmissionsRead::Landed => SubmissionState::NotSubmitted,
            SubmissionsRead::Failed | SubmissionsRead::Unread => SubmissionState::Unknown,
        },
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn row(repo: &str) -> SubmissionRow {
        SubmissionRow {
            repo: repo.to_owned(),
            status: "pending".to_owned(),
            status_reason: None,
            head_commit: None,
            indexed_at: None,
        }
    }

    fn ask(path: &str, repo: Option<&str>) -> SubmissionAsk {
        SubmissionAsk {
            path: path.to_owned(),
            repo: repo.map(str::to_owned),
        }
    }

    const READS: [SubmissionsRead; 3] = [
        SubmissionsRead::Landed,
        SubmissionsRead::Failed,
        SubmissionsRead::Unread,
    ];

    fn asked(read: SubmissionsRead, rows: &[SubmissionRow], ask: SubmissionAsk) -> SubmissionState {
        let path = ask.path.clone();
        states(read, rows, &[ask])
            .remove(&path)
            .expect("a state for every marketplace asked about")
    }

    /// A submission is keyed by the GitHub repository. A marketplace
    /// without one has nothing the server could have listed, so no read
    /// makes it less certain — the offer stays a first submit.
    #[test]
    fn a_marketplace_with_no_remote_is_not_submitted_however_the_read_went() {
        for read in READS {
            assert_eq!(
                asked(read, &[row("ada/team-skills")], ask("/mine", None)),
                SubmissionState::NotSubmitted
            );
        }
    }

    /// A row already read is what the server last said about that
    /// repository, and a later read that failed does not unsay it.
    #[test]
    fn a_row_in_hand_answers_for_itself_under_a_failed_read() {
        let rows = [row("ada/team-skills")];
        for read in READS {
            assert_eq!(
                asked(read, &rows, ask("/mine", Some("ada/team-skills"))),
                SubmissionState::Submitted {
                    row: row("ada/team-skills")
                }
            );
        }
    }

    /// Absence means not submitted only where a read landed to say so,
    /// or it offers a first submit over work already in review.
    #[test]
    fn absence_is_an_answer_only_where_a_read_landed() {
        let asking = || ask("/mine", Some("ada/team-skills"));
        assert_eq!(
            asked(SubmissionsRead::Landed, &[], asking()),
            SubmissionState::NotSubmitted
        );
        for read in [SubmissionsRead::Failed, SubmissionsRead::Unread] {
            assert_eq!(asked(read, &[], asking()), SubmissionState::Unknown);
        }
    }

    /// Every marketplace asked about gets an answer, under the path it
    /// was asked about: the caller looks each row up by its own path.
    #[test]
    fn every_marketplace_asked_about_is_answered_under_its_own_path() {
        let answered = states(
            SubmissionsRead::Failed,
            &[row("ada/team-skills")],
            &[
                ask("/mine/team", Some("ada/team-skills")),
                ask("/mine/scratch", None),
                ask("/mine/other", Some("ada/other")),
            ],
        );
        assert_eq!(
            answered.keys().collect::<Vec<_>>(),
            ["/mine/other", "/mine/scratch", "/mine/team"]
        );
        assert_eq!(answered["/mine/other"], SubmissionState::Unknown);
        assert_eq!(answered["/mine/scratch"], SubmissionState::NotSubmitted);
        assert!(matches!(
            answered["/mine/team"],
            SubmissionState::Submitted { .. }
        ));
    }
}
