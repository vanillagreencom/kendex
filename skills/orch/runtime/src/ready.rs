//! Whether what a duty needs is ready on this computer: the one judge, and
//! the one table of what each of orch's duties needs. A duty asks
//! ([`admit`]) before it claims anything and refuses
//! `unready duty=D program=P cause=C fix=F`, exit 1; `orch-runtime ready`
//! prints every duty's answer ([`report`]), and orch's setup prints it at
//! its end. A setting a duty needs reads `setting=K` in place of
//! `program=P`.
//!
//! A runtime built from sources is judged by its own wrapper, which holds
//! the one key reader: `version` answers 0 built. On a computer without
//! cargo an unbuilt key answers 69 at once. With cargo the wrapper opens
//! its stderr with `setup-building` and builds first: within the bound it
//! answers 0, or 69 with the setup's refusal as its last stderr line, read
//! as `unbuilt` with that line; past the bound it reads `building`. Another
//! package's program is judged present and executable only, since each
//! package refuses its own missing tools. A harness's binary stays the
//! launch's own preflight: the walk chooses the harness per launch. A
//! lookup that chooses between two mechanisms (`flock` or the `mkdir`
//! mutex) stays where the choice is made, and the table names what that
//! choice needs. A detached job's launcher falls to `setsid` wherever the
//! service manager does not run its unit, so every duty that starts a job
//! needs `setsid` whether or not `systemd-run` stands.

use std::path::{Path, PathBuf};

use agent_runtime::confine::{Answer, Host, WRAPPER, answer};
use agent_runtime::harness::Harness;
use agent_runtime::host;

use crate::error::{Error, Result};
use crate::settings::{ORCH_SETUP, OwnerAsks, Settings};

/// A wrapper's exit for a runtime whose sources are unbuilt.
const SETUP_REQUIRED: i32 = 69;

/// The fix that installs a missing package's program.
const INSTALL_PACKAGES: &str = "kendex-apply";

/// The refusal's key: a duty on an installation that cannot serve it.
const UNREADY: &str = "unready";

/// The fix where the kernel refuses the wrapper an unprivileged user
/// namespace.
const USERNS_FIX: &str = "enable-unprivileged-user-namespaces";

/// Whether a runtime's wrapper answered `status` for its key unbuilt.
pub fn setup_required(status: Option<i32>) -> bool {
    status == Some(SETUP_REQUIRED)
}

/// The key of the line a wrapper's stderr opens with while it builds the
/// program it found absent.
const SETUP_BUILDING: &str = "setup-building";

/// Whether `line` is a wrapper's `<name>: setup-building ...` line.
fn building(line: &str) -> bool {
    line.split_once(": ")
        .is_some_and(|(_, rest)| rest.split(' ').next() == Some(SETUP_BUILDING))
}

/// The setup's refusal a wrapper's 69 ended on where it built first: the
/// last line of its stderr after a leading `setup-building` line. `None`
/// for the `setup-required` answer of a computer without cargo, which
/// built nothing.
pub fn build_refusal(output: &std::process::Output) -> Option<String> {
    let text = host::stderr_text(output);
    let mut lines = text.lines();
    if !building(lines.next()?) {
        return None;
    }
    lines.last().map(str::to_owned)
}

/// What `duty` lacks where the wrapper of the runtime `program` answered
/// setup-required in the middle of its work: the line its admission prints
/// for the same state, with the setup's refusal `build` where the wrapper
/// built first.
pub fn unbuilt(duty: Duty, program: &str, settings: &Settings, build: Option<String>) -> Unready {
    Unready {
        duty,
        lacks: Lack::Program(program.to_owned()),
        cause: "unbuilt",
        fix: settings
            .roots
            .project
            .join(ORCH_SETUP)
            .display()
            .to_string(),
        build,
    }
}

/// A duty of orch's that asks before it claims anything.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Duty {
    /// `watch run`: the fleet's scheduler, which wakes the overseer through
    /// agent-runtime and reads its mailbox and its panes.
    Watch,
    /// A lane's launch: a window on the fleet's server, a worktree's git,
    /// and the detached jobs its waiters run as.
    Launch,
    /// A controller's start: a window on the fleet's server, and the
    /// detached jobs its watch and its succession run as.
    Controller,
    /// A controller's transfer or stop: a window, and the detached job that
    /// runs it, a service manager unit or a `setsid` group.
    Job,
    /// `register`: the pane it reads.
    Register,
    /// `ci-proof`: GitHub through `gh`, the head through git.
    CiProof,
    /// `reconcile-items`: GitHub through `gh`, the branches through git.
    ReconcileItems,
    /// A round's prune: the worktree program, the worktrees' git.
    Prune,
    /// The overseer, read at its takeover: the settings an owner ask on an
    /// item needs, since `lane-mail ask --issue` refuses without them.
    Overseer,
}

