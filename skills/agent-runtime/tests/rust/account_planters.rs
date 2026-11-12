//! The accounts a listing lists, planted from rows in the listing's own
//! record shape, for every row that reads an account through the listing:
//! agent-runtime's own and orch's, which includes this file by path. The
//! usage endpoints are the `usage-curl` fixture beside it.
#![allow(
    dead_code,
    reason = "each suite includes this module by path and uses a subset of it"
)]

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The fixtures the planted accounts are read through: `usage-curl` and
/// `kendex-launch`, beside this file whichever package includes it.
pub fn account_fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../agent-runtime/tests/rust/fixtures")
}

/// What a planted listing reads under: the environment (the home, the
/// records' root and the planted directories as the configured ones) and
/// the provider's `accounts` lines of the rows measured through `host`.
pub struct Planted {
    pub env: Vec<(String, String)>,
    pub provider_lines: Vec<String>,
}

/// A usage record as the listing's cache holds it, planted beside the
/// account: `<state>/usage/<harness>-<cksum>-<len>.json`.
fn usage_record_path(state: &Path, harness: &str, config_dir: &str) -> PathBuf {
    state.join("usage").join(format!(
        "{harness}-{}-{}.json",
        agent_runtime::record::cksum(config_dir.as_bytes()),
        config_dir.len()
    ))
}

/// A Claude usage body that reads as the row's windows: the 5-hour and
/// weekly windows with their resets, the model-scoped windows, and the
/// cloud credit where the row carries a dollar grant. A row naming no
/// weekly window but a headroom takes `100 - headroom` as its weekly use.
fn claude_body(row: &Value) -> Value {
    let resets = &row["resets"];
    let mut body = json!({});
    if let Some(session) = row["session_5h_pct"].as_f64() {
        body["five_hour"] = json!({"utilization": session, "resets_at": resets["session"]});
    }
    let weekly = row["weekly_pct"]
        .as_f64()
        .or_else(|| row["headroom_pct"].as_f64().map(|h| 100.0 - h));
    if let Some(weekly) = weekly {
        let reset = if resets["weekly"].is_null() {
            row["binding_resets_at"].clone()
        } else {
            resets["weekly"].clone()
        };
        body["seven_day"] = json!({"utilization": weekly, "resets_at": reset});
    }
    if let Some(buckets) = row["model_buckets"].as_array() {
        body["limits"] = Value::Array(
            buckets
                .iter()
                .map(|b| {
                    json!({"kind": "weekly_scoped", "percent": b["pct"], "resets_at": b["resets_at"],
                           "scope": {"model": {"display_name": b["label"]}}})
                })
                .collect(),
        );
    }
    if row["credits"]["unit"] == json!("usd") {
        let c = &row["credits"];
        body["iguana_necktie"] = json!({
            "limit_dollars": c["limit_dollars"], "used_dollars": c["used_dollars"],
            "remaining_dollars": c["remaining_dollars"], "resets_at": c["resets_at"],
            "locked_reason": c["locked_reason"],
        });
    }
    body
}

/// A Codex usage body that reads as the row's windows and credits.
fn codex_body(row: &Value) -> Value {
    let resets = &row["resets"];
    let epoch = |v: &Value| v.as_str().and_then(agent_runtime::clock::epoch_secs);
    let weekly = row["weekly_pct"]
        .as_f64()
        .or_else(|| row["headroom_pct"].as_f64().map(|h| 100.0 - h));
    let mut body = json!({"rate_limit": {
        "primary_window": row["session_5h_pct"].as_f64().map(|p| json!({
            "used_percent": p, "reset_at": epoch(&resets["session"]), "limit_window_seconds": 18_000})),
        "secondary_window": weekly.map(|p| json!({
            "used_percent": p,
            "reset_at": epoch(if resets["weekly"].is_null() { &row["binding_resets_at"] } else { &resets["weekly"] }),
            "limit_window_seconds": 604_800})),
    }});
    if row["credits"].is_object() {
        let c = &row["credits"];
        body["credits"] = json!({"has_credits": c["has_credits"], "unlimited": c["unlimited"],
            "overage_limit_reached": c["overage_limit_reached"], "balance": c["balance"]});
        body["spend_control"] = json!({"reached": c["spend_control_reached"]});
    }
    body
}

