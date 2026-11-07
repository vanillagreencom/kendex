//! The launch effect: resolve everything a launch can refuse before a
//! window opens, write the launch record the lane's hook reads, open the
//! lane's window on the fleet server through the operation handle (a local
//! harness, or the ssh client carrying a hosted one), confirm the harness
//! in it, and the launch cells of the reconcile matrix. What a fleet lane's
//! harness needs beyond its trust record is [`gate`]'s. A cloud session is
//! created through the Claude CLI's own answer and opens no window. Every
//! host read and write here goes through [`Operation`] or the one runner.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::harness::Harness;
use agent_runtime::host::{self, Place};
use agent_runtime::launch::{
    Compaction, LaunchCommand, LaunchIntent, Permission, QuestionTool, Resume, shell_quote,
};
use agent_runtime::reading::Reading;
use agent_runtime::trust;
use serde_json::{Value, json};

use super::operation::{
    self, Binding, EffectOutcome, Foreground, Observed, OpenRefusal, Operation, Polled,
    ProcessRead, Published, Recovered, Server, SessionFloor, Wire, Word, opening_observation,
};
use super::{
    Run, Spec, Target, build_launch, check_directory, check_program, fleet_tmux_session,
    lane_for_intent, pane_harness, pending_observation, read_brief, refused, up,
};
use crate::error::{Error, Result};
use crate::marker;
use crate::ops::{CLOUD_KIND, LaunchLane, Relaunch, accounts};
use crate::settings::Settings;
use crate::state::{self, Intent, Lane, LaunchIdentity, OpenedPane, Phase};
use crate::watch::hosted::{self, Launch, PaneKind};

mod gate;

/// The words that close a cloud session's description, after the brief:
/// the branch it cloned and how it publishes.
const CLOUD_SESSION_TEXT: &str = include_str!("cloud-session.txt");
/// The words every local and hosted lane brief closes on, the text the
/// watch's relaunch brief closes on: an unattended lane asks the overseer
/// through its mailbox, never in a chat nobody reads.
const UNATTENDED_TEXT: &str = include_str!("../watch/unattended.txt");

/// `brief` closed by the unattended words on a line of their own, once: a
/// brief that already carries them, anywhere, is kept as it stands. They
/// ride the brief, never a system-prompt flag (Pi's `--append-system-prompt`
/// would stop it reading its own `APPEND_SYSTEM.md`).
fn unattended(brief: &str) -> String {
    let brief = brief.trim_end();
    let words = UNATTENDED_TEXT.trim_end();
    if brief.contains(words) {
        brief.to_owned()
    } else if brief.is_empty() {
        words.to_owned()
    } else {
        format!("{brief}\n{words}")
    }
}
/// The POSIX shell step a hosted Pi lane on the Copilot pool runs before
/// its harness, inside the provider's login shell: it copies the
/// github-copilot key variables its Pi `models.json` names and the host's
/// egress proxy settings into the tmux session holding its pane, which a
/// pane agent `tmux split-window` starts reads its environment from. The
/// server was started outside the login profile and holds neither, so
/// without the step every pane agent stops on "No API key found for
/// github-copilot" or reaches GitHub unproxied.
const PI_SESSION_ENV_STEP: &str = include_str!("pi-session-env.txt");
/// The bound on the Claude CLI creating a cloud session.
const CLOUD_BOUND: Duration = Duration::from_secs(600);
/// The bound on the worktree package and git during a cloud launch.
const CLOUD_PREPARE_BOUND: Duration = Duration::from_secs(900);

/// The session a launch opens: the lane's bound native session resumed, or
/// a fresh one, with why where a relaunch could not resume. The route is
/// judged from the records alone: the bound session id, the harness word
/// and the item's standing handoff; no session file is looked up by its
/// age.
enum Route {
    Fresh {
        cause: Option<&'static str>,
    },
    Resume {
        session_id: String,
        /// The home the session's file was found under, and whether the
        /// launch names it: the resumed launch runs there, since another
        /// home's store may not hold it (an account's own home is that
        /// account, unchanged).
        home: Option<Kept>,
    },
    /// The destination home's session store could not be read, or the bound
    /// session belongs to another directory: the launch refuses before any
    /// window rather than resuming a session it cannot prove its own or
    /// starting fresh over one that may stand.
    Refuse {
        cause: &'static str,
    },
}

impl Route {
    fn word(&self) -> &'static str {
        match self {
            Route::Fresh { .. } => "fresh",
            Route::Resume { .. } => "resume",
            Route::Refuse { .. } => "refuse",
        }
    }

    fn cause(&self) -> Option<&'static str> {
        match self {
            Route::Fresh { cause } => *cause,
            Route::Resume { .. } => None,
            Route::Refuse { cause } => Some(cause),
        }
    }
}

/// The fixed-id lookup a route reads the destination store with: the
/// directory the session's own file records, where the file stands.
type Owner<'a> = &'a dyn Fn(Harness, &Path, &Path, &str) -> Reading<Option<PathBuf>>;

/// The route a launch of `lane` takes under `r`: a lane bound to no
/// session, or whose harness word differs, or whose item holds a standing
/// handoff that says `fresh`, starts fresh; a bound session under the same
/// harness and account resumes. Pi resumes by session file, which the
/// record does not carry, so a Pi lane starts fresh and says so. A relaunch
/// on another account than the one the bound session was recorded under
/// starts fresh with `account-switched`, and one whose bound session the
/// destination home does not hold by its fixed id (its file absent, or a
/// Copilot session that holds no event) with `session-absent`: the context
/// continues through the handoff record, never a transcript another
/// account cannot read.
/// The destination is the home the lane's last confirmed launch recorded,
/// where its bound session was written (a private Codex home links the
/// account's store), in the mode it ran in; a lane that recorded none reads
/// its account. A record with neither is one no released writer gave a
/// home, so it is read as the released relaunch read it: under the home a
/// fresh launch picks (`served`, the fleet server's, else the inherited
/// home or the default). A resume runs under the home its session was
/// found under.
fn relaunch_route(run: &Run, lane: &Lane, r: &LaunchLane, served: Option<&Path>) -> Result<Route> {
    let handoff = standing_handoff(run, &lane.item)?;
    let destination = match (&lane.home, &r.account, Harness::parse(&r.harness)) {
        (Some(home), _, _) => Some(Kept {
            home: PathBuf::from(home),
            named: !lane.home_implicit,
        }),
        (None, Some(account), _) => Some(Kept {
            home: PathBuf::from(account),
            named: true,
        }),
        (None, None, Some(harness)) => accountless_kept(run.settings, harness, None, served),
        (None, None, None) => None,
    };
    let route = route_of(
        lane,
        r,
        handoff,
        destination.as_ref().map(|kept| kept.home.as_path()),
        &operation::session_owner,
    );
    Ok(match route {
        Route::Resume { session_id, .. } => Route::Resume {
            session_id,
            home: destination,
        },
        Route::Fresh { .. } | Route::Refuse { .. } => route,
    })
}

/// The route from the records alone: `handoff` is the item's standing
/// handoff route, `destination` the home the relaunch reads its sessions
/// under through `owner`, the session owner's fixed-id lookup, which
/// answers the directory the session's file records. A file recording
/// another directory than the lane's is another lane's session, refused:
/// the Codex and Copilot stores are keyed by id alone, so nothing else
/// tells one directory's transcript from another's. The working directory
/// reaches the Claude arm alone, whose store is keyed by it.
fn route_of(
    lane: &Lane,
    r: &LaunchLane,
    handoff: Option<Relaunch>,
    destination: Option<&Path>,
    owner: Owner,
) -> Route {
    let Some(session_id) = lane.session_id.clone() else {
        return Route::Fresh { cause: None };
    };
    if lane.harness.as_deref() != Some(r.harness.as_str()) {
        return Route::Fresh {
            cause: Some("harness-switched"),
        };
    }
    let Some(harness) = Harness::parse(&r.harness) else {
        return Route::Fresh {
            cause: Some("harness-switched"),
        };
    };
    if harness == Harness::Pi {
        return Route::Fresh {
            cause: Some("resume-file-unknown"),
        };
    }
    if lane.account != r.account {
        return Route::Fresh {
            cause: Some("account-switched"),
        };
    }
    // A session the destination home does not hold by its fixed id cannot
    // be resumed there, whatever the record says of the account; a store
    // that cannot be read refuses before any window, never a resume of an
    // unproven session nor a fresh start over one that may stand.
    let cwd = match harness {
        Harness::Claude => lane.mail_root.as_deref().map(Path::new),
        Harness::Codex | Harness::Copilot | Harness::Pi => Some(Path::new("")),
    };
    if let (Some(home), Some(cwd)) = (destination, cwd) {
        match owner(harness, home, cwd, &session_id) {
            Reading::Live(None) => {}
            Reading::Live(Some(recorded)) => {
                if !same_directory(&recorded, Path::new(&r.mail_root)) {
                    return Route::Refuse {
                        cause: "session-owned-elsewhere",
                    };
                }
            }
            Reading::Gone => {
                return Route::Fresh {
                    cause: Some("session-absent"),
                };
            }
            Reading::Unreadable { cause } => return Route::Refuse { cause },
        }
    }
    match handoff {
        Some(Relaunch::Resume) | None => Route::Resume {
            session_id,
            home: None,
        },
        Some(Relaunch::Fresh) => Route::Fresh {
            cause: Some("session-retired"),
        },
    }
}

/// Whether two directory spellings name one directory: resolved where both
/// resolve, else compared as spelled with trailing separators off.
fn same_directory(a: &Path, b: &Path) -> bool {
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => {
            let trimmed = |p: &Path| p.display().to_string().trim_end_matches('/').to_owned();
            trimmed(a) == trimmed(b)
        }
    }
}

/// The item's standing handoff route, where its state file holds a
/// `handoff` record no session has resumed (`resumed_at` unset): the
/// record's `relaunch` word, `fresh` where it names none. `None` with no
/// state file, no record, or a consumed one.
fn standing_handoff(run: &Run, item: &str) -> Result<Option<Relaunch>> {
    let path = state::item_path(&run.settings.state_dir, item);
    let Some(snapshot) = operation::load(&path)? else {
        return Ok(None);
    };
    let Some(handoff) = state::field::<Value>(&path, &snapshot.doc, "handoff")? else {
        return Ok(None);
    };
    if handoff.get("resumed_at").is_some_and(|v| !v.is_null()) {
        return Ok(None);
    }
    let route = handoff
        .get("relaunch")
        .cloned()
        .and_then(|v| serde_json::from_value::<Relaunch>(v).ok())
        .unwrap_or(Relaunch::Fresh);
    Ok(Some(route))
}

