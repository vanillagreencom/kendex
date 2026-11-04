//! The account listing: every account this machine knows, discovered from
//! its home and the owner's statements, each measured through its own
//! credential at the usage endpoint behind the cache, and under a provider
//! every account the provider holds a credential for, read through its
//! `accounts` verb. A listing lists an account the owner excluded or
//! retired with that word as a flag on its row and judges nothing: the
//! judge refuses by the words. An excluded account is the one directory
//! nothing here looks inside.
//!
//! The network layer is the one impure part: `curl` as `PATH` finds it,
//! the bearer handed over on its stdin and never on its argument vector,
//! which is world-readable on Linux. A request that could not be run reads
//! `unreachable`; one an endpoint refused is recorded in the account's
//! usage record until its window passes, so no caller on the host posts
//! the refused request again, and a usage 429 is answered from the last
//! figure the record holds while that figure is younger than the session
//! window.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::clock;
use agent_runtime::host::{self, Place};
use serde_json::{Map, Value, json};

use super::cache::{self, FigureRead, REFUSAL_WINDOW_S, Refusal};
use super::renewal;
use super::usage::{self, CopilotLogin, Credential, Rounding, SESSION_WINDOW_S};
use super::{AccountRow, TAG, credit_room, grant, wall_verdict};
use crate::ops::wall;
use crate::settings::{AccountSettings, CopilotPool, Settings};

const COPILOT_CREDITS_URL: &str = "https://api.github.com/copilot_internal/user";
pub(super) const CLAUDE_OAUTH_BETA: &str = "oauth-2025-04-20";
/// A request's own bound is curl's `--max-time 10`; the runner's covers
/// the start.
const REQUEST_BOUND: Duration = Duration::from_secs(15);
/// One `secret-tool search` before the Secret Service reads absent.
const KEYRING_BOUND: Duration = Duration::from_secs(5);
const WINDOWS: [(&str, &str); 4] = [
    ("monthly", "monthly_pct"),
    ("weekly", "weekly_pct"),
    ("model", "model_pct"),
    ("session", "session_5h_pct"),
];

/// How the provider's `accounts` read ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProviderRead {
    /// No provider was asked: this machine's own reading alone.
    Local,
    /// The provider answered, rows or none.
    Answered,
    /// The provider implements no `accounts` verb.
    Absent,
    /// The verb failed, or could not be run, with the cause: the listing
    /// is this machine's reading, and a pool only the provider measures is
    /// unjudged.
    Failed(String),
}

/// The listing: one row per account in the record shape the judge reads,
/// how the provider read ended, and the lines a reader prints beside the
/// rows.
#[derive(Debug, Clone, PartialEq)]
pub struct Listing {
    pub rows: Vec<Value>,
    pub provider: ProviderRead,
    pub notes: Vec<String>,
}

struct Ctx<'a> {
    settings: &'a Settings,
    accounts: &'a AccountSettings,
    usage_dir: PathBuf,
    /// The age a cached figure is served within: the TTL, or the caller's
    /// own pass interval where that is longer; 0 declines every cached
    /// figure.
    serve_max_age: u64,
    now: u64,
    today: String,
    notes: Vec<String>,
}

/// The listing under `host` (the provider, or none for this machine
/// alone) at `now`, or the cause where it could not be read whole: a home
/// that cannot be listed, a provider whose capability line cannot be read.
pub fn list(settings: &Settings, host: Option<&str>, now: u64) -> Result<Listing, String> {
    let accounts = &settings.accounts;
    let usage_dir = settings
        .claim_store
        .parent()
        .unwrap_or(&settings.claim_store)
        .join("usage");
    let serve_max_age = if accounts.usage_ttl == 0 {
        0
    } else {
        accounts.usage_ttl.max(accounts.usage_max_age)
    };
    let mut ctx = Ctx {
        settings,
        accounts,
        usage_dir,
        serve_max_age,
        now,
        today: super::today(now),
        notes: Vec::new(),
    };
    let host_pool = match host {
        Some(host) => host_pool(&ctx, host)?,
        None => "plan".to_owned(),
    };
    let mut rows = Vec::new();
    let found = discover(&ctx)?;
    for account in &found {
        let pool = local_pool(account.harness, &host_pool);
        let mut row = measure(&mut ctx, account);
        finish(&ctx, &mut row, &pool);
        rows.push(row);
    }
    let provider = match host {
        Some(host) => {
            let (provider_rows, read) = provider_rows(&mut ctx, host, &host_pool);
            rows.extend(provider_rows);
            read
        }
        None => ProviderRead::Local,
    };
    // A stated entry for a Copilot CLI home, this machine's or a
    // provider's, states that home's fallback reading and names no Pi root.
    let copilot_homes: Vec<String> = rows
        .iter()
        .filter(|r| r["harness"] == json!("copilot"))
        .filter_map(|r| r["config_dir"].as_str().map(wall::canon))
        .collect();
    for entry in &accounts.copilot_pool {
        if copilot_homes.contains(&wall::canon(&entry.dir)) {
            continue;
        }
        let mut row = stated_row(&ctx, &entry.dir, Some(entry));
        finish(&ctx, &mut row, "copilot");
        rows.push(row);
    }
    Ok(Listing {
        rows,
        provider,
        notes: ctx.notes,
    })
}

/// Whether `ORCH_LANE_EXCLUDE` names the account: by its alias, or by its
/// directory name with or without the leading dot. The one rule; the
/// judge refuses by it.
pub fn excluded(settings: &AccountSettings, alias: &str, config_dir: &str) -> bool {
    settings
        .exclude
        .iter()
        .any(|name| super::names(alias, config_dir, name))
}

/// The `ORCH_LANE_RETIRE` date the account is stated to end on, matched
/// as the exclusion is.
pub fn retire_date(settings: &AccountSettings, alias: &str, config_dir: &str) -> Option<String> {
    settings
        .retire
        .iter()
        .find(|r| super::names(alias, config_dir, &r.name))
        .map(|r| r.date.clone())
}

/// The directory's own name without its leading dot, overlaid by the
/// owner's `ORCH_LANE_ALIASES` entry whose key names the directory. A
/// label only: launching names the directory, never the alias.
pub fn alias(settings: &AccountSettings, config_dir: &str) -> String {
    settings
        .aliases
        .iter()
        .find(|a| super::lane_named(config_dir, &a.name))
        .map(|a| a.alias.clone())
        .unwrap_or_else(|| super::base(config_dir).trim_start_matches('.').to_owned())
}

// --- discovery ------------------------------------------------------------------------------

struct Found {
    harness: &'static str,
    dir: String,
}

