//! The mailbox client: the watch's mailbox reads, the owner asks' answers
//! and closes, directive sends, lane notices, the owner notices and the
//! overseer mailbox's compaction, each a `lane-mail` call through
//! agent-runtime's one runner under the tag `mail` and under one bound, and
//! each reply decoded into typed records at this boundary. A program that never
//! started, one that gave no answer, a nonzero exit and a reply the decoder
//! cannot read are each a typed [`Refusal`] that stops the one read it
//! answered; no refusal is ever read as an empty mailbox. A program that
//! never started did nothing, where one that gave no answer may have
//! written: a send's caller reads the two apart through
//! [`Refusal::wrote_nothing`].
//!
//! The wire forms are `lane-mail --help`'s: the `count= first=` header, one
//! JSON envelope per line, the `receipts` section of `drain --receipts`, the
//! `item=` sections of `drain-many`, the keyed `lane-mail: <key>=<value>`
//! refusal lines and the receipts of `send` and `resolve`. An envelope's
//! absent and null fields read alike, as `lane-mail`'s own `.field // ""`
//! reads them.

use std::fmt;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host::{self, Place};
use serde::Deserialize;

use crate::ops::mail::DirectiveSend;

/// The bound on one call: the same one the close's `lane-mail pending` runs
/// under.
pub const BOUND: Duration = Duration::from_secs(60);

/// The name a failure reports and the start counter's key.
const PROGRAM: &str = "lane-mail";

/// The duty every start is counted under.
const TAG: &str = "mail";

/// The record line a session send prints on stderr, whatever its result,
/// after a refusal's keyed line where it refuses; read by its prefix.
const DIRECTIVE_SEND: &str = "lane-mail: directive-send item=";

/// The keyed line's prefix.
const KEYED: &str = "lane-mail: ";

/// The client over the mailbox program at `cli`.
#[derive(Debug, Clone)]
pub struct Mailbox {
    cli: PathBuf,
    bound: Duration,
}

/// Why one call did not answer: the refusals of the module doc, each
/// naming the verb it stopped.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// The program never started (the runner's `not-started`, or the
    /// request file it reads not written): nothing it would do was done.
    NotStarted { verb: &'static str, cause: String },
    /// It started and gave no answer within the bound: what it did is not
    /// known.
    Unanswered { verb: &'static str, cause: String },
    /// It exited nonzero: `status` is `None` on a signal, `keyed` the first
    /// `lane-mail: <key>=<value>` line of its stderr, where it printed one.
    Exit {
        verb: &'static str,
        status: Option<i32>,
        keyed: Option<String>,
        stderr: String,
    },
    /// It answered, and the reply is not the verb's documented form:
    /// `cause` names the part, `line` the text it stopped on.
    Reply {
        verb: &'static str,
        cause: &'static str,
        line: String,
    },
}

impl Refusal {
    pub fn verb(&self) -> &'static str {
        match self {
            Refusal::NotStarted { verb, .. }
            | Refusal::Unanswered { verb, .. }
            | Refusal::Exit { verb, .. }
            | Refusal::Reply { verb, .. } => verb,
        }
    }

    /// Whether a `send` or `notice` provably wrote nothing, so its caller
    /// may record the delivery refused rather than unknown. A program that
    /// never started did nothing, and `lane-mail` prints every keyed refusal
    /// of these verbs before their local append. Anything else (no answer, a
    /// signal, an exit with no keyed line, a reply that does not decode) may
    /// follow the append. The keyed line read is the first one, so the claim
    /// holds only for a local append with no `--ref`: a hosted append can
    /// refuse after a provider write whose reply was lost, and `--ref` prints
    /// a keyed warning that is no refusal.
    pub fn wrote_nothing(&self) -> bool {
        matches!(
            self,
            Refusal::NotStarted { .. }
                | Refusal::Exit {
                    status: Some(_),
                    keyed: Some(_),
                    ..
                }
        )
    }
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Refusal::NotStarted { verb, cause } | Refusal::Unanswered { verb, cause } => {
                write!(f, "{verb}: {cause}")
            }
            Refusal::Exit {
                verb,
                status,
                keyed,
                stderr,
            } => {
                write!(f, "{verb}: status=")?;
                match status {
                    Some(code) => write!(f, "{code}")?,
                    None => write!(f, "signal")?,
                }
                match keyed {
                    Some(line) => write!(f, " {line}"),
                    None => write!(f, " {}", stderr.trim()),
                }
            }
            Refusal::Reply { verb, cause, line } => write!(f, "{verb}: reply-{cause} line={line}"),
        }
    }
}

impl From<Refusal> for crate::Error {
    fn from(refusal: Refusal) -> crate::Error {
        crate::Error::Runtime(agent_runtime::Error::External {
            program: PROGRAM,
            operation: refusal.verb(),
            cause: refusal.to_string(),
        })
    }
}

