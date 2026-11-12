//! The `agent-runtime` command: the versioned boundary other languages and
//! hosts speak to the library through. Every verb prints one JSON reply on
//! stdout; a refusal also prints one keyed line on stderr and exits 1. A
//! usage error prints `agent-runtime: usage` and clap's message on stderr
//! and exits 2, clap's own convention, with no reply: there was no request
//! to answer.

// Every reading, close and stop outcome is matched variant by variant.
#![deny(clippy::wildcard_enum_match_arm)]

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use clap::error::ErrorKind;
use clap::{Parser, Subcommand};
use serde::{Deserialize, Serialize};
use serde_json::Map;

use agent_runtime::accounts::{self, walk};
use agent_runtime::clock;
use agent_runtime::controller::{self, views::MarkKind};
use agent_runtime::error::{Error, Result};
use agent_runtime::harness::{self, Harness};
use agent_runtime::host::tmux::{self, Close, PaneFields};
use agent_runtime::journal::Env;
use agent_runtime::launch::{self, LaunchIntent};
use agent_runtime::observe::{self, ProcessReading, State};
use agent_runtime::process::{self, Identity};
use agent_runtime::protocol::{self, Outcome, Reply};
use agent_runtime::reading::{Reading, Unreadable};
use agent_runtime::record::{self, Expect};
use agent_runtime::session;
use agent_runtime::settings;

const RECORD_VERSION: u64 = 1;
const RECORD_VERSIONS: &[u64] = &[1];

#[derive(Parser)]
#[command(
    name = "agent-runtime",
    version,
    about = "Launch, observe, deliver to and stop one coding-harness session"
)]
struct Cli {
    #[command(subcommand)]
    verb: Verb,
}

#[derive(Subcommand)]
#[allow(
    clippy::large_enum_variant,
    reason = "the parsed command line, built once; `deliver` names a session by its facts in place of a record"
)]
enum Verb {
    /// Print the protocol and crate version.
    Version,
    /// Ask each installed harness its version.
    Probe {
        #[arg(long)]
        harness: Option<String>,
    },
    /// Open a tmux window on the named socket and session, start the
    /// harness the intent file describes in it, and write the launch record.
    Launch {
        #[arg(long)]
        intent: PathBuf,
        #[arg(long)]
        record: PathBuf,
        /// The tmux socket; the caller's own, or the default, when omitted.
        #[arg(long)]
        socket: Option<PathBuf>,
        #[arg(long)]
        session: String,
        #[arg(long)]
        window_name: String,
    },
    /// Read the recorded session: pane, process, native identity, state.
    Inspect {
        #[arg(long)]
        record: PathBuf,
    },
    /// Type text into the session's pane, only when the session is
    /// positively idle, and confirm it by a user turn the harness wrote to
    /// its own session file. The session is a launch record, or its facts
    /// on the line (`--harness` with the pane, the server and the session).
    Deliver {
        #[arg(long, conflicts_with = "harness")]
        record: Option<PathBuf>,
        /// The text to type, from a file.
        #[arg(long, conflicts_with = "line")]
        file: Option<PathBuf>,
        /// The text to type, as given.
        #[arg(long)]
        line: Option<String>,
        /// Deliver whatever the screen says; for a probe that knows better.
        #[arg(long)]
        force: bool,
        /// The session's harness, with the facts below in place of a record.
        #[arg(long, requires_all = ["socket", "server_pid", "pane", "cwd"])]
        harness: Option<String>,
        /// The harness executable, where it runs from a configured path.
        #[arg(long)]
        program: Option<PathBuf>,
        /// The tmux socket and server pid the pane sits on, and the server's
        /// start where the caller recorded one; without it the server at
        /// the socket stands for the pid alone.
        #[arg(long)]
        socket: Option<PathBuf>,
        #[arg(long)]
        server_pid: Option<u32>,
        #[arg(long)]
        server_start: Option<u64>,
        #[arg(long)]
        pane: Option<String>,
        /// The harness process the session runs as; only that identity is
        /// the harness.
        #[arg(long, requires = "start")]
        pid: Option<u32>,
        #[arg(long)]
        start: Option<String>,
        /// The account home the session file is read under; the harness's
        /// default home when omitted.
        #[arg(long)]
        home: Option<PathBuf>,
        #[arg(long)]
        cwd: Option<PathBuf>,
        /// The session id the file is named by; without one no delivery is
        /// confirmable, which the reply says as its limit.
        #[arg(long)]
        session_id: Option<String>,
        /// The file's user-turn count before the paste, as an earlier
        /// `--no-paste` read it; read now when omitted. The delivery is
        /// confirmed by a turn beyond it.
        #[arg(long)]
        turns_before: Option<u64>,
        /// Read the state and the turn count alone: nothing is typed.
        #[arg(long)]
        no_paste: bool,
        /// How long the confirming turn is waited for after the paste.
        #[arg(long, default_value_t = 15)]
        bound_secs: u64,
    },
    /// End the recorded harness exactly, then close its window.
    Stop {
        #[arg(long)]
        record: PathBuf,
        #[arg(long, default_value_t = 10)]
        grace_secs: u64,
    },
    /// Judge a captured screen held in a file (fixtures and probes), drawn
    /// by the named harness. The screen alone is judged: `--process` is the
    /// caller's own reading of the pane (`harness-up` asserts the harness
    /// holds it), which a live `inspect` reads from the pane's foreground
    /// process instead.
    Judge {
        #[arg(long)]
        screen: PathBuf,
        #[arg(long)]
        harness: String,
        #[arg(long, default_value = "harness-up")]
        process: String,
    },
    /// The file a session's id names under the harness's home for the
    /// cwd, found by the id and never by its age, three-valued: `live`
    /// with the path, `gone` where no file carries the id yet, `unreadable`
    /// with the cause where the store could not be read.
    SessionFile {
        #[arg(long)]
        harness: String,
        #[arg(long)]
        home: PathBuf,
        #[arg(long)]
        cwd: PathBuf,
        #[arg(long)]
        id: String,
    },
    /// Process identity operations.
    Process {
        #[command(subcommand)]
        op: ProcessOp,
    },
    /// The account reading: this machine's accounts under the judge's
    /// statement, the account a launch spends, and the preference walk,
    /// each counting the lanes the project's orch runs on an account.
    Accounts {
        #[command(subcommand)]
        op: AccountsOp,
    },
    /// The controller's hand-over over the record `--record` names: the
    /// successor's choice, its start, transfer, adoption and stop, the
    /// reconcile of its open intents, and the job a transfer or a stop runs
    /// in.
    Controller {
        #[command(subcommand)]
        op: ControllerOp,
    },
}

