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
use std::time::Duration;

use serde_json::{Value, json};

use super::transition::OverseerExpected;
use super::views::{AccountState, Caller, MarkKind, Record};
use super::{MEMBER, Overseer, Pending};
use crate::accounts::walk::{Preference, Scope, Source, WalkAnswer, WalkRequest, Walked};
use crate::accounts::wall::canon;
use crate::accounts::{Env, PickAnswer, PickRequest};
use crate::error::{Error, Result};
use crate::harness::Harness;
use crate::launch::Permission;
use crate::record;
use crate::settings::{
    CONTROLLER_PREFERENCE_KEY, ControllerSettings, Judged, LaunchSettings, Succession,
};
use crate::stop::{self, Action, Episode, Kind, Session};

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
/// own account, unpicked, where it has room; a context mark walks the
/// caller's own entry alone where the setting names no preference, since a
/// context handoff replaces the session and not its harness or model. At
/// every mark a walk with no room takes one account nothing measured (the
/// walk's `keep_unmeasured`): the caller's own where the mark leaves it in,
/// else one whose usage query was refused with a 429. Every succession
/// walks the caller's own entry last.
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
    Ok(match mark {
        MarkKind::Headroom | MarkKind::Rate => recovery_walk(caller, harness, Leaving::Account),
        MarkKind::Context => departing(
            caller,
            harness,
            Some(entry),
            Vec::new(),
            (!choosing.controller.preference_set).then(String::new),
        ),
        MarkKind::Memory => departing(caller, harness, Some(entry), Vec::new(), None),
    })
}

/// What a succession leaves behind: the stopped session's account, at a
/// wall or an account mark, or its provider, which a provider that stopped
/// answering for its whole patience (`stop::PROVIDER_PATIENCE`) leaves.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Leaving<'a> {
    Account,
    /// The walk over `preference`, the setting's text, less every entry
    /// on the caller's provider.
    Provider {
        preference: &'a str,
    },
}

/// The walk a succession that leaves `leaving` takes for `caller` on
/// `harness`. Leaving the account, the account is left out of every pick
/// and the caller's own entry is walked last, never kept. Leaving the
/// provider, every entry on the caller's provider ([`provider`]) and the
/// caller's own entry are left out, since another account of the same
/// provider changes nothing; a preference the grammar refuses is walked as
/// written, so the walk refuses it by its own rule. Either walk takes one
/// account nothing measured where none has room.
pub fn recovery_walk(caller: &Caller, harness: Harness, leaving: Leaving) -> WalkRequest {
    match leaving {
        Leaving::Account => departing(
            caller,
            harness,
            Some(caller.walk_entry(harness)),
            caller.account.iter().cloned().collect(),
            None,
        ),
        Leaving::Provider { preference } => {
            let own = provider(harness, caller.model.as_deref().unwrap_or_default());
            let kept = match Preference::parse(preference, Scope::Overseer) {
                Ok(parsed) => parsed
                    .entries
                    .iter()
                    .filter(|entry| provider(entry.harness, &entry.model) != own)
                    .map(|entry| entry.text.as_str())
                    .collect::<Vec<_>>()
                    .join(","),
                Err(_) => preference.to_owned(),
            };
            departing(caller, harness, None, Vec::new(), Some(kept))
        }
    }
}

/// The walk a stop of the recorded `caller` on `harness` takes as it
/// leaves `leaving` ([`recovery_walk`]), or none where the record names no
/// account: a stop's move retires the stopped session as walled, which
/// spends that account (`transition::check_cause` refuses a walled
/// transfer naming none), so nothing moves it.
pub fn stop_walk(caller: &Caller, harness: Harness, leaving: Leaving) -> Option<WalkRequest> {
    caller
        .account
        .as_ref()
        .map(|_| recovery_walk(caller, harness, leaving))
}

