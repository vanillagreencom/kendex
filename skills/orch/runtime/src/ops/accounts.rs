//! The accounts judge (step6-map § A10; decisions 75, 97, 99, 105, 141 (5),
//! 182 Q12, Q13, 183 Q10, Q11; round 8 items 5-7): one view of each
//! account the legacy reader lists, [`AccountRow`], read per call and
//! stored nowhere, and the two reads over it, [`roster`] for the heartbeat
//! and [`pick`] for every launch that asks which account to spend.
//!
//! The measurement stays `lanes`' (decision 130): its usage endpoints,
//! token renewals and caches answer `lanes list --json`, read through the
//! one runner. What this module owns is the judgement over those rows: the
//! status words, the window a lane on a model is judged on, the projection
//! of the lanes already on an account, and the choice.
//!
//! The status words (round 8 item 7), one per account: `pick`; `reserve`,
//! never picked and still measured, the provider's `reserved=1`; `retired
//! <date>`, picked until that UTC day and measured after it, from the
//! machine's own `ORCH_LANE_RETIRE` (decision 183 Q11) or the provider's
//! `plan-ends`. The legacy reader is run with `ORCH_LANE_RETIRE` emptied,
//! so a retired account's credential is still read: a stated end that a
//! live reading contradicts (a credential that answers after its end) is a
//! reported line (round 8 item 6), never a silent absence. `ORCH_LANE_
//! EXCLUDE` stays the reader's own rule: an excluded directory is never
//! read, so no row of it reaches this judge.
//!
//! A listing that could not be read whole admits nothing (decision 99): no
//! pick, and a roster line saying `unread`. A provider's `plan-ends` that
//! names no calendar day is an end nobody can read: the row keeps its
//! figures, is never picked, and is one `account-plan-end-invalid` line
//! under the roster. The projection charges each account the lanes of
//! this fleet the runtime proves live on it, through the occupancy
//! reader's identities (decision 97: no legacy claim count); a relaunch
//! names the lane it replaces, whose charge is left out, so a replacement
//! adds no lane (step6-map § A5).
//!
//! A pick the legacy reader still judges (a provider's fleet, an API
//! grant) is handed the words first: the roster is read with the host, a
//! named account the word refuses is answered here, and every other such
//! account is handed to `lanes pick` as an exclusion, since that reader
//! judges none of the provider's words (decision 188 (b)).

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::path::Path;
use std::time::Duration;

use agent_runtime::clock;
use agent_runtime::host::{self, Place};
use serde::Serialize;
use serde_json::{Map, Value, json};

use super::occupancy::{self, ChargeSource, Host};
use super::wall;
use crate::settings::{AccountSettings, Settings};
use crate::state::{FleetState, Record};

/// The bound on one `lanes` call, the legacy `READ_CEILING`
/// (`oversee-watch:275`).
const BOUND: Duration = Duration::from_secs(60);

/// The start-counter tag every read of this judge is counted under.
pub const TAG: &str = "accounts";

/// The host word of a read with no provider named.
pub const LOCAL: &str = "local";

/// Where a stated end came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum EndSource {
    /// The machine's own `ORCH_LANE_RETIRE`.
    Setting,
    /// The provider's account row.
    Provider,
}

impl EndSource {
    /// Who stated the end, as the roster's and the refusal's `source=` name
    /// it.
    pub fn stated_by(self) -> &'static str {
        match self {
            EndSource::Setting => "ORCH_LANE_RETIRE",
            EndSource::Provider => "provider",
        }
    }
}

/// The status word of one account.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Word {
    Pick,
    /// Never picked, still measured.
    Reserve,
    /// Picked until `date`, measured after it.
    Retired {
        date: String,
        source: EndSource,
    },
    /// The provider's stated end is not a calendar day: never picked (the
    /// safe side of an end nobody can read), still measured.
    PlanEndInvalid {
        value: String,
    },
}

impl Word {
    /// The word as the roster prints it.
    pub fn text(&self) -> String {
        match self {
            Word::Pick => "pick".to_owned(),
            Word::Reserve => "reserve".to_owned(),
            Word::Retired { date, .. } => format!("retired:{date}"),
            Word::PlanEndInvalid { .. } => "plan-end-invalid".to_owned(),
        }
    }
}

/// What the word says of a pick today, read before any window: open to
/// the windows' judgement, or refused by the word alone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Standing {
    Open,
    Reserved,
    /// The stated end has come.
    Retired {
        date: String,
        source: EndSource,
    },
    /// The provider's stated end reads as no calendar day.
    EndUnread {
        value: String,
    },
}

/// The provider's stated end as the row carries it, three-valued: none
/// stated, a calendar day, or a value that names no calendar day.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlanEnd {
    None,
    Day(String),
    Invalid(String),
}

/// One model-scoped window of an account.
#[derive(Debug, Clone, PartialEq)]
pub struct ModelBucket {
    pub label: Option<String>,
    pub pct: f64,
    pub resets_at: Option<String>,
}

/// One account as the judge sees it: the listing's row, the provider's
/// words where the row carries them (`plan_ends`, `reserved`, `seat`),
/// and the machine's own statement matched onto it.
#[derive(Debug, Clone, PartialEq)]
pub struct AccountRow {
    pub alias: String,
    pub harness: String,
    pub config_dir: String,
    /// One spelling per account (`lib/lane-claims.sh`, `lane_claims_canon`).
    pub canon: String,
    pub measured_through: String,
    pub status: String,
    pub detail: Option<String>,
    pub verdict: String,
    pub headroom_pct: Option<f64>,
    pub binding_bucket: Option<String>,
    pub binding_resets_at: Option<String>,
    pub session_5h_pct: Option<f64>,
    pub weekly_pct: Option<f64>,
    pub monthly_pct: Option<f64>,
    pub model_buckets: Vec<ModelBucket>,
    pub session_resets_at: Option<String>,
    /// The rate the reader measured on its binding bucket, in points a
    /// minute, where its `usage_rate_state` is `measured`.
    pub usage_rate_pct_per_min: Option<f64>,
    pub usage_age_s: Option<f64>,
    pub credits: Option<Value>,
    pub plan_ends: PlanEnd,
    pub reserved: bool,
    pub seat: bool,
    /// The machine's own stated end for this account.
    pub retire: Option<String>,
    /// The row as the reader printed it, for the lines and records that
    /// carry it whole.
    pub raw: Value,
}

/// A field's text as jq's string interpolation printed it: a string as
/// is, any other value as its JSON, an absent one as `null`.
pub fn text(record: &Value, key: &str) -> String {
    match record.get(key) {
        None | Some(Value::Null) => "null".to_owned(),
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
    }
}

/// A field with jq's `// "-"` default.
pub fn text_or_dash(record: &Value, key: &str) -> String {
    match record.get(key) {
        None | Some(Value::Null) => "-".to_owned(),
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
    }
}

fn number(record: &Value, key: &str) -> Option<f64> {
    record.get(key).and_then(Value::as_f64)
}

fn string(record: &Value, key: &str) -> Option<String> {
    record.get(key).and_then(Value::as_str).map(str::to_owned)
}

