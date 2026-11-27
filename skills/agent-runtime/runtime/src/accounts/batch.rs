//! Measurements someone else took, in the two forms a provider's `accounts`
//! answer takes. The first is one tab-separated `key=value` line per
//! account. Its one parser reads a provider's answer for orch's listing and
//! a supplied batch for `accounts judge`; each line's row is finished as the
//! listing finishes its own, and a batch's rows are judged as a named pick
//! judges one account. The second, the `accounts --json --headroom`
//! document, is read for its `meters.limit_resets` alone
//! ([`super::Roster::carry_limit_resets`]).
//!
//! A Codex row carries the facts of its credit as OpenAI's answer states
//! them, never a verdict: the balance and whether credit exists, whether the
//! overage limit and the spend control are reached. The judge applies the
//! floor ([`super::credit_room`]).

use std::io::Read;
use std::path::Path;

use serde_json::{Map, Value, json};

use super::here::Beside;
use super::listing::{Ctx, Emit, Reading, Usage, alias, emit, finish};
use super::{AccountRow, Env, PickRequest, cache, judge_one};
use crate::clock;
use crate::error::{Error, Result};
use crate::harness::Harness;

/// The Pi API grant's facts, in dollars: all four or none.
const PI_GRANT: [&str; 4] = [
    "credit-limit",
    "credit-spent",
    "credit-remaining",
    "credit-expires",
];

/// The Codex credit's facts: the balance and the three flags the credit
/// rule reads, all four or none, each flag `1` or `0`.
const CODEX_CREDIT: [&str; 4] = [
    "credit-remaining",
    "credit-available",
    "credit-overage-limit-reached",
    "credit-spend-control-reached",
];

/// A non-negative decimal and the digits after its point.
fn decimal(text: &str) -> Option<(f64, usize)> {
    let (whole, fraction) = match text.split_once('.') {
        Some((w, f)) => (w, Some(f)),
        None => (text, None),
    };
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    if !digits(whole) || fraction.is_some_and(|f| !digits(f)) {
        return None;
    }
    Some((text.parse().ok()?, fraction.map_or(0, str::len)))
}

/// The protocol's dollar field: a non-negative decimal with at most two
/// places.
fn dollars(text: &str) -> Option<f64> {
    decimal(text)
        .filter(|(_, places)| *places <= 2)
        .map(|(n, _)| n)
}

/// A two-valued fact: `1` or `0`, nothing else.
fn fact(text: &str) -> Option<bool> {
    match text {
        "1" => Some(true),
        "0" => Some(false),
        _ => None,
    }
}

/// One line read: its fields, and its windows in the bucket shape every
/// reading takes.
struct Line {
    fields: Map<String, Value>,
    account: String,
    harness: Harness,
    buckets: Value,
    /// The line carries a Pi API grant.
    grant: bool,
    /// Seconds since the provider read the figures (`observed-age`), where
    /// the line states it.
    age: Option<u64>,
}

/// A line one field of which nobody can read: the account it names, empty
/// where it names none, the first such field, and the row of the line's
/// words alone where it names its account and harness and states a word.
#[derive(Debug, Clone, PartialEq)]
pub struct Unreadable {
    pub account: String,
    pub field: &'static str,
    pub words: Option<Value>,
}

/// The words a provider states of an account, apart from any figure, by
/// field and by the record's name. `unified-status` is Anthropic's admission
/// word (`allowed`, `allowed_warning`, `rejected`: FLT-1713); the judge
/// reads `rejected` as walled ([`super::AccountRow::rejected`]).
const PROVIDER_WORDS: [(&str, &str); 4] = [
    ("plan-ends", "plan_ends"),
    ("reserved", "reserved"),
    ("seat", "seat"),
    ("unified-status", "unified_status"),
];

/// A line's `key=value` fields; a field with no `=` holds the empty value.
fn line_fields(text: &str) -> Map<String, Value> {
    let mut fields: Map<String, Value> = Map::new();
    for field in text.split('\t').filter(|f| !f.is_empty()) {
        let (key, value) = field.split_once('=').unwrap_or((field, ""));
        fields.insert(key.to_owned(), Value::from(value));
    }
    fields
}