/// The company whose service a session on `harness` running `model` sends
/// its turns to, which every account and harness on that service shares: a
/// Pi model's `provider/` word names it, a `pi-claude/` model running on a
/// Claude seat, an `openai-codex/` one on the ChatGPT Codex service Codex
/// itself spends, and a `github-copilot/` one on the Copilot pool
/// (`Harness::billed`, `Harness::pool`).
fn provider(harness: Harness, model: &str) -> &str {
    match (harness, model.split_once('/')) {
        (Harness::Claude, _) | (Harness::Pi, Some(("pi-claude" | "anthropic", _))) => "anthropic",
        (Harness::Codex, _) | (Harness::Pi, Some(("openai" | "openai-codex", _))) => "openai",
        (Harness::Copilot, _) | (Harness::Pi, Some(("github-copilot", _))) => "github",
        (Harness::Pi, Some((service, _))) => service,
        (Harness::Pi, None) => "pi",
    }
}

/// An overseer succession's walk: the caller's source posture, the
/// `entry` walked last, the accounts `exclude` names left out, over
/// `preference` in place of the setting's.
fn departing(
    caller: &Caller,
    harness: Harness,
    entry: Option<crate::accounts::walk::Caller>,
    exclude: Vec<String>,
    preference: Option<String>,
) -> WalkRequest {
    WalkRequest {
        scope: Scope::Overseer,
        preference,
        lane: None,
        exclude,
        max_pct: None,
        min_headroom_pct: None,
        source: Some(source(caller, harness)),
        caller: entry,
        keep_unmeasured: true,
    }
}

/// The walk and the pick the choice judges on, its opener's: the walk over
/// the entries the request names, each on the host it names, and the pick
/// over the accounts of one host (`None` this machine's).
pub struct Ground<'g> {
    pub walk: &'g mut dyn FnMut(&WalkRequest) -> Result<Walked>,
    pub pick: &'g mut dyn FnMut(&PickRequest, Option<&str>) -> PickAnswer,
}

/// The recorded controller a succession or a stop is chosen for: its
/// session, its harness, and the compare-and-swap set naming its pane.
struct Recorded {
    caller: Caller,
    harness: Harness,
    expected: OverseerExpected,
}

/// The controller recorded at `path` whose pane `pane` names.
fn recorded(path: &Path, pane: &str) -> Result<Recorded> {
    let record = controller_record(path)?
        .ok_or_else(|| refused("record-missing", &[("path", &path.display().to_string())]))?;
    let caller = Caller::of(&record);
    let harness = caller
        .harness
        .ok_or_else(|| refused("harness-unnamed", &[("pane", pane)]))?;
    let mut expected = record.expected();
    expected.pane = json!(pane);
    Ok(Recorded {
        caller,
        harness,
        expected,
    })
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
    let recorded = predecessor.map(|pane| recorded(path, pane)).transpose()?;
    let request = match (recorded.as_ref(), mark) {
        (Some(recorded), Some(mark)) => {
            let mut pick = |request: &PickRequest| (ground.pick)(request, None);
            walk_request(
                choosing,
                &mut pick,
                &recorded.caller,
                recorded.harness,
                mark,
                now,
            )?
        }
        (recorded, _) => WalkRequest {
            scope: Scope::Overseer,
            preference: None,
            lane: None,
            exclude: Vec::new(),
            max_pct: None,
            min_headroom_pct: None,
            source: recorded.map(|recorded| source(&recorded.caller, recorded.harness)),
            caller: None,
            keep_unmeasured: false,
        },
    };
    let walked = (ground.walk)(&held(path, request, now)?)?;
    let successor = opened(choosing, recorded.as_ref(), &walked, cwd, handoff)?;
    Ok(reply(Some(&walked), successor.as_ref(), recorded.as_ref()))
}

/// The walk `request` with the accounts the record at `path` holds
/// unproved left out ([`hold_unproved`]).
fn held(path: &Path, mut request: WalkRequest, now: u64) -> Result<WalkRequest> {
    let doc = record::read_document(path)?;
    hold_unproved(
        &mut request,
        doc.as_ref()
            .and_then(|doc| doc.get(MEMBER))
            .and_then(|member| member.get("unproved")),
        now,
    );
    Ok(request)
}

