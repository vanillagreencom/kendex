//! The mail duty (step5-map § A7, § A8; decision 121 Q1, Q2, Q16): on its
//! own thread and due time, every lane mailbox read in one batched call,
//! then the overseer's own box, each envelope rendered to its legacy
//! `EVENT` line with its payload under it, and the duty's own memory of
//! each box moved only after the runner has the lines on disk.
//!
//! The overseer's box is announced and never acknowledged here (Q2,
//! correcting the legacy watch's `inbox --ack` on printing): the duty reads
//! it by logical line and records the line it announced through; only the
//! controller session's handler moves `to-lane.cursor`. So a note landing
//! between a handoff and its successor's start is in the log past the line
//! the handoff names and still unread in the box, and nothing here gates on
//! the controller's state: the log is the durable channel.
//!
//! A directive's receipt is the lane's own cursor (`drain --receipts`):
//! `directive-read` only once the lane's read moved it, `directive-unread`
//! while it stands past `ORCH_DIRECTIVE_UNREAD_SECS`, repeated every
//! `ORCH_OVERSEER_MARK_REPEAT` turns. A box whose count and first id are
//! unchanged emits no line and asks no change (decision 141 (4)).
//!
//! The wake's slot (decision 159; [`UNREAD_KIND`]): for each target read,
//! a row of that kind, identity the target, stands while the target's box
//! holds lines past the target's own read cursor, its value the newest
//! unread envelope's id, and is cleared once the box is read. The cursor is
//! read where `lane-mail` keeps it and never moved: a lane's through the
//! drain's receipts, the lead's from its `to-lane.cursor` file, since the
//! verbs that read it either move a stale one (`inbox --peek`) or read
//! another box's envelopes (`drain`).
//!
//! A target whose read refuses, or an owner ask whose default close fails,
//! stops that target alone (decisions 133, 142 (1)): every other box's
//! lines and rows are delivered, the refused target's rows stay where they
//! were so the next turn reads it again, and the turn is reported failed,
//! `watch-step-failed step=mail count=N` in the log with each refused
//! target and its cause on stderr, as the legacy's `lane_failure_report`
//! and exit 2 did. No box is ever read as empty.
//!
//! Between full turns the body asks to run each second and reads the
//! overseer box alone when its byte size moved, as the legacy wait did, so
//! an owner's note waits a second rather than the mail interval.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Display;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::error::{Error, Result};
use crate::mailbox::{BoxEvents, Cursor, Drain, Drained, Envelope, Mailbox, Refusal, Resolved};
use crate::ops::CLOUD_KIND;
use crate::ops::mail::MailCursor;
use crate::schedule::Duty;
use crate::settings::Settings;
use crate::state::{self, FleetState, Lane, LaneStatus, Record};
use crate::watch::wake::{OVERSEER_TARGET, UNREAD_KIND};
use crate::watch::{Baseline, Change, Event, Paths, Produced, Runner, Tick};

/// The baseline row kinds, the legacy `.mail` rows' words.
const LANE_MAIL: &str = "lane-mail";
const DIRECTIVE: &str = "directive";
/// The overseer box's identity among the `lane-mail` rows, and its item
/// for `lane-mail`.
const OVERSEER: &str = "overseer";

/// How often the overseer box's size is read between full turns.
const POLL: Duration = Duration::from_secs(1);

/// What the duty runs with.
#[derive(Debug, Clone)]
pub struct Config {
    /// The fleet state whose running lanes are read.
    pub fleet: PathBuf,
    /// The main checkout, which holds the overseer's box.
    pub common_root: PathBuf,
    /// The request file of the batched read, beside the watch's records.
    pub request: PathBuf,
    pub interval: Duration,
    pub mark_repeat: u32,
    pub unread: Duration,
}

impl Config {
    /// The configuration `watch run` builds from its settings and records.
    pub fn of(settings: &Settings, paths: &Paths) -> Config {
        Config {
            fleet: paths.state.clone(),
            common_root: settings.roots.common.clone(),
            request: paths.dir.join("oversee-watch.mail-request"),
            interval: settings.watch.mail_interval,
            mark_repeat: settings.watch.mark_repeat,
            unread: settings.watch.directive_unread,
        }
    }

    /// The overseer's mailbox directory, `<common root>/tmp/lane-mail/overseer`.
    fn overseer_dir(&self) -> PathBuf {
        self.common_root
            .join("tmp")
            .join("lane-mail")
            .join(OVERSEER)
    }

