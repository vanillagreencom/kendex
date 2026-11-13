//! What an overseer adds to the hand-over's choice (agent-runtime's
//! `controller::successor`): the fleet's ground it walks on, the default
//! handoff and the takeover brief a controller opens on ([`brief`]'s, for
//! every launch of one), and the snapshot writer's open-lane-asks line.

use std::path::Path;

use agent_runtime::controller::successor::{self as choice, Choosing, Ground};
use agent_runtime::controller::views::MarkKind;
use agent_runtime::harness::Harness;
use serde_json::{Value, json};

use crate::error::{Error, Result};
use crate::ops::accounts;
use agent_runtime::accounts::PickRequest;
use agent_runtime::accounts::walk::WalkRequest;

use crate::settings::Settings;

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

/// What an overseer adds to a controller start or transfer that names no
/// handoff or brief: the default handoff, and the takeover brief naming it,
/// a file in the fleet state's `intents/` named by its own checksum, so the
/// same brief is one file however often it is asked. The request names the
/// file at once; the caller writes it ([`HeldBrief::write`]) only once the
/// request's intent stands, so a refusal writes nothing. The hand-over holds
/// no default of its own and refuses `brief-missing`; these are the
/// overseer's. A harness outside the four is refused by its name first,
/// since no brief is spelled for it.
pub fn overseer_defaults(
    request: &mut crate::ops::Request,
    path: &Path,
) -> Result<Option<HeldBrief>> {
    let (pending, brief_file) = match request {
        crate::ops::Request::RequestTransfer(r) => (&mut r.successor, &mut r.brief_file),
        crate::ops::Request::StartController(r) => (&mut r.controller, &mut r.brief_file),
        _ => return Ok(None),
    };
    let handoff = pending
        .handoff
        .get_or_insert_with(|| HANDOFF.to_owned())
        .clone();
    if brief_file.is_some() {
        return Ok(None);
    }
    let Some(word) = pending.harness.as_deref() else {
        return Ok(None);
    };
    let text = format!("{}\n", brief(Harness::named(word)?, &handoff));
    let file = path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("intents")
        .join(format!(
            "overseer-{}.brief",
            agent_runtime::record::cksum(text.as_bytes())
        ));
    *brief_file = Some(file.clone());
    Ok(Some(HeldBrief { file, text }))
}

/// The takeover brief [`overseer_defaults`] named, to write once the
/// request's intent stands.
pub struct HeldBrief {
    file: std::path::PathBuf,
    text: String,
}

impl HeldBrief {
    /// Write the brief as a private staged file renamed over its name.
    #[allow(
        clippy::disallowed_methods,
        reason = "the overseer's takeover brief's one writer: its own staged file renamed over the brief its checksum names"
    )]
    pub fn write(&self) -> Result<()> {
        let held = |e: std::io::Error| agent_runtime::Error::io("write-brief", &self.file, e);
        let dir = self.file.parent().unwrap_or_else(|| Path::new("."));
        std::fs::create_dir_all(dir).map_err(held)?;
        let staged = dir.join(format!(".overseer-brief.{}", std::process::id()));
        std::fs::write(&staged, &self.text)
            .and_then(|()| std::fs::rename(&staged, &self.file))
            .map_err(held)?;
        Ok(())
    }
}

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused(key, fields).into()
}

/// The hand-over's choice read with orch's settings: the account judge's,
/// the launch's posture, the hand-over's preference and the overseer's wall
/// mark.
fn choosing(settings: &Settings) -> Choosing<'_> {
    Choosing {
        accounts: accounts::env(settings),
        launch: &settings.launch,
        controller: &settings.controller,
        wall_minutes: &settings.marks.wall_minutes,
    }
}

/// The fleet at `path` read whole, each member through its type, as orch's
/// verbs read their own record before the choice reads the controller's
/// member alone: a record whose other members do not read is never walked
/// on. `None` where no record stands; the view's refusal is its own.
#[allow(
    clippy::disallowed_methods,
    reason = "the successor's one read of its own fleet, before the choice reads its member"
)]
fn read_whole(path: &Path) -> Result<Option<Result<crate::state::FleetState>>> {
    Ok(crate::state::load(path)?.map(|snapshot| snapshot.view(path)))
}

