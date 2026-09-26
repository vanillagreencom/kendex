//! The kendex command a macOS app carries, put on `PATH`.
//!
//! The `.dmg` app holds the command at `Contents/MacOS/kendex` and nothing
//! outside the bundle names it. Installing it is one link,
//! `/usr/local/bin/kendex` to that sidecar, written through one
//! administrator prompt. A link rather than a copy: a copy is a loose
//! command the app's updater never moves, where a link keeps following the
//! app as it updates itself, and `install_channel::inside_the_app` reads a
//! command reached through it as the app's own.
//!
//! [`state`] is the one judge, read by the first-launch question and the
//! Settings row alike. [`install`] judges again before and after the
//! privileged step, so nothing is written on an answer that went stale
//! while a dialog was open. What that step may replace is decided here and
//! compared again inside the step itself ([`LINK_SCRIPT`]), because between
//! the two the directory is anybody's and the step runs as root.

use std::ffi::{OsStr, OsString};
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use serde::Serialize;
use specta::Type;

use crate::base::Base;
use crate::command_update::{
    COMMAND_NAME, INSTALLER_SYSTEM_BIN, InstalledCommand, command_candidates,
};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::install_channel::{Host, HostProbe, inside_the_app};
use crate::process::Hardened;
use crate::settings::{self, AppSettings, CommandLinkPrompt};

/// Where Homebrew links its commands on Apple silicon. Searched, never
/// written: that tree is Homebrew's.
const HOMEBREW_BIN: &str = "/opt/homebrew/bin";

/// The directory macOS runs a quarantined app from when it is opened where
/// it was downloaded. Nothing under it outlives the process.
const TRANSLOCATED: &str = "AppTranslocation";

/// Where macOS mounts a disk image, the `.dmg` included. An app opened
/// straight from the image is gone once the image is ejected.
const VOLUMES: &str = "/Volumes";

/// The status [`LINK_SCRIPT`] exits with when what is at the link is no
/// longer what [`state`] saw. The script spells it as a literal; the suite
/// runs the script and reads its status through this constant, so the two
/// cannot drift apart unnoticed.
const MOVED_EXIT: i32 = 3;

/// AppleScript's error number for a dialog the person dismissed.
const CANCELLED_NUMBER: i32 = -128;

/// How long the administrator prompt may stay open. A person is reading it
/// and typing a password, so this is a person's pace rather than a
/// program's; past it the prompt is ended and the attempt reported.
const ADMIN_PROMPT_TIMEOUT: Duration = Duration::from_secs(300);

/// The privileged step: make `$2` a link to `$3`, creating `$1` first
/// (`/usr/local/bin` does not exist on a fresh Apple-silicon Mac).
///
/// `$4` is what the link held when [`state`] judged it, or empty where
/// nothing was there. The step goes ahead only while that is still so —
/// nothing at all, or a link with exactly that text — and otherwise exits
/// [`MOVED_EXIT`] having touched nothing. It compares with the judge's
/// answer rather than judging again: which links may be replaced is
/// decided once, in [`slot`].
///
/// The comparison and the write are two steps, and something can still
/// land at `$2` between them. The write is `ln -sn`, which treats `$2` as
/// a name even where it is a link to a directory: an arrival there makes
/// the write fail, where a plain `ln -s` would create the link inside the
/// directory it names, as root. [`install`] then judges again and reports
/// what is there.
///
/// Neither `$1` nor any directory above it may be a link: one pointing
/// elsewhere, such as `/usr/local` at `/opt/homebrew`, would have the step
/// write there as root.
///
/// Constant text; every value reaches it as an argument.
const LINK_SCRIPT: &str = r#"dir=$1 link=$2 target=$3 was=$4
d=$dir
while [ "$d" != / ]; do
  if [ -L "$d" ]; then echo "$d is a link, not a directory" >&2; exit 1; fi
  d=$(/usr/bin/dirname "$d")
done
/bin/mkdir -p "$dir" || exit 1
if [ -z "$was" ]; then
  if [ -e "$link" ] || [ -L "$link" ]; then exit 3; fi
else
  { [ -L "$link" ] && [ "$(/usr/bin/readlink "$link")" = "$was" ]; } || exit 3
  /bin/rm -f "$link" || exit 1
fi
/bin/ln -sn "$target" "$link" || exit 1
"#;

