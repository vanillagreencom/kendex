//! The session send: one directive
//! to a cloud session lane, made once through the mailbox program. A
//! session send is irreversible and leaves no queue a repeat could be
//! judged against, so the lane record says a send is out before the program
//! starts (`directive_send` at its owed stage), the receipt the program
//! prints on stderr is stamped over it after, and a mark the store refused
//! leaves the record owed with the receipt kept beside the state, where the
//! reconcile stamps it without a second send. An owed record no receipt
//! settles is the watch's `directive-send-unsettled` line, once per item
//! and cause, and the operator's mark through the `op` entry settles it.
//! The mailbox writes no orch state; this
//! module and that mark are the record's writers.

use agent_runtime::effects::Reach;
use agent_runtime::record::{self, Locking};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::{Error, Result};
use crate::mailbox::{Mailbox, Route, Sent};
use crate::ops::mail::{
    Credit, DirectiveSend, DirectiveSendRecorded, DirectiveWrite, KeyedSend, RecordDirectiveSend,
    SendResult, Word, owed,
};
use crate::ops::{self, Report, Request};
use crate::settings::Settings;
use crate::state::{self, FleetState, Lane, Record};
use agent_runtime::journal::Env;

/// The directory under the state directory where a send keeps its receipt
/// between the program's answer and the mark.
pub const RECEIPT_DIR: &str = "directive-send";

/// Where the send to `item` whose owed record names `receipt` keeps its
/// receipt: a file named by the record, so a receipt another send kept
/// settles nothing of this one.
pub fn receipt_path(state_dir: &Path, item: &str, receipt: &str) -> PathBuf {
    state_dir
        .join(RECEIPT_DIR)
        .join(format!("{item}.{receipt}.json"))
}

/// The receipt name an owed record carries.
fn receipt_name(directive_send: &Value) -> Option<&str> {
    directive_send.get("receipt").and_then(Value::as_str)
}

/// The verb's reply: the receipt the send earned and how its mark went.
#[derive(Debug, Serialize)]
pub struct DirectiveSent {
    pub item: String,
    pub send: DirectiveSend,
    #[serde(flatten)]
    pub mark: Mark,
}

/// How the receipt reached the lane record.
#[derive(Debug, Serialize)]
#[serde(tag = "mark", rename_all = "kebab-case")]
pub enum Mark {
    /// Stamped: `directive_send` as the lane now holds it.
    Recorded { directive_send: Value },
    /// The store refused the mark by `refusal`; the record stands owed and
    /// the receipt waits at `receipt` for the reconcile.
    Unmarked { refusal: String, receipt: PathBuf },
}

/// The receipt as it is kept: the epoch second the send ran at and what
/// the program answered.
#[derive(Debug, Serialize, Deserialize)]
struct Receipt {
    at: u64,
    send: DirectiveSend,
}

/// Send the directive in `file` to the lane `item` of the fleet at `path`
/// and record it: the owed stage first (refused `lane-missing`,
/// `lane-channel` or `directive-send-owed` with nothing sent), then
/// `lane-mail send --item --directive --file` with the lane's session route
/// through the one runner, then the receipt as the mark. A refusal the program prints by its
/// own key with no receipt (a foreign root, an unrecorded session) is a send
/// that ran no CLI, recorded `failed` with that line, as is a program that
/// never started, recorded `failed` with the runner's cause; a program that
/// gave no answer, ended on a signal or printed a receipt that does not
/// decode leaves the record owed and refuses `directive-send-unsettled`,
/// since whether the directive reached the session is unknown. The `send` verb's
/// send, made under no key: the owed write reads no earlier send as this
/// one's, so every send it admits is made.
pub fn run(
    path: &Path,
    item: &str,
    file: &Path,
    settings: &Settings,
    env: &Env,
    locking: Locking,
) -> Result<DirectiveSent> {
    match send(path, item, file, settings, env, locking, None)? {
        Keyed::Sent(sent) => Ok(sent),
        Keyed::Found(found) => {
            unreachable!("an owed write under no key reads no send as its own: {found:?}")
        }
    }
}

/// What a send made under a key answered: the send made, or what the owed
/// write found standing under the key on the lane and left as it was, with
/// no program run.
#[derive(Debug)]
pub enum Keyed {
    Sent(DirectiveSent),
    Found(KeyedSend),
}

