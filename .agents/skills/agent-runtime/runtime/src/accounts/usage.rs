//! The readers of a usage endpoint's answer and of a harness's stored
//! login: each harness's body turned into the bucket record the listing
//! emits, the HTTP capture split into its status, Retry-After and body,
//! and the credential files read for a token and its expiry.
//!
//! The Claude endpoint is the OAuth usage endpoint Claude Code reads; the
//! Codex endpoint is the ChatGPT backend's usage endpoint, undocumented,
//! whose documented counterpart (the app server's `account/rateLimits/
//! read`) carries no `overage_limit_reached` and needs a process per
//! account; the Copilot endpoint is `copilot_internal/user`, read the way
//! GitHub's own clients read it. Every field is checked for its type: a
//! percentage that does not read makes the whole reading unmeasured, since
//! the windows beside it would otherwise bind the lane and hide a window
//! that may be exhausted; a window the body omits is no reading and leaves
//! the others measured.

use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use super::wall::canon;
use crate::harness::Harness;
use crate::launch::ClaudeSignIn;
use crate::settings;

/// Five hours: a Codex window more than half again as long is its weekly
/// one, since Codex reports window durations that vary by account, and a
/// kept figure younger than this answers a usage 429.
pub const FIVE_HOURS_S: u64 = 18_000;

/// One network answer in the shape both calls answer in: the HTTP status
/// and any Retry-After on the first line, the body under it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Answer {
    /// `None` where the capture named no three-digit status.
    pub code: Option<u16>,
    pub retry_after: Option<String>,
    pub body: String,
}

/// Turn a `curl -D - -w '\n%{http_code}'` capture into an [`Answer`]. The
/// headers reach stdout ahead of the body, so the body starts after the
/// LAST header block: a 1xx interim response is a block of its own, and a
/// split at the first blank line would hand the real headers back as the
/// body. Each block starts its own header read, so a Retry-After an
/// interim or redirect block carried is never read as the refusal's own.
pub fn answer(capture: &str) -> Answer {
    let capture = capture.replace('\r', "");
    let (rest, code) = match capture.rsplit_once('\n') {
        Some((rest, code)) => (rest, code),
        None => ("", capture.as_str()),
    };
    let code = (code.len() == 3 && code.bytes().all(|b| b.is_ascii_digit()))
        .then(|| code.parse::<u16>().ok())
        .flatten();
    let mut in_headers = true;
    let mut blank = false;
    let mut retry: Option<String> = None;
    let mut body = Vec::new();
    for line in rest.split('\n') {
        if in_headers {
            if blank && line.starts_with("HTTP/") {
                blank = false;
                retry = None;
                continue;
            }
            if blank {
                in_headers = false;
                body.push(line);
                continue;
            }
            if line.is_empty() {
                blank = true;
                continue;
            }
            if let Some((name, value)) = line.split_once(':')
                && name.eq_ignore_ascii_case("retry-after")
            {
                retry = value.split_whitespace().next().map(str::to_owned);
            }
            continue;
        }
        body.push(line);
    }
    Answer {
        code,
        retry_after: retry.filter(|r| !r.is_empty()),
        body: body.join("\n"),
    }
}

/// What an HTTP refusal of a lane's own request means for the lane, with
/// the caller's reading of every other code as `default`. `expired` asks
/// the operator to log in again, so an HTTP refusal the account will
/// survive never takes it.
pub fn refusal_status(code: u16, default: &str) -> String {
    match code {
        429 => "rate_limited".to_owned(),
        500..=599 => "unreachable".to_owned(),
        _ => default.to_owned(),
    }
}

/// Whether a figure is rendered as the display percentage or kept as the
/// fraction a consumed-reset check reads: a positive fraction is consumed
/// capacity even when the displayed whole percentage is zero.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rounding {
    Rounded,
    Unrounded,
}

/// A percentage read from a body: `None` where it is missing, not a
/// number or out of range, the unmeasured reading the judge refuses; 0
/// would read as an empty window. The range is judged before rounding:
/// -0.4 rounds to -0, which no range check rejects.
fn pct(value: Option<&Value>, rounding: Rounding, round: fn(f64) -> f64) -> Option<f64> {
    let p = value?.as_f64()?;
    if !(0.0..=1e12).contains(&p) {
        return None;
    }
    Some(match rounding {
        Rounding::Rounded => round(p),
        Rounding::Unrounded => p,
    })
}

fn number(v: Option<&Value>) -> Value {
    v.and_then(Value::as_f64).map_or(Value::Null, Value::from)
}

fn string(v: Option<&Value>) -> Value {
    v.and_then(Value::as_str).map_or(Value::Null, Value::from)
}

fn f64_value(n: Option<f64>) -> Value {
    n.map_or(Value::Null, Value::from)
}

