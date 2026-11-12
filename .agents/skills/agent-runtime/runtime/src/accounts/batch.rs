//! Measurements someone else took, in the one form the judge reads them:
//! the provider `accounts` answer, one tab-separated `key=value` line per
//! account. Its one parser reads a provider's answer for orch's listing and
//! a supplied batch for `accounts judge`; each line's row is finished as the
//! listing finishes its own, and a batch's rows are judged as a named pick
//! judges one account.
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
}

/// A line one field of which nobody can read: the account it names, empty
/// where it names none, and the first such field.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Unreadable {
    pub account: String,
    pub field: &'static str,
}

/// One line: `account` and `harness` required, the percentages whole
/// numbers 0 to 100, a credit's fields together as its harness states them:
/// the Pi grant's four on a `harness=pi` row with no `monthly-pct`, the
/// Codex credit's four on a `harness=codex` row, none on any other.
fn line(text: &str) -> std::result::Result<Line, Unreadable> {
    let mut fields: Map<String, Value> = Map::new();
    for field in text.split('\t').filter(|f| !f.is_empty()) {
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
    let has = |keys: &[&str]| keys.iter().any(|k| fields.contains_key(*k));
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
    let grant = harness == Harness::Pi && !credits.is_null();
    let buckets = json!({
        "weekly_pct": weekly,
        "model_pct": model,
        "monthly_pct": monthly,
        "credits": credits,
        "model_label": nz("model-label"),
        "model_buckets": match model {
            None => json!([]),
            Some(pct) => json!([{"label": nz("model-label"), "pct": pct, "resets_at": nz("model-resets")}]),
        },
        "resets": {"weekly": nz("weekly-resets"), "model": nz("model-resets"),
                   "monthly": nz("monthly-resets")},
    });
    Ok(Line {
        fields,
        account,
        harness,
        buckets,
        grant,
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
/// words `plan-ends`, `reserved` and `seat` are carried as written where
/// non-empty; the judge reads them.
fn rows(
    ctx: &Ctx,
    text: &str,
    host_pool: &str,
    through: &str,
) -> Vec<(usize, std::result::Result<Value, Unreadable>)> {
    let mut out = Vec::new();
    for (index, text) in text.lines().enumerate().filter(|(_, l)| !l.is_empty()) {
        let Line {
            fields,
            account,
            harness,
            buckets,
            grant,
        } = match line(text) {
            Ok(read) => read,
            Err(unreadable) => {
                out.push((index + 1, Err(unreadable)));
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
        let grant = grant || get("detail").starts_with("api-credit-");
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
                through,
                reading: Reading {
                    status,
                    detail: get("detail"),
                    plan: String::new(),
                    usage: Some(Usage::Provider(buckets)),
                    age: None,
                    prior: None,
                    // The protocol states no time a figure was read, so no
                    // fall of it can follow a wall's sighting; a record of
                    // this spelling here is this machine's.
                    fall: None,
                },
                words: Some(words),
            },
        );
        finish(ctx, &mut row, pool);
        out.push((index + 1, Ok(row)));
    }
    out
}

/// A provider's `accounts` answer under a host of `host_pool`'s kind, as
/// the listing's rows: a line nobody can read is left out, named in one
/// `host-account-invalid` note.
pub fn host_rows(ctx: &mut Ctx, text: &str, host_pool: &str) -> Vec<Value> {
    let mut out = Vec::new();
    for (_, read) in rows(ctx, text, host_pool, "host") {
        match read {
            Ok(row) => out.push(row),
            Err(Unreadable { account, field }) => {
                let named = if account.is_empty() {
                    "<unnamed>"
                } else {
                    account.as_str()
                };
                ctx.notes.push(format!(
                    "host-account-invalid account={named} field={field}"
                ));
            }
        }
    }
    out
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
/// candidate charged: the seats are the batch's own `seat=1` rows and the
/// controller member of `record`, and the lanes are charged as every room
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
    let ground = Beside::read(project, record)?;
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
            Err(Unreadable { account, field }) => json!({
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
    use super::*;
    use crate::settings::Judged;

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