/// What a launch resolved before any window opened: the harness, the fleet
/// server and session, and the spelled command.
struct LaunchPrep {
    target: Target,
    home: Option<PathBuf>,
    /// The launch names no home (`LaunchHome::cleared`).
    home_implicit: bool,
    server: Server,
    session: String,
    command: LaunchCommand,
    floor: SessionFloor,
    /// How the launch directory came to be trusted, where a home was
    /// prepared.
    trust: Option<trust::Route>,
}

/// Resolve everything a local launch can refuse before it opens a window:
/// the harness, the fleet server and session, the working directory, the
/// home with its trust record and harness gate, the program and the brief
/// file, and the command. A failure here is knowable
/// before the effect starts anything. A resumed session is the floor the
/// outcome binds (its id is known), and the command continues it rather
/// than fixing a fresh id.
fn prepare_launch(
    operation: &Operation,
    settings: &Settings,
    r: &LaunchLane,
    fleet: Fleet,
    route: &Route,
) -> std::result::Result<LaunchPrep, Unready> {
    let harness = Harness::parse(&r.harness)
        .ok_or_else(|| refused("harness-unknown", &[("harness", &r.harness)]))?;
    let cwd = PathBuf::from(&r.mail_root);
    check_directory("cwd-missing", &cwd)?;
    // The file the line reads is the brief closed by the unattended words,
    // held beside the intent.
    let brief = match &r.brief_file {
        Some(file) => Some(
            operation
                .hold_brief(&unattended(&read_brief(file)?))
                .map_err(Error::from)?,
        ),
        None => None,
    };
    let recorded = match route {
        Route::Resume { home, .. } => home.clone(),
        Route::Fresh { .. } | Route::Refuse { .. } => None,
    };
    // A seat of another harness bills the launch and is not its home: a Pi
    // lane on a Claude seat runs on Pi's own root, kept as an accountless
    // launch keeps it, so the root stands before the gate reads it.
    let kept = match &r.account {
        Some(_) if harness.account_var(r.model.as_deref()) == harness.home_var() => None,
        Some(_) => accountless_kept(settings, harness, None, None),
        None => accountless_kept(settings, harness, recorded, fleet.served.as_deref()),
    };
    let homes = launch_home(
        settings,
        harness,
        r.account.as_deref(),
        r.model.as_deref(),
        kept.as_ref(),
        &cwd,
    )?;
    let floor = match (route, &homes.sessions) {
        (Route::Resume { session_id, .. }, _) => SessionFloor::Fixed(session_id.clone()),
        (Route::Fresh { .. }, Some(home)) => operation.session_floor(harness, home, &cwd)?,
        (Route::Fresh { .. }, None) => SessionFloor::Baseline(Vec::new()),
        (Route::Refuse { .. }, _) => {
            unreachable!("a refuse route fails before prepare_launch")
        }
    };
    let permission = r.permission_words();
    let (mut intent, _) = build_launch(
        settings,
        &Spec {
            harness,
            home: homes.named.as_deref(),
            account: homes.account.as_deref(),
            model: r.model.as_deref(),
            effort: r.effort.as_deref(),
            cwd: &cwd,
            brief: brief.as_deref(),
            permission: None,
            question_tool: QuestionTool::Off,
            compaction: lane_compaction(harness),
            session_id: match route {
                Route::Fresh { .. } => floor.session_id(),
                Route::Resume { .. } | Route::Refuse { .. } => None,
            },
            extra_args: &permission,
        },
    )?;
    lane_words(&mut intent, &cwd);
    if homes.cleared {
        intent.env_remove.push(harness.home_var().to_owned());
    }
    if let Route::Resume { session_id, .. } = route {
        intent.resume = Some(Resume {
            session_id: session_id.clone(),
            session_file: None,
        });
    }
    let command = agent_runtime::launch::build(&intent)?;
    check_program(&command)?;
    Ok(LaunchPrep {
        target: Target::new(settings, harness),
        home: homes.sessions,
        home_implicit: homes.cleared,
        server: fleet.server,
        session: fleet.session,
        command,
        floor,
        trust: homes.trust,
    })
}

/// The key a harness gate's refusal stands under where its outcome names one
/// word.
pub(super) const GATE_REFUSED: &str = "launch-gate-refused";

/// A preparation refusal as the launch's observation: its key as `cause`
/// and every value it acted on beside it (the path, the harness, the
/// program), so the record a person reads names what to repair; a
/// dependency's own cause rides as `detail`, or as `detail_cause` where the
/// refusal names a `detail` of its own.
fn refusal_observation(e: &crate::error::Error) -> Value {
    let fields = e.fields();
    let cause_as = if fields.iter().any(|(field, _)| field == "detail") {
        "detail_cause"
    } else {
        "detail"
    };
    let mut observation = json!({"cause": e.key()});
    for (field, value) in fields {
        let field = if field == "cause" { cause_as } else { &field };
        observation[field] = json!(value);
    }
    observation
}

/// Why a launch cannot run where its preparation put it.
pub(super) enum Unready {
    /// A home, account, trust record or other precondition that refused.
    Refused(crate::error::Error),
    /// The harness gate's refusal, its key then its fields.
    Gate(String),
}

impl From<crate::error::Error> for Unready {
    fn from(e: crate::error::Error) -> Unready {
        Unready::Refused(e)
    }
}

impl From<agent_runtime::Error> for Unready {
    fn from(e: agent_runtime::Error) -> Unready {
        Unready::Refused(e.into())
    }
}

/// A home a launch with no account keeps, and whether the launch names it
/// to the child: every kept home is named but an accountless Claude
/// launch's implicit default config dir, which names none.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Kept {
    pub home: PathBuf,
    pub named: bool,
}

/// The home an accountless launch of `harness` keeps, decided once for the
/// lane launch, its relaunch route and the transfer: the home a resumed
/// session ran under, `recorded`, in its mode; else, for Codex and Claude,
/// `served`, the home the fleet server hands its panes (`CODEX_HOME`,
/// `CLAUDE_CONFIG_DIR`), named as found even where it spells the default;
/// else the inherited home, named, but Claude's implicit default config
/// dir, which the launch names to nothing. `None` is a host with no home
/// directory at all.
pub(super) fn accountless_kept(
    settings: &Settings,
    harness: Harness,
    recorded: Option<Kept>,
    served: Option<&Path>,
) -> Option<Kept> {
    if recorded.is_some() {
        return recorded;
    }
    let served = match harness {
        Harness::Codex | Harness::Claude => served,
        Harness::Copilot | Harness::Pi => None,
    };
    served
        .map(|home| Kept {
            home: home.to_path_buf(),
            named: true,
        })
        .or_else(|| {
            inherited_home(settings, harness).map(|home| Kept {
                home,
                named: harness != Harness::Claude,
            })
        })
}

/// The fleet server a local window opens on, its session, and the home it
/// hands an accountless Codex or Claude pane, resolved once before the
/// route and the preparation read them.
pub(super) struct Fleet {
    pub server: Server,
    pub session: String,
    pub served: Option<PathBuf>,
}

/// What a launch of `harness` runs under, a lane's or a controller's.
pub(super) struct LaunchHome {
    /// The home the launch names: prepared, or an accountless Claude
    /// launch's config dir as it was found.
    pub named: Option<PathBuf>,
    /// The launch names no home and the child must not inherit the
    /// harness's home variable: an accountless Claude launch on its implicit
    /// default config dir, since a named config dir, even `$HOME/.claude`,
    /// reads its own `.claude.json` where the implicit default reads the one
    /// in the home directory. Recorded, so a resume repeats the mode.
    pub cleared: bool,
    /// The account the launch bills where its variable is not the home's.
    pub account: Option<PathBuf>,
    /// Where its sessions are read: the named home, else the harness's own
    /// default root.
    pub sessions: Option<PathBuf>,
    /// How the launch directory came to be trusted, where a home was
    /// prepared.
    pub trust: Option<trust::Route>,
}

/// The home a harness runs under where its launch names no account, read as
/// the fleet's launchers read it: Copilot's `COPILOT_HOME` and Pi's
/// `PI_CODING_AGENT_DIR` as the settings load reads them (the environment,
/// the private file, the settings files), else the default under the home
/// directory. The launch names it to the child, so the child, its gate and
/// its session reader agree on one root whatever the fleet server's own
/// environment holds.
fn inherited_home(settings: &Settings, harness: Harness) -> Option<PathBuf> {
    let named = match harness {
        Harness::Copilot => settings.accounts.copilot_home.as_deref(),
        Harness::Pi => settings.accounts.pi_root.as_deref(),
        Harness::Claude | Harness::Codex => None,
    };
    named
        .filter(|home| !home.is_empty())
        .map(PathBuf::from)
        .or_else(|| operation::default_home(harness))
}

/// The home a launch of `harness` billing `account` on `model` names before
/// its trust record, and the account it bills where that account's variable
/// is not the home's; never the cwd. The account is the home where its
/// variable is the harness's own. Otherwise a Pi, Codex or Copilot launch
/// runs on `kept`, which must stand: the home it keeps where no account
/// names one (`accountless_kept`'s answer: the home a resumed session was
/// found under, the `CODEX_HOME` the fleet server's panes inherit, else
/// the inherited home) or the Pi root a controller's succession keeps
/// whatever account bills it; a Pi seat with no root kept rides in the
/// account alone, on its inherited root. Codex and Copilot ask a trust
/// question under theirs. An accountless Claude launch names none here, so
/// no trust record is ever written into the operator's own config;
/// `launch_home` names the config dir it keeps as found.
fn named_home(
    settings: &Settings,
    harness: Harness,
    account: Option<&str>,
    model: Option<&str>,
    kept: Option<&Path>,
) -> Result<(Option<PathBuf>, Option<PathBuf>)> {
    if harness.account_var(model) == harness.home_var()
        && let Some(account) = account
    {
        return Ok((Some(PathBuf::from(account)), None));
    }
    let billed = account.map(PathBuf::from);
    let home = match (harness, kept) {
        (Harness::Pi | Harness::Codex | Harness::Copilot, Some(kept)) => {
            check_directory("home-missing", kept)?;
            Some(kept.to_path_buf())
        }
        (Harness::Pi | Harness::Codex | Harness::Copilot, None) => {
            inherited_home(settings, harness)
        }
        (Harness::Claude, _) => None,
    };
    Ok((home, billed))
}

