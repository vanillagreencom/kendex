//! A complete tracker inventory, read without changing an issue or a fleet record.

use super::{Answered, Linear, TRACKER_TIMEOUT, invalid, is_word, refused, stamp_epoch};
use crate::error::Result;
use crate::settings::Settings;
use crate::verify::{Answer, Gh};
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

/// The branch's pull requests in the checkout's repository, with no
/// repository redirect from the environment.
fn pulls(gh: &Path, cwd: &Path, id: &str) -> std::result::Result<Pulls, String> {
    let answer = Gh::with_env(
        gh,
        vec![
            ("GH_REPO".to_owned(), "".into()),
            ("GITHUB_REPOSITORY".to_owned(), "".into()),
        ],
    )
    .tagged("reconcile-items")
    .in_dir(cwd)
    .bounded(TRACKER_TIMEOUT)
    .run(
        "pr-list",
        &[
            "pr",
            "list",
            "--state",
            "all",
            "--head",
            &id.to_ascii_lowercase(),
            "--json",
            "state,mergedAt,isCrossRepository,url",
        ],
        None,
    )
    .map_err(|unrun| unrun.detail())?;
    let stdout = match answer {
        Answer::Printed { stdout, .. } => stdout,
        Answer::Failed(failed) => return Err(failed.stderr),
    };
    let rows: Vec<Pull> = serde_json::from_slice(&stdout).map_err(|e| e.to_string())?;
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
                    // The judge reads the pull request's own reply for its
                    // merge and merge commit.
                    found
                        .keys
                        .push(format!("{}#{number}", repo.to_ascii_lowercase()));
                }
            }
            "CLOSED" => found.unmerged += 1,
            _ => return Err("PR state invalid".to_owned()),
        }
    }
    Ok(found)
}

/// The inventory is the checkout's: a project root no repository holds
/// refuses `not-repository` before any read, since the pull request probe
/// answers for the repository it runs in.
#[allow(
    clippy::disallowed_methods,
    reason = "the reconciliation verb asks git once whether its project root is a checkout, through the bounded runner"
)]
pub fn repository(project: &Path) -> Result<()> {
    let path = project.display().to_string();
    let output = host::run_tagged_in(
        "reconcile-items",
        "git",
        Path::new("git"),
        "toplevel",
        &["-C", &path, "rev-parse", "--show-toplevel"],
        host::Place::default(),
        TRACKER_TIMEOUT,
    )?;
    if !output.status.success() {
        return Err(refused("not-repository", &[("path", &path)]));
    }
    Ok(())
}

/// The merged pull requests a reader names, `ITEM=OWNER/REPO#N` each, by
/// item: that item's merge evidence in place of the branch probe's, for a
/// merge the probe cannot find (a pull request on another branch or in
/// another repository).
fn named_merges(merged: &[String]) -> Result<BTreeMap<String, Vec<String>>> {
    let mut named: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for value in merged {
        let parsed = value.split_once('=').and_then(|(item, key)| {
            let (repo, number) = key.split_once('#')?;
            let (owner, name) = repo.split_once('/')?;
            let digits = !number.is_empty()
                && !number.starts_with('0')
                && number.bytes().all(|b| b.is_ascii_digit());
            (is_word(item) && is_word(owner) && is_word(name) && digits)
                .then(|| (item.to_owned(), key.to_owned()))
        });
        let Some((item, key)) = parsed else {
            return Err(refused("merged-invalid", &[("value", value)]));
        };
        named.entry(item).or_default().push(key);
    }
    Ok(named)
}

pub fn run(
    settings: &Settings,
    stale_hours: Option<u64>,
    merged: &[String],
    gh: Option<&Path>,
    now: u64,
) -> Result<Report> {
    let named = named_merges(merged)?;
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
    if let Some(team) = &settings.linear_team {
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
    if let Some(item) = named.keys().find(|id| {
        !items
            .iter()
            .any(|i| &i.id == *id && (containers.contains(&i.id) || i.state == "Verifying"))
    }) {
        return Err(refused("merged-unjudged", &[("item", item)]));
    }
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
        // Whole hours rounded down, so an update stamped ahead of this
        // host's clock is a negative age and never stale.
        let age = stamp_epoch(&item.updated_at)
            .map(|at| (i128::from(now) - i128::from(at)).div_euclid(3600));
        // A started container is still a started item: its lifecycle
        // findings stand beside `container-parked`.
        let started = item.state_type == "started"
            && item.state != "Verifying"
            && (item.state == "In Review" || age.is_some_and(|h| h >= i128::from(stale_hours)));
        let named_keys = named.get(&item.id);
        let prs = (started || (verifying && named_keys.is_none()))
            .then(|| pulls(gh, &settings.roots.project, &item.id));
        if started {
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
            let probe = named_keys.is_none().then_some(prs.as_ref()).flatten();
            let keys = match named_keys {
                Some(keys) => Some(keys.as_slice()),
                None => probe
                    .and_then(|p| p.as_ref().ok())
                    .map(|p| p.keys.as_slice()),
            };
            let verifying_item = VerifyingItem {
                id: item.id.clone(),
                created_at: item.created_at.clone(),
                description: item.description.clone(),
                priority: "-".to_owned(),
                container,
                blocked_by_open: item.blocked_by_open.clone(),
            };
            match verifying::judge_item(&ctx, &verifying_item, keys, now, &mut read)? {
                Item::Invalid { evidence } => {
                    report.note("verifying-invalid", item, json!({"parser": evidence}));
                }
                Item::Unparsed { cause } => {
                    return Err(refused(
                        "verifying-checklist-unread",
                        &[("issue", &item.id), ("cause", &cause)],
                    ));
                }
                Item::Unread { key, cause } => {
                    // A read that failed has its cause; a merge no read
                    // found has none and is a finding.
                    let failed = probe.and_then(|p| p.as_ref().err());
                    if !cause.is_empty() || failed.is_some() {
                        let cause = failed.unwrap_or(&cause);
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
