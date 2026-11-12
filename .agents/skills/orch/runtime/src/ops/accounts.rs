//! orch's part of the account reading, which is agent-runtime's
//! (`agent_runtime::accounts`): what only a fleet holds, passed to the one
//! judge as arguments. Under a provider, the provider's rows, its seats
//! (`seat=1`) and its words (`reserved`, `plan-ends`) are read through its
//! `accounts` verb beside this machine's listing; the fleet's lanes charge
//! the accounts they run on, through the occupancy reader's identities,
//! never a claim count, a relaunch naming the lane it replaces, whose
//! charge is left out; a `cloud-session` host admits an account only where
//! `ORCH_LANE_CLOUD_REPOS` gives it this checkout's repository; and a walk
//! over the lane preference reads each entry's host's capability line.

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::path::Path;
use std::time::Duration;

use agent_runtime::accounts::cache;
use agent_runtime::accounts::listing::{Ctx, Emit, Provider, Reading, Usage, alias, emit, finish};
use agent_runtime::accounts::walk::{self, Ground, Hosted, Scope, WalkRequest, Walked};
use agent_runtime::accounts::{
    self, AccountRow, Env, FleetFacts, LOCAL, PickAnswer, PickRequest, Roster, TAG, names, wall,
};
use agent_runtime::clock;
use agent_runtime::harness::Harness;
use agent_runtime::host::{self, Place};
use serde_json::{Map, Value, json};

use super::occupancy::{self, ChargeSource, Host};
use crate::settings::{ProviderSettings, Settings};
use crate::state::{FleetState, Record};
use crate::watch::hosted::{self, Capabilities, Launch};
use crate::watch::overseer::scripts_dir;

const BOUND: Duration = Duration::from_secs(60);
/// A request's own bound; the runner's covers the start.
const REQUEST_BOUND: Duration = Duration::from_secs(15);

/// The reading's view of the loaded settings.
pub fn env(settings: &Settings) -> Env<'_> {
    Env {
        accounts: &settings.accounts,
        account_state: &settings.account_state,
        home: settings.home.as_deref(),
        copilot_home: settings.copilot_home.as_deref(),
        controller_preference: &settings.controller.preference,
    }
}

/// The listing under `host` where one is named (`local` this machine's
/// own reading, whatever provider is configured), else under the
/// configured provider: the roster, or the cause where it could not be
/// read whole, for the caller to say in its place (`account-unread`'s
/// fields).
pub fn roster(
    settings: &Settings,
    host: Option<&str>,
    now: u64,
) -> std::result::Result<Roster, String> {
    roster_naming(settings, host, None, now)
}

fn roster_naming(
    settings: &Settings,
    host: Option<&str>,
    named: Option<(Harness, &str)>,
    now: u64,
) -> std::result::Result<Roster, String> {
    let env = env(settings);
    let provider = settings.provider.get().map_err(|e| e.to_string())?;
    let host = host
        .or(provider.host.as_deref())
        .filter(|h| *h != LOCAL && !h.is_empty());
    let reading = match host {
        Some(host) => Some(
            provider_reading(
                &env,
                &provider,
                &scripts_dir(&settings.roots.project),
                host,
                now,
            )
            .map_err(|cause| format!("host={host} {cause}"))?,
        ),
        None => None,
    };
    accounts::roster_naming(&env, reading, named, now)
}