/// The provider's one-word flags as its row carries them (`reserved=1`,
/// `seat=1`): the number 1, the string `1` or `true`.
fn flag(record: &Value, key: &str) -> bool {
    match record.get(key) {
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_u64() == Some(1),
        Some(Value::String(s)) => s == "1" || s == "true",
        None | Some(Value::Null | Value::Array(_) | Value::Object(_)) => false,
    }
}

/// `lane_named` and the alias match (`lanes`' `lane_matches`): a stated
/// name is the account's alias, its directory name, or that name without
/// its leading dot.
fn names(alias: &str, config_dir: &str, name: &str) -> bool {
    let base = Path::new(config_dir)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    name == alias || name == base || Some(name) == base.strip_prefix('.')
}

impl AccountRow {
    /// One listing row as the judge reads it, under `settings`' statement.
    /// `None` for a row with no `status` or `verdict`: a listing that
    /// failed to render, never a measured account.
    pub fn parse(raw: &Value, settings: &AccountSettings) -> Option<AccountRow> {
        if raw.get("status").is_none_or(Value::is_null)
            || raw.get("verdict").is_none_or(Value::is_null)
        {
            return None;
        }
        let alias = text(raw, "alias");
        let config_dir = text(raw, "config_dir");
        let model_buckets = raw
            .get("model_buckets")
            .and_then(Value::as_array)
            .map(|buckets| {
                buckets
                    .iter()
                    .filter_map(|b| {
                        Some(ModelBucket {
                            label: string(b, "label"),
                            pct: number(b, "pct")?,
                            resets_at: string(b, "resets_at"),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        let retire = settings
            .retire
            .iter()
            .find(|r| names(&alias, &config_dir, &r.name))
            .map(|r| r.date.clone());
        let resets = raw.get("resets");
        Some(AccountRow {
            canon: wall::canon(&config_dir),
            harness: text(raw, "harness"),
            measured_through: text(raw, "measured_through"),
            status: text(raw, "status"),
            detail: string(raw, "detail"),
            verdict: text(raw, "verdict"),
            headroom_pct: number(raw, "headroom_pct"),
            binding_bucket: string(raw, "binding_bucket"),
            binding_resets_at: string(raw, "binding_resets_at"),
            session_5h_pct: number(raw, "session_5h_pct"),
            weekly_pct: number(raw, "weekly_pct"),
            monthly_pct: number(raw, "monthly_pct"),
            model_buckets,
            session_resets_at: resets.and_then(|r| string(r, "session")),
            usage_rate_pct_per_min: (string(raw, "usage_rate_state").as_deref()
                == Some("measured"))
            .then(|| number(raw, "usage_rate_pct_per_min"))
            .flatten(),
            usage_age_s: number(raw, "usage_age_s"),
            credits: raw.get("credits").filter(|c| c.is_object()).cloned(),
            plan_ends: match string(raw, "plan_ends").or_else(|| string(raw, "plan-ends")) {
                None => PlanEnd::None,
                Some(day) if crate::settings::calendar_date_valid(&day) => PlanEnd::Day(day),
                Some(value) => PlanEnd::Invalid(value),
            },
            reserved: flag(raw, "reserved"),
            seat: flag(raw, "seat"),
            retire,
            alias,
            config_dir,
            raw: raw.clone(),
        })
    }

    /// The account's status word: the provider's reservation first, then
    /// a provider's end nobody can read, then the earlier of the machine's
    /// and the provider's stated ends.
    pub fn word(&self) -> Word {
        if self.reserved {
            return Word::Reserve;
        }
        let provider = match &self.plan_ends {
            PlanEnd::None => None,
            PlanEnd::Day(day) => Some(day),
            PlanEnd::Invalid(value) => {
                return Word::PlanEndInvalid {
                    value: value.clone(),
                };
            }
        };
        match (&self.retire, provider) {
            (Some(setting), Some(provider)) if provider < setting => Word::Retired {
                date: provider.clone(),
                source: EndSource::Provider,
            },
            (Some(setting), _) => Word::Retired {
                date: setting.clone(),
                source: EndSource::Setting,
            },
            (None, Some(provider)) => Word::Retired {
                date: provider.clone(),
                source: EndSource::Provider,
            },
            (None, None) => Word::Pick,
        }
    }

    /// Whether the stated end has come: `today` is the UTC day.
    pub fn ended(&self, today: &str) -> bool {
        matches!(self.word(), Word::Retired { date, .. } if date.as_str() <= today)
    }

    /// The word's own verdict on a pick today (round 8 item 7): the one
    /// rule the judge, a named pick's answer and the delegated pick's
    /// exclusions read.
    pub fn standing(&self, today: &str) -> Standing {
        match self.word() {
            Word::Pick => Standing::Open,
            Word::Reserve => Standing::Reserved,
            Word::PlanEndInvalid { value } => Standing::EndUnread { value },
            Word::Retired { date, source } if date.as_str() <= today => {
                Standing::Retired { date, source }
            }
            Word::Retired { .. } => Standing::Open,
        }
    }

    /// Whether the row carries a usage reading (`lane_measured` with a
    /// figure).
    pub fn measured(&self) -> bool {
        (self.status == "ok" || self.status == "rate_limited") && self.headroom_pct.is_some()
    }

    /// `plan_ended`: a plan that admits no launch, a wall no reset lifts.
    pub fn plan_ended(&self) -> bool {
        self.status == "plan_ended"
    }

    /// Whether the credential answered: a stated end a measured reading
    /// contradicts.
    pub fn answers(&self) -> bool {
        self.status == "ok" || self.status == "rate_limited"
    }

    /// The field text both the roster line and the `account` event print
    /// (`account_roster_read`'s third column, `oversee-watch:5157`).
    pub fn fields(&self) -> String {
        format!(
            "{} config_dir={} harness={} through={} status={} verdict={} headroom_pct={} binding_bucket={} binding_resets_at={}",
            self.alias,
            self.config_dir,
            self.harness,
            self.measured_through,
            self.status,
            self.verdict,
            text_or_dash(&self.raw, "headroom_pct"),
            text_or_dash(&self.raw, "binding_bucket"),
            text_or_dash(&self.raw, "binding_resets_at")
        )
    }

    /// The row's identity, the legacy's first column (`oversee-watch:5155`):
    /// two accounts sharing an alias are told apart by `config_dir`.
    pub fn key(&self) -> String {
        format!(
            "{}|{}|{}",
            self.harness, self.measured_through, self.config_dir
        )
    }
}

/// The UTC day of `now_secs`, the form a stated end is compared with.
pub fn today(now_secs: u64) -> String {
    clock::iso_utc(now_secs)[..10].to_owned()
}

/// One `lanes list --json` listing under the judge's statement.
#[derive(Debug, Clone, PartialEq)]
pub struct Roster {
    pub rows: Vec<AccountRow>,
}

impl Roster {
    /// The listing read as one JSON array of records each carrying `status`
    /// and `verdict` (`account_roster_read`'s jq), or none: an answer of
    /// another shape is a listing that failed to render, never a fleet with
    /// no accounts.
    pub fn parse(stdout: &str, settings: &AccountSettings) -> Option<Roster> {
        let rows: Vec<Value> = serde_json::from_str(stdout).ok()?;
        let rows = rows
            .iter()
            .map(|raw| AccountRow::parse(raw, settings))
            .collect::<Option<Vec<AccountRow>>>()?;
        Some(Roster { rows })
    }

    /// The `account <fields>` line of each record (`oversee-watch:5155-
    /// 5157`), with the status word after the legacy's fields where it is
    /// not `pick`, and under the roster one `account-end-contradicted`
    /// line per account whose stated end has come while its credential
    /// still answers (round 8 item 6) and one `account-plan-end-invalid`
    /// line per account whose provider end names no calendar day: the
    /// lines the legacy never had.
    pub fn lines(&self, today: &str) -> Vec<String> {
        let mut lines: Vec<String> = self
            .rows
            .iter()
            .map(|r| match r.word() {
                Word::Pick => format!("account {}", r.fields()),
                word => format!("account {} word={}", r.fields(), word.text()),
            })
            .collect();
        for row in &self.rows {
            match row.word() {
                Word::Retired { date, source } if row.ended(today) && row.answers() => {
                    lines.push(format!(
                        "account-end-contradicted {} config_dir={} ends={date} source={} status={}",
                        row.alias,
                        row.config_dir,
                        source.stated_by(),
                        row.status
                    ));
                }
                Word::PlanEndInvalid { value } => lines.push(format!(
                    "account-plan-end-invalid alias={} value={value}",
                    row.alias
                )),
                Word::Pick | Word::Reserve | Word::Retired { .. } => {}
            }
        }
        lines
    }

    /// Whether an account bills the harness and pool a pick would judge
    /// (`owed_wall`'s roster check).
    pub fn bills(&self, billed: &str, pool: &str) -> bool {
        self.rows.iter().any(|r| {
            r.harness == billed
                && ((r.raw.get("pool").and_then(Value::as_str) == Some("api-credit"))
                    == (pool == "api-credit"))
        })
    }
}

/// `lanes` through the one runner: `ORCH_LANE_RETIRE` emptied, so the
/// reader measures an account the machine retired instead of listing it
/// unread, and `ORCH_LANE_HOST=<host>` where a host is named, as the
/// legacy `bounded_account_read` ran it. The answer, or the call's own
/// failure.
#[allow(
    clippy::disallowed_methods,
    reason = "the accounts judge's legacy reads, `lanes list --json` and the delegated `lanes pick` (decision 121 Q9), through the one runner under its tag"
)]
fn lanes(
    settings: &Settings,
    host: Option<&str>,
    verb: &'static str,
    args: &[&str],
    retire_read: bool,
) -> std::result::Result<std::process::Output, String> {
    let mut env: Vec<(&str, &OsStr)> = Vec::new();
    if !retire_read {
        env.push(("ORCH_LANE_RETIRE", OsStr::new("")));
    }
    if let Some(h) = host {
        env.push(("ORCH_LANE_HOST", OsStr::new(h)));
    }
    host::run_tagged_in(
        TAG,
        "lanes",
        &settings.lanes_cli,
        verb,
        args,
        Place {
            cwd: None,
            env: &env,
        },
        BOUND,
    )
    .map_err(|e| e.to_string())
}

/// `lanes list --json`, for `host` where one is named: the roster, or the
/// cause where the call failed or its answer did not read, for the caller
/// to say in its place (`account-unread`'s fields, `oversee-watch:5165`).
pub fn roster(settings: &Settings, host: Option<&str>) -> std::result::Result<Roster, String> {
    let host_word = host.unwrap_or(LOCAL);
    let out = lanes(settings, host, "list", &["list", "--json"], false)
        .map_err(|cause| format!("host={host_word} {cause}"))?;
    if !out.status.success() {
        return Err(format!(
            "host={host_word} exit={} {}",
            out.status.code().unwrap_or(-1),
            host::stderr_text(&out).trim()
        ));
    }
    Roster::parse(&host::stdout_text(&out), &settings.accounts)
        .ok_or_else(|| format!("host={host_word} parse=failed"))
}

// --- the pick ---------------------------------------------------------------------------------

/// `lane_pick_harness` (`lib/lane-launch.sh:128`): the harness an account
/// is billed under for a launch of `harness` on `model`.
pub fn pick_harness(harness: &str, model: &str) -> &'static str {
    match harness {
        "claude" => "claude",
        "codex" => "codex",
        "copilot" => "copilot",
        "pi" => {
            if model.starts_with("pi-claude/") {
                "claude"
            } else if model.starts_with("github-copilot/") || model.starts_with("anthropic/") {
                "pi"
            } else {
                "unmeasured"
            }
        }
        _ => "unmeasured",
    }
}

/// `lane_pick_pool` (`lib/lane-launch.sh:143`) with the plan pool: the
/// spending pool a launch of `harness` on `model` names.
pub fn pick_pool(harness: &str, model: &str) -> &'static str {
    match harness {
        "pi" if model.starts_with("anthropic/") => "api-credit",
        "copilot" => "copilot",
        "pi" if model.starts_with("github-copilot/") => "copilot",
        _ => "plan",
    }
}

/// What a caller asks the judge: `lanes pick`'s own words.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PickRequest {
    pub harness: String,
    /// The selector the harness runs (`--native-model`).
    pub model: Option<String>,
    /// Config dirs the pick omits before judging (`--exclude-lane`).
    pub exclude: Vec<String>,
    /// The item of the lane a relaunch replaces: its charge is left out.
    pub replaces: Option<String>,
    /// Judge seats as ordinary accounts (`--for-overseer`).
    pub for_overseer: bool,
    /// Judge one named account (`--lane DIR`) instead of choosing.
    pub lane: Option<String>,
    /// Judge the named account on the projection (`--projected`).
    pub projected: bool,
    /// The bound in percent used; the setting where unset (`--max-pct`).
    pub max_pct: Option<u32>,
    /// The provider named (`ORCH_LANE_HOST`), `None` for the local read.
    pub host: Option<String>,
}

/// The window a lane is judged on, `lane-model.sh`'s `model_binding`.
#[derive(Debug, Clone, PartialEq)]
pub struct Binding {
    pub bucket: String,
    pub pct: f64,
    pub resets_at: Option<String>,
}

/// `lane_norm`: case-folded, every character that is not a letter or a
/// digit dropped.
fn norm(text: &str) -> String {
    text.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_lowercase())
        .collect()
}