/// One envelope as the mailbox prints it, the fields the watch reads; the
/// rest of the object is not carried.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct Envelope {
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub options: Vec<String>,
    #[serde(default)]
    pub from: Option<String>,
    #[serde(default)]
    pub re: Option<String>,
    #[serde(default)]
    pub by: Option<String>,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub to: Option<String>,
    #[serde(default)]
    pub attach: Option<String>,
    #[serde(default)]
    pub reserved: Option<bool>,
    #[serde(default)]
    pub deadline: Option<String>,
    #[serde(default)]
    pub recommend: Option<String>,
    /// `events --box` alone: the envelope's logical line.
    #[serde(default)]
    pub line: Option<u64>,
    /// `events --box to-lane` alone: the shared mailbox rule's class.
    #[serde(default)]
    pub mail_class: Option<String>,
    #[serde(default)]
    pub tracker_posted: Option<bool>,
    /// An owner ask alone (`pending --to owner`): the tracker item it was
    /// posted to, the action it asks for, the comment and label it was
    /// posted under.
    #[serde(default)]
    pub issue: Option<String>,
    #[serde(default, rename = "do")]
    pub action: Option<String>,
    #[serde(default)]
    pub tracker_comment: Option<String>,
    #[serde(default)]
    pub tracker_label: Option<String>,
}

impl Envelope {
    pub fn id(&self) -> &str {
        self.id.as_deref().unwrap_or("")
    }

    pub fn kind(&self) -> &str {
        self.kind.as_deref().unwrap_or("")
    }
}

/// Where a lane's read stands, from `drain --receipts`: the count its
/// `to-lane.cursor` holds, or `missed` for a read that was not one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cursor {
    Read(u64),
    Missed,
}

/// One directive of `to-lane.jsonl`: its logical line, its id and its `at`
/// in epoch seconds, where that parsed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Directive {
    pub line: u64,
    pub id: String,
    pub at: Option<u64>,
}

/// The `receipts` section of a drain.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Receipts {
    pub cursor: Cursor,
    pub count: u64,
    pub first: String,
    pub directives: Vec<Directive>,
}

/// What `drain --receipts` answered for one lane.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Drained {
    pub count: u64,
    pub first: String,
    pub envelopes: Vec<Envelope>,
    pub receipts: Receipts,
}

/// One lane of a batched drain.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Drain {
    pub item: String,
    pub after: u64,
    pub root: PathBuf,
}

/// What `events --box to-lane --after N` answered for the overseer's box:
/// the header and every envelope past line N, each with its line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BoxEvents {
    pub count: u64,
    pub first: String,
    pub envelopes: Vec<Envelope>,
}

/// What `drain-many` answered: the lanes it drained, in the order asked and
/// as many as it printed whole, and the refusal that stopped it, where one
/// did. The program stops at the first lane it refuses with no section of
/// that lane's own, so the lane at `read.len()` in the request is the one
/// refused, and the lanes before it stand; a program that did not start or
/// answer drained none.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Batch {
    pub read: Vec<Drained>,
    pub refused: Option<Refusal>,
}

/// How a `resolve --default` ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Resolved {
    /// Closed now, `by` the closing form and `answer` the close record's id.
    Closed { by: String, answer: String },
    /// Another close won the mailbox lock first; `id` names its record.
    Already { id: String },
}

/// How a `send --re` reply to an overseer ask ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Replied {
    /// Appended to the overseer's mailbox under `id`.
    Sent { id: String },
    /// The delivery id already stood there: a retry of a reply that landed.
    Repeated { id: String },
}

/// How a `send --directive` ended.
#[derive(Debug, Clone, PartialEq)]
pub enum Sent {
    /// Appended to the lane's mailbox: the envelope's id and the monitor
    /// word of the receipt.
    Mailbox { id: String, monitor: String },
    /// The delivery id already stood in the mailbox: the send is a retry of
    /// one that landed, and `id` names that envelope.
    Repeated { id: String },
    /// The lane runs in a cloud session: the record the mailbox hands back,
    /// whatever the send's own result.
    Session { send: DirectiveSend },
}

/// How a lane's `notice` ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Noticed {
    /// Appended to the lane's `to-overseer.jsonl` under `id`.
    Sent { id: String },
    /// The same envelope stood there from less than a minute before (the
    /// program's `duplicate id=`): a retry of a notice that landed.
    Repeated { id: String },
}

/// One run's answer, before a verb reads it.
struct Answer {
    success: bool,
    status: Option<i32>,
    stdout: String,
    stderr: String,
}

impl Answer {
    /// The first keyed line of stderr, without its prefix.
    fn keyed(&self) -> Option<String> {
        self.stderr
            .lines()
            .find_map(|l| l.strip_prefix(KEYED))
            .map(str::to_owned)
    }