/// Which directories hold an account of each harness: the `ORCH_LANE_DIRS`
/// entries of its kind replace discovery; with none, `~/.<harness>` and
/// every `~/.*<harness>*` directory holding the harness's marker (a shared
/// session store or a backup matches the glob too), an excluded or retired
/// one listed on its name alone. A set `CODEX_HOME` joins the Codex
/// inventory as the account it names, a set `COPILOT_HOME` the Copilot
/// one. An excluded entry's kind is read off its name: nothing inside it is
/// looked at, the credential probe included.
fn discover(ctx: &Ctx) -> Result<Vec<Found>, String> {
    let accounts = ctx.accounts;
    let mut configured: Vec<(&'static str, String)> = Vec::new();
    for entry in &accounts.lane_dirs {
        let base = super::base(entry);
        let kind = if excluded(accounts, &alias(accounts, entry), entry) {
            if base.contains("codex") {
                "codex"
            } else if base.contains("copilot") {
                "copilot"
            } else {
                "claude"
            }
        } else {
            let holds = |name: &str| usage::exists(&Path::new(entry).join(name));
            let credentials = holds(".credentials.json")?;
            if holds("config.json")? && !credentials {
                "copilot"
            } else if holds("auth.json")? && !credentials {
                "codex"
            } else {
                "claude"
            }
        };
        configured.push((kind, entry.clone()));
    }
    let mut found: Vec<Found> = Vec::new();
    for harness in ["claude", "codex", "copilot"] {
        let mut candidates: Vec<String> = configured
            .iter()
            .filter(|(kind, _)| *kind == harness)
            .map(|(_, dir)| dir.clone())
            .collect();
        if candidates.is_empty() {
            candidates = discovered(ctx, harness)?;
        }
        if harness == "codex"
            && let Some(home) = &accounts.codex_home
        {
            candidates.push(usage::home_account(home));
        }
        if harness == "copilot"
            && let Some(home) = &accounts.copilot_home
        {
            candidates.push(home.clone());
        }
        for dir in candidates {
            if found.iter().any(|f| f.dir == dir) {
                continue;
            }
            found.push(Found { harness, dir });
        }
    }
    Ok(found)
}

/// The glob's answer for one harness, in the order a shell glob lists
/// it: the harness's own directory first, then every match by name.
fn discovered(ctx: &Ctx, harness: &str) -> Result<Vec<String>, String> {
    let Some(home) = &ctx.accounts.home else {
        return Ok(Vec::new());
    };
    let home = Path::new(home);
    let markers: [&str; 2] = match harness {
        "codex" => ["auth.json", "config.toml"],
        "copilot" => ["config.json", "session-state"],
        _ => [".claude.json", ".credentials.json"],
    };
    let mut names: Vec<String> = match std::fs::read_dir(home) {
        Ok(entries) => entries
            .filter_map(|e| e.ok().map(|e| e.file_name().to_string_lossy().into_owned()))
            .filter(|n| n.starts_with('.') && n.contains(harness))
            .collect(),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(e) => {
            return Err(format!("home-unreadable path={} cause={e}", home.display()));
        }
    };
    names.sort();
    let own = format!(".{harness}");
    let mut ordered = vec![own.clone()];
    ordered.extend(names.into_iter().filter(|n| *n != own));
    let mut dirs = Vec::new();
    for name in ordered {
        let dir = home.join(&name);
        if !usage::is_dir(&dir)? {
            continue;
        }
        let text = dir.display().to_string();
        let alias = alias(ctx.accounts, &text);
        let stated = excluded(ctx.accounts, &alias, &text)
            || retire_date(ctx.accounts, &alias, &text).is_some_and(|d| d <= ctx.today);
        if !stated
            && !usage::exists(&dir.join(markers[0]))?
            && !usage::exists(&dir.join(markers[1]))?
        {
            continue;
        }
        dirs.push(text);
    }
    Ok(dirs)
}

/// The pool a local account of `harness` spends on this host.
fn local_pool(harness: &str, host_pool: &str) -> String {
    match harness {
        "claude" if host_pool == "cloud-credit" => "cloud-credit".to_owned(),
        "copilot" => "copilot".to_owned(),
        _ => "plan".to_owned(),
    }
}

/// The pool the configured host's kind declares (`pool=` on its
/// capability line). A declaration that cannot be read refuses: no pool is
/// guessed for a host.
#[allow(
    clippy::disallowed_methods,
    reason = "the listing's read of the provider's capability line, `lane-host capabilities`, through the one runner under its tag; it acts on nothing"
)]
fn host_pool(ctx: &Ctx, host: &str) -> Result<String, String> {
    let unread = |cause: String| format!("host-capabilities-unread host={host} cause={cause}");
    let out = host::run_tagged_in(
        TAG,
        "lane-host",
        &scripts(ctx.settings).join("lane-host"),
        "capabilities",
        &["capabilities"],
        Place {
            cwd: None,
            env: &[("ORCH_LANE_HOST", OsStr::new(host))],
        },
        REQUEST_BOUND,
    )
    .map_err(|e| unread(e.to_string()))?;
    if !out.status.success() {
        return Err(unread(format!(
            "exit={} {}",
            out.status.code().unwrap_or(-1),
            host::stderr_text(&out)
        )));
    }
    let line = host::stdout_text(&out);
    let pool = line
        .split('\t')
        .find_map(|field| field.strip_prefix("pool="))
        .ok_or_else(|| unread("no pool= field".to_owned()))?;
    Ok(pool.to_owned())
}

fn scripts(settings: &Settings) -> PathBuf {
    settings
        .lanes_cli
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_default()
}

// --- one account measured ---------------------------------------------------------------------

/// What a reading's windows come from.
enum Usage {
    /// A usage body the endpoint answered, parsed by its harness.
    Body(Value),
    /// The provider's row, its windows as it stated them.
    Provider(Value),
    /// The owner's stated Copilot pool.
    Stated { used: u64, granted: u64 },
}

/// The reading of one account before the row is built.
struct Reading {
    status: String,
    detail: String,
    plan: String,
    usage: Option<Usage>,
    age: Option<u64>,
    /// The sample the figure displaced and the seconds between them.
    prior: Option<(Value, u64)>,
}

impl Reading {
    fn refused(status: &str, detail: String) -> Reading {
        Reading {
            status: status.to_owned(),
            detail,
            plan: String::new(),
            usage: None,
            age: None,
            prior: None,
        }
    }

    /// The owner's stated pool: the share used rounded up, so a pool one
    /// credit short of its grant never reads as having more, and 100 at or
    /// past the grant.
    fn stated(entry: &CopilotPool, why: &str) -> Reading {
        Reading {
            status: "ok".to_owned(),
            detail: format!(
                "Copilot pool: {} of {} credits used, as ORCH_LANE_COPILOT_POOL states; {why}",
                entry.used, entry.granted
            ),
            plan: String::new(),
            usage: Some(Usage::Stated {
                used: entry.used,
                granted: entry.granted,
            }),
            age: None,
            prior: None,
        }
    }
}

