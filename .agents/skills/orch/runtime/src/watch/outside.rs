//! The outside-contribution pass of the GitHub duty (`lib/outside-
//! contribution.sh`): every open pull request in each repository, and
//! every open issue in the first, whose author is outside the fleet,
//! reported once, and a pull request again on each new head. The fleet is
//! who GitHub says belongs to the repository: a bot account, a login
//! GitHub associates as OWNER, MEMBER or COLLABORATOR, or failing those a
//! login whose collaborator permission is admin, maintain or write, read
//! once per pass per repository and login; every other author is outside,
//! a login the permission read answers 404 among them. A failed list or a
//! line the pass cannot read is a refusal, never an empty one
//! (`:102`, `:107`); a failed permission read is no verdict (`:65`).

use std::collections::BTreeMap;

use serde::Deserialize;

use crate::error::Result;
use crate::settings::{Audit, Settings};
use crate::verify::wire::{Issue, Nullable, Pull, User};
use crate::watch::{Baseline, Change, Event, Produced};

use super::github::refused;
use crate::verify::Gh;

/// Baseline row kind: `<repo>#<number>` to `pr <head>` or `issue`.
pub const ROW: &str = "outside-contribution";

/// `GET /repos/{owner}/{repo}/collaborators/{login}/permission`.
#[derive(Debug, Deserialize)]
struct Permission {
    permission: String,
}

/// One listed item: its number, kind, login and head (`-` for an issue),
/// the line the legacy's jq printed.
struct Listed {
    number: u64,
    kind: &'static str,
    login: String,
    head: String,
}

/// Whether the author's own fields read fleet (`OUTSIDE_AUTHOR_JQ`): a Bot
/// account, or an OWNER, MEMBER or COLLABORATOR association.
fn author_fleet(user: &Nullable<User>, association: Option<&str>) -> bool {
    if let Nullable::Present(user) = user
        && user.kind == "Bot"
    {
        return true;
    }
    association.is_some_and(|a| matches!(a, "OWNER" | "MEMBER" | "COLLABORATOR"))
}

fn login_of(user: &Nullable<User>) -> String {
    match user {
        Nullable::Present(user) => user.login.clone(),
        Nullable::Absent | Nullable::Null => "ghost".to_owned(),
    }
}

/// A listed item's line validation: a word
/// login, a 40-hex head on a pull request, `-` on an issue.
fn valid(item: &Listed) -> bool {
    let login_ok = !item.login.is_empty()
        && item
            .login
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'));
    let head_ok = match item.kind {
        "pr" => {
            item.head.len() == 40
                && item
                    .head
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        }
        _ => item.head == "-",
    };
    login_ok && head_ok
}

/// `outside_author_is_fleet`: GitHub's collaborator permission for `login`
/// on `repo`, once per pass per pair; admin, maintain or write is fleet,
/// a 404 is none and so outside, any other failure is the pass's refusal.
fn fleet_by_permission(
    gh: &Gh,
    repo: &str,
    login: &str,
    verdicts: &mut BTreeMap<(String, String), bool>,
) -> Result<bool> {
    let key = (repo.to_owned(), login.to_owned());
    if let Some(verdict) = verdicts.get(&key) {
        return Ok(*verdict);
    }
    let path = format!("repos/{repo}/collaborators/{login}/permission");
    let permission = match gh.object::<Permission>("collaborator-permission", &path) {
        Ok(Some(read)) => read.permission,
        Ok(None) => "none".to_owned(),
        Err(cause) => {
            return Err(refused(
                "outside-list-failed",
                &[
                    ("repo", repo),
                    ("list", "collaborator-permission"),
                    ("login", login),
                    ("cause", &cause.to_string()),
                ],
            ));
        }
    };
    let fleet = matches!(permission.as_str(), "admin" | "maintain" | "write");
    verdicts.insert(key, fleet);
    if fleet {
        let _ = std::io::Write::write_all(
            &mut std::io::stderr(),
            format!(
                "outside-fleet-by-permission repo={repo} author={login} permission={permission}\n"
            )
            .as_bytes(),
        );
    }
    Ok(fleet)
}

