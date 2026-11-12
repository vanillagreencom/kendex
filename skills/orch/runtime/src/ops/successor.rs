//! The controller an overseer launch opens: the overseer walk's choice made
//! into the pending a `start-controller` or `request-transfer` request
//! carries. A fleet's first controller walks with no source session, so
//! only an entry whose harness writes a full bypass is taken, and runs under
//! the settings' posture; a succession walks with the recorded controller's
//! posture as the source and keeps it on a same-harness successor. A
//! succession a mark sent walks as that mark decides (`walk_request`).
//! Nothing is written: the request that carries the answer records it. The
//! brief a controller opens on is [`brief`]'s, for every launch of one.

use agent_runtime::controller::Pending;
use std::path::Path;

use agent_runtime::harness::Harness;
use agent_runtime::launch::Permission;
use serde_json::{Value, json};

use crate::error::{Error, Result};
use crate::ops::accounts;
use agent_runtime::accounts::walk::{Preference, Scope, Source, WalkAnswer, WalkRequest};
use agent_runtime::settings::CONTROLLER_PREFERENCE_KEY;

use crate::settings::Settings;
use crate::watch::overseer::{AccountState, Caller, MarkKind, Record};

/// The handoff a controller is pointed at where its launch names no other.
pub const HANDOFF: &str = "tmp/handoffs/OVERSEER-HANDOFF.md";

/// The brief a controller opens on: the takeover workflow with the overseer
/// handoff at `handoff`, in the form `harness` opens on, Pi on its skill
/// command.
pub fn brief(harness: Harness, handoff: &str) -> String {
    const TAKEOVER: &str = ".agents/skills/orch/workflows/oversee-takeover.md";
    match harness {
        Harness::Pi => {
            format!("/skill:orch follow {TAKEOVER} with the overseer handoff at {handoff}")
        }
        Harness::Claude | Harness::Codex | Harness::Copilot => format!(
            "Read .agents/skills/orch/SKILL.md and follow {TAKEOVER} with the overseer handoff at {handoff}"
        ),
    }
}

/// The posture a successor launches under: the one it carries, else the
/// settings', so its record names the posture the next walk reads.
pub fn posture(pending: &mut Pending, settings: &Settings) -> Result<()> {
    if pending.permission.is_none() {
        pending.permission = Some(settings.engine.permission.get()?);
    }
    Ok(())
}

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused(key, fields).into()
}

/// The walk's source for a succession: a recorded bypass is a posture any
/// harness with a bypass word takes, so its row answers; a native posture
/// carries only its own words, and an unrecorded one none, so no entry of
/// another harness is launched under a posture nobody recorded. Every
/// overseer walk with a source session takes it, the watch's walled one
/// included.
pub fn source(caller: &Caller, harness: Harness) -> Source {
    Source {
        harness,
        flags: match caller.permission {
            Some(Permission::Bypass) => None,
            Some(Permission::Native) | None => Some(caller.extra_args.clone()),
        },
    }
}

/// The walk a succession the `mark` sent takes for `caller` on `harness`.
/// Where the caller's own account reaches an account mark (its headroom
/// trigger, else a wall its rate projects inside the setting), the walk is
/// that mark's whatever mark fired first, headroom, then rate, then context,
/// since that account is the one the successor must leave. A headroom or
/// rate mark leaves the caller's
/// account out of every pick. A context or memory mark keeps the caller's
/// own account, unpicked, where it has room; a context mark also keeps an
/// account nothing measures where no other account of its harness has room
/// (the walk's `keep_unmeasured`), and walks the caller's own entry alone
/// where the setting names no preference, since a context handoff replaces
/// the session and not its harness or model. Every succession walks the
/// caller's own entry last.
fn walk_request(
    settings: &Settings,
    path: &Path,
    host: &crate::ops::Host<'_>,
    caller: &Caller,
    harness: Harness,
    mark: MarkKind,
    now: u64,
) -> Result<WalkRequest> {
    let (state, reached) = match mark {
        MarkKind::Headroom | MarkKind::Rate => (None, None),
        MarkKind::Context | MarkKind::Memory => {
            let (state, reached) = caller.account_departure(harness, settings, path, host, now)?;
            (Some(state), reached)
        }
    };
    let mark = reached.unwrap_or(mark);
    let mut entry = caller.walk_entry(harness);
    entry.keep = state == Some(AccountState::HasRoom)
        && matches!(mark, MarkKind::Context | MarkKind::Memory);
    let (exclude, preference) = match mark {
        MarkKind::Headroom | MarkKind::Rate => (caller.account.iter().cloned().collect(), None),
        MarkKind::Context => (
            Vec::new(),
            (!settings.engine.controller_preference_set).then(String::new),
        ),
        MarkKind::Memory => (Vec::new(), None),
    };
    Ok(WalkRequest {
        scope: Scope::Overseer,
        preference,
        lane: None,
        exclude,
        max_pct: None,
        min_headroom_pct: None,
        source: Some(source(caller, harness)),
        caller: Some(entry),
        keep_unmeasured: mark == MarkKind::Context,
    })
}