/// One local account's row: its credential read, its usage answered from
/// its record or fetched under the host-wide lock.
fn measure(ctx: &mut Ctx, account: &Found) -> Value {
    let dir = account.dir.as_str();
    let harness = account.harness;
    let alias = alias(ctx.accounts, dir);
    let row = |ctx: &Ctx, reading: Reading| {
        emit(
            ctx,
            &Emit {
                alias: &alias,
                harness,
                dir,
                through: "local",
                reading,
                words: None,
            },
        )
    };
    if excluded(ctx.accounts, &alias, dir) {
        return row(
            ctx,
            Reading::refused(
                "excluded",
                "ORCH_LANE_EXCLUDE names this account; nothing inside it is read".to_owned(),
            ),
        );
    }
    let mut renewed = false;
    let (token, account_id, plan) = match harness {
        "copilot" => match copilot_token(dir) {
            Ok(token) => (token, String::new(), String::new()),
            Err(why) => {
                let canon = wall::canon(dir);
                let stated = ctx
                    .accounts
                    .copilot_pool
                    .iter()
                    .find(|e| wall::canon(&e.dir) == canon);
                let reading = match stated {
                    Some(entry) => Reading::stated(entry, &format!("copilot login unread: {why}")),
                    None => Reading::refused(
                        "no_credentials",
                        format!(
                            "copilot login unread: {why}, and ORCH_LANE_COPILOT_POOL states no reading for this account"
                        ),
                    ),
                };
                let through = if stated.is_some() { "stated" } else { "local" };
                return emit(
                    ctx,
                    &Emit {
                        alias: &alias,
                        harness,
                        dir,
                        through,
                        reading,
                        words: None,
                    },
                );
            }
        },
        _ => match usage::credential(harness, dir) {
            Credential::Missing(path) => {
                return row(
                    ctx,
                    Reading::refused("no_credentials", format!("no credential file at {path}")),
                );
            }
            Credential::Invalid(_) => {
                return row(
                    ctx,
                    Reading::refused("error", "credential file is not valid JSON".to_owned()),
                );
            }
            Credential::NoToken { path, plan } => {
                let mut reading =
                    Reading::refused("no_credentials", format!("no access token in {path}"));
                reading.plan = plan;
                return row(ctx, reading);
            }
            Credential::Token {
                token,
                expires_ms,
                refresh_expires_ms,
                plan,
                account_id,
            } => {
                if harness == "claude" && usage::expired(refresh_expires_ms, ctx.now) {
                    let mut reading = Reading::refused(
                        "expired",
                        "refresh token expired; sign in again".to_owned(),
                    );
                    reading.plan = plan;
                    return row(ctx, reading);
                }
                if usage::expired(expires_ms, ctx.now) {
                    match renewed_token(ctx, harness, dir) {
                        Ok(token) => {
                            renewed = true;
                            (token, account_id, plan)
                        }
                        Err(reading) => {
                            let mut reading = *reading;
                            reading.plan = plan;
                            return row(ctx, reading);
                        }
                    }
                } else {
                    (token, account_id, plan)
                }
            }
        },
    };
    let mut reading = usage_reading(ctx, harness, dir, &token, &account_id, renewed);
    reading.plan = match (harness, &reading.usage) {
        ("copilot", Some(Usage::Body(body))) => body
            .get("copilot_plan")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned(),
        ("copilot", _) => String::new(),
        _ => plan,
    };
    let mut row = row(ctx, reading);
    if renewed {
        row["refreshable"] = json!(true);
    }
    row
}

/// A Copilot account's token from its stored login: `config.json`'s own,
/// or the Secret Service item Copilot CLI keeps a keyring login in, read
/// through `secret-tool search` under the item's `:github` username and
/// then the older one, without unlocking anything. `Err` is the keyed
/// reason and where the login was sought.
#[allow(
    clippy::disallowed_methods,
    reason = "the listing's read of a Copilot keyring login, `secret-tool search`, through the one runner under its tag, bounded; it acts on nothing"
)]
fn copilot_token(dir: &str) -> Result<String, String> {
    let login = match usage::copilot_login(dir) {
        CopilotLogin::Token(token) => return Ok(token),
        CopilotLogin::Unread { reason, place } => return Err(format!("{reason} in {place}")),
        CopilotLogin::Keyring(login) => login,
    };
    let users = [
        format!("https://github.com:{login}:github"),
        format!("https://github.com:{login}"),
    ];
    for user in &users {
        let out = host::run_tagged_in(
            TAG,
            "secret-tool",
            Path::new("secret-tool"),
            "keyring",
            &["search", "service", "copilot-cli", "username", user],
            Place::default(),
            KEYRING_BOUND,
        );
        let out = match out {
            Ok(out) => out,
            Err(e) => {
                let cause = e.to_string();
                let place = if cause.contains("os error 2") {
                    "the Secret Service: no secret-tool on PATH".to_owned()
                } else if cause.contains("no answer within") {
                    format!(
                        "the Secret Service: secret-tool search outlasted {}s for username={user}",
                        KEYRING_BOUND.as_secs()
                    )
                } else {
                    format!(
                        "the Secret Service: secret-tool search failed for username={user}: {cause}"
                    )
                };
                return Err(format!("keyring-absent in {place}"));
            }
        };
        let err_line = host::stderr_text(&out)
            .lines()
            .find(|l| l.starts_with("secret-tool: "))
            .map(str::to_owned);
        if !out.status.success() {
            return Err(format!(
                "keyring-absent in the Secret Service: secret-tool search exited {} for username={user}{}",
                out.status.code().unwrap_or(-1),
                err_line.map(|e| format!(": {e}")).unwrap_or_default()
            ));
        }
        let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
        if let Some(secret) = stdout.lines().find_map(|l| l.strip_prefix("secret = ")) {
            if !secret.is_empty() {
                return Ok(secret.to_owned());
            }
        } else if stdout.lines().any(|l| l.starts_with("label = ")) {
            let place = format!("the Secret Service item service=copilot-cli username={user}");
            return Err(
                if err_line.as_deref() == Some("secret-tool: Cannot get secret of a locked object")
                {
                    format!("keyring-locked in {place}")
                } else {
                    format!(
                        "keyring-refused in {place}: {}",
                        err_line.unwrap_or_else(|| {
                            "secret withheld with no secret-tool error line".to_owned()
                        })
                    )
                },
            );
        }
    }
    Err(format!(
        "keyring-empty in the Secret Service items service=copilot-cli username={} and {}",
        users[0], users[1]
    ))
}

/// The owner's stated Copilot pool for one Pi root as a row, measured
/// through `stated`: neither this machine nor a provider read it. With no
/// entry the root is `no_usage_data`: nothing measured, never room.
fn stated_row(ctx: &Ctx, dir: &str, entry: Option<&CopilotPool>) -> Value {
    let alias = alias(ctx.accounts, dir);
    let reading = match entry {
        Some(entry) => Reading::stated(entry, "no Copilot login is read for a Pi root"),
        None => Reading::refused(
            "no_usage_data",
            "no lane host row and no ORCH_LANE_COPILOT_POOL entry reads a Copilot pool for this account"
                .to_owned(),
        ),
    };
    emit(
        ctx,
        &Emit {
            alias: &alias,
            harness: "pi",
            dir,
            through: "stated",
            reading,
            words: None,
        },
    )
}

/// The live token of an account whose access token expired: the refusal
/// its record holds for the token endpoint, else the renewal under the
/// credentials lock. A refusal the endpoint answered is recorded for its
/// window, so no caller on the host posts the refused grant again; one
/// this machine raised on its own posted nothing, and nothing stops the
/// next listing from posting.
fn renewed_token(ctx: &mut Ctx, harness: &str, dir: &str) -> Result<String, Box<Reading>> {
    let path = cache::record_path(&ctx.usage_dir, harness, dir);
    if !credential_newer(harness, dir, &path)
        && let Some(record) = cache::read(&path, harness, dir)
        && let Some((refusal, age)) = cache::refusal(&record, "token", ctx.now)
    {
        let mut reading = Reading::refused(&refusal.status, refusal.detail.clone());
        reading.age = Some(age);
        return Err(Box::new(reading));
    }
    let refused = match renewal::renew(ctx.accounts, harness, dir, ctx.now) {
        Ok(token) => return Ok(token),
        Err(refused) => refused,
    };
    let detail = format!(
        "access token expired and could not be renewed: {}",
        refused.cause
    );
    if let Some(code) = refused.code {
        let refusal = Refusal {
            endpoint: "token".to_owned(),
            status: refused.status.clone(),
            code: Some(code.to_string()),
            detail: detail.clone(),
            expires_at: ctx.now + refusal_window(refused.retry_after.as_deref()),
        };
        if let Err(cause) = cache::write_refusal(&path, harness, dir, refusal, ctx.now) {
            ctx.notes.push(format!(
                "refusal-unrecorded dir={} cause={cause}",
                ctx.usage_dir.display()
            ));
        }
    }
    Err(Box::new(Reading::refused(&refused.status, detail)))
}