    /// The overseer's box, `to-lane.jsonl` under its mailbox directory.
    pub fn overseer_box(&self) -> PathBuf {
        self.overseer_dir().join("to-lane.jsonl")
    }

    /// The lead's read cursor on its box, `to-lane.cursor`, the file
    /// `lane-mail inbox --item overseer` keeps.
    pub fn overseer_cursor(&self) -> PathBuf {
        self.overseer_dir().join("to-lane.cursor")
    }
}

/// Register the mail duty on `runner` for the fleet state at `fleet`, with
/// the mailbox program the settings name.
pub fn register(runner: &mut Runner<'_>, fleet: &Path, settings: &Settings) -> Result<()> {
    let duty = MailDuty::new(
        Mailbox::new(settings.lane_mail_cli.clone()),
        Config::of(settings, &Paths::of(fleet)?),
    );
    register_duty(runner, duty);
    Ok(())
}

/// Register a built duty: the row's route, with its own mailbox program.
pub fn register_duty(runner: &mut Runner<'_>, mut duty: MailDuty) {
    runner.register(Duty::Mail, Box::new(move |tick: &Tick| duty.run(tick)));
}

/// The duty's body and its memory between runs.
pub struct MailDuty {
    mailbox: Mailbox,
    config: Config,
    /// The start of the last full turn; the next is due an interval after.
    last_full: Option<Instant>,
    /// The overseer box's byte size at the last read, `None` for no box.
    box_size: Option<Option<u64>>,
}

/// One target a turn could not read: the item key, [`OVERSEER_TARGET`] or
/// the batched verb where no lane is left to name, and the cause as the
/// mailbox client or the record reader stated it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refused {
    pub target: String,
    pub cause: String,
}

/// The lines, row changes and refusals one turn collects.
#[derive(Default)]
struct Turn {
    events: Vec<Event>,
    changes: Vec<Change>,
    refused: Vec<Refused>,
}

impl Turn {
    /// Set a row where its value differs from the baseline's.
    fn set(&mut self, baseline: &Baseline, kind: &str, identity: &str, value: String) {
        if baseline.get(kind, identity) != Some(value.as_str()) {
            self.changes.push(Change::Set {
                kind: kind.to_owned(),
                identity: identity.to_owned(),
                value,
            });
        }
    }

    /// Clear a row where the baseline holds one.
    fn clear(&mut self, baseline: &Baseline, kind: &str, identity: &str) {
        if baseline.get(kind, identity).is_some() {
            self.changes.push(Change::Clear {
                kind: kind.to_owned(),
                identity: identity.to_owned(),
            });
        }
    }

    fn refuse(&mut self, target: &str, cause: impl Display) {
        self.refused.push(Refused {
            target: target.to_owned(),
            cause: cause.to_string(),
        });
    }
}

/// The envelope's payload under its line: the text line by line, then its
/// options (`oversee-watch:3194-3199`).
fn payload(envelope: &Envelope, events: &mut Vec<Event>) {
    if let Some(text) = envelope.text.as_deref()
        && !text.is_empty()
    {
        for line in text.lines() {
            events.push(Event::Payload {
                line: line.to_owned(),
            });
        }
    }
    if !envelope.options.is_empty() {
        events.push(Event::Payload {
            line: format!("options: {}", envelope.options.join(", ")),
        });
    }
}