/// The hand-over's verbs, each over the controller record `--record` names.
#[derive(Subcommand)]
enum ControllerOp {
    /// The controller walk's choice: the pending a start or transfer request
    /// carries, for a first controller in `--cwd`, or for the successor of
    /// the recorded controller whose pane `--predecessor` names, walked as
    /// its `--mark` decides; `--recover` replays its own launch.
    Successor {
        #[arg(long)]
        record: PathBuf,
        #[arg(long)]
        cwd: PathBuf,
        #[arg(long)]
        predecessor: Option<String>,
        #[arg(long, requires = "predecessor", conflicts_with = "recover", value_parser = mark_kind)]
        mark: Option<MarkKind>,
        #[arg(long, requires = "predecessor")]
        recover: bool,
        /// The handoff the pending names; the recorded controller's own
        /// where left out.
        #[arg(long)]
        handoff: Option<String>,
        /// The preference the walk takes, in the setting's form, over
        /// `AGENT_RUNTIME_CONTROLLER_PREFERENCE`.
        #[arg(long, conflicts_with = "recover")]
        preference: Option<String>,
    },
    /// Open a controller where none runs, on the request file's
    /// `{controller, brief_file, session?, watch?}`.
    Start {
        #[arg(long)]
        record: PathBuf,
        #[arg(long)]
        request: PathBuf,
        /// Exit by the effect's outcome: 0 confirmed, 3 failed, 75 unknown.
        #[arg(long)]
        effect_exit: bool,
        #[command(flatten)]
        reach: ReachArgs,
    },
    /// Ask for a succession on the request file's `{expected, successor,
    /// brief_file, cause, ...}`, run by its detached job.
    Transfer {
        #[arg(long)]
        record: PathBuf,
        #[arg(long)]
        request: PathBuf,
        /// Exit by the effect's outcome: 0 confirmed or the runner up, 3
        /// failed, 75 unknown.
        #[arg(long)]
        effect_exit: bool,
        #[command(flatten)]
        reach: ReachArgs,
    },
    /// Record the controller a person opened by hand in the caller's own
    /// pane, or the pane `--pane` names (on `--socket`, else the caller's own
    /// server) running `--harness`, or the pane an adoption request names.
    Adopt {
        #[arg(long)]
        record: PathBuf,
        /// The account the session spends, where its rows and its
        /// environment do not say.
        #[arg(long, conflicts_with = "request")]
        account: Option<String>,
        #[arg(long, conflicts_with = "pane")]
        request: Option<PathBuf>,
        #[arg(long, requires = "harness")]
        pane: Option<String>,
        #[command(flatten)]
        named: AdoptArgs,
    },
    /// Retire the recorded controller exactly and record `off`, run by its
    /// detached job.
    Stop {
        #[arg(long)]
        record: PathBuf,
        #[arg(long)]
        effect_exit: bool,
        #[command(flatten)]
        reach: ReachArgs,
    },
    /// The recorded controller, whether it still runs, the open controller
    /// intents and, with `--server`, how the record stands to the caller's
    /// own pane: `binding`, `native_match` and `model_launch`.
    Status {
        #[arg(long)]
        record: PathBuf,
        /// The caller's tmux server pid.
        #[arg(long, requires = "pane")]
        server: Option<String>,
        /// The socket the caller's server answers on; the record's where
        /// left out.
        #[arg(long, requires = "server")]
        socket: Option<PathBuf>,
        #[arg(long, requires = "server")]
        pane: Option<String>,
        #[arg(long, requires = "server", default_value = "")]
        harness: String,
        /// The caller's launch home, empty where it could not be read.
        #[arg(long, requires = "server", default_value = "")]
        home: String,
        /// The caller's native session id.
        #[arg(long, requires = "server", default_value = "")]
        session: String,
    },
    /// Complete or mark every open controller intent from its recorded
    /// phase, send the notices closed ones owe, and heal the record from its
    /// pane.
    Reconcile {
        #[arg(long)]
        record: PathBuf,
        #[command(flatten)]
        reach: ReachArgs,
    },
    /// Write the handoff's snapshot at `--handoff` under its generation
    /// header, the record's controller generation, over the prepared body at
    /// `--body`; `--keep-prior` keeps the installed snapshot's content ahead
    /// of the body.
    Handoff {
        #[arg(long)]
        record: PathBuf,
        #[arg(long)]
        body: PathBuf,
        #[arg(long)]
        handoff: PathBuf,
        #[arg(long)]
        keep_prior: bool,
    },
    /// The detached job a transfer or a stop runs in.
    #[command(hide = true)]
    Job {
        #[arg(long)]
        record: PathBuf,
        #[arg(long)]
        intent: String,
        #[command(flatten)]
        reach: ReachArgs,
    },
}

/// What an adoption of the pane `--pane` names records beside it.
#[derive(clap::Args)]
struct AdoptArgs {
    /// The tmux server the pane is on; the caller's own `$TMUX` where left
    /// out.
    #[arg(long, requires = "pane")]
    socket: Option<PathBuf>,
    #[arg(long, requires = "pane")]
    harness: Option<String>,
    /// The harness's native session id.
    #[arg(long, requires = "pane")]
    session_id: Option<String>,
    #[arg(long, requires = "pane")]
    home: Option<String>,
    #[arg(long, requires = "pane")]
    model: Option<String>,
    #[arg(long, requires = "pane")]
    effort: Option<String>,
    #[arg(long, requires = "pane")]
    cwd: Option<String>,
}

impl AdoptArgs {
    /// The adoption request the flags name for `pane`.
    fn request(self, pane: String, account: Option<String>) -> controller::AdoptController {
        controller::AdoptController {
            pane,
            socket: self.socket,
            harness: self.harness.unwrap_or_default(),
            session_id: self.session_id,
            account,
            home: self.home,
            model: self.model,
            effort: self.effort,
            cwd: self.cwd,
            session_rows: None,
            permission: None,
            extra_args: None,
        }
    }
}

/// The mailbox and the tmux server a verb that runs an effect reaches, each
/// named by the caller: nothing is found from the directory the command
/// runs in, which a detached job inherits from whatever started it.
#[derive(clap::Args)]
struct ReachArgs {
    /// The mailbox program an owner notice runs.
    #[arg(long)]
    mail_program: Option<PathBuf>,
    /// The mailbox root an owner notice is delivered under.
    #[arg(long)]
    mail_root: Option<PathBuf>,
    /// The tmux server a window opens on and a pane is read on; the record's
    /// recorded server where left out.
    #[arg(long)]
    socket: Option<PathBuf>,
}

impl ReachArgs {
    /// The reach the caller named for the record at `path`, refused before
    /// any intent, job or server: `mailbox-unnamed` naming the missing flag,
    /// `tmux-server-unnamed` where neither the call nor the record names a
    /// server.
    fn named(self, path: &Path) -> Result<agent_runtime::effects::Reach> {
        let missing = |field: &str| Error::refused("mailbox-unnamed", &[("field", field)]);
        let mail_program = self.mail_program.ok_or_else(|| missing("mail_program"))?;
        let mail_root = self.mail_root.ok_or_else(|| missing("mail_root"))?;
        let socket = match self.socket {
            Some(socket) => socket,
            None => {
                recorded_socket(path)?.ok_or_else(|| Error::refused("tmux-server-unnamed", &[]))?
            }
        };
        Ok(agent_runtime::effects::Reach {
            mail_program,
            mail_root,
            socket: Some(socket),
        })
    }
}

/// The server the controller record at `path` names, where it names one.
fn recorded_socket(path: &Path) -> Result<Option<PathBuf>> {
    let Some(doc) = record::read_document(path)? else {
        return Ok(None);
    };
    Ok(
        record::field::<controller::Overseer>(path, &doc, controller::MEMBER)?
            .as_ref()
            .and_then(agent_runtime::effects::overseer_socket),
    )
}

/// A mark word as the choice takes it.
fn mark_kind(word: &str) -> std::result::Result<MarkKind, String> {
    MarkKind::parse(word)
        .ok_or_else(|| format!("{word} is none of context, headroom, rate, memory"))
}