/// The home a launch of `harness` runs under, prepared before its window
/// opens: the trust record for `cwd` under the named home, and a private
/// Codex home built under the account where the account's own config does
/// not trust `cwd`, its sessions linked from the account's. An accountless
/// Claude launch runs on the config dir it keeps where `kept` names it (the
/// fleet server's, or the one a resumed session ran under), named as found
/// and never prepared, so nothing is written into the operator's config;
/// on its implicit default, the variable cleared, where `kept` names none
/// (`accountless_kept` decides which). The harness
/// gate then judges what the harness needs beyond its trust record under
/// the home its sessions are read from.
pub(super) fn launch_home(
    settings: &Settings,
    harness: Harness,
    account: Option<&str>,
    model: Option<&str>,
    kept: Option<&Kept>,
    cwd: &Path,
) -> std::result::Result<LaunchHome, Unready> {
    let (home, billed) = named_home(
        settings,
        harness,
        account,
        model,
        kept.map(|k| k.home.as_path()),
    )?;
    let trusted = home
        .map(|home| prepare_trust(harness, &home, cwd))
        .transpose()?;
    let mut named = trusted.as_ref().map(|t| t.home.clone());
    let mut cleared = false;
    if let (Harness::Claude, None) = (harness, account) {
        named = kept.filter(|kept| kept.named).map(|kept| kept.home.clone());
        cleared = named.is_none();
    }
    let sessions = named.clone().or_else(|| operation::default_home(harness));
    gate::local(harness, sessions.as_deref(), cwd).map_err(Unready::Gate)?;
    Ok(LaunchHome {
        sessions,
        named,
        cleared,
        account: billed,
        trust: trusted.map(|t| t.route),
    })
}

/// The trust record a launch of `harness` under `home` needs for `cwd`,
/// made before the window opens; its refusal is the launch's.
#[allow(
    clippy::disallowed_methods,
    reason = "the launch's trust record, written before the window it serves opens, its refusal the launch's own"
)]
fn prepare_trust(harness: Harness, home: &Path, cwd: &Path) -> Result<trust::Prepared> {
    Ok(trust::prepare(harness, home, cwd)?)
}

/// A lane runs with the harness's own compaction off where it has a word
/// for it, since orch's handoff mark judges the window.
fn lane_compaction(harness: Harness) -> Compaction {
    match harness.compaction_off_words() {
        Some(_) => Compaction::Off,
        None => Compaction::Native,
    }
}

/// The lane's two kendex variables: the owner's email cleared, so a lane
/// never writes as the owner, and the lane's origin, the directory the
/// hook and the mailbox read the lane by.
fn lane_words(intent: &mut LaunchIntent, cwd: &Path) {
    intent
        .env
        .insert("KENDEX_USER_EMAIL".to_owned(), String::new());
    intent
        .env
        .insert("KENDEX_LANE_ORIGIN".to_owned(), cwd.display().to_string());
}

/// An outcome once the window exists: the pane is carried on `launch` so a
/// reconcile can re-observe it, and written on the observation. The server
/// start travels with the pane, so the lane's pane key carries it.
fn with_pane(opened: &OpenedPane, outcome: EffectOutcome) -> EffectOutcome {
    let mut outcome = outcome;
    outcome.annotate("pane", json!(opened.pane));
    outcome.annotate("server", json!(opened.server));
    outcome.with_wire(Wire {
        launch: Some(LaunchIdentity {
            pane: Some(opened.pane.clone()),
            server: Some(opened.server),
            server_start: Some(opened.server_start),
            pid: None,
            start: None,
        }),
        ..Wire::default()
    })
}

/// The pane stands but nothing is settled: `unconfirmed`, the pane kept for
/// the next reconcile with the obligations the intent recorded.
fn launch_pane_unconfirmed(
    operation: Operation,
    opened: &OpenedPane,
    observation: Value,
) -> EffectOutcome {
    with_pane(opened, operation.hold(observation))
}

/// The recorded pane read gone, or its server gone or replaced with it: the
/// pane was discharged by that read, and the identity the set recorded is
/// read here through the one identity reader, never settled by the pane's
/// disappearance: `failed` once both are discharged, else `unconfirmed` with
/// the identity standing. The pane stays on `launch` for the record.
fn launch_pane_gone(
    mut operation: Operation,
    opened: &OpenedPane,
    cause: &'static str,
    observation: Value,
) -> Result<EffectOutcome> {
    let mut observation = observation;
    observation["cause"] = json!(cause);
    if let Some(identity) = &opened.identity {
        observation["identity"] = json!(match operation.read_process(identity)? {
            ProcessRead::Live => "live",
            ProcessRead::Gone => "gone",
            ProcessRead::Stale { .. } => "stale",
            ProcessRead::Unreadable { .. } => "unreadable",
        });
    }
    operation.read_receipt()?;
    // Every recorded process is read by its own key, the receipt's registered
    // pid and any foreground read on the way included: a survivor still live
    // holds the launch, one read gone lets it settle.
    operation.read_standing_processes()?;
    Ok(with_pane(
        opened,
        operation.settle(Word::Failed, observation),
    ))
}

/// The host a request names: a local window, the cloud kind, or a
/// provider's path. `L` is what a local window carries once a launch has
/// resolved it, its fleet server; a reconcile's reading of a record
/// carries nothing.
enum Surface<'a, L = ()> {
    Local(L),
    Cloud,
    Hosted(&'a str),
}

/// The surface a record's or a request's `host` names.
fn surface_of(host: Option<&str>) -> Surface<'_> {
    match host {
        None | Some("") | Some("local") => Surface::Local(()),
        Some(CLOUD_KIND) => Surface::Cloud,
        Some(provider) => Surface::Hosted(provider),
    }
}

/// The scripts directory the provider and the worktree package run from.
fn scripts_dir(settings: &Settings) -> PathBuf {
    crate::watch::overseer::scripts_dir(&settings.roots.project)
}

pub(super) fn launch_effect(run: &Run, intent: &Intent, r: &LaunchLane) -> Result<EffectOutcome> {
    let operation = Operation::open(run, intent)?;
    let (lane, _) = lane_for_intent(run.path, &intent.id)?;
    // A local window's fleet server is resolved before the route, which
    // reads a record with no home under the home that server hands its
    // panes; one that cannot be resolved fails before anything opens.
    let surface = match surface_of(r.host.as_deref()) {
        Surface::Local(()) => match local_fleet(run, &operation, r) {
            Ok(fleet) => Surface::Local(fleet),
            Err(e) => return Ok(operation.settle(Word::Failed, refusal_observation(&e))),
        },
        Surface::Cloud => Surface::Cloud,
        Surface::Hosted(provider) => Surface::Hosted(provider),
    };
    let served = match &surface {
        Surface::Local(fleet) => fleet.served.as_deref(),
        Surface::Cloud | Surface::Hosted(_) => None,
    };
    let route = relaunch_route(run, &lane, r, served)?;
    // A destination session store that could not be read, or a bound
    // session another directory owns, refuses before any window opens,
    // nothing recorded.
    if let Route::Refuse { cause } = &route {
        return Ok(operation.settle(Word::Failed, json!({"cause": cause})));
    }
    // Whether the launch re-enters a standing record, as the transition
    // judged it: the provider then reuses the worktree it holds.
    let relaunch = intent.selection.as_ref().is_some_and(|s| s.relaunch);
    let mut outcome = match surface {
        Surface::Local(fleet) => local_launch(run, operation, r, fleet, &route)?,
        Surface::Hosted(provider) => hosted_launch(run, operation, r, provider, relaunch)?,
        Surface::Cloud => cloud_launch(run, operation, &lane, r)?,
    };
    outcome.annotate("route", json!(route.word()));
    if let Some(cause) = route.cause() {
        outcome.annotate("route_cause", json!(cause));
    }
    Ok(outcome)
}

/// The window on the fleet server and the wait for the harness in it: the
/// one route a local lane and the ssh client of a hosted one share. The
/// phases are recorded before each wait, so a crash leaves a step a
/// reconcile can resume from.
#[allow(clippy::too_many_arguments)]
fn open_and_confirm(
    mut operation: Operation,
    r: &LaunchLane,
    server: &Server,
    session: &str,
    floor: &SessionFloor,
    command: &LaunchCommand,
    harness: Harness,
    owns: &dyn Fn(&str) -> bool,
    sessions: Sessions,
) -> Result<EffectOutcome> {
    // The server, the floor and the home the sessions are read under are
    // recorded before the window opens, so a crash in the open leaves a
    // phase a reconcile can resume: it adopts the pane this launch's receipt
    // names, fails the recorded pane that never registered, or fails
    // `nothing-opened`.
    let (home, home_implicit) = match &sessions {
        Sessions::Store {
            home,
            home_implicit,
            ..
        } => (*home, *home_implicit),
        Sessions::Hosted { .. } => (None, false),
    };
    let opening = match operation.opening(server, floor, None, home, home_implicit) {
        Ok(opening) => opening,
        Err(e) => {
            return Ok(operation.settle(Word::Failed, refusal_observation(&Error::from(e))));
        }
    };
    operation.record_phase(Phase::Opening {
        opening: opening.clone(),
    })?;
    let pane = match operation.open_window(server, session, &r.item, command, &opening)? {
        Ok(pane) => pane,
        // Refused before the launcher was asked: `arm` failed before the
        // receipt or window was recorded, so nothing stands and the launch
        // fails with its cause.
        Err(OpenRefusal::Refused(e)) => {
            return Ok(operation.settle(Word::Failed, refusal_observation(&Error::from(e))));
        }
        // The launcher was asked and did not answer: a window may stand
        // that nothing registers, an obligation the reconcile reads; the
        // intent stays open with it.
        Err(OpenRefusal::Unanswered { refusal }) => {
            return Ok(operation.hold(json!({
                "phase": "opening",
                "note": "window-unread",
                "cause": refusal.key(),
            })));
        }
        // The window opened and its line did not type. Its one pane was
        // closed by exact id: closed or gone, the launch fails with nothing
        // standing; a close the host did not answer for leaves the recorded
        // pane for the reconcile at `opening`, the intent open.
        Err(OpenRefusal::LineUnsent { refusal }) => {
            let mut outcome = operation.settle(
                Word::Failed,
                json!({
                    "phase": "opening",
                    "note": "launch-line-unsent",
                    "refusal": refusal.key(),
                }),
            );
            if !outcome.notes("cause") {
                outcome.annotate("cause", json!("launch-line-unsent"));
            }
            return Ok(outcome);
        }
    };
    let mut opened = opening.into_opened(pane.id.clone(), None);
    // The window exists and the line is typed: the window-opened phase is
    // recorded before the wait, the receipt standing until it is read.
    operation.record_phase(Phase::WindowOpened {
        opened: opened.clone(),
    })?;
    let polled = operation.await_state(&pane, harness, owns, None, &up)?;
    // The identity the judge read is the attempt's from here: written into
    // the phase with the receipt read, so a reconcile of an intent left open
    // confirms that process and no other.
    if let Polled::Ready { identity }
    | Polled::Pending {
        identity: Some(identity),
        ..
    } = &polled
    {
        operation.record_identity(&mut opened, identity)?;
    }
    launch_outcome(
        operation, harness, sessions, session, &r.item, &opened, polled,
    )
}