/// A refusal's window: the answer's own Retry-After where it named
/// seconds, else the default. A Retry-After written as an HTTP date names
/// no seconds to wait out, and a window nobody can read is never zero.
fn refusal_window(retry_after: Option<&str>) -> u64 {
    retry_after
        .and_then(|r| r.parse::<u64>().ok())
        .filter(|w| *w > 0)
        .unwrap_or(REFUSAL_WINDOW_S)
}

/// The account's usage: its record's figure where fresh enough, its
/// record's live refusal, else one request under the host-wide lock, the
/// record read again inside it so a caller that waited takes what the
/// holder brought back instead of posting its own. A login this listing
/// renewed itself is the same account, so its record stands.
fn usage_reading(
    ctx: &mut Ctx,
    harness: &str,
    dir: &str,
    token: &str,
    account_id: &str,
    renewed: bool,
) -> Reading {
    let path = cache::record_path(&ctx.usage_dir, harness, dir);
    let newer_credential = !renewed && credential_newer(harness, dir, &path);
    let record = |ctx: &mut Ctx| -> Option<Reading> {
        if newer_credential {
            return None;
        }
        let record = cache::read(&path, harness, dir)?;
        match cache::figure(&record, harness, Some(ctx.serve_max_age), ctx.now) {
            FigureRead::Served(figure) => return Some(served(figure, "ok", String::new())),
            FigureRead::Reset(reset) => ctx
                .notes
                .push(format!("usage-cache-reset account={dir} resets-at={reset}")),
            FigureRead::Miss => {}
        }
        let (refusal, age) = cache::refusal(&record, "usage", ctx.now)?;
        Some(refused_reading(&record, harness, &refusal, age, ctx.now))
    };
    if let Some(reading) = record(ctx) {
        return reading;
    }
    let url = match harness {
        "claude" => ctx.accounts.claude_usage_url.clone(),
        "copilot" => COPILOT_CREDITS_URL.to_owned(),
        _ => ctx.accounts.codex_usage_url.clone(),
    };
    let usage_dir = ctx.usage_dir.clone();
    let (reading, notice) = cache::under_refresh_lock(&usage_dir, || {
        if let Some(reading) = record(ctx) {
            return reading;
        }
        fetch(ctx, harness, dir, &path, &url, token, account_id)
    });
    if let Some(notice) = notice {
        ctx.notes.push(notice);
    }
    reading
}

/// Whether the credential file is newer than the record: a renewed login
/// makes the figure another login's.
fn credential_newer(harness: &str, dir: &str, record: &Path) -> bool {
    let modified = |p: &Path| std::fs::metadata(p).and_then(|m| m.modified()).ok();
    match (
        modified(Path::new(&usage::credential_path(harness, dir))),
        modified(record),
    ) {
        (Some(credential), Some(record)) => credential > record,
        (_, _) => false,
    }
}

fn served(figure: cache::Figure, status: &str, detail: String) -> Reading {
    Reading {
        status: status.to_owned(),
        detail,
        plan: String::new(),
        usage: Some(Usage::Body(figure.usage)),
        age: Some(figure.age),
        prior: figure
            .prior
            .map(|p| (p.usage, figure.fetched_at.saturating_sub(p.fetched_at))),
    }
}

/// A recorded refusal as the account's reading: a 429 answered from the
/// last figure beside it while that figure is younger than the session
/// window and no consumed bucket reset arrived; any other refusal, and a
/// 429 with no such figure, reported as the record states it with no
/// windows and the record's own age.
fn refused_reading(
    record: &cache::Record,
    harness: &str,
    refusal: &Refusal,
    age: u64,
    now: u64,
) -> Reading {
    if refusal.status == "rate_limited"
        && let FigureRead::Served(figure) =
            cache::figure(record, harness, Some(SESSION_WINDOW_S), now)
    {
        return served(
            figure,
            "rate_limited",
            format!("{}; these are the last figures it gave", refusal.detail),
        );
    }
    let mut reading = Reading::refused(&refusal.status, refusal.detail.clone());
    reading.age = Some(age);
    reading
}

/// One request to the usage endpoint: a refusal recorded in the account's
/// record for its window, an answer recorded as the figure with the one it
/// displaced beside it.
#[allow(
    clippy::disallowed_methods,
    reason = "the listing's one request to a usage endpoint, `curl` as PATH finds it, through the one runner under its tag, the bearer on its stdin; it acts on nothing"
)]
fn fetch(
    ctx: &mut Ctx,
    harness: &str,
    dir: &str,
    path: &Path,
    url: &str,
    token: &str,
    account_id: &str,
) -> Reading {
    let mut args: Vec<&str> = vec![
        "-s",
        "--max-time",
        "10",
        "-D",
        "-",
        "-w",
        "\n%{http_code}",
        url,
    ];
    let beta = format!("anthropic-beta: {CLAUDE_OAUTH_BETA}");
    let account = format!("chatgpt-account-id: {account_id}");
    let config = match harness {
        "claude" => {
            args.extend(["-H", &beta]);
            format!("header = \"Authorization: Bearer {token}\"\n")
        }
        "copilot" => {
            args.extend(["-H", "Accept: application/json"]);
            format!("header = \"Authorization: token {token}\"\n")
        }
        _ => {
            if !account_id.is_empty() {
                args.extend(["-H", &account]);
            }
            format!("header = \"Authorization: Bearer {token}\"\n")
        }
    };
    args.extend(["-K", "-"]);
    let out = host::run_tagged_fed(
        TAG,
        "curl",
        Path::new("curl"),
        "usage",
        &args,
        Place::default(),
        config.as_bytes(),
        REQUEST_BOUND,
    );
    let out = match out {
        Ok(out) if out.status.success() => out,
        Ok(_) | Err(_) => {
            return Reading::refused("unreachable", "usage query could not be run".to_owned());
        }
    };
    let answer = usage::answer(&String::from_utf8_lossy(&out.stdout));
    if let Some(code) = answer.code.filter(|c| !(200..300).contains(c)) {
        let mut status = usage::refusal_status(code, "refused");
        let mut detail = format!("usage query refused with HTTP {code}");
        if harness == "claude"
            && matches!(code, 401 | 403)
            && let Some(ended) = plan_ended(url, token)
        {
            status = "plan_ended".to_owned();
            detail = ended;
        }
        let window = refusal_window(answer.retry_after.as_deref());
        let refusal = Refusal {
            endpoint: "usage".to_owned(),
            status: status.clone(),
            code: Some(code.to_string()),
            detail: detail.clone(),
            expires_at: ctx.now + window,
        };
        if let Err(cause) = cache::write_refusal(path, harness, dir, refusal, ctx.now) {
            ctx.notes.push(format!(
                "refusal-unrecorded dir={} cause={cause}",
                ctx.usage_dir.display()
            ));
        }
        if status == "rate_limited"
            && let Some(record) = cache::read(path, harness, dir)
            && let FigureRead::Served(figure) =
                cache::figure(&record, harness, Some(SESSION_WINDOW_S), ctx.now)
        {
            return served(
                figure,
                "rate_limited",
                format!("{detail}; these are the last figures it gave"),
            );
        }
        return Reading::refused(&status, detail);
    }
    if answer.body.is_empty() {
        return Reading::refused(
            "unreachable",
            format!(
                "usage query answered HTTP {} with no body",
                answer.code.unwrap_or(0)
            ),
        );
    }
    let Ok(usage) = serde_json::from_str::<Value>(&answer.body) else {
        return Reading::refused("error", "usage response was not a JSON object".to_owned());
    };
    if !usage.is_object() {
        return Reading::refused("error", "usage response was not a JSON object".to_owned());
    }
    let prior = cache::read(path, harness, dir).and_then(|r| {
        let at = r.usage_fetched_at.unwrap_or(r.fetched_at);
        r.usage.map(|u| (u, ctx.now.saturating_sub(at)))
    });
    cache::write_figure(path, harness, dir, usage.clone(), ctx.now);
    Reading {
        status: "ok".to_owned(),
        detail: String::new(),
        plan: String::new(),
        usage: Some(Usage::Body(usage)),
        age: Some(0),
        prior,
    }
}