/// Runs [`LINK_SCRIPT`] under `do shell script ... with administrator
/// privileges`, the one prompt macOS shows. Every argument passes through
/// AppleScript's `quoted form of`, so no path is ever read as shell text.
const ADMIN_APPLESCRIPT: &str = r#"on run argv
	set shellCommand to "/bin/sh -c " & quoted form of (item 1 of argv)
	repeat with i from 2 to (count of argv)
		set shellCommand to shellCommand & " " & quoted form of (item i of argv)
	end repeat
	do shell script shellCommand with administrator privileges
end run"#;

/// Where the command is looked for and where the link goes: this Mac's
/// places in the app, a temporary tree in a suite.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Places {
    /// The link this module writes.
    pub link: PathBuf,
    /// Where an installed kendex command is looked for.
    pub searched: Vec<PathBuf>,
}

impl Places {
    /// This Mac: the link in `/usr/local/bin`, where `install.sh` also puts
    /// the command. The search is the one the app's updater runs for the
    /// command beside it — every `PATH` entry, then `install.sh`'s two
    /// directories — with Homebrew's `bin` and the recorded command after
    /// it. `path_var` is the app's `PATH`, which the launch environment has
    /// already taken from the login shell; the two additions cover a shell
    /// whose startup files never name them.
    pub fn on_this_mac(
        home: &Path,
        path_var: Option<&OsStr>,
        installed: Option<&InstalledCommand>,
    ) -> Places {
        let mut searched = command_candidates(home, path_var);
        let more = std::iter::once(Path::new(HOMEBREW_BIN).join(COMMAND_NAME))
            .chain(installed.map(|record| record.path.clone()));
        for candidate in more {
            if !searched.contains(&candidate) {
                searched.push(candidate);
            }
        }
        Places {
            link: Path::new(INSTALLER_SYSTEM_BIN).join(COMMAND_NAME),
            searched,
        }
    }
}

/// Where the kendex command stands for the running app.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum CommandLink {
    /// The running app holds no command: a build that was not bundled, or
    /// a platform whose installer puts the command on `PATH` itself.
    NotCarried,
    /// The app runs from where it will not stay — a copy macOS translocated,
    /// or a mounted disk image — so a link to it would stop working, and no
    /// kendex command is installed. Opening it from Applications lifts this.
    Transient,
    /// `link` already runs this app's command at `target`.
    Linked { link: PathBuf, target: PathBuf },
    /// Installing creates `link` pointing at `target`. `replaces` is set
    /// where the link leads into another copy of kendex now, which the
    /// install points at this one instead.
    Offered {
        link: PathBuf,
        target: PathBuf,
        replaces: Option<PathBuf>,
    },
    /// A kendex command is already installed at `path`, and it is not a
    /// link into a kendex app at `link`.
    Elsewhere { path: PathBuf },
    /// Something other than a link into a kendex app is at `link`, and no
    /// searched place holds a command. kendex leaves it alone.
    Taken { link: PathBuf },
}

/// What the first-launch question and the Settings row read.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CommandLinkState {
    pub command: CommandLink,
    /// Whether the first launch puts the question.
    pub ask: bool,
}

/// Why an install did not leave the link in place.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum LinkRefused {
    /// The administrator prompt was dismissed. Nothing changed.
    Cancelled,
    /// What is there now takes no install; `command` says what it is.
    NotOffered { command: CommandLink },
    /// The link is not in place, in words.
    Failed { message: String },
}

impl From<CoreError> for LinkRefused {
    fn from(error: CoreError) -> LinkRefused {
        LinkRefused::Failed {
            message: error.to_string(),
        }
    }
}

/// What the privileged step is asked to do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkPlan {
    pub link: PathBuf,
    pub target: PathBuf,
    /// The link's text as it was judged, or `None` where nothing was there.
    pub was: Option<PathBuf>,
}

impl LinkPlan {
    /// [`LINK_SCRIPT`], the name it runs under, and its arguments in the
    /// order it reads them.
    fn script_args(&self) -> Vec<OsString> {
        let dir = self.link.parent().unwrap_or(Path::new("/"));
        vec![
            OsString::from(LINK_SCRIPT),
            OsString::from("kendex-link"),
            dir.as_os_str().to_owned(),
            self.link.as_os_str().to_owned(),
            self.target.as_os_str().to_owned(),
            self.was.clone().unwrap_or_default().into_os_string(),
        ]
    }
}