/// The pending the walk's chosen entry opens, in `cwd` with the handoff at
/// `handoff`, else the recorded controller's own: a first controller under
/// the settings' posture, a successor under the one it carries. `None`
/// where the walk chose none.
fn opened(
    choosing: &Choosing,
    recorded: Option<&Recorded>,
    walked: &Walked,
    cwd: &Path,
    handoff: Option<&str>,
) -> Result<Option<Pending>> {
    let chosen = match &walked.answer {
        WalkAnswer::Lane(chosen) => chosen,
        WalkAnswer::None | WalkAnswer::Held { .. } => return Ok(None),
    };
    let mut pending = match recorded {
        None => {
            let mut pending = Caller::default().successor_of(chosen);
            pending.permission = Some(choosing.launch.permission.get()?);
            pending
        }
        Some(recorded) => {
            let mut pending = recorded.caller.successor_of(chosen);
            posture(&mut pending, choosing.launch)?;
            pending
        }
    };
    pending.cwd.get_or_insert_with(|| cwd.display().to_string());
    pending.handoff = handoff
        .map(str::to_owned)
        .or_else(|| recorded.and_then(|recorded| recorded.caller.handoff.clone()));
    Ok(Some(pending))
}

/// The answer a choice prints: the walk's own reply (`null` where none
/// ran), the pending, and the compare-and-swap set a succession's transfer
/// carries.
fn reply(
    walked: Option<&Walked>,
    successor: Option<&Pending>,
    recorded: Option<&Recorded>,
) -> Value {
    json!({
        "walk": walked.map(Walked::reply),
        "successor": successor,
        "expected": recorded.map(|recorded| &recorded.expected),
    })
}

/// A stop of the recorded controller as its caller asks it: the stop's
/// kind, and the episode the caller recorded from an earlier answer.
#[derive(Debug)]
pub struct Stopped {
    pub kind: Kind,
    pub recorded: Option<Episode>,
}

/// The stop decision for the recorded controller whose pane `predecessor`
/// names, on the opener's `ground`: [`stop::action`]'s action for Jarvis,
/// its one caller (an overseer's stop is orch's watch's, on the fleet's
/// ground), the episode that stands, for the caller to record, and the
/// reset a wait waits for, beside [`successor`]'s answer: the walk, the
/// pending a move's transfer carries and its compare-and-swap set.
///
/// A provider stop inside the patience is asked as though another
/// provider had room, so no walk runs; past it the walk leaves the
/// provider ([`stop_walk`]), and a walk that chose none, left an entry
/// unread or refused resumes the session, the refusal answered as
/// `walk_refused`. A limit or an ended sign-in walks off the account, and
/// a limit no other account has room for reads its own account's reset.
/// Under succession off, or for a record naming no account, no walk runs
/// and nothing moves. Where neither a move nor a resume follows, a walk
/// that chose none past an entry it could not read decides nothing
/// (`walk-unread`), and nor does an own account the judge could not read
/// (`account-unread`). An exited harness is refused (`stop-kind-unjudged`):
/// its own account's room decides it, and no caller asks it here.
#[allow(clippy::too_many_arguments)]
pub fn stopped(
    choosing: &Choosing,
    path: &Path,
    predecessor: &str,
    asked: Stopped,
    cwd: &Path,
    handoff: Option<&str>,
    ground: Ground,
    now: u64,
) -> Result<Value> {
    let since = stop::standing(asked.recorded, now).unwrap_or(now);
    let age = Duration::from_secs(now.saturating_sub(since));
    let session = Session::Jarvis;
    let own_room = asked.kind == Kind::Provider;
    let ground_of = |room, reset| stop::Ground {
        own_room,
        room,
        reset,
        resets: &[],
    };
    let leaving = match asked.kind {
        Kind::Provider => (stop::action(Kind::Provider, age, session, ground_of(true, false))
            == Action::MoveProvider)
            .then_some(Leaving::Provider {
                preference: &choosing.controller.preference,
            }),
        Kind::Usage | Kind::Auth => Some(Leaving::Account),
        Kind::Exited => return Err(refused("stop-kind-unjudged", &[("kind", "exited")])),
    };
    let recorded = recorded(path, predecessor)?;
    // Under succession off the hand-over admits no transfer, so a move
    // named here could never happen.
    let may_move = choosing.controller.succession.get()? == Succession::On;
    let request = leaving
        .filter(|_| may_move)
        .and_then(|leaving| stop_walk(&recorded.caller, recorded.harness, leaving));
    let Ground { walk, pick } = ground;
    let found = match request {
        Some(request) => Some(walk(&held(path, request, now)?)),
        None => None,
    };
    let (walked, walk_refused) = match found {
        Some(Ok(walked)) => (Some(walked), None),
        // A provider stop's own account still has room: a walk that could
        // not judge another provider leaves the session where it stopped,
        // as one that left an entry unread does.
        Some(Err(refusal)) if asked.kind == Kind::Provider => (None, Some(refusal)),
        Some(Err(refusal)) => return Err(refusal),
        None => (None, None),
    };
    let successor = match &walked {
        Some(walked) => opened(choosing, Some(&recorded), walked, cwd, handoff)?,
        None => None,
    };
    let moves = successor.is_some();
    if !moves
        && asked.kind != Kind::Provider
        && let Some(walked) = &walked
        && !walked.unread.is_empty()
    {
        return Err(refused(
            "walk-unread",
            &[("entries", &walked.unread.join(","))],
        ));
    }
    let reset = match asked.kind {
        Kind::Usage if !moves => {
            own_reset(choosing, &recorded, &mut |request| pick(request, None), now)?
        }
        Kind::Usage | Kind::Auth | Kind::Provider | Kind::Exited => None,
    };
    let action = stop::action(asked.kind, age, session, ground_of(moves, reset.is_some()));
    let mut answer = reply(walked.as_ref(), successor.as_ref(), Some(&recorded));
    answer["action"] = json!(action);
    answer["episode"] = json!(Episode { since, last: now });
    answer["reset"] = json!(reset);
    if let Some(refusal) = &walk_refused {
        answer["walk_refused"] = json!(crate::protocol::Refusal::from(refusal));
    }
    Ok(answer)
}