/// Whether Claude's profile confirms an ended plan behind a usage 401 or
/// 403: a free organization whose subscription is canceled and no Max
/// account. The stored `subscriptionType` can survive cancellation and
/// auth status does not expose the subscription, so the profile is asked.
/// An unread or contradictory profile proves no cause.
#[allow(
    clippy::disallowed_methods,
    reason = "the listing's one request to the Claude profile endpoint behind a usage refusal, `curl` as PATH finds it, through the one runner under its tag, the bearer on its stdin; it acts on nothing"
)]
fn plan_ended(usage_url: &str, token: &str) -> Option<String> {
    let base = usage_url.rsplit_once('/').map_or("", |(base, _)| base);
    let url = format!("{base}/profile");
    let beta = format!("anthropic-beta: {CLAUDE_OAUTH_BETA}");
    let config = format!("header = \"Authorization: Bearer {token}\"\n");
    let out = host::run_tagged_fed(
        TAG,
        "curl",
        Path::new("curl"),
        "profile",
        &[
            "-s",
            "--max-time",
            "10",
            "-D",
            "-",
            "-w",
            "\n%{http_code}",
            &url,
            "-H",
            &beta,
            "-K",
            "-",
        ],
        Place::default(),
        config.as_bytes(),
        REQUEST_BOUND,
    )
    .ok()
    .filter(|out| out.status.success())?;
    let answer = usage::answer(&String::from_utf8_lossy(&out.stdout));
    if !answer.code.is_some_and(|c| (200..300).contains(&c)) {
        return None;
    }
    let profile: Value = serde_json::from_str(&answer.body).ok()?;
    let org = profile.get("organization")?;
    let kind = org.get("organization_type")?.as_str()?;
    let status = org.get("subscription_status")?.as_str()?;
    let max = profile.pointer("/account/has_claude_max")?;
    (kind == "claude_free" && status == "canceled" && *max == Value::Bool(false))
        .then(|| format!("plan ended: {kind}, subscription {status}"))
}

// --- the provider's rows ----------------------------------------------------------------------

/// The provider's `accounts` answer, one tab-separated `key=value` line per
/// account it holds a credential for, read through `lane-host` under the
/// host and cached under the same window every figure here is; an absent
/// verb (exit 2) is cached as well, a failed one never, since the failure
/// is the transient answer and must not be replayed for the rest of the
/// window. The read is bounded by `ORCH_LANE_HOST_ACCOUNTS_TIMEOUT_S`,
/// the dispatcher's own slot wait held under it.
#[allow(
    clippy::disallowed_methods,
    reason = "the listing's read of the provider's accounts, `lane-host accounts`, through the one runner under its tag, bounded; it acts on nothing"
)]
fn provider_rows(ctx: &mut Ctx, host: &str, host_pool: &str) -> (Vec<Value>, ProviderRead) {
    let path = cache::record_path(&ctx.usage_dir, "lane-host", host);
    let cached = |ctx: &Ctx| -> Option<(u64, String)> {
        let record = cache::read(&path, "lane-host", host)?;
        let usage = record.usage.as_ref()?;
        let status = usage.get("status")?.as_u64()?;
        let rows = usage.get("rows")?.as_str()?.to_owned();
        let fresh = record.fetched_at <= ctx.now && ctx.now - record.fetched_at < ctx.serve_max_age;
        fresh.then_some((status, rows))
    };
    let answer = match cached(ctx) {
        Some(answer) => Ok(answer),
        None => {
            let usage_dir = ctx.usage_dir.clone();
            let (answer, notice) = cache::under_refresh_lock(&usage_dir, || {
                if let Some(answer) = cached(ctx) {
                    return Ok(answer);
                }
                let timeout = ctx.accounts.accounts_timeout;
                let bound = match timeout {
                    0 => Duration::from_secs(u64::from(u32::MAX)),
                    secs => Duration::from_secs(secs),
                };
                let busy_wait = ctx
                    .accounts
                    .host_busy_wait
                    .clone()
                    .unwrap_or_else(|| "30".to_owned());
                let busy_wait = match busy_wait.parse::<u64>() {
                    Ok(wait) if timeout != 0 && wait >= timeout => (timeout - 1).to_string(),
                    Ok(_) | Err(_) => busy_wait,
                };
                let out = host::run_tagged_in(
                    TAG,
                    "lane-host",
                    &scripts(ctx.settings).join("lane-host"),
                    "accounts",
                    &["accounts"],
                    Place {
                        cwd: None,
                        env: &[
                            ("ORCH_LANE_HOST", OsStr::new(host)),
                            (
                                "ORCH_LANE_HOST_SHORT_BUSY_WAIT_SECS",
                                OsStr::new(&busy_wait),
                            ),
                        ],
                    },
                    bound,
                );
                match out {
                    Ok(out) if out.status.success() => {
                        let rows = String::from_utf8_lossy(&out.stdout).into_owned();
                        cache::write_figure(
                            &path,
                            "lane-host",
                            host,
                            json!({"status": 0, "rows": rows}),
                            ctx.now,
                        );
                        Ok((0, rows))
                    }
                    Ok(out) if out.status.code() == Some(2) => {
                        cache::write_figure(
                            &path,
                            "lane-host",
                            host,
                            json!({"status": 2, "rows": ""}),
                            ctx.now,
                        );
                        Ok((2, String::new()))
                    }
                    Ok(out) if out.status.code() == Some(69) => Err(format!(
                        "lane-host-busy step=accounts {}",
                        host::stderr_text(&out)
                    )),
                    Ok(out) => Err(format!(
                        "host-accounts-unreadable host={host} exit={} {}",
                        out.status.code().unwrap_or(-1),
                        host::stderr_text(&out)
                    )),
                    Err(e) => Err(format!("host-accounts-unreadable host={host} cause={e}")),
                }
            });
            if let Some(notice) = notice {
                ctx.notes.push(notice);
            }
            answer
        }
    };
    match answer {
        Ok((2, _)) => (Vec::new(), ProviderRead::Absent),
        Ok((_, rows)) => (host_rows(ctx, &rows, host_pool), ProviderRead::Answered),
        Err(cause) => {
            ctx.notes.push(cause.clone());
            (Vec::new(), ProviderRead::Failed(cause))
        }
    }
}

/// A non-negative decimal with at most two places, the protocol's dollar
/// field.
fn dollars(text: &str) -> Option<f64> {
    let (whole, fraction) = match text.split_once('.') {
        Some((w, f)) => (w, Some(f)),
        None => (text, None),
    };
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    if !digits(whole) || fraction.is_some_and(|f| !digits(f) || f.len() > 2) {
        return None;
    }
    text.parse().ok()
}