/// The fleet server a local lane's window opens on, and the home it hands
/// an accountless Codex or Claude pane, read from the server's own
/// environment.
fn local_fleet(run: &Run, operation: &Operation, r: &LaunchLane) -> Result<Fleet> {
    let doc_session = fleet_tmux_session(run.path)?;
    let (server, session) = operation.fleet_server(doc_session.as_deref())?;
    let served = match (Harness::parse(&r.harness), &r.account) {
        (Some(harness @ (Harness::Codex | Harness::Claude)), None) => {
            operation::server_home(&server, &session, harness)?
        }
        (Some(Harness::Codex | Harness::Claude | Harness::Copilot | Harness::Pi) | None, _) => None,
    };
    Ok(Fleet {
        server,
        session,
        served,
    })
}

/// A local lane: the launch record written before the window, then the
/// window and the harness in it.
fn local_launch(
    run: &Run,
    operation: Operation,
    r: &LaunchLane,
    fleet: Fleet,
    route: &Route,
) -> Result<EffectOutcome> {
    let cwd = PathBuf::from(&r.mail_root);
    let prep = match prepare_launch(&operation, run.settings, r, fleet, route) {
        Ok(prep) => prep,
        // A harness, session, directory, program or brief the effect cannot
        // resolve: `failed` before anything opens, never a bare refusal.
        Err(Unready::Refused(e)) => {
            return Ok(operation.settle(Word::Failed, refusal_observation(&e)));
        }
        Err(Unready::Gate(cause)) => {
            return Ok(operation.settle(Word::Failed, json!({"cause": cause})));
        }
    };
    // The marker, the mailbox and the refresh record stand before any
    // window opens: the hook judges the lane by them from its first turn,
    // and a crash between here and the window leaves a marker the next
    // launch rewrites, never a lane with no mail.
    let resumed = match route {
        Route::Resume { session_id, .. } => Some(marker::Resumed {
            harness: &r.harness,
            session_id,
        }),
        Route::Fresh { .. } | Route::Refuse { .. } => None,
    };
    if let Err(e) = marker::write(&cwd, &r.item, r.refresh, resumed) {
        return Ok(operation.settle(Word::Failed, refusal_observation(&e)));
    }
    let target = prep.target.clone();
    let mut outcome = open_and_confirm(
        operation,
        r,
        &prep.server,
        &prep.session,
        &prep.floor,
        &prep.command,
        prep.target.harness,
        &|name| target.owns(name),
        Sessions::Store {
            home: prep.home.as_deref(),
            home_implicit: prep.home_implicit,
            cwd: &cwd,
        },
    )?;
    if let Some(route) = prep.trust {
        outcome.annotate("trust", json!(route));
    }
    Ok(outcome)
}

/// A hosted lane: the provider's `create` (and `wait`), the launch record
/// verified on the host, then the fleet window running the ssh client
/// whose one typed line starts the harness under the provider's prefix.
fn hosted_launch(
    run: &Run,
    mut operation: Operation,
    r: &LaunchLane,
    provider: &str,
    relaunch: bool,
) -> Result<EffectOutcome> {
    let failed = |operation: Operation, cause: &str| {
        Ok(operation.settle(Word::Failed, json!({"cause": cause})))
    };
    let scripts = scripts_dir(run.settings);
    let caps = match hosted::capabilities(&scripts, provider) {
        Ok(caps) => caps,
        Err(cause) => return failed(operation, &cause),
    };
    match caps.launch {
        Some(Launch::Ssh) => {}
        Some(Launch::CloudTask) => return failed(operation, "kind-unbuilt kind=codex-cloud"),
        Some(Launch::CloudSession) => {
            return failed(operation, "cloud-session-invalid host=provider");
        }
        Some(Launch::Window) | None => {
            return failed(operation, "host-capabilities-failed launch=window");
        }
    }
    // A provider that owns the harness's session itself opens no window
    // this effect could register: no route here starts it.
    if caps.pane == PaneKind::Verb {
        return failed(operation, "host-pane-verb");
    }
    let Some(harness) = Harness::parse(&r.harness) else {
        return failed(operation, "harness-unknown");
    };
    if let Err(cause) = gate::before_create(harness, r.model.as_deref(), provider) {
        return failed(operation, &cause);
    }
    let (Some(account), Some(repo)) = (r.account.as_deref(), r.repo.as_deref()) else {
        return failed(operation, "host-request-incomplete");
    };
    let doc_session = fleet_tmux_session(run.path)?;
    let (server, session) = match operation.fleet_server(doc_session.as_deref()) {
        Ok(found) => found,
        Err(e) => return Ok(operation.settle(Word::Failed, refusal_observation(&e))),
    };
    let cwd = PathBuf::from(&r.mail_root);
    if let Err(e) = check_directory("cwd-missing", &cwd) {
        return Ok(operation.settle(Word::Failed, refusal_observation(&e)));
    }
    let brief = match r.brief_file.as_deref().map(read_brief).transpose() {
        Ok(text) => text.map(|text| unattended(&text)),
        Err(e) => return Ok(operation.settle(Word::Failed, refusal_observation(&e))),
    };
    operation.record_phase(Phase::Preparing {
        step: HOST_CREATE.to_owned(),
        at: provider.to_owned(),
    })?;
    let mut created = hosted::create(
        &scripts, provider, &r.item, repo, &r.harness, account, relaunch,
    );
    if let Ok(made) = &created
        && made.preparing
        && let Err(asked) = hosted::wait(&scripts, provider, &r.item)
    {
        created = Err(asked);
    }
    let created = match created {
        Ok(created) => created,
        Err(hosted::Asked::Failed(cause)) => return failed(operation, &cause),
        // The provider may hold the item. Its create reuses the worktree it
        // holds, so the launch fails and the next launch's create settles
        // what this one may have left: nothing is held for a person.
        Err(hosted::Asked::Unknown(cause)) => {
            return Ok(operation.settle(
                Word::Failed,
                json!({"note": format!("{HOST_CREATE}-unknown"), "cause": cause, "at": provider}),
            ));
        }
    };
    if let Harness::Pi = harness
        && let Err(cause) = gate::hosted_pi(
            &scripts,
            provider,
            &r.item,
            created.pi_root.as_deref(),
            &created.path,
        )
    {
        return failed(operation, &cause);
    }
    if let Err(cause) = hosted_marker(&scripts, provider, &r.item, &created.path, r.refresh) {
        return failed(operation, &cause);
    }
    let command = match hosted_command(run.settings, r, harness, &created, brief.as_deref()) {
        Ok(command) => command,
        Err(e) => return Ok(operation.settle(Word::Failed, refusal_observation(&e))),
    };
    if let Err(e) = check_program(&command) {
        return Ok(operation.settle(Word::Failed, refusal_observation(&e)));
    }
    let target = Target::new(run.settings, harness);
    // A hosted lane's sessions live on its host and bind nothing here, so
    // every hosted launch starts the harness fresh and the context
    // continues through the handoff record.
    open_and_confirm(
        operation,
        r,
        &server,
        &session,
        &SessionFloor::Baseline(Vec::new()),
        &command,
        harness,
        &|name| name == "ssh" || target.owns(name),
        Sessions::Hosted {
            mail_root: created.path.clone(),
        },
    )
}

/// The launch record on the host, verified rather than trusted: the
/// worktree's `.git` names the clone's common git directory; the marker
/// there holds the worktree path, written where it does not; the
/// launch-fields record names the runtime the provider built, since the
/// lane's own workflow calls it on the host; a refresh lane's record holds
/// the path. `Err` is the cause.
fn hosted_marker(
    scripts: &Path,
    host: &str,
    item: &str,
    path: &str,
    refresh: bool,
) -> std::result::Result<(), String> {
    let gitfile_path = format!("{path}/.git");
    let gitfile = match hosted::fetch(scripts, host, item, &gitfile_path) {
        hosted::Answer::Live(text) => text,
        hosted::Answer::Gone => return Err(format!("host-gitfile-unread path={gitfile_path}")),
        hosted::Answer::Unreadable { cause } => {
            return Err(format!(
                "host-gitfile-unread path={gitfile_path} cause={cause}"
            ));
        }
    };
    let Some((git_dir, common)) = marker::git_dirs_of(&gitfile) else {
        return Err(format!(
            "host-gitfile-invalid path={gitfile_path} value={}",
            gitfile.trim_end()
        ));
    };
    let name = marker::item_name(item).map_err(|e| e.key().to_owned())?;
    let marker = marker::marker_path(&common, name).display().to_string();
    let root_line = format!("{path}\n");
    let standing = match hosted::fetch(scripts, host, item, &marker) {
        hosted::Answer::Live(text) => text == root_line,
        hosted::Answer::Gone => false,
        hosted::Answer::Unreadable { cause } => {
            return Err(format!("marker-failed path={marker} cause={cause}"));
        }
    };
    if !standing {
        hosted::put(scripts, host, item, &marker, root_line.as_bytes())
            .map_err(|cause| format!("marker-failed path={marker} cause={cause}"))?;
        match hosted::fetch(scripts, host, item, &marker) {
            hosted::Answer::Live(text) if text == root_line => {}
            hosted::Answer::Live(_) | hosted::Answer::Gone => {
                return Err(format!("marker-failed path={marker} cause=read-back"));
            }
            hosted::Answer::Unreadable { cause } => {
                return Err(format!("marker-failed path={marker} cause={cause}"));
            }
        }
    }
    let launch = marker::launch_path(&common, name).display().to_string();
    let record = match hosted::fetch(scripts, host, item, &launch) {
        hosted::Answer::Live(text) => text,
        hosted::Answer::Gone => {
            return Err(format!(
                "host-runtime-unbuilt path={launch} cause=record-missing"
            ));
        }
        hosted::Answer::Unreadable { cause } => {
            return Err(format!("marker-failed path={launch} cause={cause}"));
        }
    };
    let fields: Value = serde_json::from_str(&record)
        .map_err(|e| format!("marker-failed path={launch} cause={e}"))?;
    let built = fields
        .get("runtime")
        .and_then(Value::as_str)
        .is_some_and(|binary| binary.starts_with('/'));
    if !built {
        return Err(format!(
            "host-runtime-unbuilt path={launch} cause=runtime-unnamed"
        ));
    }
    if refresh {
        let record = marker::refresh_path(&git_dir).display().to_string();
        hosted::put(scripts, host, item, &record, root_line.as_bytes())
            .map_err(|cause| format!("marker-failed path={record} cause={cause}"))?;
    }
    Ok(())
}