/// Claude: `.seven_day` carries utilization and resets_at; the 5-hour
/// `.five_hour` is no plan window the listing rates, kept as
/// `session_5h_pct` for the judge (`accounts::SESSION`), with its reset for
/// the usage cache;
/// `.iguana_necktie`, the cloud credit in dollars, is kept as `credits`.
/// The model-scoped weekly windows are the `limits[]` entries of kind
/// `weekly_scoped`; the older `seven_day_sonnet` and `seven_day_opus`
/// fields stand in where a body carries no entries. Every scoped window is
/// kept in `model_buckets`, the label the API's own display name and
/// nothing where it omits one: a window nobody can name may wall any
/// model, and a filler string would be a name matching no model.
pub fn parse_claude(body: &Value, rounding: Rounding) -> Value {
    let round = |p: f64| p.round();
    let weekly = body.get("seven_day").filter(|v| !v.is_null());
    let live: Vec<&Value> = body
        .get("limits")
        .and_then(Value::as_array)
        .map(|limits| {
            limits
                .iter()
                .filter(|l| l.is_object())
                .filter(|l| {
                    l.get("kind").and_then(Value::as_str) == Some("weekly_scoped")
                        || (l.get("group").and_then(Value::as_str) == Some("weekly")
                            && l.get("scope").is_some_and(|s| !s.is_null()))
                })
                .collect()
        })
        .unwrap_or_default();
    let mut older = Vec::new();
    for (field, name) in [("seven_day_sonnet", "Sonnet"), ("seven_day_opus", "Opus")] {
        if let Some(window) = body.get(field).filter(|v| !v.is_null()) {
            older.push(json!({
                "percent": window.get("utilization").cloned().unwrap_or(Value::Null),
                "resets_at": window.get("resets_at").cloned().unwrap_or(Value::Null),
                "scope": {"model": {"display_name": name}},
            }));
        }
    }
    let scoped: Vec<Value> = if live.is_empty() {
        older
    } else {
        live.into_iter().cloned().collect()
    };
    let most = scoped
        .iter()
        .max_by(|a, b| {
            let p = |v: &Value| v.get("percent").and_then(Value::as_f64).unwrap_or(0.0);
            p(a).total_cmp(&p(b))
        })
        .cloned();
    let credit = body
        .get("iguana_necktie")
        .filter(|c| c.is_object())
        .map(|c| {
            json!({
                "unit": "usd",
                "limit_dollars": number(c.get("limit_dollars")),
                "used_dollars": number(c.get("used_dollars")),
                "remaining_dollars": number(c.get("remaining_dollars")),
                "resets_at": string(c.get("resets_at")),
                "locked_reason": c.get("locked_reason").cloned().unwrap_or(Value::Null),
            })
        })
        .unwrap_or(Value::Null);
    let session = body.get("five_hour").filter(|v| !v.is_null());
    let present: Vec<Option<&Value>> = weekly
        .into_iter()
        .chain(session)
        .map(|w| w.get("utilization"))
        .chain(scoped.iter().map(|s| s.get("percent")))
        .collect();
    let unread = present.iter().any(|p| pct(*p, rounding, round).is_none());
    let read = |v: Option<&Value>| {
        if unread {
            None
        } else {
            pct(v, rounding, round)
        }
    };
    let label = |scope: &Value| string(scope.pointer("/scope/model/display_name"));
    json!({
        "weekly_pct": f64_value(weekly.and_then(|w| read(w.get("utilization")))),
        "model_pct": f64_value(most.as_ref().and_then(|m| read(m.get("percent")))),
        "model_label": most.as_ref().map_or(Value::Null, |m| {
            let name = label(m);
            if name.is_null() { Value::from("weekly (model)") } else { name }
        }),
        "model_buckets": scoped.iter().map(|s| json!({
            "label": label(s),
            "pct": f64_value(read(s.get("percent"))),
            "resets_at": s.get("resets_at").cloned().unwrap_or(Value::Null),
        })).collect::<Vec<Value>>(),
        "credits": credit,
        "session_5h_pct": f64_value(session.and_then(|w| read(w.get("utilization")))),
        "resets": {
            "weekly": weekly.map_or(Value::Null, |w| w.get("resets_at").cloned().unwrap_or(Value::Null)),
            "model": most.as_ref().map_or(Value::Null, |m| m.get("resets_at").cloned().unwrap_or(Value::Null)),
            "session": session.map_or(Value::Null, |w| w.get("resets_at").cloned().unwrap_or(Value::Null)),
        },
    })
}

