//! The outcome model: the intent's durable obligation set, the evidence that
//! discharges one obligation, the tokens the acting methods take, and the one
//! type the recording boundary takes. Every type here is private to
//! `effects::operation`.
//!
//! An [`Obligation`] is a handle the operation acquired, in the record
//! `Intent.obligations`, under the [`Role`] it plays there. A [`Discharge`]
//! names the one obligation it settles and carries the read or answer that
//! settles it. A [`Standing`] token names an obligation of the set as it
//! stands and is minted here alone, so an acting method cannot be handed a
//! key the set never held; the method checks the key still stands in its
//! own set before it acts. `signalled` is recorded
//! at the first signal; [`Unsignalled`] is minted only from a record that
//! says nothing was signalled, and [`Settled`] only from a set with nothing
//! standing. [`EffectOutcome`] is what every effect returns; `apply_outcome`
//! is the one place it becomes the wire record.

use std::path::Path;

use agent_runtime::harness::Harness;
use agent_runtime::host::tmux::{Close, Pane};
use agent_runtime::process::{Identity, Stop};
use agent_runtime::reading::Reading;
use serde_json::{Value, json};

use crate::error::{Error, Result};
use crate::state::{
    self, EffectOp, Intent, LaunchIdentity, Obligation, ObligationRecord, OpenedPane, Overseer,
    Owner, Phase, Role, WatchJob,
};

use super::super::{overseer_identity, pid_value};

/// A pane by exact id on the server identity that holds it, pid and tmux
/// start. A lane record the shell launcher wrote names the server by pid
/// alone, so its start is `None` there and nowhere else.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct PaneRef {
    pub pane: String,
    pub server: u64,
    pub server_start: Option<u64>,
}

impl PaneRef {
    pub(super) fn of_opened(opened: &OpenedPane) -> PaneRef {
        PaneRef {
            pane: opened.pane.clone(),
            server: opened.server,
            server_start: Some(opened.server_start),
        }
    }

    pub(super) fn obligation(&self) -> Obligation {
        Obligation::Pane {
            pane: self.pane.clone(),
            server: self.server,
            server_start: self.server_start,
        }
    }
}

/// The detached job a transfer or a stop was handed to, by the identity its
/// launcher's record names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JobHandle {
    /// The job runs as this transient user unit, read through its manager.
    Unit { unit: String },
    /// The job leads this process group, read through the one identity
    /// reader.
    Group(Identity),
    /// The job's group by its key alone, where the launcher never read the
    /// leader's start: read in the kernel's table.
    Pgid(u32),
}

impl JobHandle {
    pub(super) fn obligation(&self) -> Obligation {
        match self {
            JobHandle::Unit { unit } => Obligation::JobUnit { unit: unit.clone() },
            JobHandle::Group(identity) => Obligation::JobGroup(identity.clone()),
            JobHandle::Pgid(pgid) => Obligation::JobPgid { pgid: *pgid },
        }
    }
}

/// What a read of the job launcher's record found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SidecarRead {
    /// No record: the launcher refused before it asked anything.
    Absent,
    Present(JobHandle),
    /// The launcher ended the launch after its first write: its record
    /// carries the `status` word and nothing started.
    Failed {
        status: String,
    },
    /// A record that could not be read, or one naming no identity yet: the
    /// job stands as unread, never as absent.
    Unreadable {
        cause: String,
    },
}

/// What ended a recorded process, as the reader or the stop answered.
pub(super) enum ProcessEnd {
    Stop(Stop),
    Read(Reading<Identity>),
    /// The recorded pid live under another start, read `readings` times
    /// independently; the second settles it.
    Stale {
        readings: u64,
    },
    /// The predecessor's stop read unreadable before it sent any signal: the
    /// handle returns to the record it came from, settled by that answer.
    NotSignalled,
}

/// What ended a recorded pane: the close of its window or itself by exact
/// id, a read of that id gone on its proven server, or its server gone or
/// replaced with every pane it held.
pub(super) enum PaneEnd {
    Close(Close),
    Gone,
    /// The predecessor's stop sent no signal: its window returns to the
    /// record it came from, settled by that answer.
    NotSignalled,
}

/// What ended a detached job short of its own claim.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum JobEnd {
    /// The manager has no record of the unit: it never started, or ended.
    UnitGone,
    /// The unit stands in a state that runs nothing (`inactive`, `failed`).
    UnitEnded { state: String },
    /// The group's identity read gone through the one identity reader.
    Exited,
    /// The fleet watch's claim names a live runtime identity: the job is
    /// the fleet's from here, not this intent's.
    Claimed,
}

/// What a read of the pane's receipt settled: a receipt read, or one absent
/// past the bound within which the pane could still register, discharges the
/// obligation; an invalid or unreadable receipt leaves it standing.
pub(super) enum ReceiptEnd {
    Absent,
    Read,
    Invalid { cause: &'static str },
}

/// An obligation of the set as it stands, by its key `K`: the one argument an
/// acting method takes. Minted only by [`Obligations::standing_process`] and
/// [`Obligations::standing_pane`], from a standing obligation of that kind.
/// The acting method checks the key still stands in its own set and refuses
/// `token-stale` where it does not; whether that set is still the record's
/// is the store's judgement, made at the write that precedes every act: a
/// set replaced since the handle read it refuses `set-replaced`.
pub struct Standing<K> {
    key: K,
}

impl<K> Standing<K> {
    pub fn key(&self) -> &K {
        &self.key
    }
}

/// Evidence that settles one named obligation. A discharge whose evidence
/// does not settle (a stop that timed out, a close the host did not answer,
/// a first stale reading, an unreadable record) leaves the obligation
/// standing with the cause.
pub(super) enum Discharge {
    Process {
        identity: Identity,
        end: ProcessEnd,
    },
    Pid {
        pid: u32,
        read: Reading<Identity>,
    },
    Pane {
        pane: PaneRef,
        end: PaneEnd,
    },
    /// The window possibly opened on the server is gone with the server.
    Window {
        server: u64,
        server_start: u64,
    },
    Receipt(ReceiptEnd),
    Job {
        job: JobHandle,
        end: JobEnd,
    },
    /// The launcher's record at `record` was read: a handle it names becomes
    /// the job's obligation through the caller's `add`.
    Sidecar {
        record: String,
        read: SidecarRead,
    },
}

impl Discharge {
    /// The one obligation this evidence is about.
    pub(super) fn names(&self) -> Obligation {
        match self {
            Discharge::Process { identity, .. } => Obligation::Process(identity.clone()),
            Discharge::Pid { pid, .. } => Obligation::Pid { pid: *pid },
            Discharge::Pane { pane, .. } => pane.obligation(),
            Discharge::Window {
                server,
                server_start,
            } => Obligation::Window {
                server: *server,
                server_start: *server_start,
            },
            Discharge::Receipt(_) => Obligation::Receipt,
            Discharge::Job { job, .. } => job.obligation(),
            Discharge::Sidecar { record, .. } => Obligation::JobSidecar {
                record: record.clone(),
            },
        }
    }
}

/// The obligations an operation stands under: the intent's durable record
/// (standing, discharged, signalled) and, for this run alone, why each
/// discharge that settled nothing left its obligation standing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Obligations {
    record: ObligationRecord,
    held: Vec<String>,
}

/// Every obligation discharged. Made only by [`Obligations::settled`] and
/// [`Obligations::publish`]; carries the record it proves.
#[must_use]
#[derive(Debug)]
pub(super) struct Settled(ObligationRecord);

/// A token a site holds while the intent has signalled nothing: a
/// [`Terminal::Refused`] needs one, and only [`Obligations::unsignalled`]
/// mints it, from a record that says so.
#[must_use]
pub(super) struct Unsignalled(());

impl Obligations {
    pub(super) fn none() -> Obligations {
        Obligations::of(Vec::new(), Role::Harness, None)
    }