/// The account reading's verbs.
#[derive(Subcommand)]
enum AccountsOp {
    /// The listing under the judge's statement: each row with its status
    /// word, and the roster lines.
    Roster,
    /// Which account a launch spends: the listing judged with the
    /// controller record's seat and the lanes' live charges; the reply
    /// carries the answer's exit by number and its record or counts.
    Pick {
        #[arg(long)]
        harness: String,
        /// The selector the harness runs.
        #[arg(long)]
        native_model: Option<String>,
        /// Judge one named account instead of choosing.
        #[arg(long)]
        account: Option<String>,
        /// Judge the named account on the projection.
        #[arg(long, requires = "account")]
        projected: bool,
        /// A config dir the pick omits before judging.
        #[arg(long)]
        exclude_account: Vec<String>,
        /// Judge seats as ordinary accounts: the controller's own pick.
        #[arg(long)]
        for_controller: bool,
        /// The bound in percent used; `AGENT_RUNTIME_ACCOUNT_MAX_PCT` where unset.
        #[arg(long, value_parser = clap::value_parser!(u32).range(0..=100), conflicts_with = "min_headroom_pct")]
        max_pct: Option<u32>,
        /// The headroom the caller's own judgement triggers at: the same
        /// bound as `--max-pct 100-T`.
        #[arg(long, value_parser = clap::value_parser!(u32).range(0..=100))]
        min_headroom_pct: Option<u32>,
        /// Hold the account's own binding bucket to the bound beside the
        /// model's window.
        #[arg(long)]
        binding_floor: bool,
        /// The fleet record whose controller member is a seat and whose
        /// lanes are charged; orch's own fleet where unset.
        #[arg(long)]
        record: Option<PathBuf>,
        /// Print the launch prefix, `VAR=<config dir>`, and exit by the
        /// answer's exit in place of the reply: the room check a consumer's
        /// `SECOND_OPINION_<NAME>_ROOM_CMD` runs.
        #[arg(long)]
        env: bool,
    },
    /// The preference walk: `--preference`'s entries, or for a
    /// controller's session `AGENT_RUNTIME_CONTROLLER_PREFERENCE`'s, in
    /// order, each judged by `pick`'s rule; the reply names the entry taken
    /// and every entry skipped with the judge's word.
    #[command(group = clap::ArgGroup::new("walked").required(true).multiple(true).args(["controller", "preference"]))]
    Walk {
        /// Walk the controller preference: seats judged as ordinary
        /// accounts, the headroom trigger as the bound, the caller's own
        /// entry last.
        #[arg(long, conflicts_with_all = ["account", "max_pct"])]
        controller: bool,
        /// The entries walked, in place of the controller preference.
        #[arg(long)]
        preference: Option<String>,
        /// The fleet record whose controller member is a seat and whose
        /// lanes are charged; orch's own fleet where unset.
        #[arg(long)]
        record: Option<PathBuf>,
        /// An account every entry is judged on (a directory or a listed
        /// alias).
        #[arg(long)]
        account: Option<String>,
        /// A config dir every pick omits before judging.
        #[arg(long)]
        exclude_account: Vec<String>,
        /// The bound in percent used; `AGENT_RUNTIME_ACCOUNT_MAX_PCT` where unset.
        #[arg(long, value_parser = clap::value_parser!(u32).range(0..=100), conflicts_with = "min_headroom_pct")]
        max_pct: Option<u32>,
        /// The headroom the caller's own judgement triggers at;
        /// `AGENT_RUNTIME_CONTROLLER_HEADROOM_PCT` for a controller where unset.
        #[arg(long, value_parser = clap::value_parser!(u32).range(0..=100))]
        min_headroom_pct: Option<u32>,
        /// The harness of the session the walk is asked for, whose
        /// permission posture an entry of another harness must take.
        #[arg(long)]
        source_harness: Option<String>,
        /// That session's launch words; left out, the harness's row alone
        /// answers.
        #[arg(long, requires = "source_harness", allow_hyphen_values = true)]
        source_flags: Option<String>,
        /// The predecessor's harness: its own entry walks last.
        #[arg(long)]
        caller_harness: Option<String>,
        #[arg(long, requires = "caller_harness")]
        caller_account: Option<String>,
        /// The model the successor runs; a numeric entry's model too.
        #[arg(long, requires = "caller_harness")]
        caller_model: Option<String>,
        #[arg(long, requires = "caller_harness")]
        caller_effort: Option<String>,
        /// The model the caller's account is judged on.
        #[arg(long, requires = "caller_harness")]
        caller_pick_model: Option<String>,
        /// Keep the caller's own account without a pick.
        #[arg(long, requires = "caller_harness")]
        caller_keep: bool,
        /// At a context mark with the caller's account unmeasured: an entry
        /// of its harness whose pick finds none keeps the caller's account
        /// where the judge still reads it unmeasured.
        #[arg(long, requires = "caller_harness")]
        keep_unmeasured: bool,
    },
    /// A batch someone else measured, in the provider `accounts` line form,
    /// each line judged as `pick --account` judges an account now; one
    /// reply entry per line, in order.
    Judge {
        /// The batch's file; `-` reads it from stdin.
        #[arg(long)]
        rows: PathBuf,
        /// The bound in percent used; `AGENT_RUNTIME_ACCOUNT_MAX_PCT` where unset.
        #[arg(long, value_parser = clap::value_parser!(u32).range(0..=100), conflicts_with = "min_headroom_pct")]
        max_pct: Option<u32>,
        /// The headroom the caller's own judgement triggers at.
        #[arg(long, value_parser = clap::value_parser!(u32).range(0..=100))]
        min_headroom_pct: Option<u32>,
        /// Judge seats as ordinary accounts: the controller's own question.
        #[arg(long)]
        for_controller: bool,
        /// The fleet record whose controller member is a seat and whose
        /// lanes are charged; orch's own fleet where unset.
        #[arg(long)]
        record: Option<PathBuf>,
    },
}

/// The settings a reading takes: the account keys, the records' root, the
/// homes, the controller preference, and the project whose orch counts the
/// lanes. Loaded from the checkout the command runs in; a directory in no
/// checkout is its own root, so a reading runs anywhere.
struct AccountSettings {
    project: PathBuf,
    accounts: settings::Judged<settings::AccountSettings>,
    state: settings::Judged<PathBuf>,
    home: Option<String>,
    copilot_home: Option<String>,
    preference: String,
}

/// The home a Copilot account directory is resolved under.
const COPILOT_HOME_KEY: &str = "COPILOT_HOME";

impl AccountSettings {
    fn load() -> Result<AccountSettings> {
        let cwd = std::env::current_dir().map_err(|e| Error::io("read", ".", e))?;
        let roots = settings::roots(&cwd)?;
        let environment: Vec<(std::ffi::OsString, std::ffi::OsString)> =
            std::env::vars_os().collect();
        let keys = settings::Keys {
            read: &[
                settings::ACCOUNT_KEYS,
                settings::ENGINE_KEYS,
                &[COPILOT_HOME_KEY],
            ],
            load: &[],
        };
        let values = settings::layered(&roots.project, &environment, true, &keys)?;
        if let Some((path, keys)) = &values.passed_over {
            for key in keys {
                let _ = writeln!(
                    std::io::stderr().lock(),
                    "settings-skipped path={} key={key} reason=shell-form",
                    path.display()
                );
            }
        }
        let loaded = AccountSettings {
            accounts: settings::AccountSettings::read(&values),
            state: settings::account_state_dir(&values),
            home: values.get(settings::HOME_KEY).map(str::to_owned),
            copilot_home: values.get(COPILOT_HOME_KEY).map(str::to_owned),
            preference: settings::ControllerSettings::read(&values).preference,
            project: roots.project,
        };
        // Every verb reads the account keys first: a value outside its form
        // refuses before anything is read.
        loaded.accounts.get()?;
        loaded.state.get()?;
        Ok(loaded)
    }

    fn env(&self) -> accounts::Env<'_> {
        accounts::Env {
            accounts: &self.accounts,
            account_state: &self.state,
            home: self.home.as_deref(),
            copilot_home: self.copilot_home.as_deref(),
            controller_preference: &self.preference,
        }
    }
}

fn accounts_verb(op: AccountsOp) -> Result<serde_json::Value> {
    let loaded = AccountSettings::load()?;
    let env = loaded.env();
    let now = clock::Clock::wall(&clock::SystemClock)
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    match op {
        AccountsOp::Roster => {
            let today = accounts::today(now);
            Ok(match accounts::roster(&env, None, now) {
                Ok(roster) => serde_json::json!({
                    "read": true,
                    "accounts": roster.rows.len(),
                    "lines": roster.lines(&today),
                    "rows": roster.rows.iter().map(|r| serde_json::json!({
                        "alias": r.alias,
                        "config_dir": r.config_dir,
                        "harness": r.harness,
                        "measured_through": r.measured_through,
                        "status": r.status,
                        "word": r.word().text(),
                        "ended": r.ended(&today),
                        "record": r.raw,
                    })).collect::<Vec<serde_json::Value>>(),
                }),
                Err(cause) => serde_json::json!({"read": false, "cause": cause}),
            })
        }
        AccountsOp::Pick {
            harness,
            native_model,
            account,
            projected,
            exclude_account,
            for_controller,
            max_pct,
            min_headroom_pct,
            binding_floor,
            record,
            env: text,
        } => {
            let named = Harness::named(&harness)?;
            let request = accounts::PickRequest {
                harness: named,
                model: native_model,
                exclude: exclude_account,
                for_overseer: for_controller,
                lane: account,
                projected,
                max_pct,
                min_headroom_pct,
                binding_floor,
                admit_unread_scope: false,
                opens_here: false,
            };
            let answer =
                accounts::here::pick(&env, &loaded.project, record.as_deref(), &request, now)?;
            if text {
                // The text form a room check reads: the variable the harness
                // launches its account under and the directory, on stdout at
                // exit 0; any other answer its keyed line on stderr at the
                // answer's exit.
                if let accounts::PickAnswer::Lane(judged) = &answer {
                    let _ = writeln!(
                        std::io::stdout().lock(),
                        "{}={}",
                        named.account_var(request.model.as_deref()),
                        judged.row.config_dir
                    );
                } else {
                    let reply = answer.reply();
                    let _ = writeln!(
                        std::io::stderr().lock(),
                        "agent-runtime: account-{} harness={} exit={}",
                        reply["answer"].as_str().unwrap_or("unjudged"),
                        request.harness,
                        answer.exit()
                    );
                }
                std::process::exit(answer.exit());
            }
            Ok(answer.reply())
        }
        AccountsOp::Walk {
            controller,
            preference,
            record,
            account,
            exclude_account,
            max_pct,
            min_headroom_pct,
            source_harness,
            source_flags,
            caller_harness,
            caller_account,
            caller_model,
            caller_effort,
            caller_pick_model,
            caller_keep,
            keep_unmeasured,
        } => {
            let request = walk::WalkRequest {
                scope: if controller {
                    walk::Scope::Overseer
                } else {
                    walk::Scope::Lane
                },
                preference,
                lane: account,
                exclude: exclude_account,
                max_pct,
                min_headroom_pct,
                source: source_harness
                    .map(|word| Harness::named(&word))
                    .transpose()?
                    .map(|harness| walk::Source {
                        harness,
                        flags: source_flags
                            .map(|text| text.split_whitespace().map(str::to_owned).collect()),
                    }),
                caller: caller_harness
                    .map(|word| Harness::named(&word))
                    .transpose()?
                    .map(|harness| walk::Caller {
                        harness,
                        lane: caller_account,
                        model: caller_model,
                        effort: caller_effort,
                        pick_model: caller_pick_model,
                        keep: caller_keep,
                    }),
                keep_unmeasured,
            };
            Ok(
                accounts::here::walk(&env, &loaded.project, record.as_deref(), &request, now)?
                    .reply(),
            )
        }
        AccountsOp::Judge {
            rows,
            max_pct,
            min_headroom_pct,
            for_controller,
            record,
        } => accounts::batch::judge(
            &env,
            &loaded.project,
            record.as_deref(),
            &rows,
            accounts::batch::Question {
                max_pct,
                min_headroom_pct,
                for_controller,
            },
            now,
        ),
    }
}

