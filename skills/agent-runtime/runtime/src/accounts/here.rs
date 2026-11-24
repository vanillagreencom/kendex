//! The reading a program outside orch asks at the command line: this
//! machine's listing, its controllers' seats, and the lanes' charges.
//! Every room reading counts the lanes that run on an account
//! wherever orch is installed, so the charges are asked of the one program
//! that counts them, the project's own `orch-runtime`, once per reading, at
//! a fixed path no setting names: no orch in the project means no lanes, and
//! none is counted; an orch that is installed and cannot answer refuses the
//! reading, never a judgement as if no lane ran.

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Deserialize;

use super::walk::{self, Ground, Hosted, Scope, WalkRequest, Walked};
use super::{AccountRow, Env, FleetFacts, LOCAL, PickAnswer, PickRequest, ProviderKey, TAG};
use crate::error::{Error, Result};
use crate::group::{self, Seats};
use crate::harness::Harness;
use crate::host::{self, Place};
use crate::process;

/// Where a project holds orch's entry, the one program that counts its lanes.
pub const ORCH_ENTRY: &str = ".agents/skills/orch/scripts/orch-runtime";
/// The count's own bound, its start included.
const COUNT_BOUND: Duration = Duration::from_secs(60);
/// Pi's credential check's bound, its start included: a key stored in the
/// root answers in under a second (pi 1.6.0), and an OAuth refresh or a
/// `!command` key reaches past this machine.
const KEY_BOUND: Duration = Duration::from_secs(30);

/// The lanes' charges orch counted for one fleet record, as `orch-runtime
/// lane charges` prints them, and the record they were read from.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct Counted {
    /// The fleet record orch read; its controller's seat is the caller's
    /// own where the caller named no record.
    pub fleet: Option<PathBuf>,
    pub charges: BTreeMap<String, u32>,
    pub started: BTreeMap<String, Vec<u64>>,
}

#[derive(Deserialize)]
struct CountReply {
    ok: bool,
    result: Option<Counted>,
}

fn unread(program: &Path, exit: &str, cause: Option<&str>) -> Error {
    let program = program.display().to_string();
    let mut fields = vec![("program", program.as_str()), ("exit", exit)];
    if let Some(cause) = cause {
        fields.push(("cause", cause));
    }
    Error::refused("account-charges-unread", &fields)
}

/// The charges of the lanes of `record` (the fleet orch resolves where
/// none is named), counted by the project's orch where it holds one.
#[allow(
    clippy::disallowed_methods,
    reason = "the reading's one call to the project's orch for its lanes' charges, through the one runner under the accounts tag; it acts on nothing"
)]
pub fn count(project: &Path, record: Option<&Path>) -> Result<Counted> {
    let program = project.join(ORCH_ENTRY);
    match std::fs::symlink_metadata(&program) {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Counted::default()),
        Err(e) => return Err(unread(&program, "none", Some(&e.to_string()))),
    }
    let file = record.map(|p| p.display().to_string());
    let mut args = vec!["lane", "charges"];
    match &file {
        Some(file) => args.extend(["--file", file.as_str()]),
        None => args.push("--fleet"),
    }
    let out = host::run_tagged_in(
        TAG,
        "orch-runtime",
        &program,
        "lane-charges",
        &args,
        Place {
            cwd: Some(project),
            env: &[],
        },
        COUNT_BOUND,
    )
    .map_err(|e| unread(&program, "none", Some(&e.to_string())))?;
    let exit = out
        .status
        .code()
        .map_or("signal".to_owned(), |c| c.to_string());
    if !out.status.success() {
        return Err(unread(&program, &exit, None));
    }
    match serde_json::from_slice::<CountReply>(&out.stdout) {
        Ok(CountReply {
            ok: true,
            result: Some(counted),
        }) => Ok(counted),
        Ok(_) | Err(_) => Err(unread(&program, &exit, Some("reply-unread"))),
    }
}