/// `wall_rank`: the order two windows at one percentage are told apart by.
fn wall_rank(bucket: &str) -> u8 {
    match bucket {
        "monthly" => 3,
        "weekly" => 2,
        "model" => 1,
        _ => 0,
    }
}

/// `max_binding`: the window with the largest percentage, the higher rank
/// at a tie; `None` where none carries one.
fn max_binding(bindings: Vec<Binding>) -> Option<Binding> {
    bindings.into_iter().max_by(|a, b| {
        a.pct
            .total_cmp(&b.pct)
            .then(wall_rank(&a.bucket).cmp(&wall_rank(&b.bucket)))
    })
}

/// `lane_binding($model)`: an ended plan is a full wall; an unmeasured row
/// answers nothing; with a model the bucket with the largest usage among
/// the 5-hour session window, the plan-wide weekly window, the monthly
/// pool and the model-scoped windows whose label names the model (a
/// trailing `[1m]` dropped, the normalized spellings contained either
/// way; a window with no label counts for every model); with none, the
/// reader's own binding bucket.
fn lane_binding(row: &AccountRow, model: Option<&str>) -> Option<Binding> {
    if row.plan_ended() {
        return Some(Binding {
            bucket: "plan".to_owned(),
            pct: 100.0,
            resets_at: None,
        });
    }
    if !row.measured() {
        return None;
    }
    let Some(model) = model.filter(|m| !m.is_empty()) else {
        return row
            .headroom_pct
            .zip(row.binding_bucket.clone())
            .map(|(headroom, bucket)| Binding {
                bucket,
                pct: 100.0 - headroom,
                resets_at: row.binding_resets_at.clone(),
            });
    };
    let m = norm(
        model
            .strip_suffix("[1m]")
            .or_else(|| model.strip_suffix("[1M]"))
            .unwrap_or(model),
    );
    let resets = |key: &str| row.raw.get("resets").and_then(|r| string(r, key));
    let mut bindings = Vec::new();
    for (bucket, pct) in [
        ("session", row.session_5h_pct),
        ("weekly", row.weekly_pct),
        ("monthly", row.monthly_pct),
    ] {
        if let Some(pct) = pct {
            bindings.push(Binding {
                bucket: bucket.to_owned(),
                pct,
                resets_at: resets(bucket),
            });
        }
    }
    for bucket in &row.model_buckets {
        let l = bucket.label.as_deref().map(norm);
        let matches = match &l {
            None => true,
            Some(l) => !l.is_empty() && !m.is_empty() && (l.contains(&m) || m.contains(l)),
        };
        if matches {
            bindings.push(Binding {
                bucket: "model".to_owned(),
                pct: bucket.pct,
                resets_at: bucket.resets_at.clone(),
            });
        }
    }
    max_binding(bindings)
}