/// The reset of the recorded controller's own account, epoch seconds, as
/// the judge reads it at the trigger: `None` where nothing measures it or
/// its reading states no reset. An account the judge could not read
/// ([`AccountState::Unreadable`]) refuses `account-unread` with the
/// listing's status where it holds one: the reset such a reading lacks is
/// unread, never one nobody states.
fn own_reset(
    choosing: &Choosing,
    recorded: &Recorded,
    pick: &mut dyn FnMut(&PickRequest) -> PickAnswer,
    now: u64,
) -> Result<Option<u64>> {
    let trigger = choosing.accounts.accounts.get()?.controller_headroom_pct;
    let read = recorded
        .caller
        .own_account(recorded.harness, pick, trigger, now);
    match read.state {
        AccountState::HasRoom | AccountState::AtTrigger => {
            Ok(crate::clock::epoch_secs(&read.resets))
        }
        AccountState::Unmeasured => Ok(None),
        AccountState::Unreadable => {
            let account = recorded.caller.account.as_deref().unwrap_or_default();
            let mut fields = vec![("account", account)];
            if !read.status.is_empty() {
                fields.push(("status", read.status.as_str()));
            }
            Err(refused("account-unread", &fields))
        }
    }
}

/// How long a failed attempt holds its account out of the walk. A mark
/// repeats every watch pass, so an account that just failed would be
/// relaunched at once with no hold; a hold with no end would keep it out
/// after its cause was repaired, with nothing that clears it short of a
/// confirmed hand-over. Half an hour spans several mark repeats and ends
/// well inside an account's weekly window.
pub const UNPROVED_HOLD_SECS: u64 = 1800;