    fn refused(&self, verb: &'static str) -> Refusal {
        Refusal::Exit {
            verb,
            status: self.status,
            keyed: self.keyed(),
            stderr: self.stderr.clone(),
        }
    }

    /// The reply of a run that exited 0; the refusal of one that did not.
    fn ok(self, verb: &'static str) -> Result<String, Refusal> {
        if self.success {
            Ok(self.stdout)
        } else {
            Err(self.refused(verb))
        }
    }
}

fn reply(verb: &'static str, cause: &'static str, line: &str) -> Refusal {
    Refusal::Reply {
        verb,
        cause,
        line: line.to_owned(),
    }
}

/// `count=N first=F` from a header line.
fn header(verb: &'static str, line: &str) -> Result<(u64, String), Refusal> {
    let rest = line
        .strip_prefix("count=")
        .ok_or_else(|| reply(verb, "header", line))?;
    let (count, first) = rest
        .split_once(" first=")
        .ok_or_else(|| reply(verb, "header", line))?;
    let count = count.parse().map_err(|_| reply(verb, "header", line))?;
    Ok((count, first.to_owned()))
}

fn envelope(verb: &'static str, line: &str) -> Result<Envelope, Refusal> {
    serde_json::from_str(line).map_err(|_| reply(verb, "envelope", line))
}

impl Drained {
    /// Decode one lane's drain from `lines`, which stops at the section's end.
    fn parse<'a>(
        verb: &'static str,
        lines: &mut std::iter::Peekable<impl Iterator<Item = &'a str>>,
    ) -> Result<Drained, Refusal> {
        let first_line = lines.next().ok_or_else(|| reply(verb, "short", ""))?;
        let (count, first) = header(verb, first_line)?;
        let mut envelopes = Vec::new();
        let mut receipts = None;
        while let Some(line) = lines.next() {
            if let Some(rest) = line.strip_prefix("receipts cursor=") {
                let (cursor, rest) = rest
                    .split_once(" count=")
                    .ok_or_else(|| reply(verb, "receipts", line))?;
                let cursor = match cursor {
                    "missed" => Cursor::Missed,
                    n => Cursor::Read(n.parse().map_err(|_| reply(verb, "receipts", line))?),
                };
                let (count, first) = rest
                    .split_once(" first=")
                    .ok_or_else(|| reply(verb, "receipts", line))?;
                let count = count.parse().map_err(|_| reply(verb, "receipts", line))?;
                let mut directives = Vec::new();
                while let Some(line) = lines.peek().copied() {
                    if line.starts_with("item=") {
                        break;
                    }
                    lines.next();
                    let mut fields = line.splitn(3, ' ');
                    let number = fields.next().unwrap_or_default();
                    let id = fields
                        .next()
                        .ok_or_else(|| reply(verb, "directive", line))?;
                    let at = fields.next().unwrap_or_default();
                    let at = if at.is_empty() {
                        None
                    } else {
                        Some(at.parse().map_err(|_| reply(verb, "directive", line))?)
                    };
                    directives.push(Directive {
                        line: number.parse().map_err(|_| reply(verb, "directive", line))?,
                        id: id.to_owned(),
                        at,
                    });
                }
                receipts = Some(Receipts {
                    cursor,
                    count,
                    first: first.to_owned(),
                    directives,
                });
                break;
            }
            envelopes.push(envelope(verb, line)?);
        }
        // A drain cut short of its receipts section answered for no lane.
        let receipts = receipts.ok_or_else(|| reply(verb, "short", first_line))?;
        Ok(Drained {
            count,
            first,
            envelopes,
            receipts,
        })
    }
}

/// The `lane-mail: <key>=<value> ...` line's key and the rest.
fn keyed_value<'a>(keyed: &'a str, key: &str) -> Option<&'a str> {
    keyed.strip_prefix(key)?.strip_prefix('=')
}

/// `id=<id>` among a keyed line's trailing fields.
fn id_field(rest: &str) -> Option<String> {
    rest.split(' ')
        .find_map(|f| f.strip_prefix("id="))
        .map(str::to_owned)
}

impl Mailbox {
    pub fn new(cli: PathBuf) -> Mailbox {
        Mailbox { cli, bound: BOUND }
    }

    /// The same client under another bound: a row that holds the program
    /// on a FIFO waits it out at this bound.
    pub fn bounded(self, bound: Duration) -> Mailbox {
        Mailbox { bound, ..self }
    }

    /// One run of the program: the verb first, then `args`, under the bound.
    fn call(&self, verb: &'static str, args: &[&str]) -> Result<Answer, Refusal> {
        self.call_on(verb, args, None, None)
    }

