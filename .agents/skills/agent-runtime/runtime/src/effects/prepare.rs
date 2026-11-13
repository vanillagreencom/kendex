//! What a launch resolves before its window opens, a lane's and a
//! controller's alike: the command spelled from its spec, the program and
//! directory preflights, the home it runs under with its trust record and
//! harness gate ([`gate`]), and the runtimes of its install built.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};

use super::{ProcessReading, State};
use crate::error::{Error, Result};
use crate::harness::Harness;
use crate::host::{self, Place};
use crate::launch::{Brief, Compaction, LaunchCommand, LaunchIntent, Permission, QuestionTool};
use crate::settings::{EngineSettings, LaunchSettings};
use crate::trust;

pub mod gate;

/// What the opener hands every launch's preparation: the homes an
/// accountless launch inherits where its launch names none (`COPILOT_HOME`
/// and `PI_CODING_AGENT_DIR` as the opener's settings load read them), and
/// the setups the pre-window build runs.
#[derive(Debug, Clone, Copy, Default)]
pub struct Inherited<'a> {
    pub copilot_home: Option<&'a str>,
    pub pi_root: Option<&'a str>,
    /// The setups that build the runtimes a launch's harness reaches, each
    /// relative to the launch's directory and run there in order, where the
    /// first stands: that directory's own install. None named builds nothing.
    pub setups: &'a [&'a str],
}

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    Error::refused(key, fields)
}

/// What the opener hands its session beside the builder's words, as the
/// intent's members of the same names: the variables it sets, the ones it
/// clears, and the variable a Codex session's compaction reading is written
/// under. The variables are the opener's own, so the builder copies them and
/// names none; an opener with none of its own passes the default.
#[derive(Debug, Clone, Default)]
pub struct OpenerEnv {
    pub env: BTreeMap<String, String>,
    pub env_remove: Vec<String>,
    pub compaction_env: Option<String>,
}

/// What one launch runs: the harness, its home and the account it spends,
/// model, effort, working directory, opening brief, the permission posture
/// and question-tool posture, its own compaction, the caller's own words and
/// the opener's environment, as a launch or a succession resolved them. The
/// command is spelled from these by agent-runtime's one builder; no recorded
/// line is executed.
pub struct Spec<'a> {
    pub harness: Harness,
    /// The harness's own home, where its native sessions are read.
    pub home: Option<&'a Path>,
    /// The account the launch spends, routed by the builder's table.
    pub account: Option<&'a Path>,
    pub model: Option<&'a str>,
    pub effort: Option<&'a str>,
    pub cwd: &'a Path,
    pub brief: Option<&'a Path>,
    /// The posture the caller judged; `None` takes the settings' posture.
    pub permission: Option<Permission>,
    pub question_tool: QuestionTool,
    pub compaction: Compaction,
    /// The session id the launch fixes, for a harness that takes one.
    pub session_id: Option<&'a str>,
    /// The caller's own words, appended as given.
    pub extra_args: &'a [String],
    pub opener: &'a OpenerEnv,
}

/// The intent the harness launches under, built from a spec and the settings
/// posture. `program` is the configured executable for the harness, so a
/// test selects its stub through the one binary-path setting. The caller's
/// words and the judged posture must agree under the builder's table:
/// a `native` posture whose words carry the harness's
/// bypass word refuses `permission-mismatch` before any window; under
/// `bypass` the words are preserved as given and the builder adds no
/// duplicate permission word.
pub fn build_launch(
    launch: &LaunchSettings,
    engine: &EngineSettings,
    spec: &Spec,
) -> Result<(LaunchIntent, LaunchCommand)> {
    let permission = spec
        .permission
        .map_or_else(|| launch.permission.get(), Ok)?;
    if permission == Permission::Native
        && let Some(word) = spec.harness.bypass_word_in(spec.extra_args)
    {
        return Err(refused(
            "permission-mismatch",
            &[
                ("harness", spec.harness.name()),
                ("posture", "native"),
                ("word", &word),
            ],
        ));
    }
    let intent = LaunchIntent {
        harness: spec.harness,
        home: spec.home.map(Path::to_path_buf),
        account: spec.account.map(Path::to_path_buf),
        cwd: spec.cwd.to_path_buf(),
        model: spec.model.map(str::to_owned),
        effort: spec.effort.map(str::to_owned),
        permission,
        question_tool: spec.question_tool,
        compaction: spec.compaction,
        brief: match spec.brief {
            Some(path) => Brief::File {
                path: path.to_path_buf(),
            },
            None => Brief::None,
        },
        resume: None,
        session_id: spec.session_id.map(str::to_owned),
        env: spec.opener.env.clone(),
        env_remove: spec.opener.env_remove.clone(),
        compaction_env: spec.opener.compaction_env.clone(),
        extra_args: spec.extra_args.to_vec(),
        program: engine.harness_binaries.get()?.remove(&spec.harness),
    };
    let command = crate::launch::build(&intent)?;
    Ok((intent, command))
}