/// `reset_epoch`: a stamp as an epoch second, `None` where it is none.
fn reset_epoch(stamp: Option<&str>) -> Option<u64> {
    clock::epoch_secs(stamp?)
}

/// The projected rooms of one account (`with_lane_projection`): the window
/// that binds charged, per live lane, one hour of its burn (the measured
/// rate where the reader measured one on that same window, else the
/// setting scaled to the window's length), and the 5-hour session window
/// charged beside it, per live lane, its session burn for each hour left
/// to its reset. The smaller room decides.
#[derive(Debug, Clone, PartialEq)]
pub struct Projection {
    pub headroom: f64,
    pub window: Binding,
    pub burn: f64,
}

fn projection(
    row: &AccountRow,
    binding: &Binding,
    claims: u32,
    burn_default: f64,
    now: u64,
) -> Projection {
    let same_window = row.binding_bucket.as_deref() == Some(binding.bucket.as_str());
    let burn = match row.usage_rate_pct_per_min {
        Some(rate) if claims > 0 && same_window => rate * 60.0,
        _ => match binding.bucket.as_str() {
            "session" => burn_default,
            "monthly" => burn_default * 5.0 / 720.0,
            _ => burn_default * 5.0 / 168.0,
        },
    };
    let claims = f64::from(claims);
    let binding_room = 100.0 - binding.pct - claims * burn;
    let session_reset = reset_epoch(row.session_resets_at.as_deref());
    let session_hours = match session_reset {
        None => 1.0,
        Some(reset) => ((reset as f64 - now as f64) / 3600.0).clamp(1.0, 5.0),
    };
    let session_burn = match (row.session_5h_pct, session_reset) {
        _ if binding.bucket == "session" && row.usage_rate_pct_per_min.is_some() => burn,
        (Some(pct), Some(reset)) => {
            let sample_at = now as f64 - row.usage_age_s.unwrap_or(0.0);
            let hours = ((sample_at - (reset as f64 - 18000.0)) / 3600.0).max(1.0 / 60.0);
            pct / hours
        }
        (None, _) | (_, None) => burn_default,
    };
    let session_room = row
        .session_5h_pct
        .map(|pct| 100.0 - pct - claims * session_burn * session_hours);
    match session_room {
        Some(room) if room < binding_room => Projection {
            headroom: room,
            window: Binding {
                bucket: "session".to_owned(),
                pct: row.session_5h_pct.unwrap_or(0.0),
                resets_at: row.session_resets_at.clone(),
            },
            burn,
        },
        Some(_) | None => Projection {
            headroom: binding_room,
            window: binding.clone(),
            burn,
        },
    }
}

/// `wall_verdict($max)` over one percentage: room, walled, or unmeasured.
fn wall_verdict(wall: Option<f64>, max: f64) -> &'static str {
    match wall {
        None => "unmeasured",
        Some(w) if w < max => "room",
        Some(_) => "walled",
    }
}

/// `credit_room($credit_floor)`: a Codex account whose credit balance
/// OpenAI spends once the plan windows are reached, strictly above the
/// floor, with the three flags as the reader printed them.
fn credit_room(row: &AccountRow, floor: f64) -> bool {
    let Some(credits) = &row.credits else {
        return false;
    };
    row.harness == "codex"
        && credits.get("has_credits") == Some(&Value::Bool(true))
        && credits.get("overage_limit_reached") == Some(&Value::Bool(false))
        && credits.get("spend_control_reached") == Some(&Value::Bool(false))
        && credits
            .get("balance")
            .and_then(Value::as_f64)
            .is_some_and(|b| b > floor)
}

/// One account judged for one launch.
#[derive(Debug, Clone, PartialEq)]
pub struct Judged {
    pub row: AccountRow,
    /// `room`, `walled`, `unmeasured`, `seat-reserve`, `reserved`,
    /// `retired` or `plan-end-invalid`.
    pub verdict: String,
    /// The reading's wall: the binding window's percentage used.
    pub wall: Option<f64>,
    pub binding: Option<Binding>,
    pub claims: u32,
    pub projection: Option<Projection>,
    pub seat: bool,
    pub credits: bool,
    pub score: Option<f64>,
}