    /// A set of `standing` obligations, each under `role`, the harness
    /// kind `harness` recorded on those under the harness role.
    fn of(standing: Vec<Obligation>, role: Role, harness: Option<Harness>) -> Obligations {
        Obligations {
            record: ObligationRecord {
                standing: standing
                    .into_iter()
                    .map(|obligation| state::Held {
                        obligation,
                        role: Some(role),
                        harness: harness.filter(|_| role == Role::Harness),
                    })
                    .collect(),
                discharged: Vec::new(),
                signalled: false,
                stale: Default::default(),
                revision: 0,
            },
            held: Vec::new(),
        }
    }

    /// A record with a row under no role is refused `role-missing`: the set
    /// alone selects the harness, the pane and the wake by role, and no
    /// released writer writes a row without one.
    pub(super) fn recorded(intent: &Intent) -> Result<Option<Obligations>> {
        let Some(record) = intent.obligations.clone() else {
            return Ok(None);
        };
        if record.standing.iter().any(|h| h.role.is_none())
            || record.discharged.iter().any(|d| d.role.is_none())
        {
            return Err(Error::RoleMissing {
                id: intent.id.clone(),
            });
        }
        Ok(Some(Obligations {
            record,
            held: Vec::new(),
        }))
    }

    /// What a launch or succession phase names, under `role` with the
    /// harness kind `harness`: nothing before a phase; at `opening` once
    /// asked, the armed receipt and the window possibly opened until its
    /// pane is recorded; then the pane, the receipt and the identity once
    /// read.
    pub(super) fn of_phase(
        phase: Option<&Phase>,
        role: Role,
        harness: Option<Harness>,
    ) -> Obligations {
        match phase {
            None | Some(Phase::CloudCreate { .. } | Phase::Preparing { .. }) => Obligations::none(),
            Some(Phase::Opening { opening }) => match (&opening.pane, opening.asked) {
                (None, false) => Obligations::none(),
                (None, true) => Obligations::of(
                    vec![
                        Obligation::Receipt,
                        Obligation::Window {
                            server: opening.server,
                            server_start: opening.server_start,
                        },
                    ],
                    role,
                    harness,
                ),
                (Some(pane), _) => Obligations::of(
                    vec![
                        Obligation::Receipt,
                        PaneRef {
                            pane: pane.clone(),
                            server: opening.server,
                            server_start: Some(opening.server_start),
                        }
                        .obligation(),
                    ],
                    role,
                    harness,
                ),
            },
            Some(Phase::IdentityRead { opened, pid, start }) => {
                // Written by this runtime from the reader's own `u32`.
                let Ok(pid) = u32::try_from(*pid) else {
                    unreachable!("an identity-read phase carries a kernel pid, got {pid}")
                };
                let mut obligations = Obligations::of_opened(opened, role, harness);
                obligations.add(
                    Obligation::Process(Identity {
                        pid,
                        start: start.clone(),
                    }),
                    role,
                    harness,
                );
                obligations
            }
            Some(
                Phase::WindowOpened { opened }
                | Phase::Delivering { opened, .. }
                | Phase::Delivered { opened, .. },
            ) => Obligations::of_opened(opened, role, harness),
        }
    }

    /// A recorded pane past `opening` and the identity read in it, where one
    /// was, under `role`: the receipt is read and discharged by the time the
    /// window is recorded open, so it is not among what `window-opened` on
    /// names.
    pub(super) fn of_opened(
        opened: &OpenedPane,
        role: Role,
        harness: Option<Harness>,
    ) -> Obligations {
        let mut standing = vec![PaneRef::of_opened(opened).obligation()];
        if let Some(identity) = &opened.identity {
            standing.push(Obligation::Process(identity.clone()));
        }
        Obligations::of(standing, role, harness)
    }

    /// What a lane's `launch` records, under the harness role with the
    /// harness kind the lane runs: the one reading of the launch record, at
    /// the bootstrap.
    pub(super) fn of_launch(
        launch: Option<&LaunchIdentity>,
        harness: Option<Harness>,
    ) -> Obligations {
        Obligations::of(state::launch_obligations(launch), Role::Harness, harness)
    }

    /// What the overseer record names, under the predecessor role: its pane
    /// on its server, with the server's start where recorded, else the pane
    /// unaddressable, and the harness identity it recorded.
    pub(super) fn of_overseer(overseer: &Overseer) -> Obligations {
        let mut standing = Vec::new();
        match (
            overseer.extra.get("pane").and_then(Value::as_str),
            overseer.extra.get("server").and_then(pid_value),
        ) {
            (Some(pane), Some(server)) => standing.push(Obligation::Pane {
                pane: pane.to_owned(),
                server,
                server_start: overseer.extra.get("server_start").and_then(pid_value),
            }),
            (Some(pane), None) => standing.push(Obligation::PaneUnaddressed {
                pane: pane.to_owned(),
            }),
            (None, Some(_) | None) => {}
        }
        if let Some(identity) = overseer_identity(overseer) {
            standing.push(Obligation::Process(identity));
        }
        Obligations::of(standing, Role::Predecessor, None)
    }

    /// A handle acquired or read on the way, under `role`, the harness kind
    /// `harness` recorded on it under the harness role. One already standing
    /// or already discharged is not added again.
    pub(super) fn add(&mut self, obligation: Obligation, role: Role, harness: Option<Harness>) {
        if !self.record.holds(&obligation) {
            self.record.standing.push(state::Held {
                obligation,
                role: Some(role),
                harness: harness.filter(|_| role == Role::Harness),
            });
        }
    }

    /// Every standing obligation of `other` added, each under its own role
    /// and harness kind.
    pub(super) fn extend(&mut self, other: Obligations) {
        for held in other.record.standing {
            self.add(
                held.obligation,
                held.role.unwrap_or(Role::Harness),
                held.harness,
            );
        }
    }

    /// The harness kind recorded under the harness role: what names the
    /// processes below a recorded root that a stop on this set may signal.
    pub(super) fn recorded_harness(&self) -> Option<Harness> {
        self.record.recorded_harness()
    }

    /// `old`, where it stands, settled `by` the evidence that names `new` in
    /// its place under `role`: a window by the pane id its creating call
    /// printed, a pid by the identity read for it, the launcher's record by
    /// the handle it names.
    pub(super) fn replace(
        &mut self,
        old: &Obligation,
        by: &str,
        new: Obligation,
        role: Role,
        harness: Option<Harness>,
    ) {
        self.record.discharge_where(|o| o == old, by);
        self.add(new, role, harness);
    }

    /// The pane the receipt proved on its server is adopted under `role`:
    /// the receipt is read, the window or any other pane the `opening` named
    /// is settled by it, and `pane` on the proven server stands. A recorded
    /// pane whose key equals the adopted one keeps standing.
    pub(super) fn adopt(&mut self, pane: PaneRef, role: Role, harness: Option<Harness>) {
        self.record
            .discharge_where(|o| matches!(o, Obligation::Receipt), "receipt-read");
        let adopted = pane.obligation();
        self.record.discharge_where(
            |o| {
                *o != adopted
                    && matches!(
                        o,
                        Obligation::Window { .. }
                            | Obligation::Pane { .. }
                            | Obligation::PaneUnaddressed { .. }
                    )
            },
            "adopted",
        );
        self.add(adopted, role, harness);
    }

    /// A detached job asked for again: the launcher's unread record at
    /// `record` is a fresh acquisition each time the launcher is asked, so
    /// it joins the standing set even where an earlier ask's record was
    /// read. The path is recorded with the obligation:
    /// the reader of an unread sidecar reads that address and no other.
    pub(super) fn ask_job(&mut self, record: &Path) {
        let sidecar = Obligation::JobSidecar {
            record: record.display().to_string(),
        };
        if !self.record.stands(&sidecar) {
            self.record.standing.push(state::Held {
                obligation: sidecar,
                role: Some(Role::Job),
                harness: None,
            });
        }
    }

