//! What charges the fleet's lane cap, judged at admission
//! from the records and the kernel table in one transition, with no release
//! write. The execution charge is derived from the recorded identities
//! before any status word is read: a lane attempt charges one slot while a
//! proven live owned harness identity exists (its recorded launch or wake
//! process, read through the one identity reader), while its launch intent
//! is open (the preparing row an admission wrote), or while an
//! explicit unexpired [`Reservation`] an op wrote stands. A pane, a status
//! word, parked disk, a pending return or a native transcript never charges,
//! and `done`, `stopped` and `parked` are never read as zero: a live
//! identity charges whatever the status says. An identity that could not be
//! read protects its slot as unknown, never zero, and so does a `running` or
//! `preparing` record that names no identity at all.
//!
//! One slot per lane record, the first rule that holds deciding
//! (`lane_charge`); a `kind: claude-cloud` record belongs to the cloud cap
//! and is not read here:
//!
//! | Record reads | Charge | Reason, cause |
//! |---|---|---|
//! | `launch.{pid,start}` reads `Live` | 1 | `live`, whatever the status word |
//! | `launch` identity `Unreadable` | 1 | `unknown`, the reader's cause |
//! | `launch` gone or none, `wake.{pid,start}` reads `Live` | 1 | `wake` |
//! | `wake` identity `Unreadable` | 1 | `unknown`, the reader's cause |
//! | `reservation {reason, until}` with `until` after the op clock | 1 | `reservation`, the reason; at or after `until` nothing; an `until` that is no stamp protects as `unknown`, `reservation-until-invalid` |
//! | `preparing` with an open `launch-lane` intent on it | 1 | `preparing` |
//! | no identity recorded at all and status `running` or `preparing` | 1 | `unknown`, `identity-unrecorded` |
//! | identities gone (a pid live under another start among them), or no identity on `stopped`, `parked` or `done` | none | released by derivation; disk, worktree, mailbox, `pending_pr`, `parked`, `launch`, `recovery`, counters untouched |
//!
//! A relaunch replaces its own record's `launch` and `reservation`, so the
//! charges derived from those are left out of its count; a charge its wake
//! identity derives is owned execution the relaunch does not replace, and
//! the relaunch is refused beside it (`retained_charge`).
//!
//! The shell launcher's claim store is read, never written: a `.claim`
//! row carries a server pid and a pane id and no harness identity. It is
//! suppressed only on two proofs together: the `launch` identity of a lane of this fleet
//! recorded at that server pid and pane id reads `Live`, and the pane the
//! row names, on the server it names, holds that identity in its
//! foreground group, read through `observe::foreground` with the recorded
//! identity by exact pane id. A live wake, a status word or equal numbers
//! alone never suppress: a wake runs outside any pane, and a server pid and
//! a pane id are handed on to later servers and windows. One slot per row,
//! the first rule that holds deciding (`claim_charge`):
//!
//! | Row reads | Charge | Reason, cause |
//! |---|---|---|
//! | `.claim` at the server pid and pane id of a lane whose `launch` identity reads `Live`, that pane on that server holding the identity in its foreground group | none | the row doubles the one proven harness |
//! | `.claim` at those numbers, the pane read `Gone` | 1 | `claim`, `pane-gone` |
//! | `.claim` at those numbers, another process or a shell in the pane's foreground | 1 | `claim`, `foreground-not-harness` |
//! | `.claim` at those numbers, the server, the pane or the foreground unreadable | 1 | `unknown`, the reader's cause |
//! | `.claim` at numbers no live `launch` identity records | 1 | `claim`, `unmatched` |
//! | `.reserve`: a launcher pid and no start, which is no identity | 1 | `unknown`, `identity-unrecorded`; never read by that pid |
//! | a row that does not parse | 1 | `unknown`, `malformed` |
//!
//! The shell launcher's pruner is the only remover of its rows; this
//! reader deletes none.
use std::fs;
use std::path::{Path, PathBuf};

use agent_runtime::clock;
use agent_runtime::harness::Harness;
use agent_runtime::host::tmux;
use agent_runtime::observe::{self, ProcessReading};
use agent_runtime::process::{self, Identity};
use agent_runtime::reading::Reading;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::admission::{AdmissionReads, Clis};
use crate::error::{Error, Result};
use crate::settings::Settings;
use crate::state::{EffectOp, Intent, Lane, LaneStatus, LaunchIdentity};

/// The `kind` a Claude cloud lane records: hosted, its `mail_root` the
/// item's worktree on this machine. The cloud cap counts it, not this one
/// (`lane-cap.sh`'s `cap_kind`); the lane observation duty does not observe
/// it; the close owes its worktree.
pub(crate) const CLOUD_KIND: &str = "claude-cloud";

/// The host facts a fleet transition judges beside the record: the lane cap
/// setting, the shell claim store, the liveness read of the one identity
/// reader and the pane read a claim's suppression needs. The reads are
/// injected so a transition is a function of the record and what the
/// kernel and the tmux server answered; production takes
/// [`Host::kernel`]. The readers are private to `ops`: an effect file
/// receives the operation handle and no primitive function pointer
/// No read takes a pid alone: a pid alone is no identity.
pub struct Host<'a> {
    pub lane_cap: u32,
    /// The shell claim store; `None` where no shell launcher writes one.
    pub claim_store: Option<PathBuf>,
    /// Whether a recorded identity still runs under its recorded start.
    pub(super) still_runs: &'a dyn Fn(&Identity) -> Reading<Identity>,
    /// Who holds the terminal of the pane a claim row names: the pane by
    /// exact id on the server with that pid, read with the
    /// lane's live launch identity and its harness. Consulted only for a
    /// claim at the numbers of a live launch identity.
    pub(super) pane_foreground: PaneForeground<'a>,
    /// The admission's reads: the item read
    /// eligibility and the Location paths are judged from, for the
    /// launching item and for a holder with no recorded touched set, and
    /// the changed paths of a diff range. `None` on a host built for an
    /// entry that launches no lane.
    pub(super) admission: Option<AdmissionReads<'a>>,
    /// The settings the accounts judge reads a launch's account under
    /// the listing reader and the account bounds. `None`
    /// on a host built for an entry that launches no lane, which judges no
    /// account.
    pub(super) accounts: Option<&'a Settings>,
}

