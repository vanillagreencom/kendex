//! The one settings reader: a project's `[env]` tables, its private env
//! file and the caller's environment, layered the way the shell store loads
//! them, read as data and never run; and the two key blocks this package
//! owns, the account readers' and the engine's.
//!
//! Precedence, highest first: the caller's own environment, the private env
//! file (`.env.local`, or the file `KENDEX_ENV_FILE` names, skipped under
//! `--no-private-env`), `.kendex/settings.toml`, then
//! `kendex.settings.toml`. An empty value is an unset one, as a shell
//! `${KEY:-default}` read takes it.
//!
//! The settings files follow the kendex `[env]` contract the shell loader
//! holds them to: `[env]` assignments of single-line basic strings with no
//! `"` or `\`, or literal strings with no apostrophe, an optional trailing
//! `#` comment, a duplicate key refused, a `[`-led line a lone `[name]`
//! header or refused, a leading byte-order mark refused. The private env
//! file is shell to the loader that sources it; here it is read and never
//! run, one assignment line at a time, `KEY=VALUE` with an optional leading
//! `export`. A key's value is read as the sourcing shell assigns it in the
//! forms [`decode_account_value`] names. Any other form of a key only some
//! verbs read is passed over and named; of a key [`Keys::load`] lists it
//! refuses, since reading past it would take the shell's value for
//! another. A line of any other shape assigns nothing here.
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::Harness;
use crate::error::{Error, Result};
use crate::host;
use crate::launch::{Permission, QuestionTool};

/// The settings key naming the project's private env file.
pub const ENV_FILE_KEY: &str = "KENDEX_ENV_FILE";
/// The private env file read when the project names none.
pub const DEFAULT_ENV_FILE: &str = ".env.local";
/// The settings files in loading order; a later file outranks an earlier.
pub const SETTINGS_FILES: [&str; 2] = ["kendex.settings.toml", ".kendex/settings.toml"];
/// The home the private env file's home forms and a relative account
/// directory are read under.
pub const HOME_KEY: &str = "HOME";
const GIT_TIMEOUT: Duration = Duration::from_secs(15);

// The engine's keys.
/// The tmux session every harness window opens in.
pub const TMUX_SESSION_KEY: &str = "AGENT_RUNTIME_TMUX_SESSION";
/// Seconds a launch waits for the harness to come up at its composer.
pub const VERIFY_SECS_KEY: &str = "AGENT_RUNTIME_TMUX_VERIFY_SECS";
/// Seconds a transfer's or a stop's caller waits for its detached job to
/// claim the intent: the claim's own bound, apart from the tmux
/// verification bound a test shortens to force a failed delivery.
pub const JOB_CLAIM_SECS_KEY: &str = "AGENT_RUNTIME_JOB_CLAIM_SECS";
/// Whether a launched controller keeps the harness's question dialog.
pub const QUESTION_TOOL_KEY: &str = "AGENT_RUNTIME_QUESTION_TOOL";
/// The permission posture every launch runs under: `bypass`, the
/// unattended default, or `native`, the harness's own prompts.
pub const LAUNCH_PERMISSION_KEY: &str = "AGENT_RUNTIME_LAUNCH_PERMISSION";
/// Where a harness executable is installed when not on `PATH`, as
/// `harness=/absolute/path` pairs separated by commas.
pub const HARNESS_BINARIES_KEY: &str = "AGENT_RUNTIME_HARNESS_BINARIES";
/// Whether a controller may ask for its own succession: `on`, the default,
/// or `off`, under which `request-transfer` refuses before any intent
/// persists.
pub const SUCCESSION_KEY: &str = "AGENT_RUNTIME_CONTROLLER_SUCCESSION";
/// The `harness:model:effort` entries a succession walks for the
/// successor; a controller's mark line names its value.
pub const CONTROLLER_PREFERENCE_KEY: &str = "AGENT_RUNTIME_CONTROLLER_PREFERENCE";
/// The standard class on each harness.
pub const DEFAULT_CONTROLLER_PREFERENCE: &str = "claude:standard:high,codex:standard:high";
const DEFAULT_VERIFY_SECS: u64 = 15;
const DEFAULT_CLAIM_SECS: u64 = 15;

/// The engine's keys, read from the private env file.
pub const ENGINE_KEYS: &[&str] = &[
    TMUX_SESSION_KEY,
    VERIFY_SECS_KEY,
    JOB_CLAIM_SECS_KEY,
    QUESTION_TOOL_KEY,
    LAUNCH_PERMISSION_KEY,
    HARNESS_BINARIES_KEY,
    SUCCESSION_KEY,
    CONTROLLER_PREFERENCE_KEY,
    ACCOUNT_STATE_DIR_KEY,
];

// The account readers' keys.
/// A providerless machine's own statement of a plan's end, `<name>=<YYYY-
/// MM-DD>` pairs: the account is picked until that UTC day and measured
/// after it, so a stated end a live reading contradicts is seen. The judge
/// reads it; the account reader is run with it emptied, so it measures the
/// account instead of listing it `retired` unread.
pub const ACCOUNT_RETIRE_KEY: &str = "AGENT_RUNTIME_ACCOUNT_RETIRE";
/// The bound a pick admits an account under, in percent used.
pub const ACCOUNT_MAX_PCT_KEY: &str = "AGENT_RUNTIME_ACCOUNT_MAX_PCT";
/// A live session's hourly spend where its account measured no rate, in
/// points of five hours' room: a week is charged 5/168 of it an hour, a
/// month 5/720.
pub const ACCOUNT_BURN_PCT_KEY: &str = "AGENT_RUNTIME_ACCOUNT_BURN_PCT_PER_HOUR";
/// The account headroom a controller hands off at, and so the room a seat
/// keeps for it: a worker's pick holds a seat to `min(max pct, 100 -
/// this)`.
pub const CONTROLLER_HEADROOM_PCT_KEY: &str = "AGENT_RUNTIME_CONTROLLER_HEADROOM_PCT";
/// The Codex credit balance a window wall is lifted above.
pub const CODEX_CREDIT_FLOOR_KEY: &str = "AGENT_RUNTIME_CODEX_CREDIT_FLOOR";
/// The dollars a cloud or API credit grant must exceed to be picked.
pub const CLOUD_CREDIT_FLOOR_KEY: &str = "AGENT_RUNTIME_CLOUD_CREDIT_FLOOR";
/// `<pi root>=<used>/<granted>` pairs: the Copilot pool each Pi root
/// spends, as the owner states it, judged where neither the root's own
/// Copilot login nor a provider row reads it.
pub const COPILOT_POOL_KEY: &str = "AGENT_RUNTIME_COPILOT_POOL";
/// The account names the reader never reads, applied here to the stated
/// Pi roots alone, which no reader lists.
pub const ACCOUNT_EXCLUDE_KEY: &str = "AGENT_RUNTIME_ACCOUNT_EXCLUDE";
/// `<discovered name>=<alias>` pairs, the owner's names over the discovered
/// ones, read here for the stated Pi roots alone: the reader names every
/// row it lists through it and matches an exclusion or a retirement
/// through that name.
pub const ACCOUNT_ALIASES_KEY: &str = "AGENT_RUNTIME_ACCOUNT_ALIASES";
/// Colon-separated config directories, each an account of the harness
/// whose credential it holds: the accounts the chooser picks among, an
/// entry relative to `HOME` resolved under it. Unset, none is.
pub const ACCOUNT_DIRS_KEY: &str = "AGENT_RUNTIME_ACCOUNT_DIRS";
/// A Codex home the CLI reads, measured as the account it names and never
/// a candidate.
pub const CODEX_HOME_KEY: &str = "CODEX_HOME";
/// Seconds a cached usage figure is served within; 0 declines every
/// cached figure. The default outlasts the longest watch interval, since a
/// window under it has every pass find the figure expired and post again.
pub const USAGE_TTL_KEY: &str = "AGENT_RUNTIME_USAGE_TTL";
/// A caller's own pass interval, which widens the window and never
/// narrows it.
pub const USAGE_MAX_AGE_KEY: &str = "AGENT_RUNTIME_USAGE_MAX_AGE";
/// The usage endpoints, for a host that reaches them through another
/// address.
pub const CLAUDE_USAGE_URL_KEY: &str = "AGENT_RUNTIME_CLAUDE_USAGE_URL";
pub const CODEX_USAGE_URL_KEY: &str = "AGENT_RUNTIME_CODEX_USAGE_URL";
/// The Claude token endpoint a renewal posts its refresh-token grant to,
/// and the OAuth client id it posts with; with no client id every expired
/// Claude account reads `error` naming the key.
pub const CLAUDE_TOKEN_URL_KEY: &str = "AGENT_RUNTIME_CLAUDE_TOKEN_URL";
pub const CLAUDE_CLIENT_ID_KEY: &str = "AGENT_RUNTIME_CLAUDE_CLIENT_ID";
/// The account records' root: the usage cache under `usage/` and the wall
/// records under `walls/`, one of each per account on the machine whoever
/// reads it. An absolute or `~/` value; a relative one is refused, since it
/// would make a root per checkout again.
pub const ACCOUNT_STATE_DIR_KEY: &str = "AGENT_RUNTIME_ACCOUNT_STATE_DIR";
/// The base directory the default root sits under, where absolute.
const STATE_HOME_KEY: &str = "XDG_STATE_HOME";
const DEFAULT_USAGE_TTL: u64 = 300;
const CLAUDE_USAGE_URL_DEFAULT: &str = "https://api.anthropic.com/api/oauth/usage";
const CODEX_USAGE_URL_DEFAULT: &str = "https://chatgpt.com/backend-api/wham/usage";
const CLAUDE_TOKEN_URL_DEFAULT: &str = "https://platform.claude.com/v1/oauth/token";
const DEFAULT_ACCOUNT_MAX_PCT: u32 = 95;
const DEFAULT_ACCOUNT_BURN_PCT: u32 = 5;
const DEFAULT_CONTROLLER_HEADROOM_PCT: u32 = 5;
const DEFAULT_CODEX_CREDIT_FLOOR: u64 = 5000;
const DEFAULT_CLOUD_CREDIT_FLOOR: u64 = 10;