/// The `successor` verb: the overseer walk for the fleet at `path`, for its
/// first controller in `cwd`, or for the successor of the recorded
/// controller whose pane `predecessor` names, walked as the `mark` that
/// sent it decides. The reply carries the walk's
/// own reply, the pending the choice opens and the brief it opens on with
/// the handoff at `handoff` (each `null` where the walk chose none) and,
/// for a succession, the compare-and-swap set naming that pane. Left out,
/// the handoff is the recorded controller's own, else the default, so a
/// succession keeps the launch's handoff.
#[allow(
    clippy::disallowed_methods,
    reason = "the verb's one read of the fleet state, a snapshot the walk reads; the kernel host for the judge's occupancy read, which acts on nothing"
)]
pub fn successor(
    settings: &Settings,
    path: &Path,
    predecessor: Option<&str>,
    mark: Option<MarkKind>,
    cwd: &Path,
    handoff: Option<&str>,
    now: u64,
) -> Result<Value> {
    // An empty preference is a setting with no entry to walk, not a walk
    // that found no room: no wait for headroom could open anything. A mark's
    // succession still walks the caller's own entry.
    if mark.is_none()
        && Preference::parse(&settings.engine.controller_preference, Scope::Overseer)
            .is_ok_and(|preference| preference.entries.is_empty())
    {
        return Err(refused(
            "preference-empty",
            &[("setting", CONTROLLER_PREFERENCE_KEY)],
        ));
    }
    let recorded = match predecessor {
        None => None,
        Some(pane) => {
            let record = crate::state::load(path)?
                .map(|snapshot| {
                    <crate::state::FleetState as crate::state::Record>::view(path, &snapshot.doc)
                })
                .transpose()?
                .as_ref()
                .and_then(Record::read)
                .ok_or_else(|| {
                    refused("record-missing", &[("path", &path.display().to_string())])
                })?;
            let caller = Caller::of(&record);
            let harness = caller
                .harness
                .ok_or_else(|| refused("harness-unnamed", &[("pane", pane)]))?;
            let mut expected = record.expected();
            expected.pane = json!(pane);
            Some((caller, harness, expected))
        }
    };
    let handoff = handoff
        .map(str::to_owned)
        .or_else(|| {
            recorded
                .as_ref()
                .and_then(|(caller, _, _)| caller.handoff.clone())
        })
        .unwrap_or_else(|| HANDOFF.to_owned());
    let host = crate::ops::Host::kernel();
    let request = match (recorded.as_ref(), mark) {
        (Some((caller, harness, _)), Some(mark)) => {
            walk_request(settings, path, &host, caller, *harness, mark, now)?
        }
        (recorded, _) => WalkRequest {
            scope: Scope::Overseer,
            preference: None,
            lane: None,
            exclude: Vec::new(),
            max_pct: None,
            min_headroom_pct: None,
            source: recorded.map(|(caller, harness, _)| source(caller, *harness)),
            caller: None,
            keep_unmeasured: false,
        },
    };
    let walked = accounts::walk(settings, path, &host, None, &request, now)?;
    let successor = match &walked.answer {
        WalkAnswer::Lane(chosen) => {
            let mut pending = match &recorded {
                None => {
                    let mut pending = Caller::default().successor_of(chosen);
                    pending.permission = Some(settings.engine.permission.get()?);
                    pending
                }
                Some((caller, _, _)) => {
                    let mut pending = caller.successor_of(chosen);
                    posture(&mut pending, settings)?;
                    pending
                }
            };
            pending.cwd.get_or_insert_with(|| cwd.display().to_string());
            pending.handoff = Some(handoff.clone());
            Some(pending)
        }
        WalkAnswer::None | WalkAnswer::Held { .. } => None,
    };
    let opens_on = successor
        .as_ref()
        .and_then(|pending| pending.harness.as_deref())
        .and_then(Harness::parse)
        .map(|harness| brief(harness, &handoff));
    Ok(json!({
        "walk": walked.reply(),
        "successor": successor,
        "brief": opens_on,
        "expected": recorded.map(|(_, _, expected)| expected),
    }))
}