#[derive(Subcommand)]
enum ProcessOp {
    /// The identity of a live pid.
    Identity { pid: u32 },
    /// Whether an identity still runs.
    Live { pid: u32, start: String },
}

/// What a launch records: the pane, the command, and the identities read
/// so far. Written at launch and healed by `inspect` as the harness comes up.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct LaunchRecord {
    harness: Harness,
    intent: LaunchIntent,
    command_line: String,
    pane: tmux::Pane,
    launched_at: String,
    /// The harness process holding the pane, read once it is up and the
    /// only process a later read confirms.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    harness_process: Option<Identity>,
    /// The native session the harness recorded for the cwd, bound once it
    /// is up: by the id the launch fixed, else as the one lead session for
    /// the cwd that appeared after the window opened and stood in no
    /// `baseline`. Never the newest file by its age.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    native_session: Option<session::SessionRef>,
    /// The lead session ids for the cwd under the launch's home before the
    /// window opened, the floor `native_session` is bound above for a
    /// harness whose launch fixes no id. Three-valued:
    /// absent where no baseline was read (the launch fixed an id, named no
    /// home, or the record predates the field), when nothing binds by
    /// appearance; present and empty where the store held no lead for the
    /// cwd, when exactly one appeared lead binds; present and filled as
    /// read.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    baseline: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    stopped: Option<StopRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StopRecord {
    at: String,
    outcome: process::Stop,
    window: Close,
}

/// What `inspect` read: the pane by its exact id, the recorded harness and
/// whether it still runs, the native session and the judged state. Each
/// read is three-valued; an unreadable pane or process is
/// printed as such, never as absent.
#[derive(Debug, Serialize)]
struct Inspection {
    pane: Reading<PaneFields>,
    harness_process: Option<Identity>,
    harness_live: Option<Reading<Identity>>,
    native_session: Option<session::SessionRef>,
    /// Why `native_session` is null though the store was asked: the cause
    /// word of the read that failed. Absent when the store was read whole,
    /// or not asked.
    #[serde(skip_serializing_if = "Option::is_none")]
    native_session_unreadable: Option<&'static str>,
    state: State,
    screen_tail: Vec<String>,
}

fn read_record(path: &Path) -> Result<(LaunchRecord, u64, Map<String, serde_json::Value>)> {
    let loaded = record::read::<LaunchRecord>(path, RECORD_VERSIONS)?.ok_or_else(|| {
        Error::refused("record-missing", &[("path", &path.display().to_string())])
    })?;
    Ok((loaded.body, loaded.revision, loaded.extra))
}

/// The harness's process names for this record: its own, and the configured
/// program's where the intent names one.
fn owns(rec: &LaunchRecord) -> impl Fn(&str) -> bool + '_ {
    move |name| {
        rec.harness
            .owns_process_of(rec.intent.program.as_deref(), name)
    }
}

/// The harness holding the pane with no identity recorded: the nearest
/// harness-named process under the pane's own, by one table read. `Gone`
/// when no harness process runs under the pane.
fn harness_identity(rec: &LaunchRecord) -> Reading<Identity> {
    let fields = match tmux::pane_fields(&rec.pane.server, &rec.pane.id) {
        Reading::Live(fields) => fields,
        Reading::Gone => return Reading::Gone,
        Reading::Unreadable { cause } => return Reading::Unreadable { cause },
    };
    let rows = match process::table() {
        Ok(rows) => rows,
        Err(Unreadable { cause }) => return Reading::Unreadable { cause },
    };
    let below = process::below(&rows, fields.pid, &owns(rec));
    let Some((_, pid)) = below.first() else {
        return Reading::Gone;
    };
    process::identity(*pid)
}

/// The inspection of a pane that was not read live: nothing of it judged.
fn unjudged(rec: &LaunchRecord, pane: Reading<PaneFields>, cause: &str) -> Inspection {
    Inspection {
        pane,
        harness_process: rec.harness_process.clone(),
        harness_live: None,
        native_session: rec.native_session.clone(),
        native_session_unreadable: None,
        state: State::Unjudged {
            cause: cause.to_owned(),
        },
        screen_tail: Vec::new(),
    }
}

