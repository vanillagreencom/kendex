//! What the sidebar card is told about the `kendex` command beside the
//! app. The one place a [`CommandBeside`] becomes text bound for the UI,
//! so the rule that no value read off the machine reaches a command string
//! is kept in one file.

use std::path::Path;

use serde::{Deserialize, Serialize};
use specta::Type;

use super::CommandBeside;
use crate::install_channel::InstallChannel;
use crate::names::{quoted, shown};

/// What the sidebar card says about the `kendex` command beside the app,
/// before Update now is pressed — afterwards the app has restarted and
/// there is no card left to say it on. `None` where there is nothing to
/// say: no command here, or one Update now carries across itself.
///
/// Every string is fixed text decided by which arm ran, save the path,
/// which names one file to a person who may have several — the rule the
/// [`InstallChannel`] command strings already live under.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum CommandNotice {
    /// Another installer owns the command; `manager` names it and
    /// `command` brings it current.
    Managed { manager: String, command: String },
    /// Nothing names an owner and no record proves the file is kendex's,
    /// so there is no name to print and no command to offer.
    Unknown,
    /// Kendex's own command, where this app cannot write. `command` is
    /// what carries it across with the privilege the app lacks.
    NeedsPrivilege { path: String, command: String },
}

/// What `kendex update` is spelled as when it has to run as root, naming
/// the file the card just named.
///
/// The path, because `sudo` resolves a bare name against its own
/// `secure_path` and not against this person's `PATH`. `install.sh` reaches
/// `/usr/local/bin` whenever that is the first of its two directories on
/// `PATH`, and that is the case that reaches this state at all — the app
/// cannot write there. A distribution whose `secure_path` leaves it out
/// answers `command not found`; one carrying a second `kendex` inside
/// `secure_path` updates that one and leaves this file where it was.
///
/// The path and nothing else. Carrying `HOME` would put the record where
/// the app reads it, and would also point a root process at a tree its
/// owner controls: the record is opened by name and every component of
/// that name is theirs to replace, so a person allowed only this one
/// command under `sudoers` could aim it at a root-owned file. What the
/// elevated run leaves behind is root's record and a stale one of theirs;
/// that is a card that stops offering, not a file that changes hands.
/// KEN-853 carries the record across without a privileged write.
///
/// Quoted, not merely shown: `shown` makes a path readable, and this is a
/// line somebody pastes into a root shell.
fn elevated_update(path: &Path) -> String {
    format!("sudo {} update", quoted(&path.display().to_string()))
}

impl CommandNotice {
    /// What the card owes a person about this command, or `None` where it
    /// owes them nothing.
    pub fn for_card(beside: &CommandBeside) -> Option<Self> {
        match beside {
            CommandBeside::Ours(_) | CommandBeside::Absent => None,
            CommandBeside::NeedsPrivilege(path) => Some(Self::NeedsPrivilege {
                path: shown(&path.display().to_string()),
                command: elevated_update(path),
            }),
            CommandBeside::NotOurs(InstallChannel::Managed { manager, command }) => {
                Some(Self::Managed {
                    manager: manager.clone(),
                    command: command.clone(),
                })
            }
            // `Direct` never reaches here — a command judged replaceable
            // is `Ours` or `NeedsPrivilege` — and `Unknown` is the arm
            // that names nobody. Both say the same thing to a person.
            CommandBeside::NotOurs(InstallChannel::Direct | InstallChannel::Unknown) => {
                Some(Self::Unknown)
            }
        }
    }
}

#[cfg(test)]
mod tests;
