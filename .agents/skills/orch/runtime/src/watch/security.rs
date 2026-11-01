//! The security-alert pass of the GitHub duty (`lib/security-alerts.sh`):
//! every open Dependabot, code scanning and secret scanning alert in each
//! repository, reported until the fleet state's `alerts_triaged` records
//! its verdict, repeated with `report=repeat` on every pass while its row
//! stands, each alert read under the installation token the fleet renews
//! in `ORCH_SECURITY_ALERT_TOKEN_FILE` and no other call. A read that
//! cannot be judged keeps every row of its source and joins the pass's one
//! `security-alerts-unread reads=` line, printed only when the set of
//! failed reads changes (`:290`); a refused token, an unreadable verdict
//! record and a list the pass cannot read are each such a source, never
//! an empty list (`:153`, `:171`, `:194`).
//!
//! The lines are protocol the overseer reads under
//! `references/security-alerts.md`; their bytes are `security-alerts.sh:235-
//! 245` and `:298`, rendered by `Event::SecurityAlert` and
//! `Event::SecurityAlertsUnread`.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::error::Result;
use crate::settings::{Audit, Settings};
use crate::verify::wire::Nullable;
use crate::watch::{Baseline, Change, Event, Produced};

use super::github::{Gh, paged};

/// Baseline row kinds (`security-alerts.sh:123-131`).
pub const ALERT_ROW: &str = "security-alert";
pub const BOT_FIX_ROW: &str = "bot-fix";
pub const UNREAD_ROW: &str = "security-alerts-unread";

/// The identity the unread row is held under.
const FLEET: &str = "fleet";

/// The alert API's own path segments (`SECURITY_KINDS`).
const KINDS: [&str; 3] = ["dependabot", "code-scanning", "secret-scanning"];

/// The most bytes a token file may hold (`orch_token_file_read`).
const TOKEN_CAP: usize = 4096;

/// The alert-to-pull-request link (`SECURITY_PR_QUERY`): GitHub's GraphQL
/// alert record is the one read that links an alert to its pull request.
const PR_QUERY: &str = "query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    vulnerabilityAlerts(first: 100, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes { number state dependabotUpdate { pullRequest { number state } } }
    }
  }
}";

// --- the wire shapes ------------------------------------------------------------

/// `GET /repos/{owner}/{repo}/dependabot/alerts`: the columns
/// `security_alert_jq` printed.
#[derive(Debug, Deserialize)]
struct DependabotAlert {
    number: u64,
    html_url: String,
    dependency: Dependency,
    security_advisory: Advisory,
}

#[derive(Debug, Deserialize)]
struct Dependency {
    package: Package,
    /// Documented nullable.
    #[serde(default)]
    manifest_path: Nullable<String>,
    #[serde(default)]
    scope: Nullable<String>,
}

#[derive(Debug, Deserialize)]
struct Package {
    name: String,
}

#[derive(Debug, Deserialize)]
struct Advisory {
    severity: String,
    ghsa_id: String,
}

/// `GET /repos/{owner}/{repo}/code-scanning/alerts`.
#[derive(Debug, Deserialize)]
struct CodeScanningAlert {
    number: u64,
    html_url: String,
    rule: Rule,
}

#[derive(Debug, Deserialize)]
struct Rule {
    id: String,
    severity: String,
    /// The security level where the rule has one, else its own level.
    #[serde(default)]
    security_severity_level: Nullable<String>,
}

/// `GET /repos/{owner}/{repo}/secret-scanning/alerts`.
#[derive(Debug, Deserialize)]
struct SecretScanningAlert {
    number: u64,
    html_url: String,
    secret_type: String,
    #[serde(default)]
    validity: Nullable<String>,
}

/// One GraphQL page of the alert-to-pull-request link.
#[derive(Debug, Deserialize)]
struct PrPage {
    data: PrData,
}

#[derive(Debug, Deserialize)]
struct PrData {
    repository: PrRepository,
}

#[derive(Debug, Deserialize)]
struct PrRepository {
    #[serde(rename = "vulnerabilityAlerts")]
    vulnerability_alerts: PrAlerts,
}

#[derive(Debug, Deserialize)]
struct PrAlerts {
    nodes: Vec<PrNode>,
}

#[derive(Debug, Deserialize)]
struct PrNode {
    number: u64,
    state: String,
    #[serde(default, rename = "dependabotUpdate")]
    dependabot_update: Nullable<DependabotUpdate>,
}

