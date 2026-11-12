//! The controller a hand-over opens: the controller walk's choice made
//! into the pending a start or transfer request carries. A first
//! controller walks with no source session, so only an entry whose harness
//! writes a full bypass is taken, and runs under the settings' posture; a
//! succession walks with the recorded controller's posture as the source
//! and keeps it on a same-harness successor. A succession a mark sent walks
//! as that mark decides (`walk_request`). Nothing is written: the request
//! that carries the answer records it. The walk judges on its opener's
//! ground: the host each entry names and the pick over the accounts there.

use std::path::Path;

use serde_json::{Value, json};

use super::views::{AccountState, Caller, MarkKind, Record};
use super::{MEMBER, Overseer, Pending};
use crate::accounts::walk::{Preference, Scope, Source, WalkAnswer, WalkRequest, Walked};
use crate::accounts::{Env, PickAnswer, PickRequest};
use crate::error::{Error, Result};
use crate::harness::Harness;
use crate::launch::Permission;
use crate::record;
use crate::settings::{CONTROLLER_PREFERENCE_KEY, ControllerSettings, Judged, LaunchSettings};

/// What the choice reads beside the record: the account judge's settings,
/// the launch's posture, the hand-over's preference, and the wall mark the
/// opener's marks name, read only where a mark's succession needs it.
pub struct Choosing<'a> {
    pub accounts: Env<'a>,
    pub launch: &'a LaunchSettings,
    pub controller: &'a ControllerSettings,
    pub wall_minutes: &'a Judged<u32>,
}

/// The posture a successor launches under: the one it carries, else the
/// settings', so its record names the posture the next walk reads.
pub fn posture(pending: &mut Pending, launch: &LaunchSettings) -> Result<()> {
    if pending.permission.is_none() {
        pending.permission = Some(launch.permission.get()?);
    }
    Ok(())
}

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    Error::refused(key, fields)
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
    choosing: &Choosing,
    pick: &mut dyn FnMut(&PickRequest) -> PickAnswer,
    caller: &Caller,
    harness: Harness,
    mark: MarkKind,
    now: u64,
) -> Result<WalkRequest> {
    let (state, reached) = match mark {
        MarkKind::Headroom | MarkKind::Rate => (None, None),
        MarkKind::Context | MarkKind::Memory => {
            let wall_minutes = choosing.wall_minutes.get()?;
            let trigger = choosing.accounts.accounts.get()?.controller_headroom_pct;
            let (state, reached) =
                caller.account_departure(harness, wall_minutes, trigger, pick, now);
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
            (!choosing.controller.preference_set).then(String::new),
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

/// The walk and the pick the choice judges on, its opener's: the walk over
/// the entries the request names, each on the host it names, and the pick
/// over the accounts of one host (`None` this machine's).
pub struct Ground<'g> {
    pub walk: &'g mut dyn FnMut(&WalkRequest) -> Result<Walked>,
    pub pick: &'g mut dyn FnMut(&PickRequest, Option<&str>) -> PickAnswer,
}

/// The choice: the controller walk for the record at `path`, for its
/// first controller in `cwd`, or for the successor of the recorded
/// controller whose pane `predecessor` names, walked as the `mark` that
/// sent it decides, on the opener's `ground`. The reply carries the walk's
/// own reply, the pending the choice opens with the handoff at `handoff`
/// (`null` where the walk chose none) and, for a succession, the
/// compare-and-swap set naming that pane. Left out, the handoff is the
/// recorded controller's own, so a succession keeps the launch's handoff;
/// the pending names none where neither does.
#[allow(clippy::too_many_arguments)]
pub fn successor(
    choosing: &Choosing,
    path: &Path,
    predecessor: Option<&str>,
    mark: Option<MarkKind>,
    cwd: &Path,
    handoff: Option<&str>,
    ground: Ground,
    now: u64,
) -> Result<Value> {
    // An empty preference is a setting with no entry to walk, not a walk
    // that found no room: no wait for headroom could open anything. A mark's
    // succession still walks the caller's own entry.
    if mark.is_none()
        && Preference::parse(&choosing.controller.preference, Scope::Overseer)
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
            let record = controller_record(path)?.ok_or_else(|| {
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
    let handoff = handoff.map(str::to_owned).or_else(|| {
        recorded
            .as_ref()
            .and_then(|(caller, _, _)| caller.handoff.clone())
    });
    let request = match (recorded.as_ref(), mark) {
        (Some((caller, harness, _)), Some(mark)) => {
            let mut pick = |request: &PickRequest| (ground.pick)(request, None);
            walk_request(choosing, &mut pick, caller, *harness, mark, now)?
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
    let walked = (ground.walk)(&request)?;
    let successor = match &walked.answer {
        WalkAnswer::Lane(chosen) => {
            let mut pending = match &recorded {
                None => {
                    let mut pending = Caller::default().successor_of(chosen);
                    pending.permission = Some(choosing.launch.permission.get()?);
                    pending
                }
                Some((caller, _, _)) => {
                    let mut pending = caller.successor_of(chosen);
                    posture(&mut pending, choosing.launch)?;
                    pending
                }
            };
            pending.cwd.get_or_insert_with(|| cwd.display().to_string());
            pending.handoff = handoff.clone();
            Some(pending)
        }
        WalkAnswer::None | WalkAnswer::Held { .. } => None,
    };
    Ok(json!({
        "walk": walked.reply(),
        "successor": successor,
        "expected": recorded.map(|(_, _, expected)| expected),
    }))
}

/// The successor a model recovery opens for the recorded controller whose
/// pane `predecessor` names: the controller's own launch, its model the one
/// it was launched with, under its own handoff, with the record as the
/// compare-and-swap set and the record's launch as the recovery's binding,
/// which the transition holds the acquired model check to. No walk: the
/// recovery replaces the session, never its account or harness.
pub fn recovery(launch: &LaunchSettings, path: &Path, predecessor: &str) -> Result<Value> {
    let missing = || refused("record-missing", &[("path", &path.display().to_string())]);
    let doc = record::read_document(path)?.ok_or_else(missing)?;
    let record = record::field::<Overseer>(path, &doc, MEMBER)
        .ok()
        .flatten()
        .and_then(|overseer| Record::read(Some(&overseer)))
        .ok_or_else(missing)?;
    let mut successor = record
        .own_successor()
        .ok_or_else(|| refused("harness-unnamed", &[("pane", predecessor)]))?;
    posture(&mut successor, launch)?;
    let mut expected = record.expected();
    expected.pane = json!(predecessor);
    let recorded = doc.get(MEMBER).cloned().unwrap_or(Value::Null);
    let binding: serde_json::Map<String, Value> = super::transition::MODEL_LAUNCH_KEYS
        .iter()
        .map(|key| {
            (
                (*key).to_owned(),
                recorded.get(*key).cloned().unwrap_or(Value::Null),
            )
        })
        .collect();
    Ok(json!({
        "successor": successor,
        "expected": expected,
        "recovery": binding,
    }))
}

/// The controller member of the record at `path` as the choice reads it;
/// `None` where no record stands or its member names no server or pane.
fn controller_record(path: &Path) -> Result<Option<Record>> {
    let Some(doc) = record::read_document(path)? else {
        return Ok(None);
    };
    let overseer: Option<Overseer> = record::field(path, &doc, MEMBER)?;
    Ok(Record::read(overseer.as_ref()))
}