impl Judged {
    /// The record a caller reads: the reader's row with the judgement's
    /// fields over it, as `lanes pick --json` printed them.
    pub fn record(&self) -> Value {
        let mut record = match &self.row.raw {
            Value::Object(m) => m.clone(),
            _ => Map::new(),
        };
        let number = Value::from;
        record.insert("word".to_owned(), Value::from(self.row.word().text()));
        if let Some(retire) = &self.row.retire {
            record.insert("retire_date".to_owned(), Value::from(retire.as_str()));
        }
        record.insert("claims".to_owned(), Value::from(self.claims));
        record.insert("wall".to_owned(), self.wall.map_or(Value::Null, number));
        if let Some(binding) = &self.binding {
            record.insert(
                "binding_bucket".to_owned(),
                Value::from(binding.bucket.as_str()),
            );
            record.insert(
                "binding_resets_at".to_owned(),
                binding
                    .resets_at
                    .as_deref()
                    .map_or(Value::Null, Value::from),
            );
            record.insert("headroom_pct".to_owned(), number(100.0 - binding.pct));
        }
        if self.credits {
            record.insert("binding_bucket".to_owned(), Value::from("credits"));
        }
        match &self.projection {
            Some(p) => {
                record.insert("projected_headroom_pct".to_owned(), number(p.headroom));
                record.insert("burn_pct_per_lane_hour".to_owned(), number(p.burn));
                record.insert(
                    "projected_window".to_owned(),
                    json!({
                        "bucket": p.window.bucket,
                        "pct": p.window.pct,
                        "resets_at": p.window.resets_at,
                    }),
                );
            }
            None => {
                record.insert("projected_headroom_pct".to_owned(), Value::Null);
                record.insert("projected_window".to_owned(), Value::Null);
            }
        }
        record.insert(
            "selection_score".to_owned(),
            self.score.map_or(Value::Null, number),
        );
        record.insert("verdict".to_owned(), Value::from(self.verdict.as_str()));
        record.insert("seat".to_owned(), Value::from(self.seat));
        Value::Object(record)
    }

    /// The earliest moment this walled account could have room: the
    /// projected window's reset where one was projected, else the
    /// binding's.
    fn retry_at(&self) -> Option<String> {
        match &self.projection {
            Some(p) => p.window.resets_at.clone(),
            None => self.binding.as_ref().and_then(|b| b.resets_at.clone()),
        }
    }
}

/// The judge's answer, `lanes pick`'s exits by name.
#[derive(Debug, Clone, PartialEq)]
pub enum PickAnswer {
    /// Exit 0: the account to spend.
    Lane(Judged),
    /// Exit 3 of the chooser: no account qualifies.
    None {
        walled: u32,
        unmeasured: u32,
        seats: Vec<Judged>,
        walled_resets_at: Option<String>,
        exclusions: Vec<(String, String)>,
    },
    /// Exit 3 of `--lane`: the named account is walled or on its seat's
    /// reserve.
    Walled(Judged),
    /// Exit 3 of `--lane`: the provider reserved the named account (round
    /// 8 item 7). Its word refuses it, whatever its room; a caller prints
    /// the word, never the wall's figures.
    Reserved(Judged),
    /// Exit 3 of `--lane`: the named account's stated end has come. The
    /// day and who stated it are the refusal's, never the wall's figures.
    Retired {
        judged: Judged,
        ends: String,
        source: EndSource,
    },
    /// Exit 5 of `--lane`: nothing measured the named account.
    Unmeasured(Judged),
    /// Exit 4 of `--lane`: no row names the directory.
    NoRecord,
    /// The judge could not judge: the listing or the occupancy unread, or
    /// a delegated read that failed. Never a verdict.
    Unjudged { cause: String },
}

impl PickAnswer {
    /// `lanes pick`'s exit status for this answer.
    pub fn exit(&self) -> i32 {
        match self {
            PickAnswer::Lane(_) => 0,
            PickAnswer::None { .. }
            | PickAnswer::Walled(_)
            | PickAnswer::Reserved(_)
            | PickAnswer::Retired { .. } => 3,
            PickAnswer::NoRecord => 4,
            PickAnswer::Unmeasured(_) => 5,
            PickAnswer::Unjudged { .. } => 1,
        }
    }

    /// The reply a caller reads: the answer's word, the exit it maps to,
    /// and the record or the counts `lanes pick --json` printed.
    pub fn reply(&self) -> Value {
        let (answer, record) = match self {
            PickAnswer::Lane(j) => ("lane", j.record()),
            PickAnswer::None {
                walled,
                unmeasured,
                seats,
                walled_resets_at,
                exclusions,
            } => (
                "none",
                json!({
                    "walled": walled,
                    "unmeasured": unmeasured,
                    "seats": seats.iter().map(|s| json!({
                        "config_dir": s.row.config_dir,
                        "projected_headroom_pct": s.projection.as_ref().map(|p| p.headroom),
                    })).collect::<Vec<Value>>(),
                    "qualifying_count": 0,
                    "walled_resets_at": walled_resets_at,
                    "refusals": [],
                    "exclusions": exclusions.iter().map(|(d, r)| json!({"config_dir": d, "reason": r})).collect::<Vec<Value>>(),
                }),
            ),
            PickAnswer::Walled(j) => ("walled", j.record()),
            PickAnswer::Reserved(j) => ("reserved", j.record()),
            PickAnswer::Retired { judged, .. } => ("retired", judged.record()),
            PickAnswer::Unmeasured(j) => ("unmeasured", j.record()),
            PickAnswer::NoRecord => ("no-record", Value::Null),
            PickAnswer::Unjudged { cause } => ("unjudged", json!({"cause": cause})),
        };
        json!({"answer": answer, "exit": self.exit(), "record": record})
    }
}

/// What the judge reads beside the rows: the seats and the fleet's live
/// charges per account, each from this fleet's own records.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FleetFacts {
    /// Canonical config dirs the fleet's overseer and the provider's
    /// `seat=1` rows hold.
    pub seats: Vec<String>,
    /// Live charges per canonical config dir (decision 97).
    pub charges: BTreeMap<String, u32>,
}

/// Judge one row for `req`.
fn judge(
    row: &AccountRow,
    req: &PickRequest,
    facts: &FleetFacts,
    settings: &AccountSettings,
    today: &str,
    now: u64,
) -> Judged {
    let max = f64::from(req.max_pct.unwrap_or(settings.max_pct));
    let claims = facts.charges.get(&row.canon).copied().unwrap_or(0);
    let binding = lane_binding(row, req.model.as_deref());
    let wall = binding.as_ref().map(|b| b.pct);
    let projection = binding
        .as_ref()
        .map(|b| projection(row, b, claims, f64::from(settings.burn_pct_per_hour), now));
    let judged_wall = if req.projected || req.lane.is_none() {
        projection.as_ref().map(|p| 100.0 - p.headroom)
    } else {
        wall
    };
    let seat = !req.for_overseer
        && row.harness != "copilot"
        && row.harness != "pi"
        && facts.seats.contains(&row.canon);
    let reserve = if req.for_overseer {
        0.0
    } else {
        f64::from(settings.seat_reserve_pct)
    };
    let ordinary = wall_verdict(judged_wall, max);
    let limit = if seat { max.min(100.0 - reserve) } else { max };
    let plan = wall_verdict(judged_wall, limit);
    let mut credits = false;
    let verdict = match row.standing(today) {
        Standing::Reserved => "reserved",
        Standing::Retired { .. } => "retired",
        Standing::EndUnread { .. } => "plan-end-invalid",
        Standing::Open => {
            if row.plan_ended() {
                "walled"
            } else if ordinary == "walled"
                && credit_room(row, settings.codex_credit_floor as f64)
                && (!seat || reserve < 100.0)
            {
                credits = true;
                "room"
            } else if seat && plan == "walled" {
                "seat-reserve"
            } else {
                plan
            }
        }
    };
    let score = if credits {
        row.credits
            .as_ref()
            .and_then(|c| c.get("balance"))
            .and_then(Value::as_f64)
    } else {
        projection.as_ref().map(|p| {
            let hours = binding
                .as_ref()
                .and_then(|b| reset_epoch(b.resets_at.as_deref()))
                .map(|reset| (reset as f64 - now as f64).max(0.0) / 3600.0);
            p.headroom * hours.map_or(1.0, |h| 1.0 + 1.0 / (1.0 + h))
        })
    };
    Judged {
        row: row.clone(),
        verdict: verdict.to_owned(),
        wall,
        binding,
        claims,
        projection,
        seat,
        credits,
        score,
    }
}