/// Codex: the primary and secondary windows do not map to a window by
/// position (a weekly-only account reports its 7-day limit as the primary
/// window), so each is routed by its own `limit_window_seconds`: one longer
/// than 150 percent of five hours, or unstated, is the weekly window; a
/// shorter one is the 5-hour window, kept as Claude's is. A window present
/// whose figure does not read leaves the other unread too. `credits`
/// is the balance spent past the plan windows with the body's
/// `spend_control.reached` beside it; a flag or balance that does not
/// parse is null, which the credit rule never reads as room. The
/// [Codex rate-limit protocol] treats absent and null spend controls as unavailable.
///
/// [Codex rate-limit protocol]: https://github.com/openai/codex/blob/b392250f487949a79931ef4f7871bfdacc19c6e9/codex-rs/app-server-protocol/src/protocol/v2/account.rs#L809
pub fn parse_codex(body: &Value, rounding: Rounding) -> Value {
    let round = |p: f64| p.floor();
    let flag = |v: Option<&Value>| v.and_then(Value::as_bool).map_or(Value::Null, Value::from);
    let spent = body
        .get("spend_control")
        .filter(|s| s.is_object())
        .map(|s| flag(s.get("reached")))
        .unwrap_or(Value::Null);
    let credits = body
        .get("credits")
        .filter(|c| c.is_object())
        .map(|c| {
            json!({
                "unit": "credits",
                "unlimited": flag(c.get("unlimited")),
                "has_credits": flag(c.get("has_credits")),
                "overage_limit_reached": flag(c.get("overage_limit_reached")),
                "balance": match c.get("balance") {
                    Some(Value::Number(n)) => Value::from(n.as_f64().unwrap_or(0.0)),
                    Some(Value::String(s)) => s.trim().parse::<f64>().map_or(Value::Null, Value::from),
                    None | Some(_) => Value::Null,
                },
                "spend_control_reached": spent,
            })
        })
        .unwrap_or(Value::Null);
    struct Window {
        pct: Option<f64>,
        resets_at: Value,
        window_s: u64,
    }
    let bound = FIVE_HOURS_S * 3 / 2;
    let windows: Vec<Window> = ["primary_window", "secondary_window"]
        .iter()
        .filter_map(|key| body.pointer(&format!("/rate_limit/{key}")))
        .filter(|w| !w.is_null())
        .map(|w| Window {
            pct: pct(w.get("used_percent"), rounding, round),
            resets_at: w
                .get("reset_at")
                .and_then(Value::as_f64)
                .map_or(Value::Null, |s| {
                    Value::from(crate::clock::iso_utc(s as u64))
                }),
            window_s: w
                .get("limit_window_seconds")
                .and_then(Value::as_f64)
                .unwrap_or(0.0)
                .max(0.0) as u64,
        })
        .collect();
    let long = windows
        .iter()
        .find(|w| w.window_s == 0 || w.window_s > bound);
    let session = windows
        .iter()
        .find(|w| w.window_s != 0 && w.window_s <= bound);
    let unread = long.into_iter().chain(session).any(|w| w.pct.is_none());
    let read = |w: Option<&Window>| w.and_then(|w| w.pct).filter(|_| !unread);
    json!({
        "weekly_pct": f64_value(read(long)),
        "model_pct": Value::Null,
        "model_label": Value::Null,
        "credits": credits,
        "session_5h_pct": f64_value(read(session)),
        "resets": {
            "weekly": long.map_or(Value::Null, |w| w.resets_at.clone()),
            "model": Value::Null,
            "session": session.map_or(Value::Null, |w| w.resets_at.clone()),
        },
    })
}

/// Copilot: the monthly pool from `quota_snapshots.premium_interactions`,
/// the used count being the grant less `remaining` (the endpoint's own
/// `credits_used` is not the pool github.com shows), the share used
/// rounded up so a pool one credit short of its grant never reads as
/// having more, 100 at or past the grant whatever overage the account
/// permits, 0 where more remains than was granted. A boolean `unlimited`
/// with a positive entitlement is a pool at 0 percent used; without that
/// entitlement it is spent. An answer lacking `remaining` or `entitlement`
/// as numbers, or with an entitlement of zero, measures nothing unless it
/// says unlimited.
pub fn parse_copilot(body: &Value) -> Value {
    let q = body
        .pointer("/quota_snapshots/premium_interactions")
        .filter(|q| q.is_object())
        .cloned()
        .unwrap_or_else(|| Value::Object(Map::new()));
    let remaining = q.get("remaining").and_then(Value::as_f64);
    let granted = q.get("entitlement").and_then(Value::as_f64);
    let unlimited_flag = q.get("unlimited") == Some(&Value::Bool(true));
    let unlimited = unlimited_flag && granted.is_some_and(|g| g > 0.0);
    let counted = remaining.is_some() && granted.is_some_and(|g| g > 0.0);
    let pct = if unlimited {
        Some(0.0)
    } else if unlimited_flag {
        Some(100.0)
    } else if !counted {
        None
    } else {
        let (r, g) = (remaining.unwrap_or(0.0), granted.unwrap_or(1.0));
        Some(if r <= 0.0 {
            100.0
        } else {
            ((g - r) * 100.0 / g).ceil().max(0.0)
        })
    };
    let reset = body
        .get("quota_reset_date_utc")
        .and_then(Value::as_str)
        .and_then(|d| {
            let date = d.len() == 10 && d.as_bytes()[4] == b'-' && d.as_bytes()[7] == b'-';
            if date
                && d.bytes()
                    .enumerate()
                    .all(|(i, b)| matches!(i, 4 | 7) || b.is_ascii_digit())
            {
                Some(format!("{d}T00:00:00Z"))
            } else if d.len() > 10
                && d.as_bytes()[10] == b'T'
                && d[..10]
                    .bytes()
                    .enumerate()
                    .all(|(i, b)| matches!(i, 4 | 7) || b.is_ascii_digit())
            {
                Some(d.to_owned())
            } else {
                None
            }
        });
    let credits = if unlimited {
        json!({"unit": "AIC", "unlimited": true})
    } else if counted {
        let (r, g) = (remaining.unwrap_or(0.0), granted.unwrap_or(0.0));
        json!({
            "unit": "AIC", "unlimited": false,
            "used": g - r, "granted": g, "remaining": r,
            "over": number(q.get("overage_count")),
            "overage_permitted": q.get("overage_permitted") == Some(&Value::Bool(true)),
            "token_based_billing": q.get("token_based_billing").and_then(Value::as_bool).map_or(Value::Null, Value::from),
        })
    } else {
        Value::Null
    };
    json!({
        "monthly_pct": f64_value(pct),
        "credits_used": number(q.get("credits_used")),
        "unlimited": unlimited,
        "credits": credits,
        "plan": string(body.get("copilot_plan")),
        "resets": {"monthly": if pct.is_none() { Value::Null } else { reset.map_or(Value::Null, Value::from) }},
    })
}