/// A Copilot usage body that reads as the row's monthly pool.
fn copilot_body(row: &Value) -> Value {
    let granted = row["credits"]["granted"].as_f64().unwrap_or(100.0);
    let pct = row["monthly_pct"]
        .as_f64()
        .or_else(|| row["headroom_pct"].as_f64().map(|h| 100.0 - h))
        .unwrap_or(0.0);
    json!({
        "copilot_plan": row["plan"],
        "quota_reset_date_utc": row["resets"]["monthly"],
        "quota_snapshots": {"premium_interactions": {
            "entitlement": granted, "remaining": granted - (pct * granted / 100.0).ceil()}},
    })
}

/// The accounts a listing lists, planted from rows in the listing's own
/// record shape: a row measured through `local` is a directory under
/// `root/home` named as the row's `config_dir` is (under the planted
/// path itself where two rows share a name), holding the credential its
/// `status` reads as (`expired` a token past its expiry, `no_credentials`
/// none, `error` a file that is not JSON) and, under `state/usage`, the
/// record its figure or refusal reads as; a row measured through `host` is
/// one provider `accounts` line, returned for the caller to answer. Directories
/// under `root/home` the rows no longer name are removed, and a provider's
/// cached answer with them. The planted directories are the configured ones,
/// since a planted name need not carry its harness's word.
pub fn plant_listing(root: &Path, state: &Path, rows: &[Value], now: u64) -> Planted {
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let mut env = vec![
        ("HOME".to_owned(), home.display().to_string()),
        (
            "AGENT_RUNTIME_ACCOUNT_STATE_DIR".to_owned(),
            state.display().to_string(),
        ),
    ];
    let mut provider_lines = Vec::new();
    let mut local_dirs: Vec<PathBuf> = Vec::new();
    for row in rows {
        let through = row["measured_through"].as_str().unwrap_or("local");
        let config_dir = row["config_dir"].as_str().unwrap().to_owned();
        if through == "host" {
            provider_lines.push(provider_line(row, &config_dir));
            continue;
        }
        let name = Path::new(&config_dir).file_name().unwrap().to_owned();
        let dir = if local_dirs.iter().any(|d| d.file_name() == Some(&name)) {
            root.join(config_dir.trim_start_matches('/'))
        } else {
            home.join(&name)
        };
        plant_local(&dir, state, row, now);
        local_dirs.push(dir);
    }
    for entry in std::fs::read_dir(&home).unwrap().flatten() {
        let keep = local_dirs.iter().any(|d| *d == entry.path());
        if !keep && entry.file_name().to_string_lossy().starts_with('.') {
            std::fs::remove_dir_all(entry.path()).unwrap();
        }
    }
    env.push((
        "AGENT_RUNTIME_ACCOUNT_DIRS".to_owned(),
        local_dirs
            .iter()
            .map(|d| d.display().to_string())
            .collect::<Vec<String>>()
            .join(":"),
    ));
    for entry in std::fs::read_dir(state.join("usage"))
        .into_iter()
        .flatten()
        .flatten()
    {
        if entry
            .file_name()
            .to_string_lossy()
            .starts_with("lane-host-")
        {
            std::fs::remove_file(entry.path()).unwrap();
        }
    }
    Planted {
        env,
        provider_lines,
    }
}