/// The pick over `rows` (`lane_selection`, `lanes --help` § pick): the
/// candidates are the rows billed under the launch's harness, the excluded
/// directories left out; each is judged on its projected wall; the room
/// rows are ordered a seat last, then credits after plan windows, then by
/// score, fewer claims, more projected room and the lower wall; the first
/// is the lane. With `lane` named, that one row is judged alone.
pub fn pick(
    rows: &[AccountRow],
    req: &PickRequest,
    facts: &FleetFacts,
    settings: &AccountSettings,
    now: u64,
) -> PickAnswer {
    let today = today(now);
    let billed = pick_harness(&req.harness, req.model.as_deref().unwrap_or(""));
    if let Some(lane) = &req.lane {
        let canon = wall::canon(lane);
        let Some(row) = rows
            .iter()
            .find(|r| r.canon == canon && r.harness == billed)
        else {
            return PickAnswer::NoRecord;
        };
        return named_answer(judge(row, req, facts, settings, &today, now), &today);
    }
    let excluded: Vec<String> = req.exclude.iter().map(|d| wall::canon(d)).collect();
    let judged: Vec<Judged> = rows
        .iter()
        .filter(|r| r.harness == billed && !excluded.contains(&r.canon))
        .map(|r| judge(r, req, facts, settings, &today, now))
        .collect();
    let mut room: Vec<&Judged> = judged.iter().filter(|j| j.verdict == "room").collect();
    room.sort_by(|a, b| {
        let tier = |j: &Judged| u8::from(j.credits);
        let neg = |v: Option<f64>| v.map(|n| -n);
        a.seat
            .cmp(&b.seat)
            .then(tier(a).cmp(&tier(b)))
            .then(
                neg(a.score)
                    .unwrap_or(f64::INFINITY)
                    .total_cmp(&neg(b.score).unwrap_or(f64::INFINITY)),
            )
            .then(a.claims.cmp(&b.claims))
            .then(
                neg(a.projection.as_ref().map(|p| p.headroom))
                    .unwrap_or(f64::INFINITY)
                    .total_cmp(
                        &neg(b.projection.as_ref().map(|p| p.headroom)).unwrap_or(f64::INFINITY),
                    ),
            )
            .then(
                a.wall
                    .unwrap_or(f64::INFINITY)
                    .total_cmp(&b.wall.unwrap_or(f64::INFINITY)),
            )
    });
    if let Some(chosen) = room.first() {
        return PickAnswer::Lane((*chosen).clone());
    }
    let walled: Vec<&Judged> = judged.iter().filter(|j| j.verdict == "walled").collect();
    PickAnswer::None {
        walled: walled.len() as u32,
        unmeasured: judged.iter().filter(|j| j.verdict == "unmeasured").count() as u32,
        seats: judged
            .iter()
            .filter(|j| j.verdict == "seat-reserve")
            .cloned()
            .collect(),
        walled_resets_at: walled.iter().filter_map(|j| j.retry_at()).min(),
        exclusions: judged
            .iter()
            .filter(|j| j.verdict != "room")
            .map(|j| (j.row.config_dir.clone(), j.verdict.clone()))
            .collect(),
    }
}

/// A `--lane` pick's answer from its one judgement: the word's refusal
/// where the word refused it (an end nobody can read is no verdict, so it
/// is unjudged with the cause, decision 99), else the windows' answer by
/// `lanes pick --lane`'s exits.
fn named_answer(judged: Judged, today: &str) -> PickAnswer {
    match judged.row.standing(today) {
        Standing::Reserved => PickAnswer::Reserved(judged),
        Standing::Retired { date, source } => PickAnswer::Retired {
            judged,
            ends: date,
            source,
        },
        Standing::EndUnread { value } => PickAnswer::Unjudged {
            cause: format!("plan-end-invalid alias={} value={value}", judged.row.alias),
        },
        Standing::Open => match judged.verdict.as_str() {
            "room" => PickAnswer::Lane(judged),
            "unmeasured" => PickAnswer::Unmeasured(judged),
            _ => PickAnswer::Walled(judged),
        },
    }
}

/// The fleet's seats and live charges per account from its state file
/// (decision 97): the overseer's account is a seat; every lane record
/// charges its account while the occupancy reader proves its identity
/// live, protects it unknown, or holds it preparing or reserved; the lane
/// `replaces` names is left out. The provider's `seat=1` rows join the
/// seats from the listing.
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
    let occupancy = occupancy::occupancy(&fleet.lanes, &fleet.intents, None, &[], now, host);
    for charge in occupancy.charges {
        let ChargeSource::Lane { item } = charge.source else {
            continue;
        };
        if replaces == Some(item.as_str()) {
            continue;
        }
        let Some(account) = fleet
            .lanes
            .iter()
            .find(|l| l.item == item)
            .and_then(|l| l.account.as_deref())
            .filter(|a| !a.is_empty())
        else {
            continue;
        };
        *facts.charges.entry(wall::canon(account)).or_insert(0) += 1;
    }
    Ok(facts)
}

/// Whether `req`'s windows are judged here or by the legacy reader: a pick
/// under a provider (its rows standing in for this machine's, its seats
/// and its cloud credit) and a pick on an API grant (`api-credit`, tier
/// 0's expires-first rule) stay `lanes pick`'s until those rules are
/// ported. The words are this judge's on either path ([`delegated_pick`]).
pub fn delegated(req: &PickRequest) -> bool {
    req.host
        .as_deref()
        .is_some_and(|h| h != LOCAL && !h.is_empty())
        || pick_pool(&req.harness, req.model.as_deref().unwrap_or("")) == "api-credit"
}