/// The account readers' keys (the listing, the renewal and the judge), read
/// from the private env file. A spelling of one that only a shell reads is
/// passed over and named, never refused: an operator wrote these for a
/// loader that sourced the file, so such a line stays the shell's, as a key
/// no reader reads does.
pub const ACCOUNT_KEYS: &[&str] = &[
    ACCOUNT_RETIRE_KEY,
    COPILOT_POOL_KEY,
    ACCOUNT_EXCLUDE_KEY,
    ACCOUNT_ALIASES_KEY,
    ACCOUNT_MAX_PCT_KEY,
    ACCOUNT_BURN_PCT_KEY,
    CONTROLLER_HEADROOM_PCT_KEY,
    CODEX_CREDIT_FLOOR_KEY,
    CLOUD_CREDIT_FLOOR_KEY,
    HOME_KEY,
    ACCOUNT_DIRS_KEY,
    CODEX_HOME_KEY,
    USAGE_TTL_KEY,
    USAGE_MAX_AGE_KEY,
    CLAUDE_USAGE_URL_KEY,
    CODEX_USAGE_URL_KEY,
    CLAUDE_TOKEN_URL_KEY,
    CLAUDE_CLIENT_ID_KEY,
    ACCOUNT_STATE_DIR_KEY,
];

/// The keys a caller reads from the private env file. A line of a key of
/// `read` in a form only a shell reads is passed over and named, so a value
/// only some verbs read never refuses every verb; of a key of `load`, which
/// every verb needs, it refuses the load. Under `--no-private-env` the
/// settings files still give the `load` keys and no other.
#[derive(Debug, Clone, Copy)]
pub struct Keys<'a> {
    pub read: &'a [&'a [&'a str]],
    pub load: &'a [&'a str],
}

impl Keys<'_> {
    fn reads(&self, key: &str) -> bool {
        self.load.contains(&key) || self.read.iter().any(|block| block.contains(&key))
    }
}

/// The checkout the settings belong to: the toplevel of the directory the
/// runtime runs in, and the main checkout a relative state directory is
/// resolved against (a linked worktree keeps its state beside the main
/// checkout's).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Roots {
    pub project: PathBuf,
    pub common: PathBuf,
}

/// Which question dialog setting a launched controller runs under.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QuestionToolSetting {
    Off,
    Overseer,
}

impl QuestionToolSetting {
    /// The intent a controller launch carries; a worker never keeps the
    /// dialog, whatever the setting says.
    pub fn for_controller(self) -> QuestionTool {
        match self {
            QuestionToolSetting::Off => QuestionTool::Off,
            QuestionToolSetting::Overseer => QuestionTool::Keep,
        }
    }
}

/// Whether a controller may ask for its own succession.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Succession {
    On,
    Off,
}

impl Succession {
    /// The setting's word, as a mark line's `succession=` field prints it.
    pub fn word(self) -> &'static str {
        match self {
            Succession::On => "on",
            Succession::Off => "off",
        }
    }
}

/// The engine's settings: the session a window opens in, the launch's
/// bounds and binaries, the detached job's claim bound, and the account
/// records' root a published or adopted controller's seat is recorded
/// under.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineSettings {
    pub tmux_session: Option<String>,
    pub verify: Judged<Duration>,
    pub claim: Judged<Duration>,
    pub harness_binaries: Judged<BTreeMap<Harness, PathBuf>>,
    pub account_state: Judged<PathBuf>,
}

impl EngineSettings {
    pub fn read(values: &Layered) -> EngineSettings {
        EngineSettings {
            tmux_session: values.get(TMUX_SESSION_KEY).map(str::to_owned),
            verify: values.secs(VERIFY_SECS_KEY, DEFAULT_VERIFY_SECS),
            claim: values.secs(JOB_CLAIM_SECS_KEY, DEFAULT_CLAIM_SECS),
            harness_binaries: Judged::of(
                HARNESS_BINARIES_KEY,
                match values.get(HARNESS_BINARIES_KEY) {
                    None => Ok(BTreeMap::new()),
                    Some(text) => harness_binaries(text).ok_or(text),
                },
            ),
            account_state: account_state_dir(values),
        }
    }
}

/// The launch's posture, which every launch reads, a lane's and a
/// controller's: `bypass`, or `native` with the caller's own words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchSettings {
    pub permission: Judged<Permission>,
}

impl LaunchSettings {
    pub fn read(values: &Layered) -> LaunchSettings {
        LaunchSettings {
            permission: Judged::word(
                LAUNCH_PERMISSION_KEY,
                values.get(LAUNCH_PERMISSION_KEY),
                &[
                    ("bypass", Permission::Bypass),
                    ("native", Permission::Native),
                ],
            ),
        }
    }
}

/// The hand-over's settings: a controller launch's question dialog, the
/// switch a succession is asked under, and the preference the successor
/// walk takes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControllerSettings {
    pub question_tool: Judged<QuestionToolSetting>,
    pub succession: Judged<Succession>,
    /// The succession's preference entries; an empty value reads as the
    /// default, as this reader takes every key.
    pub preference: String,
    /// Whether the setting names the succession's preference, an empty
    /// value included: unset, a context mark's succession walks the
    /// controller's own entry alone, since a context handoff replaces the
    /// session and not its harness or model.
    pub preference_set: bool,
}

impl ControllerSettings {
    pub fn read(values: &Layered) -> ControllerSettings {
        ControllerSettings {
            question_tool: Judged::word(
                QUESTION_TOOL_KEY,
                values.get(QUESTION_TOOL_KEY),
                &[
                    ("off", QuestionToolSetting::Off),
                    ("overseer", QuestionToolSetting::Overseer),
                ],
            ),
            succession: Judged::word(
                SUCCESSION_KEY,
                values.get(SUCCESSION_KEY),
                &[("on", Succession::On), ("off", Succession::Off)],
            ),
            // A preference set empty names no entry, which the controller
            // launch refuses; unset is the default.
            preference: values
                .raw(CONTROLLER_PREFERENCE_KEY)
                .unwrap_or(DEFAULT_CONTROLLER_PREFERENCE)
                .to_owned(),
            preference_set: values.raw(CONTROLLER_PREFERENCE_KEY).is_some(),
        }
    }
}