/// How the privileged step ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Elevated {
    Done,
    /// The person dismissed the prompt.
    Cancelled,
    /// What was at the link changed after it was judged; nothing was
    /// written.
    Moved,
    Failed(String),
}

/// Runs the privileged step. The administrator prompt needs a person at the
/// keyboard, so a suite hands [`install`] a step of its own.
pub trait Elevate {
    fn link(&self, plan: &LinkPlan) -> Elevated;
}

/// The administrator prompt, through `osascript`.
pub struct AdministratorPrompt;

impl Elevate for AdministratorPrompt {
    fn link(&self, plan: &LinkPlan) -> Elevated {
        let run = Hardened::osascript(ADMIN_APPLESCRIPT, plan.script_args())
            .timeout(ADMIN_PROMPT_TIMEOUT)
            .run();
        match run {
            Err(error) => Elevated::Failed(error.to_string()),
            Ok(output) if output.status.success() => Elevated::Done,
            Ok(output) => from_osascript(&String::from_utf8_lossy(&output.stderr)),
        }
    }
}

/// How `osascript` reported a failed run. It prints the script's error as
/// `<span>: execution error: <text> (<number>)`, where the number is
/// AppleScript's for a dismissed dialog, or the exit status of a
/// `do shell script` that failed.
fn from_osascript(stderr: &str) -> Elevated {
    let said = stderr.trim();
    let number = said
        .strip_suffix(')')
        .and_then(|rest| rest.rsplit_once('('))
        .and_then(|(_, number)| number.parse::<i32>().ok());
    match number {
        Some(CANCELLED_NUMBER) => Elevated::Cancelled,
        Some(MOVED_EXIT) => Elevated::Moved,
        _ if said.is_empty() => {
            Elevated::Failed("the administrator step failed and said nothing".to_owned())
        }
        _ => Elevated::Failed(said.to_owned()),
    }
}

/// What is at the link.
enum Slot {
    Empty,
    /// A link that resolves to this app's command.
    Here,
    /// A link into another kendex app's bundle, whether that copy is still
    /// there or not. `text` is the link as written, `command` the path it
    /// names.
    OtherApp {
        text: PathBuf,
        command: PathBuf,
    },
    /// Anything else: a file, a directory, a link somewhere else.
    Foreign,
}

fn slot(link: &Path, target: &Path) -> Result<Slot> {
    let Some(meta) = crate::fs::entry(link)? else {
        return Ok(Slot::Empty);
    };
    if !meta.file_type().is_symlink() {
        return Ok(Slot::Foreign);
    }
    if Host.resolve(link) == Host.resolve(target) {
        return Ok(Slot::Here);
    }
    let text = std::fs::read_link(link).map_err(|error| CoreError::io(link, error))?;
    let command = match text.is_absolute() {
        true => text.clone(),
        false => link.parent().unwrap_or(Path::new("/")).join(&text),
    };
    let into_an_app = command.file_name().is_some_and(|name| name == COMMAND_NAME)
        && inside_the_app(&command, &Host);
    Ok(match into_an_app {
        true => Slot::OtherApp { text, command },
        false => Slot::Foreign,
    })
}

struct Judged {
    command: CommandLink,
    /// Present exactly when `command` is [`CommandLink::Offered`].
    plan: Option<LinkPlan>,
    /// Whether any searched place holds a command.
    reachable: bool,
}

impl Judged {
    fn settled(command: CommandLink, reachable: bool) -> Judged {
        Judged {
            command,
            plan: None,
            reachable,
        }
    }
}

/// Whether the app at `target` runs from where it will not stay, so a link
/// to it would soon lead nowhere: a copy macOS translocated, or an app
/// opened straight from a mounted disk image.
fn transient(target: &Path) -> bool {
    target.starts_with(VOLUMES)
        || target
            .components()
            .any(|part| part == Component::Normal(TRANSLOCATED.as_ref()))
}