impl Host<'static> {
    /// The host as production judges it: the kernel's own identity read and
    /// the pane read through the one judge.
    #[allow(
        clippy::disallowed_methods,
        reason = "the one site that hands the kernel's identity reader to a fleet transition, which judges live processes beside the record and never acts on one"
    )]
    pub fn kernel(lane_cap: u32, claim_store: Option<PathBuf>) -> Host<'static> {
        Host {
            lane_cap,
            claim_store,
            still_runs: &process::still_runs,
            pane_foreground: &pane_foreground,
            admission: None,
            accounts: None,
        }
    }
}

impl<'a> Host<'a> {
    /// The kernel host with the admission's reads through the named
    /// programs: what the launch and admit entries judge against.
    pub fn admitting(self, clis: Clis) -> Host<'a> {
        Host {
            admission: Some(AdmissionReads::through(clis)),
            ..self
        }
    }

    /// The host with the accounts judge's settings: a launch that names
    /// an account is judged on that account's room.
    pub fn judging(self, settings: &'a Settings) -> Host<'a> {
        Host {
            accounts: Some(settings),
            ..self
        }
    }
}

/// The pane read a claim's suppression needs: the server pid and pane id a
/// lane's `launch` records, that launch identity read live, and the lane's
/// harness, answered with who holds the pane's terminal; `Gone` for a pane
/// the server has not, `Unreadable` when the server or the pane did not
/// answer.
pub(super) type PaneForeground<'a> =
    &'a dyn Fn(u64, &str, &Identity, Option<Harness>) -> Reading<ProcessReading>;

/// Who holds the terminal of pane `pane` on the tmux server whose pid is
/// `server`, read for `recorded`, a lane's launch identity, with `harness`
/// naming the lane's harness processes. A lane record names its server by
/// pid alone, so the read goes to the caller's ambient server, the socket
/// `$TMUX` names or the user's default, the server the shell claim writer
/// and this runtime's launches open their windows on (`effects::fleet_server`);
/// a server there with another pid, or none answering, leaves the pane
/// `Unreadable`, never gone, since a server pid is handed on to later
/// servers. The pane is read by exact id and its foreground through
/// `observe::foreground` with the recorded identity, so no other process is
/// ever taken for the harness.
#[allow(
    clippy::disallowed_methods,
    reason = "the occupancy's one pane read, injected through Host: a lane transition judges who holds a claimed pane beside the record and never acts on it"
)]
fn pane_foreground(
    server: u64,
    pane: &str,
    recorded: &Identity,
    harness: Option<Harness>,
) -> Reading<ProcessReading> {
    let live = match tmux::server(&tmux::ambient_socket()) {
        Ok(live) if u64::from(live.pid) == server => live,
        Ok(_) | Err(_) => {
            return Reading::Unreadable {
                cause: "server-unreachable",
            };
        }
    };
    let owns = |name: &str| harness.is_some_and(|h| h.owns_process(name));
    tmux::pane_fields(&live, pane)
        .map(|fields| observe::foreground(fields.pid, &owns, Some(recorded)))
}

/// Why a slot is charged.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ChargeReason {
    /// The lane's recorded harness runs under its recorded start.
    Live,
    /// The lane's recorded detached wake turn runs.
    Wake,
    /// The lane is `preparing` under an open launch intent.
    Preparing,
    /// An explicit reservation stands and has not lapsed.
    Reservation,
    /// Ownership could not be established: an unreadable identity, a record
    /// in flight with no identity, a reservation with no readable term, a
    /// shell reservation row, or a claim row that does not parse.
    /// Protected, never released.
    Unknown,
    /// A shell claim store row no live lane record accounts for.
    Claim,
}

/// What a charge is attributed to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "source", rename_all = "kebab-case")]
pub enum ChargeSource {
    Lane {
        item: String,
    },
    /// A shell `claim.*.claim` row, by file name.
    Claim {
        file: String,
    },
    /// A shell `claim.*.reserve` row, by file name.
    Reservation {
        file: String,
    },
}

/// One slot charged, and why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Charge {
    #[serde(flatten)]
    pub source: ChargeSource,
    pub reason: ChargeReason,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cause: Option<String>,
}

/// The cap and what charges it at one admission; `occupancy` is the number
/// of charges, one per lane or unaccounted claim row, never per pid.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Occupancy {
    pub cap: u32,
    pub occupancy: u32,
    pub charges: Vec<Charge>,
}

/// The process identity a lane's `launch` names, where it names one.
pub(super) fn identity_of(launch: &LaunchIdentity) -> Option<Identity> {
    Some(Identity {
        pid: u32::try_from(launch.pid?).ok()?,
        start: launch.start.clone()?,
    })
}