    /// The standing pane obligation `pane` on `server` is recorded under: the
    /// key with that id and server pid whose start is `server_start`, or, for
    /// a lane record the shell launcher wrote, unknown. `None` for
    /// `server_start` takes the key at any start.
    pub(super) fn pane_key(
        &self,
        pane: &str,
        server: u64,
        server_start: Option<u64>,
    ) -> Option<PaneRef> {
        self.record.standing_obligations().find_map(|o| match o {
            Obligation::Pane {
                pane: id,
                server: pid,
                server_start: start,
            } if id == pane
                && *pid == server
                && server_start.is_none_or(|at| start.is_none_or(|s| s == at)) =>
            {
                Some(PaneRef {
                    pane: id.clone(),
                    server: *pid,
                    server_start: *start,
                })
            }
            Obligation::Pane { .. }
            | Obligation::Process(_)
            | Obligation::Pid { .. }
            | Obligation::PaneUnaddressed { .. }
            | Obligation::Window { .. }
            | Obligation::Receipt
            | Obligation::JobSidecar { .. }
            | Obligation::JobUnit { .. }
            | Obligation::JobGroup(_)
            | Obligation::JobPgid { .. } => None,
        })
    }

    /// The token for `id`, where `Process(id)` stands.
    pub(super) fn standing_process(&self, id: &Identity) -> Option<Standing<Identity>> {
        self.stands(&Obligation::Process(id.clone()))
            .then(|| Standing { key: id.clone() })
    }

    /// The token for `pane`, where its key (id, server pid, server start)
    /// stands; the pane comes back where it does not.
    pub(super) fn standing_pane(&self, pane: Pane) -> std::result::Result<Standing<Pane>, Pane> {
        match self.pane_key(&pane.id, pane.server.pid as u64, Some(pane.server.start)) {
            Some(_) => Ok(Standing { key: pane }),
            None => Err(pane),
        }
    }

    /// The harness identity the set recorded under the harness role,
    /// standing or discharged: what a lane close stops, selected from the
    /// set and never from the lane's launch record.
    pub(super) fn harness_identity(&self) -> Option<Identity> {
        self.record
            .standing_obligations()
            .chain(self.record.discharged.iter().map(|d| &d.obligation))
            .find_map(|o| match o {
                Obligation::Process(id) if self.record.role_of(o) == Some(Role::Harness) => {
                    Some(id.clone())
                }
                Obligation::Process(_)
                | Obligation::Pid { .. }
                | Obligation::Pane { .. }
                | Obligation::PaneUnaddressed { .. }
                | Obligation::Window { .. }
                | Obligation::Receipt
                | Obligation::JobSidecar { .. }
                | Obligation::JobUnit { .. }
                | Obligation::JobGroup(_)
                | Obligation::JobPgid { .. } => None,
            })
    }

    /// The standing pid-only obligation under the harness role: a shell
    /// launcher's lane record's harness, named with no start.
    pub(super) fn harness_pid(&self) -> Option<u32> {
        self.record.standing_obligations().find_map(|o| match o {
            Obligation::Pid { pid } if self.record.role_of(o) == Some(Role::Harness) => Some(*pid),
            Obligation::Pid { .. }
            | Obligation::Process(_)
            | Obligation::Pane { .. }
            | Obligation::PaneUnaddressed { .. }
            | Obligation::Window { .. }
            | Obligation::Receipt
            | Obligation::JobSidecar { .. }
            | Obligation::JobUnit { .. }
            | Obligation::JobGroup(_)
            | Obligation::JobPgid { .. } => None,
        })
    }

    /// One more independent stale reading of `id`, recorded; the count so
    /// far. The rule for every recorded key: the second settles.
    pub(super) fn note_stale(&mut self, id: &Identity) -> u64 {
        let count = self
            .record
            .stale
            .entry(format!("{}:{}", id.pid, id.start))
            .or_insert(0);
        *count += 1;
        *count
    }

    /// The stale readings recorded for `id`.
    pub(super) fn stale_readings(&self, id: &Identity) -> u64 {
        self.record
            .stale
            .get(&format!("{}:{}", id.pid, id.start))
            .copied()
            .unwrap_or(0)
    }

    /// Every standing `Process` identity, in record order.
    pub(super) fn standing_processes(&self) -> Vec<Identity> {
        self.record
            .standing_obligations()
            .filter_map(|o| match o {
                Obligation::Process(id) => Some(id.clone()),
                Obligation::Pid { .. }
                | Obligation::Pane { .. }
                | Obligation::PaneUnaddressed { .. }
                | Obligation::Window { .. }
                | Obligation::Receipt
                | Obligation::JobSidecar { .. }
                | Obligation::JobUnit { .. }
                | Obligation::JobGroup(_)
                | Obligation::JobPgid { .. } => None,
            })
            .collect()
    }

    /// Whether the record carries `pid` as a process or pid obligation,
    /// standing or discharged: a receipt's registered pid the record already
    /// accounts for.
    pub(super) fn names_pid(&self, pid: u32) -> bool {
        let names = |o: &Obligation| match o {
            Obligation::Process(id) => id.pid == pid,
            Obligation::Pid { pid: p } => *p == pid,
            Obligation::Pane { .. }
            | Obligation::PaneUnaddressed { .. }
            | Obligation::Window { .. }
            | Obligation::Receipt
            | Obligation::JobSidecar { .. }
            | Obligation::JobUnit { .. }
            | Obligation::JobGroup(_)
            | Obligation::JobPgid { .. } => false,
        };
        self.record.standing_obligations().any(names)
            || self.record.discharged.iter().any(|d| names(&d.obligation))
    }

    pub(super) fn stands(&self, obligation: &Obligation) -> bool {
        self.record.stands(obligation)
    }

    /// The standing addressable pane recorded under `role`: what a window
    /// close names, selected from the set by role.
    pub(super) fn pane(&self, role: Role) -> Option<PaneRef> {
        self.record.standing_obligations().find_map(|o| match o {
            Obligation::Pane {
                pane,
                server,
                server_start,
            } if self.record.role_of(o) == Some(role) => Some(PaneRef {
                pane: pane.clone(),
                server: *server,
                server_start: *server_start,
            }),
            Obligation::Pane { .. } => None,
            Obligation::Process(_)
            | Obligation::Pid { .. }
            | Obligation::PaneUnaddressed { .. }
            | Obligation::Window { .. }
            | Obligation::Receipt
            | Obligation::JobSidecar { .. }
            | Obligation::JobUnit { .. }
            | Obligation::JobGroup(_)
            | Obligation::JobPgid { .. } => None,
        })
    }

    /// The detached job's standing obligations: its unread record, its unit
    /// or its group.
    pub(super) fn jobs(&self) -> Vec<Obligation> {
        self.record
            .standing_obligations()
            .filter(|o| ObligationRecord::is_job(o))
            .cloned()
            .collect()
    }

    /// Every standing addressable pane key, in record order: what a retry on
    /// the set alone closes.
    pub(super) fn standing_panes(&self) -> Vec<PaneRef> {
        self.record
            .standing_obligations()
            .filter_map(|o| match o {
                Obligation::Pane {
                    pane,
                    server,
                    server_start,
                } => Some(PaneRef {
                    pane: pane.clone(),
                    server: *server,
                    server_start: *server_start,
                }),
                Obligation::Process(_)
                | Obligation::Pid { .. }
                | Obligation::PaneUnaddressed { .. }
                | Obligation::Window { .. }
                | Obligation::Receipt
                | Obligation::JobSidecar { .. }
                | Obligation::JobUnit { .. }
                | Obligation::JobGroup(_)
                | Obligation::JobPgid { .. } => None,
            })
            .collect()
    }

    /// Record the first signal: from here nothing on this intent is a
    /// refusal. Whether this call was the first.
    pub(super) fn spend(&mut self) -> bool {
        let first = !self.record.signalled;
        self.record.signalled = true;
        first
    }

