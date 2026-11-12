//! Whether a turn end is a launched lane's: the lane's root, its item and
//! the launch marker that binds them. A launch writes the lane's root to
//! the marker under the common git directory, which no checkout carries, so
//! a mailbox a repository commits never poses as a lane; the marker's
//! spelling and its reader are `marker`'s.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host::{self, Place};
use agent_runtime::reading::Reading;

use super::answer::Said;
use super::payload::{Caller, Payload};
use super::{Arm, Flow, Turn, Vars};
use crate::marker;

/// The bound on one `git` read of the lane's checkout.
const GIT_BOUND: Duration = Duration::from_secs(30);

/// The lane a turn end's identity names: its root, the common git
/// directory its markers live in, its mailbox root and its item.
pub struct Lane {
    pub root: PathBuf,
    /// `None` where a managed home that is no repository is read without
    /// lane discovery: no marker stands there.
    pub common: Option<PathBuf>,
    pub mail_root: PathBuf,
    /// The mailbox this lane reads, empty where the root holds no fleet lane.
    pub item: Option<String>,
}

impl Lane {
    /// The root, its common git directory and its item, in the order the
    /// lane's root is decided: the directory the harness started the session
    /// in (`CLAUDE_PROJECT_DIR`); else the root the marker for
    /// `LANE_MAIL_ITEM` binds, where that root stands, since a lane runs its
    /// post-merge steps from the main clone; else the directory the call
    /// runs in. A Copilot context reading starts from the session directory
    /// its payload names. Git reports one status for a directory that is no
    /// repository and for metadata it cannot read, and a lane always runs in
    /// one: with no mailbox under it the session is no lane and passes, with
    /// one the lane cannot be named, which is never passed off as no lane.
    pub(super) fn read(turn: &mut Turn, vars: &Vars, payload: &Payload) -> Flow<Lane> {
        let lane_dir = match (&turn.arm, &vars.project_dir) {
            (Some(Arm::Usage), _) => PathBuf::from(&payload.cwd),
            (_, Some(project)) => project.clone(),
            (_, None) => vars.pwd.clone(),
        };
        let (mut root, common) = match marker::located(&lane_dir) {
            Ok(Ok(checkout)) => (checkout.root, Some(checkout.common)),
            Ok(Err(words)) => unlocated(turn, vars, lane_dir, &words)?,
            Err(e) => unlocated(turn, vars, lane_dir, &e.to_string())?,
        };
        if vars.project_dir.is_none()
            && let Some(item) = &vars.item
            && marker::item_name(item).is_ok()
            && let Some(bound) = bound_root(turn, common.as_deref(), item)?
            && is_dir(Path::new(&bound))
        {
            root = PathBuf::from(bound);
        }
        let mail_root = root.join("tmp").join("lane-mail");
        let mut lane = Lane {
            root,
            common,
            mail_root,
            item: None,
        };
        lane.refuse_missing_mailbox(turn, vars, payload)?;
        lane.item = lane.item_of(turn, vars)?;
        Ok(lane)
    }

    /// A root its launch marker binds is a lane whatever else it lacks, and
    /// a lane with no mailbox directory reads no halt and no directive while
    /// its overseer's sends have nowhere to land. So it is refused, naming
    /// the marker and the one command that restores the directory; that
    /// command alone passes a tool call. A subagent is refused it and told to
    /// report the gap; a caller the payload leaves unknown may run it, since
    /// the directory holds no mail it could consume. The command makes the
    /// directory and no more: the item is known here only in lower case, and
    /// a mailbox made in that case would be refused by `lane-mail` as a case
    /// variant of the one the overseer's first send creates.
    fn refuse_missing_mailbox(&self, turn: &mut Turn, vars: &Vars, payload: &Payload) -> Flow {
        if matches!(turn.arm, Some(Arm::Row { .. } | Arm::Lane)) || is_dir(&self.mail_root) {
            return Ok(());
        }
        let Some(common) = &self.common else {
            return Ok(());
        };
        if !is_dir(&common.join("lane-mail")) {
            return Ok(());
        }
        let named = match &vars.item {
            Some(item) => item.clone(),
            None => self.branch(turn)?,
        };
        if marker::item_name(&named).is_err() {
            return Ok(());
        }
        if !self.bound_here(bound_root(turn, Some(common), &named)?) {
            return Ok(());
        }
        let command = format!("mkdir -p -- {}", shell_quoted(&self.mail_root));
        let subagent = turn.caller == Caller::Subagent;
        if !subagent && matches!(turn.arm, Some(Arm::Halt)) {
            let call = payload
                .command()
                .map_err(|invalid| turn.refuse(Said::PayloadInvalid, &invalid.0))?;
            if call == command {
                return Err(turn.pass());
            }
        }
        let marker = marker::marker_path(common, &named);
        let said = Said::MailboxMissing {
            mail_root: self.mail_root.clone(),
            marker,
            command: (!subagent).then_some(command),
        };
        Err(turn.refuse(said, ""))
    }