/// The identity of the lane's recorded detached wake turn, `wake {pid,
/// start}`, where the record carries one.
fn wake_identity(lane: &Lane) -> Option<Identity> {
    let wake = lane.extra.get("wake")?;
    let pid = match wake.get("pid")? {
        Value::Number(n) => n.as_u64()?,
        Value::String(s) => s.parse().ok()?,
        _ => return None,
    };
    Some(Identity {
        pid: u32::try_from(pid).ok()?,
        start: wake.get("start")?.as_str()?.to_owned(),
    })
}

/// One recorded identity and what the kernel answered for it.
#[derive(Debug, Clone)]
pub(super) struct Read {
    pub id: Identity,
    pub reading: Reading<Identity>,
}

/// The identities a lane record names, each read once through the one
/// identity reader: the harness its `launch` names and the detached wake
/// turn its `wake` names. `None` where the record names no such identity.
#[derive(Debug, Clone, Default)]
pub(super) struct Identities {
    pub launch: Option<Read>,
    pub wake: Option<Read>,
}

impl Identities {
    /// Whether the record names any identity at all.
    fn recorded(&self) -> bool {
        self.launch.is_some() || self.wake.is_some()
    }
}

/// Read the lane's recorded identities through the host's reader.
pub(super) fn read_identities(lane: &Lane, host: &Host) -> Identities {
    let read = |id: Option<Identity>| {
        id.map(|id| Read {
            reading: (host.still_runs)(&id),
            id,
        })
    };
    Identities {
        launch: read(lane.launch.as_ref().and_then(identity_of)),
        wake: read(wake_identity(lane)),
    }
}

fn lane_source(lane: &Lane) -> ChargeSource {
    ChargeSource::Lane {
        item: lane.item.clone(),
    }
}

/// The charge one recorded identity derives: live charges `reason`, an
/// unreadable one protects as unknown with the reader's cause, a gone one
/// derives nothing.
fn execution_charge(lane: &Lane, read: Option<&Read>, reason: ChargeReason) -> Option<Charge> {
    match &read?.reading {
        Reading::Live(_) => Some(Charge {
            source: lane_source(lane),
            reason,
            cause: None,
        }),
        Reading::Unreadable { cause } => Some(Charge {
            source: lane_source(lane),
            reason: ChargeReason::Unknown,
            cause: Some((*cause).to_owned()),
        }),
        Reading::Gone => None,
    }
}

/// The slot one lane attempt charges, or none, from its identities as
/// read and its record. `launch_open` says whether a launch intent on the
/// lane is open. Each rule is read in order and the first that holds
/// decides, so a lane charges at most once; the identities come first, so
/// no status word is read as zero over a live or unreadable harness.
pub(super) fn lane_charge(
    lane: &Lane,
    launch_open: bool,
    now_secs: u64,
    ids: &Identities,
) -> Option<Charge> {
    let charge = |reason: ChargeReason, cause: Option<String>| Charge {
        source: lane_source(lane),
        reason,
        cause,
    };
    if let Some(charge) = execution_charge(lane, ids.launch.as_ref(), ChargeReason::Live) {
        return Some(charge);
    }
    if let Some(charge) = execution_charge(lane, ids.wake.as_ref(), ChargeReason::Wake) {
        return Some(charge);
    }
    if let Some(reservation) = &lane.reservation {
        match clock::epoch_secs(&reservation.until) {
            Some(until) if now_secs < until => {
                return Some(charge(
                    ChargeReason::Reservation,
                    Some(reservation.reason.clone()),
                ));
            }
            Some(_) => {}
            None => {
                return Some(charge(
                    ChargeReason::Unknown,
                    Some("reservation-until-invalid".to_owned()),
                ));
            }
        }
    }
    // A launch in progress holds its slot while its intent is open; expiry
    // alone cannot release a still-authorized launcher.
    if lane.status == LaneStatus::Preparing && launch_open {
        return Some(charge(ChargeReason::Preparing, None));
    }
    // A record in flight that names no identity claims execution this
    // reader cannot prove or disprove: protected. A stopped, parked or done
    // record with none was written after an authorized stop and holds
    // nothing.
    if !ids.recorded() && lane.status.in_flight() {
        return Some(charge(
            ChargeReason::Unknown,
            Some("identity-unrecorded".to_owned()),
        ));
    }
    None
}

/// What a lane's record still charges once a relaunch replaces its
/// `launch` and its `reservation`: the detached wake turn, which the
/// relaunch does not replace and which refuses it while it reads live or
/// unreadable.
fn retained_charge(lane: &Lane, ids: &Identities) -> Option<Charge> {
    execution_charge(lane, ids.wake.as_ref(), ChargeReason::Wake)
}

/// One row of the shell claim store as this reader takes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum ClaimRow {
    /// A lane's claim: the tmux server pid and pane id its window had.
    Claim {
        file: String,
        server: u64,
        pane: String,
    },
    /// A launcher's reservation: a slot held from its count until its claim
    /// or record stands. It names a pid and no start, so it protects until
    /// the shell launcher removes it.
    Reserve { file: String },
    /// A row that does not parse; its fleet cannot be told, so it protects
    /// a slot until the shell readers, which prune such rows, remove it.
    Malformed { file: String },
}

/// The spelling the shell launcher gives a fleet in its claim rows: the
/// state file's directory resolved physically, else its own spelling with
/// trailing slashes off (`lane_claims_canon`), then the file name.
pub(super) fn canonical_fleet(path: &Path) -> String {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let dir = path.parent().unwrap_or(Path::new(""));
    let dir = match fs::canonicalize(dir) {
        Ok(resolved) => resolved.display().to_string(),
        Err(_) => {
            let mut spelled = dir.display().to_string();
            while spelled.len() > 1 && spelled.ends_with('/') {
                spelled.pop();
            }
            spelled
        }
    };
    format!("{dir}/{name}")
}