/// The provider's rows as records: `account` and `harness` required, the
/// percentages whole numbers 0 to 100, the four credit fields together on
/// a `harness=pi` row with no `monthly-pct`; a row a field of which cannot
/// be read is left out with a note rather than listed on a guess, since a
/// percentage nobody can parse must not be judged as room. The provider's
/// words `plan-ends`, `reserved` and `seat` are carried as written where
/// non-empty; this listing judges none of them.
fn host_rows(ctx: &mut Ctx, rows: &str, host_pool: &str) -> Vec<Value> {
    let mut out = Vec::new();
    for line in rows.lines().filter(|l| !l.is_empty()) {
        let mut fields: Map<String, Value> = Map::new();
        for field in line.split('\t').filter(|f| !f.is_empty()) {
            let (key, value) = field.split_once('=').unwrap_or((field, ""));
            fields.insert(key.to_owned(), Value::from(value));
        }
        let get = |key: &str| {
            fields
                .get(key)
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned()
        };
        let account = get("account");
        let harness = get("harness");
        let mut bad: Option<&str> = None;
        let mut pcts: [(&str, Option<u64>); 4] = [
            ("session-5h-pct", None),
            ("weekly-pct", None),
            ("model-pct", None),
            ("monthly-pct", None),
        ];
        for (key, value) in &mut pcts {
            let text = get(key);
            if text.is_empty() {
                continue;
            }
            match text.parse::<u64>() {
                Ok(n) if text.len() <= 3 && n <= 100 => *value = Some(n),
                Ok(_) | Err(_) => bad = bad.or(Some(key)),
            }
        }
        if account.is_empty() {
            bad = bad.or(Some("account"));
        }
        if !matches!(harness.as_str(), "claude" | "codex" | "copilot" | "pi") {
            bad = bad.or(Some("harness"));
        }
        let credit_fields = [
            "credit-limit",
            "credit-spent",
            "credit-remaining",
            "credit-expires",
        ]
        .iter()
        .any(|k| fields.contains_key(*k));
        let limit = dollars(&get("credit-limit"));
        let remaining = dollars(&get("credit-remaining"));
        if credit_fields {
            if harness != "pi"
                || fields.contains_key("monthly-pct")
                || limit.is_none_or(|l| l <= 0.0)
                || remaining.is_none()
                || clock::epoch_secs(&get("credit-expires")).is_none()
            {
                bad = bad.or(Some("credit-fields"));
            }
            if dollars(&get("credit-spent")).is_none() {
                bad = bad.or(Some("credit-spent"));
            }
        }
        if let Some(field) = bad {
            let named = if account.is_empty() {
                "<unnamed>"
            } else {
                account.as_str()
            };
            ctx.notes.push(format!(
                "host-account-invalid account={named} field={field}"
            ));
            continue;
        }
        let nz = |key: &str| {
            let v = get(key);
            if v.is_empty() {
                Value::Null
            } else {
                Value::from(v)
            }
        };
        let [session, weekly, model, monthly] = pcts.map(|(_, v)| v);
        let credits = credit_fields.then(|| {
            json!({
                "unit": "usd",
                "limit_dollars": limit,
                "used_dollars": dollars(&get("credit-spent")),
                "remaining_dollars": remaining,
                "resets_at": get("credit-expires"),
                "locked_reason": Value::Null,
            })
        });
        let buckets = json!({
            "session_5h_pct": session,
            "weekly_pct": weekly,
            "model_pct": model,
            "monthly_pct": monthly,
            "credits": credits.unwrap_or(Value::Null),
            "model_label": nz("model-label"),
            "model_buckets": match model {
                None => json!([]),
                Some(pct) => json!([{"label": nz("model-label"), "pct": pct, "resets_at": nz("model-resets")}]),
            },
            "resets": {"session": nz("session-resets"), "weekly": nz("weekly-resets"),
                       "model": nz("model-resets"), "monthly": nz("monthly-resets")},
        });
        let status = match get("status") {
            s if s.is_empty() => "ok".to_owned(),
            s => s,
        };
        let mut words = Map::new();
        for (key, name) in [
            ("plan-ends", "plan_ends"),
            ("reserved", "reserved"),
            ("seat", "seat"),
        ] {
            let value = get(key);
            if !value.is_empty() {
                words.insert(name.to_owned(), Value::from(value));
            }
        }
        let grant = credit_fields || get("detail").starts_with("api-credit-");
        let pool = match harness.as_str() {
            "pi" if grant => "api-credit",
            "pi" | "copilot" => "copilot",
            "claude" if host_pool == "cloud-credit" => "cloud-credit",
            _ => "plan",
        };
        let alias = alias(ctx.accounts, &account);
        let mut row = emit(
            ctx,
            &Emit {
                alias: &alias,
                harness: &harness,
                dir: &account,
                through: "host",
                reading: Reading {
                    status,
                    detail: get("detail"),
                    plan: String::new(),
                    usage: Some(Usage::Provider(buckets)),
                    age: None,
                    prior: None,
                },
                words: Some(words),
            },
        );
        finish(ctx, &mut row, pool);
        out.push(row);
    }
    out
}

// --- the row ----------------------------------------------------------------------------------

struct Emit<'a> {
    alias: &'a str,
    harness: &'a str,
    dir: &'a str,
    through: &'a str,
    reading: Reading,
    words: Option<Map<String, Value>>,
}

/// The buckets a reading carries.
fn buckets_of(harness: &str, usage: &Usage) -> Value {
    match usage {
        Usage::Body(body) => usage::parse_body(harness, body, Rounding::Rounded),
        Usage::Provider(buckets) => buckets.clone(),
        Usage::Stated { used, granted } => {
            let pct = if used >= granted {
                100
            } else {
                (used * 100).div_ceil(*granted)
            };
            json!({
                "monthly_pct": pct,
                "credits": {"unit": "AIC", "unlimited": false, "used": used, "granted": granted,
                            "remaining": granted.saturating_sub(*used)},
                "unlimited": false,
                "resets": {"monthly": Value::Null},
            })
        }
    }
}

