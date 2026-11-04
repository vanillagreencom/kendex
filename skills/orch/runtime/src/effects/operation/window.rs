//! The handle's window methods: the `opening` record, the window open with
//! its receipt and launch line, the poll of a pane, and the recovery of an
//! effect interrupted at `opening`. Every acquisition on the way is written
//! before the action or wait that follows it, and every discharge comes from
//! this handle's own read.

use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use agent_runtime::harness::Harness;
use agent_runtime::host::tmux;
use agent_runtime::launch::LaunchCommand;
use agent_runtime::observe::{ProcessReading, State};
use agent_runtime::process::{self, Identity};
use agent_runtime::reading::Reading;
use serde_json::{Value, json};

use super::host::{Foreground, Observed, Recorded, SessionFloor, unanswering};
use super::obligations::{Discharge, Obligations, PaneEnd, PaneRef, ReceiptEnd};
use super::{Close, Operation, Pane, Server, receipt};
use crate::error::Result;
use crate::state::{Obligation, Opening, Phase, Role};

/// How often a poll re-reads the pane within its bound.
const POLL: std::time::Duration = std::time::Duration::from_millis(200);

/// Why a window did not open with its line typed. `Refused` is a host refusal before the
/// launcher was asked, nothing of the effect's standing; `Unanswered` is a
/// `new-window` the host did not answer for after it was asked, a window
/// possibly opened that the record names as such;
/// `LineUnsent` is a window that opened, recorded at `opening`, whose line
/// could not be typed, its one pane closed again by exact id and that close
/// discharged by its own answer, so the caller judges what stands.
pub(in crate::effects) enum OpenRefusal {
    Refused(agent_runtime::Error),
    Unanswered { refusal: agent_runtime::Error },
    LineUnsent { refusal: agent_runtime::Error },
}