/// The provider's reading under `host`: the pool its kind declares, then
/// its rows through its `accounts` verb; the cause where its capability
/// line cannot be read.
fn provider_reading(
    env: &Env,
    provider: &ProviderSettings,
    scripts: &Path,
    host: &str,
    now: u64,
) -> std::result::Result<Provider, String> {
    let read = env.accounts.get().map_err(|e| e.to_string())?;
    let pool = host_pool(scripts, host)?;
    let mut ctx = Ctx::new(env, &read, now)?;
    let (rows, failure) = provider_rows(&mut ctx, provider, scripts, host, &pool);
    Ok(Provider {
        host: host.to_owned(),
        pool,
        rows,
        failure,
        notes: ctx.notes,
    })
}
/// The pool the configured host's kind declares (`pool=` on its
/// capability line). A declaration that cannot be read refuses: no pool is
/// guessed for a host.
#[allow(
    clippy::disallowed_methods,
    reason = "the listing's read of the provider's capability line, `lane-host capabilities`, through the one runner under its tag; it acts on nothing"
)]
fn host_pool(scripts: &Path, host: &str) -> Result<String, String> {
    let unread = |cause: String| format!("host-capabilities-unread host={host} cause={cause}");
    let out = host::run_tagged_in(
        TAG,
        "lane-host",
        &scripts.join("lane-host"),
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
fn provider_rows(
    ctx: &mut Ctx,
    provider: &ProviderSettings,
    scripts: &Path,
    host: &str,
    host_pool: &str,
) -> (Vec<Value>, Option<String>) {
    let path = cache::record_path(&ctx.usage_dir, "lane-host", host);
    let cached = |ctx: &mut Ctx| -> Option<(u64, String)> {
        let record = cache::read(&path, "lane-host", host)?;
        let usage = record.usage.as_ref()?;
        let status = usage.get("status")?.as_u64()?;
        let rows = usage.get("rows")?.as_str()?.to_owned();
        let fresh = record.fetched_at <= ctx.now && ctx.now - record.fetched_at < ctx.serve_max_age;
        if !fresh {
            return None;
        }
        let reset = rows
            .lines()
            .filter_map(|line| provider_line(line).ok())
            .find_map(|line| cache::consumed_reset(&line.buckets, ctx.now));
        if let Some(reset) = reset {
            ctx.notes.push(format!(
                "usage-cache-reset account={host} resets-at={reset}"
            ));
            return None;
        }
        Some((status, rows))
    };
    let answer = match cached(ctx) {
        Some(answer) => Ok(answer),
        None => {
            let usage_dir = ctx.usage_dir.clone();
            let (answer, notice) = cache::under_refresh_lock(&usage_dir, || {
                if let Some(answer) = cached(ctx) {
                    return Ok(answer);
                }
                let timeout = provider.accounts_timeout;
                let bound = match timeout {
                    0 => Duration::from_secs(u64::from(u32::MAX)),
                    secs => Duration::from_secs(secs),
                };
                let busy_wait = provider
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
                    &scripts.join("lane-host"),
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
        // The provider's exit 2: it holds no accounts, said beside the
        // rows so an empty listing is never read as an unread one.
        Ok((2, _)) => {
            ctx.notes.push(format!("host-accounts-absent host={host}"));
            (Vec::new(), None)
        }
        Ok((_, rows)) => (host_rows(ctx, &rows, host_pool), None),
        Err(cause) => {
            ctx.notes.push(cause.clone());
            (Vec::new(), Some(cause))
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

/// One provider `accounts` line read: its fields, and its windows in the
/// bucket shape every reading takes.
struct ProviderLine {
    fields: Map<String, Value>,
    account: String,
    harness: Harness,
    buckets: Value,
    credit_fields: bool,
}

struct Unreadable {
    account: String,
    field: &'static str,
}

/// One provider line: `account` and `harness` required, the percentages
/// whole numbers 0 to 100, the four credit fields together on a
/// `harness=pi` row with no `monthly-pct`.
fn provider_line(line: &str) -> Result<ProviderLine, Unreadable> {
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
    let harness = Harness::parse(&get("harness"));
    let mut bad: Option<&'static str> = None;
    let mut pcts: [(&'static str, Option<u64>); 3] = [
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
    if harness.is_none() {
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
        if harness != Some(Harness::Pi)
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
    let (None, Some(harness)) = (bad, harness) else {
        return Err(Unreadable {
            account,
            field: bad.unwrap_or("harness"),
        });
    };
    let nz = |key: &str| {
        let v = get(key);
        if v.is_empty() {
            Value::Null
        } else {
            Value::from(v)
        }
    };
    let [weekly, model, monthly] = pcts.map(|(_, v)| v);
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
        "weekly_pct": weekly,
        "model_pct": model,
        "monthly_pct": monthly,
        "credits": credits.unwrap_or(Value::Null),
        "model_label": nz("model-label"),
        "model_buckets": match model {
            None => json!([]),
            Some(pct) => json!([{"label": nz("model-label"), "pct": pct, "resets_at": nz("model-resets")}]),
        },
        "resets": {"weekly": nz("weekly-resets"), "model": nz("model-resets"),
                   "monthly": nz("monthly-resets")},
    });
    Ok(ProviderLine {
        fields,
        account,
        harness,
        buckets,
        credit_fields,
    })
}

/// The provider's rows as records: a row a field of which cannot be read
/// is left out with a note rather than listed on a guess, since a
/// percentage nobody can parse must not be judged as room. The provider's
/// words `plan-ends`, `reserved` and `seat` are carried as written where
/// non-empty; this listing judges none of them.
fn host_rows(ctx: &mut Ctx, rows: &str, host_pool: &str) -> Vec<Value> {
    let mut out = Vec::new();
    for line in rows.lines().filter(|l| !l.is_empty()) {
        let ProviderLine {
            fields,
            account,
            harness,
            buckets,
            credit_fields,
        } = match provider_line(line) {
            Ok(parsed) => parsed,
            Err(Unreadable { account, field }) => {
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
        };
        let get = |key: &str| {
            fields
                .get(key)
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned()
        };
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
        let pool = match harness {
            Harness::Pi if grant => "api-credit",
            Harness::Pi | Harness::Copilot => "copilot",
            Harness::Claude if host_pool == "cloud-credit" => "cloud-credit",
            Harness::Claude | Harness::Codex => "plan",
        };
        let alias = alias(ctx.accounts, &account);
        let mut row = emit(
            ctx,
            &Emit {
                alias: &alias,
                harness,
                dir: &account,
                through: "host",
                reading: Reading {
                    status,
                    detail: get("detail"),
                    plan: String::new(),
                    usage: Some(Usage::Provider(buckets)),
                    age: None,
                    prior: None,
                    // The provider's protocol states no time a figure was
                    // read, so no fall of it can follow a wall's sighting;
                    // a record of this spelling here is this machine's.
                    fall: None,
                },
                words: Some(words),
            },
        );
        finish(ctx, &mut row, pool);
        out.push(row);
    }
    out
}

struct Hosts<'a> {
    scripts: &'a Path,
    lines: BTreeMap<String, Capabilities>,
}

impl Hosts<'_> {
    fn read(&mut self, host: &str) -> agent_runtime::Result<&Capabilities> {
        if !self.lines.contains_key(host) {
            let line = hosted::capabilities(self.scripts, host).map_err(|cause| {
                agent_runtime::Error::refused(
                    "host-capabilities-unread",
                    &[("host", host), ("cause", &cause)],
                )
            })?;
            self.lines.insert(host.to_owned(), line);
        }
        Ok(&self.lines[host])
    }

    /// Where a walk's entry is judged: a lane's own host, else the fleet's,
    /// whose launch kind may take no lane of the entry (a cloud task; a
    /// cloud session for any harness but Claude, or for a relaunch, which
    /// the cloud cannot resume); an overseer runs here, so only a provider
    /// sharing the Claude plan's pool over ssh reads for it.
    fn hosted(
        &mut self,
        fleet_host: Option<&str>,
        replaces: bool,
        scope: Scope,
        entry_host: Option<&str>,
        harness: Harness,
    ) -> agent_runtime::Result<Hosted> {
        match scope {
            Scope::Lane => {
                let host = entry_host.or(fleet_host).filter(|h| *h != LOCAL);
                let launch = match host {
                    Some(h) => self.read(h)?.launch,
                    None => Capabilities::LOCAL.launch,
                };
                let Some(launch) = launch else {
                    return Err(agent_runtime::Error::refused(
                        "host-capabilities-unread",
                        &[("host", host.unwrap_or(LOCAL)), ("cause", "launch-missing")],
                    ));
                };
                let word = match launch {
                    Launch::Window => "window",
                    Launch::Ssh => "ssh",
                    Launch::CloudSession => "cloud-session",
                    Launch::CloudTask => "cloud-task",
                };
                let skipped = match launch {
                    Launch::Window | Launch::Ssh => false,
                    Launch::CloudSession => harness != Harness::Claude || replaces,
                    Launch::CloudTask => true,
                };
                Ok(if skipped {
                    Hosted::Skip {
                        host: host.unwrap_or(LOCAL).to_owned(),
                        launch: word,
                    }
                } else {
                    Hosted::Judge {
                        host: host.map(str::to_owned),
                        launch: Some(word),
                    }
                })
            }
            Scope::Overseer => {
                let mut host = None;
                if harness == Harness::Claude
                    && let Some(h) = fleet_host.filter(|h| *h != LOCAL)
                    && self.read(h)?.launch == Some(Launch::Ssh)
                {
                    host = Some(h.to_owned());
                }
                Ok(Hosted::Judge { host, launch: None })
            }
        }
    }
}

/// The walk under the fleet's provider: the lane preference where the
/// request names none, each entry's host read through its capability line,
/// and every pick judged with the fleet's seats and live charges, the lane
/// `replaces` names left out.
pub fn walk(
    settings: &Settings,
    fleet_path: &Path,
    kernel: &Host,
    replaces: Option<&str>,
    req: &WalkRequest,
    now: u64,
) -> crate::error::Result<Walked> {
    let provider = settings.provider.get()?;
    let scripts = scripts_dir(&settings.roots.project);
    let mut hosts = Hosts {
        scripts: &scripts,
        lines: BTreeMap::new(),
    };
    let fleet_host = provider.host.as_deref();
    let mut host = |scope: Scope, entry_host: Option<&str>, harness: Harness| {
        hosts.hosted(fleet_host, replaces.is_some(), scope, entry_host, harness)
    };
    let mut pick = |request: &PickRequest, judge_host: Option<&str>| {
        pick_fleet(
            settings, fleet_path, kernel, judge_host, replaces, request, now,
        )
    };
    let req = WalkRequest {
        preference: req.preference.clone().or_else(|| match req.scope {
            Scope::Lane => settings.lane_preference.clone(),
            Scope::Overseer => None,
        }),
        ..req.clone()
    };
    let ground = Ground {
        host: &mut host,
        pick: &mut pick,
    };
    Ok(walk::walk(&env(settings), ground, &req, now)?)
}

/// The fleet's seats and live charges per account from its state file:
/// the overseer's account is a seat; every lane record
/// charges its account while the occupancy reader proves its identity
/// live, protects it unknown, or holds it preparing or reserved, and
/// names the instant it began spending on that account where its record
/// carries one: `session_since`, which every launch and relaunch rewrites
/// and a wake keeps, else `running_at`, else `launched_at`, which a
/// relaunch keeps from the first launch, so a lane relaunched onto the
/// account after a usage sample is counted after it; the lane `replaces`
/// names is left out. The provider's `seat=1` rows join the
/// seats from the listing, read before the readings are resolved, so a
/// seat the provider holds is a seat whichever reading is judged.
#[allow(
    clippy::disallowed_methods,
    reason = "the accounts judge's one read of the fleet state, a snapshot it judges room on; it acts on nothing"
)]
pub fn fleet_facts(
    path: &Path,
    rows: &[AccountRow],
    replaces: Option<&str>,
    host: &Host,
    now: u64,
) -> std::result::Result<FleetFacts, String> {
    let mut facts = FleetFacts::default();
    for row in rows.iter().filter(|r| r.seat) {
        facts.seats.push(row.canon.clone());
    }
    let Some(snapshot) = crate::state::load(path).map_err(|e| e.to_string())? else {
        return Ok(facts);
    };
    let fleet = FleetState::view(path, &snapshot.doc).map_err(|e| e.to_string())?;
    if let Some(account) = fleet
        .overseer
        .as_ref()
        .and_then(|o| o.extra.get("account"))
        .and_then(Value::as_str)
        .filter(|a| !a.is_empty())
    {
        facts.seats.push(wall::canon(account));
    }
    let charges = occupancy::lane_charges(&fleet.lanes, &fleet.intents, now, host);
    for charge in charges {
        let ChargeSource::Lane { item } = charge.source;
        if replaces == Some(item.as_str()) {
            continue;
        }
        let Some(lane) = fleet
            .lanes
            .iter()
            .find(|l| l.item == item)
            .filter(|l| l.account.as_deref().is_some_and(|a| !a.is_empty()))
        else {
            continue;
        };
        let canon = wall::canon(lane.account.as_deref().unwrap_or_default());
        *facts.charges.entry(canon.clone()).or_insert(0) += 1;
        if let Some(start) = lane
            .session_since
            .as_deref()
            .or(lane.running_at.as_deref())
            .or(lane.launched_at.as_deref())
            .and_then(clock::epoch_secs)
        {
            facts.started.entry(canon).or_default().push(start);
        }
    }
    Ok(facts)
}

/// The accounts a `cloud-session` host may launch on (`lane_tier_inputs`,
/// `lib/lane-usage.sh`): where `host`'s capability line declares
/// `launch=cloud-session`, the rows whose `ORCH_LANE_CLOUD_REPOS` entry
/// names the `owner/repo` of this checkout's github.com origin, compared
/// as GitHub reads names, without case; an origin nobody can read admits
/// none. `None` for any other host: the rule does not apply. A capability
/// line that cannot be read is the cause, never a judgement off the local
/// kind.
#[allow(
    clippy::disallowed_methods,
    reason = "the accounts judge's read of this checkout's origin, `git remote get-url origin`, through the one runner under its tag; it acts on nothing"
)]
fn cloud_repo(
    settings: &Settings,
    provider: &ProviderSettings,
    host: &str,
    rows: &[AccountRow],
) -> std::result::Result<Option<Vec<String>>, String> {
    let scripts = crate::watch::overseer::scripts_dir(&settings.roots.project);
    if hosted::capabilities(&scripts, host)?.launch != Some(Launch::CloudSession) {
        return Ok(None);
    }
    let project = settings.roots.project.display().to_string();
    let origin = host::run_tagged_in(
        TAG,
        "git",
        Path::new("git"),
        "origin-url",
        &["-C", &project, "remote", "get-url", "origin"],
        Place {
            cwd: None,
            env: &[],
        },
        BOUND,
    )
    .ok()
    .filter(|out| out.status.success())
    .and_then(|out| super::admission::origin_slug(&host::stdout_text(&out)));
    let Some(origin) = origin else {
        return Ok(Some(Vec::new()));
    };
    let admitted = rows
        .iter()
        .filter(|row| {
            provider.cloud_repos.iter().any(|entry| {
                names(&row.alias, &row.config_dir, &entry.name)
                    && entry.repo.eq_ignore_ascii_case(&origin)
            })
        })
        .map(|row| row.config_dir.clone())
        .collect();
    Ok(Some(admitted))
}

/// The pick a caller receives: a launch whose model's provider nothing
/// bills refused before any read (`accounts::unbilled`); else the listing
/// under `lane_host` (the provider, `local` this machine's own reading,
/// `None` the fleet's configured provider), the fleet's seats and charges
/// read from its state with the lane `replaces` names left out, the host's
/// repository rule where one applies, and the judgement over them. An
/// unread listing, fleet or capability line is unjudged, never a verdict;
/// so is a Pi launch on a grant pool only the provider measures where the
/// provider's read failed, since a failed read is never cached and asking
/// again can answer it, where a missing row is a read to repair.
pub fn pick_fleet(
    settings: &Settings,
    fleet_path: &Path,
    host: &Host,
    lane_host: Option<&str>,
    replaces: Option<&str>,
    req: &PickRequest,
    now: u64,
) -> PickAnswer {
    if let Some(answer) = accounts::unbilled(req) {
        return answer;
    }
    let (accounts, provider) = match (settings.accounts.get(), settings.provider.get()) {
        (Ok(accounts), Ok(provider)) => (accounts, provider),
        (Err(e), _) | (_, Err(e)) => {
            return PickAnswer::Unjudged {
                cause: e.to_string(),
            };
        }
    };
    let asked = lane_host.or(provider.host.as_deref());
    let lane_host = asked.filter(|h| *h != LOCAL && !h.is_empty());
    let model = req.model.as_deref().unwrap_or("");
    let named = req.harness.billed(model).zip(req.lane.as_deref());
    let roster = match roster_naming(settings, asked, named, now) {
        Ok(roster) => roster,
        Err(cause) => {
            return PickAnswer::Unjudged {
                cause: format!("listing-unread {cause}"),
            };
        }
    };
    let pool = req.harness.pool(model);
    if req.harness == Harness::Pi
        && let Some(cause) = &roster.provider_failure
    {
        let stated = roster
            .rows
            .iter()
            .any(|r| r.harness == Harness::Pi && r.measured_through == "stated");
        if pool == "api-credit" || (pool == "copilot" && !stated) {
            let word = if pool == "api-credit" {
                "api-grant-unread"
            } else {
                "copilot-pool-unread"
            };
            return PickAnswer::Unjudged {
                cause: format!("{word} host={} {cause}", lane_host.unwrap_or(LOCAL)),
            };
        }
    }
    let rows = roster.rows;
    let mut facts = match fleet_facts(fleet_path, &rows, replaces, host, now) {
        Ok(facts) => facts,
        Err(cause) => {
            return PickAnswer::Unjudged {
                cause: format!("fleet-unread {cause}"),
            };
        }
    };
    if let Some(lane_host) = lane_host {
        facts.cloud_repo = match cloud_repo(settings, &provider, lane_host, &rows) {
            Ok(admitted) => admitted,
            Err(cause) => return PickAnswer::Unjudged { cause },
        };
    }
    accounts::pick(&rows, req, &facts, &accounts, now)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_providers_row_is_read_field_by_field_and_dropped_on_one_nobody_can_parse() {
        let dir = tempfile::tempdir().unwrap();
        let settings = crate::settings::load(
            &agent_runtime::settings::Roots {
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
        let env = Env {
            account_state: &agent_runtime::settings::Judged::of(
                "state",
                Ok(dir.path().to_path_buf()),
            ),
            ..env(&settings)
        };
        let accounts = settings.accounts.get().unwrap();
        let mut ctx = Ctx::new(&env, &accounts, 1_800_000_000).unwrap();
        ctx.serve_max_age = 300;
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
}