/// The ssh client's command for the fleet window: one typed line, `ssh -t
/// TARGET LINE`, where LINE is the provider's prefix followed by the
/// harness line the builder spells for the worktree on the host, quoted as
/// one word. The brief travels inline, since the file is on this machine;
/// the harness is the host's own program by name; no account variable
/// reaches the host, whose prefix carries the credential it placed. A Pi
/// lane on the Copilot pool runs the session-environment step first, in
/// the same login shell.
fn hosted_command(
    settings: &Settings,
    r: &LaunchLane,
    harness: Harness,
    created: &hosted::Created,
    brief: Option<&str>,
) -> Result<LaunchCommand> {
    let remote_cwd = PathBuf::from(&created.path);
    let permission = r.permission_words();
    let (mut intent, _) = build_launch(
        settings,
        &Spec {
            harness,
            home: None,
            account: None,
            model: r.model.as_deref(),
            effort: r.effort.as_deref(),
            cwd: &remote_cwd,
            brief: r.brief_file.as_deref(),
            permission: None,
            question_tool: QuestionTool::Off,
            compaction: lane_compaction(harness),
            session_id: None,
            extra_args: &permission,
        },
    )?;
    intent.program = None;
    lane_words(&mut intent, &remote_cwd);
    let mut remote = agent_runtime::launch::build(&intent)?;
    if let (Some(index), Some(text)) = (remote.brief_arg, brief) {
        remote.args[index] = text.to_owned();
        remote.brief_arg = None;
        remote.brief_path = None;
    }
    let mut shell_line = remote.shell_line();
    if harness == Harness::Pi
        && accounts::pick_pool("pi", r.model.as_deref().unwrap_or("")) == "copilot"
    {
        shell_line = format!("{} && {shell_line}", PI_SESSION_ENV_STEP.trim_end());
    }
    let line = format!("{} {}", created.prefix, shell_quote(&shell_line));
    // The client by the path this process finds it at: the pane's shell
    // runs it, and its search path is the fleet server's, not this one's.
    let program = on_path("ssh")
        .map(|p| p.display().to_string())
        .unwrap_or_else(|| "ssh".to_owned());
    Ok(LaunchCommand {
        program,
        args: vec!["-t".to_owned(), created.target.clone(), line],
        env: Default::default(),
        env_remove: Vec::new(),
        cwd: PathBuf::from(&r.mail_root),
        brief_arg: None,
        brief_path: None,
    })
}

/// The file `name` resolves to on this process's search path, if any.
fn on_path(name: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|path| {
        std::env::split_paths(&path)
            .map(|dir| dir.join(name))
            .find(|candidate| std::fs::metadata(candidate).is_ok_and(|m| m.is_file()))
    })
}

/// A cloud session: the item's branch pushed from its worktree, the session
/// created through the Claude CLI's own answer under the lane's account,
/// its id the record. No window opens; the overseer reaches the session
/// through `send`.
fn cloud_launch(
    run: &Run,
    mut operation: Operation,
    lane: &Lane,
    r: &LaunchLane,
) -> Result<EffectOutcome> {
    let failed = |operation: Operation, cause: &str| {
        Ok(operation.settle(Word::Failed, json!({"cause": cause})))
    };
    if r.refresh {
        return failed(operation, "cloud-refresh-unsupported");
    }
    if Harness::parse(&r.harness) != Some(Harness::Claude) {
        return failed(operation, "cloud-session-invalid cause=harness");
    }
    if lane.session_id.is_some() || lane.running_at.is_some() {
        return failed(operation, "cloud-session-invalid cause=relaunch");
    }
    let Some(brief_file) = r.brief_file.as_deref() else {
        return failed(operation, "cloud-brief-missing");
    };
    let brief = match read_brief(brief_file) {
        Ok(text) => text,
        Err(e) => return Ok(operation.settle(Word::Failed, refusal_observation(&e))),
    };
    let Some(account) = r.account.as_deref() else {
        return failed(operation, "host-request-incomplete");
    };
    let scripts = scripts_dir(run.settings);
    match hosted::capabilities(&scripts, CLOUD_KIND) {
        Ok(caps) if caps.launch == Some(Launch::CloudSession) => {}
        Ok(_) => return failed(operation, "host-capabilities-failed launch=cloud-session"),
        Err(cause) => return failed(operation, &cause),
    }
    let claim_root = PathBuf::from(&r.mail_root);
    for file in [
        Path::new(account).join("settings.json"),
        claim_root.join(".claude").join("settings.json"),
    ] {
        if bundle_forced(&file) {
            return failed(
                operation,
                &format!("cloud-bundle-risk cause=settings path={}", file.display()),
            );
        }
    }
    let origin = git_line(&claim_root, "origin-url", &["remote", "get-url", "origin"])
        .ok()
        .and_then(|url| crate::ops::origin_slug(&url));
    let Some(origin) = origin else {
        return failed(operation, "cloud-bundle-risk cause=remote");
    };
    let worktree = run.settings.worktree_cli.clone();
    operation.record_phase(Phase::Preparing {
        step: WORKTREE_CREATE.to_owned(),
        at: claim_root.display().to_string(),
    })?;
    let wt = match package(
        &worktree,
        &claim_root,
        "create",
        &["create", &r.item, "--no-checkout"],
        CLOUD_PREPARE_BOUND,
    ) {
        Ok(path) => PathBuf::from(path),
        Err(Package::Owned) => return failed(operation, "item-owned exit=75"),
        Err(Package::Failed(cause)) => {
            return failed(operation, &format!("worktree-failed {cause}"));
        }
        Err(Package::Unknown(cause)) => {
            return Ok(preparing_held(
                operation,
                WORKTREE_CREATE,
                &claim_root.display().to_string(),
                &cause,
            ));
        }
    };
    let Ok(branch) = git_line(&wt, "branch", &["symbolic-ref", "--short", "HEAD"]) else {
        return failed(operation, "cloud-branch-unread");
    };
    let prompt = format!(
        "{brief}\n\n{}",
        CLOUD_SESSION_TEXT
            .trim_end_matches('\n')
            .replace("{branch}", &branch)
    );
    operation.record_phase(Phase::Preparing {
        step: WORKTREE_PUSH.to_owned(),
        at: wt.display().to_string(),
    })?;
    if let Err(cause) = package(
        &worktree,
        &claim_root,
        "push",
        &["push", &r.item, "--set-upstream"],
        CLOUD_PREPARE_BOUND,
    ) {
        let cause = match cause {
            Package::Owned => "exit=75".to_owned(),
            Package::Failed(cause) => cause,
            Package::Unknown(cause) => {
                return Ok(preparing_held(
                    operation,
                    WORKTREE_PUSH,
                    &wt.display().to_string(),
                    &cause,
                ));
            }
        };
        return failed(operation, &format!("cloud-push-failed {cause}"));
    }
    let (_, command) = build_launch(
        run.settings,
        &Spec {
            harness: Harness::Claude,
            home: None,
            account: Some(Path::new(account)),
            model: r.model.as_deref(),
            effort: r.effort.as_deref(),
            cwd: &wt,
            brief: None,
            permission: Some(Permission::Native),
            question_tool: QuestionTool::Keep,
            compaction: Compaction::Native,
            session_id: None,
            extra_args: &[],
        },
    )?;
    let answer_by = operation.stamp_after(CLOUD_BOUND);
    operation.record_phase(Phase::CloudCreate {
        worktree: wt.display().to_string(),
        answer_by: Some(answer_by.clone()),
    })?;
    let session = match cloud_create(&command, &prompt) {
        Created::Session(id) => id,
        Created::Refused(cause) => return failed(operation, &cause),
        // A session may exist that nothing here can name: the intent stays
        // open, the lane preparing, so no second create starts beside it.
        Created::Unknown(cause) => {
            return Ok(operation.hold(json!({
                "note": CLOUD_CREATE_UNKNOWN,
                "cause": cause,
                "worktree": wt.display().to_string(),
                "answer_by": answer_by,
            })));
        }
    };
    let mut repositories: BTreeSet<String> = BTreeSet::new();
    repositories.insert(origin.to_ascii_lowercase());
    if let Some(repo) = r.repo.as_deref() {
        repositories.insert(repo.to_ascii_lowercase());
    }
    repositories.extend(
        run.settings
            .reads
            .connected_repos
            .iter()
            .map(|r| r.to_ascii_lowercase()),
    );
    let url = format!("https://claude.ai/code/{session}");
    let outcome = operation.settle(
        Word::Confirmed,
        json!({
            "cloud_session": session,
            "cloud_repo_access": {"repositories": repositories, "url": url},
        }),
    );
    Ok(outcome.with_wire(Wire {
        session_id: Some(session),
        mail_root: Some(wt.display().to_string()),
        ..Wire::default()
    }))
}

/// Whether a Claude settings file forces a bundled checkout
/// (`env.CCR_FORCE_BUNDLE` set to `1`); a file that stands and cannot be
/// read is read as one that sets it, since the session could then push
/// nothing.
fn bundle_forced(file: &Path) -> bool {
    match std::fs::read_to_string(file) {
        Ok(text) => serde_json::from_str::<Value>(&text).map_or(true, |settings| {
            settings
                .get("env")
                .and_then(|env| env.get("CCR_FORCE_BUNDLE"))
                .is_some_and(|v| match v {
                    Value::String(s) => s == "1",
                    Value::Number(n) => n.as_u64() == Some(1),
                    Value::Null | Value::Bool(_) | Value::Array(_) | Value::Object(_) => false,
                })
        }),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
        Err(_) => true,
    }
}