/// The class table of `check_mail` (`oversee-watch:3167-3190`): the line
/// one envelope renders to, by the box it came from and, for the overseer's
/// box, the class the shared mailbox rule gave it; `None` for a stray
/// answer, which is nobody's.
///
/// | box, class or kind | line |
/// |---|---|
/// | overseer, `resolution` | `owner-ask-resolved <re> by=<by> id=<id>` |
/// | overseer, `close` | `owner-ask-closed <re> by=<by>` |
/// | overseer, `owner-note` | `owner-note <id>` |
/// | overseer, `peer` | `peer-note <from without overseer:> <id> kind=<kind>[ re=<re>]` |
/// | overseer, `stray` | nothing |
/// | lane, kind `ask` | `lane-question <item> <id>` |
/// | lane, any other kind | `lane-notice <item> <id>` |
pub fn classify(item: &str, envelope: &Envelope) -> Result<Option<Event>> {
    let id = envelope.id().to_owned();
    if item == OVERSEER {
        let re = envelope.re.clone().unwrap_or_default();
        let by = envelope.by.clone().unwrap_or_default();
        return match envelope.mail_class.as_deref() {
            Some("resolution") => Ok(Some(Event::OwnerAskResolved { re, by, id })),
            Some("close") => Ok(Some(Event::OwnerAskClosed { re, by })),
            Some("owner-note") => Ok(Some(Event::OwnerNote { id })),
            Some("peer") => {
                let from = envelope.from.clone().unwrap_or_default();
                Ok(Some(Event::PeerNote {
                    repository: from
                        .strip_prefix("overseer:")
                        .map(str::to_owned)
                        .unwrap_or(from),
                    id,
                    kind: envelope.kind().to_owned(),
                    re: envelope.re.clone().filter(|r| !r.is_empty()),
                }))
            }
            Some("stray") => Ok(None),
            other => Err(invalid(item, format!("class={}", other.unwrap_or("")))),
        };
    }
    Ok(Some(if envelope.kind() == "ask" {
        Event::LaneQuestion {
            item: item.to_owned(),
            id,
        }
    } else {
        Event::LaneNotice {
            item: item.to_owned(),
            id,
        }
    }))
}

/// The legacy `mail-read-invalid` refusal: a reply the duty cannot read.
fn invalid(item: &str, value: String) -> Error {
    Error::Runtime(agent_runtime::Error::External {
        program: "lane-mail",
        operation: "read",
        cause: format!("mail-read-invalid item={item} value={value}"),
    })
}

/// The `directive` row: the cursor `directive-read` was last reported up
/// to, the last line reported `directive-unread` with the turns since
/// unread lines were last reported, and the id `to-lane.jsonl` opened with
/// (`oversee-watch:3099-3107`).
struct DirectiveRow {
    read_at: u64,
    unread_at: u64,
    passes: u32,
    first: String,
}

impl DirectiveRow {
    /// `None` for no row or one whose counts do not read, which the legacy
    /// took as a lane having read up to its cursor.
    fn parse(row: Option<&str>) -> Option<DirectiveRow> {
        let row = row?;
        let mut fields = row.splitn(3, ' ');
        let read_at = fields.next()?.parse().ok()?;
        let unread = fields.next()?;
        let first = fields.next().unwrap_or("").to_owned();
        let (unread_at, passes) = match unread.split_once(':') {
            Some((at, passes)) => (at.parse().ok()?, passes.parse().ok()?),
            None => (unread.parse().ok()?, 0),
        };
        Some(DirectiveRow {
            read_at,
            unread_at,
            passes,
            first,
        })
    }

    fn render(&self) -> String {
        format!(
            "{} {}:{} {}",
            self.read_at, self.unread_at, self.passes, self.first
        )
    }
}

/// Whether a box whose row holds `prior` and `seen` reads as a replacement
/// when it opens with `first` and holds `count` lines
/// (`oversee-watch:3070-3081`): a mailbox opening with another envelope than
/// the one recorded, or, with no first id recorded, one holding fewer lines
/// than were drained. A read finding no line is no replacement.
fn replaced(prior: u64, seen: &str, count: u64, first: &str) -> bool {
    if prior == 0 || count == 0 {
        return false;
    }
    if seen.is_empty() {
        count < prior
    } else {
        first != seen
    }
}

/// The wake slot's value for a box of `count` lines whose newest line past
/// the target's cursor the read carries as `newest` (its line and id): the
/// id where that is the box's last line and carries one, else the last
/// line's number as its index. A lane's drain carries its directives alone,
/// so an answer or a peer ask as the newest line is keyed by its number.
fn unread_value(newest: Option<(u64, &str)>, count: u64) -> String {
    match newest {
        Some((line, id)) if line == count && !id.is_empty() => id.to_owned(),
        Some(_) | None => count.to_string(),
    }
}

/// Which lanes of the fleet have a mailbox the duty reads: a running lane
/// whose kind's channel is a mailbox (`check_mail`'s `MAILLESS` filter),
/// with its recorded root.
fn readable(lane: &Lane) -> Result<Option<(bool, Drain)>> {
    if lane.status != LaneStatus::Running {
        return Ok(None);
    }
    if lane.kind.as_deref() == Some(CLOUD_KIND) || lane.host.as_deref() == Some(CLOUD_KIND) {
        return Ok(None);
    }
    let Some(root) = lane.mail_root.as_deref() else {
        return Err(invalid(&lane.item, "mail-root-unrecorded".into()));
    };
    let hosted = lane.host.as_deref().is_some_and(|h| h != "local");
    Ok(Some((
        hosted,
        Drain {
            item: lane.item.clone(),
            after: 0,
            root: PathBuf::from(root),
        },
    )))
}