pub fn parse_body(harness: Harness, body: &Value, rounding: Rounding) -> Value {
    match harness {
        Harness::Claude => parse_claude(body, rounding),
        Harness::Copilot | Harness::Pi => parse_copilot(body),
        Harness::Codex => parse_codex(body, rounding),
    }
}

pub(super) fn claude_limit_resets(body: &Value, now: u64) -> Vec<super::LimitReset> {
    use super::{LimitReset, LimitResetKind};

    let program = &body["cedar_ember"];
    if program["eligible"].as_bool() != Some(true) {
        return Vec::new();
    }
    program["grants"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|grant| {
            let left = grant["resets_left"].as_u64()?;
            let end = crate::clock::epoch_secs(&utc_stamp(grant["ends_at"].as_str()?))?;
            if left == 0 || end <= now {
                return None;
            }
            let kind = match grant["gives_back_weekly"].as_bool()? {
                true => LimitResetKind::Fable,
                false => LimitResetKind::Full,
            };
            Some(LimitReset {
                kind: Some(kind),
                left,
            })
        })
        .collect()
}

/// One spelling for every reset a record carries: whole-second UTC with a
/// `Z`. The Claude endpoint writes fractional seconds and `+00:00`, and a
/// provider row carries whatever its timestamp is; a reader comparing two
/// stamps needs one form.
pub fn utc_stamp(stamp: &str) -> String {
    let mut text = stamp.to_owned();
    if let Some(dot) = text.find('.') {
        let end = text[dot + 1..]
            .find(|c: char| !c.is_ascii_digit())
            .map_or(text.len(), |i| dot + 1 + i);
        text.replace_range(dot..end, "");
    }
    if let Some(stripped) = text.strip_suffix("+00:00") {
        text = format!("{stripped}Z");
    }
    text
}

pub fn utc_resets(buckets: &mut Value) {
    if let Some(resets) = buckets.get_mut("resets").and_then(Value::as_object_mut) {
        for value in resets.values_mut() {
            if let Some(s) = value.as_str() {
                *value = Value::from(utc_stamp(s));
            }
        }
    }
    if let Some(scoped) = buckets
        .get_mut("model_buckets")
        .and_then(Value::as_array_mut)
    {
        for bucket in scoped.iter_mut() {
            if let Some(reset) = bucket.get_mut("resets_at")
                && let Some(s) = reset.as_str()
            {
                *reset = Value::from(utc_stamp(s));
            }
        }
    }
    if let Some(reset) = buckets.pointer_mut("/credits/resets_at")
        && let Some(s) = reset.as_str()
    {
        *reset = Value::from(utc_stamp(s));
    }
}

/// The largest rise two whole-percent readings show for a spend of a
/// hundredth of a point (40.49 then 40.50 read 40 then 41): such a rise
/// measures no burn, so the set burn stands and the usage record keeps its
/// older reading as the rate's anchor until the rise from it passes this.
pub(super) const ROUNDING_STEP: f64 = 1.0;

/// Whether two reset stamps name one window: both present, and parsed to
/// epochs no more than five minutes apart (a stamp read either side of a
/// second boundary is still the same reset), else equal as text.
pub(super) fn same_reset(a: &Value, b: &Value) -> bool {
    let (Some(a), Some(b)) = (a.as_str(), b.as_str()) else {
        return false;
    };
    match (crate::clock::epoch_secs(a), crate::clock::epoch_secs(b)) {
        (Some(x), Some(y)) => x.abs_diff(y) <= 300,
        (_, _) => a == b,
    }
}

// --- the stored logins ----------------------------------------------------------------------

/// The credential file of a Claude or Codex account as the listing reads
/// it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Credential {
    /// No file at the path.
    Missing(String),
    /// A file that is not JSON.
    Invalid(String),
    /// A file holding no access token (and no API key).
    NoToken { path: String, plan: String },
    Token {
        token: String,
        /// The access token's expiry in milliseconds since the epoch, 0
        /// where the file states none.
        expires_ms: u64,
        /// The refresh login's expiry, 0 where the file states none (Claude).
        refresh_expires_ms: u64,
        plan: String,
        /// The ChatGPT account id (Codex), sent as a header where present.
        account_id: String,
    },
}

pub fn credential_path(harness: Harness, dir: &str) -> String {
    match harness {
        Harness::Claude => format!("{dir}/.credentials.json"),
        Harness::Copilot => format!("{dir}/config.json"),
        Harness::Codex | Harness::Pi => format!("{dir}/auth.json"),
    }
}

fn ms(v: Option<&Value>) -> u64 {
    match v {
        Some(Value::Number(n)) => n.as_f64().map_or(0, |f| f.max(0.0) as u64),
        Some(Value::String(s)) => s
            .split('.')
            .next()
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(0),
        None | Some(_) => 0,
    }
}

