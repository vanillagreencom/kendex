//! What the sidebar card is told about the `kendex` command beside the
//! app. The one place a [`CommandBeside`] becomes text bound for the UI,
//! so the rule that no value read off the machine reaches a command string
//! is kept in one file.

use serde::{Deserialize, Serialize};
use specta::Type;

use super::{CommandBeside, CommandHalf};
use crate::install_channel::InstallChannel;
use crate::names::shown;

/// What the sidebar card says about the `kendex` command beside the app.
/// Read before Update now is pressed, and read again after an install that
/// answered rather than restarting, which leaves the card up with this the
/// only thing on it that can still be true. An install that restarts takes
/// the card with it. `None` where there is nothing to say: no command
/// here, or one Update now carries across itself.
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

    /// What a person is owed when the command the update found was not the
    /// one the card described. Answered once both halves have landed.
    ///
    /// The card is the whole of what they are told about that command,
    /// because Update now restarts the app and takes the card with it. A
    /// disposition that changed while the card sat on screen is a sentence
    /// that was never said, and the command half then acted on the new
    /// answer. Nothing is refused — the app is on the new release either
    /// way — so this is where they hear about it, on a card the restart has
    /// not taken away yet.
    ///
    /// Compared as what was *said*, not as what was found: two `Ours` at
    /// different paths say the same nothing to a person and are the same
    /// answer here, while `Ours` become `NotOurs` says something new, and
    /// so does the reverse. A value that prints a path said that path as
    /// well, so two `NeedsPrivilege` naming different files are two
    /// different sentences: the person was pointed at one file and another
    /// is the one left behind, which is a change and is reported.
    ///
    /// Which sentence is `half`'s to decide, with one exception it cannot
    /// tell on its own: nothing there at all also says nothing to a card,
    /// so a lookup answering `None` is either the command this app just
    /// carried across — that is `Moved` — or no command on the machine,
    /// which is `Untouched` with nothing left behind to report.
    pub fn not_as_shown(
        release: &str,
        half: CommandHalf,
        found: Option<&Self>,
        shown: Option<&Self>,
    ) -> Option<String> {
        if found == shown {
            return None;
        }
        let installed = format!("kendex {release} is installed and starts on the next launch");
        Some(match (half, found) {
            (CommandHalf::Untouched, None) => format!(
                "{installed}; the kendex command the notice described is not beside this app any more, so nothing was carried across"
            ),
            (CommandHalf::Untouched, Some(_)) => format!(
                "{installed}; the kendex command beside this app is no longer the one the notice described, so it was left on the release it is on"
            ),
            (CommandHalf::Moved, _) => format!(
                "{installed}; the kendex command beside this app is no longer the one the notice described, so it was carried across rather than left where the notice said it would be"
            ),
        })
    }
}

#[cfg(test)]
mod tests;