/// [`run`] on the fleet under the settings' state directory, under `key`,
/// the caller's name for this send (the validation end notice's
/// `validate-<run_id>`), through `reach`, the mailbox of the process the
/// caller runs in: its program, run in its root. The owed write carries
/// the key, every settle keeps it on the record, and the write reads the
/// lane's send under it before it writes, inside the store's lock,
/// so a replay of the notice, whichever walker makes it, learns from
/// the one record whether its own send is out or settled and makes no
/// second one; nothing is run on a found send.
pub fn run_keyed(
    item: &str,
    file: &Path,
    settings: &Settings,
    reach: &Reach,
    env: &Env,
    locking: Locking,
    key: &str,
) -> Result<Keyed> {
    let path = agent_runtime::record::fleet_path(&settings.state_dir);
    send(
        &path,
        item,
        file,
        settings,
        env,
        locking,
        Some((key, reach)),
    )
}

/// How long the mailbox program is given to take the notice.
const NOTICE_TIMEOUT: Duration = Duration::from_secs(60);

/// How a notice's send went: the owner word to mark the stage with, or a
/// send held, the stage left owed for the next walk (a send whose outcome
/// is not known, one the lane's record refuses for now, or a fleet record
/// that cannot be read to route it).
pub(crate) enum NoticeSend {
    Marked(String),
    Held,
}

/// Send the end notice `text` to the lane of `item` and answer the word its
/// mark records: a validation run's close and a launched job's end
/// (`job_end`) each tell their lane through here. The fleet record picks the
/// route. A session lane takes the
/// `orch-runtime send` owner, which records the directive owed before the
/// CLI and settles it under its own reconcile, so an irreversible send is
/// never retried blindly. Every other lane takes the mailbox's outbound
/// directive route, `lane-mail send --item ITEM --directive --file F
/// --delivery-id <key>`, which writes the lane's own inbox (`to-lane.jsonl`)
/// and judges the key under the lock, so a replay after a lost mark lands
/// once and answers `delivery-repeated`. The mark is `sent` on a receipt or
/// a repeated delivery, and `unsent:<cause>` where the route refused or
/// never started: recorded, never a reason to hold the close. The send is
/// held where its answer is not known, the replay under the key landing at
/// most once, and where the fleet record cannot be read, since the mailbox
/// route would send to a session lane with no owed record. The file the
/// program reads the notice from is this walker's own scratch,
/// `<key>.<the request's stamp>.notice`, created exclusively and removed by
/// this walker alone, so a second walker of the same notice (the owed walk
/// meeting the job's send in flight) never removes the file the first's
/// program is about to read; the record carries the key, never the file.
/// Both routes run `reach`'s program in its root.
#[allow(
    clippy::disallowed_methods,
    reason = "the end notice's file, this walker's own under the state directory, created exclusively for the mailbox program to read and removed by this walker after its send"
)]
pub(crate) fn send_notice(
    settings: &Settings,
    reach: &Reach,
    item: &str,
    key: &str,
    text: &str,
    env: &Env,
    locking: Locking,
) -> NoticeSend {
    use std::io::Write;
    let dir = settings.state_dir.join("validate");
    if let Err(e) = fs::create_dir_all(&dir) {
        return NoticeSend::Marked(format!("unsent:notice-dir:{e}"));
    }
    let path = dir.join(format!("{key}.{}.notice", env.round_id()));
    let written = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .and_then(|mut file| file.write_all(format!("{text}\n").as_bytes()));
    if let Err(e) = written {
        return NoticeSend::Marked(format!("unsent:notice-write:{e}"));
    }
    let mark = match lane_record(settings, item) {
        Ok(Some(lane)) if lane.session_channel() => {
            send_session(settings, reach, &lane, key, &path, env, locking)
        }
        Ok(Some(lane)) => send_directive(reach, item, Route::of(&lane), key, &path),
        Ok(None) => send_directive(reach, item, Route::Local { root: None }, key, &path),
        Err(_) => NoticeSend::Held,
    };
    let _ = fs::remove_file(&path);
    mark
}