/// The access token and expiry a Claude `.credentials.json` or a Codex
/// `auth.json` holds. A Claude file states the expiry as `expiresAt`; a
/// Codex file states none, so it is the `exp` claim of the access token
/// itself, a JWT, 0 where the file holds no such token (an API key, or a
/// token no claim reads out of).
pub fn credential(harness: Harness, dir: &str) -> Credential {
    let path = credential_path(harness, dir);
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Credential::Missing(path),
        Err(_) => return Credential::Invalid(path),
    };
    let Ok(file) = serde_json::from_str::<Value>(&text) else {
        return Credential::Invalid(path);
    };
    if !file.is_object() {
        return Credential::Invalid(path);
    }
    let text_of = |v: Option<&Value>| v.and_then(Value::as_str).unwrap_or("").to_owned();
    let (token, expires_ms, refresh_expires_ms, plan, account_id) = if harness == Harness::Claude {
        let oauth = file.get("claudeAiOauth");
        (
            text_of(oauth.and_then(|o| o.get("accessToken"))),
            ms(oauth.and_then(|o| o.get("expiresAt"))),
            ms(oauth.and_then(|o| o.get("refreshTokenExpiresAt"))),
            text_of(oauth.and_then(|o| o.get("subscriptionType"))),
            String::new(),
        )
    } else {
        let tokens = file.get("tokens");
        let access = text_of(tokens.and_then(|t| t.get("access_token")));
        let token = if access.is_empty() {
            text_of(file.get("OPENAI_API_KEY"))
        } else {
            access.clone()
        };
        (
            token,
            jwt_exp_ms(&access),
            0,
            String::new(),
            text_of(tokens.and_then(|t| t.get("account_id"))),
        )
    };
    if token.is_empty() {
        return Credential::NoToken { path, plan };
    }
    Credential::Token {
        token,
        expires_ms,
        refresh_expires_ms,
        plan,
        account_id,
    }
}

/// Whether an expiry in milliseconds since the epoch has passed at `now`
/// seconds. A zero stamp is not expired: the file states no expiry, and
/// refusing on it would disable a lane that works.
pub fn expired(expires_ms: u64, now: u64) -> bool {
    expires_ms > 0 && expires_ms <= now * 1000
}