/// The path the fleet launch lock is taken beside: the shell `cap_take`
/// holds `flock` on `<fleet>.launch.lock`, and `record::lock` names its
/// file `<base>.lock`, so the base is `<fleet>.launch` in the shell
/// fleet spelling.
pub(super) fn launch_lock_base(path: &Path) -> PathBuf {
    PathBuf::from(format!("{}.launch", canonical_fleet(path)))
}

/// Read the rows of `store` that belong to `fleet` and its fleet cap,
/// without writing or pruning anything. An absent store is empty; a store or
/// a row that cannot be read refuses `cap-unreadable`, since a count missing
/// a lane admits one too many. A row whose kind is `claude-cloud` belongs to
/// the cloud cap and is left out; one of another fleet is left out.
pub(super) fn read_claims(store: &Path, fleet: &str) -> Result<Vec<ClaimRow>> {
    let entries = match fs::read_dir(store) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => {
            return Err(Error::CapUnreadable {
                read: "claims",
                path: store.to_path_buf(),
                cause: e.to_string(),
            });
        }
    };
    let mut rows = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| Error::CapUnreadable {
            read: "claims",
            path: store.to_path_buf(),
            cause: e.to_string(),
        })?;
        let name = entry.file_name().to_string_lossy().into_owned();
        // A row becomes visible by its rename onto the suffix; a file still
        // under its temporary name is half-written and not yet a row.
        if !(name.ends_with(".claim") || name.ends_with(".reserve")) {
            continue;
        }
        let path = entry.path();
        let text = fs::read_to_string(&path).map_err(|e| Error::CapUnreadable {
            read: "claims",
            path: path.clone(),
            cause: e.to_string(),
        })?;
        if let Some(row) = parse_row(&name, text.lines().next().unwrap_or(""), fleet) {
            rows.push(row);
        }
    }
    Ok(rows)
}

/// One row's fields: `server\tpane\tcfg\twindow\tcreated\tfleet\tnamed\tkind\tpool`
/// (`lane_claim_put`); rows older than the last three fields carry six.
fn parse_row(file: &str, line: &str, fleet: &str) -> Option<ClaimRow> {
    let fields: Vec<&str> = line.split('\t').collect();
    let malformed = || {
        Some(ClaimRow::Malformed {
            file: file.to_owned(),
        })
    };
    if fields.len() < 6 || fields[1].is_empty() {
        return malformed();
    }
    let Ok(server) = fields[0].parse::<u64>() else {
        return malformed();
    };
    if fields[5] != fleet {
        return None;
    }
    if fields.get(7).copied().unwrap_or("") == CLOUD_KIND {
        return None;
    }
    if fields[1] == "-" {
        return Some(ClaimRow::Reserve {
            file: file.to_owned(),
        });
    }
    Some(ClaimRow::Claim {
        file: file.to_owned(),
        server,
        pane: fields[1].to_owned(),
    })
}

/// Whether an open launch intent stands on `item`.
pub(super) fn launch_open(intents: &[Intent], item: &str) -> bool {
    intents
        .iter()
        .any(|i| i.open() && i.op == EffectOp::LaunchLane && i.target == item)
}

/// A lane whose `launch` identity reads live, at the server pid and pane id
/// its launch records: the one provenance a claim row is matched on, and
/// the identity the pane read must find holding that pane. A live wake is no launch: it runs outside any pane.
struct LiveLaunch<'a> {
    server: u64,
    pane: &'a str,
    identity: Identity,
    harness: Option<Harness>,
}

fn live_launch<'a>(lane: &'a Lane, ids: &Identities) -> Option<LiveLaunch<'a>> {
    let read = ids.launch.as_ref()?;
    let Reading::Live(_) = &read.reading else {
        return None;
    };
    let launch = lane.launch.as_ref()?;
    Some(LiveLaunch {
        server: launch.server?,
        pane: launch.pane.as_deref()?,
        identity: read.id.clone(),
        harness: lane.harness.as_deref().and_then(Harness::parse),
    })
}

/// The slot a `.claim` row charges, or none when the row is proven the
/// double of one live launch: a lane's launch identity reads live at the
/// row's server pid and pane id, and that pane, read on that server by
/// exact id, holds the identity in its foreground group. Every other
/// reading protects the row, an unreadable one as unknown with its cause.
fn claim_charge(
    file: &str,
    server: u64,
    pane: &str,
    launches: &[LiveLaunch],
    host: &Host,
) -> Option<Charge> {
    let protect = |reason: ChargeReason, cause: &str| {
        Some(Charge {
            source: ChargeSource::Claim {
                file: file.to_owned(),
            },
            reason,
            cause: Some(cause.to_owned()),
        })
    };
    let Some(launch) = launches
        .iter()
        .find(|l| l.server == server && l.pane == pane)
    else {
        return protect(ChargeReason::Claim, "unmatched");
    };
    match (host.pane_foreground)(server, pane, &launch.identity, launch.harness) {
        Reading::Live(ProcessReading::Harness { identity }) if identity == launch.identity => None,
        Reading::Live(
            ProcessReading::Harness { .. }
            | ProcessReading::HarnessUp
            | ProcessReading::ShellsOnly
            | ProcessReading::ForegroundShell { .. }
            | ProcessReading::ForegroundOther { .. },
        ) => protect(ChargeReason::Claim, "foreground-not-harness"),
        Reading::Live(ProcessReading::Unread { cause }) | Reading::Unreadable { cause } => {
            protect(ChargeReason::Unknown, cause)
        }
        Reading::Gone => protect(ChargeReason::Claim, "pane-gone"),
    }
}