/// `harness=/absolute/path` pairs separated by commas, one per harness;
/// `None` is any other shape.
fn harness_binaries(text: &str) -> Option<BTreeMap<Harness, PathBuf>> {
    let mut binaries = BTreeMap::new();
    for pair in text.split(',') {
        let (name, path) = pair.trim().split_once('=')?;
        let harness = Harness::parse(name.trim())?;
        let path = PathBuf::from(path.trim());
        if !path.is_absolute() || binaries.insert(harness, path).is_some() {
            return None;
        }
    }
    Some(binaries)
}

/// One stated retirement, `<name>=<YYYY-MM-DD>`: the account whose
/// alias or directory name is `name` ends its plan on that UTC day.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Retirement {
    pub name: String,
    pub date: String,
}

/// What the accounts judge reads beside the listing: the local retirement
/// statement and the pick's bounds, each its default where unset, refused
/// by key and value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountSettings {
    pub retire: Vec<Retirement>,
    pub max_pct: u32,
    pub burn_pct_per_hour: u32,
    pub controller_headroom_pct: u32,
    pub codex_credit_floor: u64,
    pub cloud_credit_floor: u64,
    /// The Copilot pool each Pi root spends, as the owner states it.
    pub copilot_pool: Vec<CopilotPool>,
    /// The excluded names, applied to the stated Pi roots alone: the
    /// reader applies the setting to every row it lists.
    pub exclude: Vec<String>,
    /// The aliases, read for the stated Pi roots alone: the reader names
    /// every row it lists through them.
    pub aliases: Vec<Alias>,
    pub account_dirs: Vec<String>,
    pub codex_home: Option<String>,
    pub usage_ttl: u64,
    pub usage_max_age: u64,
    pub claude_usage_url: String,
    pub codex_usage_url: String,
    pub claude_token_url: String,
    pub claude_client_id: Option<String>,
}

/// One copilot pool entry, `<pi root>=<used>/<granted>`: the Copilot pool
/// the Pi root at `dir` spends, `used` of `granted` credits spent, as the
/// owner states it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CopilotPool {
    pub dir: String,
    pub used: u64,
    pub granted: u64,
}

/// One alias entry, `<name>=<alias>`: the account whose directory name is
/// `name`, with or without its dot, is called `alias`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Alias {
    pub name: String,
    pub alias: String,
}

impl AccountSettings {
    /// The account keys, judged together since every entry of the judge
    /// reads them: a retirement names an account (no `/`, no `~`) and a
    /// real calendar day; a percentage is a whole number 0 to 100; a value
    /// nobody can read is refused, never defaulted.
    pub fn read(values: &Layered) -> Judged<AccountSettings> {
        let get = |key: &str| values.get(key);
        Judged {
            read: (|| {
                let mut retire = Vec::new();
                for item in list(get(ACCOUNT_RETIRE_KEY)) {
                    let valid = item.split_once('=').filter(|(name, date)| {
                        account_name_valid(name.trim()) && calendar_date_valid(date.trim())
                    });
                    let Some((name, date)) = valid else {
                        return Err((ACCOUNT_RETIRE_KEY, item.to_owned()));
                    };
                    retire.push(Retirement {
                        name: name.trim().to_owned(),
                        date: date.trim().to_owned(),
                    });
                }
                // An absolute Pi root, the credits used and granted as whole
                // numbers of at most twelve digits, the grant above zero, one
                // entry per root; an entry nobody can read is refused, never
                // dropped, since a reading nobody can parse is not judged as
                // room.
                let mut copilot_pool: Vec<CopilotPool> = Vec::new();
                for item in list(get(COPILOT_POOL_KEY)) {
                    let whole = |s: &str| {
                        (1..=12).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_digit())
                    };
                    let entry = item.rsplit_once('=').and_then(|(dir, value)| {
                        let dir = dir.trim().trim_end_matches('/');
                        let (used, granted) = value.trim().split_once('/')?;
                        (dir.starts_with('/') && whole(used) && whole(granted)).then(|| {
                            CopilotPool {
                                dir: dir.to_owned(),
                                used: used.parse().unwrap_or(0),
                                granted: granted.parse().unwrap_or(0),
                            }
                        })
                    });
                    let Some(entry) = entry.filter(|e| e.granted > 0) else {
                        return Err((COPILOT_POOL_KEY, item.to_owned()));
                    };
                    if copilot_pool.iter().any(|e| e.dir == entry.dir) {
                        return Err((COPILOT_POOL_KEY, item.to_owned()));
                    }
                    copilot_pool.push(entry);
                }
                // An exclusion names accounts, never paths.
                let mut exclude = Vec::new();
                for item in list(get(ACCOUNT_EXCLUDE_KEY)) {
                    if !account_name_valid(item) {
                        return Err((ACCOUNT_EXCLUDE_KEY, item.to_owned()));
                    }
                    exclude.push(item.to_owned());
                }
                // An item without `=` or with an empty side is passed over,
                // never refused.
                let mut aliases = Vec::new();
                for item in list(get(ACCOUNT_ALIASES_KEY)) {
                    let Some((name, alias)) = item.split_once('=') else {
                        continue;
                    };
                    let (name, alias) = (name.trim(), alias.trim());
                    if name.is_empty() || alias.is_empty() {
                        continue;
                    }
                    aliases.push(Alias {
                        name: name.to_owned(),
                        alias: alias.to_owned(),
                    });
                }
                Ok(AccountSettings {
                    retire,
                    max_pct: values
                        .pct(ACCOUNT_MAX_PCT_KEY, DEFAULT_ACCOUNT_MAX_PCT)
                        .read?,
                    burn_pct_per_hour: values
                        .pct(ACCOUNT_BURN_PCT_KEY, DEFAULT_ACCOUNT_BURN_PCT)
                        .read?,
                    controller_headroom_pct: values
                        .pct(CONTROLLER_HEADROOM_PCT_KEY, DEFAULT_CONTROLLER_HEADROOM_PCT)
                        .read?,
                    codex_credit_floor: values
                        .whole(CODEX_CREDIT_FLOOR_KEY, DEFAULT_CODEX_CREDIT_FLOOR)
                        .read?,
                    cloud_credit_floor: values
                        .whole(CLOUD_CREDIT_FLOOR_KEY, DEFAULT_CLOUD_CREDIT_FLOOR)
                        .read?,
                    copilot_pool,
                    exclude,
                    aliases,
                    account_dirs: get(ACCOUNT_DIRS_KEY)
                        .unwrap_or_default()
                        .split(':')
                        .filter(|d| !d.is_empty())
                        .map(str::to_owned)
                        .collect(),
                    codex_home: get(CODEX_HOME_KEY).map(str::to_owned),
                    usage_ttl: values.whole(USAGE_TTL_KEY, DEFAULT_USAGE_TTL).read?,
                    usage_max_age: values.whole(USAGE_MAX_AGE_KEY, 0).read?,
                    claude_usage_url: get(CLAUDE_USAGE_URL_KEY)
                        .unwrap_or(CLAUDE_USAGE_URL_DEFAULT)
                        .to_owned(),
                    codex_usage_url: get(CODEX_USAGE_URL_KEY)
                        .unwrap_or(CODEX_USAGE_URL_DEFAULT)
                        .to_owned(),
                    claude_token_url: get(CLAUDE_TOKEN_URL_KEY)
                        .unwrap_or(CLAUDE_TOKEN_URL_DEFAULT)
                        .to_owned(),
                    claude_client_id: get(CLAUDE_CLIENT_ID_KEY).map(str::to_owned),
                })
            })(),
        }
    }
}

/// The account records' root ([`ACCOUNT_STATE_DIR_KEY`]): the setting,
/// `~/` read under `HOME`; unset, `kendex/agent-runtime/accounts` under
/// `XDG_STATE_HOME` where that is absolute, else under `~/.local/state`.
/// A relative value, or a home form with no home to read, is refused.
pub fn account_state_dir(values: &Layered) -> Judged<PathBuf> {
    let home = values.get(HOME_KEY).map(Path::new);
    let read = match values.get(ACCOUNT_STATE_DIR_KEY) {
        Some(text) => match text.strip_prefix("~/") {
            Some(rest) => home.map(|h| h.join(rest)).ok_or(text),
            None if Path::new(text).is_absolute() => Ok(PathBuf::from(text)),
            None => Err(text),
        },
        None => values
            .get(STATE_HOME_KEY)
            .map(PathBuf::from)
            .filter(|base| base.is_absolute())
            .or_else(|| home.map(|h| h.join(".local/state")))
            .map(|base| base.join("kendex/agent-runtime/accounts"))
            .ok_or(""),
    };
    Judged::of(ACCOUNT_STATE_DIR_KEY, read)
}