/// The legacy `lanes pick` for `req`, its answer read as the legacy
/// callers read it: the record at exit 0, the counts at exit 3 (the
/// chooser) or the record (a named lane), the record at 5, nothing at 4;
/// any other exit, a signal or an unreadable answer is unjudged with the
/// cause.
fn legacy_pick(settings: &Settings, req: &PickRequest) -> PickAnswer {
    let mut args: Vec<String> = vec![
        "pick".to_owned(),
        "--harness".to_owned(),
        req.harness.clone(),
    ];
    if let Some(model) = &req.model {
        args.push("--native-model".to_owned());
        args.push(model.clone());
    }
    for dir in &req.exclude {
        args.push("--exclude-lane".to_owned());
        args.push(dir.clone());
    }
    if let Some(lane) = &req.lane {
        args.push("--lane".to_owned());
        args.push(lane.clone());
    }
    if req.projected {
        args.push("--projected".to_owned());
    }
    if req.for_overseer {
        args.push("--for-overseer".to_owned());
    }
    if let Some(max) = req.max_pct {
        args.push("--max-pct".to_owned());
        args.push(max.to_string());
    }
    args.push("--json".to_owned());
    let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
    let out = match lanes(settings, req.host.as_deref(), "pick", &arg_refs, true) {
        Ok(out) => out,
        Err(cause) => return PickAnswer::Unjudged { cause },
    };
    let record = |out: &std::process::Output| -> Option<Judged> {
        let value: Value = serde_json::from_str(&host::stdout_text(out)).ok()?;
        let row = AccountRow::parse(&value, &settings.accounts)?;
        let verdict = string(&value, "verdict").unwrap_or_default();
        Some(Judged {
            wall: number(&value, "wall"),
            binding: None,
            claims: value.get("claims").and_then(Value::as_u64).unwrap_or(0) as u32,
            projection: None,
            seat: false,
            credits: string(&value, "binding_bucket").as_deref() == Some("credits"),
            score: number(&value, "selection_score"),
            verdict,
            row,
        })
    };
    let unparsed = || PickAnswer::Unjudged {
        cause: "pick-unparsed".to_owned(),
    };
    match out.status.code() {
        Some(0) => record(&out).map_or_else(unparsed, PickAnswer::Lane),
        Some(3) if req.lane.is_some() => record(&out).map_or_else(unparsed, PickAnswer::Walled),
        Some(3) => {
            let Ok(counts) = serde_json::from_str::<Value>(&host::stdout_text(&out)) else {
                return unparsed();
            };
            PickAnswer::None {
                walled: counts.get("walled").and_then(Value::as_u64).unwrap_or(0) as u32,
                unmeasured: counts
                    .get("unmeasured")
                    .and_then(Value::as_u64)
                    .unwrap_or(0) as u32,
                seats: Vec::new(),
                walled_resets_at: string(&counts, "walled_resets_at"),
                exclusions: counts
                    .get("exclusions")
                    .and_then(Value::as_array)
                    .map(|rows| {
                        rows.iter()
                            .map(|e| (text(e, "config_dir"), text(e, "reason")))
                            .collect()
                    })
                    .unwrap_or_default(),
            }
        }
        Some(4) => PickAnswer::NoRecord,
        Some(5) => record(&out).map_or_else(unparsed, PickAnswer::Unmeasured),
        Some(code) => PickAnswer::Unjudged {
            cause: format!("exit={code} {}", host::stderr_text(&out).trim()),
        },
        None => PickAnswer::Unjudged {
            cause: "signalled".to_owned(),
        },
    }
}

/// The [`delegated`] pick (decision 188 (b)): the legacy reader judges
/// none of the provider's words, so the roster is read with the host
/// first and the words applied here. A `--lane` pick naming an account
/// the word refuses is answered without asking; a chooser's pick hands
/// every such account of the billed harness to `lanes pick` as an
/// exclusion beside the request's own (`pick --lane` takes none, and
/// judges its one row). A roster that cannot be read is unjudged with the
/// cause (decision 99): never a pick that ignores the word.
fn delegated_pick(settings: &Settings, req: &PickRequest, now: u64) -> PickAnswer {
    let roster = match roster(settings, req.host.as_deref()) {
        Ok(roster) => roster,
        Err(cause) => {
            return PickAnswer::Unjudged {
                cause: format!("listing-unread {cause}"),
            };
        }
    };
    let today = today(now);
    let billed = pick_harness(&req.harness, req.model.as_deref().unwrap_or(""));
    let refused: Vec<&AccountRow> = roster
        .rows
        .iter()
        .filter(|r| r.harness == billed && r.standing(&today) != Standing::Open)
        .collect();
    let Some(lane) = &req.lane else {
        let exclude = req
            .exclude
            .iter()
            .cloned()
            .chain(refused.iter().map(|r| r.config_dir.clone()))
            .collect();
        return legacy_pick(
            settings,
            &PickRequest {
                exclude,
                ..req.clone()
            },
        );
    };
    let canon = wall::canon(lane);
    match refused.iter().find(|r| r.canon == canon) {
        Some(row) => named_answer(
            judge(
                row,
                req,
                &FleetFacts::default(),
                &settings.accounts,
                &today,
                now,
            ),
            &today,
        ),
        None => legacy_pick(settings, req),
    }
}