#[derive(Debug, Deserialize)]
struct DependabotUpdate {
    #[serde(default, rename = "pullRequest")]
    pull_request: Nullable<PullRef>,
}

#[derive(Debug, Deserialize)]
struct PullRef {
    number: u64,
    state: String,
}

/// One alert's line columns (`security_alert_jq`), an absent value `None`.
#[derive(Debug, Clone, PartialEq, Eq)]
struct AlertRow {
    number: u64,
    severity: Option<String>,
    subject_key: &'static str,
    subject: String,
    manifest: Option<String>,
    scope: Option<String>,
    advisory: Option<String>,
    validity: Option<String>,
    url: String,
}

fn present(value: &Nullable<String>) -> Option<String> {
    match value {
        Nullable::Present(s) if !s.is_empty() => Some(s.clone()),
        Nullable::Present(_) | Nullable::Absent | Nullable::Null => None,
    }
}

/// The manifest's repository path with each `%` and white space character
/// percent-encoded (`security-alerts.sh:52`), so a directory name with a
/// space stays one word.
fn encoded_manifest(path: &str) -> String {
    let mut out = String::new();
    for c in path.chars() {
        if c == '%' || c.is_whitespace() {
            let mut buf = [0u8; 4];
            for byte in c.encode_utf8(&mut buf).bytes() {
                out.push_str(&format!("%{byte:02X}"));
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// Every column one word (`security_lines_valid`): a subject and a URL, a
/// severity where the kind has one, and no white space in any value.
fn row_valid(kind: &str, row: &AlertRow) -> bool {
    if row.subject.is_empty() || row.url.is_empty() {
        return false;
    }
    if kind != "secret-scanning" && row.severity.as_deref().is_none_or(str::is_empty) {
        return false;
    }
    [
        row.severity.as_deref(),
        Some(row.subject_key),
        Some(row.subject.as_str()),
        row.manifest.as_deref(),
        row.scope.as_deref(),
        row.advisory.as_deref(),
        row.validity.as_deref(),
        Some(row.url.as_str()),
    ]
    .into_iter()
    .flatten()
    .all(|v| !v.chars().any(char::is_whitespace))
}

/// The cause a failed read is reported under (`security_read_cause`): the
/// first row whose words match what gh printed, else GitHub's HTTP status
/// where gh names one, else the exit status.
fn read_cause(stderr: &str, status: &str) -> String {
    let permission = [
        "Resource not accessible by integration",
        "Resource not accessible by personal access token",
    ];
    if permission.iter().any(|p| stderr.contains(p)) {
        return "permission".to_owned();
    }
    let off = [
        "alerts are disabled",
        "scanning is disabled",
        "Security is not enabled",
        "Security must be enabled",
        "no analysis found",
    ];
    if off.iter().any(|p| stderr.contains(p)) {
        return "feature-off".to_owned();
    }
    if let Some(at) = stderr.find("(HTTP ")
        && let Some(close) = stderr[at..].find(')')
    {
        let code = &stderr[at + 6..at + close];
        if code.len() == 3 && code.bytes().all(|b| b.is_ascii_digit()) {
            return format!("http-{code}");
        }
    }
    let exit = status
        .strip_prefix("exit status ")
        .filter(|n| n.bytes().all(|b| b.is_ascii_digit()))
        .unwrap_or("1");
    format!("exit-{exit}")
}

/// How one source's read ended.
enum ReadEnd<T> {
    Read(T),
    /// gh exited nonzero: the cause, and its words for stderr.
    Failed {
        cause: String,
        stderr: String,
    },
    /// A list this pass cannot report from.
    Invalid,
}

/// The current process's effective uid, for the token file's ownership
/// (`-O`); none where the kernel's record cannot be read.
fn effective_uid() -> Option<u32> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    let line = status.lines().find(|l| l.starts_with("Uid:"))?;
    line.split_whitespace().nth(2)?.parse().ok()
}

/// `orch_token_file_read` (`lib/gh-auth.sh:32`): the installation token
/// the fleet renews in `file`, refused with its cause unless the file is a
/// regular file owned by this process with no group or other bits, under a
/// parent owned by this process with no group or other write bit, holding
/// one word under the cap. The refusal names the path judged.
fn read_token(file: Option<&Path>) -> std::result::Result<String, (String, String)> {
    let Some(file) = file.filter(|f| !f.as_os_str().is_empty()) else {
        return Err((String::new(), "unset".to_owned()));
    };
    let shown = file.display().to_string();
    let meta = match std::fs::metadata(file) {
        Ok(meta) if meta.is_file() => meta,
        Ok(_) | Err(_) => return Err((shown, "not-regular".to_owned())),
    };
    let parent = file.parent().filter(|p| !p.as_os_str().is_empty());
    let parent = parent.unwrap_or(Path::new("."));
    let uid = effective_uid();
    let parent_meta = std::fs::metadata(parent)
        .map_err(|_| (parent.display().to_string(), "malformed".to_owned()))?;
    for (path, meta, bits) in [(file, &meta, 0o077), (parent, &parent_meta, 0o022)] {
        let shown = path.display().to_string();
        if uid.is_none_or(|uid| meta.uid() != uid) {
            return Err((shown, "not-owned".to_owned()));
        }
        let mode = meta.mode() & 0o7777;
        if mode & bits != 0 {
            return Err((shown, format!("mode-{mode:o}")));
        }
    }
    let bytes = std::fs::read(file).map_err(|_| (shown.clone(), "malformed".to_owned()))?;
    if bytes.len() >= TOKEN_CAP {
        return Err((shown, "too-long".to_owned()));
    }
    if bytes.contains(&0) {
        return Err((shown, "malformed".to_owned()));
    }
    let text = String::from_utf8(bytes).map_err(|_| (shown.clone(), "malformed".to_owned()))?;
    let token = text.trim_end_matches('\n');
    if token.is_empty() || token.chars().any(char::is_whitespace) {
        return Err((shown, "malformed".to_owned()));
    }
    Ok(token.to_owned())
}

fn note(text: String) {
    let _ = std::io::Write::write_all(&mut std::io::stderr(), text.as_bytes());
}

/// The pass's failed reads, in order (`security_unread`).
#[derive(Default)]
struct Unread(Vec<String>);

impl Unread {
    fn add(&mut self, source: &str, cause: &str, stderr: &str) {
        self.0.push(format!("{source}:{cause}"));
        note(format!(
            "security-alerts-read-failed source={source} cause={cause}\n"
        ));
        if !stderr.is_empty() {
            note(format!("{stderr}\n"));
        }
    }

    /// The `reads=` value: the sources in the order they failed.
    fn reads(&self) -> String {
        self.0.join(",")
    }
}

/// The pass's `security-alerts-unread` line and row
/// (`security_unread_commit`): the line only when the set differs from the
/// row's, the row holding the set; a pass with every read judged clears it.
fn commit_unread(unread: &Unread, baseline: &Baseline, produced: &mut Produced) {
    if unread.0.is_empty() {
        if baseline.get(UNREAD_ROW, FLEET).is_some() {
            produced.changes.push(Change::Clear {
                kind: UNREAD_ROW.to_owned(),
                identity: FLEET.to_owned(),
            });
        }
        return;
    }
    let reads = unread.reads();
    if baseline.get(UNREAD_ROW, FLEET) != Some(reads.as_str()) {
        produced.events.push(Event::SecurityAlertsUnread {
            reads: reads.clone(),
        });
    }
    produced.changes.push(Change::Set {
        kind: UNREAD_ROW.to_owned(),
        identity: FLEET.to_owned(),
        value: reads,
    });
}

/// The `bot-fix` rows as they stand in the baseline: what the heartbeat
/// keeps marking its open list with through an outage.
fn standing_bot_fix(baseline: &Baseline) -> BTreeMap<String, String> {
    baseline
        .identities(BOT_FIX_ROW)
        .into_iter()
        .filter_map(|key| {
            baseline
                .get(BOT_FIX_ROW, &key)
                .map(|v| (key.clone(), v.to_owned()))
        })
        .collect()
}

/// The verdicts `alerts_triaged` records (`security-alerts.sh:160-184`),
/// each `<repo>#<kind>/<number>` lowercased; a row naming no repository,
/// no alert kind or no whole number is the record's `invalid`.
fn recorded(verdicts: &[Value]) -> Option<BTreeSet<String>> {
    let mut out = BTreeSet::new();
    // Each field as the legacy's `"\(.repo)\t\(.kind)\t\(.number)"` rendered
    // it: a string's text, `null` for an absent one, any other value's JSON,
    // so a row missing a field is `invalid`, not skipped.
    let text = |value: Option<&Value>| match value {
        None | Some(Value::Null) => "null".to_owned(),
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
    };
    for row in verdicts {
        let repo = text(row.get("repo"));
        let kind = text(row.get("kind"));
        let number = text(row.get("number"));
        let repo = repo.to_ascii_lowercase();
        let kind = kind.to_ascii_lowercase();
        if repo.is_empty() && kind.is_empty() && number.is_empty() {
            continue;
        }
        let repo_ok = repo.split_once('/').is_some_and(|(o, r)| {
            let word = |s: &str| {
                !s.is_empty()
                    && s.bytes().all(|b| {
                        b.is_ascii_lowercase()
                            || b.is_ascii_digit()
                            || matches!(b, b'.' | b'_' | b'-')
                    })
            };
            word(o) && word(r)
        });
        let number_ok = !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit());
        if !repo_ok || !KINDS.contains(&kind.as_str()) || !number_ok {
            return None;
        }
        out.insert(format!("{repo}#{kind}/{number}"));
    }
    Some(out)
}

/// One alert list under the token, every page (`gh api --paginate`): the
/// typed rows, or how the read ended.
fn alert_list<T: DeserializeOwned>(
    gh: &Gh,
    read: &'static str,
    path: &str,
    token: &str,
) -> Result<ReadEnd<Vec<T>>> {
    let env = [("GH_TOKEN", OsStr::new(token))];
    let mut members: Vec<T> = Vec::new();
    for page in 1..=super::github::MAX_PAGES {
        let raw = gh.raw(read, &["api", &paged(path, page)], &env)?;
        if !raw.success {
            return Ok(ReadEnd::Failed {
                cause: read_cause(&raw.stderr, &raw.status),
                stderr: raw.stderr,
            });
        }
        let Ok(arrived) = serde_json::from_slice::<Vec<T>>(&raw.stdout) else {
            return Ok(ReadEnd::Invalid);
        };
        let short = arrived.len() < super::github::PER_PAGE;
        members.extend(arrived);
        if short {
            return Ok(ReadEnd::Read(members));
        }
    }
    Ok(ReadEnd::Invalid)
}

fn alert_rows(kind: &str, members: Value) -> Option<Vec<AlertRow>> {
    let rows = match kind {
        "dependabot" => serde_json::from_value::<Vec<DependabotAlert>>(members)
            .ok()?
            .into_iter()
            .map(|a| AlertRow {
                number: a.number,
                severity: Some(a.security_advisory.severity),
                subject_key: "package",
                subject: a.dependency.package.name,
                manifest: present(&a.dependency.manifest_path).map(|m| encoded_manifest(&m)),
                scope: present(&a.dependency.scope),
                advisory: Some(a.security_advisory.ghsa_id),
                validity: None,
                url: a.html_url,
            })
            .collect(),
        "code-scanning" => serde_json::from_value::<Vec<CodeScanningAlert>>(members)
            .ok()?
            .into_iter()
            .map(|a| AlertRow {
                number: a.number,
                severity: Some(present(&a.rule.security_severity_level).unwrap_or(a.rule.severity)),
                subject_key: "rule",
                subject: a.rule.id,
                manifest: None,
                scope: None,
                advisory: None,
                validity: None,
                url: a.html_url,
            })
            .collect(),
        _ => serde_json::from_value::<Vec<SecretScanningAlert>>(members)
            .ok()?
            .into_iter()
            .map(|a| AlertRow {
                number: a.number,
                severity: None,
                subject_key: "rule",
                subject: a.secret_type,
                manifest: None,
                scope: None,
                advisory: None,
                validity: present(&a.validity),
                url: a.html_url,
            })
            .collect(),
    };
    Some(rows)
}

/// The Dependabot alerts in any state that carry an open pull request,
/// `(alert, alert state, pr)` each, through the GraphQL record paged by
/// gh (`security-alerts.sh:198`).
fn dependabot_prs(gh: &Gh, repo: &str, token: &str) -> Result<ReadEnd<Vec<(u64, String, u64)>>> {
    let env = [("GH_TOKEN", OsStr::new(token))];
    let (owner, name) = repo.split_once('/').unwrap_or((repo, ""));
    let owner = format!("owner={owner}");
    let name = format!("name={name}");
    let query = format!("query={PR_QUERY}");
    let raw = gh.raw(
        "dependabot-prs",
        &[
            "api",
            "graphql",
            "--paginate",
            "-f",
            &owner,
            "-f",
            &name,
            "-f",
            &query,
        ],
        &env,
    )?;
    if !raw.success {
        return Ok(ReadEnd::Failed {
            cause: read_cause(&raw.stderr, &raw.status),
            stderr: raw.stderr,
        });
    }
    let mut out = Vec::new();
    for page in serde_json::Deserializer::from_slice(&raw.stdout).into_iter::<PrPage>() {
        let Ok(page) = page else {
            return Ok(ReadEnd::Invalid);
        };
        for node in page.data.repository.vulnerability_alerts.nodes {
            let Nullable::Present(update) = node.dependabot_update else {
                continue;
            };
            let Nullable::Present(pull) = update.pull_request else {
                continue;
            };
            if pull.state != "OPEN" {
                continue;
            }
            if node.state.is_empty()
                || !node
                    .state
                    .bytes()
                    .all(|b| b.is_ascii_uppercase() || b == b'_')
            {
                return Ok(ReadEnd::Invalid);
            }
            out.push((node.number, node.state, pull.number));
        }
    }
    Ok(ReadEnd::Read(out))
}

/// The pass (`check_security_alerts`): the token, the verdicts, each
/// repository's three lists and the Dependabot link, the lines and rows,
/// the unread line. The `bot-fix` mapping as it stands after the pass is
/// handed back for the heartbeat.
pub(super) fn pass(
    gh: &Gh,
    settings: &Settings,
    repos: &[String],
    verdicts: &[Value],
    baseline: &Baseline,
    produced: &mut Produced,
) -> Result<BTreeMap<String, String>> {
    if settings.reads.security_alerts == Audit::Off {
        return Ok(BTreeMap::new());
    }
    let mut unread = Unread::default();
    // The fleet renews the installation token in this file: read once per
    // pass so every alert read shares it, but unrelated gh calls never do.
    let token = match read_token(settings.reads.security_alert_token_file.as_deref()) {
        Ok(token) => token,
        Err((file, cause)) => {
            unread.add(
                "installation-token",
                "credential",
                &format!("orch_token_file_read: refused file={file} cause={cause}"),
            );
            commit_unread(&unread, baseline, produced);
            return Ok(standing_bot_fix(baseline));
        }
    };
    // The verdicts first: without them nothing is judged, and every row
    // stands.
    let Some(recorded) = recorded(verdicts) else {
        unread.add("alerts_triaged", "invalid", "");
        commit_unread(&unread, baseline, produced);
        return Ok(standing_bot_fix(baseline));
    };
    let reported: BTreeSet<String> = baseline.identities(ALERT_ROW).into_iter().collect();
    let standing_fix = standing_bot_fix(baseline);
    let mut keys: BTreeSet<String> = BTreeSet::new();
    let mut fix_keys: BTreeSet<String> = BTreeSet::new();
    let mut fix_rows: BTreeMap<String, String> = BTreeMap::new();
    let mut repeats: Vec<Event> = Vec::new();
    let mut events: Vec<Event> = Vec::new();
    let mut new_rows: Vec<String> = Vec::new();
    for repo in repos {
        for kind in KINDS {
            let mut source = format!("{repo}/{kind}");
            let mut query = "state=open".to_owned();
            // A secret's plaintext value is in the list unless GitHub is
            // told to leave it out, and the check never reads it.
            if kind == "secret-scanning" {
                query.push_str("&hide_secret=true");
            }
            let path = format!("repos/{repo}/{kind}/alerts?{query}");
            let mut end = match alert_list::<Value>(gh, "alerts", &path, &token)? {
                ReadEnd::Read(members) => match alert_rows(kind, Value::Array(members)) {
                    Some(rows) if rows.iter().all(|r| row_valid(kind, r)) => ReadEnd::Read(rows),
                    Some(_) | None => ReadEnd::Invalid,
                },
                ReadEnd::Failed { cause, stderr } => ReadEnd::Failed { cause, stderr },
                ReadEnd::Invalid => ReadEnd::Invalid,
            };
            let mut prs: Vec<(u64, String, u64)> = Vec::new();
            if matches!(end, ReadEnd::Read(_)) && kind == "dependabot" {
                source = format!("{repo}/dependabot-prs");
                match dependabot_prs(gh, repo, &token)? {
                    ReadEnd::Read(linked) => prs = linked,
                    ReadEnd::Failed { cause, stderr } => end = ReadEnd::Failed { cause, stderr },
                    ReadEnd::Invalid => end = ReadEnd::Invalid,
                }
            }
            let rows = match end {
                ReadEnd::Read(rows) => rows,
                failed => {
                    match failed {
                        ReadEnd::Invalid => unread.add(&source, "invalid", ""),
                        // Code and secret scanning answer feature-off on
                        // every repository without GitHub's paid security
                        // products: the source is off, not unread, and its
                        // rows stand as for a failed read.
                        ReadEnd::Failed { cause, stderr } => {
                            if !(cause == "feature-off" && kind != "dependabot") {
                                unread.add(&source, &cause, &stderr);
                            }
                        }
                        ReadEnd::Read(_) => unreachable!("a read list is matched above"),
                    }
                    let prefix = format!("{repo}#{kind}/");
                    keys.extend(reported.iter().filter(|k| k.starts_with(&prefix)).cloned());
                    if kind == "dependabot" {
                        let prefix = format!("{repo}#");
                        fix_keys.extend(
                            standing_fix
                                .keys()
                                .filter(|k| k.starts_with(&prefix))
                                .cloned(),
                        );
                    }
                    continue;
                }
            };
            // The open pull requests the alerts link, each to its open
            // alerts, in alert order (`security-alerts.sh:221-229`).
            let mut linked: Vec<(u64, Vec<u64>)> = Vec::new();
            let mut sorted = prs.clone();
            sorted.sort_by_key(|(alert, _, _)| *alert);
            for (alert, state, pr) in &sorted {
                let entry = match linked.iter_mut().find(|(p, _)| p == pr) {
                    Some(entry) => entry,
                    None => {
                        linked.push((*pr, Vec::new()));
                        linked.last_mut().expect("just pushed")
                    }
                };
                if state == "OPEN" {
                    entry.1.push(*alert);
                }
            }
            for (pr, alerts) in linked {
                let key = format!("{repo}#{pr}");
                let value = if alerts.is_empty() {
                    "none".to_owned()
                } else {
                    alerts
                        .iter()
                        .map(u64::to_string)
                        .collect::<Vec<_>>()
                        .join(",")
                };
                fix_keys.insert(key.clone());
                fix_rows.insert(key, value);
            }
            for row in rows {
                let key = format!("{repo}#{kind}/{}", row.number);
                if recorded.contains(&key) {
                    continue;
                }
                keys.insert(key.clone());
                let pr = prs
                    .iter()
                    .find(|(alert, _, _)| *alert == row.number)
                    .map(|(_, _, pr)| *pr);
                let repeat = reported.contains(&key);
                let line = Event::SecurityAlert {
                    repo: repo.clone(),
                    kind: kind.to_owned(),
                    number: row.number,
                    severity: row.severity.clone(),
                    subject_key: row.subject_key.to_owned(),
                    subject: row.subject.clone(),
                    manifest: row.manifest.clone(),
                    scope: row.scope.clone(),
                    advisory: row.advisory.clone(),
                    validity: row.validity.clone(),
                    url: row.url.clone(),
                    pr,
                    repeat,
                };
                if repeat {
                    repeats.push(line);
                } else {
                    events.push(line);
                    new_rows.push(key);
                }
            }
        }
    }
    // The rows: the alert rows pruned to the keys read or kept, the fix rows
    // pruned the same way then set, the new alert rows added.
    for identity in reported.iter() {
        if !keys.contains(identity) {
            produced.changes.push(Change::Clear {
                kind: ALERT_ROW.to_owned(),
                identity: identity.clone(),
            });
        }
    }
    let mut bot_fix: BTreeMap<String, String> = BTreeMap::new();
    for (key, value) in &standing_fix {
        if !fix_keys.contains(key) {
            produced.changes.push(Change::Clear {
                kind: BOT_FIX_ROW.to_owned(),
                identity: key.clone(),
            });
        } else {
            bot_fix.insert(key.clone(), value.clone());
        }
    }
    for (key, value) in fix_rows {
        if standing_fix.get(&key) != Some(&value) {
            produced.changes.push(Change::Set {
                kind: BOT_FIX_ROW.to_owned(),
                identity: key.clone(),
                value: value.clone(),
            });
        }
        bot_fix.insert(key, value);
    }
    for key in new_rows {
        produced.changes.push(Change::Set {
            kind: ALERT_ROW.to_owned(),
            identity: key,
            value: "reported".to_owned(),
        });
    }
    // The repeats ride the pass's output ahead of the first reports
    // (`security-alerts.sh:261-265`).
    produced.events.extend(repeats);
    produced.events.extend(events);
    commit_unread(&unread, baseline, produced);
    Ok(bot_fix)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The cause table (`SECURITY_CAUSES`, `security_read_cause`) on the
    /// words the legacy suite pins (`oversee_watch_security.sh`), the
    /// manifest encoding, and the row validation.
    #[test]
    fn a_failed_reads_cause_is_githubs_own_words_then_its_status() {
        let rows = [
            (
                "gh: Resource not accessible by integration (HTTP 403)",
                "permission",
            ),
            (
                "gh: Resource not accessible by personal access token (HTTP 403)",
                "permission",
            ),
            (
                "gh: Dependabot alerts are disabled for this repository. (HTTP 403)",
                "feature-off",
            ),
            (
                "gh: Secret scanning is disabled on this repository. (HTTP 404)",
                "feature-off",
            ),
            (
                "gh: GitHub Code Security or GitHub Advanced Security is not enabled (HTTP 403)",
                "feature-off",
            ),
            (
                "gh: Advanced Security must be enabled for this repository to use code scanning. (HTTP 403)",
                "feature-off",
            ),
            ("gh: no analysis found (HTTP 404)", "feature-off"),
            (
                "gh: You have exceeded a secondary rate limit. (HTTP 403)",
                "http-403",
            ),
            ("gh: Bad Gateway (HTTP 502)", "http-502"),
            ("something else", "exit-1"),
        ];
        for (text, cause) in rows {
            assert_eq!(read_cause(text, "exit status 1"), cause, "{text}");
        }
        assert_eq!(read_cause("", "exit status 7"), "exit-7");
        assert_eq!(
            encoded_manifest("packages/my app/100%/package.json"),
            "packages/my%20app/100%25/package.json"
        );
        let row = |severity: Option<&str>, subject: &str| AlertRow {
            number: 1,
            severity: severity.map(str::to_owned),
            subject_key: "rule",
            subject: subject.to_owned(),
            manifest: None,
            scope: None,
            advisory: None,
            validity: None,
            url: "https://x/1".to_owned(),
        };
        assert!(row_valid("code-scanning", &row(Some("error"), "r")));
        assert!(!row_valid("code-scanning", &row(None, "r")));
        assert!(row_valid("secret-scanning", &row(None, "r")));
        assert!(!row_valid("code-scanning", &row(Some("error"), "r x")));
    }

    /// The verdict record's reading (`security-alerts.sh:176-184`): the
    /// repository case folded, a row naming no alert kind refused.
    #[test]
    fn the_verdict_record_folds_case_and_refuses_an_unknown_kind() {
        let rows = vec![
            serde_json::json!({"repo": "Owner/Repo", "kind": "dependabot", "number": 7}),
            serde_json::json!({"repo": "owner/repo", "kind": "secret-scanning", "number": 3}),
        ];
        assert_eq!(
            recorded(&rows),
            Some(BTreeSet::from([
                "owner/repo#dependabot/7".to_owned(),
                "owner/repo#secret-scanning/3".to_owned()
            ]))
        );
        let bad = vec![serde_json::json!({"repo": "owner/repo", "kind": "npm", "number": 7})];
        assert_eq!(recorded(&bad), None);
        // A row missing a field reads `null` there, as the legacy's jq
        // rendered it, and is the record's `invalid`; an all-empty row is
        // skipped as the legacy skipped it.
        let missing = vec![serde_json::json!({"repo": "owner/repo", "number": 7})];
        assert_eq!(recorded(&missing), None);
        let empty = vec![serde_json::json!({"repo": "", "kind": "", "number": ""})];
        assert_eq!(recorded(&empty), Some(BTreeSet::new()));
        assert_eq!(recorded(&[]), Some(BTreeSet::new()));
    }
}