    /// The item this lane reads: what the launch brief set
    /// (`LANE_MAIL_ITEM`), or the mailbox whose name is the branch, matched
    /// without regard to ASCII case since `worktree create` names a lane's
    /// branch after its item in lower case. A root with no mailbox directory
    /// holds no fleet lane: a launch makes the lane's own directory beside
    /// its marker, and a marked root without one was refused above.
    fn item_of(&self, turn: &mut Turn, vars: &Vars) -> Flow<Option<String>> {
        if !is_dir(&self.mail_root) {
            return Ok(None);
        }
        let branch = self.branch(turn)?;
        if let Some(item) = &vars.item {
            if marker::item_name(item).is_err() {
                return Err(turn.stall(Said::ItemInvalid, ""));
            }
            return Ok(Some(item.clone()));
        }
        if branch.is_empty() {
            return Ok(None);
        }
        let mut matched = None;
        let mut matches = 0;
        let entries = std::fs::read_dir(&self.mail_root).into_iter().flatten();
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.')
                || marker::item_name(&name).is_err()
                || !name.eq_ignore_ascii_case(&branch)
                || !is_dir(&entry.path())
            {
                continue;
            }
            matched = Some(name);
            matches += 1;
        }
        if matches > 1 {
            return Err(turn.stall(Said::ItemAmbiguous, ""));
        }
        Ok(matched)
    }

    /// Whether a launch recorded this lane: the marker for its item binds
    /// this root.
    pub(super) fn launched(&self, turn: &mut Turn) -> Flow<bool> {
        let Some(item) = &self.item else {
            return Ok(false);
        };
        let bound = bound_root(turn, self.common.as_deref(), item)?;
        Ok(self.bound_here(bound))
    }

    fn bound_here(&self, bound: Option<String>) -> bool {
        bound.is_some_and(|bound| OsStr::new(&bound) == self.root.as_os_str())
    }

    /// The branch the root has checked out, empty for a HEAD that names
    /// none. `symbolic-ref -q` exits 1 for a HEAD that names no branch
    /// (detached, and never a lane) and 128 for a repository it cannot read,
    /// so the two are told apart without reading git's prose.
    #[allow(
        clippy::disallowed_methods,
        reason = "the turn end's one read of the branch a lane's root has checked out, `git symbolic-ref` through the one runner; it acts on nothing"
    )]
    fn branch(&self, turn: &mut Turn) -> Flow<String> {
        let root = self.root.display().to_string();
        let command = format!("-C {root} symbolic-ref -q --short HEAD");
        let env = [("LC_ALL", OsStr::new("C"))];
        let ran = host::run_tagged_in(
            "turn-end",
            "git",
            Path::new("git"),
            "symbolic-ref",
            &["-C", &root, "symbolic-ref", "-q", "--short", "HEAD"],
            Place {
                cwd: None,
                env: &env,
            },
            GIT_BOUND,
        );
        let out = match ran {
            Ok(out) => out,
            Err(e) => return Err(turn.stall(Said::Git(command), &e.to_string())),
        };
        let stdout = host::stdout_text(&out);
        match out.status.code() {
            Some(0) => Ok(stdout.trim_end_matches('\n').to_owned()),
            Some(1) => Ok(String::new()),
            _ => {
                let words = format!("{stdout}{}", host::stderr_text(&out));
                Err(turn.stall(Said::Git(command), &words))
            }
        }
    }
}