    /// [`Self::call`] with `lane-host`'s host named: a hosted lane's reads
    /// go to the provider its record names, never the one the settings name;
    /// and in `cwd` where the verb is rooted at the checkout it runs in.
    #[allow(
        clippy::disallowed_methods,
        reason = "the mailbox client's every `lane-mail` call, through agent-runtime's one runner under the `mail` tag and one bound; the duty writes nothing of the fleet through it"
    )]
    fn call_on(
        &self,
        verb: &'static str,
        args: &[&str],
        lane_host: Option<&str>,
        cwd: Option<&Path>,
    ) -> Result<Answer, Refusal> {
        let mut argv = Vec::with_capacity(args.len() + 1);
        argv.push(verb);
        argv.extend_from_slice(args);
        let env: Vec<(&str, &std::ffi::OsStr)> = lane_host
            .map(|h| ("ORCH_LANE_HOST", std::ffi::OsStr::new(h)))
            .into_iter()
            .collect();
        let place = Place { cwd, env: &env };
        let output = host::run_tagged_in(TAG, PROGRAM, &self.cli, verb, &argv, place, self.bound)
            .map_err(|e| {
            let cause = e.to_string();
            match e {
                agent_runtime::Error::NotStarted { .. } => Refusal::NotStarted { verb, cause },
                _ => Refusal::Unanswered { verb, cause },
            }
        })?;
        Ok(Answer {
            success: output.status.success(),
            status: output.status.code(),
            stdout: host::stdout_text(&output),
            stderr: host::stderr_text(&output),
        })
    }

    /// `drain-many`: every lane of `lanes` drained in one process, in order,
    /// each with its receipts; the request is written to `request` first.
    /// The lanes printed whole before a refusal stand; a lane the reply
    /// stops short of, names out of order or cuts is answered for by the
    /// refusal, never read as empty.
    #[allow(
        clippy::disallowed_methods,
        reason = "the mail duty's one request file, written whole beside the watch's own records for the one batched read"
    )]
    pub fn drain_many(&self, request: &Path, lanes: &[Drain]) -> Batch {
        const VERB: &str = "drain-many";
        let mut text = String::new();
        for lane in lanes {
            text.push_str(&format!(
                "{} {} {}\n",
                lane.item,
                lane.after,
                lane.root.display()
            ));
        }
        let write = || -> std::io::Result<()> {
            let mut file = std::fs::File::create(request)?;
            file.write_all(text.as_bytes())?;
            file.sync_data()
        };
        let answer = write()
            .map_err(|e| Refusal::NotStarted {
                verb: VERB,
                cause: format!("request {}: {e}", request.display()),
            })
            .and_then(|()| self.call(VERB, &["--file", &request.display().to_string()]));
        let answer = match answer {
            Ok(answer) => answer,
            Err(refusal) => {
                return Batch {
                    read: Vec::new(),
                    refused: Some(refusal),
                };
            }
        };
        let mut lines = answer.stdout.lines().peekable();
        let mut read = Vec::new();
        let mut stopped = None;
        for lane in lanes {
            match lines.next() {
                // The reply ended: the lanes from here on were not drained.
                None => break,
                Some(line) if line.strip_prefix("item=") == Some(lane.item.as_str()) => {
                    match Drained::parse(VERB, &mut lines) {
                        Ok(drained) => read.push(drained),
                        Err(refusal) => {
                            stopped = Some(refusal);
                            break;
                        }
                    }
                }
                Some(line) => {
                    stopped = Some(reply(VERB, "item", line));
                    break;
                }
            }
        }
        // The program's own refusal names the cause where it exited on
        // one; a reply that ended early or ran past the lanes asked under
        // a clean exit is refused on its form.
        let refused = if !answer.success {
            Some(answer.refused(VERB))
        } else if stopped.is_some() {
            stopped
        } else if read.len() < lanes.len() {
            Some(reply(VERB, "short", &answer.stdout))
        } else {
            lines.next().map(|extra| reply(VERB, "trailing", extra))
        };
        Batch { read, refused }
    }

    /// `drain --receipts` for one lane; a hosted lane's through `lane-host`
    /// under `host`, its record's host.
    pub fn drain(&self, lane: &Drain, host: Option<&str>) -> Result<Drained, Refusal> {
        const VERB: &str = "drain";
        let after = lane.after.to_string();
        let root = lane.root.display().to_string();
        let mut args = vec![
            "--item",
            &lane.item,
            "--root",
            &root,
            "--after",
            &after,
            "--receipts",
        ];
        if host.is_some() {
            args.push("--host");
        }
        let stdout = self.call_on(VERB, &args, host, None)?.ok(VERB)?;
        let mut lines = stdout.lines().peekable();
        let drained = Drained::parse(VERB, &mut lines)?;
        if let Some(extra) = lines.next() {
            return Err(reply(VERB, "trailing", extra));
        }
        Ok(drained)
    }

    /// `events --item overseer --box to-lane --after N` at the main
    /// checkout `root`: the overseer's box read by logical line, no cursor
    /// touched.
    pub fn box_events(&self, root: &Path, after: u64) -> Result<BoxEvents, Refusal> {
        const VERB: &str = "events";
        let after = after.to_string();
        let root = root.display().to_string();
        let stdout = self
            .call(
                VERB,
                &[
                    "--item", "overseer", "--root", &root, "--box", "to-lane", "--after", &after,
                ],
            )?
            .ok(VERB)?;
        let mut lines = stdout.lines();
        let (count, first) = header(VERB, lines.next().ok_or_else(|| reply(VERB, "short", ""))?)?;
        let mut envelopes = Vec::new();
        for line in lines {
            let env = envelope(VERB, line)?;
            if env.line.is_none() {
                return Err(reply(VERB, "line", line));
            }
            envelopes.push(env);
        }
        Ok(BoxEvents {
            count,
            first,
            envelopes,
        })
    }

    /// `pending --item overseer --to owner`: every pending owner ask, one
    /// row per line.
    pub fn pending_owner_asks(&self, root: &Path) -> Result<Vec<Envelope>, Refusal> {
        self.owner_asks(root, &[])
    }

    /// `pending --item overseer --to owner --due`: the owner asks whose
    /// deadline has passed and whose form lets it close them.
    pub fn due_owner_asks(&self, root: &Path) -> Result<Vec<Envelope>, Refusal> {
        self.owner_asks(root, &["--due"])
    }

    /// `pending --item ITEM --root ROOT`: the lane's open asks and the
    /// directives it has not read, moving no cursor; a hosted lane's
    /// through `lane-host` under `host`, its record's host.
    pub fn pending(
        &self,
        item: &str,
        root: &Path,
        host: Option<&str>,
    ) -> Result<Vec<Envelope>, Refusal> {
        const VERB: &str = "pending";
        let root = root.display().to_string();
        let mut args = vec!["--item", item, "--root", &root];
        if host.is_some() {
            args.push("--host");
        }
        let stdout = self.call_on(VERB, &args, host, None)?.ok(VERB)?;
        stdout
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| envelope(VERB, l))
            .collect()
    }

    fn owner_asks(&self, root: &Path, select: &[&str]) -> Result<Vec<Envelope>, Refusal> {
        const VERB: &str = "pending";
        let root = root.display().to_string();
        let mut args = vec!["--item", "overseer", "--root", &root, "--to", "owner"];
        args.extend_from_slice(select);
        let stdout = self.call(VERB, &args)?.ok(VERB)?;
        stdout
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| envelope(VERB, l))
            .collect()
    }

    /// `send --item overseer --re ASK --delivery-id ID --file F`: an answer
    /// handed back to the overseer under
    /// the ask it answers; one that landed before under the same delivery
    /// id is `Replied::Repeated`, no failure.
    pub fn send_answer(
        &self,
        root: &Path,
        ask: &str,
        delivery_id: &str,
        file: &Path,
    ) -> Result<Replied, Refusal> {
        const VERB: &str = "send";
        let root = root.display().to_string();
        let file = file.display().to_string();
        let answer = self.call(
            VERB,
            &[
                "--item",
                "overseer",
                "--root",
                &root,
                "--re",
                ask,
                "--delivery-id",
                delivery_id,
                "--file",
                &file,
            ],
        )?;
        if !answer.success {
            if let Some(keyed) = answer.keyed()
                && let Some(rest) = keyed_value(&keyed, "delivery-repeated")
                && let Some(id) = id_field(rest)
            {
                return Ok(Replied::Repeated { id });
            }
            return Err(answer.refused(VERB));
        }
        // The reply's receipt, `lane-mail: sent item=<item> id=<id> bytes=<n>
        // to=<lane> ref=<ask>`: the reply form carries no monitor word.
        let line = answer
            .stdout
            .lines()
            .find(|l| l.starts_with("lane-mail: sent item="))
            .ok_or_else(|| reply(VERB, "receipt", &answer.stdout))?;
        line.split(' ')
            .find_map(|field| field.strip_prefix("id="))
            .map(|id| Replied::Sent { id: id.to_owned() })
            .ok_or_else(|| reply(VERB, "receipt", line))
    }

    /// `resolve --item overseer --id ID --default`: close a due ask with its
    /// recommendation. Run from inside the checkout, as every overseer
    /// write is.
    pub fn resolve_default(&self, root: &Path, id: &str) -> Result<Resolved, Refusal> {
        const VERB: &str = "resolve";
        let root = root.display().to_string();
        let answer = self.call(
            VERB,
            &[
                "--item",
                "overseer",
                "--root",
                &root,
                "--id",
                id,
                "--default",
            ],
        )?;
        if !answer.success {
            if let Some(keyed) = answer.keyed()
                && let Some(rest) = keyed_value(&keyed, "resolved-already")
                && let Some(id) = id_field(rest)
            {
                return Ok(Resolved::Already { id });
            }
            return Err(answer.refused(VERB));
        }
        let line = answer
            .stdout
            .lines()
            .find(|l| l.starts_with("lane-mail: resolved id="))
            .ok_or_else(|| reply(VERB, "receipt", &answer.stdout))?;
        let mut by = None;
        let mut close = None;
        for field in line.split(' ') {
            if let Some(v) = field.strip_prefix("by=") {
                by = Some(v.to_owned());
            } else if let Some(v) = field.strip_prefix("answer=") {
                close = Some(v.to_owned());
            }
        }
        match (by, close) {
            (Some(by), Some(answer)) => Ok(Resolved::Closed { by, answer }),
            _ => Err(reply(VERB, "receipt", line)),
        }
    }

    /// `send --directive` to the lane `item`, the text in `file`: at `root`
    /// where the caller names the mailbox root, else at the checkout the
    /// program runs in; under `delivery_id` where the caller names its
    /// delivery, so a retry after a crash between the append and the receipt
    /// lands nothing twice; against the fleet record under `state_dir` where
    /// the caller names one, so the program routes by the lane's recorded
    /// channel. A session lane's receipt is handed back whatever its result.
    pub fn send_directive(
        &self,
        item: &str,
        root: Option<&Path>,
        hosted: bool,
        file: &Path,
        delivery_id: Option<&str>,
        state_dir: Option<&Path>,
    ) -> Result<Sent, Refusal> {
        const VERB: &str = "send";
        let root = root.map(|r| r.display().to_string());
        let state_dir = state_dir.map(|d| d.display().to_string());
        let file = file.display().to_string();
        let mut args = vec!["--item", item, "--directive", "--file", &file];
        if let Some(root) = &root {
            args.push("--root");
            args.push(root);
        }
        if hosted {
            args.push("--host");
        }
        if let Some(key) = delivery_id {
            args.push("--delivery-id");
            args.push(key);
        }
        if let Some(dir) = &state_dir {
            args.push("--state-dir");
            args.push(dir);
        }
        let answer = self.call(VERB, &args)?;
        if let Some(line) = answer
            .stderr
            .lines()
            .find(|l| l.starts_with(DIRECTIVE_SEND))
        {
            let send = decode_directive_send(line).ok_or_else(|| reply(VERB, "record", line))?;
            return Ok(Sent::Session { send });
        }
        if !answer.success {
            if let Some(keyed) = answer.keyed()
                && let Some(rest) = keyed_value(&keyed, "delivery-repeated")
                && let Some(id) = id_field(rest)
            {
                return Ok(Sent::Repeated { id });
            }
            return Err(answer.refused(VERB));
        }
        sent_line(VERB, &answer.stdout)
    }

    /// The lane's `notice --item ITEM --file F` to its overseer, run in the
    /// lane's worktree `root`: the program roots a lane verb at the checkout
    /// it runs in (`git rev-parse --show-toplevel`), so the envelope lands in
    /// `root`'s `tmp/lane-mail/ITEM/to-overseer.jsonl`, the box the watch
    /// drains. Under `delivery_id` the mailbox reads a replay as
    /// `Noticed::Repeated` whenever it comes; without one, only inside its
    /// minute window.
    pub fn notice(
        &self,
        item: &str,
        root: &Path,
        file: &Path,
        delivery_id: Option<&str>,
    ) -> Result<Noticed, Refusal> {
        const VERB: &str = "notice";
        let file = file.display().to_string();
        let mut args = vec!["--item", item, "--file", &file];
        if let Some(key) = delivery_id {
            args.push("--delivery-id");
            args.push(key);
        }
        let answer = self.call_on(VERB, &args, None, Some(root))?;
        if !answer.success {
            if let Some(keyed) = answer.keyed() {
                if let Some(id) = keyed.strip_prefix("duplicate id=") {
                    return Ok(Noticed::Repeated { id: id.to_owned() });
                }
                if let Some(rest) = keyed_value(&keyed, "delivery-repeated")
                    && let Some(id) = id_field(rest)
                {
                    return Ok(Noticed::Repeated { id });
                }
            }
            return Err(answer.refused(VERB));
        }
        // `lane-mail: sent item=<item> id=<id> bytes=<n> to= ref=`.
        let line = answer
            .stdout
            .lines()
            .find(|l| l.starts_with("lane-mail: sent item="))
            .ok_or_else(|| reply(VERB, "receipt", &answer.stdout))?;
        id_field(line)
            .map(|id| Noticed::Sent { id })
            .ok_or_else(|| reply(VERB, "receipt", line))
    }

    /// `notice --item overseer --to owner --file F` at the main checkout
    /// `root`, run there: a notice the owner relay carries, with no
    /// attachment. The owner holds the words on a clean exit, and on either
    /// refusal of a repeat of a notice that landed: the same envelope inside
    /// the minute (`duplicate id=`) or the same text inside the day
    /// (`owner-notice-repeated=`). No caller reads the receipt's id.
    pub fn owner_notice(&self, root: &Path, file: &Path) -> Result<(), Refusal> {
        const VERB: &str = "notice";
        let root_text = root.display().to_string();
        let file = file.display().to_string();
        let answer = self.call_on(
            VERB,
            &[
                "--item", "overseer", "--to", "owner", "--file", &file, "--root", &root_text,
            ],
            None,
            Some(root),
        )?;
        let repeated = answer.keyed().is_some_and(|keyed| {
            keyed.starts_with("duplicate id=") || keyed.starts_with("owner-notice-repeated=")
        });
        if answer.success || repeated {
            Ok(())
        } else {
            Err(answer.refused(VERB))
        }
    }

    /// `compact --item overseer --root ROOT`, run in the main checkout
    /// `root`, whose settings the program reads its retention from: what
    /// leaves the overseer mailbox is the mailbox skill's rule.
    pub fn compact(&self, root: &Path) -> Result<(), Refusal> {
        const VERB: &str = "compact";
        let root_text = root.display().to_string();
        self.call_on(
            VERB,
            &["--item", "overseer", "--root", &root_text],
            None,
            Some(root),
        )?
        .ok(VERB)
        .map(drop)
    }

    /// `events --item overseer` at the main checkout `root`: both of the
    /// overseer's boxes whole, the overseer's own sends among them.
    pub fn events(&self, root: &Path) -> Result<Vec<Envelope>, Refusal> {
        const VERB: &str = "events";
        let root = root.display().to_string();
        let stdout = self
            .call(VERB, &["--item", "overseer", "--root", &root])?
            .ok(VERB)?;
        stdout
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| envelope(VERB, l))
            .collect()
    }

    /// The owner notice carrying `attach`, run in `root`, where the program
    /// resolves the progress-report directory the attachment must sit in.
    /// The answer is the overseer box read back: the program's own exit
    /// cannot tell a lost reply, a minute-window `duplicate` or a day-window
    /// `owner-notice-repeated` naming another attachment from a send that
    /// landed, so only an owner notice carrying this attachment is a
    /// receipt, and one already standing sends nothing again.
    pub fn report_notice(
        &self,
        root: &Path,
        attach: &Path,
        summary: &Path,
    ) -> Result<String, Refusal> {
        const VERB: &str = "notice";
        let attach = attach.display().to_string();
        let confirmed = |events: Vec<Envelope>| {
            events
                .into_iter()
                .find(|e| {
                    e.kind() == "notice"
                        && e.to.as_deref() == Some("owner")
                        && e.attach.as_deref() == Some(&attach)
                })
                .and_then(|e| e.id)
        };
        if let Some(id) = confirmed(self.events(root)?) {
            return Ok(id);
        }
        let root_text = root.display().to_string();
        let summary = summary.display().to_string();
        let answer = self.call_on(
            VERB,
            &[
                "--item", "overseer", "--root", &root_text, "--to", "owner", "--attach", &attach,
                "--file", &summary,
            ],
            None,
            Some(root),
        )?;
        if let Some(id) = confirmed(self.events(root)?) {
            return Ok(id);
        }
        if !answer.success {
            return Err(answer.refused(VERB));
        }
        Err(reply(VERB, "attachment-unconfirmed", &answer.stdout))
    }
}