impl Duty {
    /// Every duty, in the order `orch-runtime ready` prints them.
    pub const DUTIES: [Duty; 9] = [
        Duty::Watch,
        Duty::Launch,
        Duty::Controller,
        Duty::Job,
        Duty::Register,
        Duty::CiProof,
        Duty::ReconcileItems,
        Duty::Prune,
        Duty::Overseer,
    ];

    /// The duty's word on a line and in `--duty`.
    pub fn name(self) -> &'static str {
        match self {
            Duty::Watch => "watch",
            Duty::Launch => "launch",
            Duty::Controller => "controller",
            Duty::Job => "job",
            Duty::Register => "register",
            Duty::CiProof => "ci-proof",
            Duty::ReconcileItems => "reconcile-items",
            Duty::Prune => "prune",
            Duty::Overseer => "overseer",
        }
    }

    /// The duty `name` spells, or `duty-unknown name=`.
    pub fn from_word(name: &str) -> Result<Duty> {
        Duty::DUTIES
            .into_iter()
            .find(|duty| duty.name() == name)
            .ok_or_else(|| refused("duty-unknown", &[("name", name)]))
    }
}

/// One program or setting a duty needs, as the judge reads it.
enum Need {
    /// A runtime built from this install's sources, judged by its wrapper.
    Built {
        name: &'static str,
        wrapper: PathBuf,
    },
    /// Another package's program: present and executable.
    Entry { name: &'static str, path: PathBuf },
    /// A program on `PATH`.
    OnPath(&'static str),
    /// The wrapper a confined lane's harness runs under, as agent-runtime's
    /// probe judges it on `PATH`: present, and the kernel lets it make an
    /// unprivileged user namespace.
    Confined,
    /// The owner-ask keys: each key the settings leave unset is lacking.
    OwnerAsks,
}

/// What a duty lacks: a program, or a key its settings leave unset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Lack {
    Program(String),
    Setting(&'static str),
}

impl Lack {
    /// The field naming it on a line and in a refusal, and its value.
    fn field(&self) -> (&'static str, &str) {
        match self {
            Lack::Program(name) => ("program", name),
            Lack::Setting(key) => ("setting", key),
        }
    }
}

/// What a duty lacks on this computer and the fix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Unready {
    pub duty: Duty,
    pub lacks: Lack,
    pub cause: &'static str,
    pub fix: String,
    /// The setup's refusal where the wrapper built first and the build
    /// failed, last on the line, to its end.
    pub build: Option<String>,
}

impl Unready {
    /// The line `orch-runtime ready` prints and the refusal's fields.
    pub fn line(&self) -> String {
        let (field, name) = self.lacks.field();
        let mut line = format!(
            "unready duty={} {field}={name} cause={} fix={}",
            self.duty.name(),
            self.cause,
            self.fix
        );
        if let Some(build) = &self.build {
            line.push_str(&format!(" build={build}"));
        }
        line
    }