/// The lane of `item` from the fleet record where one stands. No fleet, or
/// one with no record for `item`, is no lane: the notice's mailbox route
/// then writes a local inbox, which is the channel every non-cloud lane
/// reads, and the acceptance reads the item's own checkout. A fleet that
/// cannot be read is `Err`: it may hold the item's lane.
#[allow(
    clippy::disallowed_methods,
    reason = "the one read of an item's lane record from the fleet record: the notice send's route and the acceptance's repository"
)]
pub(crate) fn lane_record(settings: &Settings, item: &str) -> Result<Option<Lane>> {
    let fleet = record::fleet_path(&settings.state_dir);
    let Some(snapshot) = state::load(&fleet)? else {
        return Ok(None);
    };
    let fleet = FleetState::view(&fleet, &snapshot.doc)?;
    Ok(fleet.lanes.into_iter().find(|l| l.item == item))
}

/// The mailbox's outbound directive to a non-session lane by `route`, keyed
/// by the run: `reach`'s program run in its root, a local lane's box left to
/// the program's own lookup from there.
#[allow(
    clippy::disallowed_methods,
    reason = "the validation job's one outbound send of the lane's end notice through the mailbox program, keyed by the run so a replay lands once"
)]
fn send_directive(
    reach: &Reach,
    item: &str,
    route: Route<'_>,
    key: &str,
    file: &Path,
) -> NoticeSend {
    match Mailbox::new(reach.mail_program.clone())
        .bounded(NOTICE_TIMEOUT)
        .send_directive(item, route, file, Some(key), Some(&reach.mail_root))
    {
        Ok(Sent::Mailbox { .. } | Sent::Repeated { .. }) => NoticeSend::Marked("sent".to_owned()),
        // The program routed the lane to its session itself: the send's own
        // result marks it.
        Ok(Sent::Session { send }) => NoticeSend::Marked(session_mark(send.result)),
        Err(refusal) if refusal.wrote_nothing() => NoticeSend::Marked(format!("unsent:{refusal}")),
        // The append may stand: the next walk sends again under the run's
        // key, which reads a landed notice as a repeat.
        Err(_) => NoticeSend::Held,
    }
}

/// The owner word a session send's result marks the stage with: delivered
/// is `sent`; an archived session or a failed send is terminal, the stage
/// marked `unsent:session:<result>` and never retried blindly (the lane's
/// `directive_send` keeps the receipt for the hosted stall close).
fn session_mark(result: SendResult) -> String {
    match result {
        SendResult::Sent => "sent".to_owned(),
        SendResult::Archived => "unsent:session:archived".to_owned(),
        SendResult::Failed => "unsent:session:failed".to_owned(),
    }
}

/// The session send owner for a cloud lane, keyed by the notice:
/// `send::run_keyed` reads the lane's `directive_send` under this key inside
/// its owed write, under the store's lock, so a replay (the stage still owed
/// when the owed walk or the job's own retry meets it) takes what this
/// notice's own send already settled, with no CLI call, whichever walker's
/// settle it was: a send made `sent` and a found `sent` both mark `sent`;
/// `archived` or `failed`, made or found, takes the terminal mark; a send
/// found owed under this key is held until it settles (the verb's reconcile,
/// or the operator's mark after the watch's `directive-send-unsettled` line),
/// and one found unreadable is held too, never a reason to act. A refusal
/// (the send's outcome unknown, another send still owed on the lane, the
/// lane's record moved) holds the stage owed and sends nothing. The residual,
/// stated and not claimed exactly-once: a crash after this send's settle,
/// then another send to the same lane, then the replay, sends the notice
/// twice, a repeated line in the session and not a harm.
fn send_session(
    settings: &Settings,
    reach: &Reach,
    lane: &Lane,
    key: &str,
    file: &Path,
    env: &Env,
    locking: Locking,
) -> NoticeSend {
    match run_keyed(&lane.item, file, settings, reach, env, locking, key) {
        Ok(Keyed::Sent(sent)) => NoticeSend::Marked(session_mark(sent.send.result)),
        Ok(Keyed::Found(KeyedSend::Settled(result))) => NoticeSend::Marked(session_mark(result)),
        Ok(Keyed::Found(KeyedSend::Owed | KeyedSend::Unreadable)) | Err(_) => NoticeSend::Held,
    }
}