/// One `accounts` line for a provider's row: the words and windows the
/// row carries, as the provider states them.
pub fn provider_line(row: &Value, account: &str) -> String {
    let mut fields = vec![
        format!("account={account}"),
        format!("harness={}", row["harness"].as_str().unwrap_or("claude")),
    ];
    if let Some(status) = row["status"].as_str().filter(|s| *s != "ok") {
        fields.push(format!("status={status}"));
    }
    if let Some(detail) = row["detail"].as_str() {
        fields.push(format!("detail={detail}"));
    }
    let resets = &row["resets"];
    let weekly = row["weekly_pct"]
        .as_f64()
        .or_else(|| row["headroom_pct"].as_f64().map(|h| 100.0 - h));
    let weekly_reset = if resets["weekly"].is_null() {
        &row["binding_resets_at"]
    } else {
        &resets["weekly"]
    };
    for (key, value, reset_key, reset) in [
        (
            "session-5h",
            row["session_5h_pct"].as_f64(),
            "session",
            &resets["session"],
        ),
        ("weekly", weekly, "weekly", weekly_reset),
        (
            "monthly",
            row["monthly_pct"].as_f64(),
            "monthly",
            &resets["monthly"],
        ),
    ] {
        if let Some(pct) = value {
            fields.push(format!("{key}-pct={}", pct as u64));
            if let Some(reset) = reset.as_str() {
                fields.push(format!("{reset_key}-resets={reset}"));
            }
        }
    }
    if let Some(bucket) = row["model_buckets"].as_array().and_then(|b| b.first()) {
        if let Some(pct) = bucket["pct"].as_f64() {
            fields.push(format!("model-pct={}", pct as u64));
        }
        if let Some(label) = bucket["label"].as_str() {
            fields.push(format!("model-label={label}"));
        }
        if let Some(reset) = bucket["resets_at"].as_str() {
            fields.push(format!("model-resets={reset}"));
        }
    }
    if row["credits"]["unit"] == json!("usd") {
        let c = &row["credits"];
        fields.push(format!(
            "credit-limit={}",
            c["limit_dollars"].as_f64().unwrap_or(0.0)
        ));
        fields.push(format!(
            "credit-spent={}",
            c["used_dollars"].as_f64().unwrap_or(0.0)
        ));
        fields.push(format!(
            "credit-remaining={}",
            c["remaining_dollars"].as_f64().unwrap_or(0.0)
        ));
        fields.push(format!(
            "credit-expires={}",
            c["resets_at"].as_str().unwrap_or("")
        ));
    }
    for (key, name) in [
        ("plan_ends", "plan-ends"),
        ("plan-ends", "plan-ends"),
        ("reserved", "reserved"),
        ("seat", "seat"),
    ] {
        match &row[key] {
            Value::Null => {}
            Value::String(s) => fields.push(format!("{name}={s}")),
            other => fields.push(format!("{name}={other}")),
        }
    }
    format!("{}\n", fields.join("\t"))
}

