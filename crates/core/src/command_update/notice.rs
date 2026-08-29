//! What the sidebar card is told about the `kendex` command beside the
//! app. The one place a [`CommandBeside`] becomes text bound for the UI,
//! so the rule that no value read off the machine reaches a command string
//! is kept in one file.

use serde::Serialize;
use specta::Type;

use super::CommandBeside;
use crate::install_channel::InstallChannel;
use crate::names::shown;

/// What the sidebar card says about the `kendex` command beside the app,
/// before Update now is pressed — afterwards the app has restarted and
/// there is no card left to say it on. `None` where there is nothing to
/// say: no command here, or one Update now carries across itself.
///
/// Every string is fixed text decided by which arm ran, save the path,
/// which names one file to a person who may have several — the rule the
/// [`InstallChannel`] command strings already live under.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
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

/// What `kendex update` is spelled as when it has to run as root.
const ELEVATED_UPDATE: &str = "sudo kendex update";

impl CommandNotice {
    /// What the card owes a person about this command, or `None` where it
    /// owes them nothing.
    pub fn for_card(beside: &CommandBeside) -> Option<Self> {
        match beside {
            CommandBeside::Ours(_) | CommandBeside::Absent => None,
            CommandBeside::NeedsPrivilege(path) => Some(Self::NeedsPrivilege {
                path: shown(&path.display().to_string()),
                command: ELEVATED_UPDATE.to_owned(),
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
