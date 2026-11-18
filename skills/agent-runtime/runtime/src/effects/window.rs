//! The handle's window methods: the `opening` record, the window open with
//! its receipt and launch line, the poll of a pane, and the recovery of an
//! effect interrupted at `opening`. Every acquisition on the way is written
//! before the action or wait that follows it, and every discharge comes from
//! this handle's own read.

use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::harness::Harness;
use crate::host::tmux;
use crate::launch::LaunchCommand;
use crate::observe::{self, ProcessReading, State};
use crate::process::{self, Identity};
use crate::reading::Reading;
use serde_json::{Value, json};

use super::host::{Foreground, Observed, Recorded, SessionFloor, unanswering};
use super::obligations::{Discharge, Obligations, PaneEnd, PaneRef, ReceiptEnd};
use super::{Close, Operation, POLL, Pane, Server, Target, receipt};
use crate::error::Result;
use crate::intent::{Obligation, Opening, Phase, Role};

/// Why a window did not open with its line typed. `Refused` is a host refusal before the
/// launcher was asked, nothing of the effect's standing; `Unanswered` is a
/// `new-window` the host did not answer for after it was asked, a window
/// possibly opened that the record names as such;
/// `LineUnsent` is a window that opened, recorded at `opening`, whose line
/// could not be typed, its one pane closed again by exact id and that close
/// discharged by its own answer, so the caller judges what stands; for the
/// session's idle shell, a line not typed or whose receipt never came, the
/// shell left standing.
pub enum OpenRefusal {
    Refused(crate::Error),
    Unanswered { refusal: crate::Error },
    LineUnsent { refusal: crate::Error },
}

