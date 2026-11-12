//! The reading a program outside orch asks at the command line: this
//! machine's listing, the seat the controller record names, and the lanes'
//! charges. Every room reading counts the lanes that run on an account
//! wherever orch is installed, so the charges are asked of the one program
//! that counts them, the project's own `orch-runtime`, once per reading, at
//! a fixed path no setting names: no orch in the project means no lanes, and
//! none is counted; an orch that is installed and cannot answer refuses the
//! reading, never a judgement as if no lane ran.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Deserialize;
use serde_json::Value;

use super::walk::{self, Ground, Hosted, Scope, WalkRequest, Walked};
use super::{AccountRow, Env, FleetFacts, LOCAL, PickAnswer, PickRequest, TAG, wall};
use crate::controller::{MEMBER, Overseer};
use crate::error::{Error, Result};
use crate::harness::Harness;
use crate::host::{self, Place};
use crate::record;

/// Where a project holds orch's entry, the one program that counts its lanes.
pub const ORCH_ENTRY: &str = ".agents/skills/orch/scripts/orch-runtime";
/// The count's own bound, its start included.
const COUNT_BOUND: Duration = Duration::from_secs(60);

/// The lanes' charges orch counted for one fleet record, as `orch-runtime
/// lane charges` prints them, and the record they were read from.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct Counted {
    /// The fleet record orch read; its controller member is the seat where
    /// the caller named no record.
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

/// The account the controller member of `path` runs on, where the record
/// and the member stand and name one.
fn seat(path: &Path) -> Result<Option<String>> {
    let Some(doc) = record::read_document(path)? else {
        return Ok(None);
    };
    let controller: Option<Overseer> = record::field(path, &doc, MEMBER)?;
    Ok(controller
        .and_then(|c| {
            c.extra
                .get("account")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .filter(|a| !a.is_empty()))
}

/// What a reading here judges beside the rows: the seat of the record the
/// caller named (else of the fleet orch read) and the charges counted.
pub(super) struct Beside {
    seat: Option<String>,
    counted: Counted,
}

impl Beside {
    pub(super) fn read(project: &Path, record: Option<&Path>) -> Result<Beside> {
        let counted = count(project, record)?;
        let seat = match record.or(counted.fleet.as_deref()) {
            Some(path) => seat(path)?,
            None => None,
        };
        Ok(Beside { seat, counted })
    }

    pub(super) fn facts(&self, rows: &[AccountRow]) -> FleetFacts {
        let mut seats: Vec<String> = rows
            .iter()
            .filter(|r| r.seat)
            .map(|r| r.canon.clone())
            .collect();
        seats.extend(self.seat.as_deref().map(wall::canon));
        FleetFacts {
            seats,
            charges: self.counted.charges.clone(),
            started: self.counted.started.clone(),
            cloud_repo: None,
        }
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
            now,
        ),
        Err(cause) => PickAnswer::Unjudged {
            cause: format!("listing-unread {cause}"),
        },
    }
}

/// The pick here: the judge over this machine's listing, the seat of
/// `record` and the lanes' charges of the project at `project`.
pub fn pick(
    settings: &Env,
    project: &Path,
    record: Option<&Path>,
    req: &PickRequest,
    now: u64,
) -> Result<PickAnswer> {
    if let Some(answer) = super::unbilled(req) {
        return Ok(answer);
    }
    let ground = Beside::read(project, record)?;
    Ok(judge(settings, &ground, req, now))
}

/// The walk here: every entry judged on this machine, an entry naming a
/// host refused, since no provider is read without orch.
pub fn walk(
    settings: &Env,
    project: &Path,
    record: Option<&Path>,
    req: &WalkRequest,
    now: u64,
) -> Result<Walked> {
    let ground = Beside::read(project, record)?;
    let mut host = |_: Scope, entry_host: Option<&str>, _: Harness| match entry_host {
        Some(h) if h != LOCAL => Err(Error::refused(
            "host-capabilities-unread",
            &[("host", h), ("cause", "no-provider")],
        )),
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