/// A comma list's items, trimmed, the empty ones dropped.
fn list(text: Option<&str>) -> impl Iterator<Item = &str> {
    text.unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|i| !i.is_empty())
}

/// The one grammar of a name that stands for an account in a setting (an
/// exclusion, a retirement, a cloud repository): a directory name or an
/// alias, never empty; a `/` or a `~` makes it a path, which names no
/// account, so a statement written that way would cover nothing.
pub fn account_name_valid(name: &str) -> bool {
    !name.is_empty() && !name.contains('/') && !name.contains('~')
}

/// Whether `text` is a `YYYY-MM-DD` naming a real calendar day, by
/// arithmetic.
pub fn calendar_date_valid(text: &str) -> bool {
    let bytes = text.as_bytes();
    if bytes.len() != 10
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || !bytes
            .iter()
            .enumerate()
            .all(|(i, b)| i == 4 || i == 7 || b.is_ascii_digit())
    {
        return false;
    }
    let (Ok(y), Ok(m), Ok(d)) = (
        text[0..4].parse::<u32>(),
        text[5..7].parse::<u32>(),
        text[8..10].parse::<u32>(),
    ) else {
        return false;
    };
    let days = match m {
        4 | 6 | 9 | 11 => 30,
        2 if y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) => 29,
        2 => 28,
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        _ => return false,
    };
    (1..=days).contains(&d)
}

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    Error::refused(key, fields)
}

fn file_refusal(path: &Path, key: &str, reason: &str) -> Error {
    refused(
        "settings-invalid",
        &[
            ("path", &path.display().to_string()),
            ("key", key),
            ("reason", reason),
        ],
    )
}

pub fn value_refusal(key: &str, value: &str) -> Error {
    refused("setting-invalid", &[("key", key), ("value", value)])
}

/// A key only some verbs read: the key's one parse ran in the load, and its
/// answer waits here, so a value outside its form refuses the verb that
/// reads it and no other.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Judged<T> {
    /// The value, or the key and the text it refused.
    pub read: std::result::Result<T, (&'static str, String)>,
}

impl<T: Clone> Judged<T> {
    pub fn of(key: &'static str, read: std::result::Result<T, &str>) -> Judged<T> {
        Judged {
            read: read.map_err(|text| (key, text.to_owned())),
        }
    }

    /// A key read as one of its words, unset the first word's value.
    pub fn word(key: &'static str, text: Option<&str>, words: &[(&str, T)]) -> Judged<T> {
        let read = match text {
            None => Ok(words[0].1.clone()),
            Some(text) => words
                .iter()
                .find(|(word, _)| *word == text)
                .map(|(_, value)| value.clone())
                .ok_or(text),
        };
        Judged::of(key, read)
    }

    /// The value, or `setting-invalid` naming the key and the text refused.
    pub fn get(&self) -> Result<T> {
        self.read
            .clone()
            .map_err(|(key, value)| value_refusal(key, &value))
    }
}

/// The values the ladder resolved, each key's highest rung, and the keys
/// whose private env file line it passed over in a form only a shell reads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Layered {
    values: BTreeMap<String, String>,
    /// The private env file read and the keys whose line it passed over.
    pub passed_over: Option<(PathBuf, Vec<String>)>,
}

impl Layered {
    /// A key's value; an empty value is an unset one.
    pub fn get(&self, key: &str) -> Option<&str> {
        self.values
            .get(key)
            .filter(|v| !v.is_empty())
            .map(String::as_str)
    }

    /// A key's value as set, an empty value kept, for a key whose empty
    /// value says something its unset value does not.
    pub fn raw(&self, key: &str) -> Option<&str> {
        self.values.get(key).map(String::as_str)
    }

    /// Whole seconds above zero, base ten with no sign and no leading zero.
    pub fn secs(&self, key: &'static str, default: u64) -> Judged<Duration> {
        Judged::of(
            key,
            match self.get(key) {
                None => Ok(Duration::from_secs(default)),
                Some(text) => match text.parse::<u64>() {
                    Ok(n) if n > 0 && !text.starts_with('0') && !text.starts_with('+') => {
                        Ok(Duration::from_secs(n))
                    }
                    Ok(_) | Err(_) => Err(text),
                },
            },
        )
    }

    /// A percentage, a whole number 0 to 100 of at most three digits.
    pub fn pct(&self, key: &'static str, default: u32) -> Judged<u32> {
        Judged::of(
            key,
            match self.get(key) {
                None => Ok(default),
                Some(text) => match text.parse::<u32>() {
                    Ok(n)
                        if n <= 100
                            && text.len() <= 3
                            && text.bytes().all(|b| b.is_ascii_digit()) =>
                    {
                        Ok(n)
                    }
                    Ok(_) | Err(_) => Err(text),
                },
            },
        )
    }

    /// A whole number from zero, digits alone.
    pub fn whole(&self, key: &'static str, default: u64) -> Judged<u64> {
        Judged::of(
            key,
            match self.get(key) {
                None => Ok(default),
                Some(text) => match text.parse::<u64>() {
                    Ok(n) if text.bytes().all(|b| b.is_ascii_digit()) => Ok(n),
                    Ok(_) | Err(_) => Err(text),
                },
            },
        )
    }
}

/// The ladder for a checkout at `project`: the settings files, the private
/// env file where `private_env` holds, and the caller's `environment` over
/// all. Under `--no-private-env` the shell loader takes the keys of
/// [`Keys::load`] alone from the files, the later file outranking the
/// earlier and both outranking the caller's environment, and reads no other
/// key from them; every other key comes from the caller's environment.
pub fn layered(
    project: &Path,
    environment: &[(OsString, OsString)],
    private_env: bool,
    keys: &Keys,
) -> Result<Layered> {
    let caller: BTreeMap<String, String> = environment
        .iter()
        .filter_map(|(k, v)| Some((k.to_str()?.to_owned(), v.to_str()?.to_owned())))
        .collect();
    let disk = |path: &Path| read_text(path);
    let rung = file_rung(
        project,
        &disk,
        private_env.then(|| {
            (
                caller.get(ENV_FILE_KEY).map(String::as_str),
                caller.get(HOME_KEY).map(String::as_str),
            )
        }),
        true,
        keys,
    )?;
    let mut values: BTreeMap<String, String> = BTreeMap::new();
    let Some((path, private)) = rung.private else {
        values.extend(caller);
        for key in keys.load {
            if let Some(value) = rung.values.get(*key) {
                values.insert((*key).to_owned(), value.clone());
            }
        }
        return Ok(Layered {
            values,
            passed_over: None,
        });
    };
    values.extend(rung.values);
    values.extend(private.values);
    values.extend(caller);
    Ok(Layered {
        values,
        passed_over: Some((path, private.passed_over)),
    })
}

/// The checkout roots for `cwd`, read from git through the one runner. A
/// directory outside any repository is its own root, as the shell
/// `git rev-parse --show-toplevel || pwd` takes it.
pub fn roots(cwd: &Path) -> Result<Roots> {
    let cwd_text = cwd.display().to_string();
    let Some(toplevel) = git_line(&cwd_text, "toplevel", &["--show-toplevel"])? else {
        return Ok(Roots {
            project: cwd.to_path_buf(),
            common: cwd.to_path_buf(),
        });
    };
    let project = PathBuf::from(toplevel);
    let common_dir = git_line(&cwd_text, "common-dir", &["--git-common-dir"])?
        .map(PathBuf::from)
        .unwrap_or_else(|| project.join(".git"));
    // As the mailbox's common root: a common dir named `.git` is a
    // checkout's own, whose parent is the main checkout; anything else is
    // this toplevel.
    let common = if common_dir.file_name().is_some_and(|n| n == ".git") {
        let git_dir = if common_dir.is_absolute() {
            common_dir
        } else {
            cwd.join(common_dir)
        };
        let parent = git_dir.parent().unwrap_or(&git_dir);
        fs::canonicalize(parent).map_err(|e| Error::io("resolve", parent, e))?
    } else {
        project.clone()
    };
    Ok(Roots { project, common })
}

