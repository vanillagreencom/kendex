//! A complete tracker inventory, read without changing an issue or a fleet record.

use super::{Answered, Linear, TRACKER_TIMEOUT, invalid, is_word, refused, stamp_epoch};
use crate::error::Result;
use crate::settings::Settings;
use crate::watch::tracker::{Shared, VerifyingItem};
use crate::watch::verifying::{self, Item};
use agent_runtime::host;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

#[derive(Deserialize)]
struct Issue {
    id: String,
    title: String,
    description: String,
    state: String,
    state_type: String,
    updated_at: String,
    created_at: String,
    parent_id: String,
    in_pr_bundle: bool,
    blocked_by_open: Vec<String>,
}

#[derive(Deserialize)]
struct Pull {
    state: String,
    #[serde(rename = "mergedAt")]
    merged_at: Option<String>,
    #[serde(rename = "isCrossRepository")]
    cross_repository: bool,
    #[serde(rename = "mergeCommit")]
    merge_commit: Option<Value>,
    url: Option<String>,
}

struct Pulls {
    open: usize,
    merged: usize,
    unmerged: usize,
    latest: Option<String>,
    keys: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct Finding {
    pub kind: &'static str,
    pub issue: String,
    pub detail: Value,
}

#[derive(Debug, Default, Serialize)]
pub struct Counts {
    pub due: u64,
    pub overdue: u64,
    pub blocked: u64,
    pub waiting: u64,
    pub items: u64,
}

#[derive(Debug, Default, Serialize)]
pub struct Report {
    pub findings: Vec<Finding>,
    pub lines: Vec<String>,
    pub counts: Counts,
}

impl Report {
    fn note(&mut self, kind: &'static str, item: &Issue, detail: Value) {
        self.findings.push(Finding {
            kind,
            issue: item.id.clone(),
            detail,
        });
    }
}

#[allow(
    clippy::disallowed_methods,
    reason = "the reconciliation inventory reads local branch pull requests through the bounded runner without repository redirects"
)]
fn pulls(
    gh: &Path,
    cwd: &Path,
    id: &str,
    read: &mut BTreeMap<String, Value>,
) -> std::result::Result<Pulls, String> {
    let output = host::run_tagged_in(
        "reconcile-items",
        "gh",
        gh,
        "pr-list",
        &[
            "pr",
            "list",
            "--state",
            "all",
            "--head",
            &id.to_ascii_lowercase(),
            "--json",
            "state,mergedAt,isCrossRepository,mergeCommit,url",
        ],
        host::Place {
            cwd: Some(cwd),
            env: &[
                ("GH_REPO", std::ffi::OsStr::new("")),
                ("GITHUB_REPOSITORY", std::ffi::OsStr::new("")),
            ],
        },
        TRACKER_TIMEOUT,
    )
    .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(host::stderr_text(&output));
    }
    let rows: Vec<Pull> = serde_json::from_slice(&output.stdout).map_err(|e| e.to_string())?;
    let mut found = Pulls {
        open: 0,
        merged: 0,
        unmerged: 0,
        latest: None,
        keys: Vec::new(),
    };
    let mut latest = None;
    let mut rows: Vec<Pull> = rows
        .into_iter()
        .filter(|row| !row.cross_repository)
        .collect();
    rows.sort_by_key(|row| row.merged_at.as_deref().and_then(stamp_epoch));
    for row in rows {
        match row.state.as_str() {
            "OPEN" => found.open += 1,
            "MERGED" => {
                let stamp = row.merged_at.as_deref().ok_or("mergedAt missing")?;
                let epoch = stamp_epoch(stamp).ok_or("mergedAt invalid")?;
                found.merged += 1;
                if latest.is_none_or(|at| epoch > at) {
                    latest = Some(epoch);
                    found.latest = Some(stamp.to_owned());
                }
                if let Some((repo, number)) = row
                    .url
                    .as_deref()
                    .and_then(|url| url.strip_prefix("https://github.com/"))
                    .and_then(|tail| tail.split_once("/pull/"))
                    .filter(|(repo, number)| {
                        repo.split('/').count() == 2 && number.parse::<u64>().is_ok()
                    })
                {
                    let repo = repo.to_ascii_lowercase();
                    found.keys.push(format!("{repo}#{number}"));
                    read.insert(format!("repos/{repo}/pulls/{number}"), json!({
                        "merged_at": agent_runtime::clock::iso_utc(epoch),
                        "merge_commit_sha": row.merge_commit.as_ref().and_then(|c| c.get("oid")),
                    }));
                }
            }
            "CLOSED" => found.unmerged += 1,
            _ => return Err("PR state invalid".to_owned()),
        }
    }
    Ok(found)
}

