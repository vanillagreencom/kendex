//! The usage records under `usage/` beside the claim store, one per
//! account named by its harness and a checksum of its config dir, shared
//! with every other reader of the same state directory: a record holds a
//! usage figure, a refusal, or a refusal with the last figure kept beside
//! it, and a reader on another host of the same directory serves what this
//! one wrote. `fetched_at` is when the record's own answer arrived; a
//! figure kept beside a refusal keeps its stamp in `usage_fetched_at`, so
//! no reader takes a refused refresh for a fresh figure. The host-wide
//! refresh lock turns N callers times M accounts into one request per
//! account per window.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::usage::{Rounding, parse_body};
use super::wall;
use super::{MODEL, WINDOWS};

/// How long a refused endpoint is left alone when its answer named no
/// Retry-After: long enough that a fleet measuring every thirty seconds
/// stops feeding the limit it hit, short enough that an account comes back
/// inside one operator's attention.
pub const REFUSAL_WINDOW_S: u64 = 300;

/// How long a reader waits for the host-wide refresh lock: the holder
/// refreshes one account under a 10-second request bound, so this outlasts
/// an ordinary refresh.
const LOCK_WAIT: Duration = Duration::from_secs(10);

/// A recorded refusal of one endpoint.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Refusal {
    pub endpoint: String,
    pub status: String,
    #[serde(default)]
    pub code: Option<String>,
    pub detail: String,
    pub expires_at: u64,
}

/// A figure kept beside a refusal, or the sample a fresh figure displaced.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Prior {
    pub fetched_at: u64,
    pub usage: Value,
}

/// A fall of the account's weekly figure inside one weekly window: a reset
/// came before the window's end, which a wall recorded before the earlier
/// figure was read cannot have foreseen.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Fall {
    pub from_at: u64,
    pub from_pct: f64,
    pub at: u64,
    pub to_pct: f64,
}

/// One account's record as the file holds it. Fields other readers add
/// (a normalized block) are dropped on rewrite; they re-derive them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Record {
    pub harness: String,
    pub config_dir: String,
    pub fetched_at: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage_fetched_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prior: Option<Prior>,
    #[serde(default = "one")]
    pub sample_claims: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refusal: Option<Refusal>,
    /// The latest fall, kept across later figures: `prior` shows a fall for
    /// one fetch only, and the wall it ends stands until it is read.
    #[serde(rename = "drop", default, skip_serializing_if = "Option::is_none")]
    pub fall: Option<Fall>,
}

fn one() -> u64 {
    1
}

impl Record {
    /// The stamp of the figure the record holds: its own where it stands
    /// alone, `usage_fetched_at` where a refusal was written over it.
    fn figure_at(&self) -> Option<u64> {
        self.usage.as_ref()?;
        Some(self.usage_fetched_at.unwrap_or(self.fetched_at))
    }

    /// The fall the record holds: the one written, else the one between its
    /// displaced sample and its figure, which the shell `lanes` writes
    /// without keeping `drop`.
    fn held_fall(&self) -> Option<Fall> {
        self.fall.clone().or_else(|| {
            let prior = self.prior.as_ref()?;
            fall(
                &self.harness,
                (prior.fetched_at, &prior.usage),
                (self.figure_at()?, self.usage.as_ref()?),
            )
        })
    }
}

/// The fall from the `earlier` figure to the `later`, each with its stamp:
/// both weekly figures read, the later lower in the whole percents the
/// listing judges, and read before the earlier figure's weekly reset. A
/// lower figure past that reset is the next week's; a figure nobody could
/// read is never lower.
fn fall(harness: &str, earlier: (u64, &Value), later: (u64, &Value)) -> Option<Fall> {
    let weekly = |usage: &Value| {
        let buckets = parse_body(harness, usage, Rounding::Rounded);
        let pct = buckets.get("weekly_pct").and_then(Value::as_f64);
        let reset = buckets
            .pointer("/resets/weekly")
            .and_then(Value::as_str)
            .and_then(|s| crate::clock::epoch_secs(&super::usage::utc_stamp(s)));
        (pct, reset)
    };
    let (from_at, from) = earlier;
    let (at, to) = later;
    let (Some(from_pct), Some(window_ends)) = weekly(from) else {
        return None;
    };
    let (Some(to_pct), _) = weekly(to) else {
        return None;
    };
    (to_pct < from_pct && at < window_ends).then_some(Fall {
        from_at,
        from_pct,
        at,
        to_pct,
    })
}