/// The overseer's additions to a choice's reply: the default handoff where
/// the pending names none, and the brief it opens on (`null` where the walk
/// chose none).
fn with_overseer_brief(mut reply: Value) -> Value {
    let pending = reply.get_mut("successor").filter(|s| s.is_object());
    let opens_on = pending.map(|pending| {
        if pending.get("handoff").is_none_or(Value::is_null) {
            pending["handoff"] = json!(HANDOFF);
        }
        let handoff = pending["handoff"].as_str().unwrap_or(HANDOFF).to_owned();
        pending
            .get("harness")
            .and_then(Value::as_str)
            .and_then(Harness::parse)
            .map(|harness| brief(harness, &handoff))
    });
    reply["brief"] = json!(opens_on.flatten());
    reply
}

/// The `successor` verb: the hand-over's choice for the fleet at `path` on
/// the fleet's ground (each entry's host through the provider, every pick
/// with the fleet's seats and lanes' live charges), with the overseer's
/// default handoff and its takeover brief.
#[allow(
    clippy::disallowed_methods,
    reason = "the kernel host for the judge's occupancy read, which acts on nothing"
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
    if predecessor.is_some() {
        read_whole(path)?.transpose()?;
    }
    let host = crate::ops::Host::kernel();
    let mut walk = |request: &WalkRequest| {
        accounts::walk(settings, path, &host, None, request, now)
            .map_err(agent_runtime::Error::from)
    };
    let mut pick = |request: &PickRequest, judge_host: Option<&str>| {
        accounts::pick_fleet(settings, path, &host, judge_host, None, request, now)
    };
    let reply = choice::successor(
        &choosing(settings),
        path,
        predecessor,
        mark,
        cwd,
        handoff,
        Ground {
            walk: &mut walk,
            pick: &mut pick,
        },
        now,
    )?;
    Ok(with_overseer_brief(reply))
}

/// The successor a model recovery opens for the recorded controller whose
/// pane `predecessor` names, the hand-over's own launch replayed, under the
/// overseer's default handoff where the record names none. A record orch
/// cannot read whole refuses `record-missing` here; no record at all is the
/// hand-over's own refusal.
pub fn recovery(settings: &Settings, path: &Path, predecessor: &str) -> Result<Value> {
    if let Some(Err(_)) = read_whole(path)? {
        return Err(refused(
            "record-missing",
            &[("path", &path.display().to_string())],
        ));
    }
    let mut reply = choice::recovery(&settings.launch, path, predecessor)?;
    if let Some(pending) = reply.get_mut("successor").filter(|s| s.is_object())
        && pending.get("handoff").is_none_or(Value::is_null)
    {
        pending["handoff"] = json!(HANDOFF);
    }
    Ok(reply)
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

/// The `handoff` verb's write: the hand-over's snapshot writer
/// (agent-runtime's `controller::handoff::write`) with the overseer's State
/// line naming every open lane ask the running lanes' mailboxes hold, and
/// its refusal of a labeled ruling, filing or Verifying record under
/// `## Progress log`, since each belongs elsewhere.
pub fn write_handoff(
    settings: &Settings,
    path: &Path,
    body: &Path,
    handoff: &Path,
    keep_prior: bool,
    env: &agent_runtime::journal::Env,
) -> Result<Value> {
    let asks = std::cell::RefCell::new(Vec::new());
    let amend = |text: &str| -> agent_runtime::Result<String> {
        let read = open_asks(settings, path).map_err(agent_runtime::Error::from)?;
        let amended = with_asks_line(text, &asks_line(&read));
        *asks.borrow_mut() = read;
        Ok(amended)
    };
    let written = agent_runtime::controller::handoff::write(
        path,
        body,
        handoff,
        keep_prior,
        &agent_runtime::controller::handoff::Opener {
            misplaced: &progress_record,
            amend: &amend,
        },
        env,
    )?;
    Ok(json!({
        "path": written.path,
        "generation": written.generation,
        "written_at": written.written_at,
        "asks": asks.into_inner(),
    }))
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
