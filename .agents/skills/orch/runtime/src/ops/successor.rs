//! The controller an overseer launch opens: the overseer walk's choice made
//! into the pending a `start-controller` or `request-transfer` request
//! carries. A fleet's first controller walks with no source session, so
//! only an entry whose harness writes a full bypass is taken, and runs under
//! the settings' posture; a succession walks with the recorded controller's
//! posture as the source and keeps it on a same-harness successor. A
//! succession a mark sent walks as that mark decides (`walk_request`).
//! Nothing is written: the request that carries the answer records it. The
//! brief a controller opens on is [`brief`]'s, for every launch of one.

use std::path::Path;

use agent_runtime::harness::Harness;
use agent_runtime::launch::Permission;
use serde_json::{Value, json};

use crate::error::{Error, Result};
use crate::ops::walk::{self, Preference, Scope, Source, WalkAnswer, WalkRequest};
use crate::settings::{OVERSEER_PREFERENCE_KEY, Settings};
use crate::state::Pending;
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
pub fn posture(pending: &mut Pending, settings: &Settings) {
    pending.permission.get_or_insert(settings.permission);
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
        harness: harness.name().to_owned(),
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
) -> WalkRequest {
    let (state, reached) = match mark {
        MarkKind::Headroom | MarkKind::Rate => (None, None),
        MarkKind::Context | MarkKind::Memory => {
            let (state, reached) = caller.account_departure(harness, settings, path, host, now);
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
            (!settings.overseer_preference_set).then(String::new),
        ),
        MarkKind::Memory => (Vec::new(), None),
    };
    WalkRequest {
        scope: Scope::Overseer,
        preference,
        lane: None,
        exclude,
        replaces: None,
        max_pct: None,
        min_headroom_pct: None,
        source: Some(source(caller, harness)),
        caller: Some(entry),
        keep_unmeasured: mark == MarkKind::Context,
    }
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
        && Preference::parse(&settings.overseer_preference, Scope::Overseer)
            .is_ok_and(|preference| preference.entries.is_empty())
    {
        return Err(refused(
            "preference-empty",
            &[("setting", OVERSEER_PREFERENCE_KEY)],
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
    let host = crate::ops::Host::kernel(settings.lane_cap);
    let request = match (recorded.as_ref(), mark) {
        (Some((caller, harness, _)), Some(mark)) => {
            walk_request(settings, path, &host, caller, *harness, mark, now)
        }
        (recorded, _) => WalkRequest {
            scope: Scope::Overseer,
            preference: None,
            lane: None,
            exclude: Vec::new(),
            replaces: None,
            max_pct: None,
            min_headroom_pct: None,
            source: recorded.map(|(caller, harness, _)| source(caller, *harness)),
            caller: None,
            keep_unmeasured: false,
        },
    };
    let walked = walk::walk(settings, path, &host, &request, now)?;
    let successor = match &walked.answer {
        WalkAnswer::Lane(chosen) => {
            let mut pending = match &recorded {
                None => {
                    let mut pending = Caller::default().successor_of(chosen);
                    pending.permission = Some(settings.permission);
                    pending
                }
                Some((caller, _, _)) => {
                    let mut pending = caller.successor_of(chosen);
                    posture(&mut pending, settings);
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