fn judge(app_exe: Option<&Path>, places: &Places) -> Result<Judged> {
    let Some(target) = app_exe
        .and_then(Path::parent)
        .map(|dir| dir.join(COMMAND_NAME))
    else {
        return Ok(Judged::settled(CommandLink::NotCarried, false));
    };
    if !inside_the_app(&target, &Host) || !crate::fs::is_executable(&target) {
        return Ok(Judged::settled(CommandLink::NotCarried, false));
    }
    let found = places
        .searched
        .iter()
        .find(|path| crate::fs::is_executable(path));
    // A command already installed is the answer wherever the app runs from;
    // only with none does the app's own place decide.
    if transient(&target) {
        return Ok(match found {
            Some(path) => Judged::settled(CommandLink::Elsewhere { path: path.clone() }, true),
            None => Judged::settled(CommandLink::Transient, false),
        });
    }
    let link = places.link.clone();
    let offered = |replaces: Option<PathBuf>, was: Option<PathBuf>| Judged {
        command: CommandLink::Offered {
            link: link.clone(),
            target: target.clone(),
            replaces,
        },
        plan: Some(LinkPlan {
            link: link.clone(),
            target: target.clone(),
            was,
        }),
        reachable: found.is_some(),
    };
    Ok(match (slot(&link, &target)?, found) {
        (Slot::Here, _) => Judged::settled(
            CommandLink::Linked {
                link: link.clone(),
                target: target.clone(),
            },
            true,
        ),
        (Slot::OtherApp { text, command }, _) => offered(Some(command), Some(text)),
        (Slot::Empty | Slot::Foreign, Some(path)) => {
            Judged::settled(CommandLink::Elsewhere { path: path.clone() }, true)
        }
        (Slot::Empty, None) => offered(None, None),
        (Slot::Foreign, None) => Judged::settled(CommandLink::Taken { link: link.clone() }, false),
    })
}

/// Where the command stands for the app running from `app_exe`, and
/// whether the first launch asks about it. `app_exe` is the running
/// executable as the process was handed it, `None` on a platform whose
/// installer needs no link.
///
/// It asks only where the answer can be yes and nothing is installed yet:
/// the install is on offer, no searched place holds a command, and the
/// question has not been answered before. A link into another copy of
/// kendex that still runs is offered in Settings but not asked about,
/// because a kendex command is already reachable.
pub fn state(
    app_exe: Option<&Path>,
    places: &Places,
    prompt: CommandLinkPrompt,
) -> Result<CommandLinkState> {
    let judged = judge(app_exe, places)?;
    let ask = match prompt {
        CommandLinkPrompt::Ask => judged.plan.is_some() && !judged.reachable,
        CommandLinkPrompt::Answered => false,
    };
    Ok(CommandLinkState {
        command: judged.command,
        ask,
    })
}

/// Put the link in place, through `elevate`.
///
/// Judged again first, so a Settings row or a dialog drawn a while ago
/// cannot start a write on what it saw then, and again after, so success
/// means the link leads to this app's command rather than that the step
/// exited zero.
pub fn install(
    app_exe: Option<&Path>,
    places: &Places,
    elevate: &dyn Elevate,
) -> std::result::Result<(), LinkRefused> {
    let judged = judge(app_exe, places)?;
    let Some(plan) = judged.plan else {
        return match judged.command {
            CommandLink::Linked { .. } => Ok(()),
            command => Err(LinkRefused::NotOffered { command }),
        };
    };
    match elevate.link(&plan) {
        Elevated::Done => {}
        Elevated::Cancelled => return Err(LinkRefused::Cancelled),
        Elevated::Failed(message) => return Err(LinkRefused::Failed { message }),
        Elevated::Moved => {
            return match judge(app_exe, places)?.command {
                CommandLink::Linked { .. } => Ok(()),
                CommandLink::Offered { .. } => Err(LinkRefused::Failed {
                    message: format!(
                        "{} changed while the administrator prompt was open, so nothing was written; try again",
                        plan.link.display()
                    ),
                }),
                command => Err(LinkRefused::NotOffered { command }),
            };
        }
    }
    match judge(app_exe, places)?.command {
        CommandLink::Linked { .. } => Ok(()),
        CommandLink::NotCarried
        | CommandLink::Transient
        | CommandLink::Offered { .. }
        | CommandLink::Elsewhere { .. }
        | CommandLink::Taken { .. } => Err(LinkRefused::Failed {
            message: format!(
                "the administrator step finished, but {} does not lead to {}",
                plan.link.display(),
                plan.target.display()
            ),
        }),
    }
}

/// Record that the first-launch question was answered, so it is not put
/// again.
pub fn answer_prompt(env: &Env) -> Result<(AppSettings, Base)> {
    settings::mutate(env, |settings| {
        settings.command_link_prompt = CommandLinkPrompt::Answered;
        Ok(())
    })
}

#[cfg(test)]
mod tests;