/// The stored login of a home on this machine ([`stored_login`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoredLogin {
    /// The home holds a credential whose login has not expired.
    Held,
    /// The home holds nothing the harness signs in with.
    Missing { cause: &'static str },
    /// Nothing here reads this harness's stored login.
    Unjudged { cause: &'static str },
}

/// The stored login of `harness` under `dir` at `now`: the credential file
/// the listing reads, Claude's on Linux alone, since another platform keeps
/// it in its own store; Copilot's and Pi's are read by nothing here.
pub fn stored_login(harness: Harness, dir: &str, now: u64) -> StoredLogin {
    if matches!(harness, Harness::Copilot | Harness::Pi) {
        return StoredLogin::Unjudged {
            cause: "harness-unread",
        };
    }
    if harness == Harness::Claude && !cfg!(target_os = "linux") {
        return StoredLogin::Unjudged {
            cause: "platform-store",
        };
    }
    match credential(harness, dir) {
        Credential::Missing(_) => StoredLogin::Missing {
            cause: "no-credential",
        },
        Credential::NoToken { .. } => StoredLogin::Missing { cause: "no-token" },
        Credential::Invalid(_) => StoredLogin::Unjudged {
            cause: "credential-invalid",
        },
        Credential::Token {
            refresh_expires_ms, ..
        } if expired(refresh_expires_ms, now) => StoredLogin::Missing {
            cause: "login-expired",
        },
        Credential::Token { .. } => StoredLogin::Held,
    }
}

/// The token files `AGENT_RUNTIME_ACCOUNT_TOKEN_FILES` declares, each home
/// in its one spelling ([`canon`]), checked whole once so a lookup cannot
/// fail.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TokenFiles(Vec<(String, PathBuf)>);

impl TokenFiles {
    /// No declaration: the set a caller whose billed harness is not Claude
    /// reads with, so a malformed setting refuses no other harness.
    pub fn none() -> TokenFiles {
        TokenFiles(Vec::new())
    }

    /// The file declared for the home `dir`.
    pub fn declared(&self, dir: &str) -> Option<&Path> {
        let dir = canon(dir);
        self.0
            .iter()
            .find(|(declared, _)| *declared == dir)
            .map(|(_, file)| file.as_path())
    }
}

/// The declared pairs as a lookup, or `setting-invalid`: a value outside
/// the key's form, or two pairs naming one home in two spellings, since
/// either file could then be its.
pub fn token_files(
    setting: &settings::Judged<Vec<(String, PathBuf)>>,
) -> crate::error::Result<TokenFiles> {
    let pairs = setting.get()?;
    let mut files: Vec<(String, PathBuf)> = Vec::new();
    for (i, (dir, file)) in pairs.iter().enumerate() {
        let home = canon(dir);
        if let Some(j) = files.iter().position(|(seen, _)| *seen == home) {
            return Err(settings::value_refusal(
                settings::ACCOUNT_TOKEN_FILES_KEY,
                &[&pairs[j], &pairs[i]]
                    .iter()
                    .map(|(dir, file)| format!("{dir}={}", file.display()))
                    .collect::<Vec<_>>()
                    .join(","),
            ));
        }
        files.push((home, file.clone()));
    }
    Ok(TokenFiles(files))
}

/// The sign-in a session opened here on a home starts with, the one answer
/// the walk, the roster, the keep and a controller's transfer read. An
/// environment token never counts: a named Claude home's launch clears the
/// inherited ones, and the walk and the roster read no window's
/// environment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SignIn {
    /// The home's stored login is held.
    StoredLogin,
    /// The home's declared token file holds a token, which its launch
    /// exports.
    TokenFile(PathBuf),
    /// The home holds nothing the harness signs in with.
    Missing { cause: &'static str },
    /// Nothing here reads this sign-in: the first turn alone judges it.
    Unjudged { cause: &'static str },
}

/// The sign-in of the home `dir` for a session billing `billed`, at `now`:
/// a Claude home with a declared token file is judged by that file alone,
/// since its launch exports the file's text over its stored login, so no
/// other source stands in for a file that is wrong; any other home by its
/// stored login ([`stored_login`]).
pub fn sign_in(billed: Harness, dir: &str, files: &TokenFiles, now: u64) -> SignIn {
    if billed == Harness::Claude
        && let Some(file) = files.declared(dir)
    {
        return declared_token(file);
    }
    match stored_login(billed, dir, now) {
        StoredLogin::Held => SignIn::StoredLogin,
        StoredLogin::Missing { cause } => SignIn::Missing { cause },
        StoredLogin::Unjudged { cause } => SignIn::Unjudged { cause },
    }
}

impl SignIn {
    /// How a launch on the home `dir` this answer judged signs in, the one
    /// projection a successor, a local lane and `agent-runtime launch` read:
    /// a held token file is exported, and a held stored login, or one
    /// nothing here reads, which the first turn judges, is the launch's own
    /// once the inherited credentials are cleared. A home holding nothing
    /// refuses `successor-not-signed-in` before any window opens, with the
    /// home, the cause and the file `files` declares for it; a Codex home's
    /// launch reads that refusal alone.
    pub fn launch(self, dir: &str, files: &TokenFiles) -> crate::error::Result<ClaudeSignIn> {
        match self {
            SignIn::StoredLogin | SignIn::Unjudged { .. } => Ok(ClaudeSignIn::StoredLogin),
            SignIn::TokenFile(file) => Ok(ClaudeSignIn::TokenFile(file)),
            SignIn::Missing { cause } => {
                let file = files.declared(dir).map(|f| f.display().to_string());
                let mut fields = vec![("account", dir), ("cause", cause)];
                if let Some(file) = &file {
                    fields.push(("file", file));
                }
                Err(crate::error::Error::refused(
                    "successor-not-signed-in",
                    &fields,
                ))
            }
        }
    }
}

/// The sign-in a declared token file gives: held where its text less
/// trailing newlines, as the launch's `$(cat FILE)` takes it, is
/// non-empty.
fn declared_token(file: &Path) -> SignIn {
    let absent = SignIn::Missing {
        cause: "declared-token-absent",
    };
    match std::fs::read(file) {
        Ok(text) if text.iter().any(|b| *b != b'\n') => SignIn::TokenFile(file.to_path_buf()),
        Ok(_) => absent,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => absent,
        Err(_) => SignIn::Missing {
            cause: "declared-token-unreadable",
        },
    }
}

/// The `exp` claim of a JWT access token in milliseconds, 0 where the
/// token is no JWT or carries none. The segments are unpadded base64url.
pub fn jwt_exp_ms(token: &str) -> u64 {
    let Some(payload) = token.split('.').nth(1) else {
        return 0;
    };
    let Some(bytes) = base64url(payload) else {
        return 0;
    };
    serde_json::from_slice::<Value>(&bytes)
        .ok()
        .and_then(|claims| claims.get("exp").and_then(Value::as_f64))
        .map_or(0, |exp| (exp.floor() * 1000.0) as u64)
}

fn base64url(text: &str) -> Option<Vec<u8>> {
    let mut bits: u32 = 0;
    let mut have = 0;
    let mut out = Vec::new();
    for byte in text.bytes() {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'-' | b'+' => 62,
            b'_' | b'/' => 63,
            b'=' => break,
            _ => return None,
        };
        bits = (bits << 6) | u32::from(value);
        have += 6;
        if have >= 8 {
            have -= 8;
            out.push(((bits >> have) & 0xff) as u8);
        }
    }
    Some(out)
}

/// A Copilot account's stored login as Copilot CLI's `config.json` or a Pi
/// root's `auth.json` names it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CopilotLogin {
    /// The GitHub.com token itself.
    Token(String),
    /// The GitHub.com login `lastLoggedInUser` names, whose token the
    /// Secret Service holds.
    Keyring(String),
    /// No login read: the keyed reason and where it was sought.
    Unread { reason: &'static str, place: String },
}

/// The login `config.json` under `dir` names: the file is JSON after any
/// leading `//` comment lines; `copilotTokens` holds the token as a string
/// or as an object keyed `<host>:<login>` whose one GitHub.com entry is
/// the token (a token another host issued is never sent to GitHub.com);
/// with none, `lastLoggedInUser`'s GitHub.com login names the keyring
/// item.
pub fn copilot_login(dir: &str) -> CopilotLogin {
    let path = credential_path(Harness::Copilot, dir);
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return CopilotLogin::Unread {
                reason: "config-missing",
                place: path,
            };
        }
        Err(_) => {
            return CopilotLogin::Unread {
                reason: "config-unreadable",
                place: path,
            };
        }
    };
    let json: String = text
        .lines()
        .filter(|l| !l.trim_start().starts_with("//"))
        .collect::<Vec<&str>>()
        .join("\n");
    let Ok(file) = serde_json::from_str::<Value>(&json) else {
        return CopilotLogin::Unread {
            reason: "config-unreadable",
            place: path,
        };
    };
    let tokens = file
        .get("copilotTokens")
        .filter(|t| !t.is_null())
        .or_else(|| file.get("copilot_tokens"));
    let login = file
        .get("lastLoggedInUser")
        .filter(|u| u.is_object())
        .filter(|u| u.get("host").and_then(Value::as_str) == Some("https://github.com"))
        .and_then(|u| u.get("login").and_then(Value::as_str))
        .filter(|l| !l.is_empty())
        .map(str::to_owned);
    let missing = || match login {
        Some(login) => CopilotLogin::Keyring(login),
        None => CopilotLogin::Unread {
            reason: "token-missing",
            place: path.clone(),
        },
    };
    match tokens {
        Some(Value::String(token)) => CopilotLogin::Token(token.clone()),
        Some(Value::Object(map)) => {
            let strings: Vec<(&String, &str)> = map
                .iter()
                .filter_map(|(k, v)| v.as_str().map(|s| (k, s)))
                .collect();
            let github: Vec<&str> = strings
                .iter()
                .filter(|(k, _)| k.starts_with("https://github.com:"))
                .map(|(_, v)| *v)
                .collect();
            match github.len() {
                1 => CopilotLogin::Token(github[0].to_owned()),
                n if n > 1 => CopilotLogin::Unread {
                    reason: "token-ambiguous",
                    place: path,
                },
                _ if !strings.is_empty() => CopilotLogin::Unread {
                    reason: "token-foreign-host",
                    place: path,
                },
                _ => missing(),
            }
        }
        None | Some(_) => missing(),
    }
}