    /// The duty's refusal, before it claims anything.
    pub fn refusal(&self) -> Error {
        let mut fields = vec![
            ("duty", self.duty.name()),
            self.lacks.field(),
            ("cause", self.cause),
            ("fix", &self.fix),
        ];
        if let Some(build) = &self.build {
            fields.push(("build", build));
        }
        refused(UNREADY, &fields)
    }
}

/// The table: what `duty` needs, as `settings` name each program.
fn needs(duty: Duty, settings: &Settings) -> Vec<Need> {
    let mail = settings.reach.as_ref().map_or_else(
        || settings.lane_mail_cli.clone(),
        |r| r.mail_program.clone(),
    );
    match duty {
        Duty::Watch => vec![
            Need::Built {
                name: "agent-runtime",
                wrapper: settings.agent_runtime.clone(),
            },
            Need::Entry {
                name: "lane-mail",
                path: mail,
            },
            Need::OnPath("tmux"),
            Need::OnPath("git"),
        ],
        Duty::Launch => vec![
            Need::OnPath("tmux"),
            Need::OnPath("git"),
            Need::OnPath("setsid"),
            Need::Confined,
        ],
        Duty::Controller => vec![Need::OnPath("tmux"), Need::OnPath("setsid")],
        Duty::Job => vec![Need::OnPath("tmux"), Need::OnPath("setsid")],
        Duty::Register => vec![Need::OnPath("tmux")],
        Duty::CiProof | Duty::ReconcileItems => vec![Need::OnPath("gh"), Need::OnPath("git")],
        Duty::Prune => vec![
            Need::Entry {
                name: "worktree",
                path: settings.worktree_cli.clone(),
            },
            Need::OnPath("git"),
        ],
        Duty::Overseer => vec![Need::OwnerAsks],
    }
}

/// What `duty` lacks on this computer, every program it needs judged.
pub fn judge(duty: Duty, settings: &Settings) -> Result<Vec<Unready>> {
    judge_needs(duty, settings, true)
}

fn judge_needs(duty: Duty, settings: &Settings, confined: bool) -> Result<Vec<Unready>> {
    let setup = settings.roots.project.join(ORCH_SETUP);
    let mut lacking = Vec::new();
    for need in needs(duty, settings) {
        let program = |name: &str| Lack::Program(name.to_owned());
        let mut build = None;
        let found: Vec<(Lack, &'static str, String)> = match &need {
            Need::Built { name, wrapper } => built(name, wrapper, settings)?
                .map(|(cause, refusal)| {
                    build = refusal;
                    (program(name), cause, fix_of(cause, &setup))
                })
                .into_iter()
                .collect(),
            Need::Entry { name, path } => executable(path)
                .map(|cause| (program(name), cause, INSTALL_PACKAGES.to_owned()))
                .into_iter()
                .collect(),
            Need::OnPath(name) => on_path(name)
                .is_none()
                .then(|| (program(name), "absent", format!("install-{name}")))
                .into_iter()
                .collect(),
            Need::Confined => confined
                .then(confinement_lacking)
                .flatten()
                .map(|(name, cause, fix)| (program(name), cause, fix))
                .into_iter()
                .collect(),
            Need::OwnerAsks => match &settings.reads.owner_asks {
                OwnerAsks::Configured(_) => Vec::new(),
                OwnerAsks::Unset(keys) => keys
                    .iter()
                    .map(|key| (Lack::Setting(key), "unset", format!("set-{key}")))
                    .collect(),
            },
        };
        lacking.extend(found.into_iter().map(|(lacks, cause, fix)| Unready {
            duty,
            lacks,
            cause,
            fix,
            build: build.clone(),
        }));
    }
    Ok(lacking)
}

/// The duty's admission: `Ok` where everything it needs is ready, else the
/// refusal naming the first program it lacks.
pub fn admit(duty: Duty, settings: &Settings) -> Result<()> {
    match judge(duty, settings)?.first() {
        Some(unready) => Err(unready.refusal()),
        None => Ok(()),
    }
}

pub(crate) fn admit_launch(request: &crate::ops::LaunchLane, settings: &Settings) -> Result<()> {
    let confined = request.unconfined_cause()?.is_none();
    match judge_needs(Duty::Launch, settings, confined)?.first() {
        Some(unready) => Err(unready.refusal()),
        None => Ok(()),
    }
}

/// Every line `orch-runtime ready` prints for `duties`: `ready duty=D`, or
/// one `unready` line per program or setting a duty lacks.
pub fn report(duties: &[Duty], settings: &Settings) -> Result<(Vec<String>, bool)> {
    let mut lines = Vec::new();
    let mut ready = true;
    for &duty in duties {
        let lacking = judge(duty, settings)?;
        if lacking.is_empty() {
            lines.push(format!("ready duty={}", duty.name()));
        }
        ready &= lacking.is_empty();
        lines.extend(lacking.iter().map(Unready::line));
        if duty == Duty::Launch {
            lines.extend(unconfined_lines());
            lines.extend(
                crate::effects::linked_seats(settings)?
                    .iter()
                    .map(|seat| linked_seat_line(seat)),
            );
        }
    }
    Ok((lines, ready))
}

/// What the confinement lacks on this computer, by agent-runtime's probe
/// over this process's `PATH`: `bwrap` absent, or a trial the kernel
/// refuses. A host other than Linux answers unconfined by name and lacks
/// nothing.
fn confinement_lacking() -> Option<(&'static str, &'static str, String)> {
    let path = std::env::var_os("PATH");
    let refusal = agent_runtime::confine::probe(Host::this(), path.as_deref()).err()?;
    let missing = Error::from(refusal)
        .fields()
        .iter()
        .any(|(field, value)| field == "cause" && value == "bwrap-missing");
    Some(if missing {
        (WRAPPER, "bwrap-missing", format!("install-{WRAPPER}"))
    } else {
        (WRAPPER, "userns-off", USERNS_FIX.to_owned())
    })
}

/// The lanes a launch runs unconfined by name, said beside the launch
/// duty's readiness, refusing nothing: `confinement=off harness=H cause=C`
/// for each harness agent-runtime's answer leaves unconfined on this host.
fn unconfined_lines() -> Vec<String> {
    Harness::ALL
        .into_iter()
        .filter_map(|harness| match answer(Host::this(), harness) {
            Answer::Confined => None,
            Answer::Unconfined { cause } => Some(format!(
                "confinement=off harness={} cause={}",
                harness.name(),
                serde_json::to_value(cause)
                    .ok()
                    .and_then(|v| v.as_str().map(str::to_owned))
                    .unwrap_or_default()
            )),
        })
        .collect()
}

/// The line naming a configured Codex seat whose lanes run unconfined,
/// in the form of [`unconfined_lines`] with the seat beside the cause.
fn linked_seat_line(seat: &Path) -> String {
    let cause = serde_json::to_value(agent_runtime::confine::Cause::LinkedSeat)
        .ok()
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_default();
    format!(
        "confinement=off harness={} cause={cause} seat={}",
        Harness::Codex.name(),
        seat.display()
    )
}

/// The file `name` resolves to on this process's search path, a regular
/// file someone may execute: the one `PATH` lookup of this crate.
pub fn on_path(name: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|path| {
        std::env::split_paths(&path)
            .map(|dir| dir.join(name))
            .find(|candidate| executable(candidate).is_none())
    })
}