/// The record file for `config_dir` measured through `harness`: a
/// checksum of the whole directory path, so two accounts sharing a name
/// keep separate records and no name leaves the directory.
pub fn record_path(usage_dir: &Path, harness: &str, config_dir: &str) -> PathBuf {
    usage_dir.join(format!(
        "{harness}-{}-{}.json",
        wall::cksum(config_dir.as_bytes()),
        config_dir.len()
    ))
}

/// The record at `path` naming `harness` and `config_dir`, or `None`: no
/// file, a file that does not parse, or one naming another account (a
/// checksum collision) is a miss.
pub fn read(path: &Path, harness: &str, config_dir: &str) -> Option<Record> {
    let text = std::fs::read_to_string(path).ok()?;
    let record: Record = serde_json::from_str(&text).ok()?;
    (record.harness == harness && record.config_dir == config_dir).then_some(record)
}

/// The figure a record serves at `now` under `max_age`: its usage with the
/// figure's own age, and the displaced sample beside it, or `None` where
/// the record holds no figure, the figure is stamped in the future, is at
/// or past `max_age`, or a consumed bucket of it has reset.
pub struct Figure {
    pub usage: Value,
    pub fetched_at: u64,
    pub age: u64,
    pub prior: Option<Prior>,
    pub fall: Option<Fall>,
}

/// What a read of the figure found: the figure, nothing, or a figure
/// whose consumed bucket reset (the stamp named), which no reader serves.
pub enum FigureRead {
    Served(Figure),
    Miss,
    Reset(String),
}

pub fn figure(record: &Record, harness: &str, max_age: Option<u64>, now: u64) -> FigureRead {
    let (Some(usage), Some(at)) = (&record.usage, record.figure_at()) else {
        return FigureRead::Miss;
    };
    if !usage.is_object() || at > now {
        return FigureRead::Miss;
    }
    let age = now - at;
    if max_age.is_some_and(|max| age >= max) {
        return FigureRead::Miss;
    }
    let buckets = parse_body(harness, usage, Rounding::Unrounded);
    if let Some(reset) = consumed_reset(&buckets, now) {
        return FigureRead::Reset(reset);
    }
    FigureRead::Served(Figure {
        usage: usage.clone(),
        fetched_at: at,
        age,
        prior: record.prior.clone(),
        fall: record.held_fall(),
    })
}

/// The reset stamp of a consumed plan window whose reset has arrived at
/// `now`: a figure past such a reset cannot show current usage.
pub fn consumed_reset(buckets: &Value, now: u64) -> Option<String> {
    let resets = buckets.get("resets");
    let shared = WINDOWS.iter().filter(|w| w.bucket != MODEL).map(|w| {
        (
            buckets.get(w.field).and_then(Value::as_f64),
            resets
                .and_then(|r| r.get(w.bucket))
                .and_then(Value::as_str)
                .map(str::to_owned),
        )
    });
    let scoped = buckets
        .get("model_buckets")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|b| {
            (
                b.get("pct").and_then(Value::as_f64),
                b.get("resets_at")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
            )
        });
    shared.chain(scoped).find_map(|(pct, reset)| {
        let reset = reset?;
        let epoch = crate::clock::epoch_secs(&super::usage::utc_stamp(&reset))?;
        (pct.is_some_and(|p| p > 0.0) && epoch <= now).then_some(reset)
    })
}

/// The live refusal of `endpoint` a record holds at `now`, with the
/// record's own age, or `None`.
pub fn refusal(record: &Record, endpoint: &str, now: u64) -> Option<(Refusal, u64)> {
    let refusal = record.refusal.as_ref()?;
    if refusal.endpoint != endpoint || refusal.expires_at <= now || record.fetched_at > now {
        return None;
    }
    Some((refusal.clone(), now - record.fetched_at))
}