/// The pick a caller receives (decision 94 (b)): the listing read through
/// the reader, the fleet's seats and charges read from its state, the
/// judgement over them; or, where [`delegated`], the words applied here
/// and the windows the legacy reader's own judgement. An unread listing or
/// fleet is unjudged, never a verdict.
pub fn pick_fleet(
    settings: &Settings,
    fleet_path: &Path,
    host: &Host,
    req: &PickRequest,
    now: u64,
) -> PickAnswer {
    let req = &PickRequest {
        host: req.host.clone().or_else(|| settings.accounts.host.clone()),
        ..req.clone()
    };
    if delegated(req) {
        return delegated_pick(settings, req, now);
    }
    let rows = match roster(settings, None) {
        Ok(roster) => roster.rows,
        Err(cause) => {
            return PickAnswer::Unjudged {
                cause: format!("listing-unread {cause}"),
            };
        }
    };
    let facts = match fleet_facts(fleet_path, &rows, req.replaces.as_deref(), host, now) {
        Ok(facts) => facts,
        Err(cause) => {
            return PickAnswer::Unjudged {
                cause: format!("fleet-unread {cause}"),
            };
        }
    };
    pick(&rows, req, &facts, &settings.accounts, now)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::Retirement;

    fn settings() -> AccountSettings {
        AccountSettings {
            retire: vec![Retirement {
                name: "oldclaude".to_owned(),
                date: "2026-10-20".to_owned(),
            }],
            max_pct: 95,
            burn_pct_per_hour: 5,
            seat_reserve_pct: 50,
            codex_credit_floor: 5000,
            host: None,
        }
    }

    fn row(json: Value) -> AccountRow {
        AccountRow::parse(&json, &settings()).expect("a row")
    }

    /// `lane_pick_harness` and `lane_pick_pool` on the launcher's own
    /// cases (`lib/lane-launch.sh:128-150`).
    #[test]
    fn the_billed_harness_and_pool_follow_the_launchers_tables() {
        let rows = [
            ("claude", "claude-sonnet-5", "claude", "plan"),
            ("codex", "-", "codex", "plan"),
            ("copilot", "-", "copilot", "copilot"),
            ("pi", "pi-claude/opus", "claude", "plan"),
            ("pi", "github-copilot/gpt", "pi", "copilot"),
            ("pi", "anthropic/claude", "pi", "api-credit"),
            ("pi", "other/model", "unmeasured", "plan"),
        ];
        for (harness, model, billed, pool) in rows {
            assert_eq!(pick_harness(harness, model), billed, "{harness} {model}");
            assert_eq!(pick_pool(harness, model), pool, "{harness} {model}");
        }
    }

    /// A listing is one array of records each carrying `status` and
    /// `verdict`; anything else is unread, never an empty roster. The
    /// machine's stated end is matched on the alias, the directory name or
    /// that name without its dot, and the provider's words are read from
    /// the row.
    #[test]
    fn a_listing_reads_whole_or_not_at_all_and_the_words_are_matched_onto_its_rows() {
        let s = settings();
        assert!(Roster::parse("[]", &s).is_some_and(|l| l.rows.is_empty()));
        assert!(Roster::parse("", &s).is_none());
        assert!(Roster::parse("{}", &s).is_none());
        assert!(Roster::parse(r#"[{"alias":"a","status":"ok"}]"#, &s).is_none());
        let roster = Roster::parse(
            r#"[{"alias":"a","harness":"claude","config_dir":"/h/.a","measured_through":"local","status":"ok","verdict":"room","headroom_pct":0,"binding_bucket":"weekly","binding_resets_at":"2026-10-01T00:00:00Z"},
                {"alias":"oldclaude","harness":"claude","config_dir":"/h/.oldclaude","measured_through":"local","status":"ok","verdict":"room","headroom_pct":40,"binding_bucket":"weekly","binding_resets_at":null},
                {"alias":"r","harness":"claude","config_dir":"/h/.r","measured_through":"host","status":"ok","verdict":"room","headroom_pct":90,"binding_bucket":"weekly","binding_resets_at":null,"reserved":1,"seat":"1","plan-ends":"2026-12-01"}]"#,
            &s,
        )
        .unwrap();
        assert_eq!(
            roster.lines("2026-10-19"),
            vec![
                "account a config_dir=/h/.a harness=claude through=local status=ok verdict=room headroom_pct=0 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z",
                "account oldclaude config_dir=/h/.oldclaude harness=claude through=local status=ok verdict=room headroom_pct=40 binding_bucket=weekly binding_resets_at=- word=retired:2026-10-20",
                "account r config_dir=/h/.r harness=claude through=host status=ok verdict=room headroom_pct=90 binding_bucket=weekly binding_resets_at=- word=reserve",
            ]
        );
        assert_eq!(roster.rows[0].word(), Word::Pick);
        assert_eq!(
            roster.rows[1].word(),
            Word::Retired {
                date: "2026-10-20".to_owned(),
                source: EndSource::Setting
            }
        );
        assert!(!roster.rows[1].ended("2026-10-19"));
        assert!(roster.rows[1].ended("2026-10-20"));
        assert_eq!(roster.rows[2].word(), Word::Reserve);
        assert!(roster.rows[2].seat);
        assert_eq!(
            roster.rows[2].plan_ends,
            PlanEnd::Day("2026-12-01".to_owned())
        );
        assert!(roster.bills("claude", "plan"));
        assert!(!roster.bills("codex", "plan"));
        assert!(!roster.bills("claude", "api-credit"));
        // The stated end come and the credential still answering: the
        // contradiction line under the roster, and the account not picked.
        let lines = roster.lines("2026-10-20");
        assert_eq!(
            lines.last().map(String::as_str),
            Some(
                "account-end-contradicted oldclaude config_dir=/h/.oldclaude ends=2026-10-20 source=ORCH_LANE_RETIRE status=ok"
            )
        );
        assert!(names("x", "/h/.oldclaude", "oldclaude"));
        assert!(names("x", "/h/.oldclaude", ".oldclaude"));
        assert!(names("oldclaude", "/h/.y", "oldclaude"));
        assert!(!names("x", "/h/.y", "oldclaude"));
    }

    /// `model_binding` on `lane-model.sh`'s own cases: the scoped window
    /// whose label names the model, in either direction over the
    /// normalized spellings, a trailing `[1m]` dropped, an unlabeled
    /// window for every model, and the fullest shared window otherwise.
    #[test]
    fn the_model_binding_is_the_fullest_window_that_walls_the_model() {
        let r = row(json!({
            "alias": "a", "harness": "claude", "config_dir": "/h/.a", "measured_through": "local",
            "status": "ok", "verdict": "room", "headroom_pct": 10, "binding_bucket": "model",
            "binding_resets_at": null, "session_5h_pct": 20, "weekly_pct": 30, "monthly_pct": null,
            "resets": {"session": "2026-10-01T05:00:00Z", "weekly": "2026-10-03T00:00:00Z"},
            "model_buckets": [
                {"label": "Opus 5", "pct": 90, "resets_at": "2026-10-04T00:00:00Z"},
                {"label": "Fable 5.1", "pct": 60, "resets_at": null},
                {"label": null, "pct": 35, "resets_at": null}
            ]
        }));
        let binding = |model: Option<&str>| lane_binding(&r, model).map(|b| (b.bucket, b.pct));
        assert_eq!(
            binding(Some("claude-sonnet-5-5")),
            Some(("model".to_owned(), 35.0))
        );
        assert_eq!(
            binding(Some("claude-fable-5-1[1m]")),
            Some(("model".to_owned(), 60.0))
        );
        assert_eq!(binding(Some("opus")), Some(("model".to_owned(), 90.0)));
        assert_eq!(binding(None), Some(("model".to_owned(), 90.0)));
        assert_eq!(binding(Some("")), Some(("model".to_owned(), 90.0)));
        let shared_only = row(json!({
            "alias": "b", "harness": "claude", "config_dir": "/h/.b", "measured_through": "local",
            "status": "ok", "verdict": "room", "headroom_pct": 70, "binding_bucket": "weekly",
            "session_5h_pct": 20, "weekly_pct": 30, "model_buckets": [], "resets": {}
        }));
        assert_eq!(
            lane_binding(&shared_only, Some("sonnet")).map(|b| (b.bucket, b.pct)),
            Some(("weekly".to_owned(), 30.0))
        );
        let unmeasured = row(json!({
            "alias": "c", "harness": "claude", "config_dir": "/h/.c", "measured_through": "local",
            "status": "unreachable", "verdict": "unmeasured", "headroom_pct": null
        }));
        assert_eq!(lane_binding(&unmeasured, Some("sonnet")), None);
        let ended = row(json!({
            "alias": "d", "harness": "claude", "config_dir": "/h/.d", "measured_through": "local",
            "status": "plan_ended", "verdict": "walled", "headroom_pct": 0
        }));
        assert_eq!(
            lane_binding(&ended, Some("sonnet")).map(|b| (b.bucket, b.pct)),
            Some(("plan".to_owned(), 100.0))
        );
    }

    /// The grammar every stated date is held to.
    #[test]
    fn a_stated_end_names_a_real_calendar_day() {
        for ok in ["2026-10-20", "2024-02-29", "2026-12-31"] {
            assert!(crate::settings::calendar_date_valid(ok), "{ok}");
        }
        for bad in [
            "2026-13-01",
            "2026-02-30",
            "2025-02-29",
            "26-10-20",
            "2026-10-2",
            "x",
        ] {
            assert!(!crate::settings::calendar_date_valid(bad), "{bad}");
        }
    }
}
