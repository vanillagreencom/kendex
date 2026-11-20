//! The reading a program outside orch asks at the command line: this
//! machine's listing, its controllers' seats, and the lanes' charges.
//! Every room reading counts the lanes that run on an account
//! wherever orch is installed, so the charges are asked of the one program
//! that counts them, the project's own `orch-runtime`, once per reading, at
//! a fixed path no setting names: no orch in the project means no lanes, and
//! none is counted; an orch that is installed and cannot answer refuses the
//! reading, never a judgement as if no lane ran.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Deserialize;

use super::walk::{self, Ground, Hosted, Scope, WalkRequest, Walked};
use super::{AccountRow, Env, FleetFacts, LOCAL, PickAnswer, PickRequest, TAG};
use crate::error::{Error, Result};
use crate::group::{self, Seats};
use crate::harness::Harness;
use crate::host::{self, Place};
use crate::process;

/// Where a project holds orch's entry, the one program that counts its lanes.
pub const ORCH_ENTRY: &str = ".agents/skills/orch/scripts/orch-runtime";
/// The count's own bound, its start included.
const COUNT_BOUND: Duration = Duration::from_secs(60);

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
            now,
        ),
        Err(cause) => PickAnswer::Unjudged {
            cause: format!("listing-unread {cause}"),
        },
    }
}

/// The pick here: the judge over this machine's listing, its seats with
/// `record`'s controller's as the caller's own, and the lanes' charges of
/// the project at `project`.
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
    let ground = Beside::read(settings, project, record)?;
    Ok(judge(settings, &ground, req, now))
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