/// One account's record: the reading's windows, the binding window and
/// its rate against the displaced sample, the weekly wall a harness banner
/// stated held at 100 until its reset, and the owner's words as flags.
fn emit(ctx: &Ctx, e: &Emit) -> Value {
    let Reading {
        status,
        detail,
        plan,
        usage,
        age,
        prior,
    } = &e.reading;
    let mut status = status.clone();
    let mut detail = detail.clone();
    let mut buckets = usage
        .as_ref()
        .map(|u| buckets_of(e.harness, u))
        .unwrap_or_else(|| json!({}));
    usage::utc_resets(&mut buckets);
    if wall_overlay(ctx, e.dir, &mut buckets).is_err() {
        buckets = json!({});
        status = "error".to_owned();
        detail = "wall record unreadable".to_owned();
    }
    let num = |key: &str| buckets.get(key).and_then(Value::as_f64);
    let known: Vec<f64> = WINDOWS.iter().filter_map(|(_, pct)| num(pct)).collect();
    let credit_unit = buckets.pointer("/credits/unit").and_then(Value::as_str);
    if status == "ok" && known.is_empty() && credit_unit != Some("usd") {
        status = "no_usage_data".to_owned();
    }
    let measured = status == "ok" || status == "rate_limited";
    let largest = known.iter().cloned().fold(f64::MIN, f64::max);
    // A tie binds the longer window: the first of monthly, weekly, model,
    // session at the largest figure.
    let bind = WINDOWS
        .iter()
        .find(|(_, pct)| num(pct) == Some(largest))
        .map(|(bucket, _)| *bucket);
    let headroom = (measured && !known.is_empty()).then_some(100.0 - largest);
    let resets = buckets.get("resets").cloned().unwrap_or_else(|| json!({}));
    let reset_of = |key: &str| resets.get(key).cloned().unwrap_or(Value::Null);
    let binding_bucket = if measured { bind } else { None };
    let retire_date = retire_date(ctx.accounts, e.alias, e.dir);
    let retired = retire_date
        .as_deref()
        .is_some_and(|d| d <= ctx.today.as_str());
    let credits = buckets.get("credits").filter(|c| !c.is_null()).map(|c| {
        let mut c = c.clone();
        c["measured_at"] = json!(clock::iso_utc(ctx.now.saturating_sub(age.unwrap_or(0))));
        c
    });
    if status == "no_usage_data" && detail.is_empty() {
        detail = "authenticated, but the usage response carried no session/weekly/monthly window"
            .to_owned();
    }
    let mut row = json!({
        "alias": e.alias,
        "harness": e.harness,
        "config_dir": e.dir,
        "retire_date": retire_date,
        "measured_through": e.through,
        "status": status,
        "refreshable": false,
        "plan": if plan.is_empty() { Value::Null } else { Value::from(plan.as_str()) },
        "session_5h_pct": num("session_5h_pct"),
        "weekly_pct": num("weekly_pct"),
        "model_pct": num("model_pct"),
        "model_label": buckets.get("model_label").cloned().unwrap_or(Value::Null),
        "model_buckets": buckets.get("model_buckets").cloned().unwrap_or_else(|| json!([])),
        "monthly_pct": num("monthly_pct"),
        "credits": credits,
        "unlimited": buckets.get("unlimited") == Some(&Value::Bool(true)),
        "headroom_pct": headroom,
        "binding_bucket": binding_bucket,
        "binding_resets_at": binding_bucket.map_or(Value::Null, reset_of),
        "usage_age_s": age,
        "resets": {"session": reset_of("session"), "weekly": reset_of("weekly"),
                   "model": reset_of("model"), "monthly": reset_of("monthly")},
        "detail": if detail.is_empty() { Value::Null } else { Value::from(detail.as_str()) },
        "excluded": excluded(ctx.accounts, e.alias, e.dir),
        "retired": retired,
    });
    if e.harness == "copilot" {
        row["credits_used"] = buckets.get("credits_used").cloned().unwrap_or(Value::Null);
    }
    if let Some(words) = &e.words {
        for (key, value) in words {
            row[key] = value.clone();
        }
    }
    binding_and_rate(&mut row, e.harness, prior.as_ref());
    integral(&mut row);
    row
}

/// Every integral figure spelled as an integer, the form the record's
/// shell readers parse (`^[0-9]{1,3}$`) and the roster line prints.
fn integral(value: &mut Value) {
    match value {
        Value::Number(n) => {
            if let Some(f) = n.as_f64()
                && n.as_i64().is_none()
                && f.fract() == 0.0
                && f.abs() < 9.0e15
            {
                *value = Value::from(f as i64);
            }
        }
        Value::Array(items) => items.iter_mut().for_each(integral),
        Value::Object(map) => map.values_mut().for_each(integral),
        Value::Null | Value::Bool(_) | Value::String(_) => {}
    }
}

/// The weekly wall a harness banner stated for the account, held at 100
/// and resetting at the recorded reset while that reset is ahead: with no
/// record, a record naming another account or a reset already passed the
/// reading stands. A record nobody can read is the error: a wall nobody
/// can read is no evidence the account has room.
fn wall_overlay(ctx: &Ctx, dir: &str, buckets: &mut Value) -> Result<(), String> {
    let path = wall::account_wall_path(&ctx.settings.claim_store, dir);
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e.to_string()),
    };
    let record: wall::AccountWall = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    if record.config_dir != wall::canon(dir) || record.resets_at <= ctx.now {
        return Ok(());
    }
    if !buckets.is_object() {
        *buckets = json!({});
    }
    buckets["weekly_pct"] = json!(100);
    if !buckets.get("resets").is_some_and(Value::is_object) {
        buckets["resets"] = json!({});
    }
    buckets["resets"]["weekly"] = json!(clock::iso_utc(record.resets_at));
    Ok(())
}

/// The binding window (`wall`) and the rate the displaced sample exposes:
/// measured where both samples are at least a minute apart, the figure
/// rose, and the prior's window is the one judged now (same bucket, its
/// label in the normalized spelling, its reset within five minutes).
fn binding_and_rate(row: &mut Value, harness: &str, prior: Option<&(Value, u64)>) {
    let ended = row["status"] == json!("plan_ended");
    let measured = matches!(row["status"].as_str(), Some("ok" | "rate_limited"));
    let headroom = row["headroom_pct"].as_f64();
    let bucket = row["binding_bucket"].as_str().map(str::to_owned);
    let binding: Option<(String, Option<String>, f64, Value)> = match (ended, headroom, bucket) {
        (true, _, _) => Some(("plan".to_owned(), None, 100.0, Value::Null)),
        (false, Some(headroom), Some(bucket)) if measured => {
            let label = (bucket == "model")
                .then(|| {
                    row["model_buckets"]
                        .as_array()?
                        .iter()
                        .max_by(|a, b| {
                            a["pct"]
                                .as_f64()
                                .unwrap_or(0.0)
                                .total_cmp(&b["pct"].as_f64().unwrap_or(0.0))
                        })
                        .and_then(|b| b["label"].as_str().map(str::to_owned))
                })
                .flatten();
            Some((
                bucket,
                label,
                100.0 - headroom,
                row["binding_resets_at"].clone(),
            ))
        }
        (false, _, _) => None,
    };
    let Some((bucket, label, pct, resets_at)) = binding else {
        row["wall"] = Value::Null;
        row["usage_rate_state"] = json!("one-sample");
        row["usage_rate_pct_per_min"] = Value::Null;
        row["projected_wall_minutes"] = Value::Null;
        return;
    };
    row["wall"] = json!(pct);
    row["binding_bucket"] = json!(bucket);
    row["binding_resets_at"] = resets_at.clone();
    let mut prior_pct: Option<f64> = None;
    let mut elapsed = 0u64;
    if let Some((prior_usage, secs)) = prior {
        elapsed = *secs;
        let mut prior_buckets = usage::parse_body(harness, prior_usage, Rounding::Rounded);
        usage::utc_resets(&mut prior_buckets);
        let candidates: Vec<(Option<String>, Option<f64>, Value)> = if bucket == "model" {
            prior_buckets["model_buckets"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|b| {
                    (
                        b["label"].as_str().map(str::to_owned),
                        b["pct"].as_f64(),
                        b["resets_at"].clone(),
                    )
                })
                .collect()
        } else {
            let key = WINDOWS
                .iter()
                .find(|(b, _)| *b == bucket)
                .map_or("", |(_, pct)| pct);
            vec![(
                None,
                prior_buckets[key].as_f64(),
                prior_buckets["resets"][bucket.as_str()].clone(),
            )]
        };
        let norm = |l: &Option<String>| l.as_deref().map(super::norm);
        prior_pct = candidates
            .iter()
            .find(|(l, _, reset)| norm(l) == norm(&label) && same_reset(reset, &resets_at))
            .and_then(|(_, p, _)| *p);
    }
    let delta = prior_pct.map(|p| pct - p);
    let state = match delta {
        None => "one-sample",
        Some(_) if elapsed < 60 => "samples-too-close",
        Some(d) if d <= 0.0 => "not-increasing",
        Some(_) => "measured",
    };
    row["usage_rate_state"] = json!(state);
    match delta.filter(|_| state == "measured") {
        Some(d) => {
            row["usage_rate_pct_per_min"] = json!(d * 60.0 / elapsed as f64);
            row["projected_wall_minutes"] =
                json!(((100.0 - pct) * elapsed as f64 / (d * 60.0)).ceil());
        }
        None => {
            row["usage_rate_pct_per_min"] = Value::Null;
            row["projected_wall_minutes"] = Value::Null;
        }
    }
}