/// The successor a model recovery opens for the recorded controller whose
/// pane `predecessor` names: the controller's own launch, its model the one
/// it was launched with, under its own handoff, with the record as the
/// compare-and-swap set and the record's launch as the recovery's binding,
/// which the transition holds the acquired model check to. No walk: the
/// recovery replaces the session, never its account or harness.
#[allow(
    clippy::disallowed_methods,
    reason = "the verb's one read of the fleet state, a snapshot the reply is composed from"
)]
pub fn recovery(settings: &Settings, path: &Path, predecessor: &str) -> Result<Value> {
    let snapshot = crate::state::load(path)?
        .ok_or_else(|| refused("record-missing", &[("path", &path.display().to_string())]))?;
    let record = <crate::state::FleetState as crate::state::Record>::view(path, &snapshot.doc)
        .ok()
        .as_ref()
        .and_then(Record::read)
        .ok_or_else(|| refused("record-missing", &[("path", &path.display().to_string())]))?;
    let mut successor = record
        .own_successor()
        .ok_or_else(|| refused("harness-unnamed", &[("pane", predecessor)]))?;
    successor.handoff.get_or_insert_with(|| HANDOFF.to_owned());
    posture(&mut successor, settings)?;
    let mut expected = record.expected();
    expected.pane = json!(predecessor);
    let launch = snapshot.doc.get("overseer").cloned().unwrap_or(Value::Null);
    let binding: serde_json::Map<String, Value> = crate::ops::controller::MODEL_LAUNCH_KEYS
        .iter()
        .map(|key| {
            (
                (*key).to_owned(),
                launch.get(*key).cloned().unwrap_or(Value::Null),
            )
        })
        .collect();
    Ok(json!({
        "successor": successor,
        "expected": expected,
        "recovery": binding,
    }))
}

/// The handoff State line naming the open lane asks; the snapshot writer
/// owns it, so a body's own spelling of it is replaced.
const ASKS_LINE: &str = "Open lane asks:";

/// One lane's open asks as its mailbox answered them, or the read that
/// failed with its cause: an unread mailbox is never a lane with no ask.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "read", rename_all = "kebab-case")]
pub enum LaneAsks {
    Read { lane: String, asks: Vec<OpenAsk> },
    Unread { lane: String, cause: String },
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct OpenAsk {
    pub id: String,
    pub text: String,
}

/// Every running lane's open asks, read from its own mailbox through the one
/// mailbox client (a hosted lane's through its record's host), never from a
/// controller's memory. A cloud session lane has no mailbox to read.
#[allow(
    clippy::disallowed_methods,
    reason = "the snapshot's one read of the fleet state, the running lanes whose mailboxes it lists"
)]
pub fn open_asks(settings: &Settings, path: &Path) -> Result<Vec<LaneAsks>> {
    let Some(snapshot) = crate::state::load(path)? else {
        return Err(refused(
            "record-missing",
            &[("path", &path.display().to_string())],
        ));
    };
    let lanes = super::lanes(path, &snapshot.doc)?;
    let mail = crate::mailbox::Mailbox::new(settings.lane_mail_cli.clone());
    let mut out = Vec::new();
    for lane in lanes
        .iter()
        .filter(|l| l.status == crate::state::LaneStatus::Running && !l.session_channel())
    {
        let Some(root) = lane.mail_root.as_deref().filter(|r| !r.is_empty()) else {
            out.push(LaneAsks::Unread {
                lane: lane.item.clone(),
                cause: "mail-root-missing".to_owned(),
            });
            continue;
        };
        let host = lane.host.as_deref().filter(|h| !h.is_empty());
        out.push(match mail.pending(&lane.item, Path::new(root), host) {
            Ok(envelopes) => LaneAsks::Read {
                lane: lane.item.clone(),
                asks: envelopes
                    .iter()
                    .filter(|e| e.kind() == "ask")
                    .map(|e| OpenAsk {
                        id: e.id.clone().unwrap_or_else(|| "unread".to_owned()),
                        text: e.text.clone().unwrap_or_default(),
                    })
                    .collect(),
            },
            Err(refusal) => LaneAsks::Unread {
                lane: lane.item.clone(),
                cause: refusal.to_string(),
            },
        });
    }
    Ok(out)
}