/// Write `usage` as the record's figure at `now`, the figure it displaces
/// kept as the prior sample and the fall from it recorded, else the fall
/// the record held kept. Renamed into place whole, so a concurrent reader
/// never parses half a record. A record that cannot be written costs the
/// next run a fetch, never a wrong figure. The fall the record now holds.
#[allow(
    clippy::disallowed_methods,
    reason = "the usage record under the claim store's directory, the listing's own file, written whole and renamed into place as every reader of it expects"
)]
pub fn write_figure(
    path: &Path,
    harness: &str,
    config_dir: &str,
    usage: Value,
    now: u64,
) -> Option<Fall> {
    let existing = read(path, harness, config_dir);
    let held = existing.as_ref().and_then(Record::held_fall);
    let prior = existing.and_then(|r| {
        Some(Prior {
            fetched_at: r.figure_at()?,
            usage: r.usage?,
        })
    });
    let fall = prior
        .as_ref()
        .and_then(|p| fall(harness, (p.fetched_at, &p.usage), (now, &usage)))
        .or(held);
    let record = Record {
        harness: harness.to_owned(),
        config_dir: config_dir.to_owned(),
        fetched_at: now,
        usage: Some(usage),
        usage_fetched_at: None,
        prior,
        sample_claims: 1,
        refusal: None,
        fall,
    };
    let _ = replace(path, &record);
    record.fall
}

/// Write a refusal over the account's record at `now`, keeping the figure
/// the record held under its own stamp beside it, with its fall, so a
/// usage 429 is answered from it. A `plan_ended` refusal keeps none: a
/// figure from before the plan ended would hand out an account that admits
/// no launch.
/// `Ok(())` where the record stands, else the cause: every caller on the
/// host then posts again each pass.
#[allow(
    clippy::disallowed_methods,
    reason = "the usage record under the claim store's directory, the listing's own file, written whole and renamed into place as every reader of it expects"
)]
pub fn write_refusal(
    path: &Path,
    harness: &str,
    config_dir: &str,
    refusal: Refusal,
    now: u64,
) -> Result<(), String> {
    let kept = read(path, harness, config_dir)
        .filter(|_| refusal.status != "plan_ended")
        .and_then(|r| Some((r.figure_at()?, r.held_fall(), r.usage?, r.prior)));
    let (usage_fetched_at, fall, usage, prior) = match kept {
        Some((at, fall, usage, prior)) => (Some(at), fall, Some(usage), prior),
        None => (None, None, None, None),
    };
    let record = Record {
        harness: harness.to_owned(),
        config_dir: config_dir.to_owned(),
        fetched_at: now,
        usage,
        usage_fetched_at,
        prior,
        sample_claims: 1,
        refusal: Some(refusal),
        fall,
    };
    replace(path, &record)
}

#[allow(
    clippy::disallowed_methods,
    reason = "the usage record under the claim store's directory, the listing's own file, written whole and renamed into place as every reader of it expects"
)]
fn replace(path: &Path, record: &Record) -> Result<(), String> {
    let dir = path.parent().unwrap_or(path);
    std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let temp = path.with_extension(format!("json.{}.tmp", std::process::id()));
    let text = serde_json::to_string(record).map_err(|e| e.to_string())?;
    std::fs::write(&temp, text).map_err(|e| format!("{}: {e}", temp.display()))?;
    if let Err(e) = std::fs::rename(&temp, path) {
        let _ = std::fs::remove_file(&temp);
        return Err(format!("{}: {e}", path.display()));
    }
    Ok(())
}