/// Whether two reset stamps name one window: both present, and parsed to
/// epochs no more than five minutes apart (a stamp read either side of a
/// second boundary is still the same reset), else equal as text.
fn same_reset(a: &Value, b: &Value) -> bool {
    let (Some(a), Some(b)) = (a.as_str(), b.as_str()) else {
        return false;
    };
    match (clock::epoch_secs(a), clock::epoch_secs(b)) {
        (Some(x), Some(y)) => x.abs_diff(y) <= 300,
        (_, _) => a == b,
    }
}

/// The row's verdict and pool: its binding window judged against
/// `ORCH_LANE_MAX_PCT`, a Codex balance above the floor lifting a window
/// wall, an ended plan a full wall, and a grant pool judged on the grant
/// by the expires-first rule, so the listing and the judge cannot disagree
/// about a grant at the floor.
fn finish(ctx: &Ctx, row: &mut Value, pool: &str) {
    row["pool"] = json!(pool);
    row["verdict"] = json!("unmeasured");
    let Some(parsed) = AccountRow::parse(row, ctx.accounts) else {
        return;
    };
    let max = f64::from(ctx.accounts.max_pct);
    let wall = row["wall"].as_f64();
    if parsed.plan_ended() {
        row["verdict"] = json!("walled");
        return;
    }
    if pool == "cloud-credit" || pool == "api-credit" {
        let Some(grant) = grant(&parsed, ctx.accounts.cloud_credit_floor as f64, ctx.now) else {
            return;
        };
        if let Some(share) = grant.share {
            row["headroom_pct"] = json!(share);
            integral(&mut row["headroom_pct"]);
            row["binding_bucket"] = json!("credits");
            row["binding_resets_at"] = Value::Null;
        }
        row["verdict"] = json!(grant.verdict);
        if grant.verdict != "room" {
            row["refusal"] = json!({"cause": pool, "retry_at": Value::Null});
        }
        return;
    }
    let verdict = wall_verdict(wall, max);
    if verdict == "walled" && credit_room(&parsed, ctx.accounts.codex_credit_floor as f64) {
        row["verdict"] = json!("room");
        row["binding_bucket"] = json!("credits");
        row["usage_rate_state"] = json!("credits");
        row["usage_rate_pct_per_min"] = Value::Null;
        row["projected_wall_minutes"] = Value::Null;
        return;
    }
    row["verdict"] = json!(verdict);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn world() -> (tempfile::TempDir, Settings) {
        let dir = tempfile::tempdir().unwrap();
        let settings = crate::settings::load(
            &crate::settings::Roots {
                project: dir.path().to_path_buf(),
                common: dir.path().to_path_buf(),
            },
            &[],
            &crate::settings::Flags {
                state_dir: Some(dir.path().to_path_buf()),
                private_env: false,
            },
        )
        .unwrap();
        (dir, settings)
    }

    /// Defect: a row dropped on a field the provider did not state, or
    /// listed on a field nobody can read; a status one row names leaking
    /// into the next; the words carried as a default.
    #[test]
    fn a_providers_row_is_read_field_by_field_and_dropped_on_one_nobody_can_parse() {
        let (dir, settings) = world();
        let mut ctx = Ctx {
            settings: &settings,
            accounts: &settings.accounts,
            usage_dir: dir.path().join("usage"),
            serve_max_age: 300,
            now: 1_800_000_000,
            today: "2027-01-15".to_owned(),
            notes: Vec::new(),
        };
        let rows = host_rows(
            &mut ctx,
            "account=/h/.a\tharness=claude\tstatus=refused\tdetail=http-403-permission_error\n\
             account=/h/.b\tharness=claude\tsession-5h-pct=4\tweekly-pct=9\tplan-ends=2027-01-31\treserved=1\tseat=1\n\
             account=/h/.c\tharness=claude\tweekly-pct=abc\n\
             harness=claude\tweekly-pct=8\n\
             account=/h/.d\tharness=claude\n\
             account=/h/.p\tharness=pi\tcredit-limit=200.00\tcredit-spent=50.00\tcredit-remaining=150\tcredit-expires=2027-02-01T00:00:00Z\n",
            "plan",
        );
        assert_eq!(rows.len(), 4, "{rows:?}");
        assert_eq!(rows[0]["status"], json!("refused"));
        assert_eq!(rows[0]["detail"], json!("http-403-permission_error"));
        assert_eq!(rows[0].get("plan_ends"), None);
        assert_eq!(rows[1]["status"], json!("ok"));
        assert_eq!(rows[1]["detail"], Value::Null);
        assert_eq!(rows[1]["headroom_pct"], json!(91));
        assert_eq!(rows[1]["plan_ends"], json!("2027-01-31"));
        assert_eq!(rows[1]["seat"], json!("1"));
        assert_eq!(rows[1]["verdict"], json!("room"));
        assert_eq!(rows[2]["status"], json!("no_usage_data"));
        assert_eq!(rows[3]["pool"], json!("api-credit"));
        assert_eq!(rows[3]["verdict"], json!("room"));
        assert_eq!(rows[3]["headroom_pct"], json!(75));
        assert_eq!(
            ctx.notes,
            vec![
                "host-account-invalid account=/h/.c field=weekly-pct",
                "host-account-invalid account=<unnamed> field=account"
            ]
        );
    }

    /// Defect: a tie between windows binding the shorter one, or a
    /// displaced sample of another window rated as this window's.
    #[test]
    fn a_tie_binds_the_longer_window_and_the_rate_reads_the_same_window_alone() {
        let (_dir, settings) = world();
        let ctx = Ctx {
            settings: &settings,
            accounts: &settings.accounts,
            usage_dir: PathBuf::new(),
            serve_max_age: 300,
            now: 1_800_000_000,
            today: "2027-01-15".to_owned(),
            notes: Vec::new(),
        };
        let body = |session: u64, weekly: u64| {
            json!({"five_hour": {"utilization": session, "resets_at": "2027-01-15T05:00:00Z"},
                   "seven_day": {"utilization": weekly, "resets_at": "2027-01-20T00:00:00Z"}})
        };
        let emit_with = |prior: Option<(Value, u64)>| {
            emit(
                &ctx,
                &Emit {
                    alias: "a",
                    harness: "claude",
                    dir: "/h/.a",
                    through: "local",
                    reading: Reading {
                        status: "ok".to_owned(),
                        detail: String::new(),
                        plan: "max".to_owned(),
                        usage: Some(Usage::Body(body(40, 40))),
                        age: Some(0),
                        prior,
                    },
                    words: None,
                },
            )
        };
        let row = emit_with(None);
        assert_eq!(row["binding_bucket"], json!("weekly"));
        assert_eq!(row["wall"], json!(40));
        assert_eq!(row["usage_rate_state"], json!("one-sample"));
        let row = emit_with(Some((body(10, 20), 600)));
        assert_eq!(row["usage_rate_state"], json!("measured"));
        assert_eq!(row["usage_rate_pct_per_min"], json!(2));
        assert_eq!(row["projected_wall_minutes"], json!(30));
        let row = emit_with(Some((body(10, 40), 600)));
        assert_eq!(row["usage_rate_state"], json!("not-increasing"));
        let row = emit_with(Some((body(10, 20), 30)));
        assert_eq!(row["usage_rate_state"], json!("samples-too-close"));
    }
}