/// The root and common git directory of `lane_dir`, which git could not
/// read and answered with `words`. A managed assistant home need not be a
/// repository: its controller or visible identity gap is read with no lane
/// discovery. Elsewhere a directory with no mailbox is no lane.
fn unlocated(
    turn: &mut Turn,
    vars: &Vars,
    lane_dir: PathBuf,
    words: &str,
) -> Flow<(PathBuf, Option<PathBuf>)> {
    let has_mailbox = is_dir(&lane_dir.join("tmp").join("lane-mail"));
    if (vars.jarvis_record && !has_mailbox) || vars.tmux_without_pane {
        return Ok((lane_dir, None));
    }
    if !has_mailbox {
        return Err(turn.no_lane());
    }
    let command = format!(
        "-C {} rev-parse --show-toplevel --git-common-dir",
        lane_dir.display()
    );
    Err(turn.stall(Said::Git(command), words))
}

/// The root the marker for `item` under `common` binds, `None` where no
/// marker stands. A marker present in any form but a readable plain file is
/// reported rather than read as no lane.
fn bound_root(turn: &mut Turn, common: Option<&Path>, item: &str) -> Flow<Option<String>> {
    let Some(common) = common else {
        return Ok(None);
    };
    match marker::read_in(common, item) {
        Reading::Live(root) => Ok(Some(root)),
        Reading::Gone => Ok(None),
        Reading::Unreadable { .. } => {
            Err(turn.stall(Said::Marker(marker::marker_path(common, item)), ""))
        }
    }
}

/// A directory, through a link where one stands; unreadable reads as none,
/// as a shell's `-d` test reads it.
fn is_dir(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|meta| meta.is_dir())
}

/// `path` as one shell word, spelled as bash's `printf %q` spells an
/// absolute path, so the command a refusal names is the call the halt arm
/// compares with.
pub(super) fn shell_quoted(path: &Path) -> String {
    let text = path.to_string_lossy();
    if text.chars().any(char::is_control) {
        let mut quoted = String::from("$'");
        for c in text.chars() {
            match c {
                '\\' => quoted.push_str("\\\\"),
                '\'' => quoted.push_str("\\'"),
                '\n' => quoted.push_str("\\n"),
                '\t' => quoted.push_str("\\t"),
                '\r' => quoted.push_str("\\r"),
                c if c.is_control() => quoted.push_str(&format!("\\{:03o}", u32::from(c))),
                c => quoted.push(c),
            }
        }
        quoted.push('\'');
        return quoted;
    }
    let mut quoted = String::with_capacity(text.len());
    for c in text.chars() {
        let special = matches!(
            c,
            ' ' | '\''
                | '"'
                | '\\'
                | '$'
                | '&'
                | '|'
                | ';'
                | '('
                | ')'
                | '<'
                | '>'
                | '!'
                | '{'
                | '}'
                | '['
                | ']'
                | '*'
                | '?'
                | '^'
                | ','
                | '`'
        );
        if special {
            quoted.push('\\');
        }
        quoted.push(c);
    }
    quoted
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The spellings bash 5.3's `printf %q` gave for the same paths.
    #[test]
    fn a_path_is_quoted_as_bash_quotes_it() {
        for (path, bash) in [
            ("/a/b-c_d.e/tmp/lane-mail", "/a/b-c_d.e/tmp/lane-mail"),
            ("/a b/x", "/a\\ b/x"),
            ("/a,b=c+d@e%f^g:h~i", "/a\\,b=c+d@e%f\\^g:h~i"),
            ("/a'b", "/a\\'b"),
            ("/a\"b$c", "/a\\\"b\\$c"),
            ("/a\nb", "$'/a\\nb'"),
            ("/é/x", "/é/x"),
            ("/a[b]*?", "/a\\[b\\]\\*\\?"),
            ("/a#b{c}", "/a#b\\{c\\}"),
            ("/~a", "/~a"),
        ] {
            assert_eq!(shell_quoted(Path::new(path)), bash, "{path:?}");
        }
    }
}
