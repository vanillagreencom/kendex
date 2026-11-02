//! The session send (step6-map § A6; decisions 31, 170, 182): one directive
//! to a cloud session lane, made once through the mailbox program. A
//! session send is irreversible and leaves no queue a repeat could be
//! judged against, so the lane record says a send is out before the program
//! starts (`directive_send` at its owed stage), the receipt the program
//! prints on stderr is stamped over it after, and a mark the store refused
//! leaves the record owed with the receipt kept beside the state, where the
//! reconcile stamps it without a second send. An owed record no receipt
//! settles is the watch's `directive-send-unsettled` line, once per item
//! and cause, and the operator's mark through the `op` entry settles it
//! (decision 184 (5)). The mailbox writes no orch state (decision 31); this
//! module and that mark are the record's writers.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::{Error, Result};
use crate::mailbox::{Mailbox, Refusal, Sent};
use crate::ops::mail::{
    Credit, DirectiveSend, DirectiveSendRecorded, DirectiveWrite, KeyedSend, RecordDirectiveSend,
    SendResult, Word, owed,
};
use crate::ops::{self, Env, Report, Request};
use crate::settings::Settings;
use crate::state::{self, Locking};

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
/// `lane-mail send --item --directive --file --state-dir` through the one
/// runner, then the receipt as the mark. A refusal the program prints by its
/// own key with no receipt (a foreign root, an unrecorded session) is a send
/// that ran no CLI, recorded `failed` with that line; a program that gave
/// no answer, ended on a signal or printed a receipt that does not decode
/// leaves the record owed and refuses `directive-send-unsettled`, since
/// whether the directive reached the session is unknown. The `send` verb's
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
/// no program run (decision 193 (a)).
#[derive(Debug)]
pub enum Keyed {
    Sent(DirectiveSent),
    Found(KeyedSend),
}

/// [`run`] under `key`, the caller's name for this send (the validation end
/// notice's `validate-<run_id>`, decision 188 (d)): the owed write carries
/// it, every settle keeps it on the record, and the write reads the lane's
/// send under it before it writes, inside the store's lock (decision 193
/// (a)), so a replay of the notice, whichever walker makes it, learns from
/// the one record whether its own send is out or settled and makes no
/// second one; nothing is run on a found send.
pub fn run_keyed(
    path: &Path,
    item: &str,
    file: &Path,
    settings: &Settings,
    env: &Env,
    locking: Locking,
    key: &str,
) -> Result<Keyed> {
    send(path, item, file, settings, env, locking, Some(key))
}

fn send(
    path: &Path,
    item: &str,
    file: &Path,
    settings: &Settings,
    env: &Env,
    locking: Locking,
    key: Option<&str>,
) -> Result<Keyed> {
    let text = std::fs::read_to_string(file)
        .map_err(|e| Error::Runtime(agent_runtime::Error::io("read-directive", file, e)))?
        .trim_end()
        .to_owned();
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
    let answer = Mailbox::new(settings.lane_mail_cli.clone()).send_directive(
        item,
        None,
        false,
        file,
        None,
        Some(&settings.state_dir),
    );
    let send = match answer {
        Ok(Sent::Session { send }) => send,
        Ok(Sent::Mailbox { id, .. } | Sent::Repeated { id }) => {
            return Err(unsettled(
                item,
                format!("delivered to a mailbox as envelope {id}, not to a session"),
            ));
        }
        Err(Refusal::Exit {
            status: Some(_),
            keyed: Some(line),
            ..
        }) => DirectiveSend {
            result: SendResult::Failed,
            text: line,
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

/// The reconcile's one read of the fleet record.
#[allow(
    clippy::disallowed_methods,
    reason = "the settle's one read of the fleet record, for the lanes whose send stands owed"
)]
fn fleet(path: &Path) -> Result<state::FleetState> {
    use state::Record;
    let snapshot = state::load(path)?.ok_or_else(|| Error::RecordMissing {
        path: path.to_path_buf(),
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