/// Whether the command's program will run: a path names an existing file,
/// a bare name is found on this process's `PATH`, the same lookup the
/// pane's shell makes. The shell reads an unreadable path as no program,
/// so this preflight answers the same and refuses `harness-binary-missing`.
#[allow(
    clippy::disallowed_methods,
    reason = "the launch line's program preflight answers as the pane's shell will: an unreadable path is no program"
)]
pub fn check_program(command: &LaunchCommand) -> Result<()> {
    let program = Path::new(&command.program);
    let found = if program.components().count() > 1 {
        program.is_file()
    } else {
        std::env::var_os("PATH")
            .is_some_and(|path| std::env::split_paths(&path).any(|dir| dir.join(program).is_file()))
    };
    if found {
        Ok(())
    } else {
        Err(refused(
            "harness-binary-missing",
            &[("program", &command.program)],
        ))
    }
}

/// Whether the launch can start in `dir`: the shell's `cd` reads an
/// unreadable path as no directory, so this preflight refuses `key` for one
/// too.
#[allow(
    clippy::disallowed_methods,
    reason = "the launch directory's preflight answers as the pane's shell will: an unreadable path is no directory"
)]
pub fn check_directory(key: &'static str, dir: &Path) -> Result<()> {
    if dir.is_dir() {
        Ok(())
    } else {
        Err(refused(key, &[("path", &dir.display().to_string())]))
    }
}

/// The brief's text, or `brief-unreadable` naming the file.
pub fn read_brief(brief: &Path) -> Result<String> {
    std::fs::read_to_string(brief).map_err(|e| {
        refused(
            "brief-unreadable",
            &[
                ("path", &brief.display().to_string()),
                ("cause", &e.to_string()),
            ],
        )
    })
}

pub fn up(state: &State) -> bool {
    matches!(state, State::Idle | State::Working)
}

pub fn idle(state: &State) -> bool {
    *state == State::Idle
}

/// The observation a pending reading leaves on the record.
pub fn pending_observation(reading: &ProcessReading, state: &State) -> Value {
    json!({
        "process": serde_json::to_value(reading).unwrap_or(Value::Null),
        "state": serde_json::to_value(state).unwrap_or(Value::Null),
    })
}

/// The bound on one package's setup before a window opens: a first build
/// that compiles every locked dependency runs for minutes.
const SETUP_BOUND: Duration = Duration::from_secs(1200);

/// The key a harness gate's refusal stands under where its outcome names one
/// word.
pub const GATE_REFUSED: &str = "launch-gate-refused";

/// Why a launch cannot run where its preparation put it.
pub enum Unready {
    /// A home, account, trust record or other precondition that refused.
    Refused(Error),
    /// The harness gate's refusal, its key then its fields.
    Gate(String),
}

impl From<Error> for Unready {
    fn from(e: Error) -> Unready {
        Unready::Refused(e)
    }
}

/// A home a launch with no account keeps, and whether the launch names it
/// to the child: every kept home is named but an accountless Claude
/// launch's implicit default config dir, which names none.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Kept {
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
pub fn accountless_kept(
    inherited: &Inherited,
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
            inherited_home(inherited, harness).map(|home| Kept {
                home,
                named: harness != Harness::Claude,
            })
        })
}