/// The Copilot login a Pi root keeps: `auth.json`'s `github-copilot` OAuth
/// entry, whose `refresh` is the GitHub token Pi's device login brought
/// back; its `access` is the Copilot session token Pi derives from it,
/// which the user endpoint does not take. An entry naming an
/// `enterpriseUrl` holds another host's token, never sent to GitHub.com.
pub fn pi_copilot_login(dir: &str) -> CopilotLogin {
    let path = credential_path(Harness::Pi, dir);
    let unread = |reason: &'static str, place: &str| CopilotLogin::Unread {
        reason,
        place: place.to_owned(),
    };
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return unread("auth-missing", &path);
        }
        Err(_) => return unread("auth-unreadable", &path),
    };
    let Ok(file) = serde_json::from_str::<Value>(&text) else {
        return unread("auth-unreadable", &path);
    };
    let Some(entry) = file
        .get("github-copilot")
        .filter(|e| e.get("type").and_then(Value::as_str) == Some("oauth"))
    else {
        return unread("token-missing", &path);
    };
    if entry
        .get("enterpriseUrl")
        .and_then(Value::as_str)
        .is_some_and(|host| !host.is_empty())
    {
        return unread("token-foreign-host", &path);
    }
    match entry
        .get("refresh")
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty())
    {
        Some(token) => CopilotLogin::Token(token.to_owned()),
        None => unread("token-missing", &path),
    }
}

/// The account `dir` names: a Codex launch under a private home built
/// under an account sets `CODEX_HOME` to `<account>/lane-launch/<id>/home`,
/// and that home is a place to read a config from, never another account.
pub fn home_account(path: &str) -> String {
    match path.find("/lane-launch/") {
        Some(at) if path.ends_with("/home") => path[..at].to_owned(),
        Some(_) | None => path.to_owned(),
    }
}