/// What a poll of a pane settled on.
pub enum Polled {
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

/// What a wait for the runner to record the delivered turn settled on:
/// the brief appeared in a user turn in its session file, its pane went
/// (the harness exited), the pane could not be read, the bound passed with
/// the harness still refusing the submit after `presses` more Enters, or
/// the bound passed.
pub enum TurnConfirm {
    Recorded,
    PaneGone,
    PaneUnobservable { cause: String },
    Refused { presses: u32 },
    Pending,
}

/// How long a refused submit stands before Enter is pressed again, and how
/// many times it is: Copilot refuses a submit while it loads a managed
/// account's policy, which a live start saw end within the minute.
const RESUBMIT_GAP: Duration = Duration::from_secs(2);
const RESUBMITS: u32 = 5;

/// What a reconcile at `opening` settled on, the same reading
/// for a launch and a succession.
pub enum Recovered {
    /// The pane the receipt names and the identity recovered for its session.
    /// `registered` keeps the receipt's evidence for the record.
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
    /// `note` says how, every obligation the phase recorded discharged.
    Failed {
        note: &'static str,
        cause: Option<&'static str>,
    },
}

/// The observation a reconcile at `opening` records for `op` when it does
/// not adopt: the note and, where the reading has one, its cause.
pub fn opening_observation(op: &str, note: &str, cause: Option<&str>) -> Value {
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
    /// that stops answering can later be told from a server that is gone,
    /// and the floor its native session is read above, the
    /// pane not yet known. The server just answered, so its process is read
    /// live; one that reads gone or unreadable refuses the open with that
    /// cause rather than recording a server identity it does not have. The
    /// moment is the run's clock's wall time, read here.
    pub fn opening(
        &self,
        server: &Server,
        floor: &SessionFloor,
        brief: Option<&Path>,
        home: Option<&Path>,
        home_implicit: bool,
    ) -> std::result::Result<Opening, crate::Error> {
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
            adopted: false,
            asked: false,
            home: home.map(|h| h.display().to_string()),
            home_implicit,
        })
    }

    /// Hold `text` as this intent's brief, `intents/<intent id>.brief`
    /// beside its receipt, for the delivery after the window opens and for a
    /// reconcile that delivers it later; a repeat of the intent writes the
    /// same file again.
    pub fn hold_brief(&self, text: &str) -> std::result::Result<std::path::PathBuf, crate::Error> {
        let path = self
            .run
            .state_dir
            .join("intents")
            .join(format!("{}.brief", self.intent_id));
        let write = |path: &Path| {
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir)?;
            }
            std::fs::write(path, format!("{text}\n"))
        };
        write(&path).map_err(|e| crate::Error::io("write-brief", &path, e))?;
        Ok(path)
    }

    fn receipt_path(&self) -> std::path::PathBuf {
        self.run.receipt_path(&self.intent_id)
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
    /// file effect; the receipt armed, its launch file written and the window
    /// possibly opened before
    /// `new-window` runs; the pane id the creating call printed, with the
    /// server's pid and start, before anything is typed into it; then the
    /// line, which registers the pane by its receipt and `exec`s the harness.
    /// The `window-opened` phase written after the line is typed carries the
    /// receipt as standing until it is read. A window
    /// whose line could not be typed, or whose `new-window` failed after
    /// printing its pane, has its one pane closed again by exact
    /// id and that close discharged by its own answer.
    ///
    /// A start `alone` over a session whose one window is an idle shell
    /// ([`tmux::sole_idle_shell`]) runs its line in that shell instead, so
    /// the session holds the controller's window alone. A listing that does
    /// not answer opens a window as every other case does: a window of the
    /// effect's own touches nothing of the session's.
    pub fn open_window(
        &mut self,
        server: &Server,
        session: &str,
        name: &str,
        command: &LaunchCommand,
        opening: &Opening,
        alone: bool,
    ) -> Result<std::result::Result<Pane, OpenRefusal>> {
        let receipt_path = self.receipt_path();
        self.write()?;
        let line = match receipt::arm(&receipt_path)
            .and_then(|()| receipt::launch_line(&receipt_path, &self.intent_id, command))
        {
            Ok(line) => line,
            Err(e) => return Ok(Err(OpenRefusal::Refused(e))),
        };
        if alone && let Reading::Live(Some(shell)) = tmux::sole_idle_shell(server, session) {
            return self.run_in_idle_shell(shell, &line, opening, &receipt_path);
        }
        let asked = Opening {
            asked: true,
            ..opening.clone()
        };
        let role = self.principal_role();
        self.obligations
            .add(Obligation::Receipt, role, self.harness);
        let at = (opening.server, opening.server_start);
        let acquired = self.acquire_window(
            server,
            session,
            name,
            &command.cwd,
            at,
            |operation, pane| {
                operation.record_phase(Phase::Opening {
                    opening: match pane {
                        Some(pane) => Opening {
                            pane: Some(pane.to_owned()),
                            ..asked.clone()
                        },
                        None => asked.clone(),
                    },
                })
            },
        )?;
        let (pane, failed) = match acquired {
            Ok(acquired) => acquired,
            Err(refusal) => return Ok(Err(OpenRefusal::Unanswered { refusal })),
        };
        let refusal = match failed {
            Some(error) => error,
            None => match tmux::send_line(&pane, &line) {
                Ok(()) => return Ok(Ok(pane)),
                Err(refusal) => refusal,
            },
        };
        // The pane, standing since it was recorded, is closed by its token;
        // then the receipt is read, not assumed absent: an unsuccessful send
        // reply does not prove the line never ran, since the host may have
        // delivered the paste and Enter before it returned the error, so the
        // line could have written the receipt and exec'd the harness. A
        // receipt that stands discharges itself and leaves its registered
        // pid an obligation the close did not settle.
        if let Ok(token) = self.standing_pane(pane.clone()) {
            let _ = self.close_pane(token)?;
        }
        self.read_receipt()?;
        Ok(Err(OpenRefusal::LineUnsent { refusal }))
    }

    /// The window acquisition both openers share, under the principal role:
    /// a window possibly opened on the server keyed `at` (its pid and tmux
    /// start) is recorded and made durable by `persist` before `new-window`
    /// runs, then replaced by the pane the creating call printed and made
    /// durable again with that pane, before anything else touches it.
    /// `persist` is the opener's own write: the phase of the typed route,
    /// the set alone of the dormant one. A `new-window` that printed its pane
    /// and failed comes back with the pane and the failure, the pane standing
    /// for the caller to close; one that printed none comes back as the
    /// error, the window obligation standing.
    fn acquire_window(
        &mut self,
        server: &Server,
        session: &str,
        name: &str,
        cwd: &Path,
        at: (u64, u64),
        mut persist: impl FnMut(&mut Self, Option<&str>) -> Result<()>,
    ) -> Result<std::result::Result<(Pane, Option<crate::Error>), crate::Error>> {
        let (server_pid, server_start) = at;
        let role = self.principal_role();
        let window = Obligation::Window {
            server: server_pid,
            server_start,
        };
        self.obligations.add(window.clone(), role, self.harness);
        persist(self, None)?;
        // A failure that printed its pane opened a window: it is recorded as
        // any opened pane is, for the caller to close.
        let (pane, failed) = match tmux::new_window(server, session, name, cwd) {
            Ok(pane) => (pane, None),
            Err(tmux::WindowFailed {
                error,
                opened: Some(pane),
            }) => (*pane, Some(error)),
            Err(tmux::WindowFailed {
                error,
                opened: None,
            }) => return Ok(Err(error)),
        };
        self.obligations.replace(
            &window,
            "pane-recorded",
            Obligation::Pane {
                pane: pane.id.clone(),
                server: server_pid,
                server_start: Some(server_start),
            },
            role,
            self.harness,
        );
        persist(self, Some(&pane.id))?;
        Ok(Ok((pane, failed)))
    }

    /// Open a window in `session` on `server`, named `name` in `cwd`, with
    /// nothing typed into it: it holds the session's default command, its
    /// pane standing in the set under the principal role, no receipt armed
    /// and the phase left as it stands. A caller that keeps such a window
    /// running publishes it with [`Operation::publish_pane`]. A `new-window`
    /// that printed its pane and failed has that pane closed again by its
    /// token; the error comes back either way, and the set says what
    /// stands.
    pub fn open_dormant(
        &mut self,
        server: &Server,
        session: &str,
        name: &str,
        cwd: &Path,
    ) -> Result<std::result::Result<Pane, crate::Error>> {
        let at = (u64::from(server.pid), server.start);
        let acquired = self.acquire_window(server, session, name, cwd, at, |operation, _| {
            operation.write()
        })?;
        let (pane, failed) = match acquired {
            Ok(acquired) => acquired,
            Err(error) => return Ok(Err(error)),
        };
        let Some(error) = failed else {
            return Ok(Ok(pane));
        };
        if let Ok(token) = self.standing_pane(pane) {
            let _ = self.close_pane(token)?;
        }
        Ok(Err(error))
    }

    /// Set the user option `name` of the standing pane's window to `value`,
    /// taken literally: what a reader of the window, such as a tmux hook,
    /// finds there.
    pub fn set_window_option(
        &self,
        pane: &super::obligations::Standing<Pane>,
        name: &str,
        value: &str,
    ) -> std::result::Result<(), crate::Error> {
        self.check_pane_token(pane)?;
        tmux::set_window_option(pane.key(), name, value)
    }

    /// Type the launch line into `shell`, the session's idle shell, a pane
    /// this effect did not open: recorded `adopted` before the line is
    /// typed, and the effect's own pane only once its receipt names it,
    /// within the launch bound. A line the person typed and left unsent
    /// reads idle, so one interrupt key is pressed first: every shell
    /// [`crate::process::is_shell`] names discards its pending line on it and
    /// prompts again, and the runtime runs only the line it wrote. Until the
    /// receipt nothing of the effect closes or stops the shell, since it may
    /// still be the person's: a line refused before its paste leaves the
    /// shell standing as it is.
    fn run_in_idle_shell(
        &mut self,
        shell: Pane,
        line: &str,
        opening: &Opening,
        receipt_path: &Path,
    ) -> Result<std::result::Result<Pane, OpenRefusal>> {
        let role = self.principal_role();
        self.obligations
            .add(Obligation::Receipt, role, self.harness);
        self.record_phase(Phase::Opening {
            opening: Opening {
                pane: Some(shell.id.clone()),
                adopted: true,
                ..opening.clone()
            },
        })?;
        if let Err(refusal) =
            tmux::send_key(&shell, "C-c").and_then(|()| tmux::send_line(&shell, line))
        {
            self.read_receipt()?;
            return Ok(Err(OpenRefusal::LineUnsent { refusal }));
        }
        let deadline = self.now() + self.run.settings.verify.get()?;
        loop {
            if let Ok(receipt::Reading::Present(registered)) =
                receipt::read(receipt_path, &self.intent_id)
                && registered.pane == shell.id
            {
                self.obligations.adopt(
                    PaneRef {
                        pane: shell.id.clone(),
                        server: opening.server,
                        server_start: Some(opening.server_start),
                    },
                    role,
                    self.harness,
                );
                self.write()?;
                return Ok(Ok(shell));
            }
            if self.now() >= deadline {
                break;
            }
            self.sleep(POLL);
        }
        self.read_receipt()?;
        Ok(Err(OpenRefusal::LineUnsent {
            refusal: crate::Error::refused("receipt-unwritten", &[("pane", &shell.id)]),
        }))
    }

    /// Read the pane's receipt where it still stands: a
    /// receipt read discharges it, and a pid it registers that the record
    /// does not account for yet is an obligation read through the one
    /// identity reader, gone or standing; an absent receipt is discharged as
    /// never written; an invalid or unreadable one stands. A run that ends
    /// before the judge read an identity reads the receipt here, so no
    /// terminal settles over an unread receipt.
    pub fn read_receipt(&mut self) -> Result<()> {
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
    pub fn await_state(
        &mut self,
        pane: &Pane,
        harness: Harness,
        owns: &dyn Fn(&str) -> bool,
        recorded: Option<&Identity>,
        accept: &dyn Fn(&State) -> bool,
    ) -> Result<Polled> {
        let deadline = self.now() + self.run.settings.verify.get()?;
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

    /// A receipt must name the delivered brief in the runner's own session,
    /// beyond the cursor recorded before the paste. The pane gone is
    /// the harness exited; a pane the host does not answer for is retried and
    /// reported past the bound; the bound passed is `Pending`. A screen
    /// that shows the harness refused the submit, its draft held, is pressed
    /// Enter again each [`RESUBMIT_GAP`], at most [`RESUBMITS`] times: the
    /// brief is never typed twice, and the bound passed with the refusal
    /// still drawn is `Refused`. The wait is a handle method, so no poll of
    /// this loop runs outside the handle.
    pub fn await_delivered_turn(
        &mut self,
        harness: Harness,
        pane: &Pane,
        file: &Path,
        turns_before: u64,
        brief: &str,
    ) -> Result<TurnConfirm> {
        let deadline = self.now() + self.run.settings.verify.get()?;
        let expected = crate::session::normalize_user_text(brief);
        let mut presses = 0;
        let mut refused = false;
        let mut next_look = self.now() + RESUBMIT_GAP;
        loop {
            if crate::session::user_texts_after(harness, file, turns_before)?
                .iter()
                .any(|text| text == &expected)
            {
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
            if self.now() >= next_look {
                next_look = self.now() + RESUBMIT_GAP;
                // A capture that fails settles nothing: no press, no refusal.
                refused = tmux::capture(pane)
                    .is_ok_and(|screen| observe::submit_refused(&screen, harness));
                if refused && presses < RESUBMITS && tmux::send_key(pane, "Enter").is_ok() {
                    presses += 1;
                }
            }
            if self.now() >= deadline {
                return Ok(if refused {
                    TurnConfirm::Refused { presses }
                } else {
                    TurnConfirm::Pending
                });
            }
            self.sleep(POLL);
        }
    }

    /// Recover an effect interrupted at `opening`, the owner already read
    /// dead. The recorded server is judged first: one gone or replaced took
    /// every pane with it, and the receipt is
    /// read before anything is discharged, its pid read
    /// through the one identity reader; one unanswering whose process runs is
    /// unobservable. Then, in order: the pane's receipt, whose pid is read
    /// before its pane is adopted by exact id; else the recorded pane, which
    /// a reconcile within the bound leaves to register and one past it
    /// closes by that exact id, an adopted shell excepted, which is left
    /// standing; else nothing opened. No pane is enumerated
    /// and no window's name, option or environment is read. Every read here
    /// is three-valued; an adopted pane is recorded as
    /// `window-opened` under the recovered identity before the caller goes
    /// on.
    pub fn recover_opening(&mut self, opening: &Opening) -> Result<Recovered> {
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
                // stands until the operator's own close or the server's end.
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
                // A shell the effect typed into is not its own until its
                // receipt names it: past the bound the line never ran there,
                // and the shell stands as it was.
                if opening.adopted {
                    let recovered = if within_bound(
                        opening,
                        self.clock.wall(),
                        self.run.settings.verify.get()?,
                    ) {
                        Recovered::Pending {
                            note: "receipt-pending",
                            cause: None,
                        }
                    } else {
                        self.obligations
                            .discharge(Discharge::Receipt(ReceiptEnd::Absent));
                        recovered_failed("nothing-registered", Some("pane-kept"), &self.obligations)
                    };
                    self.write()?;
                    return Ok(recovered);
                }
                let key = PaneRef {
                    pane: pane_id.clone(),
                    server: opening.server,
                    server_start: Some(opening.server_start),
                };
                match tmux::pane_fields(&server, pane_id) {
                    Reading::Live(fields) => {
                        if within_bound(opening, self.clock.wall(), self.run.settings.verify.get()?)
                        {
                            Recovered::Pending {
                                note: "receipt-pending",
                                cause: None,
                            }
                        } else {
                            // A pane of ours that never ran its line holds
                            // no harness: closed by exact id, the close
                            // discharging it where it answered.
                            self.write_signal()?;
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
    /// was read and the registered pane adopted, written before any close,
    /// so a run killed at the close has the adopted pane
    /// and the receipt-read durable. A live registered pid can be the
    /// confinement wrapper, so the foreground judge identifies the lane's
    /// harness. A gone pane leaves that live pid owed, held `pid-live`. Gone:
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
                Reading::Live(fields) => {
                    let identity = if let Some(harness) = self.harness {
                        let target = Target::new(&self.run.settings.harness_binaries, harness)?;
                        match crate::observe::foreground(
                            fields.pid,
                            &|name| target.owns(name),
                            None,
                        ) {
                            ProcessReading::Harness { identity } => identity,
                            // A remote lane's own registered SSH process
                            // represents its session on this host.
                            ProcessReading::ForegroundOther { name, pid }
                                if name == "ssh" && pid == identity.pid =>
                            {
                                identity
                            }
                            ProcessReading::Unread { cause } => {
                                return Ok(Recovered::Pending {
                                    note: "identity-unreadable",
                                    cause: Some(cause.to_owned()),
                                });
                            }
                            ProcessReading::ShellsOnly
                            | ProcessReading::HarnessUp
                            | ProcessReading::ForegroundShell { .. }
                            | ProcessReading::ForegroundOther { .. } => {
                                return Ok(Recovered::Pending {
                                    note: "identity-pending",
                                    cause: None,
                                });
                            }
                        }
                    } else {
                        identity
                    };
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

    /// The server gone or replaced took every pane and window it held:
    /// the receipt is read first, and a pid it names is read
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_confined_receipt_recovers_the_harness_below_its_wrapper() {
        let dir = tempfile::tempdir().unwrap();
        let server = tmux::Private::start(dir.path());
        let server = &server.0;
        let mut settings = crate::effects::testing::settings(dir.path());
        settings.harness_binaries = crate::settings::Judged::of(
            "harness-binaries",
            Ok([(Harness::Claude, "/bin/sleep".into())].into()),
        );
        let env = crate::journal::Env {
            now_secs: 1,
            now_nanos: 1_000_000_000,
            nonce: 77,
            owner: None,
        };
        let path = dir.path().join(crate::record::FLEET_FILE_NAME);
        let run = crate::effects::testing::run(
            &path,
            &settings,
            &env,
            dir.path(),
            dir.path().join("lane-mail"),
            &crate::clock::SystemClock,
        );
        let intent = json!({
            "id": "launch-session:KEN-T:1-1", "op": "launch-session", "target": "KEN-T",
            "revision": 0, "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed"
        });
        let mut fleet: Value = serde_json::from_str(crate::effects::testing::FLEET).unwrap();
        fleet["intents"] = json!([intent]);
        std::fs::write(&path, serde_json::to_vec(&fleet).unwrap()).unwrap();
        let intent = serde_json::from_value(intent).unwrap();
        let mut operation = Operation::open(
            &run,
            &intent,
            crate::effects::Bootstrap::Launch {
                launch: None,
                harness: Some(Harness::Claude),
                auxiliary: None,
            },
        )
        .unwrap();
        let opening = operation
            .opening(server, &SessionFloor::Baseline(vec![]), None, None, false)
            .unwrap();
        // The wrapper stays in the pane while its child holds the terminal with it.
        let command = LaunchCommand {
            program: "/bin/sh".to_owned(),
            args: vec![
                "-c".to_owned(),
                "read -r ready; /bin/sleep 30 & child=$!; trap 'kill \"$child\"; wait \"$child\"' HUP; wait \"$child\""
                    .to_owned(),
            ],
            env: Default::default(),
            env_remove: vec![],
            cwd: dir.path().to_path_buf(),
            brief_arg: None,
            brief_path: None,
            confinement: None,
        };
        let pane = operation
            .open_window(server, "t", "wrapped", &command, &opening, false)
            .unwrap()
            .ok()
            .expect("the wrapper's window opened");
        let Some(Phase::Opening { opening }) = operation.phase.clone() else {
            panic!("the intent is still opening");
        };
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let registered = loop {
            if let receipt::Reading::Present(registered) =
                receipt::read(&operation.receipt_path(), &intent.id).unwrap()
            {
                break registered;
            }
            assert!(std::time::Instant::now() < deadline, "no pane receipt");
            std::thread::sleep(POLL);
        };
        let waiting = operation.recover_opening(&opening).unwrap();
        tmux::send_line(&pane, "ready").unwrap();
        let harness = loop {
            let rows = process::table().unwrap();
            if let Some(child) = rows
                .iter()
                .find(|row| row.ppid == registered.pid && row.name == "sleep")
                && let Reading::Live(identity) = process::identity(child.pid)
            {
                break identity;
            }
            assert!(std::time::Instant::now() < deadline, "no wrapper child");
            std::thread::sleep(POLL);
        };
        let Recovered::Adopted {
            identity,
            registered: evidence,
            ..
        } = operation.recover_opening(&opening).unwrap()
        else {
            panic!("the foreground harness was not adopted");
        };
        assert_eq!(identity, harness, "recover the harness under the wrapper");
        assert!(
            operation
                .principal_keys()
                .contains(&Obligation::Process(harness))
        );
        assert_eq!(evidence["pid"], registered.pid);
        assert!(matches!(
            waiting,
            Recovered::Pending {
                note: "identity-pending",
                ..
            }
        ));
    }

    #[test]
    fn the_brief_wait_requires_the_brief_after_its_cursor() {
        let dir = tempfile::tempdir().unwrap();
        let server = tmux::Private::start(dir.path());
        let Reading::Live(fields) = tmux::pane_fields(&server.0, "%0") else {
            panic!("the private pane is live");
        };
        let mut settings = crate::effects::testing::settings(dir.path());
        settings.verify = crate::settings::Judged::of("verify", Ok(std::time::Duration::ZERO));
        let env = crate::journal::Env {
            now_secs: 1_769_700_000,
            now_nanos: 1_769_700_000_000_000_000,
            nonce: 77,
            owner: None,
        };
        let path = dir.path().join(crate::record::FLEET_FILE_NAME);
        let run = crate::effects::testing::run(
            &path,
            &settings,
            &env,
            dir.path(),
            dir.path().join("lane-mail"),
            &crate::clock::SystemClock,
        );
        let intent = serde_json::from_value(json!({
            "id": "launch-session:KEN-T:1-1", "op": "launch-session", "target": "KEN-T",
            "revision": 0, "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
            "obligations": {"standing": [], "discharged": []}
        }))
        .unwrap();
        let mut operation = Operation::open(
            &run,
            &intent,
            crate::effects::Bootstrap::Launch {
                launch: None,
                harness: Some(Harness::Claude),
                auxiliary: None,
            },
        )
        .unwrap();
        let file = dir.path().join("session.jsonl");
        for (texts, cursor, recorded) in [
            (vec!["brief", "other"], 1, false),
            (vec!["other", "brief"], 0, true),
            (vec!["brief"], 1, false),
            (vec!["prefix brief suffix"], 0, false),
            (vec!["brief \r\n"], 0, true),
        ] {
            let rows: String = texts
                .iter()
                .map(|text| {
                    json!({"type": "user", "message": {"content": text}}).to_string() + "\n"
                })
                .collect();
            std::fs::write(&file, rows).unwrap();
            let answer = operation
                .await_delivered_turn(Harness::Claude, &fields.pane, &file, cursor, "brief")
                .unwrap();
            if recorded {
                assert!(
                    matches!(answer, TurnConfirm::Recorded),
                    "{texts:?} cursor={cursor}"
                );
            } else {
                assert!(
                    matches!(answer, TurnConfirm::Pending),
                    "{texts:?} cursor={cursor}"
                );
            }
        }
    }
}