/// What a launch of `harness` runs under, a lane's or a controller's.
pub struct LaunchHome {
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
fn inherited_home(inherited: &Inherited, harness: Harness) -> Option<PathBuf> {
    let named = match harness {
        Harness::Copilot => inherited.copilot_home,
        Harness::Pi => inherited.pi_root,
        Harness::Claude | Harness::Codex => None,
    };
    named
        .filter(|home| !home.is_empty())
        .map(PathBuf::from)
        .or_else(|| super::default_home(harness))
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
    inherited: &Inherited,
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
            inherited_home(inherited, harness)
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
/// (`accountless_kept` decides which). A launch whose line runs at full
/// bypass (`bypass`) gets the account's consent to it beside the trust
/// record. The harness gate then judges what the harness needs beyond its
/// trust record under the home its sessions are read from, and the runtimes
/// of `cwd`'s install are built last through the setups `inherited` names
/// (`build_runtimes`): a lane's launch and relaunch and a controller's start
/// all pass here before their window.
pub fn launch_home(
    inherited: &Inherited,
    harness: Harness,
    account: Option<&str>,
    model: Option<&str>,
    kept: Option<&Kept>,
    cwd: &Path,
    bypass: bool,
) -> std::result::Result<LaunchHome, Unready> {
    let (home, billed) = named_home(
        inherited,
        harness,
        account,
        model,
        kept.map(|k| k.home.as_path()),
    )?;
    let trusted = home
        .map(|home| prepare_trust(harness, &home, cwd, bypass))
        .transpose()?;
    let mut named = trusted.as_ref().map(|t| t.home.clone());
    let mut cleared = false;
    if let (Harness::Claude, None) = (harness, account) {
        named = kept.filter(|kept| kept.named).map(|kept| kept.home.clone());
        cleared = named.is_none();
    }
    let sessions = named.clone().or_else(|| super::default_home(harness));
    gate::local(harness, sessions.as_deref(), cwd).map_err(Unready::Gate)?;
    build_runtimes(cwd, inherited.setups)?;
    Ok(LaunchHome {
        sessions,
        named,
        cleared,
        account: billed,
        trust: trusted.map(|t| t.route),
    })
}

/// The runtimes of `cwd`'s own install, built through the `setups` the
/// opener names before the window opens, so the harness's first turn end,
/// which reads its mail through them, never meets the sources unbuilt; a
/// key already built builds nothing. A directory where the first setup does
/// not stand builds nothing here: the install its harness runs is not this
/// launch's. A setup that refuses, or gives no answer within its bound,
/// refuses the launch `runtime-unbuilt` with the setup's last line.
#[allow(
    clippy::disallowed_methods,
    reason = "each package's own setup, through the one runner, before the window it serves opens"
)]
fn build_runtimes(cwd: &Path, setups: &[&str]) -> Result<()> {
    if !setups
        .first()
        .is_some_and(|first| cwd.join(first).is_file())
    {
        return Ok(());
    }
    for setup in setups.iter().map(|setup| cwd.join(setup)) {
        let at = setup.display().to_string();
        let out = host::run_tagged_in(
            "launch",
            "setup",
            &setup,
            "build",
            &[],
            Place {
                cwd: Some(cwd),
                env: &[],
            },
            SETUP_BOUND,
        )
        .map_err(|e| {
            refused(
                "runtime-unbuilt",
                &[("setup", &at), ("detail", &e.to_string())],
            )
        })?;
        if !out.status.success() {
            let stderr = host::stderr_text(&out);
            let line = stderr.lines().rev().find(|l| !l.trim().is_empty());
            let status = out
                .status
                .code()
                .map_or_else(|| "signal".to_owned(), |code| code.to_string());
            return Err(refused(
                "runtime-unbuilt",
                &[
                    ("setup", &at),
                    ("status", &status),
                    ("detail", line.unwrap_or("")),
                ],
            ));
        }
    }
    Ok(())
}

/// The trust record a launch of `harness` under `home` needs for `cwd`,
/// made before the window opens; its refusal is the launch's.
#[allow(
    clippy::disallowed_methods,
    reason = "the launch's trust record, written before the window it serves opens, its refusal the launch's own"
)]
fn prepare_trust(
    harness: Harness,
    home: &Path,
    cwd: &Path,
    bypass: bool,
) -> Result<trust::Prepared> {
    trust::prepare(harness, home, cwd, bypass)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A launch whose opener names no setup runs none, though its directory
    /// holds an orch install whose setup would run: the shared preparation
    /// runs no package's setup the opener did not name.
    #[test]
    fn a_launch_whose_opener_names_no_setup_runs_none() {
        let dir = tempfile::tempdir().unwrap();
        let scripts = dir.path().join(".agents/skills/orch/scripts");
        std::fs::create_dir_all(&scripts).unwrap();
        let ran = dir.path().join("ran");
        let setup = scripts.join("setup");
        crate::host::write_executable(&setup, format!("#!/bin/sh\n: > '{}'\n", ran.display()));
        let built = build_runtimes(dir.path(), &[]);
        assert!(!ran.exists(), "a setup ran that the opener did not name");
        built.unwrap();
    }
}