/// The `lane-mail: sent item=... id=... monitor=...` receipt of a send that
/// exited 0, from its stdout.
fn sent_line(verb: &'static str, stdout: &str) -> Result<Sent, Refusal> {
    let line = stdout
        .lines()
        .find(|l| l.starts_with("lane-mail: sent item="))
        .ok_or_else(|| reply(verb, "receipt", stdout))?;
    let mut id = None;
    let mut monitor = None;
    for field in line.split(' ') {
        if let Some(v) = field.strip_prefix("id=") {
            id = Some(v.to_owned());
        } else if let Some(v) = field.strip_prefix("monitor=") {
            monitor = Some(v.to_owned());
        }
    }
    match (id, monitor) {
        (Some(id), Some(monitor)) => Ok(Sent::Mailbox { id, monitor }),
        _ => Err(reply(verb, "receipt", line)),
    }
}

/// The record of a session send's receipt line, `lane-mail: directive-send
/// item=<item> record=<JSON>`; `None` where the line is not that.
pub fn decode_directive_send(line: &str) -> Option<DirectiveSend> {
    let rest = line.strip_prefix(DIRECTIVE_SEND)?;
    let (_, record) = rest.split_once(" record=")?;
    serde_json::from_str(record).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ops::mail::{Credit, SendResult};

    /// Every refusal shape against whether the send provably wrote nothing:
    /// a shape read as nothing written where the append may stand loses a
    /// delivery the replay would have proved, and the reverse resends one
    /// that never left.
    #[test]
    fn a_refusal_wrote_nothing_only_where_the_program_never_started_or_refused_by_its_key() {
        let exit = |status: Option<i32>, keyed: Option<&str>| Refusal::Exit {
            verb: "send",
            status,
            keyed: keyed.map(str::to_owned),
            stderr: "lane-mail: lane-foreign=x\n".to_owned(),
        };
        let cases = [
            (
                "not started",
                Refusal::NotStarted {
                    verb: "send",
                    cause: "not-started".into(),
                },
                true,
            ),
            (
                "keyed exit",
                exit(Some(2), Some("lane-mail: lane-foreign=x")),
                true,
            ),
            ("unkeyed exit", exit(Some(1), None), false),
            (
                "signal after a keyed line",
                exit(None, Some("lane-mail: lane-foreign=x")),
                false,
            ),
            ("signal", exit(None, None), false),
            (
                "unanswered",
                Refusal::Unanswered {
                    verb: "send",
                    cause: "timeout".into(),
                },
                false,
            ),
            (
                "undecoded reply",
                Refusal::Reply {
                    verb: "send",
                    cause: "receipt",
                    line: String::new(),
                },
                false,
            ),
        ];
        for (shape, refusal, wrote_nothing) in cases {
            assert_eq!(refusal.wrote_nothing(), wrote_nothing, "{shape}");
        }
    }

    /// The drain's wire form, decoded field by field, and the three short
    /// forms refused by name, so a cut-off reply is never read as a lane
    /// with nothing new: a reply with no receipts section, a header that is
    /// not one and an envelope that is not JSON.
    #[test]
    fn a_drain_decodes_whole_and_a_short_or_malformed_one_is_refused() {
        let text = "count=3 first=a-1\n{\"id\":\"a-2\",\"kind\":\"ask\",\"options\":[\"x\",\"y\"],\"text\":\"Go?\"}\n{\"id\":\"a-3\",\"kind\":\"notice\"}\nreceipts cursor=2 count=4 first=d-1\n1 d-1 1769700000\n3 d-3 \n";
        let mut lines = text.lines().peekable();
        let drained = Drained::parse("drain", &mut lines).unwrap();
        assert_eq!(drained.count, 3);
        assert_eq!(drained.first, "a-1");
        assert_eq!(drained.envelopes.len(), 2);
        assert_eq!(drained.envelopes[0].options, vec!["x", "y"]);
        assert_eq!(drained.envelopes[1].id(), "a-3");
        assert_eq!(
            drained.receipts,
            Receipts {
                cursor: Cursor::Read(2),
                count: 4,
                first: "d-1".into(),
                directives: vec![
                    Directive {
                        line: 1,
                        id: "d-1".into(),
                        at: Some(1_769_700_000)
                    },
                    Directive {
                        line: 3,
                        id: "d-3".into(),
                        at: None
                    }
                ],
            }
        );
        let missed = "count=0 first=\nreceipts cursor=missed count=0 first=\n";
        let drained = Drained::parse("drain", &mut missed.lines().peekable()).unwrap();
        assert_eq!(drained.receipts.cursor, Cursor::Missed);
        let short = [
            ("count=1 first=a-1\n{\"id\":\"a-1\"}\n", "short"),
            ("", "short"),
            ("first=a-1 count=1\n", "header"),
            (
                "count=1 first=a-1\nnot json\nreceipts cursor=0 count=0 first=\n",
                "envelope",
            ),
            (
                "count=1 first=a-1\nreceipts cursor=x count=0 first=\n",
                "receipts",
            ),
        ];
        for (text, cause) in short {
            match Drained::parse("drain", &mut text.lines().peekable()) {
                Err(Refusal::Reply { cause: got, .. }) => assert_eq!(got, cause, "{text:?}"),
                other => panic!("{text:?}: {other:?}"),
            }
        }
    }

    /// The session send's hand-back decodes into the record
    /// orch stamps, with the credit in both its forms.
    #[test]
    fn a_directive_send_receipt_decodes_with_either_credit_form() {
        let read = decode_directive_send(
            "lane-mail: directive-send item=CC-1 record={\"result\":\"sent\",\"text\":\"\",\"credit\":{\"remaining_dollars\":12.5,\"locked_reason\":null}}",
        )
        .unwrap();
        assert_eq!(read.result, SendResult::Sent);
        assert_eq!(
            read.credit,
            Credit::Read {
                remaining_dollars: serde_json::Number::from_f64(12.5),
                locked_reason: None
            }
        );
        let unread = decode_directive_send(
            "lane-mail: directive-send item=CC-1 record={\"result\":\"failed\",\"text\":\"Session not found\",\"credit\":\"unread\"}",
        )
        .unwrap();
        assert_eq!(unread.result, SendResult::Failed);
        assert_eq!(unread.text, "Session not found");
        assert_eq!(
            unread.credit,
            Credit::Unread(crate::ops::mail::Word::Unread)
        );
        assert_eq!(
            decode_directive_send("lane-mail: sent item=CC-1 channel=session session=s"),
            None
        );
    }
}