/// One line of `git -C dir ARGS`, or `Err` with git's first stderr line.
#[allow(
    clippy::disallowed_methods,
    reason = "the cloud launch's reads of the checkout's origin and the worktree's branch, through the one runner; they act on nothing"
)]
fn git_line(
    dir: &Path,
    operation: &'static str,
    args: &[&str],
) -> std::result::Result<String, String> {
    let dir = dir.display().to_string();
    let mut argv = vec!["-C", dir.as_str()];
    argv.extend_from_slice(args);
    let out = host::run_tagged_in(
        "launch",
        "git",
        Path::new("git"),
        operation,
        &argv,
        Place {
            cwd: None,
            env: &[],
        },
        CLOUD_PREPARE_BOUND,
    )
    .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(host::stderr_text(&out)
            .lines()
            .next()
            .unwrap_or("")
            .to_owned());
    }
    Ok(host::stdout_text(&out))
}

/// How the worktree package answered: the item is another session's (75),
/// a failure with its status and first stderr line (the package never
/// started included), or no answer: its bound passed or a signal ended it,
/// so the worktree or the push may stand.
enum Package {
    Owned,
    Failed(String),
    Unknown(String),
}

/// `worktree VERB ARGS` in `dir` through the one runner: its stdout, or how
/// it refused.
#[allow(
    clippy::disallowed_methods,
    reason = "the cloud launch's worktree creation and push through the worktree package, the one runner under the launch's tag"
)]
fn package(
    cli: &Path,
    dir: &Path,
    operation: &'static str,
    args: &[&str],
    bound: Duration,
) -> std::result::Result<String, Package> {
    let out = host::run_tagged_in(
        "launch",
        "worktree",
        cli,
        operation,
        args,
        Place {
            cwd: Some(dir),
            env: &[],
        },
        bound,
    )
    .map_err(|e| {
        if let agent_runtime::Error::NotStarted { .. } = e {
            Package::Failed(e.to_string())
        } else {
            Package::Unknown(e.to_string())
        }
    })?;
    let first = host::stderr_text(&out)
        .lines()
        .next()
        .unwrap_or("")
        .to_owned();
    match out.status.code() {
        Some(0) => Ok(host::stdout_text(&out)),
        Some(75) => Err(Package::Owned),
        Some(code) => Err(Package::Failed(format!("exit={code} {first}"))),
        None => Err(Package::Unknown(format!("exit=signal {first}"))),
    }
}

/// The note a cloud launch is held under where the create's answer was lost.
const CLOUD_CREATE_UNKNOWN: &str = "cloud-create-unknown";

/// The preparation steps a launch records before asking, each read as
/// `<step>-unknown` where its answer is lost.
const HOST_CREATE: &str = "host-create";
const WORKTREE_CREATE: &str = "worktree-create";
const WORKTREE_PUSH: &str = "worktree-push";

/// A launch held over a preparation that gave no answer: the step, where it
/// was asked and the runner's cause, for the person whose close settles it.
fn preparing_held(operation: Operation, step: &str, at: &str, cause: &str) -> EffectOutcome {
    operation.hold(json!({
        "note": format!("{step}-unknown"),
        "cause": cause,
        "at": at,
    }))
}

/// How the cloud session's create answered.
enum Created {
    Session(String),
    /// The CLI never started, exited non-zero or answered `ok: false`:
    /// nothing was created.
    Refused(String),
    /// No answer within the bound, an end by a signal, or an answer that
    /// names no session: a session may exist. No documented interface lists cloud sessions by id
    /// (`claude agents --json` names local sessions alone, and the session
    /// list is claude.ai/code's page), so nothing reads it back here.
    Unknown(String),
}

/// `claude [model words] --cloud --output-format json -p PROMPT` under the
/// account the command's environment names, with the bundling switch
/// cleared and the nonessential-traffic switch set, as the session send
/// runs the CLI; the `session_id` its JSON answer carries.
#[allow(
    clippy::disallowed_methods,
    reason = "the cloud session's creation through the Claude CLI, the one runner under the launch's tag; the record is written only once the CLI answered"
)]
fn cloud_create(command: &LaunchCommand, prompt: &str) -> Created {
    // The builder's environment removals reach the child through `env -u`,
    // since the runner only adds; the additions ride the same line.
    let mut args: Vec<String> = Vec::new();
    for name in &command.env_remove {
        args.push("-u".to_owned());
        args.push(name.clone());
    }
    for (name, value) in &command.env {
        args.push(format!("{name}={value}"));
    }
    args.push("CCR_FORCE_BUNDLE=".to_owned());
    args.push("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1".to_owned());
    args.push(command.program.clone());
    args.extend(command.args.iter().cloned());
    args.extend(
        ["--cloud", "--output-format", "json", "-p", prompt]
            .into_iter()
            .map(str::to_owned),
    );
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let out = match host::run_tagged_in(
        "launch",
        "claude",
        Path::new("env"),
        "cloud-create",
        &args,
        Place {
            cwd: Some(&command.cwd),
            env: &[],
        },
        CLOUD_BOUND,
    ) {
        Ok(out) => out,
        // A CLI that never started made nothing; one that started and gave
        // no answer may have.
        Err(e @ agent_runtime::Error::NotStarted { .. }) => {
            return Created::Refused(format!("cloud-create-refused cause={e}"));
        }
        Err(e) => return Created::Unknown(format!("cloud-create-unanswered cause={e}")),
    };
    if !out.status.success() {
        // A CLI ended by a signal gave no answer.
        let Some(code) = out.status.code() else {
            return Created::Unknown("cloud-create-unanswered cause=signal".to_owned());
        };
        return Created::Refused(format!(
            "cloud-create-refused exit={code} cause={}",
            host::stderr_text(&out).lines().next().unwrap_or("")
        ));
    }
    let answer: Value = match serde_json::from_str(&host::stdout_text(&out)) {
        Ok(answer) => answer,
        Err(e) => return Created::Unknown(format!("cloud-session-unread cause={e}")),
    };
    if answer.get("ok") == Some(&Value::Bool(false)) {
        return Created::Refused(format!(
            "cloud-create-refused cause={}",
            answer.get("error").and_then(Value::as_str).unwrap_or("")
        ));
    }
    match answer
        .get("session_id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
    {
        Some(id) => Created::Session(id.to_owned()),
        None => Created::Unknown("cloud-session-unread cause=no-session-id".to_owned()),
    }
}

/// Where a confirmed launch binds the lane's session: the native store under
/// the home for the directory, or none for a lane whose sessions live on
/// its host.
enum Sessions<'a> {
    Store {
        home: Option<&'a Path>,
        /// The launch named no home (`LaunchHome::cleared`).
        home_implicit: bool,
        cwd: &'a Path,
    },
    Hosted {
        mail_root: String,
    },
}

fn launch_outcome(
    operation: Operation,
    harness: Harness,
    sessions: Sessions,
    tmux_session: &str,
    item: &str,
    opened: &OpenedPane,
    polled: Polled,
) -> Result<EffectOutcome> {
    Ok(match polled {
        Polled::Ready { identity } => {
            let mut observation = json!({"pane": opened.pane, "server": opened.server});
            // The id the launch fixed, else the one lead session that
            // appeared for the cwd since the window opened, under the
            // account home or the harness's default home. Zero or several
            // bind none, noted as a succession notes them: a lane without a
            // session id never runs under a neighbour's. A hosted lane's
            // sessions are on its host and bind nothing here.
            let (session_id, mail_root) = match sessions {
                Sessions::Hosted { mail_root } => {
                    observation["note"] = json!("session-hosted");
                    (None, Some(mail_root))
                }
                Sessions::Store { home, cwd, .. } => {
                    let session_id = match &opened.session_id {
                        Some(id) => Some(id.clone()),
                        None => {
                            let home = home
                                .map(Path::to_path_buf)
                                .or_else(|| operation::default_home(harness));
                            match home {
                                None => {
                                    observation["note"] = json!("home-unresolved");
                                    None
                                }
                                Some(home) => {
                                    match operation.appeared_session(harness, &home, cwd, opened) {
                                        Binding::Bound(session) => Some(session.session_id),
                                        Binding::Absent => {
                                            observation["note"] = json!("session-unbound");
                                            None
                                        }
                                        Binding::Ambiguous(sessions) => {
                                            observation["note"] = json!("session-ambiguous");
                                            observation["sessions"] = json!(sessions);
                                            None
                                        }
                                        // The harness is up in its pane and its
                                        // store could not be read whole: the
                                        // launch is held at this phase with the
                                        // cause, the pane kept, and the
                                        // reconcile reads again.
                                        Binding::Unreadable { cause } => {
                                            observation["note"] = json!("session-store-unreadable");
                                            observation["cause"] = json!(cause);
                                            return Ok(launch_pane_unconfirmed(
                                                operation,
                                                opened,
                                                observation,
                                            ));
                                        }
                                    }
                                }
                            }
                        }
                    };
                    (session_id, None)
                }
            };
            // The lane launch publishes: its pane and identity pass to the
            // lane record and the whole set is consumed. A handle still
            // standing holds the launch at this phase.
            let wire_identity = identity.identity().clone();
            match operation.publish(Published::Lane, opened, &identity, observation.clone())? {
                Ok(outcome) => outcome.with_wire(Wire {
                    launch: Some(LaunchIdentity {
                        pane: Some(opened.pane.clone()),
                        server: Some(opened.server),
                        server_start: Some(opened.server_start),
                        pid: Some(wire_identity.pid as u64),
                        start: Some(wire_identity.start.clone()),
                    }),
                    session_id,
                    window: Some(format!("{tmux_session}:{item}")),
                    tmux_session: Some(tmux_session.to_owned()),
                    mail_root,
                    home: opened.home.clone(),
                    home_implicit: opened.home_implicit,
                    ..Wire::default()
                }),
                Err(operation) => {
                    observation["note"] = json!("launch-handles-standing");
                    launch_pane_unconfirmed(*operation, opened, observation)
                }
            }
        }
        Polled::Gone => launch_pane_gone(operation, opened, "pane-gone", json!({}))?,
        Polled::Pending { reading, state, .. } => {
            launch_pane_unconfirmed(operation, opened, pending_observation(&reading, &state))
        }
        Polled::Unobservable { cause } => launch_pane_unconfirmed(
            operation,
            opened,
            json!({"observed": "unobservable", "cause": cause}),
        ),
    })
}