/// What charges the fleet cap now: every local lane judged by
/// [`lane_charge`] from identities read once each, except the lane a
/// relaunch replaces (`replacing`: its item and the identities the caller
/// read), which charges only what the relaunch does not replace; then the
/// shell rows no live launch, read in its pane, accounts for
/// ([`claim_charge`]).
pub(super) fn occupancy(
    lanes: &[Lane],
    intents: &[Intent],
    replacing: Option<(&str, &Identities)>,
    claims: &[ClaimRow],
    now_secs: u64,
    host: &Host,
) -> Occupancy {
    let mut charges = Vec::new();
    let mut launches: Vec<LiveLaunch> = Vec::new();
    for lane in lanes {
        if lane.kind.as_deref() == Some(CLOUD_KIND) {
            continue;
        }
        let own = replacing
            .filter(|(item, _)| *item == lane.item)
            .map(|(_, ids)| ids);
        let read;
        let ids = match own {
            Some(ids) => ids,
            None => {
                read = read_identities(lane, host);
                &read
            }
        };
        let charge = match own {
            Some(ids) => retained_charge(lane, ids),
            None => lane_charge(lane, launch_open(intents, &lane.item), now_secs, ids),
        };
        charges.extend(charge);
        launches.extend(live_launch(lane, ids));
    }
    for row in claims {
        match row {
            ClaimRow::Claim { file, server, pane } => {
                charges.extend(claim_charge(file, *server, pane, &launches, host));
            }
            ClaimRow::Reserve { file } => charges.push(Charge {
                source: ChargeSource::Reservation { file: file.clone() },
                reason: ChargeReason::Unknown,
                cause: Some("identity-unrecorded".to_owned()),
            }),
            ClaimRow::Malformed { file } => charges.push(Charge {
                source: ChargeSource::Claim { file: file.clone() },
                reason: ChargeReason::Unknown,
                cause: Some("malformed".to_owned()),
            }),
        }
    }
    Occupancy {
        cap: host.lane_cap,
        occupancy: u32::try_from(charges.len()).unwrap_or(u32::MAX),
        charges,
    }
}