    /// The refusal token, minted only while the record says nothing was
    /// signalled on this intent, by any run.
    pub(super) fn unsignalled(&self) -> Option<Unsignalled> {
        if self.record.signalled {
            None
        } else {
            Some(Unsignalled(()))
        }
    }

    /// Settle the obligation `discharge` names with its evidence. An
    /// obligation the evidence does not settle stands, with the cause; so
    /// does one the evidence names that nothing recorded, since evidence
    /// about a handle the record does not carry settles nothing of it.
    pub(super) fn discharge(&mut self, discharge: Discharge) {
        let named = discharge.names();
        let judged = match discharge {
            Discharge::Process { end, .. } => ended(end),
            Discharge::Pid { read, .. } => match read {
                Reading::Gone => Ok("read-gone".to_owned()),
                Reading::Live(_) => Err("pid-live".to_owned()),
                Reading::Unreadable { cause } => Err(format!("pid-unreadable:{cause}")),
            },
            Discharge::Pane { end, .. } => match end {
                PaneEnd::Close(Close::Closed) => Ok("closed".to_owned()),
                PaneEnd::Close(Close::AlreadyGone) | PaneEnd::Gone => Ok("pane-gone".to_owned()),
                PaneEnd::Close(Close::Unreadable { cause }) => Err(format!("pane-close:{cause}")),
                PaneEnd::NotSignalled => Ok("not-signalled".to_owned()),
            },
            Discharge::Window { .. } => Ok("server-gone".to_owned()),
            Discharge::Receipt(end) => match end {
                ReceiptEnd::Absent => Ok("receipt-absent".to_owned()),
                ReceiptEnd::Read => Ok("receipt-read".to_owned()),
                ReceiptEnd::Invalid { cause } => Err(format!("receipt-invalid:{cause}")),
            },
            Discharge::Job { end, .. } => match end {
                JobEnd::UnitGone => Ok("unit-gone".to_owned()),
                JobEnd::UnitEnded { state } => Ok(format!("unit-{state}")),
                JobEnd::Exited => Ok("job-exited".to_owned()),
                JobEnd::Claimed => Ok("watch-claimed".to_owned()),
            },
            Discharge::Sidecar { read, .. } => match read {
                SidecarRead::Absent => Ok("sidecar-absent".to_owned()),
                SidecarRead::Present(_) => Ok("sidecar-read".to_owned()),
                SidecarRead::Failed { status } => Ok(format!("launch-failed:{status}")),
                SidecarRead::Unreadable { cause } => Err(format!("job-unread:{cause}")),
            },
        };
        if !self.record.stands(&named) {
            self.held.push("evidence-without-obligation".to_owned());
            return;
        }
        match judged {
            Ok(by) => {
                self.record.discharge_where(|o| *o == named, &by);
            }
            Err(cause) => self.held.push(cause),
        }
    }

    /// The proof that nothing stands, or what still does.
    pub(super) fn settled(self) -> std::result::Result<Settled, Obligations> {
        if self.record.standing.is_empty() {
            Ok(Settled(self.record))
        } else {
            Err(self)
        }
    }

    /// The proof a publication needs: `handles`, the runner's own pane and
    /// identity, pass to the record the publication writes and are settled
    /// by that; everything else the set names must already be discharged,
    /// else the set comes back unchanged.
    pub(super) fn publish(
        mut self,
        handles: impl IntoIterator<Item = Obligation>,
    ) -> std::result::Result<Settled, Obligations> {
        let handles: Vec<Obligation> = handles.into_iter().collect();
        if self
            .record
            .standing_obligations()
            .any(|o| !handles.contains(o))
        {
            return Err(self);
        }
        for handle in handles {
            self.record.discharge_where(|o| *o == handle, "published");
        }
        self.settled()
    }

    /// The terminal `word` once every obligation is discharged, else
    /// `unconfirmed` with what stands.
    pub(super) fn judge(self, word: Word) -> Terminal {
        match self.settled() {
            Ok(_settled) => match word {
                Word::Failed => Terminal::Failed,
                Word::Confirmed => Terminal::Confirmed,
            },
            Err(remaining) => Terminal::Unconfirmed { remaining },
        }
    }

    /// The first reason a discharge left its obligation standing.
    pub(super) fn cause(&self) -> Option<&str> {
        self.held.first().map(String::as_str)
    }

    /// The standing obligations as an observation carries them: one JSON
    /// object per handle, keyed by `kind`, the form a reconcile's `remaining`
    /// takes.
    pub(super) fn value(&self) -> Value {
        Value::Array(
            self.record
                .standing_obligations()
                .map(observation_value)
                .collect(),
        )
    }

    pub(super) fn record(&self) -> &ObligationRecord {
        &self.record
    }

    /// The revision the store assigned the set at its last write, mirrored.
    pub(super) fn set_revision(&mut self, revision: u64) {
        self.record.revision = revision;
    }
}

/// One standing obligation as a reconcile's `remaining` observation carries
/// it: keyed by `kind`, a pane with no server marked `unaddressable`, a
/// detached job by its unit, its group identity or its unread sidecar.
fn observation_value(obligation: &Obligation) -> Value {
    match obligation {
        Obligation::Process(id) => json!({"kind": "process", "pid": id.pid, "start": id.start}),
        Obligation::Pid { pid } => json!({"kind": "pid", "pid": pid}),
        Obligation::Pane {
            pane,
            server,
            server_start,
        } => json!({"kind": "pane", "pane": pane, "server": server, "server_start": server_start}),
        Obligation::PaneUnaddressed { pane } => {
            json!({"kind": "pane", "pane": pane, "server": Value::Null, "unaddressable": true})
        }
        Obligation::Window {
            server,
            server_start,
        } => json!({"kind": "window", "server": server, "server_start": server_start}),
        Obligation::Receipt => json!({"kind": "receipt"}),
        Obligation::JobSidecar { .. } => json!({"kind": "job", "job": "possibly-started"}),
        Obligation::JobUnit { unit } => json!({"kind": "job", "unit": unit}),
        Obligation::JobGroup(id) => json!({"kind": "job", "pid": id.pid, "start": id.start}),
        Obligation::JobPgid { pgid } => json!({"kind": "job", "pgid": pgid}),
    }
}

/// A process end on its own: stopped, already gone, read gone, or the second
/// stale reading. A pid reused on one reading, a stop that timed out or could
/// not read, a reading live or unreadable settle nothing.
fn ended(end: ProcessEnd) -> std::result::Result<String, String> {
    match end {
        ProcessEnd::Stop(Stop::Stopped { .. }) => Ok("stopped".to_owned()),
        ProcessEnd::Stop(Stop::AlreadyGone) => Ok("already-gone".to_owned()),
        ProcessEnd::Stop(Stop::IdentityStale) => Err("identity-stale".to_owned()),
        ProcessEnd::Stop(Stop::Timeout { pid }) => Err(format!("stop-timeout:{pid}")),
        ProcessEnd::Stop(Stop::Unreadable { cause, .. }) => Err(format!("stop-unreadable:{cause}")),
        ProcessEnd::Read(Reading::Gone) => Ok("read-gone".to_owned()),
        ProcessEnd::Read(Reading::Live(_)) => Err("identity-live".to_owned()),
        ProcessEnd::Read(Reading::Unreadable { cause }) => {
            Err(format!("identity-unreadable:{cause}"))
        }
        ProcessEnd::Stale { readings } if readings >= 2 => Ok(format!("stale-readings:{readings}")),
        ProcessEnd::Stale { .. } => Err("identity-stale".to_owned()),
        ProcessEnd::NotSignalled => Ok("not-signalled".to_owned()),
    }
}

/// `observation` with `cause` written where it names none.
fn with_cause(mut observation: Value, cause: Option<&str>) -> Value {
    if let Some(cause) = cause
        && observation.get("cause").is_none_or(Value::is_null)
    {
        observation["cause"] = json!(cause);
    }
    observation
}

/// The word a settled set of obligations ends an intent with.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Word {
    Failed,
    Confirmed,
}

