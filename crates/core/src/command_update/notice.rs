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
    /// Kendex's own command, where this app cannot write. `path` names
    /// the file the notice is about; `command` is the installer, which
    /// installs to the directory it selects rather than to that file.
    NeedsPrivilege { path: String, command: String },
    /// The same, on a platform with no installer to run. `path` names the
    /// file; `page` is where its release is downloaded, because there is
    /// nothing here to hand a person to run.
    NeedsDownload { path: String, page: String },
}

/// The invocation `install.sh` publishes for itself. The script is the
/// source of it and this is its only spelling in Rust;
/// `crates/cli/tests/install_script.rs` reads it out of the script's own
/// header and compares it against what the card offers, so the two cannot
/// drift — the way the `bindir` constants in this crate are pinned through
/// `command_candidates`, and through the public surface rather than by
/// exposing the constant.
///
/// It names no path, which is the whole of why it is this and not a
/// command aimed at the file. `sudo kendex update` resolves a bare name
/// against sudo's `secure_path` rather than the person's `PATH`, so it
/// reaches a second `kendex` or none at all; spelling the path into it
/// instead hands a root shell a name an unprivileged account decides,
/// because every route to that path — a write probe on a directory its
/// owner can open up again, a prefix an account owns — is one that account
/// can arrange.
///
/// What it costs: `kendex update` holds every download to the release key
/// before it writes, and this re-run does not — `install.sh` says so in
/// its own header, because minisign is not on a machine that has installed
/// nothing. What keeping the key check would have cost is the offer above:
/// `sudo` at the recorded path, which hands a root shell a name the account
/// arranges. So the trade is an unverified download against a local
/// privilege escalation, and the escalation is the worse of the two. The
/// card is text a person reads; nothing here runs either one.
///
/// It installs to the directory the script selects, which need not be the
/// file the card names — the copy beside it says so rather than promising
/// that file moves.
const INSTALLER_RERUN: &str = "curl -fsSL https://kendex.ai/install.sh | sh";

/// Where a release is downloaded, for a platform `install.sh` refuses.
/// `README.md` publishes it and this is its only spelling in Rust; the
/// suite beside this one reads it back out of the README, so the two
/// cannot drift — the same pin the invocation above carries.
const DOWNLOAD_PAGE: &str = "https://kendex.ai/download";

/// Whether this platform has an installer to re-run. `install.sh` takes
/// Linux and macOS and rejects everything else by name, and Windows has no
/// installer of its own — a `kendex.exe` is downloaded from the release —
/// so a pipeline offered there is an instruction that cannot be followed.
const HAS_INSTALLER: bool = !cfg!(windows);

impl CommandNotice {
    /// What the card owes a person about this command, or `None` where it
    /// owes them nothing.
    pub fn for_card(beside: &CommandBeside) -> Option<Self> {
        Self::for_card_where(beside, HAS_INSTALLER)
    }

    /// The same, told whether this platform has an installer, so a suite
    /// drives either arm whatever it is running on. Every caller outside a
    /// test comes through [`Self::for_card`], which asks the platform.
    pub(crate) fn for_card_where(beside: &CommandBeside, installer: bool) -> Option<Self> {
        match beside {
            CommandBeside::Ours(_) | CommandBeside::Absent => None,
            CommandBeside::NeedsPrivilege(path) => {
                let path = shown(&path.display().to_string());
                Some(match installer {
                    true => Self::NeedsPrivilege {
                        path,
                        command: INSTALLER_RERUN.to_owned(),
                    },
                    false => Self::NeedsDownload {
                        path,
                        page: DOWNLOAD_PAGE.to_owned(),
                    },
                })
            }
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