/// The line a provider's unreadable line still says: its account, its
/// harness and its words (`plan-ends`, `reserved`, `seat`,
/// `unified-status`), no figure. A reservation or a refusal is a fact of
/// the account, so a measurement nobody can read never takes it away. None
/// where the line names no account, no harness this parser reads, or no
/// word.
fn words_line(text: &str) -> Option<Line> {
    let fields = line_fields(text);
    let get = |key: &str| fields.get(key).and_then(Value::as_str).unwrap_or("");
    let (account, harness) = (get("account"), get("harness"));
    Harness::parse(harness)?;
    let words: Vec<String> = PROVIDER_WORDS
        .iter()
        .filter(|(key, _)| !get(key).is_empty())
        .map(|(key, _)| format!("{key}={}", get(key)))
        .collect();
    if account.is_empty() || words.is_empty() {
        return None;
    }
    line(&format!(
        "account={account}\tharness={harness}\t{}",
        words.join("\t")
    ))
    .ok()
}

/// One line: `account` and `harness` required, the percentages whole
/// numbers 0 to 100, `observed-age` a non-negative number of seconds, a
/// credit's fields together as its harness states them: the Pi grant's four
/// on a `harness=pi` row with no `monthly-pct`, the Codex credit's four on a
/// `harness=codex` row, none on any other.
///
/// A Claude line with no `session-5h-pct` whose `model-pct` carries no
/// `model-label` states its 5-hour window there, with `model-resets` its
/// reset: Fleet's line before it names the window (FLT-1876 moves it).
fn line(text: &str) -> std::result::Result<Line, Unreadable> {
    let fields = line_fields(text);
    let get = |key: &str| {
        fields
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned()
    };
    let has = |keys: &[&str]| keys.iter().any(|k| fields.contains_key(*k));
    let account = get("account");
    let harness = Harness::parse(&get("harness"));
    let mut bad: Option<&'static str> = None;
    let mut pcts: [(&'static str, Option<u64>); 4] = [
        ("weekly-pct", None),
        ("model-pct", None),
        ("monthly-pct", None),
        ("session-5h-pct", None),
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
    let age = match get("observed-age") {
        text if text.is_empty() => None,
        text => match decimal(&text) {
            // Rounded up, so a fraction never reads a figure as fresher
            // than it is.
            Some((secs, _)) => Some(secs.ceil() as u64),
            None => {
                bad = bad.or(Some("observed-age"));
                None
            }
        },
    };
    if account.is_empty() {
        bad = bad.or(Some("account"));
    }
    if harness.is_none() {
        bad = bad.or(Some("harness"));
    }
    let only = |ours: &[&str], theirs: &[&str]| {
        !theirs
            .iter()
            .any(|k| !ours.contains(k) && fields.contains_key(*k))
    };
    let credits = if !has(&PI_GRANT) && !has(&CODEX_CREDIT) {
        Value::Null
    } else if harness == Some(Harness::Pi) {
        let limit = dollars(&get("credit-limit"));
        let remaining = dollars(&get("credit-remaining"));
        let spent = dollars(&get("credit-spent"));
        if !only(&PI_GRANT, &CODEX_CREDIT)
            || fields.contains_key("monthly-pct")
            || limit.is_none_or(|l| l <= 0.0)
            || remaining.is_none()
            || clock::epoch_secs(&get("credit-expires")).is_none()
        {
            bad = bad.or(Some("credit-fields"));
        }
        if spent.is_none() {
            bad = bad.or(Some("credit-spent"));
        }
        json!({
            "unit": "usd",
            "limit_dollars": limit,
            "used_dollars": spent,
            "remaining_dollars": remaining,
            "resets_at": get("credit-expires"),
            "locked_reason": Value::Null,
        })
    } else if harness == Some(Harness::Codex) {
        let balance = decimal(&get("credit-remaining")).map(|(n, _)| n);
        let [available, overage, spend] = [
            "credit-available",
            "credit-overage-limit-reached",
            "credit-spend-control-reached",
        ]
        .map(|key| fact(&get(key)));
        if !only(&CODEX_CREDIT, &PI_GRANT)
            || balance.is_none()
            || available.is_none()
            || overage.is_none()
            || spend.is_none()
        {
            bad = bad.or(Some("credit-fields"));
        }
        json!({
            "unit": "credits",
            "has_credits": available,
            "overage_limit_reached": overage,
            "spend_control_reached": spend,
            "balance": balance,
        })
    } else {
        bad = bad.or(Some("credit-fields"));
        Value::Null
    };
    let (None, Some(harness)) = (bad, harness) else {
        return Err(Unreadable {
            account,
            field: bad.unwrap_or("harness"),
            words: None,
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
    let [weekly, model, monthly, session] = pcts.map(|(_, v)| v);
    let legacy = harness == Harness::Claude
        && session.is_none()
        && model.is_some()
        && get("model-label").is_empty();
    let (model, model_resets, session, session_resets) = if legacy {
        (None, Value::Null, model, nz("model-resets"))
    } else {
        (model, nz("model-resets"), session, nz("session-resets"))
    };
    let grant = harness == Harness::Pi && !credits.is_null();
    let buckets = json!({
        "weekly_pct": weekly,
        "model_pct": model,
        "monthly_pct": monthly,
        "session_5h_pct": session,
        "credits": credits,
        "model_label": nz("model-label"),
        "model_buckets": match model {
            None => json!([]),
            Some(pct) => json!([{"label": nz("model-label"), "pct": pct, "resets_at": model_resets}]),
        },
        "resets": {"weekly": nz("weekly-resets"), "model": model_resets,
                   "monthly": nz("monthly-resets"), "session": session_resets},
    });
    Ok(Line {
        fields,
        account,
        harness,
        buckets,
        grant,
        age,
    })
}

/// The first window of a cached answer that has reset since it was read:
/// the answer is then asked again.
pub fn consumed_reset(text: &str, now: u64) -> Option<String> {
    text.lines()
        .filter_map(|l| line(l).ok())
        .find_map(|l| cache::consumed_reset(&l.buckets, now))
}

/// Each non-empty line of `text` with its number in the text, as a record
/// measured `through` under `host_pool`'s kind, or the field that left it
/// unread: a percentage nobody can parse is never judged as room. The
/// words `plan-ends`, `reserved`, `seat` and `unified-status` are carried
/// as written where non-empty, an unread line's among them as a row of no reading; the judge
/// reads them.
fn rows(
    ctx: &Ctx,
    text: &str,
    host_pool: &str,
    through: &str,
) -> Vec<(usize, std::result::Result<Value, Unreadable>)> {
    text.lines()
        .enumerate()
        .filter(|(_, l)| !l.is_empty())
        .map(|(index, text)| {
            let read = line(text)
                .map(|read| line_row(ctx, read, host_pool, through))
                .map_err(|unreadable| Unreadable {
                    words: words_line(text).map(|read| line_row(ctx, read, host_pool, through)),
                    ..unreadable
                });
            (index + 1, read)
        })
        .collect()
}

/// One read line as a record measured `through` under `host_pool`'s kind.
fn line_row(ctx: &Ctx, read: Line, host_pool: &str, through: &str) -> Value {
    let Line {
        fields,
        account,
        harness,
        buckets,
        grant,
        age,
    } = read;
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
    for (key, name) in PROVIDER_WORDS {
        let value = get(key);
        if !value.is_empty() {
            words.insert(name.to_owned(), Value::from(value));
        }
    }
    let grant = grant || get("detail").starts_with("api-credit-");
    let pool = match harness {
        Harness::Pi if grant => "api-credit",
        Harness::Pi | Harness::Copilot => "copilot",
        Harness::Claude if host_pool == "cloud-credit" => "cloud-credit",
        Harness::Claude | Harness::Codex => "plan",
    };
    let alias = alias(ctx.accounts, &account);
    // The provider protocol's `rate_limited` is a usage read that backs
    // off, as orch's lane-host schema states; no other word names an
    // endpoint.
    let refused_endpoint = (status == "rate_limited").then_some("usage");
    let mut row = emit(
        ctx,
        &Emit {
            alias: &alias,
            harness,
            dir: &account,
            through,
            reading: Reading {
                status,
                detail: get("detail"),
                plan: String::new(),
                usage: Some(Usage::Provider(buckets)),
                age,
                prior: None,
                rated_from: None,
                // The protocol states no earlier figure, so no fall of one
                // can follow a wall's sighting; a record of this spelling
                // here is this machine's.
                fall: None,
                refused_endpoint,
            },
            words: Some(words),
        },
    );
    finish(ctx, &mut row, pool);
    row
}

/// A provider's `accounts` answer under a host of `host_pool`'s kind, as
/// the listing's rows: a line nobody can read is named in one
/// `host-account-invalid` note and left out but for its words, a row of no
/// reading the pick carries onto this machine's reading of the account.
pub fn host_rows(ctx: &mut Ctx, text: &str, host_pool: &str) -> Vec<Value> {
    let mut out = Vec::new();
    for (_, read) in rows(ctx, text, host_pool, "host") {
        match read {
            Ok(row) => out.push(row),
            Err(Unreadable {
                account,
                field,
                words,
            }) => {
                let named = if account.is_empty() {
                    "<unnamed>"
                } else {
                    account.as_str()
                };
                ctx.notes.push(format!(
                    "host-account-invalid account={named} field={field}"
                ));
                out.extend(words);
            }
        }
    }
    out
}

/// A provider's `accounts` answer read for its words alone: each line's
/// words as a row of no reading, never its figures, for a pick the
/// provider's figures do not judge.
pub fn host_words(ctx: &mut Ctx, text: &str, host_pool: &str) -> Vec<Value> {
    text.lines()
        .filter_map(words_line)
        .map(|read| line_row(ctx, read, host_pool, "host"))
        .collect()
}

/// One account's unused limit resets as a provider's `accounts --json
/// --headroom` document states them: Fleet's `meters.limit_resets`, OpenAI's
/// reset credits on a Codex account whose answer states them. The document
/// names an account by its directory's name without the dot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct LimitResets {
    pub name: String,
    pub harness: Harness,
    pub count: u64,
}

#[derive(serde::Deserialize)]
struct Headroom {
    accounts: Vec<HeadroomAccount>,
}

#[derive(serde::Deserialize)]
struct HeadroomAccount {
    name: String,
    harness: String,
    #[serde(default)]
    meters: Meters,
}

#[derive(serde::Deserialize, Default)]
struct Meters {
    limit_resets: Option<u64>,
}

/// The count of each account the document `doc` states one for. An account
/// it states none for is left out, never counted as none. The cause where
/// the document cannot be read, such as a provider's `accounts` lines
/// answered in its place.
pub(super) fn limit_resets(doc: &str) -> std::result::Result<Vec<LimitResets>, String> {
    let read: Headroom =
        serde_json::from_str(doc).map_err(|e| format!("limit-resets-unreadable cause={e}"))?;
    read.accounts
        .into_iter()
        .filter_map(|account| Some((account.meters.limit_resets?, account)))
        .map(|(count, account)| match Harness::parse(&account.harness) {
            Some(harness) => Ok(LimitResets {
                name: account.name,
                harness,
                count,
            }),
            None => Err(format!(
                "limit-resets-unreadable account={} field=harness",
                account.name
            )),
        })
        .collect()
}

/// The question a supplied batch is judged on: the named pick's bound and
/// its seat rule.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Question {
    /// The bound in percent used; the setting where unset.
    pub max_pct: Option<u32>,
    /// The headroom the caller's own judgement triggers at, the bound
    /// `100 - T`.
    pub min_headroom_pct: Option<u32>,
    /// Judge seats as ordinary accounts, and an account kept from workers
    /// (the owner's exclusion, a provider's reservation) as no refusal: the
    /// controller's own question.
    pub for_controller: bool,
}

/// The batch at `path`, `-` the standard input.
fn read_batch(path: &Path) -> Result<String> {
    let mut text = String::new();
    if path == Path::new("-") {
        std::io::stdin()
            .read_to_string(&mut text)
            .map_err(|e| Error::io("read", path, e))?;
        return Ok(text);
    }
    std::fs::read_to_string(path).map_err(|e| Error::io("read", path, e))
}

/// `accounts judge`: each line of the batch at `path` read by the one
/// parser, finished as the listing finishes a row (`measured_through`
/// `supplied`), and judged as a named pick judges an account now, no
/// candidate charged: the seats are the batch's own `seat=1` rows and this
/// machine's seat records, and the lanes are charged as every room
/// reading here counts them. One entry per line, in order; a line nobody
/// can read is its entry's `unreadable` verdict with the field, never left
/// out.
pub fn judge(
    settings: &Env,
    project: &Path,
    record: Option<&Path>,
    path: &Path,
    question: Question,
    now: u64,
) -> Result<Value> {
    let accounts = settings.accounts.get()?;
    settings.account_state.get()?;
    let text = read_batch(path)?;
    let ctx = Ctx::new(settings, &accounts, now).expect("the account state was read above");
    let read = rows(&ctx, &text, "plan", "supplied");
    let ground = Beside::read(settings, project, record)?;
    let parsed: Vec<(usize, std::result::Result<AccountRow, Unreadable>)> = read
        .into_iter()
        .map(|(number, read)| {
            let row = read.map(|raw| {
                AccountRow::parse(&raw, &accounts)
                    .expect("a row the listing finished has a status, a verdict and a harness")
            });
            (number, row)
        })
        .collect();
    let judged_rows: Vec<AccountRow> = parsed
        .iter()
        .filter_map(|(_, row)| row.as_ref().ok().cloned())
        .collect();
    let facts = ground.facts(&judged_rows);
    let entries: Vec<Value> = parsed
        .into_iter()
        .map(|(number, row)| match row {
            Ok(row) => {
                let req = PickRequest {
                    lane: Some(row.config_dir.clone()),
                    max_pct: question.max_pct,
                    min_headroom_pct: question.min_headroom_pct,
                    for_overseer: question.for_controller,
                    ..PickRequest::new(row.harness)
                };
                let judged = judge_one(&row, &req, &facts, &accounts, now);
                json!({
                    "line": number,
                    "account": row.config_dir,
                    "harness": row.harness,
                    "verdict": judged.verdict,
                    "word": row.word().text(),
                    "record": judged.record(),
                })
            }
            Err(Unreadable { account, field, .. }) => json!({
                "line": number,
                "account": if account.is_empty() { Value::Null } else { Value::from(account) },
                "verdict": "unreadable",
                "field": field,
            }),
        })
        .collect();
    Ok(json!({ "rows": entries }))
}

#[cfg(test)]
mod tests {
    use super::super::{FleetFacts, pick, wall};
    use super::*;
    use crate::settings::Judged;

    const NOW: u64 = 1_800_000_000;

    /// How a pick reads a provider's `accounts` answer: [`host_rows`], or
    /// [`host_words`] for an overseer's pick here over a remote provider.
    type Parse = fn(&mut Ctx, &str, &str) -> Vec<Value>;

    /// A provider's `accounts` answer read under a `plan` host at [`NOW`],
    /// as the pick reads it: the rows, and the notes the listing said.
    fn host(text: &str) -> (Vec<Value>, Vec<String>) {
        host_through(text, host_rows)
    }

    /// [`host`] through `parse`.
    fn host_through(text: &str, parse: Parse) -> (Vec<Value>, Vec<String>) {
        let dir = tempfile::tempdir().unwrap();
        let accounts = Judged::of("accounts", Ok(super::super::tests::settings()));
        let state = Judged::of("state", Ok(dir.path().to_path_buf()));
        let env = Env {
            accounts: &accounts,
            account_state: &state,
            home: None,
            copilot_home: None,
            controller_preference: "",
            account_tokens: &Judged::of("tokens", Ok(Vec::new())),
        };
        let read = accounts.get().unwrap();
        let mut ctx = Ctx::new(&env, &read, NOW).unwrap();
        ctx.serve_max_age = 300;
        let rows = parse(&mut ctx, text, "plan");
        (rows, ctx.notes)
    }

    /// The reset `hours` after [`NOW`].
    fn at(hours: f64) -> String {
        clock::iso_utc(NOW + (hours * 3600.0) as u64)
    }

    /// Each window, the reading age and the admission word a provider's
    /// line states, as the row carries them. Fleet's line before it names
    /// the 5-hour window states it as a `model-pct` with no label; a
    /// labelled `model-pct`, or one beside `session-5h-pct`, is a model
    /// window. Each row: the case, the line after its account and harness,
    /// then the row's 5-hour figure and reset, its model windows' figures,
    /// its reading age and its verdict, or the field that left it unread.
    #[test]
    fn a_providers_line_names_its_5_hour_window_its_reading_age_and_its_admission() {
        let (five, week) = (at(2.0), at(100.0));
        type Row<'a> = (
            &'a str,
            String,
            std::result::Result<(Value, Value, Vec<u64>, Value, &'a str), &'a str>,
        );
        let rows: Vec<Row> = vec![
            (
                "the 5-hour window under its own name",
                format!(
                    "session-5h-pct=40\tsession-resets={five}\tweekly-pct=20\tweekly-resets={week}"
                ),
                Ok((json!(40), json!(five), vec![], Value::Null, "room")),
            ),
            (
                "the 5-hour window as an unlabelled model window",
                format!("weekly-pct=20\tweekly-resets={week}\tmodel-pct=74\tmodel-resets={five}"),
                Ok((json!(74), json!(five), vec![], Value::Null, "room")),
            ),
            (
                "a labelled model window",
                format!("weekly-pct=20\tmodel-pct=60\tmodel-label=Opus\tmodel-resets={week}"),
                Ok((Value::Null, Value::Null, vec![60], Value::Null, "room")),
            ),
            (
                "an unlabelled model window beside the 5-hour window",
                format!("session-5h-pct=30\tsession-resets={five}\tweekly-pct=20\tmodel-pct=50"),
                Ok((json!(30), json!(five), vec![50], Value::Null, "room")),
            ),
            (
                "a figure read ten minutes ago",
                "weekly-pct=20\tobserved-age=600".to_owned(),
                Ok((Value::Null, Value::Null, vec![], json!(600), "room")),
            ),
            (
                "a fraction of a second rounds the age up",
                "weekly-pct=20\tobserved-age=12.5".to_owned(),
                Ok((Value::Null, Value::Null, vec![], json!(13), "room")),
            ),
            (
                "an age nobody can read",
                "weekly-pct=20\tobserved-age=10m".to_owned(),
                Err("observed-age"),
            ),
            (
                "a 5-hour figure nobody can read",
                "weekly-pct=20\tsession-5h-pct=101".to_owned(),
                Err("session-5h-pct"),
            ),
            (
                "Anthropic refusing the account's requests",
                "weekly-pct=20\tunified-status=rejected".to_owned(),
                Ok((Value::Null, Value::Null, vec![], Value::Null, "walled")),
            ),
            (
                "Anthropic warning near the limit",
                "weekly-pct=20\tunified-status=allowed_warning".to_owned(),
                Ok((Value::Null, Value::Null, vec![], Value::Null, "room")),
            ),
        ];
        let mut wrong = Vec::new();
        for (case, fields, want) in rows {
            let (read, notes) = host(&format!("account=/h/.a\tharness=claude\t{fields}\n"));
            let got = match (read.first(), notes.first()) {
                (Some(row), None) => Ok((
                    row["session_5h_pct"].clone(),
                    row["resets"]["session"].clone(),
                    row["model_buckets"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|b| b["pct"].as_u64().unwrap())
                        .collect::<Vec<u64>>(),
                    row["usage_age_s"].clone(),
                    row["verdict"].as_str().unwrap_or("").to_owned(),
                )),
                (None, Some(note)) => Err(note.clone()),
                other => panic!("{case}: {other:?}"),
            };
            let want = want
                .map(|(s, r, m, a, v)| (s, r, m, a, v.to_owned()))
                .map_err(|field| format!("host-account-invalid account=/h/.a field={field}"));
            if got != want {
                wrong.push(format!("{case}: {got:?}"));
            }
        }
        assert!(wrong.is_empty(), "{wrong:#?}");
    }

    /// One account as this machine reads it: Claude's weekly window and its
    /// model windows `buckets` measured.
    fn local(dir: &str, weekly: u64, buckets: Value) -> AccountRow {
        let raw = json!({"alias": dir, "harness": "claude", "config_dir": dir,
            "measured_through": "local", "status": "ok", "verdict": "room",
            "headroom_pct": 100 - weekly, "binding_bucket": "weekly",
            "binding_resets_at": null, "weekly_pct": weekly, "model_buckets": buckets});
        AccountRow::parse(&raw, &super::super::tests::settings()).unwrap()
    }

    /// The pick over Fleet's lines, each case a pick the KEN-5803 review
    /// replays: a launch is judged on the projected 5-hour window at five
    /// points a session hour, a worker on a named model is judged on the
    /// shared windows of a row that states no model window, a controller's
    /// question about its own account reads the 5-hour window, a figure
    /// the provider read too long ago vouches for no room, and Anthropic's
    /// refusal and a spent 5-hour window the provider states wall the
    /// account whichever reading stands, the refusal also where an
    /// overseer's pick reads the provider's words alone. Each row: the
    /// case, the provider's lines, this machine's readings beside them, the
    /// request, the lanes charged and the other controllers seated per
    /// account, then the answer and the accounts it may name.
    #[test]
    fn a_pick_over_fleets_lines_spreads_sessions_by_the_5_hour_window() {
        let settings = super::super::tests::settings();
        let tokens = Judged::of(crate::settings::ACCOUNT_TOKEN_FILES_KEY, Ok(Vec::new()));
        let per = |pairs: &[(&str, u32)]| {
            pairs
                .iter()
                .map(|(dir, n)| (wall::canon(dir), *n))
                .collect()
        };
        let worker = |model: &str, lane: Option<&str>| PickRequest {
            model: Some(model.to_owned()),
            lane: lane.map(str::to_owned),
            projected: lane.is_some(),
            ..PickRequest::new(Harness::Claude)
        };
        let overseer = |lane: Option<&str>, exclude: &[&str]| PickRequest {
            model: Some("claude-opus-5-5".to_owned()),
            lane: lane.map(str::to_owned),
            for_overseer: true,
            exclude: exclude.iter().map(|d| (*d).to_owned()).collect(),
            ..PickRequest::new(Harness::Claude)
        };
        let ninth = format!(
            "account=/h/.9claude\tharness=claude\tweekly-pct=20\tweekly-resets={}\tmodel-pct=74\tmodel-resets={}",
            at(100.0),
            at(1.0)
        );
        let second = format!(
            "account=/h/.2claude\tharness=claude\tweekly-pct=85\tweekly-resets={}\tsession-5h-pct=10\tsession-resets={}",
            at(100.0),
            at(3.0)
        );
        // Nov 25, 6:57 pm PT: 9claude's 5-hour window spent; 2claude and
        // 10claude at 45 and 27 points of weekly headroom, 140 and 64 hours
        // to their resets, two other controllers live on each.
        let replay = format!(
            "account=/h/.9claude\tharness=claude\tweekly-pct=40\tweekly-resets={}\tmodel-pct=100\tmodel-resets={}\n\
             account=/h/.2claude\tharness=claude\tweekly-pct=55\tweekly-resets={}\tsession-5h-pct=55\tsession-resets={}\n\
             account=/h/.10claude\tharness=claude\tweekly-pct=73\tweekly-resets={}\tsession-5h-pct=40\tsession-resets={}",
            at(100.0),
            at(0.7),
            at(140.0),
            at(2.0),
            at(64.0),
            at(4.0)
        );
        type Row<'a> = (
            &'a str,
            String,
            Vec<AccountRow>,
            PickRequest,
            (&'a [(&'a str, u32)], &'a [(&'a str, u32)]),
            (&'a str, &'a [&'a str]),
        );
        let rows: Vec<Row> = vec![
            (
                "a 5-hour window at 74 under 13 lanes, a new lane chosen",
                format!("{ninth}\n{second}"),
                vec![],
                worker("claude-opus-5-5", None),
                (&[("/h/.9claude", 13)], &[]),
                ("lane", &["/h/.2claude"]),
            ),
            (
                "the same account named for a new lane",
                ninth.clone(),
                vec![],
                worker("claude-opus-5-5", Some("/h/.9claude")),
                (&[("/h/.9claude", 13)], &[]),
                ("walled", &["/h/.9claude"]),
            ),
            (
                "a worker on a named model over a row that states no model window",
                format!(
                    "account=/h/.5claude\tharness=claude\tweekly-pct=30\tsession-5h-pct=20\tsession-resets={}",
                    at(2.0)
                ),
                vec![local("/h/.5claude", 40, json!([]))],
                worker("claude-fable-5-2", None),
                (&[], &[]),
                ("lane", &["/h/.5claude"]),
            ),
            (
                "the 9claude overseer walled, its successor chosen",
                replay,
                vec![],
                overseer(None, &["/h/.9claude"]),
                (
                    &[("/h/.2claude", 0), ("/h/.10claude", 1)],
                    &[("/h/.2claude", 2), ("/h/.10claude", 2)],
                ),
                ("lane", &["/h/.2claude", "/h/.10claude"]),
            ),
            (
                "a controller's own account at 97 on the 5-hour window",
                format!(
                    "account=/h/.2claude\tharness=claude\tweekly-pct=30\tsession-5h-pct=97\tsession-resets={}",
                    at(1.0)
                ),
                vec![],
                overseer(Some("/h/.2claude"), &[]),
                (&[], &[]),
                ("walled", &["/h/.2claude"]),
            ),
            (
                "one point of weekly room read eight hours ago",
                "account=/h/.2claude\tharness=claude\tweekly-pct=94\tobserved-age=28800".to_owned(),
                vec![],
                worker("claude-opus-5-5", Some("/h/.2claude")),
                (&[], &[]),
                ("unmeasured", &["/h/.2claude"]),
            ),
            (
                "Anthropic refusing an account this machine reads with room on the model",
                "account=/h/.6claude\tharness=claude\tweekly-pct=20\tunified-status=rejected"
                    .to_owned(),
                vec![local(
                    "/h/.6claude",
                    20,
                    json!([{"label": "Opus", "pct": 10, "resets_at": at(100.0)}]),
                )],
                worker("claude-opus-5-5", Some("/h/.6claude")),
                (&[], &[]),
                ("walled", &["/h/.6claude"]),
            ),
            (
                "a spent 5-hour window on an account this machine reads with room on the model",
                format!(
                    "account=/h/.7claude\tharness=claude\tweekly-pct=20\tsession-5h-pct=100\tsession-resets={}",
                    at(2.0)
                ),
                vec![local(
                    "/h/.7claude",
                    20,
                    json!([{"label": "Opus", "pct": 10, "resets_at": at(100.0)}]),
                )],
                worker("claude-opus-5-5", Some("/h/.7claude")),
                (&[], &[]),
                ("walled", &["/h/.7claude"]),
            ),
        ];
        // Read through the provider's words alone, as an overseer's pick
        // here reads a remote provider.
        let words: Vec<Row> = vec![(
            "Anthropic refusing an overseer's own account this machine reads with room",
            "account=/h/.8claude\tharness=claude\tunified-status=rejected".to_owned(),
            vec![local(
                "/h/.8claude",
                20,
                json!([{"label": "Opus", "pct": 10, "resets_at": at(100.0)}]),
            )],
            overseer(Some("/h/.8claude"), &[]),
            (&[], &[]),
            ("walled", &["/h/.8claude"]),
        )];
        let mut wrong = Vec::new();
        let read_as = rows
            .into_iter()
            .map(|row| (host_rows as Parse, row))
            .chain(words.into_iter().map(|row| (host_words as Parse, row)));
        for (parse, (case, lines, own, req, (charges, others), (answer, named))) in read_as {
            let (read, notes) = host_through(&lines, parse);
            assert!(notes.is_empty(), "{case}: {notes:?}");
            let mut rows = own;
            rows.extend(
                read.iter()
                    .map(|raw| AccountRow::parse(raw, &settings).unwrap()),
            );
            let facts = FleetFacts {
                charges: per(charges),
                seats: per(others),
                others: per(others),
                ..FleetFacts::default()
            };
            let reply = pick(&rows, &req, &facts, &settings, &tokens, NOW).reply();
            let dir = reply["record"]["config_dir"].as_str().unwrap_or("");
            if reply["answer"] != json!(answer) || !named.contains(&dir) {
                wrong.push(format!("{case}: {reply}"));
            }
        }
        assert!(wrong.is_empty(), "{wrong:#?}");
    }

    #[test]
    fn a_providers_row_is_read_field_by_field_and_dropped_on_one_nobody_can_parse() {
        let dir = tempfile::tempdir().unwrap();
        let accounts = Judged::of("accounts", Ok(super::super::tests::settings()));
        let state = Judged::of("state", Ok(dir.path().to_path_buf()));
        let env = Env {
            accounts: &accounts,
            account_state: &state,
            home: None,
            copilot_home: None,
            controller_preference: "",
            account_tokens: &crate::settings::Judged::of("tokens", Ok(Vec::new())),
        };
        let read = accounts.get().unwrap();
        let mut ctx = Ctx::new(&env, &read, 1_800_000_000).unwrap();
        ctx.serve_max_age = 300;
        let rows = host_rows(
            &mut ctx,
            "account=/h/.a\tharness=claude\tstatus=refused\tdetail=http-403-permission_error\n\
             account=/h/.b\tharness=claude\tsession-5h-pct=4\tweekly-pct=9\tplan-ends=2027-01-31\treserved=1\tseat=1\n\
             account=/h/.c\tharness=claude\tweekly-pct=abc\n\
             harness=claude\tweekly-pct=8\n\
             account=/h/.d\tharness=claude\n\
             account=/h/.p\tharness=pi\tcredit-limit=200.00\tcredit-spent=50.00\tcredit-remaining=150\tcredit-expires=2027-02-01T00:00:00Z\n\
             account=/h/.x\tharness=codex\tweekly-pct=100\tcredit-remaining=6000.5\tcredit-available=1\tcredit-overage-limit-reached=0\tcredit-spend-control-reached=0\n\
             account=/h/.y\tharness=codex\tweekly-pct=100\tcredit-remaining=6000\tcredit-available=1\tcredit-overage-limit-reached=0\n\
             account=/h/.z\tharness=codex\tweekly-pct=100\tcredit-remaining=6000\tcredit-available=yes\tcredit-overage-limit-reached=0\tcredit-spend-control-reached=0\n\
             account=/h/.q\tharness=pi\tcredit-limit=200.00\tcredit-spent=50.00\tcredit-remaining=150\tcredit-expires=2027-02-01T00:00:00Z\tcredit-available=1\n\
             account=/h/.k\tharness=claude\tweekly-pct=9\tcredit-remaining=10\n",
            "plan",
        );
        assert_eq!(rows.len(), 5, "{rows:?}");
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
        assert_eq!(rows[4]["pool"], json!("plan"));
        assert_eq!(rows[4]["credits"]["balance"], json!(6000.5));
        assert_eq!(rows[4]["credits"]["has_credits"], json!(true));
        assert_eq!(rows[4]["credits"]["overage_limit_reached"], json!(false));
        assert_eq!(rows[4]["credits"]["spend_control_reached"], json!(false));
        assert_eq!(rows[4]["verdict"], json!("room"));
        assert_eq!(rows[4]["binding_bucket"], json!("credits"));
        assert_eq!(
            ctx.notes,
            vec![
                "host-account-invalid account=/h/.c field=weekly-pct",
                "host-account-invalid account=<unnamed> field=account",
                "host-account-invalid account=/h/.y field=credit-fields",
                "host-account-invalid account=/h/.z field=credit-fields",
                "host-account-invalid account=/h/.q field=credit-fields",
                "host-account-invalid account=/h/.k field=credit-fields",
            ]
        );
    }
}