/// The fleet record's running lanes, read once per full turn.
#[allow(
    clippy::disallowed_methods,
    reason = "the mail duty's one read of the fleet record it serves: which lanes have a mailbox to read, judged on a snapshot and acted on nowhere"
)]
fn fleet(path: &Path) -> Result<FleetState> {
    let snapshot = state::load(path)?.ok_or_else(|| Error::RecordMissing {
        path: path.to_path_buf(),
    })?;
    FleetState::view(path, &snapshot.doc)
}

/// The overseer box's byte size: `None` for no box yet, as the legacy's
/// `none`; a box that is there and cannot be read is refused, never read
/// as absent.
fn box_size(path: &Path) -> Result<Option<u64>> {
    match std::fs::metadata(path) {
        Ok(meta) => Ok(Some(meta.len())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(Error::Runtime(agent_runtime::Error::io("size", path, e))),
    }
}

/// The count a `to-lane.cursor` file holds, read as `lane-mail`'s own
/// `lm_cursor_read` reads it and never written: its first line, an absent
/// file or an empty line 0, any other text `cursor-invalid`; a symlink is
/// refused before any read, as `lane-mail` refuses one (`mailbox-unsafe`); a
/// file that is there and cannot be read is refused, never read as 0.
fn cursor_count(path: &Path) -> std::result::Result<u64, String> {
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => {
            return Err(format!("cursor-symlink={}", path.display()));
        }
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(e) => return Err(format!("file-unreadable={} {e}", path.display())),
    }
    match std::fs::read_to_string(path) {
        Ok(text) => {
            let first = text.lines().next().unwrap_or("");
            if first.is_empty() {
                return Ok(0);
            }
            if !first.bytes().all(|b| b.is_ascii_digit()) {
                return Err(format!("cursor-invalid={}", path.display()));
            }
            first
                .parse()
                .map_err(|_| format!("cursor-invalid={}", path.display()))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(0),
        Err(e) => Err(format!("file-unreadable={} {e}", path.display())),
    }
}

impl MailDuty {
    pub fn new(mailbox: Mailbox, config: Config) -> MailDuty {
        MailDuty {
            mailbox,
            config,
            last_full: None,
            box_size: None,
        }
    }

    /// The body: one turn delivered whole, and, where a target was refused,
    /// the refused targets with their causes as the run's partial failure,
    /// which the runner counts and says after the delivered lines under its
    /// one failure rule (decision 156 (1)); a turn with no refusal ends the
    /// count.
    pub fn run(&mut self, tick: &Tick) -> Result<Produced> {
        let full = self.full_due(tick);
        let (mut produced, refused) = self.turn(tick)?;
        // A poll between full turns reads the overseer box alone: it judges
        // nothing of the lanes a standing failure is about.
        produced.unjudged = !full && refused.is_empty();
        if !refused.is_empty() {
            let causes: Vec<String> = refused
                .iter()
                .map(|r| format!("  item={} {}", r.target, r.cause))
                .collect();
            produced.failed = Some(causes.join("\n"));
        }
        Ok(produced)
    }

    /// Whether this run is a full turn: the first, or an interval past the
    /// last.
    fn full_due(&self, tick: &Tick) -> bool {
        match self.last_full {
            None => true,
            Some(last) => self.config.interval.is_zero() || tick.now >= last + self.config.interval,
        }
    }

    /// One turn: every box on a full turn, else the overseer box alone
    /// where its size moved; what it delivers, and each target it could
    /// not read. The fleet record alone fails the turn whole.
    pub fn turn(&mut self, tick: &Tick) -> Result<(Produced, Vec<Refused>)> {
        let full = self.full_due(tick);
        let mut turn = Turn::default();
        if full {
            self.lanes_turn(tick, &mut turn)?;
        }
        match box_size(&self.config.overseer_box()) {
            Err(e) => turn.refuse(OVERSEER_TARGET, e),
            Ok(size) => {
                if full || self.box_size != Some(size) {
                    if full {
                        self.resolve_due_asks(&mut turn);
                    }
                    self.overseer_turn(tick.baseline, &mut turn);
                    // Taken before the read, so a note landing during it
                    // moves the size again and the next poll reads it; a
                    // refused read waits for the next full turn.
                    self.box_size = Some(size);
                }
            }
        }
        if full {
            self.last_full = Some(tick.now);
        }
        Ok((
            Produced {
                events: turn.events,
                changes: turn.changes,
                next_due: (!self.config.interval.is_zero()).then_some(tick.now + POLL),
                failed: None,
                unjudged: false,
            },
            turn.refused,
        ))
    }

    /// The local lanes in as few batched reads as the refusals allow: the
    /// program stops its reply at the first lane it refuses, which is named
    /// here, and the lanes after it are asked again without it, so one
    /// unreadable mailbox holds no other lane's mail (decision 133). A
    /// program that did not start or answer refuses every lane asked.
    fn drain_local(&self, lanes: &[Drain], turn: &mut Turn) -> Vec<(Drain, Drained)> {
        let mut out = Vec::new();
        let mut remaining = lanes;
        while !remaining.is_empty() {
            let batch = self.mailbox.drain_many(&self.config.request, remaining);
            let answered = batch.read.len();
            out.extend(remaining.iter().cloned().zip(batch.read));
            let Some(refusal) = batch.refused else {
                break;
            };
            match refusal {
                Refusal::Call { .. } => {
                    for lane in &remaining[answered..] {
                        turn.refuse(&lane.item, &refusal);
                    }
                    break;
                }
                Refusal::Exit { .. } | Refusal::Reply { .. } => match remaining.get(answered) {
                    Some(lane) => {
                        turn.refuse(&lane.item, &refusal);
                        remaining = &remaining[answered + 1..];
                    }
                    None => {
                        turn.refuse(refusal.verb(), &refusal);
                        break;
                    }
                },
            }
        }
        out
    }

    /// Every lane box: the local lanes batched, each hosted lane on its
    /// own, a replaced box read whole once; a lane whose read refuses is
    /// named and left for the next turn.
    fn lanes_turn(&self, tick: &Tick, turn: &mut Turn) -> Result<()> {
        let fleet = fleet(&self.config.fleet)?;
        let mut local = Vec::new();
        let mut hosted = Vec::new();
        for lane in &fleet.lanes {
            match readable(lane) {
                Ok(None) => {}
                Ok(Some((is_hosted, mut drain))) => {
                    let cursor = MailCursor::parse(tick.baseline.get(LANE_MAIL, &drain.item));
                    drain.after = cursor.announced;
                    if is_hosted {
                        hosted.push(drain);
                    } else {
                        local.push(drain);
                    }
                }
                Err(e) => turn.refuse(&lane.item, e),
            }
        }
        let mut read: Vec<(Drain, Drained, bool)> = self
            .drain_local(&local, turn)
            .into_iter()
            .map(|(lane, drained)| (lane, drained, false))
            .collect();
        for lane in &hosted {
            match self.mailbox.drain(lane, true) {
                Ok(drained) => read.push((lane.clone(), drained, true)),
                Err(refusal) => turn.refuse(&lane.item, refusal),
            }
        }
        // A replacement is read whole, once: a second mismatch would not end.
        let mut again_local = Vec::new();
        let mut again_hosted = Vec::new();
        for (lane, drained, is_hosted) in &read {
            let cursor = MailCursor::parse(tick.baseline.get(LANE_MAIL, &lane.item));
            if replaced(
                cursor.announced,
                &cursor.first,
                drained.count,
                &drained.first,
            ) {
                let whole = Drain {
                    after: 0,
                    ..lane.clone()
                };
                if *is_hosted {
                    again_hosted.push(whole);
                } else {
                    again_local.push(whole);
                }
            }
        }
        let replaced_items: BTreeSet<&str> = again_local
            .iter()
            .chain(&again_hosted)
            .map(|d| d.item.as_str())
            .collect();
        let mut reread: BTreeMap<String, Drained> = self
            .drain_local(&again_local, turn)
            .into_iter()
            .map(|(lane, drained)| (lane.item, drained))
            .collect();
        for lane in &again_hosted {
            match self.mailbox.drain(lane, true) {
                Ok(drained) => {
                    reread.insert(lane.item.clone(), drained);
                }
                Err(refusal) => turn.refuse(&lane.item, refusal),
            }
        }
        for (lane, drained, _) in &read {
            // The row read before this turn's read, and `prior` 0 for a
            // replaced box read from its start.
            let cursor = MailCursor::parse(tick.baseline.get(LANE_MAIL, &lane.item));
            let was_replaced = replaced_items.contains(lane.item.as_str());
            let (prior, drained) = if was_replaced {
                // Refused on the re-read: named above, nothing delivered.
                let Some(whole) = reread.get(&lane.item) else {
                    continue;
                };
                (0, whole)
            } else {
                (cursor.announced, drained)
            };
            self.lane_turn(tick, turn, &lane.item, prior, was_replaced, drained);
        }
        Ok(())
    }

    /// One lane's drain rendered (`oversee-watch:3125-3257`).
    fn lane_turn(
        &self,
        tick: &Tick,
        turn: &mut Turn,
        item: &str,
        prior: u64,
        was_replaced: bool,
        drained: &Drained,
    ) {
        let receipts = &drained.receipts;
        let stored = DirectiveRow::parse(tick.baseline.get(DIRECTIVE, item));
        // `hold`: the whole item on a read that missed, since the drain
        // dropped answered asks by a `to-lane.jsonl` it did not read; the
        // directive lines alone while the lane's cursor reads behind the
        // last `directive-read` reported.
        let lane_read = match receipts.cursor {
            Cursor::Missed => return,
            Cursor::Read(n) => n,
        };
        // The wake's slot: the lane's box past its own cursor.
        if receipts.count > lane_read {
            let newest = receipts
                .directives
                .iter()
                .rev()
                .find(|d| d.line > lane_read)
                .map(|d| (d.line, d.id.as_str()));
            turn.set(
                tick.baseline,
                UNREAD_KIND,
                item,
                unread_value(newest, receipts.count),
            );
        } else {
            turn.clear(tick.baseline, UNREAD_KIND, item);
        }
        let mut row = match stored {
            None => DirectiveRow {
                read_at: lane_read,
                unread_at: 0,
                passes: 0,
                first: String::new(),
            },
            Some(stored) => stored,
        };
        let mut hold_directives = false;
        if !receipts.first.is_empty() && !row.first.is_empty() && receipts.first != row.first {
            row.read_at = 0;
            row.unread_at = 0;
            row.passes = 0;
        } else if lane_read < row.read_at {
            hold_directives = true;
        }
        for envelope in &drained.envelopes {
            // A lane writes asks and notices; any other kind is a line to
            // show rather than a line to drop silently.
            if let Ok(Some(event)) = classify(item, envelope) {
                turn.events.push(event);
                payload(envelope, &mut turn.events);
            }
        }
        // A read shorter than what was drained moves no position: lowering
        // it would report the lines between again once the file reads whole.
        if was_replaced || drained.count >= prior {
            turn.set(
                tick.baseline,
                LANE_MAIL,
                item,
                MailCursor {
                    announced: drained.count,
                    first: drained.first.clone(),
                }
                .render(),
            );
        }
        if hold_directives {
            return;
        }
        // A directive reported unread and still unread is reported again
        // every MARK_REPEAT full turns; one mailbox's standing lines share
        // the count, which any unread line it reports starts over.
        row.passes += 1;
        let repeat = row.passes >= self.config.mark_repeat;
        let mut standing = false;
        let mut reported = false;
        let unread = self.config.unread.as_secs();
        for directive in &receipts.directives {
            if directive.line <= lane_read {
                if directive.line > row.read_at {
                    turn.events.push(Event::DirectiveRead {
                        item: item.to_owned(),
                        id: directive.id.clone(),
                    });
                }
            } else if let Some(age) = directive
                .at
                .and_then(|at| tick.wall.checked_sub(at))
                .filter(|age| *age >= unread && (directive.line > row.unread_at || repeat))
            {
                turn.events.push(Event::DirectiveUnread {
                    item: item.to_owned(),
                    id: directive.id.clone(),
                    age,
                });
                if directive.line > row.unread_at {
                    row.unread_at = directive.line;
                }
                reported = true;
            } else if directive.line <= row.unread_at {
                standing = true;
            }
        }
        if !standing || reported {
            row.passes = 0;
        }
        row.read_at = lane_read;
        if !receipts.first.is_empty() {
            row.first = receipts.first.clone();
        }
        turn.set(tick.baseline, DIRECTIVE, item, row.render());
    }

    /// Close the owner asks whose deadline has passed with their
    /// recommendation (`resolve_due_owner_asks`); another close winning the
    /// lock is no failure, any other refusal names the ask and the box is
    /// still read. The next read reports each close.
    fn resolve_due_asks(&self, turn: &mut Turn) {
        let asks = match self.mailbox.due_owner_asks(&self.config.common_root) {
            Ok(asks) => asks,
            Err(refusal) => return turn.refuse(OVERSEER_TARGET, refusal),
        };
        for ask in asks {
            let id = ask.id();
            if id.is_empty() {
                continue;
            }
            match self.mailbox.resolve_default(&self.config.common_root, id) {
                Ok(Resolved::Closed { .. } | Resolved::Already { .. }) => {}
                Err(refusal) => turn.refuse(OVERSEER_TARGET, format!("ask={id} {refusal}")),
            }
        }
    }

    /// The overseer's box past the line announced, a replaced box from its
    /// start, each envelope by the class table; the row moves to the count
    /// read (Q2: announced, never acknowledged), and the wake's slot
    /// follows the lead's own cursor. One read serves both: it starts at
    /// the lower of the two cursors.
    fn overseer_turn(&self, baseline: &Baseline, turn: &mut Turn) {
        let root = &self.config.common_root;
        let read = match cursor_count(&self.config.overseer_cursor()) {
            Ok(n) => n,
            Err(cause) => return turn.refuse(OVERSEER_TARGET, cause),
        };
        let cursor = MailCursor::parse(baseline.get(LANE_MAIL, OVERSEER));
        let mut announced = cursor.announced;
        let after = announced.min(read);
        let mut events: BoxEvents = match self.mailbox.box_events(root, after) {
            Ok(events) => events,
            Err(refusal) => return turn.refuse(OVERSEER_TARGET, refusal),
        };
        let mut was_replaced = false;
        if replaced(announced, &cursor.first, events.count, &events.first) {
            was_replaced = true;
            announced = 0;
            if after != 0 {
                events = match self.mailbox.box_events(root, 0) {
                    Ok(events) => events,
                    Err(refusal) => return turn.refuse(OVERSEER_TARGET, refusal),
                };
            }
        }
        let past = |line: Option<u64>, n: u64| line.is_some_and(|l| l > n);
        let mut lines = Vec::new();
        for envelope in events.envelopes.iter().filter(|e| past(e.line, announced)) {
            match classify(OVERSEER, envelope) {
                Ok(Some(event)) => {
                    lines.push(event);
                    payload(envelope, &mut lines);
                }
                Ok(None) => {}
                Err(e) => return turn.refuse(OVERSEER_TARGET, e),
            }
        }
        turn.events.extend(lines);
        if was_replaced || events.count >= announced {
            turn.set(
                baseline,
                LANE_MAIL,
                OVERSEER,
                MailCursor {
                    announced: events.count,
                    first: events.first.clone(),
                }
                .render(),
            );
        }
        if events.count > read {
            let newest = events
                .envelopes
                .iter()
                .rev()
                .find(|e| past(e.line, read))
                .and_then(|e| e.line.map(|line| (line, e.id())));
            turn.set(
                baseline,
                UNREAD_KIND,
                OVERSEER_TARGET,
                unread_value(newest, events.count),
            );
        } else {
            turn.clear(baseline, UNREAD_KIND, OVERSEER_TARGET);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The class table on real envelopes (`oversee_watch_mail.sh`'s rows):
    /// each class and kind to its line, a stray answer to none, a class the
    /// rule does not define refused. Defect: an envelope rendered under
    /// another kind's line, or a stray read back as a note.
    #[test]
    fn the_class_table_renders_each_legacy_line() {
        let env = |json: &str| -> Envelope { serde_json::from_str(json).unwrap() };
        let rows = [
            (
                "overseer",
                r#"{"id":"m-9","kind":"answer","re":"a-7","by":"text","mail_class":"resolution"}"#,
                Some("EVENT owner-ask-resolved a-7 by=text id=m-9"),
            ),
            (
                "overseer",
                r#"{"id":"m-10","kind":"resolution","re":"a-7","by":"explicit","mail_class":"close"}"#,
                Some("EVENT owner-ask-closed a-7 by=explicit"),
            ),
            (
                "overseer",
                r#"{"id":"m-9","kind":"directive","from":"owner","mail_class":"owner-note"}"#,
                Some("EVENT owner-note m-9"),
            ),
            (
                "overseer",
                r#"{"id":"m-9","kind":"directive","from":"overseer:other","mail_class":"peer"}"#,
                Some("EVENT peer-note other m-9 kind=directive"),
            ),
            (
                "overseer",
                r#"{"id":"m-9","kind":"answer","from":"overseer:other","re":"m-2","mail_class":"peer"}"#,
                Some("EVENT peer-note other m-9 kind=answer re=m-2"),
            ),
            (
                "overseer",
                r#"{"id":"m-9","kind":"answer","mail_class":"stray"}"#,
                None,
            ),
            (
                "KEN-1",
                r#"{"id":"m-9","kind":"ask","text":"Cut?","options":["cut","keep"]}"#,
                Some("EVENT lane-question KEN-1 m-9"),
            ),
            (
                "KEN-1",
                r#"{"id":"m-9","kind":"notice"}"#,
                Some("EVENT lane-notice KEN-1 m-9"),
            ),
            (
                "KEN-1",
                r#"{"id":"m-9","kind":"directive"}"#,
                Some("EVENT lane-notice KEN-1 m-9"),
            ),
            (
                "KEN-1",
                r#"{"kind":"notice"}"#,
                Some("EVENT lane-notice KEN-1 "),
            ),
        ];
        for (item, json, line) in rows {
            let got = classify(item, &env(json)).unwrap().map(|e| e.render());
            assert_eq!(got.as_deref(), line, "{item} {json}");
        }
        let unknown = env(r#"{"id":"m-9","kind":"answer","mail_class":"other"}"#);
        assert!(classify("overseer", &unknown).is_err());
        let absent = env(r#"{"id":"m-9","kind":"answer"}"#);
        assert!(classify("overseer", &absent).is_err());
        // The payload: text line by line, an empty line kept, options after.
        let mut events = Vec::new();
        payload(
            &env(
                r#"{"id":"m-9","kind":"ask","text":"EVENT merged 9\n\nlast","options":["cut","keep"]}"#,
            ),
            &mut events,
        );
        assert_eq!(
            events.iter().map(Event::render).collect::<Vec<_>>(),
            vec!["  EVENT merged 9", "  ", "  last", "  options: cut, keep"]
        );
        let mut events = Vec::new();
        payload(
            &env(r#"{"id":"m-9","kind":"notice","text":""}"#),
            &mut events,
        );
        assert!(events.is_empty());
    }

    /// The rows' wire forms: a replacement is judged as the legacy judged
    /// it, a directive row short of its counts reads as none, and the wake
    /// slot's value is the newest line's id or its number.
    #[test]
    fn a_replacement_and_a_directive_row_read_as_the_legacy_read_them() {
        assert!(!replaced(0, "", 5, "x"), "nothing drained yet");
        assert!(!replaced(3, "a", 0, ""), "a read finding no line");
        assert!(replaced(3, "a", 3, "b"), "another first id");
        assert!(!replaced(3, "a", 1, "a"), "the same first id, shorter");
        assert!(replaced(3, "", 2, "b"), "no first recorded, fewer lines");
        assert!(!replaced(3, "", 3, "b"), "no first recorded, as many");
        let row = DirectiveRow::parse(Some("4 2:3 d-1")).unwrap();
        assert_eq!((row.read_at, row.unread_at, row.passes), (4, 2, 3));
        assert_eq!(row.first, "d-1");
        let legacy = DirectiveRow::parse(Some("4 2 d-1")).unwrap();
        assert_eq!((legacy.read_at, legacy.unread_at, legacy.passes), (4, 2, 0));
        assert!(DirectiveRow::parse(Some("x 2:3 d-1")).is_none());
        assert!(DirectiveRow::parse(None).is_none());
        assert_eq!(MailCursor::parse(Some("7 a-1")).announced, 7);
        assert_eq!(MailCursor::parse(Some("7")).announced, 7);
        assert_eq!(MailCursor::parse(Some("seven a-1")).announced, 0);
        assert_eq!(MailCursor::parse(None).render(), "0 ");
        assert_eq!(unread_value(Some((3, "d-3")), 3), "d-3");
        assert_eq!(
            unread_value(Some((2, "d-2")), 3),
            "3",
            "a later line the read has no id for"
        );
        assert_eq!(
            unread_value(Some((3, "")), 3),
            "3",
            "an id outside the alphabet"
        );
        assert_eq!(unread_value(None, 3), "3");
    }
}