/// One line of `git -C cwd rev-parse ARG`, or `None` where `cwd` is in no
/// repository, git's one answer this reads as an absence.
#[allow(
    clippy::disallowed_methods,
    reason = "the settings reader runs git for the checkout roots it resolves, no effect on a session"
)]
fn git_line(cwd: &str, operation: &'static str, args: &[&str]) -> Result<Option<String>> {
    let mut full = vec!["-C", cwd, "rev-parse"];
    full.extend_from_slice(args);
    // git's "not a git repository" is read by its words, which a translated
    // git words otherwise: the C locale outranks `LANGUAGE` too.
    let c_locale = [("LC_ALL", std::ffi::OsStr::new("C"))];
    let output = host::run_tagged_in(
        "settings",
        "git",
        Path::new("git"),
        operation,
        &full,
        host::Place {
            cwd: None,
            env: &c_locale,
        },
        GIT_TIMEOUT,
    )?;
    if output.status.success() {
        return Ok(Some(host::stdout_text(&output)));
    }
    let err = host::stderr_text(&output);
    if err.starts_with("fatal: not a git repository") {
        return Ok(None);
    }
    Err(Error::External {
        program: "git",
        operation,
        cause: err,
    })
}

/// A file's text under a checkout's root, or `None` where the checkout
/// has no such file; `Err` is the read's cause. The disk reader is
/// [`read_text`]; a hosted checkout's is its provider's.
pub type FileRead<'a> = &'a dyn Fn(&Path) -> Result<Option<String>>;

/// The file rung of the settings ladder, read through `read` under `root`:
/// the `[env]` tables of the two settings files in order, the later
/// outranking, and under `private` the private env file they name
/// (`KENDEX_ENV_FILE`, else `.env.local`); `private` carries the caller's
/// own name for that file and its home, which outrank the files' in naming
/// it and in expanding its home forms. With `local`, `root` is a checkout
/// on this host's disk, and the private file's directory is held inside it
/// before the file is read.
pub struct FileRung {
    pub values: BTreeMap<String, String>,
    pub private: Option<(PathBuf, PrivateEnv)>,
}

pub fn file_rung(
    root: &Path,
    read: FileRead,
    private: Option<(Option<&str>, Option<&str>)>,
    local: bool,
    keys: &Keys,
) -> Result<FileRung> {
    let mut values: BTreeMap<String, String> = BTreeMap::new();
    for name in SETTINGS_FILES {
        let path = root.join(name);
        if let Some(text) = read(&path)? {
            for (key, value) in settings_text(&path, &text)? {
                values.insert(key, value);
            }
        }
    }
    let Some((named, home)) = private else {
        return Ok(FileRung {
            values,
            private: None,
        });
    };
    let named = named
        .or_else(|| values.get(ENV_FILE_KEY).map(String::as_str))
        .filter(|v| !v.is_empty())
        .map(str::to_owned);
    let named = private_env_name(named.as_deref())?;
    if local {
        private_env_inside(root, &named)?;
    }
    let path = root.join(named);
    let home = home
        .or_else(|| values.get(HOME_KEY).map(String::as_str))
        .map(str::to_owned);
    let env = match read(&path)? {
        Some(text) => private_env_text(&path, home.as_deref(), &text, keys)?,
        None => PrivateEnv {
            values: Vec::new(),
            passed_over: Vec::new(),
        },
    };
    Ok(FileRung {
        values,
        private: Some((path, env)),
    })
}

/// The private env file's project-relative name: the default, or the
/// configured one held to the spelling the shell loader admits.
fn private_env_name(named: Option<&str>) -> Result<PathBuf> {
    let Some(named) = named else {
        return Ok(PathBuf::from(DEFAULT_ENV_FILE));
    };
    let outside = named.starts_with('/')
        || named.contains(':')
        || named.contains('\\')
        || named == ".."
        || named.starts_with("../")
        || named.contains("/../")
        || named.ends_with("/..");
    if outside {
        return Err(refused("private-env-path", &[("path", named)]));
    }
    Ok(PathBuf::from(named))
}

/// Whether the directory the private env file `named` sits in stays inside
/// the project once every link on the way is followed, judged as the shell
/// loader judges it before it reads the file: the deepest existing ancestor
/// of that directory is resolved, a component that exists as something
/// other than a directory blocks the path, and a directory this process
/// cannot enter is unresolved. The file itself may be a link, as a
/// worktree's `.env.local` linked to its main checkout's is.
fn private_env_inside(root: &Path, named: &Path) -> Result<()> {
    // The kernel looks `.` up inside `dir` only where this process may enter
    // it, as `cd -P` must; the resolution itself drops a trailing `.`
    // without entering.
    let enter = |dir: &Path| fs::metadata(dir.join(".")).and_then(|_| fs::canonicalize(dir));
    let unresolved = |dir: &Path| {
        refused(
            "private-env-unresolved",
            &[("path", &dir.display().to_string())],
        )
    };
    let shown = named.display().to_string();
    let top = match enter(root) {
        Ok(top) => top,
        // A root that does not exist holds no file to read.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err(unresolved(root)),
    };
    let path = root.join(named);
    // The climb passes only components the loader's `-e` reads as absent,
    // which takes any failed lookup for absence.
    let mut dir = path.parent();
    while let Some(d) = dir {
        if fs::metadata(d).is_ok() {
            break;
        }
        dir = d.parent();
    }
    let dir = dir.unwrap_or(Path::new("/"));
    if !fs::metadata(dir).is_ok_and(|m| m.is_dir()) {
        return Err(refused("private-env-blocked", &[("path", &shown)]));
    }
    let at = enter(dir).map_err(|_| unresolved(dir))?;
    if !at.starts_with(&top) {
        return Err(refused("private-env-outside", &[("path", &shown)]));
    }
    Ok(())
}

/// A settings source's text, the source classified as the shell loader
/// classifies one before reading it: only a path that is absent and no link
/// reads as no file; a link that resolves to nothing refuses
/// `unresolved-link`, anything but a regular file refuses `not-file` before
/// any read (a FIFO would hold the read open), a file this process may not
/// read refuses `unreadable`, and a leading byte-order mark refuses
/// `byte-order-mark`.
pub fn read_text(path: &Path) -> Result<Option<String>> {
    let refusal = |reason: &str| file_refusal(path, "", reason);
    match fs::metadata(path) {
        Ok(meta) if !meta.is_file() => return Err(refusal("not-file")),
        Ok(_) => {}
        Err(_) if fs::symlink_metadata(path).is_ok() => return Err(refusal("unresolved-link")),
        Err(_) => return Ok(None),
    }
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
            return Err(refusal("unreadable"));
        }
        Err(e) => return Err(Error::io("read", path, e)),
    };
    if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return Err(refusal("byte-order-mark"));
    }
    Ok(Some(String::from_utf8_lossy(&bytes).into_owned()))
}