/// Whether `dir` is a directory, read three-valued: an unreadable path is
/// its own cause, never absent.
pub fn is_dir(dir: &Path) -> Result<bool, String> {
    match std::fs::metadata(dir) {
        Ok(meta) => Ok(meta.is_dir()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(format!("{}: {e}", dir.display())),
    }
}

pub fn exists(path: &Path) -> Result<bool, String> {
    match std::fs::metadata(path) {
        Ok(_) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A declared token file signs a session in only where the launch's
    /// `$(cat FILE)` would export a non-empty token: an empty or
    /// newline-only file and an absent one hold none, and a path that does
    /// not read as a file is unreadable, never held.
    #[test]
    fn a_declared_token_file_is_held_only_where_its_text_exports_a_token() {
        let dir = tempfile::tempdir().unwrap();
        let path = |name: &str| dir.path().join(name);
        std::fs::write(path("planted"), "planted\n").unwrap();
        std::fs::write(path("empty"), "").unwrap();
        std::fs::write(path("newlines"), "\n\n").unwrap();
        std::fs::create_dir(path("directory")).unwrap();
        let absent = SignIn::Missing {
            cause: "declared-token-absent",
        };
        let rows = [
            ("planted", SignIn::TokenFile(path("planted"))),
            ("empty", absent.clone()),
            ("newlines", absent.clone()),
            ("absent", absent),
            (
                "directory",
                SignIn::Missing {
                    cause: "declared-token-unreadable",
                },
            ),
        ];
        for (name, expected) in rows {
            assert_eq!(declared_token(&path(name)), expected, "{name}");
        }
    }

    #[test]
    fn the_capture_is_split_at_the_last_header_block_with_its_own_retry_after() {
        let got = answer(
            "HTTP/1.1 100 Continue\r\nRetry-After: 900\r\n\r\nHTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\n\r\n{\"error\":1}\n429",
        );
        assert_eq!(
            got,
            Answer {
                code: Some(429),
                retry_after: None,
                body: "{\"error\":1}".to_owned()
            }
        );
        let got = answer("HTTP/1.1 429 X\r\nRetry-After: 900\r\n\r\n{}\n429");
        assert_eq!(got.retry_after.as_deref(), Some("900"));
        assert_eq!(answer("garbage").code, None);
    }

    #[test]
    fn an_unreadable_window_unmeasures_the_reading_and_the_five_hour_window_is_kept_beside_the_week()
     {
        let body = json!({"seven_day": {"utilization": 20},
            "limits": [{"kind": "weekly_scoped", "percent": "30", "scope": {"model": {"display_name": "Opus"}}}]});
        let got = parse_claude(&body, Rounding::Rounded);
        assert_eq!(got["weekly_pct"], Value::Null);
        assert_eq!(got["model_buckets"][0]["pct"], Value::Null);
        let reset = "2027-01-15T05:00:00Z";
        let epoch = crate::clock::epoch_secs(reset).unwrap();
        // (case, Claude's `five_hour`, Codex's short window, the week, the
        // 5-hour figure, the 5-hour reset)
        let rows = [
            (
                "absent",
                Value::Null,
                Value::Null,
                json!(30.0),
                Value::Null,
                Value::Null,
            ),
            (
                "read",
                json!({"utilization": 98.4, "resets_at": reset}),
                json!({"used_percent": 98.4, "reset_at": epoch, "limit_window_seconds": 18_000}),
                json!(30.0),
                json!(98.0),
                json!(reset),
            ),
            (
                "unreadable",
                json!({"utilization": "12", "resets_at": reset}),
                json!({"used_percent": -1, "reset_at": epoch, "limit_window_seconds": 18_000}),
                Value::Null,
                Value::Null,
                json!(reset),
            ),
        ];
        for (case, claude, codex, week, session, session_reset) in rows {
            let claude = parse_claude(
                &json!({"five_hour": claude, "seven_day": {"utilization": 30}}),
                Rounding::Rounded,
            );
            let codex = parse_codex(
                &json!({"rate_limit": {"primary_window": codex,
                    "secondary_window": {"used_percent": 30, "limit_window_seconds": 604_800}}}),
                Rounding::Rounded,
            );
            for (harness, got) in [("claude", &claude), ("codex", &codex)] {
                assert_eq!(
                    (
                        &got["weekly_pct"],
                        &got["session_5h_pct"],
                        &got["resets"]["session"]
                    ),
                    (&week, &session, &session_reset),
                    "{case} {harness}: {got}"
                );
            }
        }
        let short = json!({"rate_limit": {"primary_window": {"used_percent": 30, "limit_window_seconds": 18_000}, "secondary_window": null}});
        assert_eq!(
            parse_codex(&short, Rounding::Rounded)["weekly_pct"],
            Value::Null
        );
    }

    #[test]
    fn the_copilot_pool_rounds_its_share_up_and_reads_only_a_boolean_unlimited() {
        let pool = |e: i64, r: i64| json!({"quota_snapshots": {"premium_interactions": {"entitlement": e, "remaining": r}}, "quota_reset_date_utc": "2099-10-01"});
        assert_eq!(
            parse_copilot(&pool(1_000_000, 1))["monthly_pct"],
            json!(100.0)
        );
        assert_eq!(
            parse_copilot(&pool(1000, -500))["monthly_pct"],
            json!(100.0)
        );
        assert_eq!(parse_copilot(&pool(1000, 1200))["monthly_pct"], json!(0.0));
        assert_eq!(
            parse_copilot(&pool(1_000_000, 900_000))["monthly_pct"],
            json!(10.0)
        );
        assert_eq!(
            parse_copilot(&pool(1_000_000, 900_000))["resets"]["monthly"],
            json!("2099-10-01T00:00:00Z")
        );
        let loose = json!({"quota_snapshots": {"premium_interactions": {"unlimited": "true"}}});
        assert_eq!(parse_copilot(&loose)["monthly_pct"], Value::Null);
        let zero = json!({"quota_snapshots": {"premium_interactions": {"unlimited": true, "entitlement": 0}}});
        assert_eq!(parse_copilot(&zero)["monthly_pct"], json!(100.0));
    }

    #[test]
    fn a_codex_tokens_expiry_is_its_exp_claim() {
        // {"exp":1700000000,"pad":"?????~~~~~"} in base64url, unpadded.
        let token = [
            "eyJhbGciOiJSUzI1NiJ9",
            "eyJleHAiOjE3MDAwMDAwMDAsInBhZCI6Ij8_Pz8_fn5-fn4ifQ",
            "sig",
        ]
        .join(".");
        let token = token.as_str();
        assert_eq!(jwt_exp_ms(token), 1_700_000_000_000);
        assert_eq!(jwt_exp_ms("sk-not-a-jwt"), 0);
        assert!(expired(1_700_000_000_000, 1_700_000_000));
        assert!(!expired(0, 1_700_000_000));
    }

    #[test]
    fn stamps_take_one_spelling() {
        assert_eq!(
            utc_stamp("2026-10-01T05:00:00.123456+00:00"),
            "2026-10-01T05:00:00Z"
        );
        assert_eq!(utc_stamp("2026-10-01T05:00:00Z"), "2026-10-01T05:00:00Z");
        assert_eq!(home_account("/h/.codex/lane-launch/x/home"), "/h/.codex");
        assert_eq!(home_account("/h/.codex"), "/h/.codex");
    }
}