/// The send under `keyed`'s key through its reach, else the `send` verb's
/// own: the caller's mailbox program in the directory the caller runs in.
fn send(
    path: &Path,
    item: &str,
    file: &Path,
    settings: &Settings,
    env: &Env,
    locking: Locking,
    keyed: Option<(&str, &Reach)>,
) -> Result<Keyed> {
    let key = keyed.map(|(key, _)| key);
    let text = std::fs::read_to_string(file)
        .map_err(|e| Error::Runtime(agent_runtime::Error::io("read-directive", file, e)))?
        .trim_end()
        .to_owned();
    // The route is read before the owed write, so a record that cannot be
    // read leaves no send owed that no program ran.
    let fleet = fleet(path)?;
    let owed = apply(
        path,
        item,
        DirectiveWrite::Owed {
            text,
            key: key.map(str::to_owned),
        },
        env,
        locking,
    )?;
    if let Some(found) = owed.found {
        return Ok(Keyed::Found(found));
    }
    let Some(name) = receipt_name(&owed.directive_send) else {
        unreachable!("the owed write names its receipt: {owed:?}");
    };
    let receipt = receipt_path(&settings.state_dir, item, name);
    let (program, cwd) = match keyed {
        Some((_, reach)) => (&reach.mail_program, Some(reach.mail_root.as_path())),
        None => (&settings.lane_mail_cli, None),
    };
    let lane = fleet
        .lanes
        .iter()
        .find(|l| l.item == item)
        .ok_or_else(|| Error::LaneMissing {
            item: item.to_owned(),
        })?;
    let answer =
        Mailbox::new(program.clone()).send_directive(item, Route::of(lane), file, None, cwd);
    let send = match answer {
        Ok(Sent::Session { send }) => send,
        Ok(Sent::Mailbox { id, .. } | Sent::Repeated { id }) => {
            return Err(unsettled(
                item,
                format!("delivered to a mailbox as envelope {id}, not to a session"),
            ));
        }
        Err(refusal) if refusal.wrote_nothing() => DirectiveSend {
            result: SendResult::Failed,
            text: refusal.to_string(),
            credit: Credit::Unread(Word::Unread),
        },
        Err(refusal) => return Err(unsettled(item, refusal.to_string())),
    };
    let at = env.now_secs;
    let kept = keep_receipt(
        &receipt,
        &Receipt {
            at,
            send: send.clone(),
        },
    );
    let write = DirectiveWrite::Settled {
        at,
        send: send.clone(),
    };
    let mark = match apply(path, item, write, env, locking) {
        Ok(recorded) => {
            clear_receipt(&receipt)?;
            Mark::Recorded {
                directive_send: recorded.directive_send,
            }
        }
        Err(e) => match kept {
            Ok(()) => Mark::Unmarked {
                refusal: e.key().to_owned(),
                receipt,
            },
            Err(cause) => {
                return Err(unsettled(
                    item,
                    format!(
                        "the mark refused {}: {e}; the receipt was not kept: {cause}",
                        e.key()
                    ),
                ));
            }
        },
    };
    Ok(Keyed::Sent(DirectiveSent {
        item: item.to_owned(),
        send,
        mark,
    }))
}

fn unsettled(item: &str, cause: String) -> Error {
    Error::DirectiveSendUnsettled {
        item: item.to_owned(),
        cause,
    }
}

/// What the reconcile settled: the lanes whose kept receipt it stamped, and
/// the owed lanes it could not settle, each with its cause.
#[derive(Debug, Default, Serialize)]
pub struct Settled {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub sends_settled: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub sends_unsettled: Vec<SendUnsettled>,
}