/// The pass (`check_outside_contribution`): every repository's open pull
/// requests, the first repository's open issues, each outside item's row
/// compared with its listed value, a line on a new or moved one, the rows
/// pruned to the items listed.
pub(super) fn pass(
    gh: &Gh,
    settings: &Settings,
    repos: &[String],
    baseline: &Baseline,
    produced: &mut Produced,
) -> Result<()> {
    if settings.reads.external_triage == Audit::Off {
        return Ok(());
    }
    let mut verdicts = BTreeMap::new();
    let mut keys: Vec<String> = Vec::new();
    for (i, repo) in repos.iter().enumerate() {
        let mut listed: Vec<Listed> = Vec::new();
        let pulls_path = format!("repos/{repo}/pulls?state=open");
        let pulls: Vec<Pull> = match gh.list("outside-pulls", &pulls_path) {
            Ok(Some(pulls)) => pulls,
            Ok(None) => return Err(list_failed(repo, "pulls", "HTTP 404")),
            Err(cause) => return Err(list_failed(repo, "pulls", &cause.to_string())),
        };
        for pull in pulls {
            if author_fleet(&pull.user, Some(&pull.author_association)) {
                continue;
            }
            listed.push(Listed {
                number: pull.number,
                kind: "pr",
                login: login_of(&pull.user),
                head: pull.head.sha.clone(),
            });
        }
        // Issues are read in the first repository alone: the fleet's other
        // repositories are watched for the pull requests their lanes open.
        if i == 0 {
            let issues_path = format!("repos/{repo}/issues?state=open");
            let issues: Vec<Issue> = match gh.list("outside-issues", &issues_path) {
                Ok(Some(issues)) => issues,
                Ok(None) => return Err(list_failed(repo, "issues", "HTTP 404")),
                Err(cause) => return Err(list_failed(repo, "issues", &cause.to_string())),
            };
            for issue in issues {
                if issue.pull_request.present().is_some()
                    || author_fleet(&issue.user, Some(&issue.author_association))
                {
                    continue;
                }
                listed.push(Listed {
                    number: issue.number,
                    kind: "issue",
                    login: login_of(&issue.user),
                    head: "-".to_owned(),
                });
            }
        }
        for item in listed {
            if !valid(&item) {
                return Err(refused(
                    "outside-list-invalid",
                    &[
                        ("repo", repo),
                        ("list", if item.kind == "pr" { "pulls" } else { "issues" }),
                        (
                            "line",
                            &format!("{} {} {} {}", item.number, item.kind, item.login, item.head),
                        ),
                    ],
                ));
            }
            if fleet_by_permission(gh, repo, &item.login, &mut verdicts)? {
                continue;
            }
            let key = format!("{repo}#{}", item.number);
            keys.push(key.clone());
            let value = if item.kind == "issue" {
                "issue".to_owned()
            } else {
                format!("pr {}", item.head)
            };
            if baseline.get(ROW, &key) == Some(value.as_str()) {
                continue;
            }
            produced.events.push(Event::OutsideContribution {
                key: key.clone(),
                kind: item.kind.to_owned(),
                author: item.login.clone(),
                head: (item.kind == "pr").then(|| item.head.clone()),
            });
            produced.changes.push(Change::Set {
                kind: ROW.to_owned(),
                identity: key,
                value,
            });
        }
    }
    for identity in baseline.identities(ROW) {
        if !keys.contains(&identity) {
            produced.changes.push(Change::Clear {
                kind: ROW.to_owned(),
                identity,
            });
        }
    }
    Ok(())
}

fn list_failed(repo: &str, list: &str, cause: &str) -> crate::error::Error {
    refused(
        "outside-list-failed",
        &[("repo", repo), ("list", list), ("cause", cause)],
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The fleet reading of an author's own fields and the line validation,
    /// on the legacy suite's shapes (`oversee_watch_outside.sh`): a bot, an
    /// owner, a member and a collaborator are fleet; a contributor, a
    /// first-time contributor, none and a deleted account are not; a
    /// pull request needs a 40-hex head and an issue `-`.
    #[test]
    fn an_author_reads_fleet_by_type_or_association_and_a_line_by_its_shape() {
        let user = |login: &str, kind: &str| {
            Nullable::Present(User {
                login: login.into(),
                kind: kind.into(),
            })
        };
        let assoc = Some;
        assert!(author_fleet(
            &user("lanes[bot]", "Bot"),
            assoc("CONTRIBUTOR")
        ));
        assert!(author_fleet(&user("founder", "User"), assoc("OWNER")));
        assert!(author_fleet(&user("teammate", "User"), assoc("MEMBER")));
        assert!(author_fleet(&user("admin", "User"), assoc("COLLABORATOR")));
        assert!(!author_fleet(
            &user("visitor", "User"),
            assoc("CONTRIBUTOR")
        ));
        assert!(!author_fleet(
            &user("visitor", "User"),
            assoc("FIRST_TIME_CONTRIBUTOR")
        ));
        assert!(!author_fleet(&user("visitor", "User"), assoc("NONE")));
        assert!(!author_fleet(&Nullable::Null, assoc("NONE")));
        assert_eq!(login_of(&Nullable::Null), "ghost");
        let listed = |kind: &'static str, login: &str, head: &str| Listed {
            number: 1,
            kind,
            login: login.into(),
            head: head.into(),
        };
        assert!(valid(&listed("pr", "fixture-visitor", &"a".repeat(40))));
        assert!(valid(&listed("issue", "newcomer", "-")));
        assert!(!valid(&listed("pr", "x", "")));
        assert!(!valid(&listed("pr", "x", &"A".repeat(40))));
        assert!(!valid(&listed("issue", "bad login", "-")));
        assert!(!valid(&listed("issue", "x", &"a".repeat(40))));
    }
}
