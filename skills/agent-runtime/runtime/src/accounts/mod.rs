//! The accounts judge: one view of each account the listing lists,
//! [`AccountRow`], read per call and stored nowhere, and the two reads over
//! it, [`roster`] for the heartbeat and [`pick`] for every pick, handoff
//! mark and overseer mark: the launcher's, the succession walk's, the
//! turn-end hook's, the mark judge's and the close's. One judge and one
//! limit ([`judge`]) answer them all; no shell judges an account.
//!
//! The listing is this module's own ([`listing`]): every account this
//! machine discovers and the owner states, measured through its credential
//! at the usage endpoint behind the cache, and beside them the rows a
//! caller read from a provider ([`Provider`]). The listing applies no exclusion and no retirement: it lists every account
//! with those words as flags, and the judge refuses by them. What this
//! module owns beside the listing is the judgement over the rows: the
//! status words, the window a lane on a model is judged on, the projection
//! of the lanes already on an account with the candidate among them, the
//! seats, the grant tier and the choice.
//!
//! The status words, one per account: `pick`; `reserve`, never picked and
//! still measured, the provider's `reserved=1`; `retired <date>`, picked
//! until that UTC day and measured after it, from the machine's own
//! `AGENT_RUNTIME_ACCOUNT_RETIRE` or the provider's `plan-ends`: a stated end that a
//! live reading contradicts (a credential that answers after its end) is a
//! reported line, never a silent absence. An account `AGENT_RUNTIME_ACCOUNT_EXCLUDE`
//! names is measured like any other and refused by that word for every
//! pick, a lane's or an overseer's, from this machine's listing, a
//! provider's rows or the owner's statement; a controller's question about
//! its own account reads its figures. Both kinds of account kept from
//! workers read `reserve` to a reader.
//!
//! A listing that could not be read whole admits nothing: no pick, and a
//! roster line saying `unread`. A provider's `plan-ends` that names no
//! calendar day is an end nobody can read: the row keeps its figures, is
//! never picked, and is one `account-plan-end-invalid` line under the
//! roster. The projection charges each account the lanes its caller counts
//! live on it ([`FleetFacts`]) and the candidate lane beside them.
//!
//! A provider's rows carry its seats (`seat=1`) and its words (`reserved`,
//! `plan-ends`). The listing carries this machine's reading of an account
//! and the provider's beside it; a pick judges one reading per billed
//! account, the provider's eligible one over the discovered local copy
//! ([`resolve`]), while the roster keeps both. A pick on a grant pool, the
//! cloud credit of a `cloud-credit` host or a Pi `anthropic/` model's API
//! credit, is judged on the grant alone (tier 0: the allowance that expires
//! first is spent first), and where the caller names the accounts a host
//! admits ([`FleetFacts`]'s `cloud_repo`) no other is a candidate. A Pi
//! launch on a `github-copilot/` model spends a Copilot pool: the
//! provider's `harness=pi` rows and the owner's stated
//! `AGENT_RUNTIME_COPILOT_POOL` for a root no provider row reads are rows of
//! the listing like any other.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{Map, Value, json};

use crate::clock;
use crate::harness::Harness;
use crate::settings::{self, AccountSettings};

pub mod batch;
pub mod cache;
pub mod here;
pub mod listing;
pub mod renewal;
pub mod usage;
pub mod walk;
pub mod wall;

pub use listing::{Listing, Provider};
pub use renewal::step as renewal_step;

/// The start-counter tag every read of this judge is counted under.
pub const TAG: &str = "accounts";

/// What the reading takes of the loaded settings: the account keys, the
/// account records' root, the homes an account directory is resolved under
/// and the controller's preference the walk reads.
#[derive(Debug, Clone, Copy)]
pub struct Env<'a> {
    pub accounts: &'a settings::Judged<AccountSettings>,
    pub account_state: &'a settings::Judged<PathBuf>,
    pub home: Option<&'a str>,
    pub copilot_home: Option<&'a str>,
    pub controller_preference: &'a str,
}

/// The host word of a read with no provider named.
pub const LOCAL: &str = "local";

/// Where a stated end came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum EndSource {
    /// The machine's own `AGENT_RUNTIME_ACCOUNT_RETIRE`.
    Setting,
    /// The provider's account row.
    Provider,
}