/// What a confirmed launch or succession published: the pane and identity
/// on the wire are the lane's record, or the controller's, from here.
#[derive(Debug)]
pub enum Published {
    Lane,
    Successor,
}

/// How an effect ended, or did not.
pub(super) enum Terminal {
    /// An obligation stands undischarged: the intent stays open with what
    /// remains.
    Unconfirmed {
        remaining: Obligations,
    },
    /// Every obligation discharged: built from a [`Settled`] proof alone.
    Failed,
    Confirmed,
    Published(Published),
    /// The effect closed nothing by design: the intent ends `failed` with
    /// `cause`, and `untouched` stands where its record keeps it.
    Refused {
        cause: String,
        untouched: Obligations,
    },
}

/// The record fields an outcome carries beside its word: what a confirmed
/// launch or succession publishes, or the pane an unconfirmed effect keeps
/// for its reconcile.
#[derive(Default)]
pub struct Wire {
    pub launch: Option<LaunchIdentity>,
    pub session_id: Option<String>,
    pub server_start: Option<u64>,
    pub server_socket: Option<String>,
    pub window: Option<String>,
    pub tmux_session: Option<String>,
    /// The home a confirmed controller or local lane runs its sessions
    /// under, as its launch prepared it.
    pub home: Option<String>,
    /// That launch named no home, the lane's `home_implicit`.
    pub home_implicit: bool,
    /// The fleet watch a confirmed start launched or found claimed.
    pub watch: Option<WatchJob>,
    /// The root a confirmed lane's files are read under, where its host
    /// named one the request could not know.
    pub mail_root: Option<String>,
}

/// An effect's result: the one type `apply_outcome` records. `record` is the
/// obligation set as the effect left it, written with the outcome;
/// `while_owner` is the owner the writes are made
/// under, where the writer may have lost the intent to a claimant;
/// `principal_keys` are the keys a terminal carries to the store's
/// moved-lane judgement.
pub struct EffectOutcome {
    pub(super) intent_id: String,
    /// The intent's operation, which decides what announcement the outcome
    /// owes.
    pub(super) op: EffectOp,
    pub(super) terminal: Terminal,
    pub(super) observation: Value,
    pub(super) wire: Wire,
    pub(super) record: ObligationRecord,
    pub(super) while_owner: Option<Owner>,
    pub(super) principal_keys: Vec<Obligation>,
    /// The identities the handle read stale this run, for the stop the same
    /// request reruns.
    pub(super) stale: Vec<Identity>,
}

impl EffectOutcome {
    fn new(
        intent_id: &str,
        op: EffectOp,
        terminal: Terminal,
        observation: Value,
        record: ObligationRecord,
    ) -> EffectOutcome {
        EffectOutcome {
            intent_id: intent_id.to_owned(),
            op,
            terminal,
            observation,
            wire: Wire::default(),
            record,
            while_owner: None,
            principal_keys: Vec::new(),
            stale: Vec::new(),
        }
    }

    /// The terminal `word` if `obligations` are all discharged, else
    /// `unconfirmed` with what remains; the first held cause is written as
    /// the observation's `cause` where it names none.
    pub(super) fn judged(
        intent_id: &str,
        op: EffectOp,
        obligations: Obligations,
        word: Word,
        observation: Value,
    ) -> EffectOutcome {
        let observation = with_cause(observation, obligations.cause());
        let record = obligations.record.clone();
        EffectOutcome::new(intent_id, op, obligations.judge(word), observation, record)
    }

    /// Nothing ends here: the intent stays open with `remaining`, whatever
    /// it holds, and the first held cause is written as the observation's
    /// `cause` where it names none.
    pub(super) fn unconfirmed(
        intent_id: &str,
        op: EffectOp,
        remaining: Obligations,
        observation: Value,
    ) -> EffectOutcome {
        let observation = with_cause(observation, remaining.cause());
        let record = remaining.record.clone();
        EffectOutcome::new(
            intent_id,
            op,
            Terminal::Unconfirmed { remaining },
            observation,
            record,
        )
    }

    pub(super) fn published(
        intent_id: &str,
        op: EffectOp,
        published: Published,
        settled: Settled,
        observation: Value,
    ) -> EffectOutcome {
        EffectOutcome::new(
            intent_id,
            op,
            Terminal::Published(published),
            observation,
            settled.0,
        )
    }

    /// A refusal, with the token that proves nothing was signalled.
    pub(super) fn refused(
        intent_id: &str,
        op: EffectOp,
        _unsignalled: Unsignalled,
        untouched: Obligations,
        cause: &str,
        observation: Value,
    ) -> EffectOutcome {
        let mut observation = observation;
        observation["cause"] = json!(cause);
        let record = untouched.record.clone();
        EffectOutcome::new(
            intent_id,
            op,
            Terminal::Refused {
                cause: cause.to_owned(),
                untouched,
            },
            observation,
            record,
        )
    }

    /// A refusal with `cause` where the intent's record says nothing was
    /// signalled, else the same cause as an `unconfirmed` outcome with
    /// `signalled` and everything still standing.
    pub(super) fn refused_or_held(
        intent_id: &str,
        op: EffectOp,
        obligations: Obligations,
        cause: &str,
        mut observation: Value,
    ) -> EffectOutcome {
        match obligations.unsignalled() {
            Some(unsignalled) => {
                EffectOutcome::refused(intent_id, op, unsignalled, obligations, cause, observation)
            }
            None => {
                observation["cause"] = json!(cause);
                observation["signalled"] = json!(true);
                EffectOutcome::unconfirmed(intent_id, op, obligations, observation)
            }
        }
    }

    pub fn with_wire(self, wire: Wire) -> EffectOutcome {
        EffectOutcome { wire, ..self }
    }

    /// The owner the launcher-side writes of this outcome are made under; the
    /// record is a no-op once another owner holds the intent.
    pub(super) fn owned_by(self, while_owner: Option<Owner>) -> EffectOutcome {
        EffectOutcome {
            while_owner,
            ..self
        }
    }

    /// The lane keys this outcome carries to the store.
    pub(super) fn keyed(self, principal_keys: Vec<Obligation>) -> EffectOutcome {
        EffectOutcome {
            principal_keys,
            ..self
        }
    }

    /// The identities the handle read stale this run.
    pub(super) fn read_stale(self, stale: Vec<Identity>) -> EffectOutcome {
        EffectOutcome { stale, ..self }
    }

    /// The identities this outcome's handle read stale, which the stop the
    /// same request reruns counts no second time.
    pub fn stale_read(&self) -> Vec<Identity> {
        self.stale.clone()
    }

    /// Write `value` under `key` on the observation: a caller's note beside
    /// the outcome, never its word or its set.
    pub fn annotate(&mut self, key: &str, value: Value) {
        self.observation[key] = value;
    }

    /// Whether the observation names `key`.
    pub fn notes(&self, key: &str) -> bool {
        self.observation.get(key).is_some_and(|v| !v.is_null())
    }

    pub fn intent_id(&self) -> &str {
        &self.intent_id
    }

    /// The intent's operation: which recording boundary takes the outcome.
    pub fn op(&self) -> EffectOp {
        self.op
    }

    /// The keys the set recorded under the principal's role, which a caller
    /// carries for its target's record under the stamp it knows.
    pub fn principal_keys(&self) -> &[Obligation] {
        &self.principal_keys
    }