/// An owed send the reconcile left as it found it. `cause` is one word, the
/// watch's `directive-send-unsettled` line's: `receipt-missing` (no receipt
/// was kept: the send never earned one, or the verb ended before keeping
/// it), `receipt-unnamed` (the record names none: a record another writer
/// shaped), `receipt-invalid` or `receipt-unreadable` (the kept receipt
/// could not be read, `detail` the reader's text), or the key the store
/// refused the mark by again.
#[derive(Debug, Serialize)]
pub struct SendUnsettled {
    pub item: String,
    pub cause: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl SendUnsettled {
    fn new(item: String, cause: &str, detail: Option<String>) -> SendUnsettled {
        SendUnsettled {
            item,
            cause: cause.to_owned(),
            detail,
        }
    }
}

/// Stamp the kept receipt of every lane whose `directive_send` stands owed
/// (the reconcile's continuation of a send whose mark the store refused).
/// Nothing is sent: a lane with no kept receipt stays owed and is reported.
pub fn settle(path: &Path, settings: &Settings, env: &Env, locking: Locking) -> Result<Settled> {
    let fleet = fleet(path)?;
    let mut settled = Settled::default();
    for lane in fleet.lanes.iter().filter(|lane| owed(&lane.extra)) {
        let item = lane.item.clone();
        let Some(name) = lane.extra.get("directive_send").and_then(receipt_name) else {
            settled
                .sends_unsettled
                .push(SendUnsettled::new(item, "receipt-unnamed", None));
            continue;
        };
        let receipt = receipt_path(&settings.state_dir, &item, name);
        let Receipt { at, send } = match std::fs::read(&receipt) {
            Ok(bytes) => match serde_json::from_slice(&bytes) {
                Ok(receipt) => receipt,
                Err(e) => {
                    settled.sends_unsettled.push(SendUnsettled::new(
                        item,
                        "receipt-invalid",
                        Some(e.to_string()),
                    ));
                    continue;
                }
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                settled
                    .sends_unsettled
                    .push(SendUnsettled::new(item, "receipt-missing", None));
                continue;
            }
            Err(e) => {
                settled.sends_unsettled.push(SendUnsettled::new(
                    item,
                    "receipt-unreadable",
                    Some(e.to_string()),
                ));
                continue;
            }
        };
        match apply(
            path,
            &item,
            DirectiveWrite::Settled { at, send },
            env,
            locking,
        ) {
            Ok(_) => {
                clear_receipt(&receipt)?;
                settled.sends_settled.push(item);
            }
            Err(e) => settled
                .sends_unsettled
                .push(SendUnsettled::new(item, e.key(), None)),
        }
    }
    Ok(settled)
}

/// The send's two writes of the lane record, through the one store entry.
#[allow(
    clippy::disallowed_methods,
    reason = "the session send's writes of the lane record: the owed stage before the mailbox program starts and the receipt after, each through the one store entry"
)]
fn apply(
    path: &Path,
    item: &str,
    write: DirectiveWrite,
    env: &Env,
    locking: Locking,
) -> Result<DirectiveSendRecorded> {
    let request = Request::RecordDirectiveSend(RecordDirectiveSend {
        item: item.to_owned(),
        write,
    });
    match ops::apply(path, &request, env, locking)?.report {
        Report::RecordDirectiveSend(recorded) => Ok(recorded),
        other => unreachable!("a record-directive-send request reports its record, not {other:?}"),
    }
}

/// The send's and the reconcile's read of the fleet record.
#[allow(
    clippy::disallowed_methods,
    reason = "the fleet record read for the lane's route before its owed write, and by the settle for the lanes whose send stands owed"
)]
fn fleet(path: &Path) -> Result<state::FleetState> {
    use state::Record;
    let snapshot = state::load(path)?.ok_or_else(|| {
        Error::Runtime(agent_runtime::Error::RecordMissing {
            path: path.to_path_buf(),
        })
    })?;
    state::FleetState::view(path, &snapshot.doc)
}

/// Keep the receipt at `path` before the mark, so a refused mark loses
/// nothing the reconcile needs. A receipt that could not be kept is
/// answered as the cause, for the mark's own outcome to weigh.
#[allow(
    clippy::disallowed_methods,
    reason = "the send's receipt file, written between the program's answer and the mark it waits for"
)]
fn keep_receipt(path: &Path, receipt: &Receipt) -> std::result::Result<(), String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    let text = serde_json::to_vec(receipt).map_err(|e| e.to_string())?;
    std::fs::write(path, text).map_err(|e| format!("{}: {e}", path.display()))
}

/// Remove the receipt at `path` once its mark stands; one that is not
/// there is nothing to remove, any other failure refuses.
#[allow(
    clippy::disallowed_methods,
    reason = "the send's receipt file, removed once its mark stands"
)]
fn clear_receipt(path: &Path) -> Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(Error::Runtime(agent_runtime::Error::io(
            "remove-receipt",
            path,
            e,
        ))),
    }
}