/// The walk of a succession with the accounts a failed attempt left
/// unproved held out of it: each in the controller record's `unproved`
/// list (`marked`) whose stamp is within [`UNPROVED_HOLD_SECS`] of `now`,
/// the caller's own among them, is excluded, which keeps it from the walk's
/// unmeasured keep as well, and the caller's entry naming one is walked,
/// never kept. An entry with no stamp, or one that does not parse, is
/// expired, since nothing says when its hold began. Every succession walk
/// that reads a controller record takes it, the watch's walled one too.
pub fn hold_unproved(request: &mut WalkRequest, marked: Option<&Value>, now: u64) {
    let holds = |entry: &Value| {
        entry
            .get("at")
            .and_then(Value::as_str)
            .and_then(crate::clock::epoch_secs)
            .is_some_and(|at| now < at.saturating_add(UNPROVED_HOLD_SECS))
    };
    let unproved: Vec<String> = marked
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|entry| holds(entry))
        .filter_map(|entry| entry.get("account").and_then(Value::as_str))
        .map(str::to_owned)
        .collect();
    if let Some(entry) = request.caller.as_mut()
        && entry
            .lane
            .as_deref()
            .is_some_and(|lane| unproved.iter().any(|account| canon(account) == canon(lane)))
    {
        entry.keep = false;
    }
    request.exclude.extend(unproved);
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
    let binding = super::model::launch_of(&super::model::Place::Controller, &recorded);
    Ok(json!({
        "successor": successor,
        "expected": expected,
        "recovery": binding,
    }))
}