#[allow(
    clippy::disallowed_methods,
    reason = "the rows write the claim stores and links the occupancy reads"
)]
#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::HashMap;

    use serde_json::json;

    use super::super::testing::no_reads;
    use super::*;
    use crate::state::Reservation;

    /// A planted reader: the readings each identity answers with, `Gone`
    /// for one not planted.
    fn planted(
        answers: &HashMap<(u32, String), Reading<Identity>>,
    ) -> impl Fn(&Identity) -> Reading<Identity> + '_ {
        move |id: &Identity| {
            answers
                .get(&(id.pid, id.start.clone()))
                .cloned()
                .unwrap_or(Reading::Gone)
        }
    }

    /// The pane reader a row installs where no claim may reach the pane
    /// read: a read through it is a suppression attempted on numbers, a
    /// wake or a status word alone.
    fn never_a_pane(
        server: u64,
        pane: &str,
        _: &Identity,
        _: Option<Harness>,
    ) -> Reading<ProcessReading> {
        panic!("pane {pane} on server {server} read where no live launch names it")
    }

    fn lane(item: &str, status: LaneStatus, launch: Option<(u32, &str)>) -> Lane {
        let mut doc = json!({"item": item, "status": status.word()});
        if let Some((pid, start)) = launch {
            doc["launch"] = json!({"pane": "%7", "server": 41020, "pid": pid, "start": start});
        }
        serde_json::from_value(doc).unwrap()
    }

    fn live(pid: u32, start: &str) -> ((u32, String), Reading<Identity>) {
        (
            (pid, start.to_owned()),
            Reading::Live(Identity {
                pid,
                start: start.to_owned(),
            }),
        )
    }

    fn unreadable(pid: u32, start: &str) -> ((u32, String), Reading<Identity>) {
        (
            (pid, start.to_owned()),
            Reading::Unreadable {
                cause: "stat-unreadable",
            },
        )
    }

    /// The reason and cause `lane_charge` gives `lane` under `host`, with
    /// no launch intent open and the clock at zero.
    fn reason(lane: &Lane, host: &Host) -> Option<(ChargeReason, Option<String>)> {
        lane_charge(lane, false, 0, &read_identities(lane, host)).map(|c| (c.reason, c.cause))
    }

    /// The charge rules, identities before status words, each from
    /// a planted reading: the identities are read before any status word,
    /// so a live recorded identity charges on every status, `done`
    /// included; a gone one releases whatever the status word says; a
    /// reused pid (gone under the recorded start) releases; an unreadable
    /// one protects; a record in flight with no identity protects; a
    /// stopped, parked or done record with none holds nothing; a live or
    /// unreadable wake charges once its parent is gone.
    #[test]
    fn a_lane_charges_by_its_identity_reading_never_by_its_status_word() {
        let answers = HashMap::from([
            live(100, "ticks:1"),
            unreadable(200, "ticks:2"),
            live(300, "ticks:3"),
            unreadable(400, "ticks:4"),
        ]);
        let reader = planted(&answers);
        let host = Host {
            lane_cap: 4,
            claim_store: None,
            still_runs: &reader,
            pane_foreground: &never_a_pane,
            admission: Some(no_reads()),
            accounts: None,
        };
        for status in [
            LaneStatus::Running,
            LaneStatus::Preparing,
            LaneStatus::Stopped,
            LaneStatus::Parked,
            LaneStatus::Done,
        ] {
            assert_eq!(
                reason(&lane("A", status, Some((100, "ticks:1"))), &host),
                Some((ChargeReason::Live, None)),
                "{}: a live identity charges whatever the status word",
                status.word()
            );
            assert_eq!(
                reason(&lane("A", status, Some((200, "ticks:2"))), &host),
                Some((ChargeReason::Unknown, Some("stat-unreadable".to_owned()))),
                "{}: an unreadable identity protects, never zero",
                status.word()
            );
        }
        assert_eq!(
            reason(
                &lane("A", LaneStatus::Running, Some((100, "ticks:9"))),
                &host
            ),
            None,
            "a pid live under another start is a reused pid: released"
        );
        assert_eq!(
            reason(
                &lane("A", LaneStatus::Running, Some((900, "ticks:1"))),
                &host
            ),
            None,
            "an ended attempt releases its slot"
        );
        for status in [LaneStatus::Running, LaneStatus::Preparing] {
            assert_eq!(
                reason(&lane("A", status, None), &host),
                Some((
                    ChargeReason::Unknown,
                    Some("identity-unrecorded".to_owned())
                )),
                "{}: a record in flight with no identity is unknown ownership",
                status.word()
            );
        }
        for status in [LaneStatus::Stopped, LaneStatus::Parked, LaneStatus::Done] {
            assert_eq!(
                reason(&lane("A", status, None), &host),
                None,
                "{}: no identity recorded and not in flight holds nothing",
                status.word()
            );
            assert_eq!(
                reason(&lane("A", status, Some((900, "ticks:1"))), &host),
                None,
                "{}: a gone identity holds nothing",
                status.word()
            );
        }
        // A parent gone with its wake turn still working charges once, on
        // every status; an unreadable wake protects.
        for status in [LaneStatus::Running, LaneStatus::Stopped, LaneStatus::Done] {
            let mut woken = lane("A", status, Some((900, "ticks:1")));
            woken
                .extra
                .insert("wake".into(), json!({"pid": 300, "start": "ticks:3"}));
            assert_eq!(
                reason(&woken, &host),
                Some((ChargeReason::Wake, None)),
                "{}",
                status.word()
            );
            woken
                .extra
                .insert("wake".into(), json!({"pid": 400, "start": "ticks:4"}));
            assert_eq!(
                reason(&woken, &host),
                Some((ChargeReason::Unknown, Some("stat-unreadable".to_owned()))),
                "{}: an unreadable wake protects",
                status.word()
            );
        }
        let mut woken = lane("A", LaneStatus::Running, Some((900, "ticks:1")));
        woken
            .extra
            .insert("wake".into(), json!({"pid": "300", "start": "ticks:3"}));
        assert_eq!(
            reason(&woken, &host),
            Some((ChargeReason::Wake, None)),
            "a wake pid a jq writer wrote as a string reads"
        );
        woken
            .extra
            .insert("wake".into(), json!({"pid": 300, "start": "ticks:0"}));
        assert_eq!(
            reason(&woken, &host),
            None,
            "a wake over a reused pid is a turn over"
        );
        // A wake alone, the parent never recorded: the wake is the identity.
        let mut wake_only = lane("A", LaneStatus::Stopped, None);
        wake_only
            .extra
            .insert("wake".into(), json!({"pid": 300, "start": "ticks:3"}));
        assert_eq!(reason(&wake_only, &host), Some((ChargeReason::Wake, None)));
        // The preparing row an admission wrote charges while its launch
        // intent is open, whatever identity it carries yet.
        let preparing = lane("A", LaneStatus::Preparing, None);
        assert_eq!(
            lane_charge(&preparing, true, 0, &read_identities(&preparing, &host)).map(|c| c.reason),
            Some(ChargeReason::Preparing)
        );
        // A relaunch replacing the record keeps only the wake's charge.
        let relaunched = lane("A", LaneStatus::Stopped, Some((100, "ticks:1")));
        assert_eq!(
            retained_charge(&relaunched, &read_identities(&relaunched, &host)),
            None,
            "the launch identity is what the relaunch replaces"
        );
        assert_eq!(
            retained_charge(&woken, &read_identities(&woken, &host)),
            None
        );
        assert_eq!(
            retained_charge(&wake_only, &read_identities(&wake_only, &host)).map(|c| c.reason),
            Some(ChargeReason::Wake),
            "a live wake is owned execution the relaunch does not replace"
        );
    }

    /// A deliberate reservation holds its slot to its term and no longer:
    /// before `until` it charges whatever the identity reads,
    /// at and after it only a live identity does; a term that is no stamp
    /// protects; the identity is read before the reservation, so a live
    /// harness under a lapsed hold charges `live`.
    #[test]
    fn a_reservation_holds_to_its_term_and_expiry_never_slides() {
        let answers = HashMap::from([live(100, "ticks:1")]);
        let reader = planted(&answers);
        let host = Host {
            lane_cap: 4,
            claim_store: None,
            still_runs: &reader,
            pane_foreground: &never_a_pane,
            admission: Some(no_reads()),
            accounts: None,
        };
        let mut held = lane("A", LaneStatus::Stopped, Some((900, "ticks:1")));
        held.reservation = Some(Reservation {
            reason: "resume".into(),
            until: "2026-01-29T15:20:00Z".into(),
        });
        let until = clock::epoch_secs("2026-01-29T15:20:00Z").unwrap();
        let at = |lane: &Lane, now: u64| {
            lane_charge(lane, false, now, &read_identities(lane, &host))
                .map(|c| (c.reason, c.cause))
        };
        assert_eq!(
            at(&held, until - 1),
            Some((ChargeReason::Reservation, Some("resume".to_owned())))
        );
        assert_eq!(at(&held, until), None, "at the term the hold is over");
        assert_eq!(at(&held, until + 3600), None);
        held.reservation = Some(Reservation {
            reason: "resume".into(),
            until: "soon".into(),
        });
        assert_eq!(
            at(&held, 0),
            Some((
                ChargeReason::Unknown,
                Some("reservation-until-invalid".to_owned())
            ))
        );
        let mut running = lane("A", LaneStatus::Stopped, Some((100, "ticks:1")));
        running.reservation = held.reservation.clone();
        assert_eq!(
            at(&running, until + 3600),
            Some((ChargeReason::Live, None)),
            "the identity is read before the hold"
        );
    }

    /// The charges of an occupancy as a keyed set: the store is read in
    /// directory order, which the contract does not fix.
    fn keyed(counted: &Occupancy) -> Vec<(String, ChargeReason, Option<String>)> {
        let mut summary: Vec<_> = counted
            .charges
            .iter()
            .map(|c| {
                let source = match &c.source {
                    ChargeSource::Lane { item } => format!("lane:{item}"),
                    ChargeSource::Claim { file } => format!("claim:{file}"),
                    ChargeSource::Reservation { file } => format!("reserve:{file}"),
                };
                (source, c.reason, c.cause.clone())
            })
            .collect();
        summary.sort_by(|a, b| a.0.cmp(&b.0));
        summary
    }

    /// The shell store, read and never written: a claim at the server pid and pane id of a lane whose launch
    /// identity reads live is suppressed once the pane, read on that
    /// server with that identity, holds it in its foreground group, so a
    /// live lane with its claim is one slot; the same pane read with a
    /// shell or another process in front, gone, or unreadable protects the
    /// claim, the unreadable one as unknown with the cause; the lane ended,
    /// or alive only through its detached wake, never reaches the pane read
    /// and its claim protects as unmatched, since neither proves the pane is
    /// that attempt's; a claim no record matches protects; a reservation
    /// row protects as unknown while it stands and is never read by its
    /// launcher pid; a row that does not parse protects; another fleet's
    /// rows and cloud-cap rows are left out; a half-written file is not yet
    /// a row; a cloud lane record belongs to the cloud cap and charges
    /// nothing here.
    #[test]
    fn shell_claim_rows_are_accounted_by_provenance_or_protected() {
        let dir = tempfile::tempdir().unwrap();
        let store = dir.path().join("claims");
        fs::create_dir_all(&store).unwrap();
        let fleet = "/f/workflow-state-oversee.json";
        let row = |name: &str, fields: &[&str]| {
            fs::write(store.join(name), format!("{}\n", fields.join("\t"))).unwrap();
        };
        row(
            "claim.a1.claim",
            &[
                "41020",
                "%7",
                "/a/a1",
                "KEN-A",
                "2026-01-01T00:00:00Z",
                fleet,
                "a1",
                "local",
                "plan",
            ],
        );
        row(
            "claim.b2.claim",
            &[
                "41020",
                "%9",
                "/a/b2",
                "KEN-B",
                "2026-01-01T00:00:00Z",
                fleet,
                "b2",
                "",
                "plan",
            ],
        );
        row(
            "claim.c3.reserve",
            &[
                "7000",
                "-",
                "",
                "KEN-C",
                "2026-01-01T00:00:00Z",
                fleet,
                "",
                "local",
                "",
            ],
        );
        row(
            "claim.f6.claim",
            &[
                "41020",
                "%7",
                "/a/a1",
                "KEN-F",
                "2026-01-01T00:00:00Z",
                "/g/workflow-state-oversee.json",
            ],
        );
        row(
            "claim.g7.claim",
            &[
                "41020",
                "%8",
                "/a/a1",
                "KEN-G",
                "2026-01-01T00:00:00Z",
                fleet,
                "a1",
                "claude-cloud",
                "plan",
            ],
        );
        row("claim.h8.claim", &["not a row"]);
        row("claim.i9", &["41020", "%7", "/a/a1", "KEN-I", "x", fleet]);
        let rows = read_claims(&store, fleet).unwrap();
        assert_eq!(rows.len(), 4, "{rows:?}");
        let answers = HashMap::from([live(100, "ticks:1"), live(300, "ticks:3")]);
        let reader = planted(&answers);
        let launch_id = Identity {
            pid: 100,
            start: "ticks:1".to_owned(),
        };
        // The planted pane read: what the claimed pane answers, and every
        // ask made of it.
        let pane_answer = RefCell::new(Reading::Live(ProcessReading::Harness {
            identity: launch_id.clone(),
        }));
        let asked = RefCell::new(Vec::new());
        let pane_reader =
            |server: u64, pane: &str, recorded: &Identity, harness: Option<Harness>| {
                asked
                    .borrow_mut()
                    .push((server, pane.to_owned(), recorded.clone(), harness));
                pane_answer.borrow().clone()
            };
        let host = Host {
            lane_cap: 4,
            claim_store: None,
            still_runs: &reader,
            pane_foreground: &pane_reader,
            admission: Some(no_reads()),
            accounts: None,
        };
        let mut cloud = lane("KEN-CLOUD", LaneStatus::Running, None);
        cloud.kind = Some("claude-cloud".into());
        let mut live_lane = lane("KEN-A", LaneStatus::Running, Some((100, "ticks:1")));
        live_lane.harness = Some("claude".into());
        let lanes = [live_lane.clone(), cloud.clone()];
        let counted = occupancy(&lanes, &[], None, &rows, 0, &host);
        assert_eq!(
            keyed(&counted),
            vec![
                (
                    "claim:claim.b2.claim".to_owned(),
                    ChargeReason::Claim,
                    Some("unmatched".to_owned())
                ),
                (
                    "claim:claim.h8.claim".to_owned(),
                    ChargeReason::Unknown,
                    Some("malformed".to_owned())
                ),
                ("lane:KEN-A".to_owned(), ChargeReason::Live, None),
                (
                    "reserve:claim.c3.reserve".to_owned(),
                    ChargeReason::Unknown,
                    Some("identity-unrecorded".to_owned())
                ),
            ]
        );
        assert_eq!(counted.occupancy, 4);
        assert_eq!(
            asked.replace(Vec::new()),
            vec![(
                41020,
                "%7".to_owned(),
                launch_id.clone(),
                Some(Harness::Claude)
            )],
            "the one claim at the live launch's numbers is read in its pane, with the launch identity"
        );
        // The same claim with the pane read answering anything but the
        // launch identity in the foreground protects: a shell or another
        // process in front, the pane gone, or the pane, server or
        // foreground unreadable.
        let a1 = |reason: ChargeReason, cause: &str| {
            (
                "claim:claim.a1.claim".to_owned(),
                reason,
                Some(cause.to_owned()),
            )
        };
        for (answer, expected) in [
            (
                Reading::Live(ProcessReading::ForegroundShell {
                    name: "bash".to_owned(),
                }),
                a1(ChargeReason::Claim, "foreground-not-harness"),
            ),
            (
                Reading::Live(ProcessReading::ForegroundOther {
                    name: "sleep".to_owned(),
                    pid: 7,
                }),
                a1(ChargeReason::Claim, "foreground-not-harness"),
            ),
            (
                Reading::Live(ProcessReading::ShellsOnly),
                a1(ChargeReason::Claim, "foreground-not-harness"),
            ),
            (Reading::Gone, a1(ChargeReason::Claim, "pane-gone")),
            (
                Reading::Live(ProcessReading::Unread {
                    cause: "foreground-group-empty",
                }),
                a1(ChargeReason::Unknown, "foreground-group-empty"),
            ),
            (
                Reading::Unreadable {
                    cause: "server-unreachable",
                },
                a1(ChargeReason::Unknown, "server-unreachable"),
            ),
        ] {
            *pane_answer.borrow_mut() = answer.clone();
            let counted = occupancy(&lanes, &[], None, &rows, 0, &host);
            assert_eq!(counted.occupancy, 5, "{answer:?}");
            assert!(keyed(&counted).contains(&expected), "{answer:?}");
            assert_eq!(asked.replace(Vec::new()).len(), 1, "{answer:?}");
        }
        // The same lane ended: no launch identity reads live at that server
        // and pane, so the pane is not read and the claim protects a slot of
        // its own.
        let never = Host {
            pane_foreground: &never_a_pane,
            ..host
        };
        let ended = [lane("KEN-A", LaneStatus::Running, Some((900, "ticks:1")))];
        let counted = occupancy(&ended, &[], None, &rows, 0, &never);
        assert_eq!(counted.occupancy, 4);
        assert!(keyed(&counted).contains(&a1(ChargeReason::Claim, "unmatched")));
        assert!(!counted.charges.iter().any(|c| c.source
            == ChargeSource::Lane {
                item: "KEN-A".into()
            }));
        // A stopped lane whose detached wake reads live keeps its
        // launch's server pid and pane id, numbers a later server and
        // another attempt's window may hold. The wake charges once, as owned
        // execution; it proves nothing about the pane, so the claim at those
        // numbers is not read and protects.
        let mut woken = lane("KEN-A", LaneStatus::Stopped, Some((900, "ticks:1")));
        woken
            .extra
            .insert("wake".into(), json!({"pid": 300, "start": "ticks:3"}));
        let counted = occupancy(&[woken], &[], None, &rows, 0, &never);
        assert_eq!(counted.occupancy, 5);
        assert!(keyed(&counted).contains(&("lane:KEN-A".to_owned(), ChargeReason::Wake, None)));
        assert!(keyed(&counted).contains(&a1(ChargeReason::Claim, "unmatched")));
        // Nothing was written or pruned.
        assert_eq!(fs::read_dir(&store).unwrap().count(), 7);
        // An absent store is empty; one that is not a directory refuses.
        assert!(
            read_claims(&dir.path().join("none"), fleet)
                .unwrap()
                .is_empty()
        );
        let file = dir.path().join("flat");
        fs::write(&file, "").unwrap();
        let err = read_claims(&file, fleet).unwrap_err();
        assert_eq!(err.key(), "cap-unreadable");
        assert_eq!(err.fields()[0], ("source".to_owned(), "claims".to_owned()));
    }

    #[test]
    fn the_fleet_spelling_follows_the_shell_launchers_canon() {
        let dir = tempfile::tempdir().unwrap();
        let real = fs::canonicalize(dir.path()).unwrap();
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert_eq!(
            canonical_fleet(&link.join("workflow-state-oversee.json")),
            format!("{}/workflow-state-oversee.json", real.display())
        );
        assert_eq!(
            canonical_fleet(Path::new("/no/such/dir//workflow-state-oversee.json")),
            "/no/such/dir/workflow-state-oversee.json"
        );
        assert_eq!(
            launch_lock_base(&link.join("workflow-state-oversee.json")),
            real.join("workflow-state-oversee.json.launch"),
            "the shell launch lock is `<fleet>.launch.lock`"
        );
    }
}