/// The marker as it stands for a local lane whose launch ended before its
/// window: read back three-valued, so the outcome says whether the hook
/// will find the lane.
fn marker_reading(lane: &Lane) -> Option<Value> {
    let root = lane.mail_root.as_deref()?;
    Some(json!(match marker::read(Path::new(root), &lane.item) {
        Reading::Live(_) => "present",
        Reading::Gone => "absent",
        Reading::Unreadable { .. } => "unreadable",
    }))
}

/// The launch cells of the reconcile matrix: no phase means nothing opened,
/// `failed`; a recorded pane gone, or its server
/// replaced or gone, is `failed`; one an unanswering server still holds is
/// `unconfirmed`; one the harness holds at its composer or working is
/// `confirmed` with the identity read; any other reading is `unconfirmed`
/// with that reading and the pane marked present, which a close may
/// supersede.
pub(super) fn reconcile_launch(run: &Run, intent: &Intent) -> Result<EffectOutcome> {
    let (lane, item) = lane_for_intent(run.path, &intent.id)?;
    let mut operation = Operation::open(run, intent)?;
    // Every standing handle is read by its own key first.
    operation.read_standing(None)?;
    let Some(phase) = &intent.phase else {
        return Ok(operation.settle(
            Word::Failed,
            json!({"reconcile": "launch", "phase": "none", "cause": "nothing-opened"}),
        ));
    };
    // At `opening` the window may or may not have opened before this
    // process ended: adopt the pane the intent's receipt names, fail the
    // recorded pane that never registered, or fail `nothing-opened`. The
    // adopted pane is recorded as `window-opened` under the identity the
    // receipt proved and judged as any other, its receipt noted on the
    // outcome; a pending reading binds no pane and leaves the lane as found
    // for the next reconcile. The marker written before the window is read
    // back on the outcome of a launch that ended there.
    let local = matches!(surface_of(lane.host.as_deref()), Surface::Local(()));
    let (opened, registered) = match phase {
        // A cloud create asked and never answered, its asking process ended
        // included, may have made a session nothing here can name: the
        // launch stays held until a close supersedes it, and says until when
        // a session it makes may still appear.
        Phase::CloudCreate {
            worktree,
            answer_by,
        } => {
            return Ok(operation.hold(json!({
                "reconcile": "launch",
                "note": CLOUD_CREATE_UNKNOWN,
                "worktree": worktree,
                "answer_by": answer_by,
            })));
        }
        // A preparation asked and never answered, its asking process ended
        // included, may stand. A hosted provider's create reuses what it
        // holds, so that launch fails and the next create settles it; a
        // worktree step is held until a close.
        Phase::Preparing { step, at } => {
            let observation = json!({
                "reconcile": "launch",
                "note": format!("{step}-unknown"),
                "at": at,
            });
            return Ok(if step == HOST_CREATE {
                operation.settle(Word::Failed, observation)
            } else {
                operation.hold(observation)
            });
        }
        Phase::Opening { opening } => match operation.recover_opening(opening)? {
            Recovered::Adopted {
                pane,
                identity,
                registered,
            } => {
                let opened = opening.into_opened(pane.id.clone(), Some(identity));
                operation.record_phase(Phase::WindowOpened {
                    opened: opened.clone(),
                })?;
                (opened, Some(registered))
            }
            Recovered::Pending { note, cause } => {
                let mut outcome =
                    operation.hold(opening_observation("launch", note, cause.as_deref()));
                if local && let Some(marker) = marker_reading(&lane) {
                    outcome.annotate("marker", marker);
                }
                return Ok(outcome);
            }
            Recovered::Failed { note, cause } => {
                let mut outcome =
                    operation.settle(Word::Failed, opening_observation("launch", note, cause));
                if local && let Some(marker) = marker_reading(&lane) {
                    outcome.annotate("marker", marker);
                }
                return Ok(outcome);
            }
        },
        Phase::WindowOpened { opened }
        | Phase::Retired { opened }
        | Phase::Delivering { opened, .. }
        | Phase::Delivered { opened, .. }
        | Phase::IdentityRead { opened, .. } => (opened.clone(), None),
    };
    let mut outcome = judge_opened(operation, run, intent, &lane, &item, &opened)?;
    if let Some(registered) = registered {
        outcome.annotate("registered", registered);
    }
    Ok(outcome)
}

/// Judge the pane a launch intent names past `opening`: gone, or its server
/// replaced or gone, is `failed`; one an unanswering server still holds, or
/// one the host did not answer for, is `unconfirmed` with the cause; one
/// the harness holds at its composer or working is `confirmed` with the
/// identity read; any other reading is `unconfirmed` with that reading and
/// the pane marked present. With an identity in the phase, only that
/// process is the harness.
fn judge_opened(
    mut operation: Operation,
    run: &Run,
    intent: &Intent,
    lane: &Lane,
    item: &str,
    opened: &OpenedPane,
) -> Result<EffectOutcome> {
    let pane = match operation.observe_pane(opened)? {
        Observed::Unobservable { cause } => {
            return Ok(launch_pane_unconfirmed(
                operation,
                opened,
                json!({"reconcile": "launch", "observed": "unobservable", "cause": cause}),
            ));
        }
        Observed::Gone { cause } => {
            return launch_pane_gone(
                operation,
                opened,
                cause,
                json!({"reconcile": "launch", "observed": "gone"}),
            );
        }
        Observed::Present(pane) => pane,
    };
    let Some(harness) = pane_harness(lane, Some(intent)) else {
        return Ok(launch_pane_unconfirmed(
            operation,
            opened,
            json!({"reconcile": "launch", "observed": "present", "cause": "harness-unknown"}),
        ));
    };
    let target = Target::new(run.settings, harness);
    let hosted = matches!(surface_of(lane.host.as_deref()), Surface::Hosted(_));
    let owns = |name: &str| (hosted && name == "ssh") || target.owns(name);
    let (foreground, state) =
        match operation.read_pane(&pane, harness, &owns, opened.identity.as_ref())? {
            Reading::Live(read) => read,
            Reading::Gone => {
                return launch_pane_gone(
                    operation,
                    opened,
                    "pane-gone",
                    json!({"reconcile": "launch", "observed": "gone"}),
                );
            }
            Reading::Unreadable { cause } => {
                return Ok(launch_pane_unconfirmed(
                    operation,
                    opened,
                    json!({"reconcile": "launch", "observed": "unobservable", "cause": cause}),
                ));
            }
        };
    let Foreground {
        reading,
        harness: read,
    } = foreground;
    // An identity first read here is the attempt's from now on, written into
    // the phase and the set before the outcome.
    let mut opened = opened.clone();
    if opened.identity.is_none()
        && let Some(identity) = &read
    {
        operation.record_identity(&mut opened, identity)?;
    }
    let opened = &opened;
    if up(&state)
        && let Some(identity) = read
    {
        let cwd = lane
            .mail_root
            .as_deref()
            .map(PathBuf::from)
            .unwrap_or_default();
        // The sessions are read under the home the launch recorded on its
        // opening, never one resolved again in this process: a Pi lane on a
        // seat keeps Pi's root, never the seat. An opening that recorded none
        // reads the account the lane records.
        let home = opened
            .home
            .as_deref()
            .or(lane.account.as_deref())
            .map(PathBuf::from);
        let sessions = if hosted {
            Sessions::Hosted {
                mail_root: cwd.display().to_string(),
            }
        } else {
            Sessions::Store {
                home: home.as_deref(),
                home_implicit: opened.home_implicit,
                cwd: &cwd,
            }
        };
        let mut outcome = launch_outcome(
            operation,
            harness,
            sessions,
            &pane.session,
            item,
            opened,
            Polled::Ready { identity },
        )?;
        outcome.annotate("reconcile", json!("launch"));
        return Ok(outcome);
    }
    let mut observation = pending_observation(&reading, &state);
    observation["reconcile"] = json!("launch");
    observation["observed"] = json!("present");
    Ok(launch_pane_unconfirmed(operation, opened, observation))
}