/// What the store answered when the record's native session was asked for.
enum Binding {
    Bound(session::SessionRef),
    /// Nothing binds yet: the fixed id's file is not written, no lead or
    /// several appeared, or no baseline was read to bind above.
    Unbound,
    /// A read failed; nothing is bound over an unread store.
    Unreadable(&'static str),
}

/// The record's native session, bound by its fixed id where the launch
/// fixed one (the file that id names under `home`, once written), else as
/// the one lead for the cwd that appeared at or after the launch and stood
/// in no baseline. None or several bind nothing; a record that predates
/// the baseline and fixed no id binds nothing either, since nothing tells
/// its session from a neighbour's.
fn bound_session(rec: &LaunchRecord, home: &Path) -> Binding {
    if let Some(id) = &rec.intent.session_id {
        let Some(file) = session::fixed_file(rec.harness, home, &rec.intent.cwd, id) else {
            return Binding::Unbound;
        };
        match std::fs::metadata(&file) {
            Ok(meta) if meta.is_file() => {}
            Ok(_) => return Binding::Unbound,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Binding::Unbound,
            Err(_) => return Binding::Unreadable("session-file-unreadable"),
        }
        return match session::identify(rec.harness, &file, Some(&rec.intent.cwd)) {
            Ok(Some(found)) => Binding::Bound(found),
            Ok(None) => Binding::Unbound,
            Err(_) => Binding::Unreadable("session-file-unreadable"),
        };
    }
    // A record with no baseline read binds nothing by appearance: nothing
    // tells its session from a neighbour's. An empty baseline
    // was read, and the one lead that appeared over it is the launch's.
    let Some(baseline) = &rec.baseline else {
        return Binding::Unbound;
    };
    let Some(since) = clock::epoch_secs(&rec.launched_at) else {
        return Binding::Unbound;
    };
    let since = std::time::UNIX_EPOCH + std::time::Duration::from_secs(since);
    match session::new_leads(rec.harness, home, &rec.intent.cwd, since, baseline) {
        Reading::Live(mut appeared) => match appeared.len() {
            1 => Binding::Bound(appeared.remove(0)),
            _ => Binding::Unbound,
        },
        Reading::Gone => Binding::Unbound,
        Reading::Unreadable { cause } => Binding::Unreadable(cause),
    }
}

/// A pane read and its screen judged once: the pane by its exact id, who
/// holds its terminal against the recorded identity, and the state.
struct Judged {
    pane: Reading<PaneFields>,
    /// Who holds the terminal; none when the pane was not read live.
    reading: Option<ProcessReading>,
    state: State,
    screen_tail: Vec<String>,
}

/// Read `pane` and judge its screen for `harness`. Who holds the pane's
/// terminal is read against `recorded` where the caller has one: that
/// identity alone is the harness, and an ended one is read as other, never
/// replaced. With none, the harness-named process now in the
/// foreground is read, for the caller to record.
fn judge_pane(
    harness: Harness,
    owns: &dyn Fn(&str) -> bool,
    pane: &tmux::Pane,
    recorded: Option<&Identity>,
) -> Result<Judged> {
    let fields = match tmux::pane_fields(&pane.server, &pane.id) {
        Reading::Live(fields) => fields,
        Reading::Gone => {
            return Ok(Judged {
                pane: Reading::Gone,
                reading: None,
                state: State::Unjudged {
                    cause: "pane-gone".to_owned(),
                },
                screen_tail: Vec::new(),
            });
        }
        Reading::Unreadable { cause } => {
            return Ok(Judged {
                pane: Reading::Unreadable { cause },
                reading: None,
                state: State::Unjudged {
                    cause: "pane-unreadable".to_owned(),
                },
                screen_tail: Vec::new(),
            });
        }
    };
    let reading = observe::foreground(fields.pid, owns, recorded);
    let screen = tmux::capture(pane)?;
    let state = observe::judge(&screen, harness, &reading, None);
    let screen_tail: Vec<String> = screen
        .lines()
        .rev()
        .filter(|l| !l.trim().is_empty())
        .take(12)
        .map(str::to_owned)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    Ok(Judged {
        pane: Reading::Live(fields),
        reading: Some(reading),
        state,
        screen_tail,
    })
}

fn inspect(rec: &mut LaunchRecord) -> Result<Inspection> {
    let judged = judge_pane(
        rec.harness,
        &owns(rec),
        &rec.pane,
        rec.harness_process.as_ref(),
    )?;
    let fields = match judged.pane {
        Reading::Live(fields) => fields,
        Reading::Gone => return Ok(unjudged(rec, Reading::Gone, "pane-gone")),
        Reading::Unreadable { cause } => {
            return Ok(unjudged(
                rec,
                Reading::Unreadable { cause },
                "pane-unreadable",
            ));
        }
    };
    if let Some(ProcessReading::Harness { identity }) = &judged.reading
        && rec.harness_process.is_none()
    {
        rec.harness_process = Some(identity.clone());
    }
    let harness_live = rec.harness_process.as_ref().map(process::still_runs);
    let mut native_session_unreadable = None;
    if rec.native_session.is_none() {
        let home = rec
            .intent
            .home
            .clone()
            .or_else(|| session::default_home(rec.harness));
        if let Some(home) = home {
            match bound_session(rec, &home) {
                Binding::Bound(found) => rec.native_session = Some(found),
                Binding::Unbound => {}
                Binding::Unreadable(cause) => native_session_unreadable = Some(cause),
            }
        }
    }
    Ok(Inspection {
        pane: Reading::Live(fields),
        harness_process: rec.harness_process.clone(),
        harness_live,
        native_session: rec.native_session.clone(),
        native_session_unreadable,
        state: judged.state,
        screen_tail: judged.screen_tail,
    })
}

/// What a delivery is confirmed by: the session file bound once (a launch
/// record's), or the id the file is found by, or nothing,
/// which no paste can be confirmed against.
enum SessionFile {
    Bound(PathBuf),
    ById {
        home: Option<PathBuf>,
        cwd: PathBuf,
        id: String,
    },
    Unbound,
}

/// The session `deliver` types into: its pane, the harness and the identity
/// holding it, and the file its turn is confirmed in.
struct Session {
    harness: Harness,
    program: Option<PathBuf>,
    pane: tmux::Pane,
    recorded: Option<Identity>,
    file: SessionFile,
}

/// The session a launch record names, inspected once and healed as
/// `inspect` heals it, with the pane judged by that same read.
fn recorded_session(path: &Path) -> Result<(Session, Judged)> {
    let (mut rec, revision, extra) = read_record(path)?;
    let inspection = inspect(&mut rec)?;
    record::write(
        path,
        RECORD_VERSION,
        &rec,
        &extra,
        Expect::Revision(revision),
    )?;
    let judged = Judged {
        pane: inspection.pane,
        reading: None,
        state: inspection.state,
        screen_tail: inspection.screen_tail,
    };
    let file = match rec.native_session {
        Some(bound) => SessionFile::Bound(bound.file),
        None => SessionFile::Unbound,
    };
    Ok((
        Session {
            harness: rec.harness,
            program: rec.intent.program,
            pane: rec.pane,
            recorded: rec.harness_process,
            file,
        },
        judged,
    ))
}

/// How a delivery ended. A paste alone settles nothing: `confirmed` is a
/// user turn the harness wrote to the session's own file after the paste,
/// `unconfirmed` the bound passed with no such turn, `limit` a session with
/// no confirmable route, into which nothing is typed.
#[derive(Debug, Serialize)]
#[serde(tag = "delivery", rename_all = "kebab-case")]
enum Delivery {
    /// `--no-paste`: the state read and the bound file's turn count.
    Read {
        state: State,
        file: PathBuf,
        turns: u64,
    },
    Confirmed {
        outcome: Outcome,
        route: &'static str,
        pane: String,
        bytes: usize,
        file: PathBuf,
        turns_before: u64,
        turns_after: u64,
    },
    Unconfirmed {
        outcome: Outcome,
        cause: &'static str,
        pane: String,
        file: PathBuf,
        turns_before: u64,
    },
    Limit {
        harness: Harness,
        cause: &'static str,
    },
}

/// How often the session file is read for the confirming turn.
const TURN_POLL: Duration = Duration::from_millis(250);

/// Type `text` into the session's pane when `judged` read it idle, and
/// confirm the delivery by a user turn in its own file within `bound`.
/// `None` text reads the state and the turn count alone. `turns_before` is
/// the count an earlier read gave, else the file is counted now, before
/// the paste.
fn deliver(
    session: &Session,
    judged: Judged,
    text: Option<&str>,
    force: bool,
    turns_before: Option<u64>,
    bound: Duration,
) -> Result<Delivery> {
    let pane_id = session.pane.id.as_str();
    match &judged.pane {
        Reading::Live(_) => {}
        Reading::Gone => return Err(Error::refused("pane-gone", &[("pane", pane_id)])),
        Reading::Unreadable { cause } => {
            return Err(Error::refused(
                "pane-unreadable",
                &[("pane", pane_id), ("cause", cause)],
            ));
        }
    }
    if !force && judged.state != State::Idle {
        let word = serde_json::to_value(&judged.state)
            .ok()
            .and_then(|v| v.get("state").and_then(|s| s.as_str()).map(str::to_owned))
            .unwrap_or_else(|| "unjudged".to_owned());
        return Err(Error::refused(
            "deliver-refused",
            &[("pane", pane_id), ("state", &word)],
        ));
    }
    let harness = session.harness;
    let file = match &session.file {
        SessionFile::Bound(path) => path.clone(),
        SessionFile::Unbound => {
            return Ok(Delivery::Limit {
                harness,
                cause: "session-unbound",
            });
        }
        SessionFile::ById { home, cwd, id } => {
            let Some(home) = home else {
                return Ok(Delivery::Limit {
                    harness,
                    cause: "home-unknown",
                });
            };
            match session::fixed_id_file(harness, home, cwd, id) {
                Reading::Live(path) => path,
                // Not written yet: a harness whose fixed id names the path
                // writes it with the first turn, which is the turn awaited;
                // one that names no path has no file to confirm in.
                Reading::Gone => match session::fixed_file(harness, home, cwd, id) {
                    Some(path) => path,
                    None => {
                        return Ok(Delivery::Limit {
                            harness,
                            cause: "session-file-absent",
                        });
                    }
                },
                Reading::Unreadable { cause } => {
                    return Err(Error::refused(
                        "session-store-unreadable",
                        &[("home", &home.display().to_string()), ("cause", cause)],
                    ));
                }
            }
        }
    };
    let before = match turns_before {
        Some(n) => n,
        None => session::user_turns(harness, &file)? as u64,
    };
    let Some(text) = text else {
        return Ok(Delivery::Read {
            state: judged.state,
            file,
            turns: before,
        });
    };
    let text = text.trim_end_matches('\n');
    // A line that never reached the pane is refused as unsent, so the
    // caller may type it again; a paste asked and not answered may stand in
    // the pane, and only its turn says whether it went in.
    let loaded = tmux::load_line(&session.pane, text)
        .map_err(|e| Error::refused("paste-unsent", &[("cause", e.key())]))?;
    let pasted = loaded.paste();
    let deadline = Instant::now() + bound;
    let unconfirmed = |cause: &'static str| Delivery::Unconfirmed {
        outcome: Outcome::Unconfirmed,
        cause,
        pane: pane_id.to_owned(),
        file: file.clone(),
        turns_before: before,
    };
    if pasted.is_err() {
        return Ok(unconfirmed("paste-unanswered"));
    }
    loop {
        let after = session::user_turns(harness, &file)? as u64;
        if after > before {
            return Ok(Delivery::Confirmed {
                outcome: Outcome::Confirmed,
                route: "pane-paste",
                pane: pane_id.to_owned(),
                bytes: text.len(),
                file,
                turns_before: before,
                turns_after: after,
            });
        }
        match tmux::pane_fields(&session.pane.server, pane_id) {
            Reading::Live(_) => {}
            Reading::Gone => return Ok(unconfirmed("pane-gone")),
            Reading::Unreadable { .. } => return Ok(unconfirmed("pane-unreadable")),
        }
        if Instant::now() >= deadline {
            return Ok(unconfirmed("turn-pending"));
        }
        std::thread::sleep(TURN_POLL);
    }
}