/// The host-wide refresh lock, `.usage-refresh.lock` under the usage
/// directory, the file every reader of the directory takes its `flock` on.
/// Held while `f` runs, up to the wait; a lock that does not come free is
/// the returned notice and `f` runs without it: refusing an account on
/// contention would report it unmeasured, the wall on every launch that
/// serving a stale figure exists to prevent, while a doubled request is
/// one notice. Where `flock(1)` is absent the shell readers take a `mkdir`
/// mutex here instead, and this lock takes none: it is held across a
/// request by processes a caller's ceiling ends, and a mutex directory
/// outlives its killed holder, so every later refresh on the host would
/// wait out the bound; a refresh a shell reader makes at the same moment
/// costs one doubled request, which a timed-out wait already accepts.
#[allow(
    clippy::disallowed_methods,
    reason = "the listing's own host-wide refresh lock beside its records, taken through agent-runtime's record lock so a shell reader's flock on the same file excludes it"
)]
pub fn under_refresh_lock<R>(usage_dir: &Path, f: impl FnOnce() -> R) -> (R, Option<String>) {
    let lock = usage_dir.join(".usage-refresh.lock");
    if std::fs::create_dir_all(usage_dir).is_err() {
        return (
            f(),
            Some(format!(
                "usage-lock-unopenable lock-file={}",
                lock.display()
            )),
        );
    }
    let mut guard = match crate::record::lock(&usage_dir.join(".usage-refresh")) {
        Ok(guard) => guard,
        Err(_) => {
            return (
                f(),
                Some(format!(
                    "usage-lock-unopenable lock-file={}",
                    lock.display()
                )),
            );
        }
    };
    let wait = crate::record::Wait {
        limit: LOCK_WAIT,
        ..crate::record::Wait::DEFAULT
    };
    let mut f = Some(f);
    let held = guard.with_wait(&wait.start(), || Ok(f.take().map(|f| f())));
    match held {
        Ok(Some(result)) => (result, None),
        Ok(None) | Err(_) => (
            f.take().expect("the closure runs once")(),
            Some(format!(
                "usage-lock-timeout lock-file={} wait-s={}",
                lock.display(),
                LOCK_WAIT.as_secs()
            )),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_kept_figure_keeps_its_own_stamp_and_a_consumed_reset_is_a_miss() {
        let dir = tempfile::tempdir().unwrap();
        let path = record_path(dir.path(), "claude", "/h/.a");
        let body = |weekly: u64, reset: &str| {
            json!({"five_hour": {"utilization": 10, "resets_at": "2099-01-01T05:00:00Z"},
                   "seven_day": {"utilization": weekly, "resets_at": reset}})
        };
        write_figure(
            &path,
            "claude",
            "/h/.a",
            body(20, "2099-01-01T00:00:00Z"),
            1000,
        );
        write_figure(
            &path,
            "claude",
            "/h/.a",
            body(40, "2099-01-01T00:00:00Z"),
            1600,
        );
        let record = read(&path, "claude", "/h/.a").unwrap();
        assert_eq!(record.prior.as_ref().map(|p| p.fetched_at), Some(1000));
        write_refusal(
            &path,
            "claude",
            "/h/.a",
            Refusal {
                endpoint: "usage".into(),
                status: "rate_limited".into(),
                code: Some("429".into()),
                detail: "HTTP 429".into(),
                expires_at: 1900,
            },
            1700,
        )
        .unwrap();
        let record = read(&path, "claude", "/h/.a").unwrap();
        assert_eq!(record.usage_fetched_at, Some(1600));
        let FigureRead::Served(served) = figure(&record, "claude", Some(300), 1800) else {
            panic!("served");
        };
        assert_eq!((served.fetched_at, served.age), (1600, 200));
        assert!(matches!(
            figure(&record, "claude", Some(100), 1800),
            FigureRead::Miss
        ));
        assert!(refusal(&record, "usage", 1800).is_some());
        assert!(refusal(&record, "usage", 1900).is_none());
        assert!(refusal(&record, "token", 1800).is_none());
        write_figure(
            &path,
            "claude",
            "/h/.a",
            body(40, "2000-01-01T00:00:00Z"),
            2000,
        );
        let record = read(&path, "claude", "/h/.a").unwrap();
        assert!(matches!(
            figure(&record, "claude", None, 1_800_000_000),
            FigureRead::Reset(_)
        ));
        assert!(read(&path, "claude", "/h/.b").is_none());
    }
}
