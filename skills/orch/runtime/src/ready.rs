//! Whether what a duty needs is ready on this computer: the one judge, and
//! the one table of what each of orch's duties needs. A duty asks
//! ([`admit`]) before it claims anything and refuses
//! `unready duty=D program=P cause=C fix=F`, exit 1; `orch-runtime ready`
//! prints every duty's answer ([`report`]), and orch's setup prints it at
//! its end.
//!
//! A runtime built from sources is judged by its own wrapper, which holds
//! the one key reader: `version` answers 0 built, 69 unbuilt. Another
//! package's program is judged present and executable only, since each
//! package refuses its own missing tools. A harness's binary stays the
//! launch's own preflight: the walk chooses the harness per launch. A
//! lookup that chooses between two mechanisms (the job's service manager or
//! `setsid`, `flock` or the `mkdir` mutex) stays where the choice is made,
//! and the table names what that choice needs.

use std::path::{Path, PathBuf};

use agent_runtime::host;

use crate::error::{Error, Result};
use crate::settings::{ORCH_SETUP, Settings};

/// A wrapper's exit for a runtime whose sources are unbuilt.
const SETUP_REQUIRED: i32 = 69;

/// The fix that installs a missing package's program.
const INSTALL_PACKAGES: &str = "kendex-apply";

/// The refusal's key: a duty on an installation that cannot serve it.
const UNREADY: &str = "unready";

/// Whether a runtime's wrapper answered `status` for its key unbuilt.
pub fn setup_required(status: Option<i32>) -> bool {
    status == Some(SETUP_REQUIRED)
}

/// What `duty` lacks where the wrapper of the runtime `program` answered
/// setup-required in the middle of its work: the line its admission prints
/// for the same state.
pub fn unbuilt(duty: Duty, program: &str, settings: &Settings) -> Unready {
    Unready {
        duty,
        program: program.to_owned(),
        cause: "unbuilt",
        fix: settings
            .roots
            .project
            .join(ORCH_SETUP)
            .display()
            .to_string(),
    }
}

/// A duty of orch's that asks before it claims anything.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Duty {
    /// `watch run`: the fleet's scheduler, which wakes the overseer through
    /// agent-runtime and reads its mailbox and its panes.
    Watch,
    /// A lane's launch: a window on the fleet's server, a worktree's git.
    Launch,
    /// A controller's start: a window on the fleet's server.
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
}

impl Duty {
    /// Every duty, in the order `orch-runtime ready` prints them.
    pub const DUTIES: [Duty; 8] = [
        Duty::Watch,
        Duty::Launch,
        Duty::Controller,
        Duty::Job,
        Duty::Register,
        Duty::CiProof,
        Duty::ReconcileItems,
        Duty::Prune,
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

/// One program a duty needs, as the judge reads it.
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
    /// One of two mechanisms a choice made where they run takes, the second
    /// the one it falls to: ready where either stands.
    Either(&'static str, &'static str),
}

/// What a duty lacks on this computer and the fix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Unready {
    pub duty: Duty,
    pub program: String,
    pub cause: &'static str,
    pub fix: String,
}

impl Unready {
    /// The line `orch-runtime ready` prints and the refusal's fields.
    pub fn line(&self) -> String {
        format!(
            "unready duty={} program={} cause={} fix={}",
            self.duty.name(),
            self.program,
            self.cause,
            self.fix
        )
    }

    /// The duty's refusal, before it claims anything.
    pub fn refusal(&self) -> Error {
        refused(
            UNREADY,
            &[
                ("duty", self.duty.name()),
                ("program", &self.program),
                ("cause", self.cause),
                ("fix", &self.fix),
            ],
        )
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
        Duty::Launch => vec![Need::OnPath("tmux"), Need::OnPath("git")],
        Duty::Controller | Duty::Register => vec![Need::OnPath("tmux")],
        Duty::Job => vec![Need::OnPath("tmux"), Need::Either("systemd-run", "setsid")],
        Duty::CiProof | Duty::ReconcileItems => vec![Need::OnPath("gh"), Need::OnPath("git")],
        Duty::Prune => vec![
            Need::Entry {
                name: "worktree",
                path: settings.worktree_cli.clone(),
            },
            Need::OnPath("git"),
        ],
    }
}

/// What `duty` lacks on this computer, every program it needs judged.
pub fn judge(duty: Duty, settings: &Settings) -> Result<Vec<Unready>> {
    let setup = settings.roots.project.join(ORCH_SETUP);
    let mut lacking = Vec::new();
    for need in needs(duty, settings) {
        let found = match &need {
            Need::Built { name, wrapper } => {
                built(name, wrapper, settings)?.map(|cause| (*name, cause, fix_of(cause, &setup)))
            }
            Need::Entry { name, path } => {
                executable(path).map(|cause| (*name, cause, INSTALL_PACKAGES.to_owned()))
            }
            Need::OnPath(name) => on_path(name)
                .is_none()
                .then(|| (*name, "absent", format!("install-{name}"))),
            Need::Either(first, second) => (on_path(first).is_none() && on_path(second).is_none())
                .then(|| (*second, "absent", format!("install-{second}"))),
        };
        if let Some((program, cause, fix)) = found {
            lacking.push(Unready {
                duty,
                program: program.to_owned(),
                cause,
                fix,
            });
        }
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

/// Every line `orch-runtime ready` prints for `duties`: `ready duty=D`, or
/// one `unready` line per program a duty lacks.
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
    }
    Ok((lines, ready))
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
fn executable(path: &Path) -> Option<&'static str> {
    use std::os::unix::fs::PermissionsExt;
    match std::fs::metadata(path) {
        Ok(m) if m.is_file() && m.permissions().mode() & 0o111 != 0 => None,
        Ok(_) => Some("not-executable"),
        Err(_) => Some("absent"),
    }
}

/// A runtime's state as its wrapper answers `version`: `None` built,
/// `unbuilt` on the wrapper's 69, `unanswered` on any other answer, or why
/// the wrapper is no program to run.
#[allow(
    clippy::disallowed_methods,
    reason = "readiness runs a runtime's own wrapper for its `version` alone, the wrapper's 69 the one reading of an unbuilt key, before any duty claims"
)]
fn built(name: &'static str, wrapper: &Path, settings: &Settings) -> Result<Option<&'static str>> {
    if let Some(cause) = executable(wrapper) {
        return Ok(Some(cause));
    }
    let answered = host::run_tagged(
        "ready",
        name,
        wrapper,
        "version",
        &["version"],
        settings.engine.verify.get()?,
    );
    Ok(match answered.map(|out| out.status.code()) {
        Ok(Some(0)) => None,
        Ok(Some(SETUP_REQUIRED)) => Some("unbuilt"),
        Ok(_) | Err(_) => Some("unanswered"),
    })
}

/// The fix for a runtime that is not ready: orch's setup where it is
/// unbuilt or unanswered, the package's install where its wrapper is gone.
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