fn is_key(text: &str) -> bool {
    let mut chars = text.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Decode a `[env]` value: `"basic"` with no `"` or `\` inside, or
/// `'literal'` with no apostrophe inside, then optional space and a `#`
/// comment. `None` is a shape outside the contract.
fn decode_toml_value(raw: &str) -> Option<String> {
    let raw = raw.trim();
    let (quote, forbidden): (char, &[char]) = if raw.starts_with('\'') {
        ('\'', &['\''])
    } else {
        ('"', &['"', '\\'])
    };
    let body = raw.strip_prefix(quote)?;
    let end = body.find(quote)?;
    let value = &body[..end];
    if value.contains(forbidden) {
        return None;
    }
    let rest = body[end + 1..].trim_start();
    if rest.is_empty() || rest.starts_with('#') {
        Some(value.to_owned())
    } else {
        None
    }
}

/// The `[env]` assignments of one settings file, in file order; an absent
/// file holds none.
pub fn settings_file(path: &Path) -> Result<Vec<(String, String)>> {
    match read_text(path)? {
        Some(text) => settings_text(path, &text),
        None => Ok(Vec::new()),
    }
}

/// [`settings_file`] over a file's text; `path` names it in a refusal.
pub fn settings_text(path: &Path, text: &str) -> Result<Vec<(String, String)>> {
    let mut out = Vec::new();
    let mut section = String::new();
    let mut seen: Vec<String> = Vec::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(rest) = line.strip_prefix('[') {
            match rest.strip_suffix(']') {
                Some(name)
                    if !name.is_empty()
                        && name
                            .chars()
                            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-')) =>
                {
                    section = name.to_owned();
                    continue;
                }
                Some(_) | None => return Err(file_refusal(path, "", "table-header")),
            }
        }
        if section != "env" {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        if !is_key(key) {
            continue;
        }
        if seen.iter().any(|k| k == key) {
            return Err(file_refusal(path, key, "duplicate-key"));
        }
        seen.push(key.to_owned());
        let Some(value) = decode_toml_value(value) else {
            return Err(file_refusal(path, key, "value-syntax"));
        };
        out.push((key.to_owned(), value));
    }
    Ok(out)
}

/// Read a key's value as the sourcing shell assigns it, for the forms this
/// reader can stand in for: one single-quoted string as it stands; one
/// double-quoted string or one bare word with `$HOME` and `${HOME}` read as
/// `home`, and in a bare word a `~` at its start or after a `:`, before a
/// `/`, a `:` or its end, read as `home` too, as bash expands it in an
/// assignment; then blanks and an optional `#` comment. An empty value is
/// the empty string, which blanks the key as the shell's assignment does.
/// `None` is any other shell form, or a home form with no home to read.
fn decode_account_value(raw: &str, home: Option<&str>) -> Option<String> {
    let raw = raw.trim_end();
    let comment_only = |rest: &str| {
        let tail = rest.trim_start();
        tail.is_empty() || (tail.starts_with('#') && tail.len() < rest.len())
    };
    if let Some(body) = raw.strip_prefix('\'') {
        let (value, rest) = body.split_once('\'')?;
        return comment_only(rest).then(|| value.to_owned());
    }
    if let Some(body) = raw.strip_prefix('"') {
        let (value, rest) = body.split_once('"')?;
        if !comment_only(rest) || value.contains(['\\', '`']) {
            return None;
        }
        return expand_home(value, home, false);
    }
    let (word, rest) = raw.split_at(raw.find(char::is_whitespace).unwrap_or(raw.len()));
    if word.is_empty() {
        return comment_only(rest).then(String::new);
    }
    if !comment_only(rest) || word.contains(['#', '\\', '\'', '"', '`']) {
        return None;
    }
    expand_home(word, home, true)
}

/// `text` with `$HOME` and `${HOME}` read as `home`, and where `tilde` (a
/// bare word) a `~` at its start or after a `:`, before a `/`, a `:` or its
/// end. `None` is any other `$` or `~` form, or one of these with no home.
fn expand_home(text: &str, home: Option<&str>, tilde: bool) -> Option<String> {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    let mut at_start = true;
    while let Some(c) = rest.chars().next() {
        let after = &rest[c.len_utf8()..];
        let tail = match c {
            '$' => after.strip_prefix("{HOME}").or_else(|| {
                after
                    .strip_prefix("HOME")
                    .filter(|t| !t.starts_with(|n: char| n.is_ascii_alphanumeric() || n == '_'))
            }),
            '~' if tilde && at_start => {
                Some(after).filter(|t| t.is_empty() || t.starts_with(['/', ':']))
            }
            _ => {
                out.push(c);
                at_start = tilde && c == ':';
                rest = after;
                continue;
            }
        };
        rest = tail?;
        out.push_str(home?);
        at_start = false;
    }
    Some(out)
}

/// The private env file's assignments the caller reads, in file order, and
/// the keys whose line it passed over.
pub struct PrivateEnv {
    pub values: Vec<(String, String)>,
    pub passed_over: Vec<String>,
}

/// The assignments of the private env file the caller reads, in file
/// order. A key's value is read as the sourcing shell assigns it, `home`
/// the shell's `HOME` until the file assigns one, and a form only a shell
/// reads is passed over, so a value only some verbs read never refuses
/// every verb; for a key of [`Keys::load`] such a form refuses the load. A
/// line that assigns nothing the caller reads is the shell's alone.
pub fn private_env_file(path: &Path, home: Option<&str>, keys: &Keys) -> Result<PrivateEnv> {
    match read_text(path)? {
        Some(text) => private_env_text(path, home, &text, keys),
        None => Ok(PrivateEnv {
            values: Vec::new(),
            passed_over: Vec::new(),
        }),
    }
}

/// [`private_env_file`] over the file's text; `path` names it in a refusal.
pub fn private_env_text(
    path: &Path,
    home: Option<&str>,
    text: &str,
    keys: &Keys,
) -> Result<PrivateEnv> {
    let mut env = PrivateEnv {
        values: Vec::new(),
        passed_over: Vec::new(),
    };
    let mut home = home.filter(|h| !h.is_empty()).map(str::to_owned);
    for raw in text.lines() {
        let line = raw.trim();
        let line = line
            .strip_prefix("export ")
            .map(str::trim_start)
            .unwrap_or(line);
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if !keys.reads(key) {
            continue;
        }
        match decode_account_value(value, home.as_deref()) {
            Some(value) => {
                if key == HOME_KEY {
                    home = Some(value.clone()).filter(|h| !h.is_empty());
                }
                env.values.push((key.to_owned(), value));
            }
            None if keys.load.contains(&key) => {
                return Err(file_refusal(path, key, "value-syntax"));
            }
            None => env.passed_over.push(key.to_owned()),
        }
    }
    Ok(env)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::Refusal;

    /// The key every verb of the caller needs: the ladder's rules for it
    /// are the rules for any key a caller passes in `Keys::load`.
    const STATE: &str = "CALLER_STATE_DIR";
    const CALLER_READS: &[&str] = &["GH_TOKEN", "GH_HOST", "GH_BOT_TOKEN"];
    const KEYS: Keys = Keys {
        read: &[ENGINE_KEYS, ACCOUNT_KEYS, CALLER_READS],
        load: &[STATE],
    };

    fn env(pairs: &[(&str, &str)]) -> Vec<(OsString, OsString)> {
        pairs
            .iter()
            .map(|(k, v)| (OsString::from(k), OsString::from(v)))
            .collect()
    }

    fn write(root: &Path, name: &str, text: &str) {
        let path = root.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    fn load(project: &Path, environment: &[(&str, &str)], private_env: bool) -> Result<Layered> {
        layered(project, &env(environment), private_env, &KEYS)
    }

    fn field(e: &Error, name: &str) -> String {
        Refusal::from(e)
            .fields
            .into_iter()
            .find_map(|(key, value)| (key == name).then_some(value))
            .unwrap_or_default()
    }

    /// The ladder, one rung at a time: the caller's environment, the
    /// private file, `.kendex/settings.toml`, `kendex.settings.toml`, then
    /// nothing; an empty caller value shadows every file.
    #[test]
    fn the_state_directory_follows_the_flag_environment_and_file_ladder() {
        let dir = tempfile::tempdir().unwrap();
        let tree = dir.path();
        let state = |environment: &[(&str, &str)], private_env: bool| {
            load(tree, environment, private_env)
                .unwrap()
                .get(STATE)
                .map(str::to_owned)
        };
        assert_eq!(state(&[], true), None, "no rung names it");
        write(
            tree,
            "kendex.settings.toml",
            &format!("[env]\n{STATE} = \"state-a\"\n"),
        );
        assert_eq!(state(&[], true).as_deref(), Some("state-a"));
        write(
            tree,
            ".kendex/settings.toml",
            &format!("[env]\n{STATE} = 'state-b'\n"),
        );
        assert_eq!(
            state(&[], true).as_deref(),
            Some("state-b"),
            "the later file outranks"
        );
        write(tree, ".env.local", &format!("export {STATE}='state-c'\n"));
        assert_eq!(state(&[], true).as_deref(), Some("state-c"));
        assert_eq!(
            state(&[], false).as_deref(),
            Some("state-b"),
            "--no-private-env skips the private file"
        );
        assert_eq!(
            state(&[(STATE, "/abs/state")], true).as_deref(),
            Some("/abs/state"),
            "the caller's environment outranks every file"
        );
        assert_eq!(
            state(&[(STATE, "")], true),
            None,
            "an empty caller value shadows the files and reads as unset"
        );
    }

    /// Under `--no-private-env` the files give the load keys alone,
    /// outranking the caller's environment, and no other file key is read;
    /// every other key comes from the environment.
    #[test]
    fn no_private_env_takes_only_the_state_dir_from_the_files() {
        let dir = tempfile::tempdir().unwrap();
        write(
            dir.path(),
            "kendex.settings.toml",
            &format!("[env]\n{STATE} = \"from-file\"\n{TMUX_SESSION_KEY} = \"file-session\"\n"),
        );
        let values = load(
            dir.path(),
            &[(STATE, "from-env"), (TMUX_SESSION_KEY, "env-session")],
            false,
        )
        .unwrap();
        assert_eq!(
            values.get(STATE),
            Some("from-file"),
            "the file's load key outranks the environment"
        );
        assert_eq!(
            EngineSettings::read(&values).tmux_session.as_deref(),
            Some("env-session"),
            "every other key is the environment's, never the file's"
        );
        // With no caller value, the file's load key still resolves and no
        // other file key leaks in.
        let values = load(dir.path(), &[], false).unwrap();
        assert_eq!(values.get(STATE), Some("from-file"));
        assert_eq!(EngineSettings::read(&values).tmux_session, None);
        assert_eq!(values.passed_over, None);
    }

    #[test]
    fn a_named_private_file_is_read_and_an_outside_name_refused() {
        let dir = tempfile::tempdir().unwrap();
        write(
            dir.path(),
            "kendex.settings.toml",
            "[env]\nKENDEX_ENV_FILE = \"config/private.env\"\n",
        );
        write(
            dir.path(),
            "config/private.env",
            &format!("# a comment\nOTHER=$(uname)\n{TMUX_SESSION_KEY}=fleet\n"),
        );
        let values = load(dir.path(), &[], true).unwrap();
        assert_eq!(values.get(TMUX_SESSION_KEY), Some("fleet"));
        for bad in ["/etc/env", "../x", "a/../b", "c:d", "a\\b"] {
            let err = load(dir.path(), &[(ENV_FILE_KEY, bad)], true).unwrap_err();
            assert_eq!(err.key(), "private-env-path", "{bad}");
        }
    }

    /// Each settings source the shell loader refuses before it reads one,
    /// refused here by the same word, with no read of a FIFO; and the
    /// private file's directory held inside the project, a link at the file
    /// itself admitted. Run as root, a closed file or directory is open, so
    /// those two cases are not asked.
    #[test]
    fn a_settings_source_is_judged_before_it_is_read() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};
        let outside = tempfile::tempdir().unwrap();
        write(
            outside.path(),
            "priv.env",
            &format!("{TMUX_SESSION_KEY}=outside\n"),
        );
        let as_root = fs::metadata(outside.path()).unwrap().uid() == 0;
        let settings = |project: &Path| project.join("kendex.settings.toml");
        let mode = |path: &Path, mode: u32| {
            fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
        };
        type Plant<'a> = Box<dyn Fn(&Path) + 'a>;
        type Case<'a> = (&'a str, Plant<'a>, Option<&'a str>, (&'a str, &'a str));
        let cases: Vec<Case> = vec![
            (
                "a dangling link",
                Box::new(|p| symlink(p.join("nowhere"), settings(p)).unwrap()),
                None,
                ("settings-invalid", "unresolved-link"),
            ),
            (
                "a link to itself",
                Box::new(|p| symlink(settings(p), settings(p)).unwrap()),
                None,
                ("settings-invalid", "unresolved-link"),
            ),
            (
                "a directory",
                Box::new(|p| fs::create_dir(settings(p)).unwrap()),
                None,
                ("settings-invalid", "not-file"),
            ),
            (
                "a FIFO",
                Box::new(|p| {
                    let made = std::process::Command::new("mkfifo")
                        .arg(settings(p))
                        .status()
                        .unwrap();
                    assert!(made.success());
                }),
                None,
                ("settings-invalid", "not-file"),
            ),
            (
                "an unreadable file",
                Box::new(|p| {
                    write(p, "kendex.settings.toml", "[env]\n");
                    mode(&settings(p), 0o000);
                }),
                None,
                ("settings-invalid", "unreadable"),
            ),
            (
                "a file where `.kendex` names a directory",
                Box::new(|p| write(p, ".kendex", "")),
                None,
                ("loaded", ""),
            ),
            (
                "a file on the private file's path",
                Box::new(|p| write(p, "conf", "")),
                Some("conf/priv.env"),
                ("private-env-blocked", ""),
            ),
            (
                "a directory link out of the project",
                Box::new(|p| symlink(outside.path(), p.join("conf")).unwrap()),
                Some("conf/priv.env"),
                ("private-env-outside", ""),
            ),
            (
                "a directory this process cannot enter",
                Box::new(|p| {
                    fs::create_dir(p.join("locked")).unwrap();
                    mode(&p.join("locked"), 0o000);
                }),
                Some("locked/priv.env"),
                ("private-env-unresolved", ""),
            ),
            (
                "the file itself a link out",
                Box::new(|p| {
                    symlink(outside.path().join("priv.env"), p.join(".env.local")).unwrap()
                }),
                None,
                ("loaded", "outside"),
            ),
            (
                "directories not yet made",
                Box::new(|_| {}),
                Some("a/b/priv.env"),
                ("loaded", ""),
            ),
        ];
        for (case, plant, named, want) in cases {
            if as_root && (case.contains("unreadable") || case.contains("cannot enter")) {
                continue;
            }
            let dir = tempfile::tempdir().unwrap();
            let project = dir.path().join("tree");
            fs::create_dir_all(&project).unwrap();
            plant(&project);
            let caller: Vec<(&str, &str)> = named.map(|n| (ENV_FILE_KEY, n)).into_iter().collect();
            let got = match load(&project, &caller, true) {
                Ok(values) => (
                    "loaded".to_owned(),
                    values.get(TMUX_SESSION_KEY).unwrap_or_default().to_owned(),
                ),
                Err(e) => (e.key().to_owned(), field(&e, "reason")),
            };
            for closed in [settings(&project), project.join("locked")] {
                if fs::symlink_metadata(&closed).is_ok_and(|m| !m.file_type().is_symlink()) {
                    mode(&closed, 0o700);
                }
            }
            assert_eq!((got.0.as_str(), got.1.as_str()), want, "{case}");
        }
    }

    /// The file grammar the shell loader refuses, refused here by the same
    /// reason word; and the shapes it admits, decoded to the same bytes.
    #[test]
    fn settings_files_follow_the_env_table_contract() {
        let key = TMUX_SESSION_KEY;
        let refused = [
            (format!("\u{feff}[env]\n{key} = \"a\"\n"), "byte-order-mark"),
            (format!("[env] # c\n{key} = \"a\"\n"), "table-header"),
            (
                format!("[env]\n{key} = \"a\"\n{key} = \"b\"\n"),
                "duplicate-key",
            ),
            (format!("[env]\n{key} = \"a\\b\"\n"), "value-syntax"),
            (format!("[env]\n{key} = bare\n"), "value-syntax"),
        ];
        for (text, reason) in refused {
            let dir = tempfile::tempdir().unwrap();
            write(dir.path(), "kendex.settings.toml", &text);
            let err = load(dir.path(), &[], true).unwrap_err();
            assert_eq!(err.key(), "settings-invalid", "{text:?}");
            assert_eq!(field(&err, "reason"), reason, "{text:?}");
        }
        let dir = tempfile::tempdir().unwrap();
        write(
            dir.path(),
            "kendex.settings.toml",
            &format!(
                "[other]\n{key} = \"not-env\"\n[env]\n  {key} = 'lit' # x\n{VERIFY_SECS_KEY}=\"3\"   # trailing\nnot a key = \"skipped\"\n[tail]\n{JOB_CLAIM_SECS_KEY} = \"9\"\n"
            ),
        );
        let engine = EngineSettings::read(&load(dir.path(), &[], true).unwrap());
        assert_eq!(engine.tmux_session.as_deref(), Some("lit"));
        assert_eq!(engine.verify.get().unwrap(), Duration::from_secs(3));
        assert_eq!(engine.claim.get().unwrap(), Duration::from_secs(15));
    }

    /// A key's value reads as the sourcing shell assigns it, `$HOME` as the
    /// home; a form only a shell reads is passed over, the load and every
    /// other key read as before; a load key's refuses the load; an empty
    /// value blanks the key over a settings file's value, as the sourced
    /// file did.
    #[test]
    fn a_private_file_line_this_runtime_reads_must_decode_as_data() {
        let dir = tempfile::tempdir().unwrap();
        let tree = dir.path();
        write(
            tree,
            ".env.local",
            &format!(
                "{TMUX_SESSION_KEY}=a $b\nSOMETHING_ELSE=$(date)\nfunction f() {{ :; }}\n{VERIFY_SECS_KEY}=7\n"
            ),
        );
        let engine = EngineSettings::read(&load(tree, &[], true).unwrap());
        assert_eq!(engine.tmux_session, None);
        assert_eq!(engine.verify.get().unwrap(), Duration::from_secs(7));
        write(tree, ".env.local", &format!("{STATE}=a $b\n"));
        let err = load(tree, &[], true).unwrap_err();
        assert_eq!(err.key(), "settings-invalid");
        assert_eq!(field(&err, "key"), STATE);
        write(
            tree,
            ".env.local",
            &format!(
                "{TMUX_SESSION_KEY}=plain\nexport {VERIFY_SECS_KEY}=\"4\"\n{JOB_CLAIM_SECS_KEY}='5'\n"
            ),
        );
        let engine = EngineSettings::read(&load(tree, &[], true).unwrap());
        assert_eq!(engine.tmux_session.as_deref(), Some("plain"));
        assert_eq!(engine.verify.get().unwrap(), Duration::from_secs(4));
        assert_eq!(engine.claim.get().unwrap(), Duration::from_secs(5));
        write(
            tree,
            ".env.local",
            &format!(
                "{TMUX_SESSION_KEY}=\"$HOME/s\"\n{ACCOUNT_DIRS_KEY}=$(pwd)\n{CODEX_HOME_KEY}=~/c\n"
            ),
        );
        for (home, session, codex_home) in
            [(Some("/h"), Some("/h/s"), Some("/h/c")), (None, None, None)]
        {
            let caller: Vec<(&str, &str)> = home.map(|h| (HOME_KEY, h)).into_iter().collect();
            let values = load(tree, &caller, true).unwrap();
            let accounts = AccountSettings::read(&values).get().unwrap();
            assert_eq!(
                EngineSettings::read(&values).tmux_session.as_deref(),
                session,
                "{home:?}"
            );
            assert!(accounts.account_dirs.is_empty(), "{home:?}");
            assert_eq!(accounts.codex_home.as_deref(), codex_home, "{home:?}");
        }
        write(
            tree,
            "kendex.settings.toml",
            &format!("[env]\n{ACCOUNT_EXCLUDE_KEY} = \"lane-x\"\n"),
        );
        for (text, exclude) in [
            (String::new(), vec!["lane-x"]),
            (format!("{ACCOUNT_EXCLUDE_KEY}=\n"), vec![]),
            (format!("export {ACCOUNT_EXCLUDE_KEY}=\n"), vec![]),
            (format!("{ACCOUNT_EXCLUDE_KEY}= # cleared\n"), vec![]),
        ] {
            write(tree, ".env.local", &text);
            let values = load(tree, &[], true).unwrap();
            assert_eq!(
                AccountSettings::read(&values).get().unwrap().exclude,
                exclude,
                "{text:?}"
            );
        }
    }

    /// The account records' root is one per machine whoever reads: the
    /// state home's unless set, a set value absolute or under the home; a
    /// relative value would be one root per checkout, so it is refused, as
    /// a root with no home to resolve is.
    #[test]
    fn the_account_records_root_is_absolute_or_the_state_homes() {
        let dir = tempfile::tempdir().unwrap();
        let root = |caller: &[(&str, &str)]| {
            account_state_dir(&load(dir.path(), caller, true).unwrap()).read
        };
        let suffix = "kendex/agent-runtime/accounts";
        for (caller, want) in [
            (
                vec![(HOME_KEY, "/h")],
                Ok(PathBuf::from("/h/.local/state").join(suffix)),
            ),
            (
                vec![(HOME_KEY, "/h"), (STATE_HOME_KEY, "/xdg")],
                Ok(PathBuf::from("/xdg").join(suffix)),
            ),
            (
                vec![(HOME_KEY, "/h"), (STATE_HOME_KEY, "xdg")],
                Ok(PathBuf::from("/h/.local/state").join(suffix)),
            ),
            (
                vec![(HOME_KEY, "/h"), (ACCOUNT_STATE_DIR_KEY, "/var/accounts")],
                Ok(PathBuf::from("/var/accounts")),
            ),
            (
                vec![(HOME_KEY, "/h"), (ACCOUNT_STATE_DIR_KEY, "~/accounts")],
                Ok(PathBuf::from("/h/accounts")),
            ),
            (
                vec![(HOME_KEY, "/h"), (ACCOUNT_STATE_DIR_KEY, "tmp/accounts")],
                Err((ACCOUNT_STATE_DIR_KEY, "tmp/accounts".to_owned())),
            ),
            (
                vec![(ACCOUNT_STATE_DIR_KEY, "~/accounts")],
                Err((ACCOUNT_STATE_DIR_KEY, "~/accounts".to_owned())),
            ),
            (vec![], Err((ACCOUNT_STATE_DIR_KEY, String::new()))),
        ] {
            assert_eq!(root(&caller), want, "{caller:?}");
        }
    }

    /// A shell-form line of a key the load does not judge is passed over and
    /// named, never read as a value; a load key's still refuses.
    #[test]
    fn a_shell_form_private_line_is_passed_over_unless_the_load_judges_its_key() {
        let dir = tempfile::tempdir().unwrap();
        write(
            dir.path(),
            ".env.local",
            "GH_TOKEN=$(gh auth token)\nGH_HOST=github.example # enterprise\nGH_BOT_TOKEN=\n",
        );
        let values = load(dir.path(), &[], true).unwrap();
        assert_eq!(
            values.passed_over,
            Some((dir.path().join(".env.local"), vec!["GH_TOKEN".to_owned()]))
        );
        assert_eq!(values.raw("GH_TOKEN"), None);
        assert_eq!(values.raw("GH_BOT_TOKEN"), Some(""));
        assert_eq!(values.raw("GH_HOST"), Some("github.example"));
        let values = load(dir.path(), &[("GH_TOKEN", "ghs_caller")], true).unwrap();
        assert_eq!(
            values.get("GH_TOKEN"),
            Some("ghs_caller"),
            "the caller's value stands"
        );
        write(dir.path(), ".env.local", &format!("{STATE}=$(pwd)/state\n"));
        assert_eq!(
            load(dir.path(), &[], true).unwrap_err().key(),
            "settings-invalid"
        );
    }

    /// A load key's value reads as the shell loader read it in each source:
    /// the private file's `$HOME`, `${HOME}` and `~` as the home it sources
    /// under, a single-quoted value and a trailing comment as the shell
    /// assigns them; a settings file's and the caller's value as written,
    /// unexpanded; a form only a shell could evaluate refuses.
    #[test]
    fn the_state_directory_reads_its_home_forms_as_the_sourcing_shell_does() {
        let dir = tempfile::tempdir().unwrap();
        let tree = dir.path();
        let home = [(HOME_KEY, "/h")];
        for (line, state) in [
            (format!("{STATE}=$HOME/state\n"), "/h/state"),
            (format!("{STATE}=\"${{HOME}}/state\"\n"), "/h/state"),
            (format!("export {STATE}=~/state # mine\n"), "/h/state"),
            (format!("{STATE}='$HOME/state'\n"), "$HOME/state"),
        ] {
            write(tree, ".env.local", &line);
            let values = load(tree, &home, true).unwrap();
            assert_eq!(values.get(STATE), Some(state), "{line:?}");
        }
        for line in [
            format!("{STATE}=$(pwd)/state\n"),
            format!("{STATE}=$OTHER/state\n"),
        ] {
            write(tree, ".env.local", &line);
            assert_eq!(
                load(tree, &home, true).unwrap_err().key(),
                "settings-invalid",
                "{line:?}"
            );
        }
        fs::remove_file(tree.join(".env.local")).unwrap();
        write(
            tree,
            "kendex.settings.toml",
            &format!("[env]\n{STATE} = \"$HOME/state\"\n"),
        );
        let values = load(tree, &home, true).unwrap();
        assert_eq!(values.get(STATE), Some("$HOME/state"));
        let caller = [(HOME_KEY, "/h"), (STATE, "$HOME/state")];
        let values = load(tree, &caller, true).unwrap();
        assert_eq!(values.get(STATE), Some("$HOME/state"));
    }
}