/// The State line the snapshot carries: each open ask by its id and lane,
/// `none` only where every running lane's mailbox answered with none, and
/// each mailbox that did not answer named with its cause.
fn asks_line(asks: &[LaneAsks]) -> String {
    let mut named = Vec::new();
    let mut unread = Vec::new();
    for lane in asks {
        match lane {
            LaneAsks::Read { lane, asks } => {
                named.extend(asks.iter().map(|a| format!("{} ({lane})", a.id)));
            }
            LaneAsks::Unread { lane, cause } => unread.push(format!("{lane} ({cause})")),
        }
    }
    let mut line = format!("{ASKS_LINE} ");
    match (named.is_empty(), unread.is_empty()) {
        (true, true) => line.push_str("none"),
        (false, _) => line.push_str(&named.join(", ")),
        (true, false) => {}
    }
    if !unread.is_empty() {
        if !named.is_empty() {
            line.push_str("; ");
        }
        line.push_str("unread for ");
        line.push_str(&unread.join(", "));
    }
    line
}

/// Which labeled record a Progress log line is, and the home it belongs
/// to: rulings and filing history in the fleet log, Verifying readings on
/// their tracker items. None for any other line.
fn progress_record(line: &str) -> Option<(&'static str, &'static str)> {
    let lead = line.trim_start_matches(['-', '*', ' ']);
    let word_end = |rest: &str| {
        rest.chars()
            .next()
            .is_none_or(|c| !c.is_ascii_alphanumeric() && c != '_')
    };
    if lead.starts_with("Ruling:") || lead.starts_with("Rulings:") {
        return Some(("ruling", "fleet-log"));
    }
    let filed_colon = line.match_indices("Filed:").any(|(at, _)| {
        line[..at]
            .chars()
            .next_back()
            .is_none_or(|c| !c.is_ascii_alphanumeric() && c != '_')
    });
    let filed_id = line.match_indices(" filed").any(|(at, word)| {
        let id = line[..at].rsplit(' ').next().unwrap_or("");
        let tracker = id.split_once('-').is_some_and(|(team, n)| {
            !team.is_empty()
                && team.chars().all(|c| c.is_ascii_uppercase())
                && !n.is_empty()
                && n.chars().all(|c| c.is_ascii_digit())
        });
        let pr = id
            .strip_prefix('#')
            .is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()));
        (tracker || pr) && word_end(&line[at + word.len()..])
    });
    if filed_colon || filed_id {
        return Some(("filing", "fleet-log"));
    }
    let boxed = line.match_indices("box ").any(|(at, word)| {
        let rest = &line[at + word.len()..];
        let digits = rest.chars().take_while(char::is_ascii_digit).count();
        digits > 0
            && ["failed", "passed"].iter().any(|v| {
                rest[digits..]
                    .strip_prefix(' ')
                    .and_then(|r| r.strip_prefix(v))
                    .is_some_and(word_end)
            })
    });
    if lead.starts_with("Verifying read:") || lead.starts_with("Verifying reads:") || boxed {
        return Some(("verifying", "tracker-item"));
    }
    None
}

/// The snapshot with the State line: any line of the text spelling it is
/// dropped, and the generated one leads the first `## State` section, or a
/// new one ahead of the text where it has none.
fn with_asks_line(text: &str, line: &str) -> String {
    let mut out = String::new();
    let mut placed = false;
    for row in text.lines() {
        if row.starts_with(ASKS_LINE) {
            continue;
        }
        out.push_str(row);
        out.push('\n');
        if !placed && row.trim_end() == "## State" {
            out.push_str(line);
            out.push('\n');
            placed = true;
        }
    }
    if placed {
        out
    } else {
        format!("## State\n{line}\n\n{out}")
    }
}