#[allow(
    clippy::disallowed_methods,
    reason = "the session command's own launch and exact stop of the one session its record names"
)]
fn run(cli: Cli) -> Result<serde_json::Value> {
    match cli.verb {
        Verb::Version => Ok(serde_json::json!({
            "protocol": protocol::PROTOCOL,
            "crate": env!("CARGO_PKG_VERSION"),
        })),
        Verb::Probe { harness: name } => {
            let targets: Vec<Harness> = match name {
                Some(n) => vec![Harness::named(&n)?],
                None => Harness::ALL.to_vec(),
            };
            let mut rows = Vec::new();
            for h in targets {
                match harness::probe(h) {
                    Ok(installed) => rows.push(serde_json::to_value(installed).unwrap_or_default()),
                    Err(e) => rows.push(serde_json::json!({
                        "harness": h.name(),
                        "missing": protocol::diagnostic_line(&e),
                    })),
                }
            }
            Ok(serde_json::Value::Array(rows))
        }
        Verb::Launch {
            intent,
            record: record_path,
            socket,
            session,
            window_name,
        } => {
            let text =
                std::fs::read_to_string(&intent).map_err(|e| Error::io("read", &intent, e))?;
            let intent: LaunchIntent =
                serde_json::from_str(&text).map_err(|source| Error::Json {
                    path: intent.clone(),
                    source,
                })?;
            let command = launch::build(&intent)?;
            if let Some(brief) = &command.brief_path
                && !brief.is_file()
            {
                return Err(Error::refused(
                    "brief-file-missing",
                    &[("path", &brief.display().to_string())],
                ));
            }
            let socket = match socket {
                Some(socket) => socket,
                None => tmux::ambient_socket()?,
            };
            let server = tmux::server(&socket)?;
            if !tmux::session_present(&server, &session)? {
                return Err(Error::refused(
                    "tmux-session-missing",
                    &[
                        ("session", &session),
                        ("socket", &socket.display().to_string()),
                    ],
                ));
            }
            let line = command.shell_line();
            // The leads that stand before the window opens, so the one that
            // appears after it is the launch's own. A store that cannot be
            // read is no baseline: the launch is refused before any window
            // opens rather than recording a floor it does not have.
            let baseline = match intent
                .home
                .clone()
                .or_else(|| session::default_home(intent.harness))
            {
                Some(home) if intent.session_id.is_none() => {
                    match session::lead_ids(intent.harness, &home, &intent.cwd) {
                        Reading::Live(ids) => Some(ids),
                        Reading::Gone => Some(Vec::new()),
                        Reading::Unreadable { cause } => {
                            return Err(Error::refused(
                                "baseline-unreadable",
                                &[("home", &home.display().to_string()), ("cause", cause)],
                            ));
                        }
                    }
                }
                Some(_) | None => None,
            };
            let launched_at = clock::now();
            let pane = match tmux::new_window(&server, &session, &window_name, &intent.cwd) {
                Ok(pane) => pane,
                // A `new-window` that failed after its window opened named
                // the pane, which holds only its shell and no record names:
                // it is closed by its exact id, as a failed record write
                // closes it below.
                Err(tmux::WindowFailed {
                    error,
                    opened: Some(pane),
                }) => {
                    return Err(match tmux::kill_window(&pane) {
                        Close::Closed | Close::AlreadyGone => error,
                        Close::Unreadable { cause } => Error::refused(
                            "launch-window-unclosed",
                            &[
                                ("cause", error.key()),
                                ("close", &cause),
                                ("session", &pane.session),
                                ("window", &pane.window),
                                ("pane", &pane.id),
                            ],
                        ),
                    });
                }
                // A `new-window` that started and gave no answer may have
                // opened the window, and names no pane a record could hold:
                // the refusal says so, with the session and the window's name
                // to find it by.
                Err(tmux::WindowFailed {
                    error:
                        e @ Error::External {
                            operation: "new-window",
                            ..
                        },
                    opened: None,
                }) => {
                    return Err(Error::refused(
                        "launch-window-unanswered",
                        &[
                            ("cause", &e.to_string()),
                            ("session", &session),
                            ("window", &window_name),
                        ],
                    ));
                }
                Err(tmux::WindowFailed {
                    error,
                    opened: None,
                }) => return Err(error),
            };
            let rec = LaunchRecord {
                harness: intent.harness,
                intent,
                command_line: line,
                pane,
                launched_at,
                harness_process: None,
                native_session: None,
                baseline,
                stopped: None,
            };
            // The record names the window before its line is typed, so an
            // `inspect` or a `stop` reads what the launch opened whatever
            // the answer to the line. A window nothing was typed into is
            // closed by its exact id where the record cannot stand or the
            // line never reached it.
            if let Err(e) = record::write(
                &record_path,
                RECORD_VERSION,
                &rec,
                &Map::new(),
                Expect::Absent,
            ) {
                // A window whose close cannot be read may stand holding only
                // its shell, which no record names: the refusal names it.
                return Err(match tmux::kill_window(&rec.pane) {
                    Close::Closed | Close::AlreadyGone => e,
                    Close::Unreadable { cause } => Error::refused(
                        "launch-window-unclosed",
                        &[
                            ("cause", e.key()),
                            ("close", &cause),
                            ("session", &rec.pane.session),
                            ("window", &rec.pane.window),
                            ("pane", &rec.pane.id),
                        ],
                    ),
                });
            }
            let loaded = match tmux::load_line(&rec.pane, &rec.command_line) {
                Ok(loaded) => loaded,
                Err(e) => {
                    let record = record_path.display().to_string();
                    return Err(match tmux::kill_window(&rec.pane) {
                        Close::Closed | Close::AlreadyGone => {
                            let _ = std::fs::remove_file(&record_path);
                            Error::refused("launch-line-unsent", &[("cause", e.key())])
                        }
                        Close::Unreadable { .. } => Error::refused(
                            "launch-line-unsent",
                            &[("cause", e.key()), ("record", &record)],
                        ),
                    });
                }
            };
            if let Err(e) = loaded.paste() {
                return Err(Error::refused(
                    "launch-line-unanswered",
                    &[
                        ("cause", e.key()),
                        ("record", &record_path.display().to_string()),
                    ],
                ));
            }
            Ok(serde_json::to_value(&rec).unwrap_or_default())
        }
        Verb::Inspect {
            record: record_path,
        } => {
            let (mut rec, revision, extra) = read_record(&record_path)?;
            let inspection = inspect(&mut rec)?;
            record::write(
                &record_path,
                RECORD_VERSION,
                &rec,
                &extra,
                Expect::Revision(revision),
            )?;
            Ok(serde_json::to_value(inspection).unwrap_or_default())
        }
        Verb::Deliver {
            record: record_path,
            file,
            line,
            force,
            harness,
            program,
            socket,
            server_pid,
            server_start,
            pane,
            pid,
            start,
            home,
            cwd,
            session_id,
            turns_before,
            no_paste,
            bound_secs,
        } => {
            let text = match (&file, line, no_paste) {
                (_, _, true) => None,
                (Some(file), None, false) => {
                    Some(std::fs::read_to_string(file).map_err(|e| Error::io("read", file, e))?)
                }
                (None, Some(line), false) => Some(line),
                (None, None, false) => {
                    return Err(Error::refused("deliver-text-missing", &[]));
                }
                (Some(_), Some(_), false) => unreachable!("clap refuses --file with --line"),
            };
            let (session, judged) = match (record_path, harness) {
                (Some(path), None) => recorded_session(&path)?,
                (None, Some(name)) => {
                    let harness = Harness::named(&name)?;
                    let (Some(socket), Some(server_pid), Some(pane), Some(cwd)) =
                        (socket, server_pid, pane, cwd)
                    else {
                        unreachable!("clap requires the pane and session facts with --harness")
                    };
                    let recorded = match (pid, start) {
                        (Some(pid), Some(start)) => Some(Identity { pid, start }),
                        (None, _) => None,
                        (Some(_), None) => unreachable!("clap requires --start with --pid"),
                    };
                    let server = match server_start {
                        Some(start) => tmux::Server {
                            socket,
                            pid: server_pid,
                            start,
                        },
                        None => {
                            let live = tmux::server(&socket)?;
                            if live.pid != server_pid {
                                return Err(Error::refused(
                                    "server-unmatched",
                                    &[
                                        ("socket", &socket.display().to_string()),
                                        ("recorded", &server_pid.to_string()),
                                        ("live", &live.pid.to_string()),
                                    ],
                                ));
                            }
                            live
                        }
                    };
                    let pane = tmux::Pane {
                        server,
                        id: pane,
                        window: String::new(),
                        session: String::new(),
                    };
                    let file = match session_id {
                        Some(id) => SessionFile::ById {
                            home: home.or_else(|| session::default_home(harness)),
                            cwd,
                            id,
                        },
                        None => SessionFile::Unbound,
                    };
                    let session = Session {
                        harness,
                        program,
                        pane,
                        recorded,
                        file,
                    };
                    let owns = |name: &str| {
                        session
                            .harness
                            .owns_process_of(session.program.as_deref(), name)
                    };
                    let judged = judge_pane(
                        session.harness,
                        &owns,
                        &session.pane,
                        session.recorded.as_ref(),
                    )?;
                    (session, judged)
                }
                (None, None) => return Err(Error::refused("deliver-session-missing", &[])),
                (Some(_), Some(_)) => unreachable!("clap refuses --record with --harness"),
            };
            Ok(serde_json::to_value(deliver(
                &session,
                judged,
                text.as_deref(),
                force,
                turns_before,
                Duration::from_secs(bound_secs),
            )?)
            .unwrap_or_default())
        }
        Verb::Stop {
            record: record_path,
            grace_secs,
        } => {
            let (mut rec, revision, extra) = read_record(&record_path)?;
            let grace = Duration::from_secs(grace_secs);
            // The recorded harness, else the one read in the pane now; a
            // read that fails stops nothing and refuses with its cause.
            let identity = match rec.harness_process.clone() {
                Some(id) => Reading::Live(id),
                None => harness_identity(&rec),
            };
            let outcome = match identity {
                Reading::Live(id) => process::stop_tree(&id, &owns(&rec), grace)?,
                Reading::Gone => process::Stop::AlreadyGone,
                Reading::Unreadable { cause } => {
                    return Err(Error::refused(
                        "harness-unreadable",
                        &[("pane", &rec.pane.id), ("cause", cause)],
                    ));
                }
            };
            // The window is the launch's own: closed whole, and only once
            // the stop confirmed every process it names ended.
            let window = match &outcome {
                process::Stop::Stopped { .. } | process::Stop::AlreadyGone => {
                    tmux::kill_window(&rec.pane)
                }
                process::Stop::IdentityStale
                | process::Stop::Timeout { .. }
                | process::Stop::Unreadable { .. } => Close::Unreadable {
                    cause: "stop-unconfirmed".to_owned(),
                },
            };
            rec.stopped = Some(StopRecord {
                at: clock::now(),
                outcome: outcome.clone(),
                window: window.clone(),
            });
            record::write(
                &record_path,
                RECORD_VERSION,
                &rec,
                &extra,
                Expect::Revision(revision),
            )?;
            Ok(serde_json::json!({
                "stop": outcome,
                "window": window,
            }))
        }
        Verb::Judge {
            screen,
            harness: name,
            process: reading,
        } => {
            let h = Harness::named(&name)?;
            let text =
                std::fs::read_to_string(&screen).map_err(|e| Error::io("read", &screen, e))?;
            let reading = match reading.as_str() {
                "shells-only" => ProcessReading::ShellsOnly,
                "harness-up" => ProcessReading::HarnessUp,
                "unread" => ProcessReading::Unread {
                    cause: "caller-asserted",
                },
                other => {
                    return Err(Error::refused(
                        "process-reading-unknown",
                        &[("value", other)],
                    ));
                }
            };
            Ok(serde_json::to_value(observe::judge(&text, h, &reading, None)).unwrap_or_default())
        }
        Verb::SessionFile {
            harness: name,
            home,
            cwd,
            id,
        } => {
            let h = Harness::named(&name)?;
            Ok(match session::fixed_id_file(h, &home, &cwd, &id) {
                Reading::Live(file) => serde_json::json!({"reading": "live", "file": file}),
                Reading::Gone => serde_json::json!({"reading": "gone"}),
                Reading::Unreadable { cause } => {
                    serde_json::json!({"reading": "unreadable", "cause": cause})
                }
            })
        }
        // Both print the reading whole: `live` with the identity, `gone`,
        // or `unreadable` with its cause.
        Verb::Process { op } => match op {
            ProcessOp::Identity { pid } => {
                Ok(serde_json::to_value(process::identity(pid)).unwrap_or_default())
            }
            ProcessOp::Live { pid, start } => Ok(serde_json::to_value(process::still_runs(
                &Identity { pid, start },
            ))
            .unwrap_or_default()),
        },
        Verb::Accounts { op } => accounts_verb(op),
        Verb::Controller { op } => controller_verb(op),
    }
}