/// What a reading here judges beside the rows: this machine's seats, the
/// caller's own being that of the record it named (else of the fleet orch
/// read), and the charges counted.
pub(super) struct Beside {
    seats: Seats,
    counted: Counted,
}

impl Beside {
    pub(super) fn read(settings: &Env, project: &Path, record: Option<&Path>) -> Result<Beside> {
        let counted = count(project, record)?;
        let seats = group::seats(
            &settings.account_state.get()?,
            record.or(counted.fleet.as_deref()),
            &process::still_runs,
        )?;
        Ok(Beside { seats, counted })
    }

    pub(super) fn facts(&self, rows: &[AccountRow]) -> FleetFacts {
        let mut facts = FleetFacts {
            charges: self.counted.charges.clone(),
            started: self.counted.started.clone(),
            ..FleetFacts::default()
        };
        facts.seat(rows, &self.seats);
        facts
    }
}

/// The judge over this machine's listing for one request.
fn judge(settings: &Env, ground: &Beside, req: &PickRequest, now: u64) -> PickAnswer {
    if let Some(answer) = super::unbilled(req) {
        return answer;
    }
    let accounts = match settings.accounts.get() {
        Ok(accounts) => accounts,
        Err(e) => {
            return PickAnswer::Unjudged {
                cause: e.to_string(),
            };
        }
    };
    let model = req.model.as_deref().unwrap_or("");
    let named = req.harness.billed(model).zip(req.lane.as_deref());
    match super::roster_naming(settings, None, named, now) {
        Ok(roster) => super::pick(
            &roster.rows,
            req,
            &ground.facts(&roster.rows),
            &accounts,
            settings.account_tokens,
            now,
        ),
        Err(cause) => PickAnswer::Unjudged {
            cause: format!("listing-unread {cause}"),
        },
    }
}

/// The pick here: the judge over this machine's listing, its seats with
/// `record`'s controller's as the caller's own, and the lanes' charges of
/// the project at `project`. Where `admit_unbilled` asks it, a named Pi
/// root on a model naming a provider nothing bills is judged on Pi's read
/// of its key there ([`PickRequest::provider_key`]); a check that gave no
/// answer judges nothing.
pub fn pick(
    settings: &Env,
    project: &Path,
    record: Option<&Path>,
    req: &PickRequest,
    admit_unbilled: bool,
    now: u64,
) -> Result<PickAnswer> {
    let model = req.model.as_deref().unwrap_or("");
    let keyed;
    let req = match req.lane.as_deref() {
        Some(dir) if admit_unbilled && req.harness.names_unbilled_provider(model) => {
            match provider_key(dir, model) {
                Ok(key) => {
                    keyed = PickRequest {
                        provider_key: Some(key),
                        ..req.clone()
                    };
                    &keyed
                }
                Err(cause) => return Ok(PickAnswer::Unjudged { cause }),
            }
        }
        Some(_) | None => req,
    };
    if let Some(answer) = super::unbilled(req) {
        return Ok(answer);
    }
    let ground = Beside::read(settings, project, record)?;
    Ok(judge(settings, &ground, req, now))
}

/// The caller's variables Pi's credential check runs with, beside the
/// root: those that find the user's programs, files and locale and reach
/// the network, which a `!command` key or an OAuth refresh needs, and no
/// credential. Pi also counts a provider's environment variables
/// (pi 1.6.0, the package's `models.md` § Authenticate), and the window a
/// launch opens takes its server's environment, never the caller's, so a
/// key read from the caller's variables is no key the launch holds.
const KEY_CHECK_ENV: [&str; 19] = [
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "LANG",
    "DBUS_SESSION_BUS_ADDRESS",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "NODE_EXTRA_CA_CERTS",
    "CURL_CA_BUNDLE",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "NO_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
    "no_proxy",
];
/// The prefixes of the locale's and the user's directories' variables the
/// check keeps beside [`KEY_CHECK_ENV`].
const KEY_CHECK_PREFIXES: [&str; 2] = ["LC_", "XDG_"];