/// The `handoff` verb's write: the overseer handoff at `handoff` replaced by
/// the `Start here: <UTC> generation=<N>` header, the fleet record's
/// generation, over the prepared body at `body`, with the State line naming
/// every open lane ask the running lanes' mailboxes hold. `keep_prior` keeps
/// the installed snapshot's content, its old header dropped, ahead of the
/// body, as a recovery that writes no fresh State does. The body is the
/// caller's session scratch: a link, an empty or irregular file, the
/// installed handoff itself, a `Start here:` line, and a labeled ruling,
/// filing or Verifying record under `## Progress log` are refused, since each
/// belongs elsewhere. The write is a private staged file renamed over the
/// handoff, so a failure leaves the installed snapshot as it stood.
#[allow(
    clippy::disallowed_methods,
    reason = "the overseer handoff's one writer: its own exclusive staged file renamed over the handoff it owns"
)]
pub fn write_handoff(
    settings: &Settings,
    path: &Path,
    body: &Path,
    handoff: &Path,
    keep_prior: bool,
    env: &agent_runtime::journal::Env,
) -> Result<Value> {
    use std::io::Write;
    let shown = handoff.display().to_string();
    let invalid = |reason: &str| {
        refused(
            "handoff-body-invalid",
            &[("path", &body.display().to_string()), ("reason", reason)],
        )
    };
    let failed = |step: &str| refused("handoff-write-failed", &[("path", &shown), ("step", step)]);
    let generation = crate::state::load(path)?
        .and_then(|s| s.doc.get("overseer")?.get("generation")?.as_u64())
        .ok_or_else(|| {
            refused(
                "handoff-stale",
                &[("path", &shown), ("expected", "unknown"), ("found", "none")],
            )
        })?;
    let meta = std::fs::symlink_metadata(body).map_err(|_| invalid("not-nonempty-regular"))?;
    if !meta.is_file() || meta.len() == 0 {
        return Err(invalid("not-nonempty-regular"));
    }
    let body_parent = body
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::canonicalize(body_parent).map_err(|_| invalid("parent"))?;
    let parent = handoff
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(parent).map_err(|_| failed("mkdir"))?;
    let parent = std::fs::canonicalize(parent).map_err(|_| failed("parent"))?;
    let leaf = handoff.file_name().ok_or_else(|| failed("leaf"))?;
    let destination = parent.join(leaf);
    let standing = |destination: &Path| -> Result<bool> {
        match std::fs::symlink_metadata(destination) {
            Ok(m) if m.is_file() => Ok(true),
            Ok(_) => Err(failed("destination-type")),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(_) => Err(failed("destination-type")),
        }
    };
    let stood = standing(&destination)?;
    if stood && same_file(body, &destination) {
        return Err(invalid("installed-handoff"));
    }
    let payload = std::fs::read_to_string(body).map_err(|_| failed("body-read"))?;
    if payload.lines().any(|l| l.starts_with("Start here:")) {
        return Err(invalid("header"));
    }
    let mut in_log = false;
    for (n, line) in payload.lines().enumerate() {
        if line == "## Progress log" {
            in_log = true;
            continue;
        }
        if line.starts_with("## ") {
            in_log = false;
        }
        if in_log && let Some((kind, home)) = progress_record(line) {
            return Err(refused(
                "handoff-body-invalid",
                &[
                    ("path", &body.display().to_string()),
                    ("reason", &format!("progress-log-{kind}")),
                    ("line", &(n + 1).to_string()),
                    ("home", home),
                ],
            ));
        }
    }
    let mut text = String::new();
    if keep_prior && stood {
        let prior = std::fs::read_to_string(&destination).map_err(|_| failed("prior-read"))?;
        let mut rows = prior.lines();
        let first = rows.next().unwrap_or("");
        if !first.starts_with("Start here:") {
            text.push_str(first);
            text.push('\n');
        }
        for row in rows {
            text.push_str(row);
            text.push('\n');
        }
        text.push('\n');
    }
    text.push_str(&payload);
    let asks = open_asks(settings, path)?;
    let at = env.iso();
    let complete = format!(
        "Start here: {at} generation={generation}\n\n{}",
        with_asks_line(&text, &asks_line(&asks))
    );
    static STAGE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let stage = parent.join(format!(
        ".handoff.{}-{}",
        std::process::id(),
        STAGE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&stage)
        .map_err(|_| failed("mktemp"))?;
    let written = file
        .write_all(complete.as_bytes())
        .and_then(|()| file.sync_all())
        .map_err(|_| failed("body-write"))
        .and_then(|()| standing(&destination).map(|_| ()))
        .and_then(|()| {
            if same_file(body, &destination) {
                Err(invalid("installed-handoff"))
            } else {
                Ok(())
            }
        })
        .and_then(|()| std::fs::rename(&stage, &destination).map_err(|_| failed("rename")));
    if written.is_err() {
        let _ = std::fs::remove_file(&stage);
    }
    written?;
    Ok(json!({
        "path": destination.display().to_string(),
        "generation": generation,
        "written_at": at,
        "asks": asks,
    }))
}

fn same_file(a: &Path, b: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    match (std::fs::metadata(a), std::fs::metadata(b)) {
        (Ok(x), Ok(y)) => x.dev() == y.dev() && x.ino() == y.ino(),
        _ => false,
    }
}