/// Why `path` is no program to run: `absent` or `not-executable`; `None`
/// for a regular file someone may execute.
pub(crate) fn executable(path: &Path) -> Option<&'static str> {
    use std::os::unix::fs::PermissionsExt;
    match std::fs::metadata(path) {
        Ok(m) if m.is_file() && m.permissions().mode() & 0o111 != 0 => None,
        Ok(_) => Some("not-executable"),
        Err(_) => Some("absent"),
    }
}

/// A runtime's state as its wrapper answers `version`: `None` built,
/// `unbuilt` on the wrapper's 69, with the setup's refusal where the
/// wrapper built first; `building` where the bound ended a call whose
/// stderr opened with the wrapper's `setup-building` line; `unanswered` on
/// any other answer; or why the wrapper is no program to run.
#[allow(
    clippy::disallowed_methods,
    reason = "readiness runs a runtime's own wrapper for its `version` alone, the wrapper's 69 the one reading of an unbuilt key, before any duty claims"
)]
fn built(
    name: &'static str,
    wrapper: &Path,
    settings: &Settings,
) -> Result<Option<(&'static str, Option<String>)>> {
    if let Some(cause) = executable(wrapper) {
        return Ok(Some((cause, None)));
    }
    let answered = host::run_tagged(
        "ready",
        name,
        wrapper,
        "version",
        &["version"],
        settings.engine.verify.get()?,
    );
    Ok(match answered {
        Ok(out) => match out.status.code() {
            Some(0) => None,
            Some(SETUP_REQUIRED) => Some(("unbuilt", build_refusal(&out))),
            _ => Some(("unanswered", None)),
        },
        Err(e) => {
            let text = e.to_string();
            let began = text.split_once(host::STDERR_BEGAN).map(|(_, line)| line);
            Some((
                if began.is_some_and(building) {
                    "building"
                } else {
                    "unanswered"
                },
                None,
            ))
        }
    })
}

/// The fix for a runtime that is not ready: orch's setup where it is
/// unbuilt, building or unanswered, the package's install where its wrapper
/// is gone.
fn fix_of(cause: &str, setup: &Path) -> String {
    match cause {
        "absent" | "not-executable" => INSTALL_PACKAGES.to_owned(),
        _ => setup.display().to_string(),
    }
}

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    Error::from(agent_runtime::Error::refused(key, fields))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A duty's name reads back as the duty, and a word no duty spells is
    /// refused by name.
    #[test]
    fn every_duty_reads_back_by_its_name_and_an_unknown_one_is_refused() {
        for duty in Duty::DUTIES {
            assert_eq!(Duty::from_word(duty.name()).unwrap(), duty);
        }
        let err = Duty::from_word("nap").unwrap_err();
        assert_eq!(err.key(), "duty-unknown");
    }
}