/// One local account: its directory, its credential as the row's status
/// reads, and its usage record.
fn plant_local(dir: &Path, state: &Path, row: &Value, now: u64) {
    let harness = row["harness"].as_str().unwrap_or("claude");
    let alias = row["alias"].as_str().unwrap_or("account");
    let status = row["status"].as_str().unwrap_or("ok");
    let _ = std::fs::remove_dir_all(dir);
    std::fs::create_dir_all(dir).unwrap();
    let config_dir = dir.display().to_string();
    let expires_ms = if status == "expired" {
        (now - 3600) * 1000
    } else {
        (now + 365 * 86_400) * 1000
    };
    let credential = match harness {
        "claude" => json!({"claudeAiOauth": {
            "accessToken": format!("token-{alias}"), "refreshToken": format!("refresh-{alias}"),
            "expiresAt": expires_ms, "refreshTokenExpiresAt": expires_ms,
            "subscriptionType": row["plan"].as_str().unwrap_or("max")}})
        .to_string(),
        "codex" => json!({"tokens": {"access_token": format!("token-{alias}"), "account_id": format!("acct-{alias}")}}).to_string(),
        _ => json!({"copilotTokens": format!("token-{alias}")}).to_string(),
    };
    let file = match harness {
        "claude" => ".credentials.json",
        "codex" => "auth.json",
        _ => "config.json",
    };
    match status {
        "no_credentials" => std::fs::write(dir.join(".claude.json"), "{}\n").unwrap(),
        "error" => std::fs::write(dir.join(file), "not json\n").unwrap(),
        _ => std::fs::write(dir.join(file), credential).unwrap(),
    }
    let record = usage_record_path(state, harness, &config_dir);
    std::fs::create_dir_all(record.parent().unwrap()).unwrap();
    let _ = std::fs::remove_file(&record);
    let age = row["usage_age_s"].as_u64().unwrap_or(0);
    let body = match harness {
        "claude" => claude_body(row),
        "codex" => codex_body(row),
        _ => copilot_body(row),
    };
    let refusal = |status: &str, code: &str| {
        json!({"endpoint": "usage", "status": status, "code": code,
               "detail": row["detail"].as_str().unwrap_or(&format!("usage query refused with HTTP {code}")),
               "expires_at": now + 300})
    };
    // A row the listing rated carries the sample it rated against: the
    // binding window three points lower, as many seconds earlier as the
    // rate names.
    let prior = row["usage_rate_pct_per_min"]
        .as_f64()
        .filter(|r| *r > 0.0 && row["usage_rate_state"] == json!("measured"))
        .map(|rate| {
            let elapsed = (3.0 * 60.0 / rate).round() as u64;
            let mut earlier = row.clone();
            if row["binding_bucket"] == json!("model") {
                let buckets = earlier["model_buckets"].as_array_mut().unwrap();
                let fullest = (0..buckets.len())
                    .max_by(|a, b| {
                        buckets[*a]["pct"]
                            .as_f64()
                            .unwrap_or(0.0)
                            .total_cmp(&buckets[*b]["pct"].as_f64().unwrap_or(0.0))
                    })
                    .unwrap();
                let pct = buckets[fullest]["pct"].as_f64().unwrap();
                buckets[fullest]["pct"] = json!(pct - 3.0);
            } else {
                let key = match row["binding_bucket"].as_str() {
                    Some("session") => "session_5h_pct",
                    Some("monthly") => "monthly_pct",
                    _ => "weekly_pct",
                };
                let pct = row[key]
                    .as_f64()
                    .or_else(|| row["headroom_pct"].as_f64().map(|h| 100.0 - h))
                    .unwrap_or(0.0);
                earlier[key] = json!(pct - 3.0);
            }
            let body = match harness {
                "claude" => claude_body(&earlier),
                "codex" => codex_body(&earlier),
                _ => copilot_body(&earlier),
            };
            json!({"fetched_at": now - age - elapsed, "usage": body})
        })
        .unwrap_or(Value::Null);
    let value = match status {
        "ok" | "no_usage_data" => json!({"harness": harness, "config_dir": config_dir,
            "fetched_at": now - age, "usage": body, "sample_claims": 1, "prior": prior}),
        "rate_limited" => json!({"harness": harness, "config_dir": config_dir, "fetched_at": now,
            "usage_fetched_at": now - age, "usage": body, "sample_claims": 1,
            "refusal": refusal("rate_limited", "429")}),
        "unreachable" => {
            json!({"harness": harness, "config_dir": config_dir, "fetched_at": now - age,
            "refusal": refusal("unreachable", "503")})
        }
        "refused" => json!({"harness": harness, "config_dir": config_dir, "fetched_at": now - age,
            "refusal": refusal("refused", "403")}),
        "plan_ended" => {
            json!({"harness": harness, "config_dir": config_dir, "fetched_at": now - age,
            "refusal": refusal("plan_ended", "403")})
        }
        _ => return,
    };
    std::fs::write(&record, value.to_string()).unwrap();
    // The record is older than the credential it reads: a credential newer
    // than the record is a renewed login whose figure is another's.
    let at = std::time::UNIX_EPOCH + Duration::from_secs(now.saturating_sub(age + 1));
    for path in [dir.join(file), dir.join(".claude.json")] {
        if let Ok(f) = std::fs::File::open(&path) {
            let _ = f.set_modified(at);
        }
    }
}