/// What the hand-over's verbs read: the engine's, the launch's and the
/// hand-over's keys, the account keys the choice judges with, the homes an
/// accountless launch inherits, and the checkout the command runs in.
struct HandOverSettings {
    roots: settings::Roots,
    engine: settings::EngineSettings,
    launch: settings::LaunchSettings,
    controller: settings::ControllerSettings,
    accounts: AccountSettings,
    copilot_home: Option<String>,
    pi_root: Option<String>,
}

/// The Pi root an accountless Pi launch runs under.
const PI_ROOT_KEY: &str = "PI_CODING_AGENT_DIR";

impl HandOverSettings {
    fn load() -> Result<HandOverSettings> {
        let accounts = AccountSettings::load()?;
        let cwd = std::env::current_dir().map_err(|e| Error::io("read", ".", e))?;
        let roots = settings::roots(&cwd)?;
        let environment: Vec<(std::ffi::OsString, std::ffi::OsString)> =
            std::env::vars_os().collect();
        let keys = settings::Keys {
            read: &[settings::ENGINE_KEYS, &[COPILOT_HOME_KEY, PI_ROOT_KEY]],
            load: &[],
        };
        let values = settings::layered(&roots.project, &environment, true, &keys)?;
        Ok(HandOverSettings {
            engine: settings::EngineSettings::read(&values),
            launch: settings::LaunchSettings::read(&values),
            controller: settings::ControllerSettings::read(&values),
            copilot_home: values.get(COPILOT_HOME_KEY).map(str::to_owned),
            pi_root: values.get(PI_ROOT_KEY).map(str::to_owned),
            accounts,
            roots,
        })
    }

    fn effect_settings(&self) -> controller::effect::Settings<'_> {
        controller::effect::Settings {
            engine: &self.engine,
            launch: &self.launch,
            controller: &self.controller,
            // A controller that is not orch's runs no other package's setup.
            inherited: agent_runtime::effects::prepare::Inherited {
                copilot_home: self.copilot_home.as_deref(),
                pi_root: self.pi_root.as_deref(),
                setups: &[],
            },
            opener: |_, _| agent_runtime::effects::prepare::OpenerEnv::default(),
        }
    }
}

/// A controller start launches no companion of agent-runtime's own: a
/// request naming one is the opener's, and refuses here.
fn no_companion(path: &Path) -> Result<controller::effect::CompanionFiles> {
    Err(Error::refused(
        "companion-unsupported",
        &[("record", &path.display().to_string())],
    ))
}

/// The hand-over's run over the record at `path`: its files beside the
/// record, its owner notice and its server as `reach` names them, its
/// outcomes through the controller's arm, its jobs through `controller job`.
fn hand_over_run<'a>(
    path: &'a Path,
    reach: agent_runtime::effects::Reach,
    loaded: &'a HandOverSettings,
    settings: &'a controller::effect::Settings<'a>,
    env: &'a Env,
) -> controller::effect::Run<'a> {
    controller::effect::Run {
        engine: agent_runtime::effects::Run {
            speaker: "agent-runtime",
            path,
            settings: &loaded.engine,
            state_dir: path.parent().unwrap_or(Path::new(".")).to_path_buf(),
            close_grace: settings::Judged::of(
                "close-grace",
                Ok(std::time::Duration::from_secs(HAND_OVER_CLOSE_SECS)),
            ),
            reach,
            env,
            locking: record::Locking::FLOCK,
            clock: &clock::SystemClock,
            outcome_arm: controller::transition::outcome_arm,
            job_words: controller::run::job_words,
        },
        settings,
        companion: no_companion,
    }
}

/// No controller effect closes a lane; the engine's close grace is a
/// lane's, held at its default.
const HAND_OVER_CLOSE_SECS: u64 = 15;