#[allow(
    clippy::disallowed_methods,
    reason = "the rows write the item files and directories the launch reads"
)]
#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;
    use crate::state::LaneStatus;

    fn bound_lane(account: &str, mail_root: Option<&Path>) -> Lane {
        Lane {
            item: "KEN-7".to_owned(),
            tracker: None,
            repo: None,
            harness: Some("claude".to_owned()),
            window: None,
            account: Some(account.to_owned()),
            home: None,
            home_implicit: false,
            host: None,
            kind: None,
            mail_root: mail_root.map(|p| p.display().to_string()),
            surface: None,
            model: None,
            effort: None,
            session_id: Some("0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c".to_owned()),
            session_since: None,
            launched_at: None,
            running_at: None,
            status: LaneStatus::Stopped,
            over_cap: None,
            launch: None,
            reservation: None,
            touched: None,
            in_scope: None,
            rebase: Vec::new(),
            extra: Default::default(),
        }
    }

    fn request(account: &str, mail_root: &Path) -> LaunchLane {
        LaunchLane {
            item: "KEN-7".to_owned(),
            harness: "claude".to_owned(),
            mail_root: mail_root.display().to_string(),
            permission: None,
            tracker: None,
            repo: None,
            account: Some(account.to_owned()),
            model: None,
            effort: None,
            kind: None,
            host: None,
            surface: None,
            over_cap: None,
            exclude_account: None,
            judge_account: false,
            refresh: false,
            brief_file: None,
            repo_dir: None,
            scope_range: None,
            in_scope: Vec::new(),
            obligation: None,
        }
    }

    /// The cloud CLI as `cloud_create` runs it: `sh -c SCRIPT`, the create's
    /// own words after it as the script's positional parameters.
    fn cloud_cli(cwd: PathBuf, script: &str) -> LaunchCommand {
        LaunchCommand {
            program: "sh".to_owned(),
            args: vec!["-c".to_owned(), script.to_owned()],
            env: Default::default(),
            env_remove: Vec::new(),
            cwd,
            brief_arg: None,
            brief_path: None,
        }
    }

    /// A cloud create whose CLI never started made nothing, so it is
    /// refused and a second launch may ask again, never held for a person
    /// over nothing.
    #[test]
    fn a_cloud_create_whose_cli_never_started_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let gone = cloud_cli(dir.path().join("gone"), "exit 0");
        assert!(matches!(
            cloud_create(&gone, "brief"),
            Created::Refused(cause) if cause.starts_with("cloud-create-refused")
        ));
    }

    /// A cloud create whose CLI started and ended by a signal gave no
    /// answer, so a session may exist and the create is unknown, never a
    /// refusal that lets a second launch create a second session beside one
    /// that may stand.
    #[test]
    fn a_cloud_create_whose_cli_is_killed_is_unknown() {
        let dir = tempfile::tempdir().unwrap();
        let killed = cloud_cli(dir.path().to_owned(), "kill -KILL $$");
        assert!(matches!(
            cloud_create(&killed, "brief"),
            Created::Unknown(cause) if cause == "cloud-create-unanswered cause=signal"
        ));
    }

    /// The worktree package read by the runner's three values. One that
    /// never started made nothing and fails the launch; one that started
    /// and outran its bound, or that a signal ended, may have made the
    /// worktree or the push, so it is unknown: a start that failed is never
    /// held for a person over nothing, and a create or push that may have
    /// acted is never settled failed.
    #[test]
    fn the_worktree_package_never_started_fails_and_one_with_no_answer_is_unknown() {
        let dir = tempfile::tempdir().unwrap();
        let sh = Path::new("/bin/sh");
        let gone = dir.path().join("gone");
        let started = |script: &str, bound: Duration| {
            package(sh, dir.path(), "create", &["-c", script], bound)
        };
        assert!(matches!(
            package(sh, &gone, "create", &["-c", "exit 0"], BOUND_TEST),
            Err(Package::Failed(cause)) if cause.contains("gone")
        ));
        assert!(matches!(
            started("kill -KILL $$", BOUND_TEST),
            Err(Package::Unknown(cause)) if cause.starts_with("exit=signal")
        ));
        assert!(matches!(
            started("exec sleep 5", Duration::from_millis(200)),
            Err(Package::Unknown(_))
        ));
        assert!(
            matches!(started("exit 3", BOUND_TEST), Err(Package::Failed(cause)) if cause.starts_with("exit=3"))
        );
    }

    const BOUND_TEST: Duration = Duration::from_secs(10);

    /// The relaunch router. A bound session resumes under the same harness
    /// and account when the destination home holds its file; a request on
    /// another account starts fresh with `account-switched`, a destination
    /// with no file for the fixed id with `session-absent`; a standing
    /// handoff that says `fresh` and a changed harness keep their causes.
    #[test]
    fn a_relaunch_on_another_account_or_without_its_session_file_starts_fresh() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path().join("w");
        fs::create_dir_all(&cwd).unwrap();
        let a = dir.path().join("a");
        let b = dir.path().join("b");
        let id = "0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c";
        let file = operation::fixed_file(Harness::Claude, &a, &cwd, id).unwrap();
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(&file, "{}\n").unwrap();
        let lane = bound_lane(&a.display().to_string(), Some(&cwd));
        let same = request(&a.display().to_string(), &cwd);
        let other = request(&b.display().to_string(), &cwd);
        let owner = &operation::session_owner;
        assert!(matches!(
            route_of(&lane, &same, None, Some(&a), owner),
            Route::Resume { session_id, .. } if session_id == id
        ));
        assert!(matches!(
            route_of(&lane, &same, Some(Relaunch::Resume), Some(&a), owner),
            Route::Resume { .. }
        ));
        assert!(matches!(
            route_of(&lane, &other, None, Some(&b), owner),
            Route::Fresh {
                cause: Some("account-switched")
            }
        ));
        // The same account recorded, the file gone from the destination.
        fs::remove_file(&file).unwrap();
        assert!(matches!(
            route_of(&lane, &same, None, Some(&a), owner),
            Route::Fresh {
                cause: Some("session-absent")
            }
        ));
        fs::write(&file, "{}\n").unwrap();
        assert!(matches!(
            route_of(&lane, &same, Some(Relaunch::Fresh), Some(&a), owner),
            Route::Fresh {
                cause: Some("session-retired")
            }
        ));
        let mut codex = same.clone();
        codex.harness = "codex".to_owned();
        assert!(matches!(
            route_of(&lane, &codex, None, Some(&a), owner),
            Route::Fresh {
                cause: Some("harness-switched")
            }
        ));
        let mut unbound = lane.clone();
        unbound.session_id = None;
        assert!(matches!(
            route_of(&unbound, &same, None, Some(&a), owner),
            Route::Fresh { cause: None }
        ));
    }

    /// The relaunch route reads the destination session store for the bound
    /// id through the session owner's fixed-id lookup, for every resumable
    /// harness and three-valued: absent starts fresh `session-absent`,
    /// present resumes, unreadable refuses before any window. The working
    /// directory reaches the Claude arm alone: a Codex lane with no
    /// `mail_root` is still looked up.
    #[test]
    fn a_relaunch_reads_the_destination_store_for_each_resumable_harness() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path().join("w");
        fs::create_dir_all(&cwd).unwrap();
        let home = dir.path().join("home");
        fs::create_dir_all(&home).unwrap();
        let id = "0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c";
        let account = home.display().to_string();
        let bound = |harness: &str, root: Option<&Path>| {
            let mut lane = bound_lane(&account, root);
            lane.harness = Some(harness.to_owned());
            lane
        };
        let request = |harness: &str| {
            let mut r = request(&account, &cwd);
            r.harness = harness.to_owned();
            r
        };
        // The lookup as the route sees it: each row's reading, and which
        // working directory the route handed it.
        let asked: std::cell::RefCell<Vec<(Harness, PathBuf)>> = Default::default();
        let answer = std::cell::RefCell::new(Reading::Gone);
        let owner = |harness: Harness, _: &Path, cwd: &Path, _: &str| {
            asked.borrow_mut().push((harness, cwd.to_path_buf()));
            answer.borrow().clone()
        };
        assert!(matches!(
            route_of(
                &bound("codex", None),
                &request("codex"),
                None,
                Some(&home),
                &owner
            ),
            Route::Fresh {
                cause: Some("session-absent")
            }
        ));
        assert!(matches!(
            route_of(
                &bound("copilot", None),
                &request("copilot"),
                None,
                Some(&home),
                &owner
            ),
            Route::Fresh {
                cause: Some("session-absent")
            }
        ));
        assert!(matches!(
            route_of(
                &bound("claude", None),
                &request("claude"),
                None,
                Some(&home),
                &owner
            ),
            Route::Resume { .. }
        ));
        assert_eq!(
            asked.borrow().clone(),
            vec![
                (Harness::Codex, PathBuf::from("")),
                (Harness::Copilot, PathBuf::from("")),
            ],
            "Codex and Copilot are looked up with no directory; Claude with none recorded is not"
        );
        asked.borrow_mut().clear();
        *answer.borrow_mut() = Reading::Live(None);
        assert!(matches!(
            route_of(&bound("claude", Some(&cwd)), &request("claude"), None, Some(&home), &owner),
            Route::Resume { session_id, .. } if session_id == id
        ));
        assert!(matches!(
            route_of(
                &bound("codex", Some(&cwd)),
                &request("codex"),
                None,
                Some(&home),
                &owner
            ),
            Route::Resume { .. }
        ));
        assert_eq!(
            asked.borrow().clone(),
            vec![
                (Harness::Claude, cwd.clone()),
                (Harness::Codex, PathBuf::from(""))
            ],
            "the working directory reaches the Claude arm alone"
        );
        *answer.borrow_mut() = Reading::Unreadable {
            cause: "store-unreadable",
        };
        assert!(
            matches!(
                route_of(
                    &bound("copilot", Some(&cwd)),
                    &request("copilot"),
                    None,
                    Some(&home),
                    &owner
                ),
                Route::Refuse { .. }
            ),
            "an unreadable store refuses before any window"
        );
    }

    #[test]
    fn a_lane_line_turns_compaction_off_where_the_harness_can_and_carries_the_lane_words() {
        for harness in [
            Harness::Claude,
            Harness::Codex,
            Harness::Copilot,
            Harness::Pi,
        ] {
            let mut intent = LaunchIntent {
                harness,
                home: None,
                account: None,
                cwd: PathBuf::from("/w/KEN-7"),
                model: None,
                effort: None,
                permission: Permission::Native,
                question_tool: QuestionTool::Off,
                compaction: lane_compaction(harness),
                brief: agent_runtime::launch::Brief::None,
                resume: None,
                session_id: None,
                env: Default::default(),
                env_remove: Vec::new(),
                extra_args: Vec::new(),
                program: None,
            };
            let cwd = intent.cwd.clone();
            lane_words(&mut intent, &cwd);
            let command = agent_runtime::launch::build(&intent).unwrap();
            match harness.compaction_off_words() {
                Some(words) => assert!(
                    words.iter().all(|w| command.args.iter().any(|a| a == w)),
                    "{harness:?}: {:?}",
                    command.args
                ),
                None => assert!(
                    !command.args.iter().any(|a| a.contains("compact")),
                    "{harness:?}: {:?}",
                    command.args
                ),
            }
            assert_eq!(
                command.env.get("KENDEX_USER_EMAIL").map(String::as_str),
                Some("")
            );
            assert_eq!(
                command.env.get("KENDEX_LANE_ORIGIN").map(String::as_str),
                Some("/w/KEN-7")
            );
        }
    }

    #[test]
    fn a_relaunch_refuses_a_bound_session_another_directory_owns() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path().join("w");
        let other = dir.path().join("other");
        fs::create_dir_all(&cwd).unwrap();
        fs::create_dir_all(&other).unwrap();
        let home = dir.path().join("home");
        let account = home.display().to_string();
        let mut lane = bound_lane(&account, Some(&cwd));
        lane.harness = Some("codex".to_owned());
        let mut r = request(&account, &cwd);
        r.harness = "codex".to_owned();
        let elsewhere =
            |_: Harness, _: &Path, _: &Path, _: &str| Reading::Live(Some(other.clone()));
        assert!(matches!(
            route_of(&lane, &r, None, Some(&home), &elsewhere),
            Route::Refuse {
                cause: "session-owned-elsewhere"
            }
        ));
        let own = |_: Harness, _: &Path, _: &Path, _: &str| Reading::Live(Some(cwd.clone()));
        assert!(matches!(
            route_of(&lane, &r, None, Some(&home), &own),
            Route::Resume { .. }
        ));
        // A spelling that resolves to the lane's directory is its own.
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&cwd, &link).unwrap();
        let linked = |_: Harness, _: &Path, _: &Path, _: &str| Reading::Live(Some(link.clone()));
        assert!(matches!(
            route_of(&lane, &r, None, Some(&home), &linked),
            Route::Resume { .. }
        ));
    }
}