impl EndSource {
    /// Who stated the end, as the roster's and the refusal's `source=` name
    /// it.
    pub fn stated_by(self) -> &'static str {
        match self {
            EndSource::Setting => "AGENT_RUNTIME_ACCOUNT_RETIRE",
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
    pub harness: Harness,
    pub config_dir: String,
    /// One spelling per account: the resolved path where the directory
    /// stands.
    pub canon: String,
    pub measured_through: String,
    pub status: String,
    pub detail: Option<String>,
    pub verdict: String,
    pub headroom_pct: Option<f64>,
    pub binding_bucket: Option<String>,
    pub binding_resets_at: Option<String>,
    pub model_buckets: Vec<ModelBucket>,
    /// The rate the listing measured on its binding bucket, in points a
    /// minute, where its `usage_rate_state` is `measured`.
    pub usage_rate_pct_per_min: Option<f64>,
    pub usage_age_s: Option<f64>,
    pub credits: Option<Value>,
    /// The pool the row spends: `plan` where the listing named none,
    /// `copilot`, `api-credit` or `cloud-credit` for a grant.
    pub pool: String,
    pub plan_ends: PlanEnd,
    pub reserved: bool,
    pub seat: bool,
    /// The machine's own stated end for this account.
    pub retire: Option<String>,
    /// Whether `AGENT_RUNTIME_ACCOUNT_EXCLUDE` names the account: the judge refuses it
    /// by that word in every form.
    pub excluded: bool,
    /// Whether the owner configured the account (`AGENT_RUNTIME_ACCOUNT_DIRS`, a
    /// provider's row, a stated pool): the chooser picks among these alone,
    /// and a named pick judges any.
    pub configured: bool,
    /// The row as the listing built it, for the lines and records that
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

/// The directory's own name.
fn base(config_dir: &str) -> String {
    Path::new(config_dir)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// Whether a setting key names the directory by its name, with or without
/// the leading dot.
fn lane_named(config_dir: &str, name: &str) -> bool {
    let base = base(config_dir);
    name == base || Some(name) == base.strip_prefix('.')
}

/// Whether a stated name is the account's alias or names its directory.
pub fn names(alias: &str, config_dir: &str, name: &str) -> bool {
    name == alias || lane_named(config_dir, name)
}

impl AccountRow {
    /// One listing row as the judge reads it, under `settings`' statement.
    /// `None` for a row with no `status` or `verdict`, or a harness none of
    /// the four: a row that failed to render, never a measured account.
    pub fn parse(raw: &Value, settings: &AccountSettings) -> Option<AccountRow> {
        if raw.get("status").is_none_or(Value::is_null)
            || raw.get("verdict").is_none_or(Value::is_null)
        {
            return None;
        }
        let harness = Harness::parse(raw.get("harness").and_then(Value::as_str)?)?;
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
        let retire = listing::retire_date(settings, &alias, &config_dir);
        let excluded = listing::excluded(settings, &alias, &config_dir);
        Some(AccountRow {
            canon: wall::canon(&config_dir),
            harness,
            measured_through: text(raw, "measured_through"),
            status: text(raw, "status"),
            detail: string(raw, "detail"),
            verdict: text(raw, "verdict"),
            headroom_pct: number(raw, "headroom_pct"),
            binding_bucket: string(raw, "binding_bucket"),
            binding_resets_at: string(raw, "binding_resets_at"),
            model_buckets,
            usage_rate_pct_per_min: (string(raw, "usage_rate_state").as_deref()
                == Some("measured"))
            .then(|| number(raw, "usage_rate_pct_per_min"))
            .flatten(),
            usage_age_s: number(raw, "usage_age_s"),
            credits: raw.get("credits").filter(|c| c.is_object()).cloned(),
            pool: string(raw, "pool").unwrap_or_else(|| "plan".to_owned()),
            plan_ends: match string(raw, "plan_ends").or_else(|| string(raw, "plan-ends")) {
                None => PlanEnd::None,
                Some(day) if crate::settings::calendar_date_valid(&day) => PlanEnd::Day(day),
                Some(value) => PlanEnd::Invalid(value),
            },
            reserved: flag(raw, "reserved"),
            seat: flag(raw, "seat"),
            retire,
            excluded,
            configured: raw.get("configured") != Some(&Value::Bool(false)),
            alias,
            config_dir,
            raw: raw.clone(),
        })
    }

    /// The word a reader is shown: an account kept from workers reads
    /// `reserve`, whether the provider reserved it or the owner's exclusion
    /// names it; any other its stated word.
    pub fn word(&self) -> Word {
        if self.excluded {
            return Word::Reserve;
        }
        self.stated()
    }

    /// The account's stated word, what a pick is refused by: the
    /// provider's reservation first, then a provider's end nobody can read,
    /// then the earlier of the machine's and the provider's stated ends.
    fn stated(&self) -> Word {
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
        matches!(self.stated(), Word::Retired { date, .. } if date.as_str() <= today)
    }

    /// The word's own verdict on a pick today: the one
    /// rule the judge, a named pick's answer and the delegated pick's
    /// exclusions read.
    pub fn standing(&self, today: &str) -> Standing {
        match self.stated() {
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

    /// The label of the window the listing rated, its binding bucket's:
    /// where that bucket is `model`, the label of the last of its model
    /// windows at the greatest rounded percentage, never the listing's
    /// `model_label`, which is the greatest raw percentage and can name the
    /// other window of a tie; none otherwise, since a shared window
    /// carries no label.
    fn rated_label(&self) -> Option<&str> {
        if self.binding_bucket.as_deref() != Some("model") {
            return None;
        }
        self.model_buckets
            .iter()
            .max_by(|a, b| a.pct.total_cmp(&b.pct))
            .and_then(|bucket| bucket.label.as_deref())
    }

    /// The field text both the roster line and the `account` event print.
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

    /// The row's identity:
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

/// One listing under the judge's statement: its rows, the cause the
/// provider's read failed with, and the keyed lines the listing says
/// beside the rows.
#[derive(Debug, Clone, PartialEq)]
pub struct Roster {
    pub rows: Vec<AccountRow>,
    pub provider_failure: Option<String>,
    pub notes: Vec<String>,
}

impl Roster {
    fn from_listing(listing: Listing, settings: &AccountSettings) -> Option<Roster> {
        let rows = listing
            .rows
            .iter()
            .map(|raw| AccountRow::parse(raw, settings))
            .collect::<Option<Vec<AccountRow>>>()?;
        Some(Roster {
            rows,
            provider_failure: listing.provider_failure,
            notes: listing.notes,
        })
    }

    /// The `account <fields>` line of each record, with the word a reader
    /// is shown after the fields where it is not `pick`, and under the roster one
    /// `account-end-contradicted` line per account whose stated end has
    /// come while its credential still answers and one
    /// `account-plan-end-invalid` line per account whose provider end
    /// names no calendar day, and the listing's own keyed lines.
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
            match row.stated() {
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
        lines.extend(self.notes.iter().cloned());
        lines
    }

    /// Whether an account bills the harness and pool a pick would judge
    /// (`owed_wall`'s roster check).
    pub fn bills(&self, billed: Harness, pool: &str) -> bool {
        self.rows
            .iter()
            .any(|r| r.harness == billed && ((r.pool == "api-credit") == (pool == "api-credit")))
    }
}

/// The listing of this machine's accounts, with a provider's reading beside
/// them where the caller read one: the roster, or the cause where it could
/// not be read whole, for the caller to say in its place
/// (`account-unread`'s fields).
pub fn roster(
    settings: &Env,
    provider: Option<Provider>,
    now: u64,
) -> std::result::Result<Roster, String> {
    roster_naming(settings, provider, None, now)
}

/// [`roster`], with the account a named pick asks about, `(harness,
/// directory)`, measured beside the listing where the listing does not
/// list it: a named account that exists is judged on what it reads, never
/// taken for no account.
pub fn roster_naming(
    settings: &Env,
    provider: Option<Provider>,
    named: Option<(Harness, &str)>,
    now: u64,
) -> std::result::Result<Roster, String> {
    let accounts = settings.accounts.get().map_err(|e| e.to_string())?;
    let host_word = provider
        .as_ref()
        .map_or(LOCAL, |p| p.host.as_str())
        .to_owned();
    let listing = listing::list(settings, &accounts, provider, named, now)
        .map_err(|cause| format!("host={host_word} {cause}"))?;
    Roster::from_listing(listing, &accounts).ok_or_else(|| format!("host={host_word} parse=failed"))
}

/// Whether a row is a provider's reading (`measured_through` `host`, or a
/// provider's name), as against this machine's own (`local`) or the
/// owner's stated one (`stated`).
fn provider_reading(row: &AccountRow) -> bool {
    !matches!(row.measured_through.as_str(), "local" | "stated")
}

/// One reading per billed account for a pick of `billed` on `model`: the
/// listing carries this machine's reading of an account and the provider's
/// beside it, local first, and a pick judges one of them. The provider's
/// reading stands, except: a provider row that read nothing (`unreachable`,
/// or a holding with no figure and no refusal) leaves this machine's
/// measured reading in place; a Pi root's provider row stands only where it
/// read the pool, else the stated reading stands where one is stated; a
/// Claude row the provider measured with no window scoped to `model` is
/// judged on this machine's fresh reading of that window where it has one,
/// and is unmeasured where it has none (the shared windows are not that
/// model's wall), except that `admit` (the overseer walk's
/// [`PickRequest::admit_unread_scope`]) judges it on the provider's shared
/// windows, its buckets as read, marked `scope: unread`; and a local copy
/// with no credential file is no reading, so the provider's measured one
/// stands as an account's one reading does. The provider's words
/// (`reserved`, `plan-ends`) stand whichever reading does, a row with no
/// reading included. An account with one reading keeps it. The roster is
/// never resolved: it reports both readings.
///
/// A session that opens on this machine (`opens_here`) signs in with this
/// machine's stored login of the home, never with the token a provider
/// measured it through: the provider's reading stands for it only where
/// that login reads held ([`usage::stored_login`]), else the account is
/// judged on this machine's own row, and a provider's row with no home
/// listed here is no candidate for it.
fn resolve(
    rows: &[AccountRow],
    billed: Harness,
    model: &str,
    req: &PickRequest,
    now: u64,
) -> Vec<AccountRow> {
    let mut out: Vec<AccountRow> = Vec::new();
    for row in rows {
        let other = out.iter().position(|r| {
            r.harness == row.harness
                && r.canon == row.canon
                && provider_reading(r) != provider_reading(row)
        });
        match other {
            Some(i) => {
                let (own, provider) = if provider_reading(row) {
                    (out[i].clone(), row.clone())
                } else {
                    (row.clone(), out[i].clone())
                };
                let signed_in = !req.opens_here
                    || usage::stored_login(own.harness, &own.config_dir, now)
                        == usage::StoredLogin::Held;
                let (reserved, plan_ends) = (provider.reserved, provider.plan_ends.clone());
                let mut stands = if signed_in {
                    prefer(own, provider, billed, model, req.admit_unread_scope)
                } else {
                    own
                };
                stands.reserved |= reserved;
                if stands.plan_ends == PlanEnd::None {
                    stands.plan_ends = plan_ends;
                }
                out[i] = stands;
            }
            None => out.push(row.clone()),
        }
    }
    if req.opens_here {
        out.retain(|r| {
            !provider_reading(r)
                || rows.iter().any(|own| {
                    !provider_reading(own) && own.harness == r.harness && own.canon == r.canon
                })
        });
    }
    out
}

/// The reading of one account's two that stands for a pick.
fn prefer(
    own: AccountRow,
    provider: AccountRow,
    billed: Harness,
    model: &str,
    admit: bool,
) -> AccountRow {
    let scoped = billed == Harness::Claude && !model.is_empty();
    let unread = provider.harness == Harness::Pi && provider.headroom_pct.is_none()
        || provider.status == "unreachable"
        || (provider.status == "no_usage_data" && provider.headroom_pct.is_none());
    let unscoped = scoped
        && (provider.measured() || provider.status == "no_usage_data")
        && model_buckets(&provider, model).is_empty();
    if !unread && !unscoped {
        return provider;
    }
    let own_figure = own.headroom_pct.is_some()
        && (own.harness == Harness::Pi || own.status == "ok")
        && !(scoped && own.model_buckets.is_empty());
    if own_figure {
        return own;
    }
    if !unscoped {
        return provider;
    }
    // The overseer walk's admission: the shared windows the provider
    // measured judge the account, every bucket as it was read, and the
    // record says the model's own window went unread.
    if admit && provider.measured() {
        let mut admitted = provider;
        if let Value::Object(raw) = &mut admitted.raw {
            raw.insert("scope".to_owned(), Value::from("unread"));
        }
        return admitted;
    }
    // A home with no credential file, one signed in by a token, is no
    // reading: the provider's measured reading is the account's one, judged
    // as a provider-only account is.
    if provider.measured() && own.status == "no_credentials" {
        return provider;
    }
    // This machine's reading carries no fresh window scoped to the model,
    // or its own read failed: the account is unmeasured for it, with the
    // cause in its status and detail.
    let mut unmeasured = own;
    if unmeasured.measured() {
        unmeasured.status = "no_usage_data".to_owned();
    }
    unmeasured.headroom_pct = None;
    if unmeasured.detail.is_none() {
        unmeasured.detail = Some(format!("no fresh local model window for {model}"));
    }
    if let Value::Object(raw) = &mut unmeasured.raw {
        raw.insert("status".to_owned(), Value::from(unmeasured.status.as_str()));
        raw.insert("headroom_pct".to_owned(), Value::Null);
        raw.insert(
            "detail".to_owned(),
            unmeasured
                .detail
                .as_deref()
                .map_or(Value::Null, Value::from),
        );
    }
    unmeasured
}

/// The row a named Pi root on a grant pool that no reading covers is judged
/// on: nothing measured, so the judge answers `unmeasured`, exit 5, the
/// read to repair in `status` and `detail`, and for the API grant the
/// grant's own refusal (`refusal.cause=api-credit`), the record the
/// launcher's named arm reads. Never `no-record`: a Pi root is a directory
/// the listing holds only where a reading covers it, so no row is no
/// reading, not no account, and a launch onto a pool nobody measured is a
/// read to repair, never one made unjudged.
fn unmeasured_row(dir: &str, pool: &str, settings: &AccountSettings) -> AccountRow {
    let (through, detail) = if pool == "api-credit" {
        ("local", "no provider API-credit row")
    } else {
        (
            "stated",
            "no lane host row and no AGENT_RUNTIME_COPILOT_POOL entry reads a Copilot pool for this account",
        )
    };
    let raw = json!({
        "alias": listing::alias(settings, dir),
        "harness": Harness::Pi,
        "config_dir": dir,
        "retire_date": Value::Null,
        "measured_through": through,
        "status": "no_usage_data",
        "detail": detail,
        "refreshable": false,
        "plan": Value::Null,
        "weekly_pct": Value::Null,
        "model_pct": Value::Null,
        "model_label": Value::Null,
        "model_buckets": [],
        "monthly_pct": Value::Null,
        "credits": Value::Null,
        "unlimited": false,
        "claims": 0,
        "headroom_pct": Value::Null,
        "binding_bucket": Value::Null,
        "binding_resets_at": Value::Null,
        "usage_age_s": Value::Null,
        "resets": {"weekly": Value::Null, "model": Value::Null, "monthly": Value::Null},
        "wall": Value::Null,
        "usage_rate_state": "one-sample",
        "usage_rate_pct_per_min": Value::Null,
        "projected_wall_minutes": Value::Null,
        "pool": pool,
        "verdict": "unmeasured",
    });
    AccountRow::parse(&raw, settings).expect("a row with a status and a verdict parses")
}

// --- the pick ---------------------------------------------------------------------------------

/// A launch whose model's provider nothing bills ([`Harness::billed`]'s
/// `None`: a Pi model naming no provider, or one other than
/// `pi-claude/`, `github-copilot/` and `anthropic/`) is refused at exit 5
/// in both forms before any row is read, since nothing measures what it
/// spends and an unmeasured pool is never room. The chooser's answer
/// carries the chooser's refusal; the named answer carries none
/// ([`PickAnswer::Unbilled`]).
pub fn unbilled(req: &PickRequest) -> Option<PickAnswer> {
    let model = req.model.as_deref().unwrap_or("");
    req.harness
        .billed(model)
        .is_none()
        .then(|| unbilled_answer(req))
}

fn unbilled_answer(req: &PickRequest) -> PickAnswer {
    let (harness, model) = (req.harness, req.model.clone().unwrap_or_default());
    if req.lane.is_some() {
        PickAnswer::Unbilled { harness, model }
    } else {
        PickAnswer::ProviderUnmeasured { harness, model }
    }
}

/// What a caller asks the judge: `lanes pick`'s own words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PickRequest {
    pub harness: Harness,
    /// The selector the harness runs (`--native-model`).
    pub model: Option<String>,
    /// Config dirs the pick omits before judging (`--exclude-lane`).
    pub exclude: Vec<String>,
    /// Judge seats as ordinary accounts (`--for-overseer`).
    pub for_overseer: bool,
    /// Judge one named account (`--lane DIR`) instead of choosing.
    pub lane: Option<String>,
    /// Judge the named account on the projection (`--projected`).
    pub projected: bool,
    /// The bound in percent used; the setting where unset (`--max-pct`).
    pub max_pct: Option<u32>,
    /// The headroom a caller's own judgement triggers at, the succession
    /// walk's and the turn-end hook's mark (`--min-headroom-pct T`): the
    /// same bound in the record's own unit, `100 - T` percent used, so a
    /// pick admits only an account the caller would not hand off on.
    pub min_headroom_pct: Option<u32>,
    /// Hold the account's own binding bucket to the bound beside the
    /// model's window (`--binding-floor`): the overseer's next judgement
    /// reads that bucket, so a successor opened on an account whose
    /// binding bucket is a model it never launches would meet its mark at
    /// once.
    pub binding_floor: bool,
    /// Admit a Claude account whose shared windows the provider measured
    /// and whose window scoped to the model nothing read, judged on the
    /// shared windows with `scope: unread` on its record: the overseer
    /// walk's question alone, where the account-wall succession covers the
    /// unread window. Otherwise that account is unmeasured for the model.
    pub admit_unread_scope: bool,
    /// The session the pick places opens on this machine (an overseer, a
    /// lane in a local window), so it signs in with this machine's stored
    /// login of the account and never with the token a provider measured
    /// the account through.
    pub opens_here: bool,
}

impl PickRequest {
    /// The chooser's plain question for `harness`: no model, no exclusion,
    /// no named account, the setting's bound.
    pub fn new(harness: Harness) -> PickRequest {
        PickRequest {
            harness,
            model: None,
            exclude: Vec::new(),
            for_overseer: false,
            lane: None,
            projected: false,
            max_pct: None,
            min_headroom_pct: None,
            binding_floor: false,
            admit_unread_scope: false,
            opens_here: false,
        }
    }

    /// The bound in percent used a request names, where it names one.
    fn bound(&self) -> Option<u32> {
        self.max_pct.or(self.min_headroom_pct.map(|t| 100 - t))
    }

    /// Whether the request is the launch question: the lane the caller is
    /// about to add is charged and the projected wall judged (the chooser,
    /// and a named account under `--projected`). The plain named reading is
    /// the question whether an account is out of room now: a running
    /// lane's own charge is among the live ones, so no candidate is added.
    fn launch(&self) -> bool {
        self.projected || self.lane.is_none()
    }
}

/// The window a lane is judged on, `lane-model.sh`'s `model_binding`: its
/// bucket, its percentage used, its reset and, for a model-scoped window,
/// its label, the identity that tells two model windows at one reset
/// apart.
#[derive(Debug, Clone, PartialEq)]
pub struct Binding {
    pub bucket: String,
    pub pct: f64,
    pub resets_at: Option<String>,
    pub label: Option<String>,
}

/// `lane_norm`: case-folded, every character that is not a letter or a
/// digit dropped.
fn norm(text: &str) -> String {
    text.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_lowercase())
        .collect()
}

/// One kind of plan window: its bucket, the reading's field and its length.
pub(crate) struct Window {
    pub bucket: &'static str,
    pub field: &'static str,
    pub hours: f64,
}

/// The plan windows the judge reads, longest first: the listing rates a
/// reading on them, the binding and the projection judge them, and the
/// cache misses on a consumed one's reset. Each provider's parser emits the
/// kinds that provider states; a provider with another window adds a row.
/// At one percentage the earlier row binds.
pub(crate) const WINDOWS: [Window; 3] = [
    Window {
        bucket: "monthly",
        field: "monthly_pct",
        hours: 720.0,
    },
    Window {
        bucket: "weekly",
        field: "weekly_pct",
        hours: 168.0,
    },
    Window {
        bucket: "model",
        field: "model_pct",
        hours: 168.0,
    },
];

/// The bucket the model-scoped windows share; every other row of
/// [`WINDOWS`] is a window shared by every model.
pub(crate) const MODEL: &str = "model";

/// `wall_rank`: the order two windows at one percentage are told apart by.
fn wall_rank(bucket: &str) -> usize {
    WINDOWS
        .iter()
        .position(|w| w.bucket == bucket)
        .map_or(0, |i| WINDOWS.len() - i)
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
/// the shared windows of [`WINDOWS`] and the model-scoped windows whose
/// label names the model (a trailing `[1m]` dropped, the normalized
/// spellings contained either way; a window with no label counts for every
/// model); with none, the reader's own binding bucket.
fn model_binding(row: &AccountRow, model: Option<&str>) -> Option<Binding> {
    if row.plan_ended() {
        return Some(Binding {
            bucket: "plan".to_owned(),
            pct: 100.0,
            resets_at: None,
            label: None,
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
                label: row.rated_label().map(str::to_owned),
            });
    };
    let resets = |key: &str| row.raw.get("resets").and_then(|r| string(r, key));
    let mut bindings = Vec::new();
    for window in WINDOWS.iter().filter(|w| w.bucket != MODEL) {
        if let Some(pct) = number(&row.raw, window.field) {
            bindings.push(Binding {
                bucket: window.bucket.to_owned(),
                pct,
                resets_at: resets(window.bucket),
                label: None,
            });
        }
    }
    bindings.extend(model_buckets(row, model));
    max_binding(bindings)
}

/// `model_bindings($model)`: the model-scoped windows whose label names
/// the model (a trailing `[1m]` dropped, the normalized spellings contained
/// either way; a window with no label counts for every model).
fn model_buckets(row: &AccountRow, model: &str) -> Vec<Binding> {
    let m = norm(
        model
            .strip_suffix("[1m]")
            .or_else(|| model.strip_suffix("[1M]"))
            .unwrap_or(model),
    );
    row.model_buckets
        .iter()
        .filter(|bucket| match bucket.label.as_deref().map(norm) {
            None => true,
            Some(l) => !l.is_empty() && !m.is_empty() && (l.contains(&m) || m.contains(&l)),
        })
        .map(|bucket| Binding {
            bucket: MODEL.to_owned(),
            pct: bucket.pct,
            resets_at: bucket.resets_at.clone(),
            label: bucket.label.clone(),
        })
        .collect()
}

/// `lane_binding($model; $binding_floor)`: the model's window, and under
/// the floor the account's own binding bucket held to the same bound
/// beside it, the fuller of the two deciding; an unmeasured bucket on
/// either side is a window nobody read, never room.
fn lane_binding(row: &AccountRow, model: Option<&str>, floor: bool) -> Option<Binding> {
    let window = model_binding(row, model)?;
    if !floor || model.is_none_or(str::is_empty) {
        return Some(window);
    }
    let account = model_binding(row, None)?;
    max_binding(vec![window, account])
}

/// `reset_epoch`: a stamp as an epoch second, `None` where it is none.
fn reset_epoch(stamp: Option<&str>) -> Option<u64> {
    clock::epoch_secs(stamp?)
}

/// The length in hours of the window a bucket names, the most a charge to
/// its reset can run for.
fn window_hours(bucket: &str) -> f64 {
    WINDOWS
        .iter()
        .find(|w| w.bucket == bucket)
        .map_or(168.0, |w| w.hours)
}

/// The projected room of one account on the window that binds it: the
/// window charged `S × burn × hours_to_reset`. `S` is the lanes that will
/// spend it: the fleet's live lanes on the account and, for the launch
/// question, the candidate about to join them. `burn` is the window's burn
/// per lane hour: where the reader measured a rate on that same window,
/// the account's measured rate, the whole account's delta, shared among
/// the lanes live at the sample (`sampled`; a model window's rate is one
/// lane's, since no lane on another model spends it); else
/// `AGENT_RUNTIME_ACCOUNT_BURN_PCT_PER_HOUR`, a lane's hourly spend in points of five
/// hours, scaled to the window's length. The divisor is the sample's own
/// occupancy, never the lanes live now: the charged lanes whose current
/// session on the account began at or before the sample (`session_since`,
/// which every launch and relaunch rewrites), so a lane launched or
/// relaunched onto the account after the sample, which spent none of it,
/// cannot dilute the per-lane burn the sample measured.
/// `hours_to_reset` is the hours left to the window's reset, at least one
/// and at most the window's length, one where no reset is known.
///
/// On a seat the overseer spends the window beside the lanes: it is one
/// more spender at the sample, the measured rate shared with it, and what
/// it will spend to the reset at that burn is `kept`, the room the seat
/// keeps for it beyond its own trigger. The overseer is never charged in
/// `headroom`, which is the lanes' alone.
///
/// The selection score (`with_lane_selection_score`, `lanes --help`
/// § pick) is no charge: it is the projected room weighted by the reset
/// bonus `1 + 1 / (1 + hours to the binding reset)`, bounded to twice the
/// room, so among accounts with room the sooner reset is tried first and
/// no reset time buys a launch past the bound.
#[derive(Debug, Clone, PartialEq)]
pub struct Projection {
    pub headroom: f64,
    pub window: Binding,
    pub burn: f64,
    pub kept: f64,
}

/// Whether the window a lane is judged on is the one the reader rated
/// (`lane-model.sh`'s `same_window`): the reader's binding bucket, at its
/// reset, under its label, compared in the normalized spelling; a window
/// with no label matches only a window with none. Two model windows at
/// one reset are two windows, and the reader's measured rate is the one
/// the label names.
fn same_window(row: &AccountRow, binding: &Binding) -> bool {
    row.binding_bucket.as_deref() == Some(binding.bucket.as_str())
        && row.binding_resets_at == binding.resets_at
        && row.rated_label().map(norm) == binding.label.as_deref().map(norm)
}

/// Who spends a window [`projection`] charges: the fleet's live lanes on
/// the account, those of them live at the sample, the candidate about to
/// join them, and on a seat its overseer.
#[derive(Clone, Copy)]
struct Spenders {
    claims: u32,
    sampled: u32,
    candidate: bool,
    seat: bool,
}

fn projection(
    row: &AccountRow,
    binding: &Binding,
    spenders: &Spenders,
    burn_default: f64,
    now: u64,
) -> Projection {
    let Spenders {
        claims,
        sampled,
        candidate,
        seat,
    } = *spenders;
    let share = if binding.bucket == "model" {
        1.0
    } else {
        f64::from((sampled + u32::from(seat)).max(1))
    };
    let window = window_hours(&binding.bucket);
    let burn = match row.usage_rate_pct_per_min {
        Some(rate) if (claims > 0 || seat) && same_window(row, binding) => rate * 60.0 / share,
        _ => burn_default * 5.0 / window,
    };
    let lanes = f64::from(claims) + if candidate { 1.0 } else { 0.0 };
    let hours = match reset_epoch(binding.resets_at.as_deref()) {
        None => 1.0,
        Some(reset) => ((reset as f64 - now as f64) / 3600.0).clamp(1.0, window),
    };
    Projection {
        headroom: 100.0 - binding.pct - lanes * burn * hours,
        window: binding.clone(),
        burn,
        kept: if seat { burn * hours } else { 0.0 },
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

/// What a row's own reading answers before its word and its seat: an ended
/// plan a full wall, a grant pool its grant's verdict, a Codex balance above
/// the floor lifting a window wall, else the wall against `max`. The one
/// rule the judge and the listing's verdict read, so a roster line and a
/// pick cannot disagree about one reading.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Reads {
    PlanEnded,
    Grant(&'static str),
    Credits,
    Wall(&'static str),
}

impl Reads {
    pub(crate) fn of(
        row: &AccountRow,
        wall: Option<f64>,
        max: f64,
        grant: Option<&Grant>,
        codex_floor: f64,
    ) -> Reads {
        let verdict = wall_verdict(wall, max);
        if row.plan_ended() {
            Reads::PlanEnded
        } else if let Some(grant) = grant {
            Reads::Grant(grant.verdict)
        } else if verdict == "walled" && credit_room(row, codex_floor) {
            Reads::Credits
        } else {
            Reads::Wall(verdict)
        }
    }

    pub(crate) fn verdict(self) -> &'static str {
        match self {
            Reads::PlanEnded => "walled",
            Reads::Grant(verdict) | Reads::Wall(verdict) => verdict,
            Reads::Credits => "room",
        }
    }
}

/// `credit_room($credit_floor)`: a Codex account whose credit balance
/// OpenAI spends once the plan windows are reached, strictly above the
/// floor, with the three flags as the reader printed them. The credits
/// count as room on a seat as on any account: they spend no
/// plan window the overseer needs.
pub fn credit_room(row: &AccountRow, floor: f64) -> bool {
    let Some(credits) = &row.credits else {
        return false;
    };
    row.harness == Harness::Codex
        && credits.get("has_credits") == Some(&Value::Bool(true))
        && credits.get("overage_limit_reached") == Some(&Value::Bool(false))
        && credits.get("spend_control_reached") == Some(&Value::Bool(false))
        && credits
            .get("balance")
            .and_then(Value::as_f64)
            .is_some_and(|b| b > floor)
}

/// The reset bonus (`with_lane_selection_score`): a sooner reset ranks a
/// room ahead, at most twofold; an unknown reset earns none.
fn reset_bonus(hours: Option<f64>) -> f64 {
    hours.map_or(1.0, |h| 1.0 + 1.0 / (1.0 + h))
}

/// A grant judged (`with_lane_tier`, `lanes --help` § pick tier 0): the
/// cloud credit of a `cloud-credit` host or a Pi `anthropic/` model's API
/// credit, an allowance that expires and does not refill. Read where the
/// row's `credits` carry a dollar limit and remainder and an end `E` (the
/// credit's own reset, for cloud credit the earlier of that and the
/// account's stated retirement); `room` while the remainder is above the
/// floor, the grant unlocked and `E` ahead; `walled` where the grant is
/// read and spent, locked or expired (an API grant whose row reads
/// `expired` too); `unmeasured` otherwise. Its share left is the
/// `headroom_pct` a caller reads, its score the share weighted by the
/// reset bonus of its hours to `E`.
#[derive(Debug, Clone, PartialEq)]
pub struct Grant {
    pub verdict: &'static str,
    pub expires: Option<u64>,
    pub share: Option<f64>,
    pub score: f64,
}

fn grant(row: &AccountRow, floor: f64, now: u64) -> Option<Grant> {
    let api = match row.pool.as_str() {
        "api-credit" => true,
        "cloud-credit" => false,
        _ => return None,
    };
    let credits = row.credits.clone().unwrap_or_default();
    let remaining = number(&credits, "remaining_dollars");
    let limit = number(&credits, "limit_dollars");
    let retire = (!api)
        .then_some(row.retire.as_deref())
        .flatten()
        .and_then(|day| clock::epoch_secs(&format!("{day}T00:00:00Z")));
    let expires = [
        reset_epoch(string(&credits, "resets_at").as_deref()),
        retire,
    ]
    .into_iter()
    .flatten()
    .min();
    let read = string(&credits, "unit").as_deref() == Some("usd")
        && remaining.is_some()
        && limit.is_some()
        && expires.is_some();
    let measured = !api || row.answers();
    let ahead = expires.is_some_and(|e| e > now);
    let share = match (read && measured, remaining, limit) {
        (true, Some(remaining), Some(limit)) if limit > 0.0 => Some(if ahead {
            (100.0 * remaining / limit).floor()
        } else {
            0.0
        }),
        _ => None,
    };
    let locked = credits.get("locked_reason").is_some_and(|l| !l.is_null());
    let verdict = if read
        && measured
        && remaining.is_some_and(|r| r > floor)
        && !locked
        && limit.is_some_and(|l| l > 0.0)
        && ahead
    {
        "room"
    } else if (api && row.status == "expired") || (read && measured) {
        "walled"
    } else {
        "unmeasured"
    };
    let hours = expires.map(|e| (e as f64 - now as f64).max(0.0) / 3600.0);
    Some(Grant {
        verdict,
        expires,
        share,
        score: share.unwrap_or(0.0) * reset_bonus(hours),
    })
}

/// One account judged for one launch.
#[derive(Debug, Clone, PartialEq)]
pub struct Judged {
    pub row: AccountRow,
    /// `room`, `walled`, `unmeasured`, `seat-reserve`, `cloud-repo-unset`,
    /// `reserved`, `retired` or `plan-end-invalid`.
    pub verdict: String,
    /// The reading's wall: the binding window's percentage used.
    pub wall: Option<f64>,
    pub binding: Option<Binding>,
    pub claims: u32,
    pub projection: Option<Projection>,
    pub seat: bool,
    /// The bound in percent used this account was held to: the request's,
    /// and on a seat the overseer's trigger kept beside it.
    pub limit: f64,
    pub credits: bool,
    pub grant: Option<Grant>,
    pub score: Option<f64>,
    /// On the chooser's answer, the room rows the choice was made among
    /// (`lanes pick --json`'s `qualifying_count`), the figure the succession
    /// walk's successor bound and the mark judge's capacity row read; a
    /// named account's judgement counts none.
    pub qualifying: Option<u32>,
}

/// A figure as the record spells it: an integral value as an integer, a
/// fraction as it is. The shell callers read the record's `wall`,
/// `effective_headroom_pct` and `need` by the pattern `^[0-9]{1,3}$`
/// (the hook's seat line), the spelling
/// `lanes pick --json` gives an integer percentage; `60.0` is unreadable
/// to them.
fn figure(n: f64) -> Value {
    if n.fract() == 0.0 && n.abs() < 9.0e15 {
        Value::from(n as i64)
    } else {
        Value::from(n)
    }
}

impl Judged {
    /// The record a caller reads: the reader's row with the judgement's
    /// fields over it, as `lanes pick --json` prints them, every integral
    /// figure spelled as an integer ([`figure`]); the rate fields of the
    /// window `wall` names, which are the reader's where that window is
    /// its binding and `one-sample` otherwise (the reader rated no other
    /// window); and on a seat `need`, the room the seat keeps, the figure
    /// `pick-seat-omitted` names.
    pub fn record(&self) -> Value {
        let mut record = match &self.row.raw {
            Value::Object(m) => m.clone(),
            _ => Map::new(),
        };
        let number = figure;
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
            if !same_window(&self.row, binding) {
                record.insert("usage_rate_state".to_owned(), Value::from("one-sample"));
                record.insert("usage_rate_pct_per_min".to_owned(), Value::Null);
                record.insert("projected_wall_minutes".to_owned(), Value::Null);
            }
        }
        if self.credits {
            record.insert("binding_bucket".to_owned(), Value::from("credits"));
            record.insert("usage_rate_state".to_owned(), Value::from("credits"));
            record.insert("usage_rate_pct_per_min".to_owned(), Value::Null);
            record.insert("projected_wall_minutes".to_owned(), Value::Null);
        }
        if let Some(grant) = &self.grant {
            record.insert(
                "headroom_pct".to_owned(),
                grant.share.map_or(Value::Null, number),
            );
            record.insert("binding_bucket".to_owned(), Value::from("credits"));
            record.insert("binding_resets_at".to_owned(), Value::Null);
            if grant.verdict != "room" {
                record.insert(
                    "refusal".to_owned(),
                    json!({"cause": self.row.pool, "retry_at": Value::Null}),
                );
            }
        }
        match &self.projection {
            Some(p) => {
                record.insert("projected_headroom_pct".to_owned(), number(p.headroom));
                record.insert("burn_pct_per_lane_hour".to_owned(), number(p.burn));
                record.insert(
                    "projected_window".to_owned(),
                    json!({
                        "bucket": p.window.bucket,
                        "pct": number(p.window.pct),
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
        record.insert(
            "effective_headroom_pct".to_owned(),
            self.wall.map_or(Value::Null, |w| number(100.0 - w)),
        );
        if let Some(qualifying) = self.qualifying {
            record.insert("qualifying_count".to_owned(), Value::from(qualifying));
        }
        record.insert("seat".to_owned(), Value::from(self.seat));
        if self.seat {
            record.insert("need".to_owned(), number(self.need()));
        }
        Value::Object(record)
    }

    /// The room a seat keeps for the overseer, in percent of the window:
    /// the headroom its limit leaves and what the overseer spends to the
    /// reset, rounded up to the whole percent the shell callers read.
    fn need(&self) -> f64 {
        (100.0 - self.limit + self.projection.as_ref().map_or(0.0, |p| p.kept)).ceil()
    }

    /// The earliest moment this walled account could have room: a grant
    /// states none; the projected window's reset where one was projected,
    /// else the binding's.
    fn retry_at(&self) -> Option<String> {
        if self.grant.is_some() {
            return None;
        }
        match &self.projection {
            Some(p) => p.window.resets_at.clone(),
            None => self.binding.as_ref().and_then(|b| b.resets_at.clone()),
        }
    }

    /// The order key of a room row (`lane_selection`, `lanes --help`
    /// § pick): a seat last; then the tier, a grant first (the allowance
    /// that expires first), plan windows, Codex credits last; then the
    /// grant's end, the higher score, fewer claims, more projected room,
    /// the lower wall.
    fn tier(&self) -> u8 {
        if self.grant.is_some() {
            0
        } else if self.credits {
            2
        } else {
            1
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
        /// Each candidate a grant refused, its directory and the grant's
        /// refusal: the read a caller repairs before a retry.
        refusals: Vec<(String, Value)>,
        exclusions: Vec<(String, String)>,
    },
    /// Exit 3 of `--lane`: the named account is walled or on its seat's
    /// reserve.
    Walled(Judged),
    /// Exit 3 of `--lane`: the provider reserved the named account. Its
    /// word refuses it, whatever its room; a caller prints
    /// the word, never the wall's figures.
    Reserved(Judged),
    /// Exit 3 of `--lane`: the named account's stated end has come. The
    /// day and who stated it are the refusal's, never the wall's figures.
    Retired {
        judged: Judged,
        ends: String,
        source: EndSource,
    },
    /// Exit 3 of `--lane`: `AGENT_RUNTIME_ACCOUNT_EXCLUDE` or `--exclude-lane` names
    /// the account. Its word refuses it, whatever its room, as a retired
    /// one is refused; the record's `verdict` is `excluded`.
    Excluded(Judged),
    /// Exit 5 of `--lane`: nothing measured the named account, a grant pool
    /// no reading covers among them ([`unmeasured_row`]).
    Unmeasured(Judged),
    /// Exit 5 of the chooser on a grant pool: no grant row measured the
    /// launch (`pick-provider-unmeasured`), a read to repair, never a
    /// window to wait out; and the chooser's answer to a launch whose
    /// model's provider nothing bills ([`unbilled`]).
    ProviderUnmeasured { harness: Harness, model: String },
    /// Exit 5 of `--lane`: the launch names a model whose provider nothing
    /// bills ([`unbilled`]), refused before any row is read. The record
    /// names the harness and the model and carries no `refusal`: the
    /// launcher's named arm reads a refusal it does not know as its judge
    /// failing, and a record with none as `lane-provider-unmeasured`.
    Unbilled { harness: Harness, model: String },
    /// Exit 4 of `--lane`: no row names the directory.
    NoRecord,
    /// Exit 7 of `--lane`: a `cloud-session` host's account that
    /// the caller's repository rule gives no access to this checkout's
    /// repository.
    CloudRepoUnset(Judged),
    /// The judge could not judge: the listing, the fleet or the host's
    /// capabilities unread. Never a verdict.
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
            | PickAnswer::Retired { .. }
            | PickAnswer::Excluded(_) => 3,
            PickAnswer::NoRecord => 4,
            PickAnswer::Unmeasured(_)
            | PickAnswer::ProviderUnmeasured { .. }
            | PickAnswer::Unbilled { .. } => 5,
            PickAnswer::CloudRepoUnset(_) => 7,
            PickAnswer::Unjudged { .. } => 1,
        }
    }

    /// The reply a caller reads: the answer's word, the exit it maps to,
    /// and the record or the counts `lanes pick --json` prints.
    pub fn reply(&self) -> Value {
        let (answer, record) = match self {
            PickAnswer::Lane(j) => ("lane", j.record()),
            PickAnswer::None {
                walled,
                unmeasured,
                seats,
                walled_resets_at,
                refusals,
                exclusions,
            } => (
                "none",
                json!({
                    "walled": walled,
                    "unmeasured": unmeasured,
                    "seats": seats.iter().map(|s| json!({
                        "config_dir": s.row.config_dir,
                        "projected_headroom_pct": s.projection.as_ref().map_or(Value::Null, |p| figure(p.headroom)),
                        "need": figure(s.need()),
                    })).collect::<Vec<Value>>(),
                    "qualifying_count": 0,
                    "walled_resets_at": walled_resets_at,
                    "refusals": refusals.iter().map(|(d, r)| json!({"config_dir": d, "refusal": r})).collect::<Vec<Value>>(),
                    "exclusions": exclusions.iter().map(|(d, r)| json!({"config_dir": d, "reason": r})).collect::<Vec<Value>>(),
                }),
            ),
            PickAnswer::Walled(j) => ("walled", j.record()),
            PickAnswer::Reserved(j) => ("reserved", j.record()),
            PickAnswer::Retired { judged, .. } => ("retired", judged.record()),
            PickAnswer::Excluded(j) => ("excluded", j.record()),
            PickAnswer::Unmeasured(j) => ("unmeasured", j.record()),
            PickAnswer::ProviderUnmeasured { harness, model } => (
                "unmeasured",
                json!({"harness": harness, "model": model, "refusal": {"cause": "provider-unmeasured", "retry_at": Value::Null}}),
            ),
            PickAnswer::Unbilled { harness, model } => {
                ("unmeasured", json!({"harness": harness, "model": model}))
            }
            PickAnswer::NoRecord => ("no-record", Value::Null),
            PickAnswer::CloudRepoUnset(j) => ("cloud-repo-unset", j.record()),
            PickAnswer::Unjudged { cause } => ("unjudged", json!({"cause": cause})),
        };
        json!({"answer": answer, "exit": self.exit(), "record": record})
    }
}

/// What the judge reads beside the rows: the seats and the fleet's live
/// charges per account, each from this fleet's own records, and the
/// accounts a `cloud-session` host may launch on.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FleetFacts {
    /// Canonical config dirs the fleet's overseer and the provider's
    /// `seat=1` rows hold.
    pub seats: Vec<String>,
    pub charges: BTreeMap<String, u32>,
    /// The instant, as epoch seconds, each charged lane began spending on
    /// its account, per canonical config dir, where its record names one:
    /// the lanes live at a usage sample are the charged lanes whose instant
    /// is at or before it.
    pub started: BTreeMap<String, Vec<u64>>,
    /// On a `cloud-session` host, the config dirs the caller's repository rule
    /// gives this checkout's repository; `None` for every other launch.
    pub cloud_repo: Option<Vec<String>>,
}

/// Judge one row for `req`: the one limit every pick, handoff mark and
/// overseer mark is held to. The bound is the request's, or the
/// setting; a seat, an account the fleet's overseer or a provider's
/// `seat=1` row holds, keeps what its overseer needs to the reset: the
/// room left once the overseer's spend to the reset is charged beside the
/// lanes ([`Projection`]'s `kept`) is held to
/// `min(bound, 100 - AGENT_RUNTIME_CONTROLLER_HEADROOM_PCT)`, so a worker never spends
/// the room the overseer runs on or hands off at, unless the overseer
/// itself asks (`for_overseer`).
fn judge(
    row: &AccountRow,
    req: &PickRequest,
    facts: &FleetFacts,
    settings: &AccountSettings,
    today: &str,
    now: u64,
) -> Judged {
    let max = f64::from(req.bound().unwrap_or(settings.max_pct));
    let claims = facts.charges.get(&row.canon).copied().unwrap_or(0);
    // The lanes live at the reading's sample: the charged lanes that began
    // spending on the account at or before it. A reading with no sample
    // age (a provider's row) is one lane's.
    let sampled = match row.usage_age_s {
        None => 1,
        Some(age) => {
            let sample_at = now as f64 - age;
            facts.started.get(&row.canon).map_or(0, |starts| {
                starts.iter().filter(|s| **s as f64 <= sample_at).count()
            }) as u32
        }
    };
    let binding = lane_binding(row, req.model.as_deref(), req.binding_floor);
    let wall = binding.as_ref().map(|b| b.pct);
    let seat = !req.for_overseer
        && !matches!(row.harness, Harness::Copilot | Harness::Pi)
        && facts.seats.contains(&row.canon);
    let projection = binding.as_ref().map(|b| {
        projection(
            row,
            b,
            &Spenders {
                claims,
                sampled,
                candidate: req.launch(),
                seat,
            },
            f64::from(settings.burn_pct_per_hour),
            now,
        )
    });
    let judged_wall = if req.launch() {
        projection.as_ref().map(|p| 100.0 - p.headroom)
    } else {
        wall
    };
    let kept = projection.as_ref().map_or(0.0, |p| p.kept);
    let limit = if seat {
        max.min(100.0 - f64::from(settings.controller_headroom_pct))
    } else {
        max
    };
    let grant = grant(row, settings.cloud_credit_floor as f64, now);
    let reads = Reads::of(
        row,
        judged_wall,
        max,
        grant.as_ref(),
        settings.codex_credit_floor as f64,
    );
    let standing = standing_for(row, req, today);
    let credits = reads == Reads::Credits && standing == Standing::Open;
    let verdict = match standing {
        Standing::Reserved => "reserved",
        Standing::Retired { .. } => "retired",
        Standing::EndUnread { .. } => "plan-end-invalid",
        Standing::Open => match reads {
            Reads::Wall(_) if seat => match wall_verdict(judged_wall.map(|w| w + kept), limit) {
                "walled" => "seat-reserve",
                plan => plan,
            },
            Reads::PlanEnded | Reads::Grant(_) | Reads::Credits | Reads::Wall(_) => reads.verdict(),
        },
    };
    let verdict = match &facts.cloud_repo {
        Some(admitted) if !admitted.contains(&row.config_dir) => "cloud-repo-unset",
        Some(_) | None => verdict,
    };
    let score = if let Some(grant) = &grant {
        Some(grant.score)
    } else if credits {
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
            p.headroom * reset_bonus(hours)
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
        limit,
        credits,
        grant,
        score,
        qualifying: None,
    }
}

/// The verdict of an account a request's exclusion covers.
const EXCLUDED: &str = "excluded";

/// Whether `req` is a controller's question about one account by name: the
/// read of its own account at its trigger (`Caller::own_account`) and the
/// walk's keep of the caller's own account. A controller already running
/// on an account kept from workers may stay on it, so that question reads
/// the account's figures; every choice among accounts refuses it.
fn own_question(req: &PickRequest) -> bool {
    req.for_overseer && req.lane.is_some()
}

/// Whether `req` leaves the account out by name: `--exclude-lane`'s
/// directories, and the owner's exclusion, which keeps an account from
/// every pick but a controller's question about its own account.
fn left_out(row: &AccountRow, req: &PickRequest) -> bool {
    req.exclude.iter().any(|d| wall::canon(d) == row.canon) || (row.excluded && !own_question(req))
}

/// The account's standing for `req`: its word's, except that a
/// controller's question about its own account reads a provider's
/// reservation as no refusal, as it reads the owner's exclusion.
fn standing_for(row: &AccountRow, req: &PickRequest, today: &str) -> Standing {
    match row.standing(today) {
        Standing::Reserved if own_question(req) => Standing::Open,
        standing => standing,
    }
}

/// One named account judged for `req`: the judgement, its verdict
/// `excluded` where the request leaves the account out by name, whatever
/// was read of it. The one judgement a named pick answers and a supplied
/// batch reports per row.
pub fn judge_one(
    row: &AccountRow,
    req: &PickRequest,
    facts: &FleetFacts,
    settings: &AccountSettings,
    now: u64,
) -> Judged {
    let mut judged = judge(row, req, facts, settings, &today(now), now);
    if left_out(row, req) {
        judged.verdict = EXCLUDED.to_owned();
    }
    judged
}

/// The pick over `rows`: the candidates are the configured rows billed
/// under the launch's harness and spending its pool, the directories
/// `--exclude-lane` names and the accounts `AGENT_RUNTIME_ACCOUNT_EXCLUDE` names left
/// out; each is judged on its projected wall; the room rows are ordered a
/// seat last, then by tier (a grant first, plan windows, Codex credits
/// last), the grant's end, the score, fewer claims, more projected room
/// and the lower wall; the first is the lane. With `lane` named, that one
/// row is judged alone: one the exclusion covers is refused by its word,
/// `excluded`, as a retired one is, whatever was read of it; a Pi root on
/// a grant pool that no row holds is judged on the row nothing measured
/// ([`unmeasured_row`]), `unmeasured`; any other directory no row holds is
/// no record: [`pick_fleet`] measures a named directory that exists, so it
/// is one that does not.
pub fn pick(
    rows: &[AccountRow],
    req: &PickRequest,
    facts: &FleetFacts,
    settings: &AccountSettings,
    now: u64,
) -> PickAnswer {
    let today = today(now);
    let model = req.model.as_deref().unwrap_or("");
    let Some(billed) = req.harness.billed(model) else {
        return unbilled_answer(req);
    };
    let pool = req.harness.pool(model);
    let api_credit = pool == "api-credit";
    // A pool nobody measured is a read to repair, never a window to wait
    // out: the API grant's and the Pi Copilot pool's answer alike. A pool
    // whose every row was left out by name is a pool with no candidate.
    let grant_pool = api_credit || (req.harness == Harness::Pi && pool == "copilot");
    let rows = &resolve(rows, billed, model, req, now);
    let candidate =
        |r: &AccountRow| r.harness == billed && ((r.pool == "api-credit") == api_credit);
    if let Some(lane) = &req.lane {
        let canon = wall::canon(lane);
        let judged = match rows.iter().find(|r| r.canon == canon && candidate(r)) {
            Some(row) => judge_one(row, req, facts, settings, now),
            None if grant_pool => judge_one(
                &unmeasured_row(lane, pool, settings),
                req,
                facts,
                settings,
                now,
            ),
            None => return PickAnswer::NoRecord,
        };
        if judged.verdict == EXCLUDED {
            return PickAnswer::Excluded(judged);
        }
        return named_answer(judged, req, &today);
    }
    let candidates = rows.iter().filter(|r| candidate(r)).count();
    let judged: Vec<Judged> = rows
        .iter()
        .filter(|r| candidate(r) && r.configured && !left_out(r, req))
        .map(|r| judge(r, req, facts, settings, &today, now))
        .collect();
    let mut room: Vec<&Judged> = judged.iter().filter(|j| j.verdict == "room").collect();
    room.sort_by(|a, b| {
        let neg = |v: Option<f64>| v.map(|n| -n);
        let expires = |j: &Judged| j.grant.as_ref().and_then(|g| g.expires).unwrap_or(0);
        a.seat
            .cmp(&b.seat)
            .then(a.tier().cmp(&b.tier()))
            .then(expires(a).cmp(&expires(b)))
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
        let mut chosen = (*chosen).clone();
        chosen.qualifying = Some(room.len() as u32);
        return PickAnswer::Lane(chosen);
    }
    let walled: Vec<&Judged> = judged.iter().filter(|j| j.verdict == "walled").collect();
    let unmeasured = judged.iter().filter(|j| j.verdict == "unmeasured").count() as u32;
    if grant_pool && walled.is_empty() && (candidates == 0 || unmeasured > 0) {
        return PickAnswer::ProviderUnmeasured {
            harness: req.harness,
            model: model.to_owned(),
        };
    }
    PickAnswer::None {
        walled: walled.len() as u32,
        unmeasured,
        seats: judged
            .iter()
            .filter(|j| j.verdict == "seat-reserve")
            .cloned()
            .collect(),
        walled_resets_at: walled.iter().filter_map(|j| j.retry_at()).min(),
        refusals: judged
            .iter()
            .filter_map(|j| {
                let refusal = j.record().get("refusal")?.clone();
                Some((j.row.config_dir.clone(), refusal))
            })
            .collect(),
        exclusions: judged
            .iter()
            .filter(|j| j.verdict != "room")
            .map(|j| (j.row.config_dir.clone(), j.verdict.clone()))
            .collect(),
    }
}

/// A `--lane` pick's answer from its one judgement: the word's refusal
/// where the word refused it (an end nobody can read is no verdict, so it
/// is unjudged with the cause), else the windows' answer by
/// `lanes pick --lane`'s exits.
fn named_answer(judged: Judged, req: &PickRequest, today: &str) -> PickAnswer {
    match standing_for(&judged.row, req, today) {
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
            "cloud-repo-unset" => PickAnswer::CloudRepoUnset(judged),
            _ => PickAnswer::Walled(judged),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::Retirement;

    pub(super) fn settings() -> AccountSettings {
        AccountSettings {
            retire: vec![Retirement {
                name: "oldclaude".to_owned(),
                date: "2026-10-20".to_owned(),
            }],
            max_pct: 95,
            burn_pct_per_hour: 5,
            controller_headroom_pct: 5,
            codex_credit_floor: 5000,
            cloud_credit_floor: 10,
            copilot_pool: Vec::new(),
            exclude: Vec::new(),
            aliases: Vec::new(),
            account_dirs: Vec::new(),
            codex_home: None,
            usage_ttl: 300,
            usage_max_age: 0,
            claude_usage_url: String::new(),
            codex_usage_url: String::new(),
            claude_token_url: String::new(),
            claude_client_id: None,
        }
    }

    fn row(json: Value) -> AccountRow {
        AccountRow::parse(&json, &settings()).expect("a row")
    }

    #[test]
    fn the_billed_harness_and_pool_follow_the_launchers_tables() {
        use Harness::{Claude, Codex, Copilot, Pi};
        let rows = [
            (Claude, "claude-sonnet-5", Some(Claude), "plan"),
            (Codex, "-", Some(Codex), "plan"),
            (Copilot, "-", Some(Copilot), "copilot"),
            (Pi, "pi-claude/opus", Some(Claude), "plan"),
            (Pi, "github-copilot/gpt", Some(Pi), "copilot"),
            (Pi, "anthropic/claude", Some(Pi), "api-credit"),
            (Pi, "other/model", None, "plan"),
        ];
        for (harness, model, billed, pool) in rows {
            assert_eq!(harness.billed(model), billed, "{harness} {model}");
            assert_eq!(harness.pool(model), pool, "{harness} {model}");
        }
    }

    /// The machine's stated end is matched on the alias, the directory name
    /// or that name without its dot, and the provider's words are read from
    /// the row.
    #[test]
    fn the_words_are_matched_onto_the_rows_and_said_on_the_roster_lines() {
        let roster = Roster {
            rows: [
                json!({"alias":"a","harness":"claude","config_dir":"/h/.a","measured_through":"local","status":"ok","verdict":"room","headroom_pct":0,"binding_bucket":"weekly","binding_resets_at":"2026-10-01T00:00:00Z"}),
                json!({"alias":"oldclaude","harness":"claude","config_dir":"/h/.oldclaude","measured_through":"local","status":"ok","verdict":"room","headroom_pct":40,"binding_bucket":"weekly","binding_resets_at":null}),
                json!({"alias":"r","harness":"claude","config_dir":"/h/.r","measured_through":"host","status":"ok","verdict":"room","headroom_pct":90,"binding_bucket":"weekly","binding_resets_at":null,"reserved":1,"seat":"1","plan-ends":"2026-12-01"}),
            ]
            .into_iter()
            .map(row)
            .collect(),
            provider_failure: None,
            notes: Vec::new(),
        };
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
        assert!(roster.bills(Harness::Claude, "plan"));
        assert!(!roster.bills(Harness::Codex, "plan"));
        assert!(!roster.bills(Harness::Claude, "api-credit"));
        // The stated end come and the credential still answering: the
        // contradiction line under the roster, and the account not picked.
        let lines = roster.lines("2026-10-20");
        assert_eq!(
            lines.last().map(String::as_str),
            Some(
                "account-end-contradicted oldclaude config_dir=/h/.oldclaude ends=2026-10-20 source=AGENT_RUNTIME_ACCOUNT_RETIRE status=ok"
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
        let binding =
            |model: Option<&str>| lane_binding(&r, model, false).map(|b| (b.bucket, b.pct));
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
            lane_binding(&shared_only, Some("sonnet"), false).map(|b| (b.bucket, b.pct)),
            Some(("weekly".to_owned(), 30.0))
        );
        let unmeasured = row(json!({
            "alias": "c", "harness": "claude", "config_dir": "/h/.c", "measured_through": "local",
            "status": "unreachable", "verdict": "unmeasured", "headroom_pct": null
        }));
        assert_eq!(lane_binding(&unmeasured, Some("sonnet"), false), None);
        let ended = row(json!({
            "alias": "d", "harness": "claude", "config_dir": "/h/.d", "measured_through": "local",
            "status": "plan_ended", "verdict": "walled", "headroom_pct": 0
        }));
        assert_eq!(
            lane_binding(&ended, Some("sonnet"), false).map(|b| (b.bucket, b.pct)),
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