/// `pi auth check --model MODEL --json` under the root `dir`, run in that
/// root so no project's own `.pi` configuration is read, with the caller's
/// [`KEY_CHECK_ENV`] alone: Pi's documented readiness check (pi 1.6.0, the
/// package's `cli.md` § Credential commands) over the root's `auth.json`
/// and `models.json` and the ambient credentials Pi finds under the
/// user's home, the sources the launched Pi reads too. Like every Pi
/// start on the root, the launch's own included, it refreshes an expired
/// OAuth credential and writes it back to the root's `auth.json`, and a
/// `!command` key runs its command. Exit 0 answers `ready`, 1 `not_ready`
/// and 2 `invalid`, each with its JSON line; any other ending is no
/// answer.
#[allow(
    clippy::disallowed_methods,
    reason = "the one run of Pi's own credential check, `pi auth check` under the named root through the one runner under the accounts tag; it writes nothing of the pick's"
)]
fn provider_key(dir: &str, model: &str) -> std::result::Result<ProviderKey, String> {
    let inherited: Vec<(String, std::ffi::OsString)> = std::env::vars_os()
        .filter_map(|(name, value)| Some((name.into_string().ok()?, value)))
        .filter(|(name, _)| {
            KEY_CHECK_ENV.contains(&name.as_str())
                || KEY_CHECK_PREFIXES.iter().any(|p| name.starts_with(p))
        })
        .collect();
    let env: Vec<(&str, &OsStr)> = inherited
        .iter()
        .map(|(name, value)| (name.as_str(), value.as_os_str()))
        .chain([(Harness::Pi.home_var(), OsStr::new(dir))])
        .collect();
    let out = host::run_tagged_alone(
        TAG,
        Harness::Pi.binary(),
        Path::new(Harness::Pi.binary()),
        "auth-check",
        &["auth", "check", "--model", model, "--json"],
        Place {
            cwd: Some(Path::new(dir)),
            env: &env,
        },
        KEY_BOUND,
    )
    .map_err(|e| format!("provider-key-unread dir={dir} cause={e}"))?;
    let exit = out.status.code();
    let answer: Option<serde_json::Value> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .last()
        .and_then(|line| serde_json::from_str(line).ok());
    let field = |name: &str| {
        answer
            .as_ref()
            .and_then(|a| a.get(name))
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned)
    };
    match (exit, field("status").as_deref()) {
        (Some(0), Some("ready")) => Ok(ProviderKey::Ready),
        (Some(1), Some(status @ "not_ready")) | (Some(2), Some(status @ "invalid")) => {
            Ok(ProviderKey::Refused {
                status: status.to_owned(),
                reason: field("reason").unwrap_or_default(),
            })
        }
        _ => Err(format!(
            "provider-key-unread dir={dir} exit={}",
            exit.map_or("signal".to_owned(), |c| c.to_string())
        )),
    }
}

/// The walk here: every entry judged on this machine, an entry naming a
/// host passed over unread, since no provider is read without orch.
pub fn walk(
    settings: &Env,
    project: &Path,
    record: Option<&Path>,
    req: &WalkRequest,
    now: u64,
) -> Result<Walked> {
    let ground = Beside::read(settings, project, record)?;
    let mut host = |_: Scope, entry_host: Option<&str>, _: Harness| match entry_host {
        Some(h) if h != LOCAL => Ok(Hosted::Unread {
            host: h.to_owned(),
            cause: "no-provider".to_owned(),
        }),
        Some(_) | None => Ok(Hosted::Judge {
            host: None,
            launch: None,
        }),
    };
    let mut pick = |request: &PickRequest, _: Option<&str>| judge(settings, &ground, request, now);
    walk::walk(
        settings,
        Ground {
            host: &mut host,
            pick: &mut pick,
        },
        req,
        now,
    )
}