/// The successor that continues the recorded controller's own native
/// session once the session running it ended, as after a restart: its own
/// launch with no walk, the record's native id as its resume and, for Pi,
/// which continues by file, the file that id names under its home for its
/// working directory, which must stand (`session-missing`): the home is the
/// one the start's launch names, the account where it is the Pi root. An
/// accountless Claude or Codex successor keeps the recorded home, a Claude
/// one in its recorded mode, as does a Claude one recorded on its implicit
/// default whose account is that path. A start opens
/// it; a record naming no native id refuses `session-unrecorded`.
pub fn resumed(launch: &LaunchSettings, path: &Path) -> Result<Value> {
    let missing = || refused("record-missing", &[("path", &path.display().to_string())]);
    let doc = record::read_document(path)?.ok_or_else(missing)?;
    let overseer = record::field::<Overseer>(path, &doc, MEMBER)?.ok_or_else(missing)?;
    let record = Record::read(Some(&overseer)).ok_or_else(missing)?;
    let mut successor = record
        .own_successor()
        .ok_or_else(|| refused("harness-unnamed", &[("pane", &record.pane)]))?;
    posture(&mut successor, launch)?;
    let id = overseer
        .session_id
        .filter(|id| !id.is_empty())
        .ok_or_else(|| {
            refused(
                "session-unrecorded",
                &[("field", "session_id"), ("pane", &record.pane)],
            )
        })?;
    // An accountless session's store is the home its record keeps, which
    // the variable the fleet server or the caller hands may no longer name.
    // A Claude home resumes only with its recorded mode; one recorded with
    // none resumes on the home a fresh launch resolves, as before modes
    // were recorded. A Claude session on its implicit default whose account
    // is that same path, the account a registration derives for a session
    // naming no config dir, resumes on that default too, its account still
    // billed and measured.
    if let Some(home) = Caller::of(&record).home {
        let mode = record.raw.get("home_implicit").and_then(Value::as_bool);
        match (record.harness, successor.account.as_deref(), mode) {
            (Some(Harness::Codex), None, _) => successor.home = Some(home),
            (Some(Harness::Claude), None, Some(implicit)) => {
                successor.home = Some(home);
                successor.home_implicit = implicit;
            }
            (Some(Harness::Claude), Some(account), Some(true))
                if canon(account) == canon(&home) =>
            {
                successor.home = Some(home);
                successor.home_implicit = true;
            }
            (Some(Harness::Codex), Some(_), _)
            | (Some(Harness::Claude), _, _)
            | (Some(Harness::Copilot | Harness::Pi) | None, _, _) => {}
        }
    }
    if record.harness == Some(Harness::Pi) {
        // The Pi root the launch runs on: the account where its variable is
        // Pi's own (a model Pi's root bills), else the home the record keeps.
        let billed_root =
            Harness::Pi.account_var(successor.model.as_deref()) == Harness::Pi.home_var();
        let home = successor
            .account
            .as_deref()
            .filter(|_| billed_root)
            .or(successor.home.as_deref())
            .map(std::path::PathBuf::from)
            .or_else(|| crate::effects::default_home(Harness::Pi));
        let cwd = successor.cwd.as_deref().map(Path::new);
        let found = match (home, cwd) {
            (Some(home), Some(cwd)) => crate::effects::fixed_id_file(Harness::Pi, &home, cwd, &id),
            (None, _) | (_, None) => crate::reading::Reading::Gone,
        };
        successor.resume_file = match found {
            crate::reading::Reading::Live(file) => Some(file.display().to_string()),
            crate::reading::Reading::Gone => {
                return Err(refused("session-missing", &[("session", &id)]));
            }
            crate::reading::Reading::Unreadable { cause } => {
                return Err(refused("session-store-unreadable", &[("cause", cause)]));
            }
        };
    }
    successor.resume = Some(id);
    Ok(json!({"successor": successor}))
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::accounts::{AccountRow, Judged};
    use crate::settings::{AccountSettings, Judged as Setting, QuestionToolSetting, Succession};

    fn account_settings() -> AccountSettings {
        AccountSettings {
            retire: Vec::new(),
            max_pct: 90,
            burn_pct_per_hour: 0,
            controller_headroom_pct: 20,
            codex_credit_floor: 0,
            cloud_credit_floor: 0,
            copilot_pool: Vec::new(),
            exclude: Vec::new(),
            aliases: Vec::new(),
            account_dirs: Vec::new(),
            codex_home: None,
            usage_ttl: 0,
            usage_max_age: 0,
            claude_usage_url: String::new(),
            codex_usage_url: String::new(),
            claude_token_url: String::new(),
            claude_client_id: None,
        }
    }

    /// The caller's own account judged `verdict` at `wall` percent used.
    fn judged(verdict: &str, wall: f64) -> Judged {
        let raw = json!({"alias": "a1", "harness": "claude", "config_dir": "/a/a1",
                         "status": "ok", "verdict": verdict, "headroom_pct": 100.0 - wall});
        Judged {
            row: AccountRow::parse(&raw, &account_settings()).unwrap(),
            verdict: verdict.to_owned(),
            wall: Some(wall),
            binding: None,
            claims: 0,
            projection: None,
            seat: false,
            credits: false,
            grant: None,
            score: None,
            qualifying: None,
            usage_stale: false,
        }
    }

    /// Row 250: for one caller and one answer of the pick over its own
    /// account, the walk a context mark's succession takes keeps or leaves
    /// that account as `own_account` reads it: an account with room is kept
    /// unpicked and excluded from nothing; a walled one sends the walk as
    /// the headroom mark's, the account left out of every pick and not
    /// kept; one nothing measures is not kept and is left in the pick.
    /// Every row's walk keeps one account nothing measured where none has
    /// room, which the walk judges.
    #[test]
    fn a_marks_walk_keeps_or_leaves_the_callers_account_as_its_own_read_says() {
        let accounts = Setting::of("accounts", Ok(account_settings()));
        let account_state = Setting::of("account-state", Ok(std::path::PathBuf::from("/none")));
        let launch = LaunchSettings {
            permission: Setting::of("permission", Ok(Permission::Bypass)),
        };
        let controller = ControllerSettings {
            question_tool: Setting::of("question-tool", Ok(QuestionToolSetting::Off)),
            succession: Setting::of("succession", Ok(Succession::On)),
            preference: String::new(),
            preference_set: true,
            account_tokens: Setting::of("account-tokens", Ok(Vec::new())),
        };
        let wall_minutes = Setting::of("wall-minutes", Ok(0));
        let choosing = Choosing {
            accounts: Env {
                accounts: &accounts,
                account_state: &account_state,
                home: None,
                copilot_home: None,
                controller_preference: "",
                account_tokens: &controller.account_tokens,
            },
            launch: &launch,
            controller: &controller,
            wall_minutes: &wall_minutes,
        };
        let caller = Caller {
            harness: Some(Harness::Claude),
            account: Some("/a/a1".to_owned()),
            model: Some("claude-opus-5-5".to_owned()),
            ..Caller::default()
        };
        // case, the pick's answer, the state read, kept, the accounts
        // excluded
        type Row = (
            &'static str,
            fn() -> PickAnswer,
            AccountState,
            bool,
            &'static [&'static str],
        );
        let rows: [Row; 3] = [
            (
                "room",
                || PickAnswer::Lane(judged("room", 40.0)),
                AccountState::HasRoom,
                true,
                &[],
            ),
            (
                "walled",
                || PickAnswer::Walled(judged("walled", 95.0)),
                AccountState::AtTrigger,
                false,
                &["/a/a1"],
            ),
            (
                "unmeasured",
                || PickAnswer::NoRecord,
                AccountState::Unmeasured,
                false,
                &[],
            ),
        ];
        for (case, answer, state, keep, exclude) in rows {
            let mut pick = |_: &PickRequest| answer();
            let read = caller.own_account(Harness::Claude, &mut pick, 20, 1_800_000_000);
            assert_eq!(read.state, state, "{case}");
            let request = walk_request(
                &choosing,
                &mut pick,
                &caller,
                Harness::Claude,
                MarkKind::Context,
                1_800_000_000,
            )
            .unwrap();
            let entry = request.caller.as_ref().unwrap();
            assert_eq!(entry.keep, keep, "{case}");
            assert!(request.keep_unmeasured, "{case}");
            assert_eq!(request.exclude, exclude, "{case}");
        }
    }

    /// A provider stop's walk leaves out every entry on the caller's
    /// provider, whichever harness carries it, and the caller's own entry;
    /// an account's walk leaves out the account and walks the caller last.
    #[test]
    fn a_recovery_walk_leaves_the_callers_account_or_every_entry_on_its_provider() {
        let preference = "claude:standard:high,pi:pi-claude/opus:high,pi:anthropic/claude-x:high,codex:standard:high,pi:openai/gpt-5:high,copilot:standard:high,pi:github-copilot/gpt-5:high,pi:google/gemini:high";
        let caller = |harness, account: &str, model: &str| Caller {
            harness: Some(harness),
            account: Some(account.to_owned()),
            model: Some(model.to_owned()),
            ..Caller::default()
        };
        // case, the caller, the walk left, the preference walked, the
        // accounts excluded, the caller's entry walked
        type Row<'a> = (
            &'a str,
            Caller,
            Leaving<'a>,
            Option<&'a str>,
            &'a [&'a str],
            bool,
        );
        let rows: [Row; 5] = [
            (
                "claude account",
                caller(Harness::Claude, "/a/a1", "opus"),
                Leaving::Account,
                None,
                &["/a/a1"],
                true,
            ),
            (
                "claude provider",
                caller(Harness::Claude, "/a/a1", "opus"),
                Leaving::Provider { preference },
                Some(
                    "codex:standard:high,pi:openai/gpt-5:high,copilot:standard:high,pi:github-copilot/gpt-5:high,pi:google/gemini:high",
                ),
                &[],
                false,
            ),
            (
                "pi copilot provider",
                caller(Harness::Pi, "/p/root", "github-copilot/gpt-5"),
                Leaving::Provider { preference },
                Some(
                    "claude:standard:high,pi:pi-claude/opus:high,pi:anthropic/claude-x:high,codex:standard:high,pi:openai/gpt-5:high,pi:google/gemini:high",
                ),
                &[],
                false,
            ),
            // Pi's `openai-codex/` model is the ChatGPT Codex service Codex
            // spends (harness.rs's real-example row names
            // `openai-codex/gpt-5.5`).
            (
                "codex provider",
                caller(Harness::Codex, "/c/c1", ""),
                Leaving::Provider {
                    preference: "codex:standard:high,pi:openai-codex/gpt-5.5:high,copilot:standard:high",
                },
                Some("copilot:standard:high"),
                &[],
                false,
            ),
            (
                "refused preference",
                caller(Harness::Codex, "/c/c1", ""),
                Leaving::Provider {
                    preference: "codex",
                },
                Some("codex"),
                &[],
                false,
            ),
        ];
        for (case, caller, leaving, walked, exclude, entry) in rows {
            let harness = caller.harness.unwrap();
            let request = recovery_walk(&caller, harness, leaving);
            assert_eq!(request.preference.as_deref(), walked, "{case}");
            assert_eq!(request.exclude, exclude, "{case}");
            assert_eq!(
                request.caller.as_ref().map(|c| (c.harness, c.keep)),
                entry.then_some((harness, false)),
                "{case}"
            );
            assert!(request.keep_unmeasured, "{case}");
            assert_eq!(request.scope, Scope::Overseer, "{case}");
        }
    }
}