    /// Whether the outcome ends the intent: a terminal word or a
    /// publication, never a hold.
    pub fn ended(&self) -> bool {
        match &self.terminal {
            Terminal::Failed
            | Terminal::Confirmed
            | Terminal::Published(_)
            | Terminal::Refused { .. } => true,
            Terminal::Unconfirmed { .. } => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(pid: u32) -> Identity {
        Identity {
            pid,
            start: format!("ticks:{pid}"),
        }
    }

    fn pane() -> PaneRef {
        PaneRef {
            pane: "%7".to_owned(),
            server: 4242,
            server_start: None,
        }
    }

    fn launch(
        pane: Option<&str>,
        server: Option<u64>,
        pid: Option<u64>,
        start: Option<&str>,
    ) -> LaunchIdentity {
        LaunchIdentity {
            pane: pane.map(str::to_owned),
            server,
            server_start: None,
            pid,
            start: start.map(str::to_owned),
        }
    }

    fn pane_and_process() -> Obligations {
        Obligations::of_launch(
            Some(&launch(Some("%7"), Some(4242), Some(31), Some("ticks:31"))),
            None,
        )
    }

    fn standing(obligations: &Obligations) -> Vec<Obligation> {
        obligations.record.standing_obligations().cloned().collect()
    }

    fn discharged_by(obligations: &Obligations) -> Vec<String> {
        obligations
            .record
            .discharged
            .iter()
            .map(|d| d.by.clone())
            .collect()
    }

    #[test]
    fn a_settlement_needs_every_obligation_discharged_by_its_own_evidence() {
        // (discharges, settles, the held cause)
        let rows: Vec<(&str, Vec<Discharge>, bool, Option<&str>)> = vec![
            (
                "pane gone and process read gone",
                vec![
                    Discharge::Pane {
                        pane: pane(),
                        end: PaneEnd::Gone,
                    },
                    Discharge::Process {
                        identity: identity(31),
                        end: ProcessEnd::Read(Reading::Gone),
                    },
                ],
                true,
                None,
            ),
            (
                "pane gone alone leaves the process standing",
                vec![Discharge::Pane {
                    pane: pane(),
                    end: PaneEnd::Gone,
                }],
                false,
                None,
            ),
            (
                "pane gone and the process read live",
                vec![
                    Discharge::Pane {
                        pane: pane(),
                        end: PaneEnd::Gone,
                    },
                    Discharge::Process {
                        identity: identity(31),
                        end: ProcessEnd::Read(Reading::Live(identity(31))),
                    },
                ],
                false,
                Some("identity-live"),
            ),
            (
                "process stopped and the window closed",
                vec![
                    Discharge::Process {
                        identity: identity(31),
                        end: ProcessEnd::Stop(Stop::Stopped { signaled: 1 }),
                    },
                    Discharge::Pane {
                        pane: pane(),
                        end: PaneEnd::Close(Close::Closed),
                    },
                ],
                true,
                None,
            ),
            (
                "a close the host did not answer",
                vec![
                    Discharge::Process {
                        identity: identity(31),
                        end: ProcessEnd::Stop(Stop::AlreadyGone),
                    },
                    Discharge::Pane {
                        pane: pane(),
                        end: PaneEnd::Close(Close::Unreadable {
                            cause: "timeout".to_owned(),
                        }),
                    },
                ],
                false,
                Some("pane-close:timeout"),
            ),
            (
                "a stop that timed out",
                vec![
                    Discharge::Pane {
                        pane: pane(),
                        end: PaneEnd::Close(Close::Closed),
                    },
                    Discharge::Process {
                        identity: identity(31),
                        end: ProcessEnd::Stop(Stop::Timeout { pid: 31 }),
                    },
                ],
                false,
                Some("stop-timeout:31"),
            ),
            (
                "a stop that could not read",
                vec![Discharge::Process {
                    identity: identity(31),
                    end: ProcessEnd::Stop(Stop::Unreadable {
                        pid: 31,
                        cause: "proc".to_owned(),
                        signalled: false,
                    }),
                }],
                false,
                Some("stop-unreadable:proc"),
            ),
            (
                "one stale reading, the pane closed",
                vec![
                    Discharge::Pane {
                        pane: pane(),
                        end: PaneEnd::Close(Close::Closed),
                    },
                    Discharge::Process {
                        identity: identity(31),
                        end: ProcessEnd::Stale { readings: 1 },
                    },
                ],
                false,
                Some("identity-stale"),
            ),
            (
                "the second stale reading, the pane gone",
                vec![
                    Discharge::Pane {
                        pane: pane(),
                        end: PaneEnd::Gone,
                    },
                    Discharge::Process {
                        identity: identity(31),
                        end: ProcessEnd::Stale { readings: 2 },
                    },
                ],
                true,
                None,
            ),
            (
                "a stop whose identity went stale",
                vec![Discharge::Process {
                    identity: identity(31),
                    end: ProcessEnd::Stop(Stop::IdentityStale),
                }],
                false,
                Some("identity-stale"),
            ),
            (
                "another process's stop discharges nothing recorded",
                vec![
                    Discharge::Pane {
                        pane: pane(),
                        end: PaneEnd::Close(Close::Closed),
                    },
                    Discharge::Process {
                        identity: identity(99),
                        end: ProcessEnd::Stop(Stop::Stopped { signaled: 1 }),
                    },
                ],
                false,
                Some("evidence-without-obligation"),
            ),
            (
                "another pane's close discharges nothing recorded",
                vec![Discharge::Pane {
                    pane: PaneRef {
                        pane: "%8".to_owned(),
                        server: 4242,
                        server_start: None,
                    },
                    end: PaneEnd::Close(Close::Closed),
                }],
                false,
                Some("evidence-without-obligation"),
            ),
            (
                "the same pane id on another server discharges nothing",
                vec![Discharge::Pane {
                    pane: PaneRef {
                        pane: "%7".to_owned(),
                        server: 4243,
                        server_start: None,
                    },
                    end: PaneEnd::Gone,
                }],
                false,
                Some("evidence-without-obligation"),
            ),
            (
                "the same pane id and server pid at another server start discharges nothing",
                vec![Discharge::Pane {
                    pane: PaneRef {
                        pane: "%7".to_owned(),
                        server: 4242,
                        server_start: Some(9),
                    },
                    end: PaneEnd::Gone,
                }],
                false,
                Some("evidence-without-obligation"),
            ),
        ];
        for (name, discharges, settles, cause) in rows {
            let mut obligations = pane_and_process();
            for discharge in discharges {
                obligations.discharge(discharge);
            }
            assert_eq!(obligations.cause(), cause, "{name}: cause");
            assert_eq!(obligations.settled().is_ok(), settles, "{name}");
        }
    }

    #[test]
    fn a_handle_read_on_the_way_is_an_obligation_until_its_own_end() {
        // The foreground found in the recorded pane is stopped by
        // its own identity; its stop settles it and nothing else.
        let mut obligations =
            Obligations::of_launch(Some(&launch(Some("%7"), Some(4242), None, None)), None);
        obligations.add(Obligation::Process(identity(77)), Role::Harness, None);
        obligations.discharge(Discharge::Pane {
            pane: pane(),
            end: PaneEnd::Close(Close::Closed),
        });
        let remaining = obligations
            .clone()
            .settled()
            .expect_err("the foreground stands");
        assert_eq!(
            standing(&remaining),
            vec![Obligation::Process(identity(77))]
        );
        obligations.discharge(Discharge::Process {
            identity: identity(77),
            end: ProcessEnd::Stop(Stop::Stopped { signaled: 1 }),
        });
        assert_eq!(discharged_by(&obligations), vec!["closed", "stopped"]);
        // A discharged handle is not added again by a later read of the
        // record.
        obligations.add(Obligation::Process(identity(77)), Role::Harness, None);
        assert!(obligations.settled().is_ok());
    }

    #[test]
    fn a_record_without_a_server_or_a_start_keeps_what_it_names_as_an_obligation() {
        let serverless = Obligations::of_launch(
            Some(&launch(Some("%7"), None, Some(31), Some("ticks:31"))),
            None,
        );
        assert_eq!(
            standing(&serverless),
            vec![
                Obligation::PaneUnaddressed {
                    pane: "%7".to_owned()
                },
                Obligation::Process(identity(31)),
            ]
        );
        let mut serverless = serverless;
        serverless.discharge(Discharge::Process {
            identity: identity(31),
            end: ProcessEnd::Read(Reading::Gone),
        });
        let remaining = serverless
            .settled()
            .expect_err("the pane stands unaddressed");
        assert_eq!(
            standing(&remaining),
            vec![Obligation::PaneUnaddressed {
                pane: "%7".to_owned()
            }]
        );
        assert_eq!(
            remaining.pane(Role::Harness),
            None,
            "an unaddressed pane is not what a close names"
        );

        let mut startless = Obligations::of_launch(Some(&launch(None, None, Some(31), None)), None);
        assert_eq!(standing(&startless), vec![Obligation::Pid { pid: 31 }]);
        startless.discharge(Discharge::Pid {
            pid: 31,
            read: Reading::Live(identity(31)),
        });
        assert_eq!(startless.cause(), Some("pid-live"));
        startless.discharge(Discharge::Pid {
            pid: 31,
            read: Reading::Gone,
        });
        assert!(startless.settled().is_ok());

        assert_eq!(
            standing(&Obligations::of_launch(None, None)),
            Vec::<Obligation>::new()
        );
        assert_eq!(
            standing(&Obligations::of_launch(
                Some(&launch(None, Some(4242), None, None)),
                None
            )),
            Vec::<Obligation>::new()
        );
    }

    fn opening(asked: bool, pane: Option<&str>) -> Phase {
        Phase::Opening {
            opening: crate::state::Opening {
                server: 4242,
                server_start: 1,
                server_process_start: None,
                socket: String::new(),
                since_ms: 0,
                brief: None,
                session_id: None,
                baseline: Vec::new(),
                pane: pane.map(str::to_owned),
                asked,
                home: None,
                home_implicit: false,
            },
        }
    }

    /// The receipt is an obligation from the ask on, until
    /// read; the window possibly opened is settled by the server's end or
    /// replaced by the pane the creating call printed; a receipt invalid or
    /// unreadable stands, one absent past the bound or read is settled.
    #[test]
    fn an_opening_owes_its_receipt_and_window_until_each_is_read() {
        assert_eq!(
            standing(&Obligations::of_phase(
                Some(&opening(false, None)),
                Role::Runner,
                None
            )),
            Vec::<Obligation>::new(),
            "a launcher never asked opened nothing"
        );
        let mut asked = Obligations::of_phase(Some(&opening(true, None)), Role::Runner, None);
        assert_eq!(
            standing(&asked),
            vec![
                Obligation::Receipt,
                Obligation::Window {
                    server: 4242,
                    server_start: 1
                }
            ]
        );
        asked.discharge(Discharge::Window {
            server: 4242,
            server_start: 1,
        });
        asked.discharge(Discharge::Receipt(ReceiptEnd::Invalid {
            cause: "json-invalid",
        }));
        assert_eq!(asked.cause(), Some("receipt-invalid:json-invalid"));
        assert_eq!(standing(&asked), vec![Obligation::Receipt]);
        asked.discharge(Discharge::Receipt(ReceiptEnd::Absent));
        assert!(asked.settled().is_ok());

        let mut opened = Obligations::of_phase(Some(&opening(true, None)), Role::Runner, None);
        opened.replace(
            &Obligation::Window {
                server: 4242,
                server_start: 1,
            },
            "pane-recorded",
            Obligation::Pane {
                pane: "%7".to_owned(),
                server: 4242,
                server_start: Some(1),
            },
            Role::Runner,
            None,
        );
        assert_eq!(
            standing(&opened),
            standing(&Obligations::of_phase(
                Some(&opening(true, Some("%7"))),
                Role::Runner,
                None
            ))
        );
        assert_eq!(discharged_by(&opened), vec!["pane-recorded"]);
        assert_eq!(
            standing(&Obligations::of_phase(None, Role::Runner, None)),
            Vec::<Obligation>::new()
        );
    }

    /// The launcher's record is an obligation from the ask
    /// until read; the handle it names stands until its unit or group is
    /// read ended; an unreadable record stands as the job unread. The
    /// obligation carries the record's address, and a read of
    /// another address settles nothing of it.
    #[test]
    fn a_job_asked_of_its_launcher_stands_until_its_record_and_handle_are_read() {
        let unit = JobHandle::Unit {
            unit: "orch-transfer-1".to_owned(),
        };
        let record = Path::new("/fleet/intents/transfer.job");
        let sidecar = Obligation::JobSidecar {
            record: record.display().to_string(),
        };
        let at = |read: SidecarRead| Discharge::Sidecar {
            record: record.display().to_string(),
            read,
        };
        let mut asked = Obligations::none();
        asked.ask_job(record);
        assert_eq!(standing(&asked), vec![sidecar.clone()]);
        let mut other = asked.clone();
        other.discharge(Discharge::Sidecar {
            record: "/fleet/oversee-watch.runner".to_owned(),
            read: SidecarRead::Absent,
        });
        assert_eq!(other.cause(), Some("evidence-without-obligation"));
        assert_eq!(standing(&other), vec![sidecar.clone()]);
        asked.discharge(at(SidecarRead::Unreadable {
            cause: "eacces".to_owned(),
        }));
        assert_eq!(asked.cause(), Some("job-unread:eacces"));
        assert!(asked.clone().settled().is_err());
        asked.discharge(at(SidecarRead::Present(unit.clone())));
        asked.add(
            Obligation::JobUnit {
                unit: "orch-transfer-1".to_owned(),
            },
            Role::Job,
            None,
        );
        assert_eq!(
            asked.jobs(),
            vec![Obligation::JobUnit {
                unit: "orch-transfer-1".to_owned()
            }]
        );
        asked.discharge(Discharge::Job {
            job: unit,
            end: JobEnd::UnitGone,
        });
        assert!(asked.settled().is_ok());

        let mut group = Obligations::none();
        group.ask_job(record);
        group.replace(
            &sidecar,
            "sidecar-read",
            Obligation::JobGroup(identity(31)),
            Role::Job,
            None,
        );
        group.discharge(Discharge::Job {
            job: JobHandle::Group(identity(32)),
            end: JobEnd::Exited,
        });
        assert_eq!(group.cause(), Some("evidence-without-obligation"));
        group.discharge(Discharge::Job {
            job: JobHandle::Group(identity(31)),
            end: JobEnd::Exited,
        });
        assert_eq!(discharged_by(&group), vec!["sidecar-read", "job-exited"]);
        assert!(group.settled().is_ok());

        let mut none = Obligations::none();
        none.ask_job(record);
        none.discharge(at(SidecarRead::Absent));
        assert!(none.clone().settled().is_ok());
        // A job asked for again extends the recorded set:
        // the sidecar an earlier ask discharged is no bar to the next ask.
        none.ask_job(record);
        assert_eq!(standing(&none), vec![sidecar]);
        assert_eq!(discharged_by(&none), vec!["sidecar-absent"]);
    }

    /// A publication consumes the whole set. The runner's
    /// own pane and identity pass to the record it publishes; a predecessor
    /// handle still standing keeps the set unsettled, and so does the receipt
    /// until its own read discharges it.
    #[test]
    fn a_publication_consumes_the_runners_handles_and_needs_every_other_discharged() {
        let runner_pane = Obligation::Pane {
            pane: "%3".to_owned(),
            server: 4242,
            server_start: Some(1),
        };
        let runner = Obligation::Process(identity(41));
        let predecessor_pane = Obligation::Pane {
            pane: "%1".to_owned(),
            server: 4242,
            server_start: Some(1),
        };
        let mut set = Obligations::of(
            vec![
                Obligation::Receipt,
                runner_pane.clone(),
                runner.clone(),
                predecessor_pane.clone(),
                Obligation::Process(identity(11)),
            ],
            Role::Runner,
            None,
        );
        set.discharge(Discharge::Process {
            identity: identity(11),
            end: ProcessEnd::Stop(Stop::Stopped { signaled: 1 }),
        });
        let held = set
            .clone()
            .publish([runner_pane.clone(), runner.clone()])
            .expect_err("the predecessor's window and the receipt stand");
        // A failed publication discharges nothing: the runner's own handles
        // stand too, consumed only by one that settles.
        assert_eq!(
            standing(&held),
            vec![
                Obligation::Receipt,
                runner_pane.clone(),
                runner.clone(),
                predecessor_pane.clone()
            ]
        );
        set.discharge(Discharge::Pane {
            pane: PaneRef {
                pane: "%1".to_owned(),
                server: 4242,
                server_start: Some(1),
            },
            end: PaneEnd::Close(Close::Closed),
        });
        let held = set
            .clone()
            .publish([runner_pane.clone(), runner.clone()])
            .expect_err("the receipt stands until read");
        assert_eq!(
            standing(&held),
            vec![Obligation::Receipt, runner_pane.clone(), runner.clone()]
        );
        set.discharge(Discharge::Receipt(ReceiptEnd::Read));
        let settled = set
            .publish([runner_pane, runner])
            .expect("every handle settled");
        assert!(settled.0.standing.is_empty());
        assert_eq!(
            settled
                .0
                .discharged
                .iter()
                .filter(|d| d.by == "published")
                .count(),
            2,
            "the runner's pane and identity passed to the record"
        );
    }

    /// The token is minted from the record alone. A record
    /// that says the intent signalled mints none on any later run, so a
    /// refusal site reached then holds instead; the bootstrap of an intent
    /// without a record is the initial writer's set, and a recorded set is
    /// read as written, whatever the lane says now.
    #[test]
    fn the_refusal_token_and_the_standing_set_come_from_the_record() {
        let mut set = pane_and_process();
        assert!(set.unsignalled().is_some());
        assert!(set.spend(), "the first signal");
        assert!(!set.spend(), "a second signal is not the first");
        assert!(set.unsignalled().is_none());
        let intent = Intent {
            id: "i".to_owned(),
            op: crate::state::EffectOp::CloseOwnedResources,
            target: "KEN-1".to_owned(),
            created_at: String::new(),
            owner: None,
            outcome: agent_runtime::protocol::Outcome::NotStarted,
            completed_at: None,
            lane_since: None,
            selection: None,
            original_pending: None,
            cause: None,
            handed_from: None,
            exclude_account: None,
            watch: None,
            close: None,
            cycle: None,
            notice: None,
            phase: None,
            obligations: Some(set.record.clone()),
            observation: None,
            reconciled: None,
            observed_status: None,
            observed_generation: None,
            extra: Default::default(),
        };
        let recorded = Obligations::recorded(&intent)
            .unwrap()
            .expect("the record stands");
        assert_eq!(recorded, set);
        assert!(recorded.unsignalled().is_none());
        let held = EffectOutcome::refused_or_held(
            "i",
            EffectOp::CloseOwnedResources,
            recorded,
            "ask-unanswered",
            json!({}),
        );
        assert!(matches!(held.terminal, Terminal::Unconfirmed { .. }));
        assert_eq!(held.observation["signalled"], true);
        assert!(held.record.signalled);
        let fresh = Intent {
            obligations: None,
            ..intent
        };
        assert!(Obligations::recorded(&fresh).unwrap().is_none());
        // The three refusal sites of the pane route hold the same way once
        // signalled, and refuse before.
        for cause in ["identity-unrecorded", "ask-unanswered", "ask-check-failed"] {
            let mut signalled = pane_and_process();
            signalled.spend();
            let held = EffectOutcome::refused_or_held(
                "i",
                EffectOp::CloseOwnedResources,
                signalled.clone(),
                cause,
                json!({"ask": "a1"}),
            );
            match held.terminal {
                Terminal::Unconfirmed { remaining } => assert_eq!(remaining, signalled, "{cause}"),
                Terminal::Failed
                | Terminal::Confirmed
                | Terminal::Published(_)
                | Terminal::Refused { .. } => panic!("{cause}: a signalled close cannot refuse"),
            }
            assert_eq!(held.observation["cause"], cause);
            assert_eq!(held.observation["ask"], "a1");
            let refused = EffectOutcome::refused_or_held(
                "i",
                EffectOp::CloseOwnedResources,
                pane_and_process(),
                cause,
                json!({}),
            );
            assert!(
                matches!(refused.terminal, Terminal::Refused { .. }),
                "{cause}: before any signal the same site refuses"
            );
        }
    }

    #[test]
    fn an_unconfirmed_outcome_never_ends_the_intent_and_a_refusal_mints_no_settlement() {
        let mut settled = pane_and_process();
        settled.discharge(Discharge::Pane {
            pane: pane(),
            end: PaneEnd::Gone,
        });
        settled.discharge(Discharge::Process {
            identity: identity(31),
            end: ProcessEnd::Read(Reading::Gone),
        });
        let outcome =
            EffectOutcome::unconfirmed("i", EffectOp::CloseOwnedResources, settled, json!({}));
        assert!(matches!(outcome.terminal, Terminal::Unconfirmed { .. }));
        assert_eq!(outcome.record.discharged.len(), 2);
        let token = pane_and_process().unsignalled().expect("nothing signalled");
        let refused = EffectOutcome::refused(
            "i",
            EffectOp::CloseOwnedResources,
            token,
            pane_and_process(),
            "ask-unanswered",
            json!({"ask": "a1"}),
        );
        assert_eq!(refused.observation["cause"], json!("ask-unanswered"));
        match refused.terminal {
            Terminal::Refused { cause, untouched } => {
                assert_eq!(cause, "ask-unanswered");
                assert_eq!(untouched, pane_and_process());
            }
            Terminal::Unconfirmed { .. }
            | Terminal::Failed
            | Terminal::Confirmed
            | Terminal::Published(_) => panic!("a refusal is its own terminal"),
        }
        let judged = EffectOutcome::judged(
            "i",
            EffectOp::CloseOwnedResources,
            pane_and_process(),
            Word::Confirmed,
            json!({}),
        );
        assert!(matches!(judged.terminal, Terminal::Unconfirmed { .. }));
        assert_eq!(judged.observation.get("cause"), None);
    }
    /// The set records a role per obligation, so a lane's launch record that
    /// names the recorded wake does not make the wake the principal harness.
    /// The harness is selected from the set by role, and a launch naming any
    /// other key is a moved lane under the one judgement the store applies
    /// too.
    #[test]
    fn a_launch_naming_the_recorded_wake_does_not_make_the_wake_the_harness() {
        let harness = identity(11);
        let wake = identity(12);
        let mut set = Obligations::of_launch(
            Some(&launch(Some("%7"), Some(4242), Some(11), Some("ticks:11"))),
            None,
        );
        set.add(Obligation::Process(wake.clone()), Role::Auxiliary, None);
        assert_eq!(set.harness_identity(), Some(harness.clone()));
        let keys = crate::state::PrincipalKeys {
            since: Some("2026-01-29T15:20:00Z".to_owned()),
            keys: set.record().principal_keys(Role::Harness),
        };
        assert_eq!(
            keys.keys,
            vec![
                Obligation::Pane {
                    pane: "%7".to_owned(),
                    server: 4242,
                    server_start: None
                },
                Obligation::Process(harness),
            ],
            "the keys are the harness role's alone, never the wake"
        );
        let mut lane: crate::state::Lane =
            serde_json::from_value(json!({"item": "KEN-1", "status": "running"})).unwrap();
        lane.session_since = Some("2026-01-29T15:20:00Z".to_owned());
        lane.launch = Some(launch(Some("%7"), Some(4242), Some(12), Some("ticks:12")));
        assert!(
            crate::ops::lane_moved(&lane, &keys),
            "a launch naming the wake under the same stamp is a moved lane"
        );
        lane.launch = Some(launch(Some("%7"), Some(4242), Some(11), Some("ticks:11")));
        assert!(!crate::ops::lane_moved(&lane, &keys));
        lane.session_since = Some("2026-01-29T16:00:00Z".to_owned());
        assert!(
            crate::ops::lane_moved(&lane, &keys),
            "another stamp alone moves it"
        );
    }
}