/// A request file's body, or `request-invalid` naming the file and why.
fn request_file<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
    let bytes = std::fs::read(path).map_err(|e| Error::io("read-request", path, e))?;
    serde_json::from_slice(&bytes).map_err(|e| {
        Error::refused(
            "request-invalid",
            &[
                ("path", &path.display().to_string()),
                ("cause", &e.to_string()),
            ],
        )
    })
}

/// Print `value` as the reply and exit by `status`, the effect's own.
fn replied(value: serde_json::Value, status: i32) -> ! {
    let _ = writeln!(
        std::io::stdout().lock(),
        "{}",
        serde_json::to_string(&Reply::ok(value)).unwrap_or_default()
    );
    std::process::exit(status);
}

/// One controller request answered, with `--effect-exit` exiting by the
/// effect's outcome.
fn hand_over(
    run: &controller::effect::Run,
    request: &controller::transition::Request,
    effect_exit: bool,
) -> Result<serde_json::Value> {
    let answered = controller::run::request(run, request)?;
    let mut reply = serde_json::to_value(&answered).map_err(|source| Error::Json {
        path: run.engine.path.to_path_buf(),
        source,
    })?;
    if effect_exit && let Some(effected) = &answered.effect {
        let settled = controller::run::settle(
            run.engine.path,
            effected,
            controller::run::job_bound(run.settings.engine)?,
            &clock::SystemClock,
        )?;
        reply["settled"] = serde_json::to_value(settled.intent()).unwrap_or_default();
        let status = settled.status();
        if status != 0 {
            replied(reply, status);
        }
    }
    Ok(reply)
}

fn controller_verb(op: ControllerOp) -> Result<serde_json::Value> {
    use controller::transition::Request;
    let loaded = HandOverSettings::load()?;
    let env = Env::system()?;
    let effect_settings = loaded.effect_settings();
    match op {
        ControllerOp::Successor {
            record,
            cwd,
            predecessor,
            mark,
            recover,
            handoff,
            preference,
        } => {
            if recover {
                let pane = predecessor.as_deref().unwrap_or_default();
                return controller::successor::recovery(&loaded.launch, &record, pane);
            }
            let now = clock::Clock::wall(&clock::SystemClock)
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs());
            let accounts_env = loaded.accounts.env();
            // The choice judges no rate mark of its own: the marks are the
            // opener's, so the wall a rate projects is never reached here.
            let no_wall = settings::Judged::of("wall-minutes", Ok(0));
            let called = preference.map(|preference| settings::ControllerSettings {
                preference,
                preference_set: true,
                ..loaded.controller.clone()
            });
            let choosing = controller::successor::Choosing {
                accounts: loaded.accounts.env(),
                launch: &loaded.launch,
                controller: called.as_ref().unwrap_or(&loaded.controller),
                wall_minutes: &no_wall,
            };
            let project = loaded.accounts.project.clone();
            let mut walk = |request: &accounts::walk::WalkRequest| {
                accounts::here::walk(&accounts_env, &project, Some(&record), request, now)
            };
            let pick_env = loaded.accounts.env();
            let mut pick =
                |request: &accounts::PickRequest, _: Option<&str>| match accounts::here::pick(
                    &pick_env,
                    &project,
                    Some(&record),
                    request,
                    now,
                ) {
                    Ok(answer) => answer,
                    Err(e) => accounts::PickAnswer::Unjudged {
                        cause: e.to_string(),
                    },
                };
            controller::successor::successor(
                &choosing,
                &record,
                predecessor.as_deref(),
                mark,
                &cwd,
                handoff.as_deref(),
                controller::successor::Ground {
                    walk: &mut walk,
                    pick: &mut pick,
                },
                now,
            )
        }
        ControllerOp::Start {
            record,
            request,
            effect_exit,
            reach,
        } => {
            let reach = reach.named(&record)?;
            let r = Request::StartController(Box::new(request_file(&request)?));
            let run = hand_over_run(&record, reach, &loaded, &effect_settings, &env);
            hand_over(&run, &r, effect_exit)
        }
        ControllerOp::Transfer {
            record,
            request,
            effect_exit,
            reach,
        } => {
            let reach = reach.named(&record)?;
            let r = Request::RequestTransfer(Box::new(request_file(&request)?));
            let run = hand_over_run(&record, reach, &loaded, &effect_settings, &env);
            hand_over(&run, &r, effect_exit)
        }
        ControllerOp::Stop {
            record,
            effect_exit,
            reach,
        } => {
            let reach = reach.named(&record)?;
            let r = Request::StopController(controller::transition::StopController {});
            let run = hand_over_run(&record, reach, &loaded, &effect_settings, &env);
            hand_over(&run, &r, effect_exit)
        }
        ControllerOp::Adopt {
            record,
            account,
            request,
            pane,
            named,
        } => {
            let r: controller::AdoptController = match (request, pane) {
                (Some(request), _) => request_file(&request)?,
                (None, Some(pane)) => named.request(pane, account),
                (None, None) => {
                    return Ok(agent_runtime::effects::register_controller(
                        &record,
                        account.as_deref(),
                        &loaded.engine,
                        &loaded.roots.common,
                        record::Locking::FLOCK,
                    )?
                    .0);
                }
            };
            let adopted = agent_runtime::effects::adopt_controller(
                &record,
                &r,
                &loaded.engine,
                record::Locking::FLOCK,
            )?;
            serde_json::to_value(adopted).map_err(|source| Error::Json {
                path: record.clone(),
                source,
            })
        }
        ControllerOp::Status {
            record,
            server,
            socket,
            pane,
            harness,
            home,
            session,
        } => {
            let caller = server
                .as_deref()
                .map(|server| controller::status::CallerKey {
                    server,
                    socket: socket.as_deref(),
                    pane: pane.as_deref().unwrap_or_default(),
                    harness: &harness,
                    home: &home,
                    session: &session,
                });
            let status = controller::status::status(&record, &loaded.engine, caller.as_ref())?;
            serde_json::to_value(status).map_err(|source| Error::Json {
                path: record.clone(),
                source,
            })
        }
        ControllerOp::Reconcile { record, reach } => {
            let reach = reach.named(&record)?;
            let run = hand_over_run(&record, reach, &loaded, &effect_settings, &env);
            let reconciled = controller::run::reconcile(&run)?;
            serde_json::to_value(reconciled).map_err(|source| Error::Json {
                path: record.clone(),
                source,
            })
        }
        ControllerOp::Handoff {
            record,
            body,
            handoff,
            keep_prior,
        } => {
            let written = controller::handoff::write(
                &record,
                &body,
                &handoff,
                keep_prior,
                &controller::handoff::Opener {
                    misplaced: &|_| None,
                    amend: &|text| Ok(text.to_owned()),
                },
                &env,
            )?;
            serde_json::to_value(written).map_err(|source| Error::Json {
                path: record.clone(),
                source,
            })
        }
        ControllerOp::Job {
            record,
            intent,
            reach,
        } => {
            let reach = reach.named(&record)?;
            let run = hand_over_run(&record, reach, &loaded, &effect_settings, &env);
            let recorded = controller::run::run_job(&run, &intent)?;
            serde_json::to_value(recorded).map_err(|source| Error::Json {
                path: record.clone(),
                source,
            })
        }
    }
}

/// Exit status of a usage error, clap's convention.
const USAGE_EXIT: i32 = 2;

fn main() {
    // The account renewal re-executes this program for its step, apart
    // from the caller's process group.
    if accounts::renewal_step(std::env::args_os().nth(1).as_deref()) {
        return;
    }
    let stdout = std::io::stdout();
    let stderr = std::io::stderr();
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(e) if matches!(e.kind(), ErrorKind::DisplayHelp | ErrorKind::DisplayVersion) => {
            let _ = e.print();
            return;
        }
        Err(e) => {
            let _ = writeln!(stderr.lock(), "agent-runtime: usage");
            let _ = writeln!(stderr.lock(), "{e}");
            std::process::exit(USAGE_EXIT);
        }
    };
    match run(cli) {
        Ok(value) => {
            let reply = Reply::ok(value);
            let _ = writeln!(
                stdout.lock(),
                "{}",
                serde_json::to_string(&reply).unwrap_or_default()
            );
        }
        Err(error) => {
            let _ = writeln!(stderr.lock(), "{}", protocol::diagnostic_line(&error));
            let _ = writeln!(stderr.lock(), "{error}");
            let reply: Reply<()> = Reply::refused(&error);
            let _ = writeln!(
                stdout.lock(),
                "{}",
                serde_json::to_string(&reply).unwrap_or_default()
            );
            std::process::exit(1);
        }
    }
}