pub fn run(
    settings: &Settings,
    stale_hours: Option<u64>,
    gh: Option<&Path>,
    now: u64,
) -> Result<Report> {
    let configured = &settings.reconcile_stale_hours;
    let stale_hours = match stale_hours {
        Some(hours) => hours,
        None => {
            if configured.is_empty()
                || !configured.bytes().all(|b| b.is_ascii_digit())
                || (configured.len() > 1 && configured.starts_with('0'))
            {
                return Err(refused(
                    "reconcile-threshold-invalid",
                    &[("value", configured)],
                ));
            }
            configured
                .parse::<u64>()
                .map_err(|_| refused("reconcile-threshold-invalid", &[("value", configured)]))?
        }
    };
    let gh = gh.unwrap_or(&settings.reconcile_gh_cli);
    let linear = Linear {
        cli: &settings.reads.tracker_cli,
    };
    let mut args = vec!["issues", "list", "--max"];
    if let Some(team) = &settings.watch.linear_team {
        args.extend(["--team", team]);
    }
    args.push("--format=safe");
    let items: Vec<Issue> = match linear.json("reconcile-items", &args)? {
        Answered::Value(items) => items,
        Answered::Quota(quota) => {
            return Err(refused("reconcile-quota", &[("quota", &quota.line(now))]));
        }
    };
    let mut ids = BTreeSet::new();
    for item in &items {
        if !is_word(&item.id)
            || !ids.insert(&item.id)
            || item.state.is_empty()
            || item.state_type.is_empty()
        {
            return Err(invalid("reconcile-items", "issue", &item.id));
        }
        if item.state_type == "started" && stamp_epoch(&item.updated_at).is_none() {
            return Err(invalid("reconcile-items", "updated_at", &item.updated_at));
        }
    }
    let containers = super::completed_containers(
        items
            .iter()
            .map(|i| (i.id.as_str(), i.state_type.as_str(), i.in_pr_bundle)),
        items
            .iter()
            .map(|i| (i.parent_id.as_str(), i.state_type.as_str())),
    );
    let ctx = verifying::Context {
        settings: settings.clone(),
        gh: gh.to_owned(),
        shared: Shared::default(),
        lines: verifying::Lines::default(),
    };
    let mut report = Report::default();
    let mut read = BTreeMap::new();
    for item in &items {
        let container = containers.contains(&item.id);
        if container {
            report.note(
                "container-parked",
                item,
                json!({"state":item.state, "title":item.title}),
            );
        }
        if item.state_type == "completed" && item.description.contains("- [ ]") {
            report.note("done-unchecked", item, json!({"title":item.title}));
        }
        let verifying = container || item.state == "Verifying";
        let age = stamp_epoch(&item.updated_at).map(|at| (i128::from(now) - i128::from(at)) / 3600);
        let should_probe = verifying
            || (item.state_type == "started"
                && (item.state == "In Review"
                    || age.is_some_and(|h| h >= i128::from(stale_hours))));
        let prs = should_probe.then(|| pulls(gh, &settings.roots.project, &item.id, &mut read));
        if !verifying && should_probe {
            let evidence = match prs.as_ref().expect("a probed item") {
                Ok(prs) => Some(prs),
                Err(cause) => {
                    report.note("pr-probe-failed", item, json!({"cause":cause}));
                    None
                }
            };
            if let Some(prs) = evidence
                && item.state == "In Review"
                && prs.merged > 0
                && prs.open == 0
                && prs.unmerged == 0
            {
                report.note("merged-in-review", item, json!({"merged_at":prs.latest}));
            } else if age.is_some_and(|h| h >= i128::from(stale_hours))
                && evidence.is_none_or(|p| p.open == 0)
            {
                let state =
                    evidence.map_or(
                        "unverified",
                        |p| if p.merged > 0 { "merged" } else { "absent" },
                    );
                report.note("started-stale", item, json!({"age_hours":age, "pr":state}));
            }
        }
        if verifying {
            report.counts.items += 1;
            let keys = prs
                .as_ref()
                .and_then(|p| p.as_ref().ok())
                .map(|p| p.keys.as_slice());
            let verifying_item = VerifyingItem {
                id: item.id.clone(),
                created_at: item.created_at.clone(),
                description: item.description.clone(),
                priority: "-".to_owned(),
                container,
                blocked_by_open: item.blocked_by_open.clone(),
            };
            match verifying::judge_item(&ctx, &verifying_item, keys, now, &mut read)? {
                Item::Invalid => report.note("verifying-invalid", item, json!({})),
                Item::Unread { key, cause } => {
                    if key == "verifying-release-unread" || prs.as_ref().is_some_and(|p| p.is_err())
                    {
                        let cause = prs
                            .as_ref()
                            .and_then(|p| p.as_ref().err())
                            .unwrap_or(&cause);
                        return Err(refused(key, &[("issue", &item.id), ("cause", cause)]));
                    }
                    report.note(key, item, json!({"cause":cause}));
                }
                Item::Read {
                    lines, key, counts, ..
                } => {
                    if key == "boxes=0" {
                        report.note("verifying-empty", item, json!({}));
                    }
                    if counts.overdue > 0 {
                        report.note("verifying-overdue", item, json!({"boxes":counts.overdue}));
                    }
                    report.lines.extend(lines);
                    report.counts.due += counts.due;
                    report.counts.overdue += counts.overdue;
                    report.counts.blocked += counts.blocked;
                    report.counts.waiting += counts.waiting;
                }
            }
        }
    }
    Ok(report)
}