/// What a poll of a pane settled on.
pub(in crate::effects) enum Polled {
    /// The harness holds the pane under the recorded identity and the screen
    /// reads a state the caller accepts.
    Ready { identity: Recorded<Identity> },
    /// The pane is gone: the exec'd harness exited.
    Gone,
    /// The bound passed; the last reading is carried for the record, with the
    /// recorded harness identity where the reading named one.
    Pending {
        identity: Option<Recorded<Identity>>,
        reading: ProcessReading,
        state: State,
    },
    /// The bound passed with the pane unreadable: the host did not answer
    /// for it, so nothing about it is settled.
    Unobservable { cause: &'static str },
}

/// What a wait for the runner to record the delivered turn settled on
///: the user turn appeared in its session file, its pane went
/// (the harness exited), the pane could not be read, or the bound passed.
pub(in crate::effects) enum TurnConfirm {
    Recorded,
    PaneGone,
    PaneUnobservable { cause: String },
    Pending,
}

/// What a reconcile at `opening` settled on, the same reading
/// for a launch and a succession.
pub(in crate::effects) enum Recovered {
    /// The pane the receipt names, its registered pid live under `identity`
    /// read from the kernel: adopt it and continue as from `window-opened`
    /// under that identity alone. `registered` is the receipt
    /// as read, for the record.
    Adopted {
        pane: Pane,
        identity: Identity,
        registered: Value,
    },
    /// Nothing settled: the intent stays open with `note` and, where one
    /// names the reading, `cause`; the next reconcile reads again.
    Pending {
        note: &'static str,
        cause: Option<String>,
    },
    /// The effect failed before any harness held a pane this record names:
    /// `note` says how, every obligation the phase recorded discharged
    ///.
    Failed {
        note: &'static str,
        cause: Option<&'static str>,
    },
}

/// The observation a reconcile at `opening` records for `op` when it does
/// not adopt: the note and, where the reading has one, its cause.
pub(in crate::effects) fn opening_observation(op: &str, note: &str, cause: Option<&str>) -> Value {
    let mut observation = json!({"reconcile": op, "phase": "opening", "note": note});
    if let Some(cause) = cause {
        observation["cause"] = json!(cause);
    }
    observation
}

/// Whether the recorded pane may still be about to register at `now`: the
/// launch bound, from the moment recorded before the window opened. Past
/// it, a pane with no receipt never ran its line.
fn within_bound(opening: &Opening, now: SystemTime, verify: std::time::Duration) -> bool {
    let now_ms = now
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    now_ms < opening.since_ms.saturating_add(verify.as_millis() as u64)
}

/// A recovery that failed `note` once every obligation is discharged; one
/// that stands is held open with its cause instead.
fn recovered_failed(
    note: &'static str,
    cause: Option<&'static str>,
    obligations: &Obligations,
) -> Recovered {
    if obligations.record().standing.is_empty() {
        Recovered::Failed { note, cause }
    } else {
        Recovered::Pending {
            note,
            cause: Some(
                obligations
                    .cause()
                    .unwrap_or("obligation-standing")
                    .to_owned(),
            ),
        }
    }
}

/// The receipt the server's end leaves unread: read it,
/// and where it names a pid, read that identity. A live pid is an
/// obligation the server's end cannot discharge; a gone one is settled by
/// that read; an unreadable one, or an invalid receipt, stands.
fn read_receipt_on_gone_server(
    path: &Path,
    intent_id: &str,
    obligations: &mut Obligations,
    role: Role,
    harness: Option<Harness>,
) -> Result<()> {
    match receipt::read(path, intent_id)? {
        receipt::Reading::Absent => {
            obligations.discharge(Discharge::Receipt(ReceiptEnd::Absent));
        }
        receipt::Reading::Invalid { cause } => {
            obligations.discharge(Discharge::Receipt(ReceiptEnd::Invalid { cause }));
        }
        receipt::Reading::Present(registered) => {
            obligations.discharge(Discharge::Receipt(ReceiptEnd::Read));
            obligations.add(
                Obligation::Pid {
                    pid: registered.pid,
                },
                role,
                harness,
            );
            obligations.discharge(Discharge::Pid {
                pid: registered.pid,
                read: process::identity(registered.pid),
            });
        }
    }
    Ok(())
}

impl Operation<'_> {
    /// What an effect records before it opens its window: the
    /// server the window will open on, with its process identity so a socket
    /// that stops answering can later be told from a server that is gone
    ///, and the floor its native session is read above, the
    /// pane not yet known. The server just answered, so its process is read
    /// live; one that reads gone or unreadable refuses the open with that
    /// cause rather than recording a server identity it does not have. The
    /// moment is the run's clock's wall time, read here.
    pub(in crate::effects) fn opening(
        &self,
        server: &Server,
        floor: &SessionFloor,
        brief: Option<&Path>,
    ) -> std::result::Result<Opening, agent_runtime::Error> {
        let (session_id, baseline) = match floor {
            SessionFloor::Fixed(id) => (Some(id.clone()), Vec::new()),
            SessionFloor::Baseline(ids) => (None, ids.clone()),
        };
        let server_process_start = self.server_process_start(server)?;
        Ok(Opening {
            server: server.pid as u64,
            server_start: server.start,
            server_process_start: Some(server_process_start),
            socket: server.socket.display().to_string(),
            since_ms: self
                .clock
                .wall()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0),
            brief: brief.map(|b| b.display().to_string()),
            session_id,
            baseline,
            pane: None,
            asked: false,
        })
    }

    /// Hold `text` as this intent's brief, `intents/<intent id>.brief`
    /// beside its receipt, for the delivery after the window opens and for a
    /// reconcile that delivers it later; a repeat of the intent writes the
    /// same file again.
    pub(in crate::effects) fn hold_brief(
        &self,
        text: &str,
    ) -> std::result::Result<std::path::PathBuf, agent_runtime::Error> {
        let path = self
            .run
            .settings
            .state_dir
            .join("intents")
            .join(format!("{}.brief", self.intent_id));
        let write = |path: &Path| {
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir)?;
            }
            std::fs::write(path, format!("{text}\n"))
        };
        write(&path).map_err(|e| agent_runtime::Error::io("write-brief", &path, e))?;
        Ok(path)
    }

    fn receipt_path(&self) -> std::path::PathBuf {
        super::host::receipt_path(self.run.settings, &self.intent_id)
    }

    /// The end a read of the pane's receipt settles: read
    /// discharges it, absent discharges it, an invalid or unreadable file
    /// leaves it standing.
    pub(super) fn read_receipt_end(&self) -> Result<ReceiptEnd> {
        Ok(match receipt::read(&self.receipt_path(), &self.intent_id) {
            Ok(receipt::Reading::Present(_)) => ReceiptEnd::Read,
            Ok(receipt::Reading::Absent) => ReceiptEnd::Absent,
            Ok(receipt::Reading::Invalid { cause }) => ReceiptEnd::Invalid { cause },
            Err(_) => ReceiptEnd::Invalid {
                cause: "receipt-unreadable",
            },
        })
    }

    /// Open the effect's window and type its launch line, every acquisition
    /// recorded before the action that creates it: the receipt's directory made only after the handle's
    /// owner-conditional write, which proves the intent still this
    /// writer's and its set the record's and stops on a yield before any
    /// file effect; the receipt armed and the window
    /// possibly opened before
    /// `new-window` runs; the pane id the creating call printed, with the
    /// server's pid and start, before anything is typed into it; then the
    /// line, which registers the pane by its receipt and `exec`s the harness.
    /// The `window-opened` phase written after the line is typed carries the
    /// receipt as standing until it is read. A window
    /// whose line could not be typed has its one pane closed again by exact
    /// id and that close discharged by its own answer.
    pub(in crate::effects) fn open_window(
        &mut self,
        server: &Server,
        session: &str,
        name: &str,
        command: &LaunchCommand,
        opening: &Opening,
    ) -> Result<std::result::Result<Pane, OpenRefusal>> {
        let receipt_path = self.receipt_path();
        self.write()?;
        if let Err(e) = receipt::arm(&receipt_path) {
            return Ok(Err(OpenRefusal::Refused(e)));
        }
        let asked = Opening {
            asked: true,
            ..opening.clone()
        };
        let role = self.principal_role();
        self.obligations
            .add(Obligation::Receipt, role, self.harness);
        self.obligations.add(
            Obligation::Window {
                server: opening.server,
                server_start: opening.server_start,
            },
            role,
            self.harness,
        );
        self.record_phase(Phase::Opening {
            opening: asked.clone(),
        })?;
        let pane = match tmux::new_window(server, session, name, &command.cwd) {
            Ok(pane) => pane,
            Err(refusal) => {
                return Ok(Err(OpenRefusal::Unanswered { refusal }));
            }
        };
        self.obligations.replace(
            &Obligation::Window {
                server: opening.server,
                server_start: opening.server_start,
            },
            "pane-recorded",
            Obligation::Pane {
                pane: pane.id.clone(),
                server: opening.server,
                server_start: Some(opening.server_start),
            },
            role,
            self.harness,
        );
        self.record_phase(Phase::Opening {
            opening: Opening {
                pane: Some(pane.id.clone()),
                ..asked
            },
        })?;
        let line = receipt::launch_line(&receipt_path, &self.intent_id, command);
        if let Err(refusal) = tmux::send_line(&pane, &line) {
            // An unsuccessful send reply does not prove the line never ran:
            // the host may have delivered the paste and Enter before it
            // returned the error, so the line could have written the receipt
            // and exec'd the harness. The pane, standing since `new-window`
            // was recorded, is closed by its token; then the receipt is read,
            // not assumed absent, so a receipt that stands discharges itself
            // and leaves its registered pid an obligation the close did not
            // settle.
            if let Ok(token) = self.standing_pane(pane.clone()) {
                let _ = self.close_pane(token)?;
            }
            self.read_receipt()?;
            return Ok(Err(OpenRefusal::LineUnsent { refusal }));
        }
        Ok(Ok(pane))
    }

    /// Read the pane's receipt where it still stands: a
    /// receipt read discharges it, and a pid it registers that the record
    /// does not account for yet is an obligation read through the one
    /// identity reader, gone or standing; an absent receipt is discharged as
    /// never written; an invalid or unreadable one stands. A run that ends
    /// before the judge read an identity reads the receipt here, so no
    /// terminal settles over an unread receipt.
    pub(in crate::effects) fn read_receipt(&mut self) -> Result<()> {
        if !self.obligations.stands(&Obligation::Receipt) {
            return Ok(());
        }
        match receipt::read(&self.receipt_path(), &self.intent_id) {
            Ok(receipt::Reading::Present(registered)) => {
                self.obligations
                    .discharge(Discharge::Receipt(ReceiptEnd::Read));
                if !self.obligations.names_pid(registered.pid) {
                    let role = self.principal_role();
                    self.obligations.add(
                        Obligation::Pid {
                            pid: registered.pid,
                        },
                        role,
                        self.harness,
                    );
                    self.obligations.discharge(Discharge::Pid {
                        pid: registered.pid,
                        read: process::identity(registered.pid),
                    });
                }
            }
            Ok(receipt::Reading::Absent) => {
                self.obligations
                    .discharge(Discharge::Receipt(ReceiptEnd::Absent));
            }
            Ok(receipt::Reading::Invalid { cause }) => {
                self.obligations
                    .discharge(Discharge::Receipt(ReceiptEnd::Invalid { cause }));
            }
            Err(_) => {
                self.obligations
                    .discharge(Discharge::Receipt(ReceiptEnd::Invalid {
                        cause: "receipt-unreadable",
                    }));
            }
        }
        self.write()
    }

    /// Poll the pane until the harness holds it and the screen reads a state
    /// `accept` takes, the pane goes, or the bound passes. With `recorded`,
    /// only that identity is the harness. A read the host does not answer is
    /// retried within the bound and reported as such past it. The pane gone
    /// discharges the recorded pane by that read.
    pub(in crate::effects) fn await_state(
        &mut self,
        pane: &Pane,
        harness: Harness,
        owns: &dyn Fn(&str) -> bool,
        recorded: Option<&Identity>,
        accept: &dyn Fn(&State) -> bool,
    ) -> Result<Polled> {
        let deadline = self.now() + self.run.settings.verify;
        loop {
            let polled = match self.read_pane(pane, harness, owns, recorded)? {
                Reading::Gone => return Ok(Polled::Gone),
                Reading::Live((Foreground { reading, harness }, state)) => match harness {
                    Some(identity) if accept(&state) => return Ok(Polled::Ready { identity }),
                    harness => Polled::Pending {
                        identity: harness,
                        reading,
                        state,
                    },
                },
                Reading::Unreadable { cause } => Polled::Unobservable { cause },
            };
            if self.now() >= deadline {
                return Ok(polled);
            }
            self.sleep(POLL);
        }
    }

    /// Wait for the runner to record a user turn beyond `turns_before` in its
    /// own session file `file`, within the launch bound: the
    /// delivered brief confirmed by the harness's own record. The pane gone is
    /// the harness exited; a pane the host does not answer for is retried and
    /// reported past the bound; the bound passed is `Pending`. The wait is a
    /// handle method, so no poll of this loop runs outside the handle.
    pub(in crate::effects) fn await_delivered_turn(
        &mut self,
        harness: Harness,
        pane: &Pane,
        file: &Path,
        turns_before: u64,
    ) -> Result<TurnConfirm> {
        let deadline = self.now() + self.run.settings.verify;
        loop {
            if self.user_turns(harness, file)? > turns_before {
                return Ok(TurnConfirm::Recorded);
            }
            match self.pane_pid(pane)? {
                Reading::Live(_) => {}
                Reading::Gone => return Ok(TurnConfirm::PaneGone),
                Reading::Unreadable { cause } => {
                    return Ok(TurnConfirm::PaneUnobservable {
                        cause: cause.to_owned(),
                    });
                }
            }
            if self.now() >= deadline {
                return Ok(TurnConfirm::Pending);
            }
            self.sleep(POLL);
        }
    }

    /// Recover an effect interrupted at `opening`, the owner already read
    /// dead. The recorded server is judged first (decision
    /// 66): one gone or replaced took every pane with it, and the receipt is
    /// read before anything is discharged, its pid read
    /// through the one identity reader; one unanswering whose process runs is
    /// unobservable. Then, in order: the pane's receipt, whose pid is read
    /// before its pane is adopted by exact id; else the recorded pane, which
    /// a reconcile within the bound leaves to register and one past it
    /// closes by that exact id; else nothing opened. No pane is enumerated
    /// and no window's name, option or environment is read. Every read here
    /// is three-valued; an adopted pane is recorded as
    /// `window-opened` under the registered identity before the caller goes
    /// on.
    pub(in crate::effects) fn recover_opening(&mut self, opening: &Opening) -> Result<Recovered> {
        let server = match tmux::server(Path::new(&opening.socket)) {
            Ok(server) => server,
            Err(_) => {
                return match unanswering(opening.server, opening.server_process_start.as_deref()) {
                    Observed::Gone { cause } => self.server_gone(opening, cause),
                    Observed::Unobservable { cause } => Ok(Recovered::Pending {
                        note: "pane-unobservable",
                        cause: Some(cause.to_owned()),
                    }),
                    Observed::Present(_) => unreachable!("unanswering never returns a pane"),
                };
            }
        };
        if server.pid as u64 != opening.server || server.start != opening.server_start {
            return self.server_gone(opening, "server-replaced");
        }
        let recovered = match receipt::read(&self.receipt_path(), &self.intent_id)? {
            receipt::Reading::Present(registered) => {
                // A receipt naming another pane than the one this effect
                // recorded is not this pane's own: held, never adopted.
                if opening
                    .pane
                    .as_deref()
                    .is_some_and(|recorded| recorded != registered.pane)
                {
                    return Ok(Recovered::Pending {
                        note: "receipt-invalid",
                        cause: Some("pane-mismatch".to_owned()),
                    });
                }
                self.judge_registered(process::identity(registered.pid), &registered, &server)?
            }
            receipt::Reading::Invalid { cause } => {
                self.obligations
                    .discharge(Discharge::Receipt(ReceiptEnd::Invalid { cause }));
                Recovered::Pending {
                    note: "receipt-invalid",
                    cause: Some(cause.to_owned()),
                }
            }
            receipt::Reading::Absent => {
                // No pane recorded and no receipt. A launcher never asked
                // opened nothing. One asked may have opened a window that
                // stands unregistered on a server that answers, and no pane
                // is enumerated to find it, so that obligation
                // stands until the operator's own close or the server's end
                //.
                let Some(pane_id) = &opening.pane else {
                    let recovered = if opening.asked {
                        Recovered::Pending {
                            note: "window-unread",
                            cause: Some("pane-unrecorded".to_owned()),
                        }
                    } else {
                        recovered_failed("nothing-opened", None, &self.obligations)
                    };
                    self.write()?;
                    return Ok(recovered);
                };
                let key = PaneRef {
                    pane: pane_id.clone(),
                    server: opening.server,
                    server_start: Some(opening.server_start),
                };
                match tmux::pane_fields(&server, pane_id) {
                    Reading::Live(fields) => {
                        if within_bound(opening, self.clock.wall(), self.run.settings.verify) {
                            Recovered::Pending {
                                note: "receipt-pending",
                                cause: None,
                            }
                        } else {
                            // A pane of ours that never ran its line holds
                            // no harness: closed by exact id, the close
                            // discharging it where it answered.
                            self.signal()?;
                            let close = tmux::kill_pane(&fields.pane);
                            let cause = match &close {
                                Close::Closed => "pane-closed",
                                Close::AlreadyGone => "pane-gone",
                                Close::Unreadable { .. } => "pane-close-unreadable",
                            };
                            self.obligations.discharge(Discharge::Pane {
                                pane: key,
                                end: PaneEnd::Close(close),
                            });
                            self.obligations
                                .discharge(Discharge::Receipt(ReceiptEnd::Absent));
                            recovered_failed("nothing-registered", Some(cause), &self.obligations)
                        }
                    }
                    Reading::Gone => {
                        self.obligations.discharge(Discharge::Pane {
                            pane: key,
                            end: PaneEnd::Gone,
                        });
                        self.obligations
                            .discharge(Discharge::Receipt(ReceiptEnd::Absent));
                        recovered_failed("nothing-registered", Some("pane-gone"), &self.obligations)
                    }
                    Reading::Unreadable { cause } => Recovered::Pending {
                        note: "pane-unobservable",
                        cause: Some(cause.to_owned()),
                    },
                }
            }
        };
        self.write()?;
        Ok(recovered)
    }

    /// What the receipt's registered pid settles,
    /// read through the one identity reader, over the recorded set. The receipt
    /// was read and the registered pane adopted, written before any close
    ///, so a run killed at the close has the adopted pane
    /// and the receipt-read durable. Live: the pane, read by exact id, is
    /// adopted under that identity and no other; its pane gone leaves that live
    /// pid an obligation the failure cannot discharge, held `pid-live`. Gone:
    /// the registered pid holds nothing, and the pane it registered is closed
    /// through the signal-writing close, which records the first signal before
    /// the kill and discharges the pane by its own answer, a close that did not
    /// confirm holding the intent open. Unreadable: held with the cause, never
    /// read as an exit.
    fn judge_registered(
        &mut self,
        identity: Reading<Identity>,
        registered: &receipt::Receipt,
        server: &Server,
    ) -> Result<Recovered> {
        let registered_pane = PaneRef {
            pane: registered.pane.clone(),
            server: server.pid as u64,
            server_start: Some(server.start),
        };
        let role = self.principal_role();
        self.obligations
            .adopt(registered_pane.clone(), role, self.harness);
        self.write()?;
        Ok(match identity {
            Reading::Live(identity) => match tmux::pane_fields(server, &registered.pane) {
                // The pane stands: adopted under the registered identity, which
                // becomes an obligation of the attempt.
                Reading::Live(fields) => {
                    self.add(Obligation::Process(identity.clone()))?;
                    Recovered::Adopted {
                        pane: fields.pane,
                        identity,
                        registered: json!({
                            "pane": registered.pane,
                            "pid": registered.pid,
                            "written_at": registered.written_at,
                        }),
                    }
                }
                // The pane is gone but the registered pid reads live: the
                // process survived its pane, a pid
                // obligation the pane's disappearance cannot discharge.
                Reading::Gone => {
                    self.discharge(Discharge::Pane {
                        pane: registered_pane.clone(),
                        end: PaneEnd::Gone,
                    })?;
                    self.add(Obligation::Pid {
                        pid: registered.pid,
                    })?;
                    Recovered::Pending {
                        note: "pane-gone",
                        cause: Some("pid-live".to_owned()),
                    }
                }
                Reading::Unreadable { cause } => {
                    self.add(Obligation::Pid {
                        pid: registered.pid,
                    })?;
                    Recovered::Pending {
                        note: "pane-unobservable",
                        cause: Some(cause.to_owned()),
                    }
                }
            },
            Reading::Gone => match tmux::pane_fields(server, &registered.pane) {
                // The pane was adopted above, so its key stands and a token
                // mints for the close.
                Reading::Live(fields) => {
                    let cause = match self.standing_pane(fields.pane) {
                        Ok(token) => match self.close_pane(token)? {
                            Close::Closed => "pane-closed",
                            Close::AlreadyGone => "pane-gone",
                            Close::Unreadable { .. } => "pane-close-unreadable",
                        },
                        Err(_) => "pane-unrecorded",
                    };
                    recovered_failed("harness-exited", Some(cause), &self.obligations)
                }
                Reading::Gone => {
                    self.discharge(Discharge::Pane {
                        pane: registered_pane,
                        end: PaneEnd::Gone,
                    })?;
                    recovered_failed("harness-exited", Some("pane-gone"), &self.obligations)
                }
                Reading::Unreadable { cause } => Recovered::Pending {
                    note: "harness-exited",
                    cause: Some(cause.to_owned()),
                },
            },
            Reading::Unreadable { cause } => Recovered::Pending {
                note: "identity-unreadable",
                cause: Some(cause.to_owned()),
            },
        })
    }

    /// The server gone or replaced took every pane and window it held
    ///: the receipt is read first, and a pid it names is read
    /// through the one identity reader; then what the set
    /// names on the server is discharged by that read.
    fn server_gone(&mut self, opening: &Opening, cause: &'static str) -> Result<Recovered> {
        let role = self.principal_role();
        read_receipt_on_gone_server(
            &self.receipt_path(),
            &self.intent_id,
            &mut self.obligations,
            role,
            self.harness,
        )?;
        match self.obligations.pane(role) {
            Some(pane) => self.obligations.discharge(Discharge::Pane {
                pane,
                end: PaneEnd::Gone,
            }),
            None => self.obligations.discharge(Discharge::Window {
                server: opening.server,
                server_start: opening.server_start,
            }),
        }
        let recovered = recovered_failed("nothing-opened", Some(cause), &self.obligations);
        self.write()?;
        Ok(recovered)
    }
}
