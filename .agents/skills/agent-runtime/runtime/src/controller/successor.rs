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
/// one the start's launch names, the account where it is the Pi root. A start opens
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
        .ok_or_else(|| refused("session-unrecorded", &[("pane", &record.pane)]))?;
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
            limit: 80.0,
            credits: false,
            grant: None,
            score: None,
            qualifying: None,
        }
    }

    /// Row 250: for one caller and one answer of the pick over its own
    /// account, the walk a context mark's succession takes keeps or leaves
    /// that account as `own_account` reads it: an account with room is kept
    /// unpicked and excluded from nothing; a walled one sends the walk as
    /// the headroom mark's, the account left out of every pick and not
    /// kept; one nothing measures is not kept and is left in the pick.
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
        };
        let wall_minutes = Setting::of("wall-minutes", Ok(0));
        let choosing = Choosing {
            accounts: Env {
                accounts: &accounts,
                account_state: &account_state,
                home: None,
                copilot_home: None,
                controller_preference: "",
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
            assert_eq!(request.exclude, exclude, "{case}");
        }
    }
}
